#!/usr/bin/env node
// weread — 读你的微信读书数据：书架/进度、划线/想法、书籍信息、目录、搜索、统计；笔记导出 Markdown。
// 只做只读接口；正文（章节内容）不导出：网页阅读器把正文画在 canvas 上、分段载荷由 wasm 解密，
// 取正文需要绕它的反爬，本技能不做（原因见 REFERENCE.md「为什么不导出正文」）。
//
// 批量导出（export --all）是三件事：断点续跑 resume、单写入者锁 .weread-export.lock、请求超时与重试。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseFlags, timeoutMsOf, positionalText, scanGlobals } from './lib/args.mjs';
import { emit, fail, reportError, SkillError, EXIT, nowIso } from './lib/render.mjs';
import { cliCommand, CLI_DIR } from './lib/cli.mjs';
import { WereadApi, shapeBook, shapeProgress, shapeChapter, shapeHighlight, shapeReview, formatDuration } from './lib/api.mjs';
import { bookFromId, bookIdFromQuery, indexBooks, requireBook } from './lib/books.mjs';
import { mergeNotes, notesText } from './lib/notes.mjs';
import { exportBooks, sanitizeName, countNotes } from './lib/export.mjs';
import { loadAuth, saveAuth, clearAuth, loadState, saveState, cookieHeader, resolveExportDir, authPath } from './lib/store.mjs';
import { readChromeCookies, listProfiles, MANUAL_COOKIE_HINT, currentPlatform } from './lib/chrome-cookies.mjs';
import { readBrowserAuth, isLoggedInJar, launchBrowser, openLoginPanel } from './lib/browser-auth.mjs';

const CLI = cliCommand();
const sleep = (ms) => new Promise(resolve => { setTimeout(resolve, ms); });

// ------------------------------------------------------------------ 帮助

const GLOBAL_FLAGS_HELP = '全局旗标: --json（机器可读） --quiet --timeout <秒>；export 另有 --dry-run / --yes';

const COMMANDS = {
  login: {
    summary: '获取/刷新登录态：拉起浏览器扫码、日常 Chrome、或手工 cookie',
    usage: 'login [--cookie "wr_vid=…; wr_skey=…"] [--from-chrome [--profile Default]] [--browser] [--timeout 秒]',
    detail: '不带参数：已登录就直接取；没登录就打开一个独立的浏览器窗口停在微信读书登录页，\n'
      + '        用微信扫码（默认等 180 秒），cookie 由本工具自己收。\n'
      + '        机器上要有 Chrome / Edge / Brave / Chromium 之一；WEREAD_BROWSER 可指定路径。\n'
      + '        --from-chrome 读本机日常 Chrome（macOS）；--cookie 手工粘贴两个值。',
    flags: { cookie: 'string', 'from-chrome': 'bool', profile: 'string', browser: 'bool' },
    run: cmdLogin,
  },
  logout: {
    summary: '清除本机保存的登录态（不动账号本身）',
    usage: 'logout',
    detail: '删掉本机的 auth.json；下一次读写数据前需要重新 login。',
    flags: {},
    run: cmdLogout,
  },
  status: {
    summary: '实时验证登录态与账号',
    usage: 'status',
    detail: '读一次书架接口验证登录态是否仍然有效；失效时状态文件记下 auth，下次恢复后自动清除。',
    flags: {},
    run: cmdStatus,
  },
  shelf: {
    summary: '书架与阅读进度（进度/时长/最近在读）',
    usage: 'shelf [--filter all|reading|finished] [--limit N]',
    detail: '读的是书架同步接口；进度与阅读时长来自同一份同步数据。',
    flags: { filter: 'string', limit: 'int' },
    run: cmdShelf,
  },
  notes: {
    summary: '笔记本总览，或某本书的划线 + 想法',
    usage: 'notes [书名|bookId] [--book 书名] [--limit N]',
    detail: '不给书：笔记本总览（每本多少划线/想法）；给书：按章列出划线与想法。裸 bookId（纯数字或 CB_ 开头）不查本地索引。',
    flags: { book: 'string', limit: 'int' },
    run: cmdNotes,
  },
  book: {
    summary: '某本书的信息 + 目录 + 我的进度',
    usage: 'book <书名|bookId> [--limit N]',
    detail: '信息 + 目录（章节列表）+ 我的进度与笔记计数。裸 bookId（纯数字或 CB_ 开头）不查本地索引；能在书架找到时仍显示进度。',
    flags: { limit: 'int' },
    run: cmdBook,
  },
  search: {
    summary: '搜微信读书书城（书名/作者）',
    usage: 'search <关键词> [--count N]',
    detail: '搜的是微信读书书城（不是我的书架；自己的书用 shelf / notes）。',
    flags: { count: 'int' },
    run: cmdSearch,
  },
  stats: {
    summary: '阅读统计：读完/在读数、总时长、读得最多的书',
    usage: 'stats [--limit N]',
    detail: '由书架进度聚合：读完/在读、累计阅读时长、读得最多的书。',
    flags: { limit: 'int' },
    run: cmdStats,
  },
  export: {
    summary: '把划线/想法导出成 Markdown（默认预览，--yes 写入；--all 批量，可续跑）',
    usage: 'export <书名|bookId> [--out 目录] [--force] [--yes] | export --all [--yes]',
    detail: '默认只预览（--yes 才写文件）。裸 bookId（纯数字或 CB_ 开头）不查本地索引。--all 批量导出所有有笔记的书，可中断续跑（resume：已存在的跳过）。',
    flags: { all: 'bool', out: 'string', force: 'bool', yes: 'bool' },
    run: cmdExport,
  },
};

function usageText(commandName) {
  if (commandName) {
    const command = COMMANDS[commandName];
    if (!command) fail('usage', `没有这个命令：${commandName}`, `${CLI} help`);
    return `${commandName} — ${command.summary}\n\n用法: node weread.mjs ${command.usage}\n后端目录: ${CLI_DIR}\n${command.detail}\n\n${GLOBAL_FLAGS_HELP}\n`;
  }
  const names = Object.keys(COMMANDS);
  const lines = [
    'weread — 读你的微信读书数据：书架/进度、划线/想法、书籍信息、目录、搜索、统计；笔记导出 Markdown。',
    '',
    '用法: node weread.mjs <命令> [选项]',
    `后端目录: ${CLI_DIR}`,
    '',
    '命令:',
    ...names.map(name => `  ${name.padEnd(13)} ${COMMANDS[name].summary}`),
    '  help          本帮助（help <命令> 看细节）',
    '',
    '常用:',
    '  node weread.mjs status        先看登录态',
    '  node weread.mjs login         首次/掉登录：扫码、读 Chrome 会话或粘贴 cookie',
    '  node weread.mjs logout        清除本机登录态（不动账号）',
    '  node weread.mjs shelf         书架与进度',
    '  node weread.mjs notes         笔记本总览',
    '  node weread.mjs notes "书名"   某本书的划线/想法',
    '  node weread.mjs export --all --yes   把全部笔记导出 Markdown',
    '',
    '首次使用: node weread.mjs status（没有登录态会提示跑 login）',
    '失败: error=usage 看 node weread.mjs help <命令>；error=auth 跑 node weread.mjs login；其它按 hint= 执行',
  ];
  return `${lines.join('\n')}\n`;
}

// ------------------------------------------------------------------ 上下文

const requireAuth = () => {
  const auth = loadAuth();
  if (!auth?.cookies || !Object.keys(auth.cookies).length) {
    fail('auth', '还没有微信读书登录态', `${CLI} login（打开浏览器扫码）`, { needHuman: true });
  }
  return auth;
};

const apiOf = (auth, flags) => new WereadApi({
  cookie: cookieHeader(auth),
  ua: auth.ua,
  timeoutMs: timeoutMsOf(flags, 20),
});

const requireShelfAndNotebook = async (api) => ({
  shelfRaw: await api.shelf(),
  notebookRaw: await api.notebook(),
});

/** 书名继续只从书架/笔记本解析；裸 bookId 直接请求书籍接口。 */
const resolveBookForQuery = async (api, query) => {
  const bookId = bookIdFromQuery(query);
  if (bookId) return { book: bookFromId(bookId), shelfRaw: null, direct: true };
  const { shelfRaw, notebookRaw } = await requireShelfAndNotebook(api);
  return { book: requireBook(indexBooks(shelfRaw, notebookRaw), query), shelfRaw, direct: false };
};

// ------------------------------------------------------------------ login

const parseCookieString = (raw) => {
  const jar = {};
  for (const part of String(raw ?? '').split(/;\s*/)) {
    const eq = part.indexOf('=');
    if (eq <= 0) continue;
    jar[part.slice(0, eq).trim()] = part.slice(eq + 1).trim();
  }
  return jar;
};

const decodeMaybe = (value) => {
  try { return decodeURIComponent(value ?? ''); } catch { return value ?? ''; }
};

/** 本机日常浏览器里有没有微信读书的登录 cookie（macOS；逐个 profile 试）。 */
function tryChromeCookies({ profile = '' } = {}) {
  if (currentPlatform() !== 'darwin') return null;
  for (const browser of ['chrome', 'edge', 'brave']) {
    for (const entry of listProfiles({ browser })) {
      if (profile && entry.profile !== profile) continue;
      try {
        const read = readChromeCookies({ domain: 'weread.qq.com', browser, profile: entry.profile });
        if (read?.cookies?.wr_vid && read.cookies.wr_skey) return { ...read, source: `${browser}:${entry.profile}` };
      } catch (error) {
        if (error instanceof SkillError && ['deps', 'platform'].includes(error.code)) continue;
        throw error;
      }
    }
  }
  return null;
}

/** 业务接口验证：形状对的失效 cookie 过不了书架这一步，只有它算登录成功。 */
async function verifyLogin(cookies, ua) {
  const api = new WereadApi({ cookie: cookieHeader({ cookies }), ua });
  await api.authCheck();
  await api.shelf();
  return api;
}

async function cmdLogin(flags) {
  let found = null;
  let source = '';
  const expiredOnly = error => error instanceof SkillError && error.code === 'auth';
  if (flags.cookie) {
    const cookies = parseCookieString(flags.cookie);
    if (!cookies.wr_vid || !cookies.wr_skey) fail('usage', '--cookie 里缺 wr_vid 或 wr_skey', MANUAL_COOKIE_HINT);
    found = { cookies, ua: '' };
    source = 'manual';
  } else if (flags['from-chrome']) {
    // 显式走日常浏览器
    if (currentPlatform() !== 'darwin') {
      fail('platform', `自动读日常浏览器 cookie 只有 macOS 上实现了（当前平台 ${currentPlatform()}）`, MANUAL_COOKIE_HINT, { needHuman: true });
    }
    const chrome = tryChromeCookies(flags);
    if (!chrome) fail('auth', '本机日常浏览器里没有可用的微信读书登录态', `先在 Chrome 里登录 weread.qq.com，再重跑；或者去掉 --from-chrome 用内置扫码登录`, { needHuman: true });
    found = { cookies: chrome.cookies, ua: '' };
    source = chrome.source;
  } else {
    const live = await readBrowserAuth().catch(() => null);
    if (live && isLoggedInJar(live.cookies)) {
      // 登录浏览器的 cookie 形状对也可能早已被服务端判失效；验业务接口，失败就当没登录。
      try {
        await verifyLogin(live.cookies, live.ua);
        found = live;
        source = 'browser';
      } catch (error) {
        if (!expiredOnly(error)) throw error;
      }
    }
    if (!found && !flags.browser) {
      const chrome = tryChromeCookies(flags);
      if (chrome) {
        try {
          await verifyLogin(chrome.cookies, '');
          found = { cookies: chrome.cookies, ua: '' };
          source = chrome.source;
        } catch (error) {
          if (!expiredOnly(error)) throw error;
        }
      }
    }
    if (!found) {
      // 没有可用登录态：拉起登录浏览器停在扫码页，等扫完再验业务接口。
      if (!(await launchBrowser())) {
        fail('deps', '没找到可用的浏览器', '装一个 Chrome / Edge / Brave / Chromium，用 WEREAD_BROWSER 指定路径，或改用 --cookie / --from-chrome 登录', { needHuman: true });
      }
      await sleep(1500);
      await openLoginPanel();
      // 等扫码：旧 jar 的形状也满足 isLoggedInJar，所以以业务接口通过为准，
      // 否则会在扫码真正完成前拿着失效 cookie 提前返回。
      const deadline = Date.now() + timeoutMsOf(flags, 180);
      let scanned = null;
      for (;;) {
        const live = await readBrowserAuth().catch(() => null);
        if (live && isLoggedInJar(live.cookies)) {
          try {
            await verifyLogin(live.cookies, live.ua);
            scanned = live;
            break;
          } catch (error) {
            if (!expiredOnly(error)) throw error;
          }
        }
        if (Date.now() >= deadline) break;
        await sleep(2500);
      }
      if (!scanned) fail('blocked', '没等到扫码登录（超时）', `在浏览器窗口里用微信扫一扫；登录后重跑 ${CLI} login`, { needHuman: true });
      found = scanned;
      source = 'browser';
    }
  }
  const api = await verifyLogin(found.cookies, found.ua);
  const vid = found.cookies.wr_vid ?? '';
  let name = decodeMaybe(found.cookies.wr_name);
  let avatar = decodeMaybe(found.cookies.wr_avatar);
  if (vid) {
    try {
      const me = await api.me(vid);
      name = me.name || name;
      avatar = me.avatar || avatar;
    } catch { /* 名字拿不到不影响登录 */ }
  }
  const auth = saveAuth({
    cookies: found.cookies,
    ua: found.ua || '',
    name,
    vid,
    avatar,
    source,
    syncedAt: nowIso(),
    verifiedAt: nowIso(),
  });
  saveState({ status: 'ok', at: nowIso() });
  emit({
    conclusion: `登录成功：${name || vid}`,
    fields: { login: 'ok', name, vid, source, cookies: Object.keys(auth.cookies).length, path: authPath() },
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ logout

async function cmdLogout(flags) {
  const hadLogin = Boolean(loadAuth()?.cookies && Object.keys(loadAuth().cookies).length);
  clearAuth();
  saveState({ status: 'logged-out', at: nowIso() });
  emit({
    conclusion: hadLogin ? '已退出微信读书：本机登录态已删除' : '本机没有保存的微信读书登录态',
    fields: { login: 'out', path: authPath() },
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ status

async function cmdStatus(flags) {
  const auth = requireAuth();
  const api = apiOf(auth, flags);
  try {
    await api.shelf();
  } catch (error) {
    if (error instanceof SkillError && error.code === 'auth') {
      saveState({ status: 'auth', at: nowIso() });
    }
    throw error;
  }
  saveState({ status: 'ok', at: nowIso() });
  emit({
    conclusion: `登录态有效：${auth.name || auth.vid}`,
    fields: {
      ok: 'yes',
      login: 'ok',
      name: auth.name,
      vid: auth.vid,
      source: auth.source,
      synced_at: auth.syncedAt,
      cookies: Object.keys(auth.cookies).length,
    },
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ shelf

async function cmdShelf(flags) {
  const auth = requireAuth();
  const api = apiOf(auth, flags);
  const raw = await api.shelf();
  const progress = new Map((raw.bookProgress ?? []).map(entry => [entry.bookId, shapeProgress(entry)]));
  const filter = String(flags.filter ?? 'all');
  if (!['all', 'reading', 'finished'].includes(filter)) {
    fail('usage', `--filter 只能是 all / reading / finished（收到 ${filter}）`, `${CLI} help shelf`);
  }
  let books = (raw.books ?? []).map(book => {
    const entry = progress.get(book.bookId) ?? null;
    return {
      ...shapeBook(book),
      progress: entry?.progress ?? 0,
      readingTime: entry?.readingTime ?? 0,
      finished: book.finishReading === 1 || (entry?.progress ?? 0) >= 100,
      updateTime: book.readUpdateTime || entry?.updateTime || 0,
    };
  });
  if (filter === 'reading') books = books.filter(book => book.progress > 0 && !book.finished);
  if (filter === 'finished') books = books.filter(book => book.finished);
  books.sort((a, b) => (b.updateTime ?? 0) - (a.updateTime ?? 0));
  const limit = flags.limit ?? (flags.json ? books.length : 20);
  const shown = books.slice(0, Math.max(0, limit));
  emit({
    conclusion: `书架 ${books.length} 本（${filter}）`,
    fields: {
      books: books.length,
      reading: books.filter(book => book.progress > 0 && !book.finished).length,
      finished: books.filter(book => book.finished).length,
      with_progress: [...progress.keys()].length,
    },
    items: shown.map(book => `· ${book.title}${book.author ? ` — ${book.author}` : ''} · ${book.progress}%${book.readingTime ? ` · ${formatDuration(book.readingTime)}` : ''}${book.finished ? ' · 读完' : ''}`),
    json: flags.json ? { data: { shelf: shown } } : {},
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ notes

async function cmdNotes(flags, positional) {
  const auth = requireAuth();
  const api = apiOf(auth, flags);
  const query = flags.book || positionalText(positional);
  if (!query) {
    const { shelfRaw, notebookRaw } = await requireShelfAndNotebook(api);
    const index = indexBooks(shelfRaw, notebookRaw);
    const books = [...index.values()].filter(book => book.inNotebook && book.counts).sort((a, b) => (b.counts.sort ?? 0) - (a.counts.sort ?? 0));
    const totals = books.reduce((sum, book) => ({
      notes: sum.notes + book.counts.notes,
      reviews: sum.reviews + book.counts.reviews,
      bookmarks: sum.bookmarks + book.counts.bookmarks,
    }), { notes: 0, reviews: 0, bookmarks: 0 });
    emit({
      conclusion: `笔记本 ${books.length} 本有笔记`,
      fields: { books: books.length, notes: totals.notes, reviews: totals.reviews, bookmarks: totals.bookmarks },
      items: books.map(book => `· ${book.title} · 笔记 ${book.counts.notes} · 想法 ${book.counts.reviews}`),
      json: flags.json ? { data: { books: books.map(book => ({ bookId: book.bookId, title: book.title, author: book.author, counts: book.counts })) } } : {},
      asOf: nowIso(),
    }, { json: flags.json, quiet: flags.quiet });
    return;
  }
  const { book } = await resolveBookForQuery(api, query);
  const rawHighlights = await api.highlights(book.bookId);
  const rawReviews = await api.reviews(book.bookId);
  const highlights = (rawHighlights.updated ?? []).map(shapeHighlight);
  const reviews = (rawReviews.reviews ?? []).map(shapeReview);
  const merged = mergeNotes(highlights, reviews);
  const counts = countNotes(merged);
  emit({
    conclusion: `${book.title}：划线 ${counts.highlights} · 想法 ${counts.notes}`,
    fields: { book: book.title, book_id: book.bookId, highlights: counts.highlights, notes: counts.notes },
    text: notesText(null, merged),
    json: flags.json ? { data: { book, highlights, reviews } } : {},
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ book

async function cmdBook(flags, positional) {
  const query = positionalText(positional);
  if (!query) fail('usage', '缺少书名或 bookId', `${CLI} help book`);
  const auth = requireAuth();
  const api = apiOf(auth, flags);
  const resolved = await resolveBookForQuery(api, query);
  const { book } = resolved;
  const rawInfo = await api.bookInfo(book.bookId);
  const rawChapters = await api.chapters([book.bookId]);
  const chapters = (rawChapters.data?.[0]?.updated ?? []).map(shapeChapter);
  // 裸 ID 不靠索引判定存在，但仍尽力补上这本书恰在书架中的阅读状态。
  const shelfRaw = resolved.direct ? await api.shelf() : resolved.shelfRaw;
  const progress = (shelfRaw?.bookProgress ?? []).map(shapeProgress).find(entry => entry.bookId === book.bookId) ?? null;
  const finished = book.finishReading === 1 || (progress?.progress ?? 0) >= 100;
  const details = {
    ...book,
    ...rawInfo,
    bookId: book.bookId,
    title: rawInfo.title || book.title,
    author: rawInfo.author || book.author,
    finished,
  };
  const limit = flags.limit ?? (flags.json ? chapters.length : 40);
  const shown = chapters.slice(0, Math.max(0, limit));
  emit({
    conclusion: `${details.title}${details.author ? ` — ${details.author}` : ''}`,
    fields: {
      book_id: book.bookId,
      author: details.author,
      category: rawInfo.category ?? '',
      word_count: rawInfo.totalWords ?? '',
      rating: rawInfo.newRating != null ? Math.round(rawInfo.newRating) / 10 : '',
      rating_count: rawInfo.ratingCount ?? '',
      chapters: chapters.length,
      progress: progress?.progress ?? '',
      reading_time: progress ? formatDuration(progress.readingTime) : '',
      finished: finished ? 'yes' : 'no',
      notes: book.counts?.notes ?? '',
      reviews: book.counts?.reviews ?? '',
    },
    items: shown.map(chapter => `· ${chapter.chapterIdx ?? '?'}. ${chapter.title}${chapter.wordCount ? `（${chapter.wordCount} 字）` : ''}`),
    json: flags.json ? { data: { book: details, chapters, progress } } : {},
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ search

async function cmdSearch(flags, positional) {
  const keyword = positionalText(positional);
  if (!keyword) fail('usage', '缺少搜索关键词', `${CLI} help search`);
  const auth = requireAuth();
  const api = apiOf(auth, flags);
  const raw = await api.search(keyword, flags.count ?? 5);
  const books = (raw.books ?? []).map(item => shapeBook(item.bookInfo ?? {}));
  emit({
    conclusion: `搜「${keyword}」：${books.length} 本（匹配 ${raw.totalCount ?? '?'}）`,
    fields: { keyword, books: books.length, total: raw.totalCount ?? '', parts: (raw.parts ?? []).length },
    items: books.map(book => `· ${book.title}${book.author ? ` — ${book.author}` : ''}${book.rating != null ? ` · 推荐值 ${book.rating}%` : ''}${book.wordCount ? ` · ${(book.wordCount / 10000).toFixed(1)} 万字` : ''} · ${book.bookId}`),
    json: flags.json ? { data: { books, parts: raw.parts ?? [] } } : {},
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ stats

async function cmdStats(flags) {
  const auth = requireAuth();
  const api = apiOf(auth, flags);
  const { shelfRaw, notebookRaw } = await requireShelfAndNotebook(api);
  const progress = new Map((shelfRaw.bookProgress ?? []).map(entry => [entry.bookId, shapeProgress(entry)]));
  const books = (shelfRaw.books ?? []).map(book => {
    const entry = progress.get(book.bookId) ?? null;
    return {
      ...shapeBook(book),
      progress: entry?.progress ?? 0,
      readingTime: entry?.readingTime ?? 0,
      finished: book.finishReading === 1 || (entry?.progress ?? 0) >= 100,
    };
  });
  const finished = books.filter(book => book.finished);
  const reading = books.filter(book => book.progress > 0 && !book.finished);
  const totalSeconds = books.reduce((sum, book) => sum + (book.readingTime || 0), 0);
  const notesTotals = (notebookRaw.books ?? []).reduce((sum, entry) => sum + (entry.noteCount ?? 0) + (entry.bookmarkCount ?? 0), 0);
  const top = [...books].filter(book => book.readingTime > 0).sort((a, b) => b.readingTime - a.readingTime).slice(0, flags.limit ?? 10);
  emit({
    conclusion: `读完 ${finished.length} 本 · 在读 ${reading.length} 本 · 累计 ${formatDuration(totalSeconds)}`,
    fields: {
      books: books.length,
      finished: finished.length,
      reading: reading.length,
      total_reading_seconds: totalSeconds,
      total_reading_time: formatDuration(totalSeconds),
      notes: notesTotals,
    },
    items: top.map(book => `· ${book.title} · ${formatDuration(book.readingTime)} · ${book.progress}%${book.finished ? ' · 读完' : ''}`),
    json: flags.json ? { data: { finished: finished.map(book => book.title), reading: reading.map(book => ({ title: book.title, progress: book.progress })), top } } : {},
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ export

async function cmdExport(flags, positional) {
  const query = positionalText(positional);
  if (!query && !flags.all) fail('usage', '要么给书名/bookId，要么加 --all', `${CLI} help export`);
  const outDir = resolveExportDir(flags);
  const auth = requireAuth();
  const api = apiOf(auth, flags);
  let targets;
  if (flags.all) {
    const { shelfRaw, notebookRaw } = await requireShelfAndNotebook(api);
    const index = indexBooks(shelfRaw, notebookRaw);
    const progressById = new Map((shelfRaw.bookProgress ?? []).map(entry => [entry.bookId, shapeProgress(entry)]));
    targets = [...index.values()]
      .filter(book => book.inNotebook && book.counts && (book.counts.notes + book.counts.reviews) > 0)
      .map(book => ({ ...book, progressEntry: progressById.get(book.bookId) ?? null }));
  } else {
    const { book, shelfRaw } = await resolveBookForQuery(api, query);
    const progress = (shelfRaw?.bookProgress ?? []).map(shapeProgress).find(entry => entry.bookId === book.bookId) ?? null;
    targets = [{ ...book, progressEntry: progress }];
  }
  if (!targets.length) fail('notfound', '没有可导出的笔记', `${CLI} notes 看哪些书有笔记`);
  const planned = targets.map(book => ({
    title: book.title,
    path: path.join(outDir, sanitizeName(book.title), '笔记.md'),
    notes: book.counts?.notes ?? null,
    reviews: book.counts?.reviews ?? null,
  }));
  if (flags['dry-run'] || !flags.yes) {
    emit({
      conclusion: `预览：将导出 ${planned.length} 本（加 --yes 才写文件）`,
      fields: { books: planned.length, out: outDir, dry_run: 'yes' },
      items: planned.map(plan => `· ${plan.title} → ${plan.path}${plan.notes != null ? `（笔记 ${plan.notes} · 想法 ${plan.reviews}）` : ''}`),
      json: flags.json ? { data: { planned, out: outDir } } : {},
      asOf: nowIso(),
    }, { json: flags.json, quiet: flags.quiet });
    return;
  }
  const result = await exportBooks({
    api,
    books: targets,
    outDir,
    force: Boolean(flags.force),
    exportedAt: nowIso().slice(0, 10),
    log: line => { if (!flags.quiet) console.error(line); },
  });
  if (!result.written.length && result.failed.length) {
    fail('external', `全部失败：${result.failed.map(item => item.title).join('、')}`, `看上面的失败行；登录态过期就跑 ${CLI} login`);
  }
  saveState({ lastExportAt: nowIso(), lastExportOut: outDir, lastExportCount: result.written.length });
  emit({
    conclusion: `导出完成：写入 ${result.written.length} · 跳过 ${result.skipped.length}${result.failed.length ? ` · 失败 ${result.failed.length}` : ''}`,
    fields: { out: outDir, written: result.written.length, skipped: result.skipped.length, failed: result.failed.length },
    items: result.written.map(item => `· ${item.title} → ${item.file}（划线 ${item.highlights} · 想法 ${item.notes}）`),
    json: flags.json ? { data: result } : {},
    asOf: nowIso(),
  }, { json: flags.json, quiet: flags.quiet });
}

// ------------------------------------------------------------------ 入口

async function main() {
  const argv = process.argv.slice(2);
  const command = argv[0] || 'help';
  if (command === 'help' || command === '-h' || command === '--help') {
    console.log(usageText(argv[1]));
    return;
  }
  if (!COMMANDS[command]) fail('usage', `没有这个命令：${command}`, `${CLI} help`);
  const { flags, positional } = parseFlags(argv.slice(1), COMMANDS[command].flags, { command });
  if (flags.help) {
    console.log(usageText(command));
    return;
  }
  await COMMANDS[command].run(flags, positional);
}

const isMain = (() => {
  if (!process.argv[1]) return false;
  try { return fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { return false; }
})();

if (isMain) {
  main().then(() => {
    if (process.exitCode) process.exit(process.exitCode);
  }).catch(error => reportError(error, { json: scanGlobals(process.argv.slice(2)).json }));
}
