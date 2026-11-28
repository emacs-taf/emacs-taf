#!/usr/bin/env node
// mpv-ctl — 后台 mpv 的生命周期与 IPC 控制（网易云播放的「播放器层」）
//
// 为什么这样：mpv 常驻（--idle=yes）+ unix socket 上跑 JSON IPC，
// 所以播放/暂停/切歌/音量都是毫秒级命令，状态（时间、进度、曲名）也是真值，
// 不再靠截屏看进度条猜。mpv 自己会接着放歌单，不需要守护进程。
//
// 输出：JSON（内部原语）；退出码 0 成功 / 2 用法 / 3 缺依赖 / 5 执行失败
// 用法：
//   mpv-ctl play <m3u|url> [--title T] [--index N]   建队列并开播
//   mpv-ctl reload <m3u>                             按 m3u 新地址接回整条队列（当前那首不动）
//   mpv-ctl attach <m3u> --at N                      整队接手：当前那首继续放，其余按 m3u 补齐（N 为 0 基序号）
//   mpv-ctl status                                   当前状态（真值）
//   mpv-ctl pause|resume|toggle|next|prev|stop
//   mpv-ctl volume [0-130] | seek <秒|+n|-n> | shuffle on|off | repeat off|list|single (on=list)
//   mpv-ctl append <m3u|url> | remove <1-based index> | clear
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';

const DIR = process.env.NETEASE_MPV_DIR || process.env.NETEASE_MUSIC_STATE_DIR
  || path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'netease-music');
// mpv 在 Windows 上只能开命名管道（没有 unix socket）。管道名跟着状态目录走，
// 同一个状态目录永远控制同一个播放器；Linux/macOS 仍是目录里的 socket 文件。
// 名字要先归一化：Emacs 传来的是 `c:/…`、CLI 自己算的是 `C:\…`，同一目录的两种
// 写法哈希出两个管道名，就会各起一个 mpv，播放和状态分别落在两个进程上。
const CANONICAL = process.platform === 'win32' ? path.resolve(DIR).toLowerCase() : path.resolve(DIR);
const SOCK = process.platform === 'win32'
  ? `\\\\.\\pipe\\netease-ncm-${createHash('sha1').update(CANONICAL).digest('hex').slice(0, 12)}`
  : path.join(DIR, 'mpv.sock');
const START_LOCK = path.join(DIR, 'mpv.start.lock');
const LOG = path.join(DIR, 'mpv.log');
fs.mkdirSync(DIR, { recursive: true });

const die = (code, hint, rc) => {
  console.error(JSON.stringify({ error: code, hint }));
  process.exit(rc);
};

function connect(timeoutMs = 1500) {
  return new Promise((resolve) => {
    const s = net.connect(SOCK);
    const t = setTimeout(() => {
      s.destroy();
      resolve(null);
    }, timeoutMs);
    s.once('connect', () => {
      clearTimeout(t);
      resolve(s);
    });
    s.once('error', () => {
      clearTimeout(t);
      s.destroy();
      resolve(null);
    });
  });
}

function makeClient(sock) {
  let buf = '';
  let id = 0;
  const pending = new Map();
  sock.on('data', (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.request_id && pending.has(msg.request_id)) {
        const { resolve } = pending.get(msg.request_id);
        pending.delete(msg.request_id);
        resolve(msg.error === 'success' || msg.error === undefined ? msg.data : { __error: msg.error });
      }
    }
  });
  const send = (command, timeoutMs = 4000) =>
    new Promise((resolve) => {
      const rid = ++id;
      const t = setTimeout(() => {
        pending.delete(rid);
        resolve({ __error: 'timeout' });
      }, timeoutMs);
      pending.set(rid, {
        resolve: (v) => {
          clearTimeout(t);
          resolve(v);
        },
      });
      sock.write(JSON.stringify({ command, request_id: rid }) + '\n');
    });
  return { send, close: () => sock.end() };
}

async function ensureMpv() {
  let sock = await connect(300);
  if (sock) return makeClient(sock);
  // 所有调用方都可能同时发现「没有守护进程」。mpv 遇到已存在的 socket 会先删
  // 再绑，两个调用各起一个就会留下一个谁都控不到的孤儿播放器（实测两个 mpv
  // 同秒出生、播放走一个、stop 打另一个）。用目录锁把启动串行化：锁在手上
  // 的那个负责起进程，其余等它的 socket。
  const deadline = Date.now() + 10000;
  if (!acquireStartLock()) {
    while (Date.now() < deadline) {
      await sleep(200);
      sock = await connect(300);
      if (sock) return makeClient(sock);
    }
    die('deps', `mpv 没起来（等 ${START_LOCK} 超时；看日志 ${LOG}）`, 3);
  }
  try {
    // 拿锁之前可能已被别人起好，先再连一次。
    sock = await connect(300);
    if (sock) return makeClient(sock);
    const out = fs.openSync(LOG, 'a');
    const child = spawn(
      'mpv',
      ['--idle=yes', '--no-video', '--force-window=no', '--audio-display=no', '--no-terminal', '--prefetch-playlist=yes', `--input-ipc-server=${SOCK}`, '--volume=70'],
      { detached: true, stdio: ['ignore', out, out] },
    );
    child.unref();
    while (Date.now() < deadline) {
      await sleep(250);
      sock = await connect(300);
      if (sock) return makeClient(sock);
    }
  } finally {
    fs.rmSync(START_LOCK, { recursive: true, force: true });
  }
  die('deps', `mpv 没起来（日志 ${LOG}）：确认 mpv 已安装并在 PATH 上`, 3);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// 起过 mpv 的进程崩溃时锁会留下；只信任新鲜锁（15 秒内），旧锁清掉重抢。
function acquireStartLock() {
  for (;;) {
    try {
      fs.mkdirSync(START_LOCK);
      return true;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        if (Date.now() - fs.statSync(START_LOCK).mtimeMs > 15000) {
          fs.rmSync(START_LOCK, { recursive: true, force: true });
          continue;
        }
      } catch { continue; }
      return false;
    }
  }
}

const argv = process.argv.slice(2);
const CMD = argv[0];
const opts = {};
const pos = [];
for (let i = 1; i < argv.length; i++) {
  if (argv[i] === '--title') opts.title = argv[++i];
  else if (argv[i] === '--index') opts.index = +argv[++i];
  else if (argv[i] === '--at') opts.at = +argv[++i];
  else pos.push(argv[i]);
}

const GOOD = {
  pause: ['set_property', 'pause', true],
  resume: ['set_property', 'pause', false],
};
async function main() {
  const repeatMode = (pos[0] || 'on') === 'on' ? 'list' : pos[0];
  if (CMD === 'repeat' && (pos.length > 1 || !['off', 'list', 'single'].includes(repeatMode))) {
    die('usage', '用法：repeat off|list|single（on = list）', 2);
  }
  if (CMD === 'remove' && (pos.length !== 1 || !/^\d+$/.test(pos[0]) || !Number.isSafeInteger(+pos[0]) || +pos[0] < 1)) {
    die('usage', '用法：remove <队列序号，从 1 开始>', 2);
  }
  if (CMD === 'clear' && pos.length) die('usage', '用法：clear', 2);
  if (CMD === 'play' && opts.index !== undefined && (!Number.isSafeInteger(opts.index) || opts.index < 0)) {
    die('usage', '--index 需要从 0 开始的序号', 2);
  }
  const c = await ensureMpv();
  const get = (p) => c.send(['get_property', p]);
  const checked = async (command) => {
    const result = await c.send(command);
    if (result && result.__error) die('external', `mpv 报错：${result.__error}`, 5);
    return result;
  };
  let out = { command: CMD };
  switch (CMD) {
    case 'play': {
      const target = pos[0];
      if (!target) die('usage', '用法：mpv-ctl play <m3u|url> [--title T] [--index N]', 2);
      const isUrl = /^https?:/.test(target);
      const isList = /\.(m3u8?|pls)$/i.test(target);
      const cmd = isUrl || !isList ? ['loadfile', target, 'replace'] : ['loadlist', target, 'replace'];
      if (isUrl && opts.title) cmd.splice(2, 0, `--force-media-title=${opts.title}`);
      // Pause first: a load starts the first entry immediately, so an indexed
      // start (or any later adjustment) would leak a fraction of the wrong
      // song as a click.  Silence the swap, position, then resume.
      await checked(['set_property', 'pause', true]);
      const r = await c.send(cmd);
      if (r && r.__error) die('external', `mpv 拒绝播放：${r.__error}`, 5);
      if (opts.index !== undefined) await checked(['set_property', 'playlist-pos', opts.index]);
      await checked(['set_property', 'pause', false]);
      // 预取下一首：mpv 在当前曲目结束前先把下一条流建连并预读，切歌不再从零等缓冲。
      // 已在跑的老 daemon 没带启动参数，这里补上；个别 mpv 版本没这个属性也不影响播放。
      await c.send(['set_property', 'prefetch-playlist', true]);
      out.playing = true;
      break;
    }
    case 'append': {
      const target = pos[0];
      if (!target) die('usage', '用法：mpv-ctl append <m3u|url>', 2);
      const isUrl = /^https?:/.test(target);
      const r = await c.send(isUrl ? ['loadfile', target, 'append'] : ['loadlist', target, 'append']);
      if (r && r.__error) die('external', `mpv 拒绝追加：${r.__error}`, 5);
      out.count = await get('playlist-count');
      break;
    }
    case 'pause':
    case 'resume':
    case 'toggle': {
      let cmd = GOOD[CMD];
      if (CMD === 'toggle') cmd = ['set_property', 'pause', !(await c.send(['get_property', 'pause']))];
      const r = await c.send(cmd);
      if (r && r.__error) die('external', `mpv 报错：${r.__error}`, 5);
      out.paused = await get('pause');
      break;
    }
    case 'next':
    case 'prev': {
      const r = await c.send([CMD === 'next' ? 'playlist-next' : 'playlist-prev', 'force']);
      if (r && r.__error) die('external', `mpv 报错：${r.__error}`, 5);
      break;
    }
    case 'stop':
    case 'clear': {
      await checked(['stop']);
      await checked(['playlist-clear']);
      out.stopped = true;
      break;
    }
    case 'attach': {
      // 整队接手：先用 m3u 的顺序建好「当前之前 + 当前之后」，接在当前那首两侧，
      // 正在放的不用重开。「起播先放选中那首、队列随后补齐」的路径用它。
      const target = pos[0];
      if (!target || !Number.isInteger(opts.at) || opts.at < 0) {
        die('usage', '用法：mpv-ctl attach <m3u> --at N（N 为 m3u 行内 0 基序号）', 2);
      }
      const [count, index] = await Promise.all([get('playlist-count'), get('playlist-pos')]);
      if (!count || index < 0) { out.attached = false; out.reason = 'idle'; break; }
      const entries = [];
      let lastTitle = '';
      for (const line of fs.readFileSync(target, 'utf8').split('\n')) {
        if (line.startsWith('#EXTINF')) lastTitle = line;
        else if (line && !line.startsWith('#')) entries.push({ title: lastTitle, url: line });
      }
      if (!entries.length || opts.at >= entries.length) {
        die('usage', `--at ${opts.at} 超出 m3u 的 ${entries.length} 行`, 2);
      }
      const before = entries.slice(0, opts.at);
      const after = entries.slice(opts.at + 1);
      const tmp = `${target}.attach.${process.pid}`;
      fs.writeFileSync(tmp, '#EXTM3U\n'
        + [...before, ...after].map((e) => `${e.title}\n${e.url}\n`).join(''));
      await checked(['playlist-clear']);
      const r = await c.send(['loadlist', tmp, 'append']);
      if (r && r.__error) { fs.rmSync(tmp, { force: true }); die('external', `mpv 拒绝接管队列：${r.__error}`, 5); }
      for (let i = 0; i < before.length; i += 1) {
        // eslint-disable-next-line no-await-in-loop
        await checked(['playlist-move', 1 + i, i]);
      }
      fs.rmSync(tmp, { force: true });
      out.attached = true;
      out.at = opts.at + 1;
      out.count = before.length + 1 + after.length;
      out.playlist = await get('playlist-count');
      break;
    }
    case 'reload': {
      const target = pos[0];
      if (!target) die('usage', '用法：mpv-ctl reload <m3u>', 2);
      const [count, index, playlist, shuffle] = await Promise.all([
        get('playlist-count'), get('playlist-pos'), get('playlist'), get('shuffle'),
      ]);
      if (!count || index < 0 || !Array.isArray(playlist)) {
        out.reloaded = false;
        out.reason = 'idle';
        break;
      }
      // m3u 的 [#id] 标题 → 刷新后的地址；整条队列换上新地址接回去，当前那首不动。
      // 不用 loadlist replace：那会把正在放的那首从头重放；playlist-clear 会保留它。
      // shuffle 打开时按 mpv 自己的队列顺序切片，不按 m3u 文件顺序。
      const byId = new Map();
      let lastTitle = '';
      for (const line of fs.readFileSync(target, 'utf8').split('\n')) {
        if (line.startsWith('#EXTINF')) lastTitle = line;
        else if (line && !line.startsWith('#')) {
          const m = lastTitle.match(/\[#(\d+)\]/);
          if (m) byId.set(m[1], line);
        }
      }
      const refreshed = (entry) => {
        const m = (entry.title || '').match(/\[#(\d+)\]/);
        const url = (m && byId.get(m[1])) || entry.filename;
        return { title: entry.title || '', url };
      };
      // 「当前之前」的条目也不能丢：队列面板要看到整条列表。先原样接回，
      // 再接「当前之后」；最后把前缀移到当前之前，播放全程不停。
      const before = playlist.slice(0, index).map(refreshed);
      const remaining = playlist.slice(index + 1).map(refreshed);
      const tmp = `${target}.reload.${process.pid}`;
      fs.writeFileSync(tmp, '#EXTM3U\n'
        + [...before, ...remaining].map((e) => `#EXTINF:-1,${e.title}\n${e.url}\n`).join(''));
      await checked(['playlist-clear']);
      if (before.length + remaining.length) {
        const r = await c.send(['loadlist', tmp, 'append']);
        if (r && r.__error) { fs.rmSync(tmp, { force: true }); die('external', `mpv 拒绝接回队列：${r.__error}`, 5); }
        for (let i = 0; i < before.length; i += 1) {
          // 前缀从当前之后逐条往左挪：p1 p2 p3 current → p1 current p2 p3 → …
          // eslint-disable-next-line no-await-in-loop
          await checked(['playlist-move', 1 + i, i]);
        }
      }
      fs.rmSync(tmp, { force: true });
      out.reloaded = true;
      out.shuffle = !!shuffle;
      out.kept = 1;
      out.appended = before.length + remaining.length;
      out.prefix = before.length;
      break;
    }
    case 'remove': {
      const index = +pos[0] - 1;
      const [count, current, paused] = await Promise.all([get('playlist-count'), get('playlist-pos'), get('pause')]);
      if (!Number.isInteger(count) || index >= count) die('notfound', `队列里没有第 ${pos[0]} 首`, 4);
      if (index === current) {
        if (count === 1) {
          await checked(['stop']);
          await checked(['playlist-clear']);
        } else {
          // 先选下一首，末尾则选上一首；不受循环模式影响，并保留暂停状态。
          await checked(['set_property', 'playlist-pos', index + 1 < count ? index + 1 : index - 1]);
          await checked(['playlist-remove', index]);
          await checked(['set_property', 'pause', paused === true]);
        }
      } else await checked(['playlist-remove', index]);
      out.removed = index + 1;
      out.count = await get('playlist-count');
      break;
    }
    case 'seek': {
      const v = pos[0] ?? '0';
      const r = await c.send(['seek', v, 'relative']);
      if (r && r.__error) die('external', `mpv 报错：${r.__error}`, 5);
      break;
    }
    case 'volume': {
      if (pos[0]) {
        await c.send(['set_property', 'volume', Number(pos[0])]);
      }
      out.volume = await get('volume');
      break;
    }
    case 'shuffle': {
      const on = (pos[0] || 'on') !== 'off';
      await checked(['set_property', 'shuffle', on]);
      out.shuffle = on;
      break;
    }
    case 'repeat': {
      // 每次同时设置两个属性，避免从 single 切换后仍单曲循环。
      await checked(['set_property', 'loop-file', repeatMode === 'single' ? 'inf' : 'no']);
      await checked(['set_property', 'loop-playlist', repeatMode === 'list' ? 'inf' : 'no']);
      out.repeat = repeatMode === 'list'; // 保留原字段含义：是否整列循环。
      out.repeat_mode = repeatMode;
      break;
    }
    case 'playlist': {
      const [ppos, list] = await Promise.all([get('playlist-pos'), get('playlist')]);
      const entries = Array.isArray(list) ? list : [];
      out = {
        command: 'playlist',
        pos: Number.isInteger(ppos) ? ppos : -1,
        count: entries.length,
        entries: entries.map((e, i) => ({
          index: i + 1,
          title: typeof e.title === 'string' ? e.title : '',
          filename: typeof e.filename === 'string' ? e.filename : '',
          duration: Math.round(e.duration || 0),
        })),
      };
      break;
    }
    case 'jump': {
      const n = Number(pos[0]);
      if (!Number.isInteger(n) || n < 1) die('usage', '用法：mpv-ctl jump <队列第几首，从 1 开始>', 2);
      const count = await get('playlist-count');
      if (!Number.isFinite(count) || count < 1) die('notfound', '队列是空的（先 play/daily/liked/artist/album 建队列）', 4);
      if (n > count) die('notfound', `队列只有 ${count} 首，没有第 ${n} 首`, 4);
      const r = await c.send(['set_property', 'playlist-pos', n - 1]);
      if (r && r.__error) die('external', `mpv 报错：${r.__error}`, 5);
      await c.send(['set_property', 'pause', false]);
      out = { command: 'jump', jumped: n, count };
      break;
    }
    case 'status': {
      const [idle, paused, tpos, dur, vol, ppos, pcount, title, path_, loop, fileLoop, shuffle] = await Promise.all([
        get('idle-active'),
        get('pause'),
        get('time-pos'),
        get('duration'),
        get('volume'),
        get('playlist-pos'),
        get('playlist-count'),
        get('media-title'),
        get('path'),
        get('loop-playlist'),
        get('loop-file'),
        get('shuffle'),
      ]);
      out = {
        command: 'status',
        idle: idle === true,
        playing: idle === false && paused === false,
        paused: paused === true,
        pos: Number.isFinite(ppos) ? ppos : -1,
        count: Number.isFinite(pcount) ? pcount : 0,
        elapsed: Number.isFinite(tpos) ? Math.round(tpos) : null,
        duration: Number.isFinite(dur) ? Math.round(dur) : null,
        volume: Number.isFinite(vol) ? vol : null,
        title: typeof title === 'string' ? title : '',
        path: typeof path_ === 'string' ? path_ : '',
        repeat: loop === 'inf',
        repeat_mode: fileLoop === 'inf' ? 'single' : loop === 'inf' ? 'list' : 'off',
        shuffle: shuffle === true,
      };
      break;
    }
    default:
      die('usage', `未知命令 ${CMD || '(空)'}：play/append/reload/attach/status/playlist/jump/remove/clear/pause/resume/toggle/next/prev/stop/volume/seek/shuffle/repeat`, 2);
  }
  console.log(JSON.stringify(out));
  c.close();
}
main().catch((e) => die('internal', String(e && e.message ? e.message : e), 5));
