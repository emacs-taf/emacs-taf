// Resolve expiring media URLs with yt-dlp; decoding belongs to the player.
import path from 'node:path';
import { spawn } from 'node:child_process';
import { agentDirOf } from '../vendor/skill-config.mjs';
import { loadState, saveState } from '../vendor/skill-state.mjs';
import { profileDir } from '../vendor/cdp-channel.mjs';
import { fail } from '../vendor/render.mjs';

const children = new Set();
const stop = child => { try { process.kill(-child.pid, 'SIGKILL'); } catch { child.kill('SIGKILL'); } };
process.on('exit', () => { for (const child of children) stop(child); });
for (const signal of ['SIGTERM', 'SIGHUP', 'SIGINT']) process.on(signal, () => {
  for (const child of children) stop(child);
  process.removeAllListeners(signal);
  process.kill(process.pid, signal);
});
const cleanEnv = () => {
  const env = { ...process.env, NO_PROXY: '*', no_proxy: '*' };
  for (const key of Object.keys(env)) if (/^(https?|all)_proxy$/i.test(key)) delete env[key];
  return env;
};
function run(program, args, timeout = 50000) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { env: cleanEnv(), detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
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
  if (!saved.error && saved.data && Date.now() - saved.data.at < 600000 && saved.data.proxy !== exclude) return saved.data.proxy;
  const candidates = [...new Set(['', process.env.HTTPS_PROXY, process.env.https_proxy, 'http://127.0.0.1:7890', 'http://127.0.0.1:1080'].filter(x => x !== undefined && x !== exclude))];
  for (const proxy of candidates) {
    const probe = await run('curl', ['--silent', '--show-error', '--output', '/dev/null', '--fail', '--max-time', '5', '--proxy', proxy,
      ...(proxy ? ['--noproxy', ''] : []), 'https://www.youtube.com/generate_204'], 6500);
    if (probe.code === 0) { saveState(routeFile(), { proxy, at: Date.now() }, { version: 1 }); return proxy; }
  }
  fail('external', '直连与本机代理均无法完成 YouTube TLS 请求', 'pi-skill youtube check');
}
export async function media(videoId, quality = '720', timeout = 55000) {
  const cap = quality === 'best' ? '' : `[height<=${quality}]`;
  let route = await chooseRoute();
  const args = ['--no-playlist', '--skip-download', '--no-warnings', '--socket-timeout', '12', '--retries', '0',
    '--cookies-from-browser', `chrome:${profileDir()}`, '-J', '-f', `bv*${cap}+ba/b${cap}`, '-S', 'vcodec:h264,res'];
  let result;
  try {
    result = await run(process.env.YOUTUBE_YTDLP || 'yt-dlp', [...args, '--proxy', route, '--', `https://www.youtube.com/watch?v=${videoId}`], timeout);
    if (result.code !== 0 && !result.timedOut && /connection|timed out|TLS|SSL|network|resolve|reset/i.test(result.err)) {
      route = await chooseRoute(route);
      result = await run(process.env.YOUTUBE_YTDLP || 'yt-dlp', [...args, '--proxy', route, '--', `https://www.youtube.com/watch?v=${videoId}`], timeout);
    }
  } catch (error) {
    if (error.code === 'ENOENT') fail('deps', '缺少 yt-dlp 或 curl', 'brew install yt-dlp curl');
    throw error;
  }
  if (result.timedOut) fail('timeout', '获取视频播放源超时', `pi-skill youtube source ${videoId}`);
  if (result.tooLarge) fail('external', '播放源响应超过 32 MiB 上限', 'pi-skill youtube check');
  if (result.code !== 0) fail(/sign in|login|cookies/i.test(result.err) ? 'auth' : 'external', result.err.trim().split('\n').at(-1) || 'yt-dlp 未返回播放源', 'pi-skill youtube login');
  let info;
  try { info = JSON.parse(result.out); } catch { fail('external', 'yt-dlp 返回的不是 JSON', 'pi-skill youtube check'); }
  const selected = info.requested_formats || [info];
  const video = selected.find(f => f.vcodec && f.vcodec !== 'none' && f.url);
  const audio = selected.find(f => f.acodec && f.acodec !== 'none' && f.url);
  if (!video) fail('notfound', '没有可播放的视频源', `pi-skill youtube video ${videoId}`);
  const subtitles = [];
  for (const [kind, tracks] of [['manual', info.subtitles], ['automatic', info.automatic_captions]])
    for (const [language, formats] of Object.entries(tracks || {})) {
      const track = formats.find(x => x.ext === 'json3');
      if (track) subtitles.push({ language, name: track.name || language, kind, url: track.url });
    }
  return { id: info.id, title: info.title, duration: info.duration || 0, width: video.width, height: video.height, fps: video.fps || 24,
    video_url: video.url, audio_url: audio?.url || '', headers: video.http_headers || info.http_headers || {}, proxy: route,
    qualities: [...new Set((info.formats || []).filter(x => x.vcodec !== 'none' && x.height).map(x => x.height))].sort((a, b) => b - a),
    subtitles, expires: new URL(video.url).searchParams.get('expire') || null };
}
export async function caption(videoId, language, quality, timeout) {
  const resolved = await media(videoId, quality, timeout);
  const track = resolved.subtitles.find(x => x.language === language);
  if (!track) fail('notfound', `视频没有 ${language} 字幕`, `pi-skill youtube source ${videoId}`);
  const result = await run('curl', ['--silent', '--show-error', '--fail', '--max-time', '20', '--proxy', resolved.proxy,
    ...(resolved.proxy ? ['--noproxy', ''] : []), track.url], 22000);
  if (result.code !== 0) fail('external', '字幕获取失败', `pi-skill youtube captions ${videoId} --language ${language}`);
  let data;
  try { data = JSON.parse(result.out); } catch { fail('external', '字幕没有返回 JSON3 内容', 'pi-skill youtube check'); }
  return { id: videoId, language, kind: track.kind, cues: (data.events || []).filter(x => x.segs).map(x => ({
    start: x.tStartMs / 1000, end: (x.tStartMs + (x.dDurationMs || 0)) / 1000, text: x.segs.map(y => y.utf8 || '').join('') })) };
}
