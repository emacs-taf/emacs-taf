#!/usr/bin/env node
// refresh-urls.mjs —— 队列地址保活
//
// 网易云的播放直链是限时签名 URL：实测取出来约 5 分钟就 403（路径里的时间戳 +
// vuutv/authSecret 签名，服务端一核，过期就拒绝）。长队列预取一批地址，放到后半段
// 会集体失效，听感是「歌还在放、就是没声音」。
//
// 由编排层在开播后拉起（一次只跑一个）。每 90 秒看一次：
//   这批地址取出来多久了（urls_at）× mpv 播到第几首
// 一到 4 分钟，就把「当前这首之后还没播的」批量重取，原地换掉 m3u 里对应的行。
// mpv 是按需读取下一首的，所以换 URL 不影响正在放的那首。
// 队列被换掉 / 停止 / mpv 退出，脚本自己收工。
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  m3uOf, queueFiles, readQueue, readUrls, songOfEntry, writeUrls,
} from './lib/queue.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const API = join(HERE, 'netease-api.mjs');
const MPVCTL = join(HERE, 'mpv-ctl.mjs');
const STATE_DIR =
  process.env.NETEASE_MUSIC_STATE_DIR ||
  join(process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state'), 'netease-music');
const STALE_AFTER = 240;    // 秒：地址取出来 4 分钟就换
const INTERVAL = 90;        // 秒：检查间隔
const URL_CHUNK = 200;

const log = (message) => console.log(`${new Date().toTimeString().slice(0, 8)} ${message}`);

function run(script, args, { cookie } = {}) {
  const env = { ...process.env };
  if (cookie) env.NETEASE_COOKIE = cookie;
  return new Promise((resolve, reject) => {
    // windowsHide：本进程由 netease-cli.mjs 以 detached 起，自己没有 console；
    // 不加这一项，每次 spawn 的 node 子进程都会新开一个黑色 console 窗口闪一下。
    execFile(process.execPath, [script, ...args],
      { env, timeout: 60_000, maxBuffer: 8 << 20, windowsHide: true },
      (error, stdout, stderr) => {
        if (error) {
          const line = String(stderr).trim().split('\n').pop();
          let report = null;
          try {
            report = JSON.parse(line);
          } catch {
            report = null;
          }
          reject(new Error(report?.hint || line || String(error)));
          return;
        }
        try {
          resolve(JSON.parse(String(stdout).trim().split('\n').pop()));
        } catch {
          reject(new Error('后端没有返回 JSON：' + String(stdout).slice(0, 200)));
        }
      });
  });
}

const mpv = (args) => run(MPVCTL, args);
const api = (args, cookie) => run(API, args, { cookie });

async function cookie() {
  if (process.env.NETEASE_COOKIE) return process.env.NETEASE_COOKIE;
  try {
    return JSON.parse(await readFile(join(STATE_DIR, 'config.json'), 'utf8')).cookie || '';
  } catch {
    return '';
  }
}

async function quality() {
  try {
    return JSON.parse(await readFile(join(STATE_DIR, 'config.json'), 'utf8')).quality || 'lossless';
  } catch {
    return 'lossless';
  }
}

async function agedSeconds() {
  try {
    const stamp = Number((await readFile(queueFiles(STATE_DIR).urlsAt, 'utf8')).trim());
    return Math.floor(Date.now() / 1000) - stamp;
  } catch {
    return 0;
  }
}

async function refresh() {
  if ((await agedSeconds()) < STALE_AFTER) return false;
  const [status, queue, urls] = await Promise.all([
    mpv(['status']), readQueue(STATE_DIR), readUrls(STATE_DIR),
  ]);
  if (status.idle || !status.count) return false;
  const current = songOfEntry(status, queue, urls);
  // 当前这首正在放，地址还能用；只换它之后还没播到的。
  const songs = queue.songs;
  const from = current ? songs.findIndex((song) => String(song.id) === String(current.id)) + 1 : 0;
  const pending = songs.slice(from).map((song) => String(song.id));
  if (!pending.length) return false;
  const level = await quality();
  const key = await cookie();
  let changed = 0;
  for (let i = 0; i < pending.length; i += URL_CHUNK) {
    // eslint-disable-next-line no-await-in-loop
    const { items } = await api(['url', ...pending.slice(i, i + URL_CHUNK), '--level', level], key);
    for (const item of items || []) {
      if (!item.url) continue;
      urls.set(String(item.id), { level: item.level || '', url: item.url });
      changed += 1;
    }
  }
  if (!changed) return false;
  await writeUrls(STATE_DIR, urls);
  const tracks = songs.map((song) => ({ song, ...urls.get(String(song.id)) })).filter((track) => track.url);
  await mpv(['reload', queueFiles(STATE_DIR).m3u]);
  log(`换了 ${changed} 个地址（第 ${from + 1} 首之后）`);
  return true;
}

// 队列换了人：mpv 的队列和 queue.json 对不上时就该收工，让新的那次播放重启保活。
async function stillMine() {
  const [playlist, queue] = await Promise.all([mpv(['playlist']), readQueue(STATE_DIR)]);
  return playlist.count > 0 && queue.songs.length > 0 && playlist.count === queue.songs.length;
}

async function main() {
  // `--once` 跑一轮就返回：手工验证「地址到底换没换」时用。
  const once = process.argv.includes('--once');
  for (;;) {
    try {
      if (!await stillMine()) {
        log('队列已经换人或空着，保活收工');
        return;
      }
      await refresh();
    } catch (error) {
      log(`这轮没刷新：${error.message}`);
    }
    if (once) return;
    await new Promise((resolve) => setTimeout(resolve, INTERVAL * 1000));
  }
}

await main();
