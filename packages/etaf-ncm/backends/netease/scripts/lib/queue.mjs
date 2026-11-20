// queue.mjs —— 队列模型：queue.json（歌曲列表）+ queue.m3u8（mpv 播放列表）+ urls.txt（id → 直链）
//
// 三份文件互为索引。mpv 开了 shuffle 后 `playlist-pos` 指的是它自己打乱过的顺序，
// 不能拿来索引 queue.json（实测会报错歌），所以每首歌在两个列表里都留同一个身份：
// m3u 的 #EXTINF 标题写成 `[#<id>] <歌手> - <歌名>`，queue.json 里存 id。
// 旧队列没有 [#id] 标题时，再按 URL、按「歌手 - 歌名」兜底。
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const ID_TITLE = /^\[#(\d+)\]\s*/;

export const queueFiles = (directory) => ({
  queue: join(directory, 'queue.json'),
  m3u: join(directory, 'queue.m3u8'),
  urls: join(directory, 'urls.txt'),
  urlsAt: join(directory, 'urls_at'),
});

export const stripQuery = (url) => String(url || '').split('?')[0];

export async function readQueue(directory) {
  try {
    const data = JSON.parse(await readFile(queueFiles(directory).queue, 'utf8'));
    return { ...data, songs: Array.isArray(data.songs) ? data.songs : [] };
  } catch {
    return { songs: [] };
  }
}

// urls.txt 每行 `<id>\t<档位>\t<地址>`；播放地址是限时签名，过期就换新的。
export async function readUrls(directory) {
  const urls = new Map();
  try {
    for (const line of (await readFile(queueFiles(directory).urls, 'utf8')).split('\n')) {
      const [id, level, url] = line.split('\t');
      if (id && url) urls.set(String(id), { level: level || '', url });
    }
  } catch {
    // 还没有队列：空表就是答案
  }
  return urls;
}

export function idOfEntry(entry, urls) {  const tagged = ID_TITLE.exec(entry.title || '');
  if (tagged) return tagged[1];
  const path = stripQuery(entry.path || entry.filename);
  if (!path) return null;
  for (const [id, value] of urls) {
    if (stripQuery(value.url) === path) return id;
  }
  return null;
}

// entry 是 mpv 给的条目：status 用 {title, path}，playlist 用 {title, filename}。
export function songOfEntry(entry, queue, urls) {
  const id = idOfEntry(entry, urls);
  const song = id ? queue.songs.find((item) => String(item.id) === String(id)) : null;
  if (song) return song;
  const title = String(entry.title || '').replace(ID_TITLE, '').trim();
  return queue.songs.find((item) => title && title === `${item.artist || ''} - ${item.name || ''}`) || null;
}

// 歌在 mpv 队列里的序号（1 起）；找不到给 nil。
export function queueIndexOf(id, entries, urls) {
  const target = String(id);
  const tagged = entries.find((entry) => idOfEntry(entry, urls) === target);
  return tagged ? tagged.index : null;
}

export function m3uOf(tracks) {
  const lines = ['#EXTM3U'];
  for (const { song, url } of tracks) {
    const seconds = Math.floor((song.ms || 0) / 1000);
    lines.push(`#EXTINF:${seconds},[#${song.id}] ${song.artist || ''} - ${song.name || ''}`);
    lines.push(url);
  }
  return `${lines.join('\n')}\n`;
}

export function queueDocument(tracks, { skipped = 0, start } = {}) {
  return {
    songs: tracks.map(({ song, level }) => ({ ...song, level: level || '' })),
    skipped,
    as_of: new Date().toISOString(),
    ...(start ? { start } : {}),
  };
}

export async function writeQueue(directory, tracks, options = {}) {
  await mkdir(directory, { recursive: true });
  const queue = queueDocument(tracks, options);
  const files = queueFiles(directory);
  await writeFile(files.queue, JSON.stringify(queue, null, 1), 'utf8');
  await writeFile(files.m3u, m3uOf(tracks), 'utf8');
  // urls.txt 必须跟队列一起落盘：status 靠它把 mpv 在放的条目对回歌曲，
  // 保活进程靠它知道哪些地址需要换。
  await writeUrls(directory, new Map(tracks.map((track) => [String(track.song.id), track])));
  await writeFile(files.urlsAt, String(Math.floor(Date.now() / 1000)), 'utf8');
  return queue;
}

// urls.txt 是「id → 当前有效直链」的唯一真源：保活换地址、追加歌曲都改它。
export async function writeUrls(directory, urls) {
  await mkdir(directory, { recursive: true });
  const lines = [...urls].map(([id, value]) => `${id}\t${value.level || ''}\t${value.url}`);
  await writeFile(queueFiles(directory).urls, `${lines.join('\n')}\n`, 'utf8');
}
