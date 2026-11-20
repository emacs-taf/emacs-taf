#!/usr/bin/env node
// netease-cli.mjs —— 编排层：把命令翻译成取数/播放调用，并管理登录态与队列。
//
// 分工（每层可单独验证）：
//   netease-api.mjs  取数：直连接口，收参数、出 JSON，不认识状态目录
//   mpv-ctl.mjs      播放：常驻 mpv 的 IPC 桥（Unix socket / Windows 命名管道）
//   lib/queue.mjs    队列：queue.json + queue.m3u8 + urls.txt 三份文件的模型
//   本文件           编排：组合上面三层，保存登录态与队列
//
// 为什么单独一层：编排原来只有 netease-music.sh 一份，而 bash 在 Windows 上
// 没有原生实现（`bash.exe' 是 WSL 启动器，读不了 Windows 路径）。编排放在
// Node 里，各平台都由 node.exe 直接执行，不需要任何 shell 参与。
//
// 与客户端（Emacs）的约定，和 netease-music.sh 相同：
//   成功：stdout 一行 JSON（--json）或一行结论，退出 0
//   失败：stderr 一行 {"error":CODE,"hint":TEXT}，退出 usage=2 auth=3 notfound=4 其它=5
import { execFile, spawn } from 'node:child_process';
import { mkdir, open, readFile, rm, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  m3uOf, queueFiles, queueIndexOf, readQueue, readUrls, songOfEntry, writeQueue, writeUrls,
} from './lib/queue.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const API = join(HERE, 'netease-api.mjs');
const MPVCTL = join(HERE, 'mpv-ctl.mjs');
const CDN = join(HERE, 'lib', 'cdn-url.mjs');
const REFRESH = join(HERE, 'refresh-urls.mjs');
// 状态目录与 netease-music.sh 用同一套规则，两个入口永远看同一份登录态与队列。
const STATE_DIR =
  process.env.NETEASE_MUSIC_STATE_DIR ||
  join(process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state'), 'netease-music');
const CONFIG = join(STATE_DIR, 'config.json');
const KEEPALIVE_PID = join(STATE_DIR, 'keepalive.pid');
// 登录可能要等手机上的安全验证，比普通取数宽松得多。
const API_TIMEOUT = 300_000;
const URL_CHUNK = 200;

class CliError extends Error {
  constructor(code, hint) {
    super(hint);
    this.code = code;
    this.hint = hint;
  }
}

// 取数层和播放层都是黑盒命令：成功给一行 JSON，失败给一行错误 JSON 和退出码。
// 这里只转发，让调用方拿到原样的 error/hint 与退出码。
function nodeRun(script, args, { cookie } = {}) {
  const env = { ...process.env };
  if (cookie) env.NETEASE_COOKIE = cookie;
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [script, ...args],
      { env, timeout: API_TIMEOUT, maxBuffer: 8 << 20, windowsHide: true },
      (error, stdout, stderr) => {
        if (error) {
          const report = lastJson(stderr);
          reject(new CliError(report?.error || 'external', report?.hint || stderr.trim() || String(error)));
          return;
        }
        const data = lastJson(stdout);
        if (data) resolve(data);
        else reject(new CliError('internal', '后端没有返回 JSON：' + stdout.trim().slice(0, 200)));
      });
  });
}

const api = (args, cookie) => nodeRun(API, args, { cookie });
const mpv = (args) => nodeRun(MPVCTL, args);

// 进度行也会写到 stderr，所以要找最后那一行 JSON。
function lastJson(text) {
  for (const line of String(text).trim().split('\n').reverse()) {
    try {
      return JSON.parse(line);
    } catch {
      continue;
    }
  }
  return null;
}

async function readConfig() {
  try {
    return JSON.parse(await readFile(CONFIG, 'utf8'));
  } catch {
    return {};
  }
}

// 只并进要改的键，其余原样留着：配置里还有音质、did 这些别的入口写的内容。
async function writeConfig(patch) {
  const config = { ...(await readConfig()), ...patch };
  await mkdir(STATE_DIR, { recursive: true });
  await writeFile(CONFIG, JSON.stringify(config, null, 2), 'utf8');
  return config;
}

const cookie = async () => process.env.NETEASE_COOKIE || (await readConfig()).cookie || '';
const quality = async () => process.env.NETEASE_MUSIC_QUALITY || (await readConfig()).quality || 'lossless';

const maskPhone = (phone) => String(phone).replace(/^(\d{3})\d*(\d{4})$/, '$1****$2');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function isoNow() {
  const now = new Date();
  const pad = (value, width = 2) => String(Math.abs(value)).padStart(width, '0');
  const offset = -now.getTimezoneOffset();
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
    + `T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`
    + `${offset < 0 ? '-' : '+'}${pad(Math.trunc(offset / 60))}${pad(offset % 60)}`;
}

function emit({ conclusion, ...fields }) {
  const payload = { ok: true, conclusion, ...fields, as_of: isoNow() };
  console.log(jsonOut ? JSON.stringify(payload) : conclusion);
}

// ---------- 登录 ----------
// 短信登录分两步，和命令行一致：先发码，再拿码换 cookie。
async function login(phone, code) {
  if (!/^\d{5,20}$/.test(phone || '')) {
    throw new CliError('usage', '短信登录要先给手机号：login --sms <手机号>');
  }
  if (!code) {
    await api(['sms-send', phone]);
    await writeConfig({ phone });
    const masked = maskPhone(phone);
    return { conclusion: `验证码已发到 ${masked}：收到后输入验证码完成登录`, phone: masked };
  }
  if (!/^\d{3,8}$/.test(code)) throw new CliError('usage', '验证码应是 3-8 位数字');
  const { cookie: session } = await api(['sms-login', phone, code]);
  // 先落盘：接口已经给了登录态，后面取昵称失败也不该把这次登录丢掉。
  await writeConfig({ cookie: session, phone });
  const account = await api(['session'], session);
  return { conclusion: `登录成功：${account.nick || maskPhone(phone)}`, nick: account.nick, uid: account.uid };
}

// ---------- 地址 ----------
// 播放地址是限时签名的，所以建队时现取；取不到的（要 VIP / 没版权）直接不进队列。
async function fetchUrls(ids) {
  const urls = new Map();
  const level = await quality();
  for (let i = 0; i < ids.length; i += URL_CHUNK) {
    const chunk = ids.slice(i, i + URL_CHUNK).map(String);
    // eslint-disable-next-line no-await-in-loop
    const { items } = await api(['url', ...chunk, '--level', level], await cookie());
    for (const item of items || []) {
      if (item.url) urls.set(String(item.id), { level: item.level || '', url: item.url });
    }
  }
  return urls;
}

// 直链节点可能整片 403（m804/m704 对我们的出口就整片拒绝，同一 path+query 在
// m801 是 206）。起播前按族抽一条探一探，坏了整族换到可用节点；探不通就沿用原地址。
function probeUrls(urls) {
  if (!urls.size) return Promise.resolve(urls);
  const input = [...urls].map(([id, value]) => `${id}\t${value.level}\t${value.url}`).join('\n') + '\n';
  return new Promise((resolve) => {
    const child = spawn(process.execPath,
      [CDN, '--sample', '1', '--concurrency', '16', '--timeout', '2000'],
      { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
    let out = '';
    const timer = setTimeout(() => {
      child.kill();
      resolve(urls);
    }, 20_000);
    child.stdout.on('data', (chunk) => { out += chunk; });
    child.on('error', () => {
      clearTimeout(timer);
      resolve(urls);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      const fixed = new Map();
      if (code === 0) {
        for (const line of out.split('\n')) {
          const [id, level, url] = line.split('\t');
          if (id && url) fixed.set(String(id), { level: level || '', url });
        }
      }
      resolve(fixed.size ? fixed : urls);
    });
    child.stdin.end(input);
  });
}

// ---------- 建队并开播 ----------
async function playSongs(songs, { start, shuffle = false } = {}) {
  if (!songs.length) throw new CliError('notfound', '这批里没有歌：换一个搜索结果或榜单');
  // `--start` 指的是它在这批里的序号（从 1 开始），先确认它自己真能播。
  const wanted = start ? songs[start - 1] : null;
  if (start && !wanted) {
    throw new CliError('notfound', '`--start` 指定的序号超出这批歌曲，队列未替换');
  }
  const urls = await probeUrls(await fetchUrls(songs.map((song) => song.id)));
  if (wanted && !urls.has(String(wanted.id))) {
    throw new CliError('notfound', '选中的这首不能播（可能要 VIP 或没有版权），队列未替换');
  }
  const tracks = songs
    .filter((song) => urls.has(String(song.id)))
    .map((song) => ({ song, ...urls.get(String(song.id)) }));
  if (!tracks.length) {
    throw new CliError('notfound', '没有一首能播（可能都要 VIP 或没版权）：换一首，或换张专辑');
  }
  // mpv 队列里的序号要按「能播的那批」重算，不能直接用它在这一批里的序号。
  const startAt = wanted ? tracks.findIndex((t) => String(t.song.id) === String(wanted.id)) + 1 : undefined;
  const queue = await writeQueue(STATE_DIR, tracks, {
    skipped: songs.length - tracks.length,
    start: startAt,
  });
  await mpv(['shuffle', shuffle ? 'on' : 'off']);
  await mpv(['play', queueFiles(STATE_DIR).m3u, ...(startAt ? ['--index', String(startAt - 1)] : [])]);
  await startKeepalive();
  return announce(queue);
}

async function currentSong() {
  let status;
  try {
    status = await mpv(['status']);
  } catch {
    return null;
  }
  const queue = await readQueue(STATE_DIR);
  const urls = await readUrls(STATE_DIR);
  // 映射不到（旧队列没有 [#id] 标题）才退回按位置取，宁可认错也不装作没有。
  return songOfEntry(status, queue, urls) || queue.songs[status.pos] || null;
}

// mpv 开着 shuffle 时「正在放」不一定是第一首，等它真出声再回读（最多 1.5 秒）。
async function announce(queue) {
  let song = null;
  for (let attempt = 0; attempt < 10 && !song; attempt += 1) {
    // eslint-disable-next-line no-await-in-loop
    song = await currentSong();
    if (!song) await sleep(150);
  }
  const playing = song || queue.songs[0] || null;
  const level = playing?.level || await quality();
  return {
    conclusion: playing ? `开始播放：${playing.name} - ${playing.artist}（队列 ${queue.songs.length} 首）` : '已建好队列',
    ...(playing ? { now_playing: `${playing.name} - ${playing.artist}`, song_id: playing.id } : {}),
    quality: level,
    ...(playing?.level && playing.level !== await quality() ? { quality_requested: await quality() } : {}),
    queue: queue.songs.length,
    ...(queue.skipped ? { skipped: `${queue.skipped}（要 VIP 或没版权）` } : {}),
    source: 'mpv',
  };
}

// ---------- 保活 ----------
// 直链约 5 分钟过期：后台按 URLS_AT 重取「还没播到的」地址并原地换掉 m3u 的行。
async function startKeepalive() {
  await stopKeepalive();
  // 日志跟 shell 入口用同一个文件，出问题时直接看 keepalive.log。
  const log = await open(join(STATE_DIR, 'keepalive.log'), 'a');
  const child = spawn(process.execPath, [REFRESH], {
    detached: true, stdio: ['ignore', log.fd, log.fd], env: process.env,
  });
  child.unref();
  await writeFile(KEEPALIVE_PID, String(child.pid), 'utf8');
}

async function stopKeepalive() {
  try {
    const pid = Number((await readFile(KEEPALIVE_PID, 'utf8')).trim());
    if (pid) process.kill(pid);
  } catch {
    // 没有在跑的保活进程：本来就没事可做
  }
  await rm(KEEPALIVE_PID, { force: true });
}

// ---------- 状态 ----------
async function status(extra = {}) {
  const [playing, queue, urls] = await Promise.all([
    mpv(['status']), readQueue(STATE_DIR), readUrls(STATE_DIR),
  ]);
  const song = songOfEntry(playing, queue, urls) || queue.songs[playing.pos] || null;
  const state = playing.idle ? 'idle' : playing.playing ? 'playing' : 'paused';
  const conclusion = song && state === 'playing' ? `正在播放：${song.name} - ${song.artist}`
    : song && state === 'paused' ? `已暂停：${song.name} - ${song.artist}`
      : playing.idle ? '没有在放' : '播放中';
  return {
    conclusion,
    ...(song ? { title: song.name, artist: song.artist, song_id: song.id } : {}),
    state,
    ...(playing.count ? { queue_pos: `${playing.pos + 1}/${playing.count}` } : {}),
    ...(playing.elapsed === null ? {} : { elapsed: playing.elapsed }),
    ...(playing.duration === null ? {} : { duration: playing.duration }),
    volume: playing.volume,
    repeat: playing.repeat,
    repeat_mode: playing.repeat_mode,
    shuffle: playing.shuffle,
    source: 'mpv',
    ...(playing.path ? { path: playing.path } : {}),
    ...extra,
  };
}

async function queueStatus(limit) {
  const [playlist, queue] = await Promise.all([mpv(['playlist']), readQueue(STATE_DIR)]);
  const count = playlist.count || 0;
  const conclusion = count
    ? `队列 ${count} 首（当前第 ${playlist.pos + 1} 首）`
    : '队列是空的（先 play / daily / liked / artist / album）';
  return {
    conclusion,
    count,
    ...(playlist.pos >= 0 ? { pos: playlist.pos + 1 } : {}),
    ...(limit && queue.songs.length > limit ? { songs_total: queue.songs.length } : {}),
    source: 'mpv',
  };
}

// ---------- 命令 ----------
async function playByIds(ids, start) {
  const { songs } = await api(['play-ids', ids.join(','), '--start', String(start)], await cookie());
  return { ...await playSongs(songs, { start }), start };
}

async function playSource(args, { shuffle = false } = {}) {
  const data = await api(args, await cookie());
  return playSongs(data.songs || [], { shuffle });
}

async function setting(name, value) {
  await mpv(value === undefined ? [name] : [name, String(value)]);
  return status({ command: name, ...(value === undefined ? {} : { requested_arg: value }) });
}

async function transport(name) {
  await mpv([name]);
  if (name === 'stop') await stopKeepalive();
  return status({ command: name });
}

async function setLike(liked) {
  const song = await currentSong();
  if (!song) throw new CliError('notfound', '取不到当前歌曲（队列信息丢了），先 play/daily 一下');
  await api(['like', String(song.id), ...(liked ? [] : ['--unlike'])], await cookie());
  const state = await api(['like-state', String(song.id)], await cookie());
  return {
    conclusion: state.liked
      ? `已加入「我喜欢的音乐」：${song.name}`
      : `已移出「我喜欢的音乐」：${song.name}`,
    song_id: song.id,
    title: song.name,
    liked: Boolean(state.liked),
  };
}

async function add(target) {
  const song = await api(['song', target], await cookie());
  const queue = await readQueue(STATE_DIR);
  if (!queue.songs.length) return playSongs([song]);
  if (queue.songs.some((item) => String(item.id) === String(song.id))) {
    return {
      conclusion: `没加：${song.name} - ${song.artist} 已经在队列里（队列 ${queue.songs.length} 首）`,
      added: 'no',
      count: queue.songs.length,
      source: 'local',
    };
  }
  const { items } = await api(['url', String(song.id), '--level', await quality()], await cookie());
  const item = (items || [])[0];
  if (!item || !item.url) throw new CliError('notfound', `这首拿不到播放地址（可能要 VIP 或已下架）：${song.name}`);
  const track = { song, level: item.level || '', url: item.url };
  // 先让 mpv 收到这一首，再落盘：反过来会留下「队列里有一首播不到的」。
  const staged = join(STATE_DIR, 'queue-add.m3u8');
  await writeFile(staged, m3uOf([track]), 'utf8');
  try {
    await mpv(['append', staged]);
  } finally {
    await rm(staged, { force: true });
  }
  const urls = await readUrls(STATE_DIR);
  urls.set(String(song.id), { level: track.level, url: track.url });
  await writeUrls(STATE_DIR, urls);
  const songs = [...queue.songs, { ...song, level: track.level }];
  const tracks = songs.map((entry) => ({ song: entry, ...urls.get(String(entry.id)) })).filter((t) => t.url);
  await writeFile(queueFiles(STATE_DIR).queue, JSON.stringify({ ...queue, songs }, null, 1), 'utf8');
  await writeFile(queueFiles(STATE_DIR).m3u, m3uOf(tracks), 'utf8');
  return { ...await status(), conclusion: `已加到队尾：${song.name} - ${song.artist}（队列 ${songs.length} 首）`, added: `${song.name} - ${song.artist}`, count: songs.length };
}

// 队列第 N 首 → mpv 里的序号。mpv 开着 shuffle 时它自己重排了队列，
// 直接拿 N 当序号会跳错歌，所以按歌 id 把两边对应起来。
async function jumpTo(queuePosition) {
  if (!Number.isSafeInteger(queuePosition) || queuePosition < 1) {
    throw new CliError('usage', '用法：jump <队列第几首，从 1 开始>');
  }
  const queue = await readQueue(STATE_DIR);
  const song = queue.songs[queuePosition - 1];
  if (!song) throw new CliError('notfound', `队列里没有第 ${queuePosition} 首（先 queue 看队列）`);
  const [playlist, urls, playing] = await Promise.all([
    mpv(['playlist']), readUrls(STATE_DIR), mpv(['status']),
  ]);
  // 没打乱时序号就是序号；打乱了又定位不到就明确报出来，不静默跳错歌。
  const index = queueIndexOf(song.id, playlist.entries, urls)
    ?? (playing.shuffle ? null : queuePosition);
  if (!index) {
    throw new CliError('notfound',
      '这首歌在 mpv 队列里定位不到（标题是旧格式或地址已刷新），随机播放时不能可靠跳转；先 shuffle off 或重放一次队列');
  }
  await mpv(['jump', String(index)]);
  return status({ command: 'jump', jumped: queuePosition });
}

const COMMANDS = {
  // 登录：login --sms <手机号> [--sms-code <验证码>]
  login: ({ args: [phone], flags }) => login(phone, flags.get('--sms-code')),

  status: () => status(),

  queue: ({ flags }) => queueStatus(Number(flags.get('--limit')) || 0),

  'play-ids': ({ args: [ids], flags }) => {
    const list = String(ids || '').split(',').filter(Boolean).map(Number);
    if (!list.length || list.some((id) => !Number.isSafeInteger(id) || id <= 0)) {
      throw new CliError('usage', '用法：play-ids <id,id,...> [--start N]');
    }
    const start = Number(flags.get('--start') || 1);
    if (!Number.isSafeInteger(start) || start < 1) throw new CliError('usage', '--start 需要从 1 开始的序号');
    return playByIds(list, start);
  },

  play: async ({ args: [target], flags }) => {
    if (!target) throw new CliError('usage', 'play 需要歌曲名、id 或链接');
    const found = /^\d+$/.test(target) ? { id: target } : await api(['song', target], await cookie());
    return playByIds([Number(found.id)], 1);
  },

  daily: ({ flags }) => playSource(['daily', '--limit', String(flags.get('--limit') || 40)],
    { shuffle: flags.has('--shuffle') }),
  liked: ({ flags }) => playSource(['liked', '--limit', String(flags.get('--limit') || 1000)],
    { shuffle: flags.has('--shuffle') }),
  fm: ({ flags }) => playSource(['fm', '--limit', String(flags.get('--limit') || 12)],
    { shuffle: flags.has('--shuffle') }),
  playlist: ({ args: [target], flags }) => playSource(
    ['playlist', String(target || '').replace(/.*[?&#/]id=/, ''), '--limit', String(flags.get('--limit') || 500)],
    { shuffle: flags.has('--shuffle') }),
  album: ({ args: [target], flags }) => playSource(
    ['album', String(target || ''), '--limit', String(flags.get('--limit') || 200)],
    { shuffle: flags.has('--shuffle') }),
  artist: ({ args: [target], flags }) => playSource(
    ['artist', String(target || ''), '--limit', String(flags.get('--limit') || 50)],
    { shuffle: flags.has('--shuffle') }),
  chart: ({ args: [target], flags }) => playSource(
    ['chart', String(target || ''), '--limit', String(flags.get('--limit') || 500)],
    { shuffle: flags.has('--shuffle') }),
  podcast: ({ args: [target], flags }) => playSource(
    ['podcast', String(target || ''), '--limit', String(flags.get('--limit') || 3)]),
  episode: ({ args: [target] }) => playSource(['episode', String(target || '')]),

  toggle: () => transport('toggle'),
  pause: () => transport('pause'),
  resume: () => transport('resume'),
  next: () => transport('next'),
  prev: () => transport('prev'),
  stop: () => transport('stop'),

  volume: ({ args: [value] }) => setting('volume', value),
  seek: ({ args: [value] }) => setting('seek', value ?? '0'),
  shuffle: ({ args: [value] }) => setting('shuffle', value ?? 'on'),
  repeat: ({ args: [value] }) => {
    const mode = !value || value === 'on' ? 'list' : value;
    if (!['off', 'list', 'single'].includes(mode)) {
      throw new CliError('usage', '用法：repeat off|list|single（on = list）');
    }
    return setting('repeat', mode);
  },

  jump: ({ args: [value] }) => jumpTo(Number(value)),

  add: ({ args: [target] }) => {
    if (!target) throw new CliError('usage', 'add 需要歌曲关键词或 id（例：add 幻听）');
    return add(target);
  },

  cover: async ({ args: [target], flags }) => {
    if (!target) throw new CliError('usage', 'cover 需要歌曲关键词或 id');
    const download = flags.get('--download');
    const args = ['cover', target, ...(download ? ['--download', download] : []),
      ...(flags.has('--force') ? ['--force'] : [])];
    const data = await api(args, await cookie());
    return { conclusion: data.file ? `封面已保存：${data.file}` : `封面：${data.cover || ''}`, ...data };
  },

  like: () => setLike(true),
  unlike: () => setLike(false),
};

// 带值的旗标按 `--name value` 收；其余 `--flag` 只记出现过。
const VALUED = new Set(['--sms-code', '--start', '--limit', '--download', '--level']);

function parse(argv) {
  const positional = [];
  const flags = new Map();
  let json = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--json') json = true;
    else if (arg === '--sms') continue;
    else if (VALUED.has(arg)) flags.set(arg, argv[++i]);
    else if (arg.startsWith('--')) flags.set(arg, '');
    else positional.push(arg);
  }
  const [command, ...args] = positional;
  return { command, args, flags, json };
}

let jsonOut = false;

function fail(error) {
  const code = error.code || 'internal';
  console.error(JSON.stringify({ error: code, hint: error.hint || String(error) }));
  process.exit(code === 'usage' ? 2 : code === 'auth' ? 3 : code === 'notfound' ? 4 : 5);
}

async function main() {
  const request = parse(process.argv.slice(2));
  jsonOut = request.json;
  const handler = COMMANDS[request.command];
  if (!handler) {
    throw new CliError('usage',
      `未知命令 ${request.command || '(空)'}；可用：${Object.keys(COMMANDS).join(' ')}`);
  }
  emit(await handler(request));
}

try {
  await main();
} catch (error) {
  fail(error);
}
