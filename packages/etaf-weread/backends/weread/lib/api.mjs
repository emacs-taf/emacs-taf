// 微信读书网页接口客户端：只做「请求 → JSON」，业务判断在各命令里。
// 关键事实（2026-09 实测，见 REFERENCE.md「接口地图」）：
//   - 只需要登录 cookie；x-wrpa-* 签名头对这些接口不是必需；
//   - 但 /web/book/bookmarklist 对 Referer 敏感：带站点首页 Referer 会静默返回空，
//     所以这里统一不发 Referer。
import { fail } from './render.mjs';
import { cliCommand } from './cli.mjs';

const DEFAULT_BASE = 'https://weread.qq.com';
const DEFAULT_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';

// 测试钩子：WEREAD_API_BASE 指向假后端（见 tests/），不改生产行为。
export const baseUrl = () => process.env.WEREAD_API_BASE || DEFAULT_BASE;

const sleep = (ms) => new Promise(resolve => { setTimeout(resolve, ms); });

const hasNonzeroErrCode = (json) => {
  if (!json || typeof json !== 'object' || !Object.hasOwn(json, 'errCode')) return false;
  const code = Number(json.errCode);
  return Number.isFinite(code) ? code !== 0 : Boolean(json.errCode);
};

const isExpiredLogin = (errCode, errMsg) => (
  Number(errCode) === -2012
  || /(?:登录|登陆).*?(?:超时|过期|失效|无效)|(?:login|session).*?(?:timeout|expired|invalid)|(?:timeout|expired|invalid).*?(?:login|session)/i.test(String(errMsg ?? ''))
);

const failBackendErrCode = (json) => {
  const errCode = json.errCode;
  const errMsg = String(json.errMsg ?? json.message ?? '').trim() || '-';
  const message = `微信读书接口错误（errCode=${errCode}，errMsg=${errMsg}）`;
  if (isExpiredLogin(errCode, errMsg)) {
    fail('auth', message, `${cliCommand()} login 重新取一次登录态`, { needHuman: true });
  }
  fail('external', message, '稍后重试；持续失败看 REFERENCE.md 的「接口变更」一节');
};

export class WereadApi {
  constructor({ cookie = '', ua = '', timeoutMs = 15000, minIntervalMs = 250, retries = 2 } = {}) {
    this.cookie = cookie;
    this.ua = ua || DEFAULT_UA;
    this.timeoutMs = timeoutMs;
    this.minIntervalMs = minIntervalMs;
    this.retries = retries;
    this.nextAt = 0;
    this.calls = 0;
  }

  async #throttle() {
    const wait = this.nextAt - Date.now();
    if (wait > 0) await sleep(wait);
    this.nextAt = Date.now() + this.minIntervalMs;
  }

  /** 一次请求（带节流 + 超时 + 重试）；错误一律转成封闭错误码。 */
  async request(method, pathname, { body, retries = this.retries } = {}) {
    let attempt = 0;
    for (;;) {
      await this.#throttle();
      this.calls += 1;
      let response;
      try {
        response = await fetch(`${baseUrl()}${pathname}`, {
          method,
          headers: {
            cookie: this.cookie,
            'user-agent': this.ua,
            accept: 'application/json, text/plain, */*',
            ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
          },
          ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
          signal: AbortSignal.timeout(this.timeoutMs),
        });
      } catch (error) {
        if (attempt < retries) { attempt += 1; await sleep(400 * attempt); continue; }
        if (error?.name === 'TimeoutError' || error?.name === 'AbortError') {
          fail('timeout', `请求超时（${Math.round(this.timeoutMs / 1000)}s）：${pathname}`, '网络慢或站点不可达；稍后重试，或检查本机网络出口');
        }
        fail('external', `请求失败：${pathname}（${error?.message ?? error}）`, '稍后重试；持续失败看 REFERENCE.md 的「接口变更」一节');
      }
      const text = await response.text();
      let json = null;
      try { json = JSON.parse(text); } catch { /* 非 JSON 在下面统一处理 */ }
      if (response.status === 401 || json?.statusCode === 401 || /LOGIN ERR/i.test(String(json?.statusMessage ?? json?.message ?? ''))) {
        fail('auth', '微信读书登录态无效（401 LOGIN ERR）', `${cliCommand()} login 重新取一次登录态`, { needHuman: true });
      }
      if (response.status === 404) {
        fail('notfound', `接口不存在（404）：${pathname}`, '可能是接口改版；看 REFERENCE.md 的「接口变更」，或把这条报给维护者');
      }
      if (response.status === 429 || response.status >= 500) {
        if (attempt < retries) { attempt += 1; await sleep(700 * attempt); continue; }
        fail('external', `站点返回 ${response.status}：${pathname}`, '稍后重试；持续失败可能是风控限流');
      }
      if (!response.ok) {
        fail('external', `站点返回 ${response.status}：${pathname}`, '稍后重试；持续失败看 REFERENCE.md');
      }
      if (json === null) {
        if (text.trim() === '') return {};
        fail('external', `响应不是 JSON：${pathname}`, `响应开头：${text.slice(0, 80).replace(/\s+/g, ' ')}`);
      }
      if (hasNonzeroErrCode(json)) failBackendErrCode(json);
      return json;
    }
  }

  authCheck() { return this.request('GET', '/api/user/config'); }
  me(vid) { return this.request('GET', `/web/user?userVid=${encodeURIComponent(vid)}`); }
  shelf() { return this.request('GET', '/web/shelf/sync'); }
  notebook() { return this.request('GET', '/api/user/notebook'); }
  bookInfo(bookId) { return this.request('GET', `/web/book/info?bookId=${encodeURIComponent(bookId)}`); }
  chapters(bookIds) { return this.request('POST', '/web/book/chapterInfos', { body: { bookIds } }); }
  highlights(bookId) { return this.request('GET', `/web/book/bookmarklist?bookId=${encodeURIComponent(bookId)}&syncKey=0`); }
  reviews(bookId, listType = 11) {
    return this.request('GET', `/web/review/list?bookId=${encodeURIComponent(bookId)}&listType=${listType}&listMode=3&syncKey=0&mine=1`);
  }
  readInfo(bookId) {
    return this.request('GET', `/web/book/readInfo?bookId=${encodeURIComponent(bookId)}&finishedBookCount=1&finishedBookIndex=1&finishedDate=1`);
  }
  search(keyword, count = 5) {
    return this.request('GET', `/web/search/global?keyword=${encodeURIComponent(keyword)}&maxIdx=0&fragmentSize=120&count=${count}`);
  }
}

// ------------------------------------------------------------------ 数据整形（字段跨版本稳定）

export const shapeBook = (book = {}) => ({
  bookId: book.bookId ?? '',
  title: book.title ?? '',
  author: book.author ?? '',
  cover: book.cover ?? '',
  format: book.format ?? '',
  category: book.category ?? '',
  wordCount: book.totalWords ?? null,
  rating: typeof book.newRating === 'number' ? Math.round(book.newRating) / 10 : null,
  ratingCount: book.ratingCount ?? null,
  encodeId: book.encodeId ?? '',
  deepLink: book.deepLink ?? '',
  updateTime: book.updateTime ?? null,
  finished: book.finished ?? null,
});

export const shapeProgress = (entry = {}) => ({
  bookId: entry.bookId ?? '',
  progress: entry.progress ?? 0,
  readingTime: entry.readingTime ?? 0,
  chapterUid: entry.chapterUid ?? null,
  chapterIdx: entry.chapterIdx ?? null,
  updateTime: entry.updateTime ?? null,
});

export const shapeHighlight = (item = {}) => ({
  bookmarkId: item.bookmarkId ?? '',
  chapterUid: item.chapterUid ?? null,
  chapterName: item.chapterName ?? '',
  chapterIdx: item.chapterIdx ?? null,
  range: item.range ?? '',
  markText: item.markText ?? '',
  contextAbstract: item.contextAbstract ?? '',
  colorStyle: item.colorStyle ?? null,
  createTime: item.createTime ?? 0,
});

export const shapeReview = (entry = {}) => {
  const review = entry.review ?? {};
  return {
    reviewId: entry.reviewId ?? '',
    content: review.content ?? '',
    abstract: review.abstract ?? '',
    range: review.range ?? '',
    chapterUid: review.chapterUid ?? null,
    chapterName: review.chapterName ?? '',
    createTime: review.createTime ?? 0,
    drawing: review.pencilNote ? (review.pencilNote.imageUrl ?? '') : '',
  };
};

export const shapeChapter = (chapter = {}) => ({
  chapterUid: chapter.chapterUid ?? null,
  chapterIdx: chapter.chapterIdx ?? null,
  title: chapter.title ?? '',
  level: chapter.level ?? 1,
  wordCount: chapter.wordCount ?? null,
  price: chapter.price ?? null,
  paid: chapter.paid ?? null,
});

/** unix 秒 → YYYY-MM-DD（UTC，稳定可对比）。 */
export const dateOf = (seconds) => (seconds ? new Date(seconds * 1000).toISOString().slice(0, 10) : '');

/** 秒 → 「1小时9分」。 */
export const formatDuration = (seconds) => {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (hours && minutes) return `${hours}小时${minutes}分`;
  if (hours) return `${hours}小时`;
  return `${minutes}分`;
};
