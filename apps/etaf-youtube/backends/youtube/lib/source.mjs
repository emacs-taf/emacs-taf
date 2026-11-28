// Resolve expiring media URLs, full quality ladders, chapters and subtitles with yt-dlp.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { agentDirOf } from '../vendor/skill-config.mjs';
import { loadState, saveState } from '../vendor/skill-state.mjs';
import { fail } from '../vendor/render.mjs';

const IS_WIN = process.platform === 'win32';
const NULL_DEV = IS_WIN ? 'NUL' : '/dev/null';
const children = new Set();
const stop = child => {
  if (!IS_WIN) {
    try { process.kill(-child.pid, 'SIGKILL'); return; } catch {}
  }
  try { child.kill('SIGKILL'); } catch {}
};
process.on('exit', () => { for (const child of children) stop(child); });
for (const signal of ['SIGTERM', 'SIGHUP', 'SIGINT']) process.on(signal, () => {
  for (const child of children) stop(child);
  process.removeAllListeners(signal);
  process.kill(process.pid, signal);
});

const cleanEnv = () => {
  const env = { ...process.env, NO_PROXY: '*', no_proxy: '*' };
  for (const key of Object.keys(env)) if (/^(https?|all)_proxy$/i.test(key)) delete env[key];
  if (IS_WIN) {
    // Drop broken or untrusted NTFS mount points from PATH so Python-based
    // tools like yt-dlp never crash with WinError 448 inside os.path.realpath().
    for (const key of Object.keys(env)) {
      if (key.toUpperCase() !== 'PATH' || typeof env[key] !== 'string') continue;
      env[key] = env[key]
        .split(path.delimiter)
        .filter(dir => {
          if (!dir) return false;
          try { fs.realpathSync(dir); return true; } catch { return false; }
        })
        .join(path.delimiter);
    }
  }
  return env;
};

function run(program, args, timeout = 50000) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, {
      env: cleanEnv(),
      detached: !IS_WIN,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    children.add(child);
    let out = '', err = '', tooLarge = false, timedOut = false;
    const timer = setTimeout(() => { timedOut = true; stop(child); }, timeout);
    child.stdout.on('data', part => { out += part; if (out.length > 32 * 1024 * 1024) { tooLarge = true; stop(child); } });
    child.stderr.on('data', part => { err = (err + part).slice(-8000); });
    child.on('error', error => { clearTimeout(timer); children.delete(child); reject(error); });
    child.on('close', code => { clearTimeout(timer); children.delete(child); resolve({ code, out, err, timedOut, tooLarge }); });
  });
}

const routeFile = () => path.join(agentDirOf(), 'local', 'skills', 'youtube', 'route.json');

async function chooseRoute(exclude) {
  const saved = loadState(routeFile(), { version: 1 });
  if (!saved.error && saved.data && Date.now() - saved.data.at < 600000 && saved.data.proxy !== exclude) {
    return saved.data.proxy || '';
  }
  const candidates = [...new Set([
    '', process.env.HTTPS_PROXY, process.env.https_proxy,
    'http://127.0.0.1:7890', 'http://127.0.0.1:1080',
  ].filter(x => x !== undefined && x !== exclude))];
  for (const proxy of candidates) {
    const probe = await run('curl', [
      '--silent', '--show-error', '--output', NULL_DEV, '--fail', '--max-time', '5',
      ...(proxy ? ['--proxy', proxy, '--noproxy', ''] : ['--noproxy', '*']),
      'https://www.youtube.com/generate_204',
    ], 6500);
    if (probe.code === 0) {
      saveState(routeFile(), { proxy, at: Date.now() }, { version: 1 });
      return proxy;
    }
  }
  fail('external', '直连与本机代理均无法完成 YouTube TLS 请求', 'M-x etaf-youtube-account');
}

/** Export YouTube cookies from the controlled CDP Chrome into a 0600 Netscape cookie jar.
 *  Never calls --cookies-from-browser (which crashes on macOS encrypted Chrome DBs). */
async function exportCdpCookies() {
  try {
    const channel = await import(process.env.YOUTUBE_CDP_MODULE || '../vendor/cdp-channel.mjs');
    const targets = await channel.listTargets();
    const target = targets.find(t => t.type === 'page' && /^https:\/\/(?:www\.|m\.)?youtube\.com\//.test(t.url))
      || targets.find(t => t.type === 'page');
    if (!target) return null;
    const { cdp } = await channel.connectPage(null, target.id);
    let cookies = [];
    try {
      const res = await cdp.send('Network.getCookies', {
        urls: ['https://www.youtube.com', 'https://youtube.com', 'https://accounts.google.com', 'https://googlevideo.com'],
      }, { timeoutMs: 4000 });
      cookies = res?.cookies || [];
    } finally {
      cdp.close?.();
    }
    if (!cookies.length) return null;
    const lines = ['# Netscape HTTP Cookie File'];
    for (const c of cookies) {
      if (!c.domain || !c.name) continue;
      const domain = c.domain.startsWith('.') ? c.domain : `.${c.domain}`;
      const expires = Number.isFinite(c.expires) && c.expires > 0 ? Math.floor(c.expires) : 0;
      const val = String(c.value || '').replace(/[\r\n\t]/g, '');
      lines.push([domain, 'TRUE', c.path || '/', c.secure ? 'TRUE' : 'FALSE', expires, c.name, val].join('\t'));
    }
    const file = path.join(os.tmpdir(), `etaf-yt-cookies-${process.pid}-${Date.now()}.txt`);
    fs.writeFileSync(file, `${lines.join('\n')}\n`, { mode: 0o600 });
    return file;
  } catch {
    return null;
  }
}

function codecLabel(vcodec) {
  const c = String(vcodec || '').toLowerCase();
  if (c.startsWith('avc') || c.includes('h264')) return 'H.264';
  if (c.startsWith('vp09') || c.startsWith('vp9')) return 'VP9';
  if (c.startsWith('av01') || c.includes('av1')) return 'AV1';
  if (c.startsWith('hev') || c.startsWith('hvc')) return 'HEVC';
  return c ? c.split('.')[0].toUpperCase() : 'VIDEO';
}

function qualityLabel(height, fps) {
  const hiFps = Number(fps) >= 45 ? `${Math.round(Number(fps))}` : '';
  const base = `${height}p${hiFps}`;
  if (height >= 2160) return `${base} 4K`;
  if (height >= 1440) return `${base} 2K`;
  return base;
}

function isHlsProto(proto) {
  return proto === 'm3u8_native' || proto === 'm3u8';
}

function isDirectProto(proto) {
  return proto === 'https' || proto === 'http';
}

function pickBestAudio(formats, wantHls) {
  const audioOnly = formats.filter(f =>
    f.url && f.acodec && f.acodec !== 'none' && (!f.vcodec || f.vcodec === 'none')
    && (wantHls ? isHlsProto(f.protocol) : isDirectProto(f.protocol)));
  if (!audioOnly.length) return null;
  const score = f => {
    const ac = String(f.acodec || '').toLowerCase();
    const note = String(f.format_note || '').toLowerCase();
    // Avoid audio-description / DRC tracks when normal tracks exist
    const nonDesc = note.includes('descriptive') ? -500 : 0;
    const nonDrc = note.includes('drc') ? -20 : 0;
    // Prefer standard stereo AAC (mp4a) / Opus over exotic AC-3/IAMF
    const codecRank = ac.startsWith('mp4a') ? 40 : ac.includes('opus') ? 35 : ac.includes('aac') ? 30 : 0;
    const abr = Math.min(Number(f.abr || f.tbr || 0), 256);
    return nonDesc + nonDrc + codecRank + abr * 0.1;
  };
  return [...audioOnly].sort((a, b) => score(b) - score(a))[0];
}

function rankVideoFormat(f, height, preferHls) {
  const proto = f.protocol || '';
  const protoScore = preferHls
    ? (isHlsProto(proto) ? 1000 : isDirectProto(proto) ? 500 : 0)
    : (isDirectProto(proto) ? 1000 : isHlsProto(proto) ? 500 : 0);
  const fpsScore = (Number(f.fps) >= 45 ? 120 : 0) + Math.min(Number(f.fps || 0), 60);
  const c = codecLabel(f.vcodec);
  // Up to 1080p: H.264 decodes fastest across every CPU/GPU. 2K/4K: VP9 > AV1.
  let codecScore = 0;
  if (height <= 1080) {
    codecScore = c === 'H.264' ? 80 : c === 'VP9' ? 60 : c === 'AV1' ? 40 : 20;
  } else {
    codecScore = c === 'VP9' ? 80 : c === 'AV1' ? 60 : c === 'H.264' ? 50 : 20;
  }
  const tbrScore = Math.min(Number(f.vbr || f.tbr || 0), 30000) * 0.001;
  return protoScore + fpsScore + codecScore + tbrScore;
}

function buildStreams(info) {
  const formats = (info.formats || []).filter(f => f && f.url && f.ext !== 'mhtml');
  const isLive = !!info.is_live;
  const directAudio = pickBestAudio(formats, false);
  const hlsAudio = pickBestAudio(formats, true);
  const videoFormats = formats.filter(f =>
    f.vcodec && f.vcodec !== 'none' && Number(f.height) >= 144
    && (isDirectProto(f.protocol) || isHlsProto(f.protocol)));

  const byHeight = new Map();
  for (const f of videoFormats) {
    const h = Number(f.height);
    if (!byHeight.has(h)) byHeight.set(h, []);
    byHeight.get(h).push(f);
  }

  const heights = [...byHeight.keys()].sort((a, b) => b - a);
  const streams = [];
  for (const height of heights) {
    const cands = byHeight.get(height);
    const sorted = [...cands].sort((a, b) => rankVideoFormat(b, height, isLive) - rankVideoFormat(a, height, isLive));
    const best = sorted[0];
    if (!best) continue;
    const muxed = best.acodec && best.acodec !== 'none';
    const bestIsHls = isHlsProto(best.protocol);
    const matchedAudio = muxed ? null : (bestIsHls ? (hlsAudio || directAudio) : (directAudio || hlsAudio));
    // Alternate protocol backup (e.g. HLS fallback for DASH, or DASH fallback for HLS)
    const alt = sorted.find(f => isHlsProto(f.protocol) !== bestIsHls);
    const altMuxed = alt && alt.acodec && alt.acodec !== 'none';
    const altAudio = !alt || altMuxed ? null : (isHlsProto(alt.protocol) ? (hlsAudio || directAudio) : (directAudio || hlsAudio));

    streams.push({
      height,
      width: Number(best.width) || Math.round(height * 16 / 9),
      fps: Number(best.fps) || 30,
      label: qualityLabel(height, best.fps),
      vcodec: best.vcodec,
      codec_label: codecLabel(best.vcodec),
      protocol: best.protocol,
      format_id: best.format_id || '',
      video_url: best.url,
      audio_url: matchedAudio?.url || null,
      alt_video_url: alt?.url || null,
      alt_audio_url: altAudio?.url || null,
      alt_protocol: alt?.protocol || null,
      headers: best.http_headers || info.http_headers || {},
    });
  }
  return streams;
}

function buildSubtitles(info) {
  const raw = [];
  const seen = new Set();
  for (const [kind, tracks] of [['manual', info.subtitles], ['automatic', info.automatic_captions]]) {
    for (const [language, formats] of Object.entries(tracks || {})) {
      if (!Array.isArray(formats)) continue;
      const track = formats.find(x => x.ext === 'json3')
        || formats.find(x => x.ext === 'vtt')
        || formats.find(x => x.ext === 'srv3');
      if (!track?.url) continue;
      const key = `${kind}:${language}`;
      if (seen.has(key)) continue;
      seen.add(key);
      raw.push({
        language,
        name: track.name || language,
        kind,
        ext: track.ext || 'json3',
        url: track.url,
      });
    }
  }
  const langWeight = item => {
    const l = item.language.toLowerCase();
    const manualBonus = item.kind === 'manual' ? 100 : 0;
    if (l === 'zh-hans' || l === 'zh-cn') return manualBonus + 50;
    if (l.startsWith('zh')) return manualBonus + 45;
    if (l === 'en' || l === 'en-orig' || l === 'en-us') return manualBonus + 40;
    if (l.startsWith('en')) return manualBonus + 35;
    if (l.startsWith('ja')) return manualBonus + 20;
    return manualBonus;
  };
  return raw.sort((a, b) => langWeight(b) - langWeight(a));
}

function buildChapters(info) {
  return (info.chapters || []).map(c => ({
    title: String(c.title || '').trim(),
    start: Math.max(0, Math.floor(Number(c.start_time) || 0)),
    end: Math.max(0, Math.floor(Number(c.end_time) || 0)),
  })).filter(c => c.title);
}

function parseVttCues(vtt) {
  const cues = [];
  const toSec = ts => {
    const parts = ts.trim().replace(',', '.').split(':').map(Number);
    if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length === 2) return parts[0] * 60 + parts[1];
    return 0;
  };
  const blocks = vtt.replace(/\r\n/g, '\n').split(/\n\n+/);
  for (const block of blocks) {
    const lines = block.split('\n').map(l => l.trim()).filter(Boolean);
    const arrowIdx = lines.findIndex(l => l.includes('-->'));
    if (arrowIdx < 0) continue;
    const [rawStart, rawEnd] = lines[arrowIdx].split('-->').map(s => s.trim().split(/\s+/)[0]);
    const text = lines.slice(arrowIdx + 1).join(' ').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
    if (!text) continue;
    const start = toSec(rawStart);
    const end = Math.max(start + 0.5, toSec(rawEnd));
    cues.push({ start, end, text });
  }
  return cues;
}

function parseJson3Cues(data) {
  const cues = [];
  for (const ev of data.events || []) {
    if (!ev.segs) continue;
    const text = ev.segs.map(y => y.utf8 || '').join('').replace(/\s+/g, ' ').trim();
    if (!text) continue;
    const start = (Number(ev.tStartMs) || 0) / 1000;
    const dur = Math.max(500, Number(ev.dDurationMs) || 2000);
    cues.push({ start, end: start + dur / 1000, text });
  }
  return cues.sort((a, b) => a.start - b.start);
}

export async function media(videoId, quality = '1080', timeout = 55000) {
  let route = await chooseRoute();
  const cookieFile = await exportCdpCookies();
  const baseArgs = [
    '--no-playlist', '--skip-download', '--no-warnings',
    '--socket-timeout', '12', '--retries', '1', '-J',
  ];
  const jsRuntimeArgs = process.execPath
    ? ['--no-js-runtimes', '--js-runtimes', `node:${process.execPath}`]
    : [];
  const runExtract = async (useCookies, currentRoute, withJsRuntime = true) => {
    const args = [
      ...baseArgs,
      ...(withJsRuntime ? jsRuntimeArgs : []),
      ...(useCookies && cookieFile ? ['--cookies', cookieFile] : []),
      ...(currentRoute ? ['--proxy', currentRoute] : []),
      '--', `https://www.youtube.com/watch?v=${videoId}`,
    ];
    const res = await run(process.env.YOUTUBE_YTDLP || 'yt-dlp', args, timeout);
    if (withJsRuntime && jsRuntimeArgs.length && res.code !== 0 && !res.timedOut
        && /no such option.*js-runtimes/i.test(res.err)) {
      return runExtract(useCookies, currentRoute, false);
    }
    return res;
  };

  let result;
  try {
    try {
      result = await runExtract(!!cookieFile, route);
      // If browser cookies triggered a YouTube reload/bot prompt, fall back once to cookieless extraction
      if (result.code !== 0 && !result.timedOut && cookieFile
          && /reload|cookies|sign in|bot|403/i.test(result.err)) {
        result = await runExtract(false, route);
      }
      if (result.code !== 0 && !result.timedOut
          && /connection|timed out|TLS|SSL|network|resolve|reset/i.test(result.err)) {
        route = await chooseRoute(route);
        result = await runExtract(!!cookieFile, route);
      }
    } catch (error) {
      if (error.code === 'ENOENT') fail('deps', '缺少 yt-dlp 或 curl', '安装 yt-dlp 与 curl（macOS: brew install yt-dlp，Windows: scoop install yt-dlp / winget install yt-dlp.yt-dlp，Linux: apt/pipx）');
      throw error;
    }
  } finally {
    if (cookieFile) try { fs.rmSync(cookieFile, { force: true }); } catch {}
  }

  if (result.timedOut) fail('timeout', '获取视频播放源超时', `node backends/youtube/youtube.mjs source ${videoId}`);
  if (result.tooLarge) fail('external', '播放源响应超过 32 MiB 上限', 'M-x etaf-youtube-account');
  if (result.code !== 0) {
    fail(/sign in|login|cookies/i.test(result.err) ? 'auth' : 'external',
      result.err.trim().split('\n').at(-1) || 'yt-dlp 未返回播放源', 'M-x etaf-youtube-login');
  }

  let info;
  try { info = JSON.parse(result.out); }
  catch { fail('external', 'yt-dlp 返回的不是 JSON', 'M-x etaf-youtube-account'); }

  const streams = buildStreams(info);
  let chosen = null;
  if (streams.length) {
    if (quality === 'best') {
      chosen = streams[0];
    } else {
      const cap = Number(quality) || 1080;
      chosen = streams.find(s => s.height <= cap) || streams[streams.length - 1];
    }
  } else {
    // Fallback to top-level url if info.formats was empty
    const selected = info.requested_formats || [info];
    const v = selected.find(f => f.vcodec && f.vcodec !== 'none' && f.url);
    const a = selected.find(f => f.acodec && f.acodec !== 'none' && (!f.vcodec || f.vcodec === 'none') && f.url);
    if (v) {
      chosen = {
        height: Number(v.height) || 720,
        width: Number(v.width) || 1280,
        fps: Number(v.fps) || 30,
        label: qualityLabel(Number(v.height) || 720, v.fps),
        vcodec: v.vcodec || '',
        codec_label: codecLabel(v.vcodec),
        protocol: v.protocol || 'https',
        format_id: v.format_id || '',
        video_url: v.url,
        audio_url: a?.url || null,
        alt_video_url: null,
        alt_audio_url: null,
        alt_protocol: null,
        headers: v.http_headers || info.http_headers || {},
      };
      streams.push(chosen);
    }
  }
  if (!chosen) fail('notfound', '没有可播放的视频源', `node backends/youtube/youtube.mjs video ${videoId}`);

  let expires = null;
  try { expires = new URL(chosen.video_url).searchParams.get('expire') || null; } catch {}

  return {
    id: info.id || videoId,
    title: info.title || '',
    duration: Number(info.duration || 0),
    width: chosen.width,
    height: chosen.height,
    fps: chosen.fps,
    codec_label: chosen.codec_label,
    quality_label: chosen.label,
    protocol: chosen.protocol,
    video_url: chosen.video_url,
    audio_url: chosen.audio_url || null,
    alt_video_url: chosen.alt_video_url || null,
    alt_audio_url: chosen.alt_audio_url || null,
    headers: chosen.headers || {},
    proxy: route || null,
    qualities: streams.map(s => s.height),
    streams,
    chapters: buildChapters(info),
    subtitles: buildSubtitles(info),
    expires,
  };
}

export async function caption(videoId, language, quality, timeout, directUrl = '') {
  let trackUrl = directUrl;
  let kind = 'manual';
  let proxy = '';
  if (trackUrl) {
    proxy = await chooseRoute();
    // Request json3 when given a raw timedtext URL without explicit fmt
    try {
      const u = new URL(trackUrl);
      if (u.pathname.includes('timedtext') && !u.searchParams.has('fmt')) {
        u.searchParams.set('fmt', 'json3');
        trackUrl = u.toString();
      }
    } catch {}
  } else {
    const resolved = await media(videoId, quality || '720', timeout);
    const track = resolved.subtitles.find(x => x.language === language);
    if (!track) fail('notfound', `视频没有 ${language} 字幕`, `node backends/youtube/youtube.mjs source ${videoId}`);
    trackUrl = track.url;
    kind = track.kind;
    proxy = resolved.proxy || '';
  }

  const result = await run('curl', [
    '--silent', '--show-error', '--fail', '--location', '--max-time', '20',
    ...(proxy ? ['--proxy', proxy, '--noproxy', ''] : ['--noproxy', '*']),
    trackUrl,
  ], 22000);
  if (result.code !== 0) fail('external', '字幕获取失败', `node backends/youtube/youtube.mjs captions ${videoId} --language ${language}`);

  let cues = [];
  const raw = result.out.trim();
  if (raw.startsWith('{')) {
    try { cues = parseJson3Cues(JSON.parse(raw)); }
    catch { fail('external', '字幕 JSON3 解析失败', 'M-x etaf-youtube-account'); }
  } else if (raw.startsWith('WEBVTT')) {
    cues = parseVttCues(raw);
  } else {
    fail('external', '字幕格式不受支持', 'M-x etaf-youtube-account');
  }

  return { id: videoId, language, kind, cues };
}
