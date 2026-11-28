#!/usr/bin/env node
// netease-api — 网易云接口客户端（自包含，零 npm 依赖）
//
// 原理：网页端所有请求都走 /weapi/<路径>，参数用「AES-128-CBC 两次 + RSA 加密密钥」包装，
// 这套加密是固定常量（见下方 NONCE/IV/MODULUS），所以不需要跑任何 API 服务，直接调。
// 登录态就是 MUSIC_U cookie，由调用方从环境变量 NETEASE_COOKIE 传进来。
//
// 输出：统一 JSON 到 stdout（内部原语，不给人读）；出错时 status 非 0 + {"error":..,"hint":..}
// 用法：node netease-api.mjs <命令> [参数]
//   列表命令支持 --offset N（默认 0）：跳过 N 条；count 是本页条数，total 是分页前总数
//   search <关键词> [--limit 20]        搜歌
//   song <关键词|id>                    解析成一首歌（关键词取最匹配一条）
//   play-ids <id,id,...> [--start N]    批量详情（只取数）；start 从 1 开始，默认 1
//   cover <关键词|id> [--download PATH] [--force]  封面 JSON；可下载图片（最多 10 MB）
//   url <id...> [--level lossless]      取播放地址（有 VIP 就取无损）
//   daily [--limit 40]                  每日推荐
//   playlist <id|链接> [--limit 500]    歌单全部歌曲
//   artist <关键词|id> [--limit 50]     歌手热门 50 首
//   album <关键词|id> [--limit 200]     专辑整张
//   albums <歌手|id> [--limit 60]       歌手的专辑列表（含搜索索引里没有的老专辑）
//   playlists <关键词> [--limit 20]     搜歌单（别人做的）
//   charts [--limit 100]                排行榜列表
//   chart <名字|id> [--limit 500]       放某个榜单
//   myalbums / myartists [--limit 60]   我收藏的专辑 / 歌手
//   fm [--limit 12]                     私人 FM
//   recent [--limit 30]                 最近播放（一周）
//   podcasts [--recommend] [--limit 50] 我的播客订阅（或推荐）
//   podcast <名字|id> [--limit 3]       某播客最新 N 期
//   episode <节目id>                    某一期节目
//   liked [--limit 1000]                我喜欢的音乐（按收藏时间由近到远）
//   liked-ids                          我喜欢的歌曲 ID 全表（只读）
//   dislike <id>                       私人 FM 垃圾桶（fm/trash）
//   like <id> [--unlike]                喜欢/取消喜欢
//   lyric <id> [--trans]                歌词（--trans 带翻译）
//   myplaylists [--limit 100]           我的歌单（含「我喜欢的音乐」）
//   session                             登录态与账号信息
//   uid                                 当前账号 uid（未登录报错）
//   qr-start                            生成扫码登录的二维码内容与 key
//   qr-poll <key> [--timeout 120]       轮询扫码结果，成功时输出 cookie
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

const NONCE = '0CoJUm6Qyw8W8jud';
const IV = '0102030405060708';
const PUBKEY = '010001';
const MODULUS =
  '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const COOKIE = process.env.NETEASE_COOKIE || '';
// 同一次进程里的请求共用一份 cookie。登录、二次放号确认和安全验证都要求
// 同一个会话：服务端把挑战绑在本次请求下发的 cookie 上，换一份就认不出来。
let jar = COOKIE;

function aesEncrypt(text, key) {
  const c = crypto.createCipheriv('aes-128-cbc', Buffer.from(key), Buffer.from(IV));
  return Buffer.concat([c.update(text, 'utf8'), c.final()]).toString('base64');
}
function modPow(b, e, m) {
  let r = 1n;
  b %= m;
  while (e > 0n) {
    if (e & 1n) r = (r * b) % m;
    b = (b * b) % m;
    e >>= 1n;
  }
  return r;
}
function rsaEncrypt(text) {
  const hex = Buffer.from(text).reverse().toString('hex');
  return modPow(BigInt('0x' + hex), BigInt('0x' + PUBKEY), BigInt('0x' + MODULUS))
    .toString(16)
    .padStart(256, '0');
}
function cookieValue(name) {
  const m = (jar || '').match(new RegExp('(?:^|;\\s*)' + name + '=([^;]*)'));
  return m ? m[1] : '';
}

function weapi(data) {
  const secret = crypto.randomBytes(8).toString('hex').slice(0, 16);
  const plain = JSON.stringify({ ...data, csrf_token: cookieValue('__csrf') });
  return {
    params: aesEncrypt(aesEncrypt(plain, NONCE), secret),
    encSecKey: rsaEncrypt(secret),
  };
}

class ApiError extends Error {
  constructor(code, hint) {
    super(hint);
    this.code = code;
    this.hint = hint;
  }
}

// 登录态失效的统一提示：消费者（app、巡检）会原样透出这行，所以写成人能直接照做的命令。
const AUTH_HINT = '登录已过期或未登录：跑 netease-music.sh login --sms <手机号> 重新登录（收短信验证码，比扫码稳；也可 login 扫码）';

// `fetch failed` 本身不含原因：node 把底层错误放在 cause 里（read ECONNRESET 之类），
// 不带上它，用户只能看到「连不上」，分不清是网络被重置、DNS 挂了还是代理没开。
function networkReason(e) {
  const cause = e.cause && (e.cause.message || e.cause.code);
  return e.message + (cause && !e.message.includes(cause) ? `（${cause}）` : '');
}

async function plainPost(path, data) {
  let res;
  try {
    res = await fetch('https://music.163.com/' + path, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Referer: 'https://music.163.com/',
        'User-Agent': UA,
        ...(jar ? { Cookie: jar } : {}),
      },
      body: new URLSearchParams(data).toString(),
    });
  } catch (e) {
    throw new ApiError('external', '连不上 music.163.com：' + networkReason(e));
  }
  lastSetCookie = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
  absorbCookies(lastSetCookie);
  const text = await res.text();
  if (!text) throw new ApiError('external', `接口返回空（HTTP ${res.status}）`);
  return JSON.parse(text);
}

let lastSetCookie = [];

// 把响应里的 cookie 并进会话：同名的取新的，其余保留
function absorbCookies(setCookies) {
  if (!setCookies || !setCookies.length) return;
  if (setCookies.some((c) => c.startsWith('MUSIC_U='))) loggedIn = true;
  const kept = jar ? jar.split('; ').filter(Boolean) : [];
  jar = jarToCookie([...kept, ...setCookies]);
}

// 登录会分多步下发 Set-Cookie，同名会有多条；按名字去重（取最后一条），避免服务端看到重复 cookie
function jarToCookie(cookies) {
  const map = new Map();
  for (const c of cookies) {
    const kv = c.split(';')[0];
    const i = kv.indexOf('=');
    if (i > 0) map.set(kv.slice(0, i).trim(), kv.slice(i + 1));
  }
  return [...map].map(([k, v]) => `${k}=${v}`).join('; ');
}
async function weapiPost(path, data = {}) {
  const body = new URLSearchParams(weapi(data)).toString();
  let res;
  try {
    res = await fetch('https://music.163.com/weapi/' + path + '?csrf_token=' + encodeURIComponent(cookieValue('__csrf')), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Referer: 'https://music.163.com/',
        'User-Agent': UA,
        ...(jar ? { Cookie: jar } : {}),
      },
      body,
    });
  } catch (e) {
    throw new ApiError('external', '连不上 music.163.com：' + networkReason(e));
  }
  lastSetCookie = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
  absorbCookies(lastSetCookie);
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new ApiError('external', `接口返回的不是 JSON（HTTP ${res.status}）：${text.slice(0, 120)}`);
  }
  return json;
}

const song = (s) => ({
  id: s.id,
  name: s.name,
  artist: (s.ar || s.artists || []).map((a) => a.name).join(' / '),
  album: (s.al || s.album || {}).name || '',
  ms: s.dt || s.duration || 0,
  vip: s.fee === 1 || s.fee === 4,
  cover: String(s.al?.picUrl || s.album?.picUrl || s.picUrl || ''),
  // 没有明确布尔值就不猜；调用方可用 liked-ids 一次取全表后按 id 补齐。
  ...(typeof s.liked === 'boolean' ? { liked: s.liked } : {}),
});
const num = (v) => (Number.isFinite(+v) ? +v : 0);

function songId(value) {
  if (!/^\d+$/.test(value || '') || !Number.isSafeInteger(+value) || +value < 1) {
    throw new ApiError('usage', '歌曲 id 需要正整数');
  }
  return +value;
}

async function cmdPlayIds(args, o) {
  if (args.length !== 1) throw new ApiError('usage', '用法：play-ids <id,id,...> [--start N]');
  const ids = args[0].split(',').map(songId);
  if (!Number.isSafeInteger(o.start) || o.start < 1 || o.start > ids.length) {
    throw new ApiError('usage', '--start 需要输入列表内的序号（从 1 开始）');
  }
  const songs = [];
  for (let i = 0; i < ids.length; i += 200) songs.push(...await songsByIds(ids.slice(i, i + 200)));
  if (songs.length !== ids.length) throw new ApiError('notfound', '输入列表中有歌曲详情缺失，队列未替换');
  return { count: songs.length, total: ids.length, start: o.start, songs };
}

// 搜索必须走明文接口：weapi 版的 cloudsearch 现在对匿名请求回空体（不报错，就空）
async function cmdSearch(kw, o) {
  const j = await plainPost('api/search/get/web', { s: kw, type: 1, limit: o.limit, offset: o.offset, total: true });
  const list = (j.result && j.result.songs) || [];
  return { kw, count: list.length, total: j.result?.songCount ?? list.length, songs: list.map(song) };
}
async function cmdSong(kw) {
  if (/^\d+$/.test(kw)) {
    const j = await weapiPost('v3/song/detail', { c: JSON.stringify([{ id: +kw }]) });
    const s = (j.songs || []).find((s) => +s.id === +kw);
    if (!s) throw new ApiError('notfound', `没有这首歌：id=${kw}`);
    return song(s);
  }
  const r = await cmdSearch(kw, { limit: 5, offset: 0 });
  if (!r.songs.length) throw new ApiError('notfound', `搜不到「${kw}」`);
  return r.songs[0];
}

const MAX_COVER_BYTES = 10_000_000;
async function downloadCover(cover, file, force) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30_000);
  let body;
  try {
    const url = new URL(cover);
    if (!['http:', 'https:'].includes(url.protocol)) throw new ApiError('external', '封面地址必须是 HTTP(S) URL');
    // 图片请求不携带登录 cookie；先完整读取有上限的响应，再打开目标文件。
    const res = await fetch(url, {
      headers: { Referer: 'https://music.163.com/', 'User-Agent': UA },
      signal: controller.signal,
    });
    if (!res.ok) throw new ApiError([404, 410].includes(res.status) ? 'notfound' : 'external', `封面下载失败（HTTP ${res.status}）`);
    const type = res.headers.get('content-type');
    if (type && !/^image\//i.test(type)) throw new ApiError('external', `封面响应不是图片：${type}`);
    if (Number(res.headers.get('content-length')) > MAX_COVER_BYTES) throw new ApiError('external', '封面超过 10 MB（10000000 字节）');
    if (!res.body) throw new ApiError('notfound', '封面图片为空');
    const chunks = [];
    let bytes = 0;
    for await (const chunk of res.body) {
      bytes += chunk.byteLength;
      if (bytes > MAX_COVER_BYTES) throw new ApiError('external', '封面超过 10 MB（10000000 字节）');
      chunks.push(chunk);
    }
    if (!bytes) throw new ApiError('notfound', '封面图片为空');
    body = Buffer.concat(chunks, bytes);
  } catch (e) {
    if (e instanceof ApiError) throw e;
    throw new ApiError(controller.signal.aborted ? 'timeout' : 'external', '封面下载失败：' + e.message);
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
  try {
    await writeFile(file, body, { flag: force ? 'w' : 'wx' });
  } catch (e) {
    if (e.code === 'EEXIST') throw new ApiError('usage', `文件已存在：${file}（覆盖需 --force）`);
    throw new ApiError('external', `无法写入封面：${e.message}`);
  }
  return body.length;
}

async function cmdCover(kw, o) {
  if (!kw.trim() || pos.some((a) => a.startsWith('--'))) throw new ApiError('usage', 'cover 需要歌曲关键词或 id');
  if (o.download !== undefined && (!o.download.trim() || o.download.startsWith('--'))) throw new ApiError('usage', '--download 需要文件路径');
  if (o.force && o.download === undefined) throw new ApiError('usage', '--force 只能与 --download 一起使用');
  let s = await cmdSong(kw);
  // 明文搜索可能省略图片 URL；只在缺封面时补查选中歌曲的详情。
  if (!s.cover && !/^\d+$/.test(kw)) s = await cmdSong(String(s.id));
  const { id, name, artist, cover } = s;
  if (!cover) throw new ApiError('notfound', `这首歌没有封面：id=${id}`);
  if (o.download === undefined) return { id, name, artist, cover };
  const file = resolve(o.download);
  const bytes = await downloadCover(cover, file, o.force);
  return { id, cover, file, bytes };
}
async function cmdUrl(ids, o) {
  const level = o.level;
  const j = await weapiPost('song/enhance/player/url/v1', {
    ids: JSON.stringify(ids.map(Number)),
    level,
    encodeType: ['standard', 'higher'].includes(level) ? 'aac' : 'flac',
    // 2026-11-18 实测：不带 immerseType 时这个接口对每首歌都回 code=404、url=null，
    // 看起来像「全部没版权」；带上 c51 就能拿到正常直链。
    immerseType: 'c51',
  });
  return {
    level: j.data && j.data[0] && j.data[0].level,
    items: (j.data || []).map((d) => ({ id: d.id, url: d.url, br: d.br, level: d.level, size: d.size, fee: d.fee })),
  };
}
async function cmdDaily(o) {
  const j = await weapiPost('v2/discovery/recommend/songs', {});
  const list = (j.data && j.data.dailySongs) || j.recommend || [];
  if (!list.length && (!o.offset || j.code !== 200)) {
    if (j.code === 301) throw new ApiError('auth', AUTH_HINT);
    throw new ApiError('external', '每日推荐返回空：' + JSON.stringify(j).slice(0, 160));
  }
  const songs = list.slice(o.offset, o.offset + o.limit).map(song);
  return { count: songs.length, total: list.length, songs };
}
async function cmdPlaylist(idOrKw, o) {
  let id = String(idOrKw);
  if (!/^\d+$/.test(id)) {
    const hit = await searchFirst(String(idOrKw), 1000, 'playlists', 'playlist');
    id = hit.id;
  }
  const j = await weapiPost('v6/playlist/detail', { id: +id, n: o.limit, s: 8 });
  if (!j.playlist) throw new ApiError('notfound', `没有这个歌单：id=${id}`);
  const tracks = j.playlist.tracks || [];
  let songs = tracks.slice(o.offset, o.offset + o.limit).map(song);
  // detail 不认 offset，内嵌 tracks 也可能截断；按完整 trackIds 取本页，缺的详情才补查。
  if (Array.isArray(j.playlist.trackIds)) {
    const ids = j.playlist.trackIds.slice(o.offset, o.offset + o.limit).map((t) => t.id);
    const byId = new Map(tracks.map((s) => [s.id, song(s)]));
    const missing = ids.filter((id) => !byId.has(id));
    for (const s of await songsByIds(missing)) byId.set(s.id, s);
    songs = ids.map((id) => byId.get(id)).filter(Boolean);
  }
  return {
    id: j.playlist.id,
    name: j.playlist.name,
    count: songs.length,
    total: j.playlist.trackCount ?? tracks.length,
    songs,
  };
}
const norm = (v) => String(v || '').toLowerCase().replace(/\s+/g, '').replace(/[（(].*$/, '');

// 同名/别名优先；专辑再按曲目数排（正版专辑 > 同名单曲/翻唱）
function pickBest(list, kw, kind) {
  const want = norm(kw);
  const score = (it) => {
    const names = [it.name, ...(it.alias || [])].map(norm);
    if (want && names.includes(want)) return 2;
    if (want && names.some((n) => n && (n.includes(want) || want.includes(n)))) return 1;
    return 0;
  };
  const ranked = list.map((it) => ({ s: score(it), it })).sort((a, b) => b.s - a.s);
  let cands = ranked.filter((r) => r.s === ranked[0].s).map((r) => r.it);
  if (ranked[0].s === 2 && kind === 'album') cands = cands.slice().sort((a, b) => (b.size || 0) - (a.size || 0));
  return cands[0];
}

// 搜歌手/专辑/歌单/播客：先走 weapi cloudsearch（已登录时索引全，明文库里连周杰伦《范特西》都没有），
// 拿不到再回退明文 api/search/get/web
async function searchList(kw, type, key, limit = 10, offset = 0) {
  let result;
  try {
    const j = await weapiPost('cloudsearch/get/web', { s: kw, type, limit, offset, total: true });
    result = j.result;
  } catch { /* 回退明文 */ }
  // 有总数的空页就是到末尾了，不换搜索索引重新找一页。
  if (!(result?.[key]?.length) && !(offset > 0 && result?.playlistCount != null)) {
    const j = await plainPost('api/search/get/web', { s: kw, type, limit, offset, total: true });
    result = j.result;
  }
  const list = result?.[key] || [];
  return { list, total: result?.playlistCount ?? list.length };
}
async function searchFirst(kw, type, key, kind) {
  const { list } = await searchList(kw, type, key);
  if (!list.length) throw new ApiError('notfound', `搜不到「${kw}」`);
  return pickBest(list, kw, kind);
}

// 歌手热门：v1/artist/<id> 的 hotSongs；老接口 artist/top/song 作回退
async function cmdArtist(kw, o) {
  const id = /^\d+$/.test(kw) ? +kw : (await searchFirst(kw, 100, 'artists', 'artist')).id;
  let j = await weapiPost(`v1/artist/${id}`, {});
  let list = j.hotSongs || [];
  let name = (j.artist && j.artist.name) || '';
  if (!list.length) {
    j = await weapiPost('artist/top/song', { id });
    list = j.songs || [];
  }
  if (!list.length && (!o.offset || j.code !== 200)) throw new ApiError('notfound', `这位歌手没有可播的歌：${kw}`);
  const songs = list.slice(o.offset, o.offset + o.limit).map(song);
  return { id, name: name || kw, count: songs.length, total: list.length, songs };
}

// 歌手的专辑列表（含经典老专辑，搜索索引里没有的也能从这里拿到 id）
async function cmdAlbums(kw, o) {
  const id = /^\d+$/.test(kw) ? +kw : (await searchFirst(kw, 100, 'artists', 'artist')).id;
  const j = await weapiPost(`artist/albums/${id}`, { limit: o.limit, offset: o.offset, total: true });
  const list = j.hotAlbums || [];
  if (!list.length && (!o.offset || j.code !== 200)) throw new ApiError('notfound', `这位歌手没有专辑：${kw}`);
  return {
    id,
    name: (list[0] && list[0].artist && list[0].artist.name) || kw,
    count: list.length,
    total: j.artist?.albumSize ?? j.total ?? list.length,
    albums: list.map((a) => ({ id: a.id, name: a.name, size: a.size, year: (a.publishTime && new Date(a.publishTime).getFullYear()) || 0 })),
  };
}

// 专辑：v1/album/<id> 的 songs（整张，按专辑顺序）
async function cmdAlbum(kw, o) {
  const id = /^\d+$/.test(kw) ? +kw : (await searchFirst(kw, 10, 'albums', 'album')).id;
  const j = await weapiPost(`v1/album/${id}`, {});
  const list = j.songs || [];
  if (!list.length && (!o.offset || j.code !== 200)) throw new ApiError('notfound', `这张专辑没有可播的歌：${kw}`);
  const songs = list.slice(o.offset, o.offset + o.limit).map(song);
  return { id, name: (j.album && j.album.name) || kw, count: songs.length, total: j.album?.size ?? j.album?.songCount ?? list.length, songs };
}

// ---------- 歌单搜索 / 榜单 / 收藏 / FM / 最近 / 播客 ----------

async function cmdPlaylists(kw, o) {
  const { list, total } = await searchList(kw, 1000, 'playlists', o.limit, o.offset);
  if (!list.length && !o.offset) throw new ApiError('notfound', `搜不到歌单「${kw}」`);
  return {
    kw,
    count: list.length,
    total,
    playlists: list.map((p) => ({
      id: p.id,
      name: p.name,
      count: p.trackCount || 0,
      creator: (p.creator || {}).nickname || '',
      sub: p.subscribed === true,
    })),
  };
}

async function cmdCharts(o) {
  const j = await weapiPost('toplist', {});
  const list = j.list || [];
  if (!list.length && (!o.offset || j.code !== 200)) throw new ApiError('external', '榜单接口没返回列表');
  const page = list.slice(o.offset, o.offset + o.limit);
  return {
    count: page.length,
    total: j.total ?? j.count ?? list.length,
    charts: page.map((c) => ({ id: c.id, name: c.name, count: c.trackCount, freq: c.updateFrequency })),
  };
}

async function cmdChart(kw, o) {
  let id = /^\d+$/.test(kw) ? +kw : 0;
  let name = kw;
  if (!id) {
    const j = await weapiPost('toplist', {});
    const hit = pickBest(j.list || [], kw, 'chart');
    if (!hit) throw new ApiError('notfound', `没有这个榜单：${kw}（用 charts 看全部）`);
    id = hit.id;
    name = hit.name;
  }
  const r = await cmdPlaylist(String(id), o);
  return { ...r, chart_id: id, chart: name };
}

async function cmdMyAlbums(o) {
  const j = await weapiPost('album/sublist', { limit: o.limit, offset: o.offset, total: true });
  const list = j.data || [];
  return {
    count: list.length,
    total: j.count ?? j.total ?? list.length,
    albums: list.map((a) => ({ id: a.id, name: a.name, size: a.size, artist: (a.artists || []).map((x) => x.name).join(' / ') })),
  };
}

async function cmdMyArtists(o) {
  const j = await weapiPost('artist/sublist', { limit: o.limit, offset: o.offset, total: true });
  const list = j.data || [];
  return { count: list.length, total: j.count ?? j.total ?? list.length, artists: list.map((a) => ({ id: a.id, name: a.name, albums: a.albumSize, songs: a.musicSize })) };
}

// 私人 FM：接口一次固定给 3 首且不认 limit，多拉几次凑够（去重）
async function cmdFm(o) {
  const want = Math.min(o.limit, 30);
  const seen = new Set();
  const out = [];
  for (let i = 0; i < 12 && out.length < want; i++) {
    const j = await weapiPost('radio/get', {});
    const batch = j.data || [];
    if (!batch.length) break;
    for (const s of batch) if (!seen.has(s.id)) { seen.add(s.id); out.push(song(s)); }
  }
  if (!out.length) throw new ApiError('external', '私人 FM 没返回歌曲');
  const picked = out.slice(0, want);
  return { count: picked.length, songs: picked };
}

async function cmdRecent(o) {
  const uid = await currentUid();
  const j = await weapiPost('v1/play/record', { uid, type: 1 }); // type=1：最近一周
  const list = j.weekData || j.allData || [];
  const items = list.slice(o.offset, o.offset + o.limit).filter((x) => x.song).map((x) => ({ ...song(x.song), plays: x.playCount }));
  if (!items.length && (!o.offset || j.code !== 200)) throw new ApiError('notfound', '最近播放是空的');
  return { count: items.length, total: j.total ?? j.count ?? list.length, songs: items };
}

async function cmdPodcasts(o) {
  // 两个端点都认 limit、不认 offset；拉到页尾再本地截，避免每页重复第一页。
  const j = await weapiPost(o.recommend ? 'djradio/recommend/v1' : 'djradio/get/subed', {
    limit: o.offset + o.limit, offset: o.offset,
  });
  const list = j.djRadios || [];
  const page = list.slice(o.offset, o.offset + o.limit);
  if (!list.length && (!o.offset || j.code !== 200)) {
    throw new ApiError('notfound', o.recommend ? '没有推荐播客' : '没订阅播客（加 --recommend 看推荐的）');
  }
  return {
    kind: o.recommend ? 'recommend' : 'subscribed',
    count: page.length,
    total: j.count ?? j.total ?? list.length,
    podcasts: page.map((r) => ({ id: r.id, name: r.name, episodes: r.programCount, dj: (r.dj || {}).nickname || '' })),
  };
}

// 放某播客的最新 N 期：名字先在订阅+推荐里找，找不到再搜播客
async function cmdPodcast(kw, o) {
  let id = /^\d+$/.test(kw) ? +kw : 0;
  let name = kw;
  if (!id) {
    const subs = (await weapiPost('djradio/get/subed', { limit: 100, offset: 0 })).djRadios || [];
    const rec = (await weapiPost('djradio/recommend/v1', { limit: 100, offset: 0 })).djRadios || [];
    const hit = pickBest([...subs, ...rec], kw, 'djradio');
    if (hit) {
      id = hit.id;
      name = hit.name;
    } else {
      const s = await searchFirst(kw, 1009, 'djRadios', 'djradio');
      id = s.id;
      name = s.name;
    }
  }
  const j = await weapiPost('dj/program/byradio', { radioId: id, limit: o.limit, offset: o.offset, asc: false });
  const progs = j.programs || [];
  const songs = progs
    .filter((p) => p.mainSong && p.mainSong.id)
    .map((p) => ({ ...song(p.mainSong), programId: p.id, program: p.name || '' }));
  if (!songs.length && (!o.offset || j.code !== 200)) throw new ApiError('notfound', `这个播客没有可播的节目：${kw}`);
  return { id, name, count: songs.length, total: j.count ?? j.total ?? progs[0]?.radio?.programCount ?? progs.length, songs };
}

async function cmdEpisode(pid, o) {
  const j = await weapiPost('dj/program/detail', { id: +pid });
  const p = j.program || {};
  const ms = p.mainSong || {};
  if (!ms.id) throw new ApiError('notfound', `没有这期节目：${pid}`);
  return {
    id: +pid,
    name: p.name || ms.name || '',
    dj: (p.dj || {}).nickname || '',
    count: 1,
    songs: [{ ...song(ms), programId: +pid, program: p.name || '' }],
  };
}

// 「我喜欢的音乐」顺序 = 收藏时间由近到远（与客户端一致）：
// song/like/get 返回的 ids 顺序与收藏时间无关（实测最老收藏的排第 1），
// 真值是 specialType=5 歌单的 trackIds[].at（收藏时间毫秒戳），按它倒序再取详情。
async function cmdLiked(o) {
  const pid = await likedPlaylistId();
  if (!pid) throw new ApiError('notfound', '找不到「我喜欢的音乐」歌单');
  // n=0 省掉内嵌 tracks，trackIds 仍全量返回
  const j = await weapiPost('v6/playlist/detail', { id: pid, n: 0, s: 8 });
  const tids = ((j.playlist || {}).trackIds || []).slice().sort((a, b) => (b.at || 0) - (a.at || 0));
  const ids = tids.slice(o.offset, o.offset + o.limit).map((x) => x.id);
  const songs = (await songsByIds(ids)).map((s) => ({ ...s, liked: true }));
  return { count: songs.length, total: tids.length, songs };
}
async function songsByIds(ids) {
  if (!ids.length) return [];
  const det = await weapiPost('v3/song/detail', { c: JSON.stringify(ids.map((id) => ({ id }))) });
  const byId = new Map((det.songs || []).map((s) => [s.id, song(s)]));
  return ids.map((id) => byId.get(id)).filter(Boolean);
}
async function likedPlaylistId() {
  const uid = await currentUid();
  const j = await weapiPost('user/playlist', { uid, limit: 1000, offset: 0, includeVideo: true });
  const p = (j.playlist || []).find((x) => x.specialType === 5) || (j.playlist || [])[0];
  return p && p.id;
}

async function cmdLike(id, o) {
  const like = !o.unlike;
  const j = await weapiPost('radio/like', { alg: 'itembased', trackId: +id, like, time: 3 });
  if (j.code === 200) return { id: +id, liked: like, via: 'radio/like', code: j.code };
  const first = `radio/like code=${j.code}：${j.message || j.msg || ''}`;
  // 风控（-460）时退一步：直接对「我喜欢的音乐」歌单做增删，走另一套风控
  const pid = await likedPlaylistId();
  if (pid) {
    const j2 = await weapiPost('playlist/manipulate/tracks', {
      op: like ? 'add' : 'del',
      pid,
      trackIds: JSON.stringify([+id]),
      imme: 'true',
    });
    if (j2.code === 200 || (like && j2.code === 502)) {
      // 502 = 歌单内歌曲重复 → 目标状态已经达成，按幂等成功处理
      return { id: +id, liked: like, via: 'playlist/manipulate/tracks', already: j2.code === 502, fallback_from: first };
    }
    throw new ApiError('external', `网易云拒绝了这次操作（${first}；playlist/manipulate code=${j2.code}：${j2.message || j2.msg || ''}）`);
  }
  throw new ApiError('external', `网易云拒绝了这次操作（${first}）`);
}
async function cmdLyric(id, o) {
  const j = await weapiPost('song/lyric', { id: +id, lv: -1, kv: -1, tv: -1 });
  return { id: +id, lyric: (j.lrc && j.lrc.lyric) || '', trans: o.trans ? (j.tlyric && j.tlyric.lyric) || '' : undefined };
}
async function cmdSession() {
  const j = await weapiPost('w/nuser/account/get', {});
  return {
    loggedIn: !!(j.profile && j.profile.userId),
    uid: num(j.profile && j.profile.userId),
    nick: (j.profile && j.profile.nickname) || '',
    vip: (j.profile && j.profile.vipType) || 0,
  };
}
async function currentUid() {
  const s = await cmdSession();
  if (!s.loggedIn) throw new ApiError('auth', AUTH_HINT);
  return s.uid;
}
async function cmdMyPlaylists(o) {
  const uid = await currentUid();
  // user/playlist 的 limit 不稳定，非零 offset 还会多跳过置顶歌单；从头取再本地分页。
  const j = await weapiPost('user/playlist', { uid, limit: o.offset + o.limit, includeVideo: true });
  const list = j.playlist || [];
  const page = list.slice(o.offset, o.offset + o.limit);
  return {
    count: page.length,
    total: j.total ?? j.count ?? list.length,
    playlists: page.map((p) => ({ id: p.id, name: p.name, count: p.trackCount, special: p.specialType || 0, sub: p.subscribed === true })),
  };
}
async function cmdLikeState(id) {
  // 这个端点回的是「我喜欢的歌曲 id 全表」（key 是 ids），不是单曲对象
  const j = await weapiPost('song/like/get', { trackIds: JSON.stringify([Number(id)]) });
  if (j.code !== 200) {
    if (j.code === 301) throw new ApiError('auth', AUTH_HINT);
    throw new ApiError('external', `查喜欢状态失败（code=${j.code}）：${j.message || j.msg || ''}`);
  }
  const ids = (Array.isArray(j.ids) ? j.ids : []).map(Number);
  return { id: Number(id), liked: ids.includes(Number(id)), liked_total: ids.length, code: j.code };
}
async function cmdLikedIds(args) {
  if (args.length) throw new ApiError('usage', '用法：liked-ids');
  const j = await weapiPost('song/like/get', { trackIds: '[]' });
  if (j.code !== 200) {
    if (j.code === 301) throw new ApiError('auth', AUTH_HINT);
    throw new ApiError('external', `查喜欢列表失败（code=${j.code}）：${j.message || j.msg || ''}`);
  }
  if (!Array.isArray(j.ids)) throw new ApiError('external', '喜欢列表缺少 ids，不能当成空列表');
  const ids = j.ids.map(Number);
  if (ids.some((id) => !Number.isSafeInteger(id) || id < 1)) throw new ApiError('external', '喜欢列表含无效歌曲 id');
  return { count: ids.length, total: ids.length, ids };
}
async function cmdDislike(args) {
  if (args.length !== 1) throw new ApiError('usage', '用法：dislike <歌曲id>');
  const id = songId(args[0]);
  // NeteaseCloudMusicApi 的 fm/trash 对应此 weapi 写端点。
  const j = await weapiPost('radio/trash/add', { songId: id, time: 25, alg: 'RT' });
  if (j.code !== 200) {
    if (j.code === 301) throw new ApiError('auth', AUTH_HINT);
    throw new ApiError('external', `私人 FM 不喜欢失败（code=${j.code}）：${j.message || j.msg || ''}`);
  }
  return { id, disliked: true, code: j.code };
}
async function cmdSmsSend(phone) {
  const j = await weapiPost('sms/captcha/sent', { cellphone: String(phone), ctcode: '86', secrete: 'music_user_login', source: 'webMainStation' });
  if (j.code !== 200) throw new ApiError('external', `发验证码没成功（code=${j.code}）：${j.message || JSON.stringify(j).slice(0, 120)}`);
  return { sent: true };
}

// 网易云把额外确认/风控挑战用这几个码下发：参数在响应的 data 里
const RISK_CODES = new Set([8860, -462, 8821]);
// 只认这次请求下发的 MUSIC_U：进来的 cookie 里本来就有登录态时，
// 失败响应也会让「jar 里有 MUSIC_U」成立。
let loggedIn = false;
const hasLogin = () => loggedIn;

// 安全验证要用户拿手机确认：有 qrencode 就把码画成图并打开，否则把链接交出去
function showVerifyQr(url) {
  console.error('网易云要求安全验证：用本账号的网易云 App 扫下面这张码确认。');
  console.error('验证链接：' + url);
  try {
    const png = resolve(tmpdir(), 'netease-verify.png');
    execFileSync('qrencode', ['-o', png, '-s', '8', '-m', '2', url], { stdio: 'ignore' });
    const opener = process.platform === 'darwin' ? 'open' : 'xdg-open';
    execFileSync(opener, [png], { stdio: 'ignore' });
    console.error('二维码图片：' + png);
  } catch {
    // 没装 qrencode 或打不开看图程序：上面的链接照样可以手动打开
  }
}

// 8860/-462/8821 带 verify 参数时是网易云的风控二次验证：生成验证二维码，
// 等用户拿手机确认；确认后登录态落在同一个会话的 cookie 里，不用再登一次。
async function verifyRisk(j) {
  const data = j.data || {};
  let extra = data.params;
  if (typeof extra === 'string') {
    try {
      extra = JSON.parse(extra);
    } catch {
      extra = null;
    }
  }
  if (!data.verifyId || !data.verifyType || !data.verifyToken || !extra || !extra.event_id || !extra.sign) return false;
  const params = JSON.stringify({ event_id: extra.event_id, sign: extra.sign });
  const made = await weapiPost('frontrisk/verify/getqrcode', {
    verifyConfigId: data.verifyId,
    verifyType: data.verifyType,
    token: data.verifyToken,
    params,
    size: 150,
  });
  const qrCode = made.data && made.data.qrCode;
  if (!qrCode) throw new ApiError('external', '安全验证二维码没生成：' + JSON.stringify(made).slice(0, 200));
  const query = new URLSearchParams({
    qrCode,
    verifyToken: data.verifyToken,
    verifyId: String(data.verifyId),
    verifyType: String(data.verifyType),
    params,
  });
  const url = 'https://st.music.163.com/encrypt-pages?' + query.toString();
  showVerifyQr(url);
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 2000));
    const s = await weapiPost('frontrisk/verify/qrcodestatus', { qrCode });
    const status = (s.data && s.data.qrCodeStatus) ?? s.qrCodeStatus;
    const reason = (s.data && s.data.detailReason) ?? s.detailReason;
    if (status === 20 && !reason) return true;
    if (status === 21) throw new ApiError('auth', '安全验证的二维码过期了：重新发一次验证码再来');
    if (reason === 303) throw new ApiError('auth', '扫码用的是别的账号：换成本账号的网易云 App 再扫');
  }
  throw new ApiError('auth', '安全验证没等到手机确认：用网易云 App 扫那张码，或者手动打开 ' + url);
}

async function cmdSmsLogin(phone, code) {
  const payload = { phone: String(phone), countrycode: '86', captcha: String(code), rememberLogin: true };
  let j = await weapiPost('login/cellphone', payload);
  if (!hasLogin() && RISK_CODES.has(Number(j.code))) {
    if (await verifyRisk(j)) {
      if (!hasLogin()) throw new ApiError('auth', '安全验证过了但没拿到登录态：重新发一次验证码再试');
      return { state: 'ok', cookie: jar };
    }
    // 没有验证参数时是「手机号被回收」的确认：同一会话里认下来再登一次
    const confirmed = await weapiPost('login/cellphone/twice/used/confirm', {});
    if (!hasLogin()) j = await weapiPost('login/cellphone', payload);
    if (!hasLogin()) {
      const why = j.message || j.msg || confirmed.message || '服务端仍要求额外确认';
      const hint = Number(j.code) === 503 ? '（验证码已被上一次请求用掉了，重新发一次）' : '';
      throw new ApiError('auth', `登录没成（code=${j.code}）：${why}${hint}`);
    }
    return { state: 'ok', cookie: jar };
  }
  if (!hasLogin()) {
    throw new ApiError('auth', `登录没成（code=${j.code}）：${j.message || JSON.stringify(j).slice(0, 200)}`);
  }
  return { state: 'ok', cookie: jar };
}
async function cmdQrStart() {
  const j = await weapiPost('login/qrcode/unikey', { type: 1, header: {} });
  if (!j.unikey) throw new ApiError('external', '拿不到二维码 key：' + JSON.stringify(j).slice(0, 160));
  return { key: j.unikey, url: 'https://music.163.com/login?codekey=' + j.unikey };
}
async function cmdQrPoll(key, o) {
  const deadline = Date.now() + o.timeout * 1000;
  let state = 'waiting';
  while (Date.now() < deadline) {
    const j = await weapiPost('login/qrcode/client/login', { key, type: 1 });
    if (j.code === 800) return { state: 'expired', code: j.code };
    if (j.code === 802 && state !== 'scanned') {
      state = 'scanned';
      console.error('已扫到，等你在手机上点「确认登录」…');
    }
    if (j.code === 803) {
      if (!hasLogin()) throw new ApiError('external', '登录成功了但没拿到 MUSIC_U：' + jar.slice(0, 120));
      return { state: 'ok', cookie: jar };
    }
    if (RISK_CODES.has(Number(j.code)) && (await verifyRisk(j))) {
      if (!hasLogin()) throw new ApiError('external', '安全验证过了但没拿到 MUSIC_U：' + jar.slice(0, 120));
      return { state: 'ok', cookie: jar };
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  return { state, code: 801 };
}

// ---------- 参数解析 ----------
const argv = process.argv.slice(2);
const CMD = argv[0];
const opts = { limit: 0, offset: 0, start: 1, level: 'lossless', trans: false, unlike: false, timeout: 120 };
const pos = [];
for (let i = 1; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--limit') opts.limit = +argv[++i];
  else if (a === '--offset') opts.offset = +argv[++i];
  else if (a === '--start') {
    const value = argv[++i];
    opts.start = /^\d+$/.test(value || '') ? +value : NaN;
  }
  else if (a === '--level') opts.level = argv[++i];
  else if (a === '--trans') opts.trans = true;
  else if (a === '--unlike') opts.unlike = true;
  else if (a === '--timeout') opts.timeout = +argv[++i];
  else if (a === '--recommend') opts.recommend = true;
  else if (a === '--download') opts.download = argv[++i] ?? '';
  else if (a === '--force') opts.force = true;
  else pos.push(a);
}
const DEFAULTS = { search: 20, daily: 40, playlist: 500, liked: 1000, myplaylists: 100, artist: 50, album: 200, albums: 60,
  playlists: 20, charts: 100, myalbums: 60, myartists: 60, fm: 12, recent: 30, podcasts: 50, podcast: 3 };
if (!opts.limit) opts.limit = DEFAULTS[CMD] || 20;

const rawPost = (path, data) => (String(path).startsWith('api/') ? plainPost(path, data) : weapiPost(path, data));

const HANDLERS = {
  search: () => cmdSearch(pos.join(' '), opts),
  song: () => cmdSong(pos.join(' ')),
  'play-ids': () => cmdPlayIds(pos, opts),
  cover: () => cmdCover(pos.join(' '), opts),
  url: () => cmdUrl(pos, opts),
  daily: () => cmdDaily(opts),
  playlist: () => cmdPlaylist(String(pos[0]).replace(/.*[?&#/]id=/, ''), opts),
  playlists: () => cmdPlaylists(pos.join(' '), opts),
  charts: () => cmdCharts(opts),
  chart: () => cmdChart(String(pos.join(' ')).replace(/.*[?&#/]id=/, ''), opts),
  myalbums: () => cmdMyAlbums(opts),
  myartists: () => cmdMyArtists(opts),
  fm: () => cmdFm(opts),
  recent: () => cmdRecent(opts),
  podcasts: () => cmdPodcasts(opts),
  podcast: () => cmdPodcast(String(pos.join(' ')), opts),
  episode: () => cmdEpisode(pos[0], opts),
  artist: () => cmdArtist(String(pos.join(' ')).replace(/.*[?&#/]id=/, ''), opts),
  album: () => cmdAlbum(String(pos.join(' ')).replace(/.*[?&#/]id=/, ''), opts),
  albums: () => cmdAlbums(String(pos.join(' ')).replace(/.*[?&#/]id=/, ''), opts),
  liked: () => cmdLiked(opts),
  'liked-ids': () => cmdLikedIds(pos),
  dislike: () => cmdDislike(pos),
  like: () => cmdLike(pos[0], opts),
  lyric: () => cmdLyric(pos[0], opts),
  myplaylists: () => cmdMyPlaylists(opts),
  session: () => cmdSession(),
  uid: () => currentUid().then((uid) => ({ uid })),
  raw: () => rawPost(pos[0], JSON.parse(pos[1] || '{}')),
  'like-state': () => cmdLikeState(pos[0]),
  'sms-send': () => cmdSmsSend(pos[0]),
  'sms-login': () => cmdSmsLogin(pos[0], pos[1]),
  'qr-start': () => cmdQrStart(),
  'qr-poll': () => cmdQrPoll(pos[0], opts),
};

if (!HANDLERS[CMD]) {
  console.error(JSON.stringify({ error: 'usage', hint: `未知命令 ${CMD || '(空)'}；可用：${Object.keys(HANDLERS).join(' ')}` }));
  process.exit(2);
}
try {
  if (!Number.isSafeInteger(opts.offset) || opts.offset < 0) throw new ApiError('usage', '--offset 需要非负整数');
  const out = await HANDLERS[CMD]();
  console.log(JSON.stringify(out));
} catch (e) {
  const code = e instanceof ApiError ? e.code : 'internal';
  console.error(JSON.stringify({ error: code, hint: e.hint || String(e) }));
  process.exit(code === 'usage' ? 2 : code === 'auth' ? 3 : code === 'notfound' ? 4 : 5);
}
