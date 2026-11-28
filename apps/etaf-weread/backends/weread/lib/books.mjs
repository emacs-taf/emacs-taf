// 书目索引与书名解析：书架（/web/shelf/sync） + 笔记本（/api/user/notebook）两份数据合起来用。
import { shapeBook } from './api.mjs';
import { fail } from './render.mjs';
import { cliCommand } from './cli.mjs';

/** 裸 bookId 可以不在书架或笔记本里：数字，或微信读书的 CB_ 编码 ID。 */
export function bookIdFromQuery(query) {
  const value = String(query ?? '').trim();
  return /^(?:\d+|CB_[A-Za-z0-9_-]+)$/.test(value) ? value : null;
}

/** 不查本地索引时的最小书目；详情接口会补全 title/author。 */
export const bookFromId = (bookId) => ({ bookId, title: bookId, author: '', inShelf: false, inNotebook: false });

/** 书架条目的 finishReading 才是用户读完状态，保留给 book 命令判定。 */
export function indexBooks(shelfRaw = {}, notebookRaw = {}) {
  const map = new Map();
  const put = (id, patch) => map.set(id, { ...(map.get(id) ?? {}), ...patch });
  for (const book of shelfRaw.books ?? []) {
    put(book.bookId, { ...shapeBook(book), finishReading: book.finishReading ?? 0, inShelf: true });
  }
  for (const entry of notebookRaw.books ?? []) {
    const book = entry.book ?? {};
    put(book.bookId, {
      ...(map.get(book.bookId) ? {} : { ...shapeBook(book), inShelf: false }),
      inNotebook: true,
      counts: {
        notes: entry.noteCount ?? 0,      // 「笔记」= 划线及其附着想法（≈ bookmarklist 条数）
        bookmarks: entry.bookmarkCount ?? 0, // 「书签」= 阅读器里加的页书签，与划线无关
        reviews: entry.reviewCount ?? 0,  // 「想法/点评」
        sort: entry.sort ?? 0,
      },
    });
  }
  return map;
}

/** 精确 bookId > 完整书名 > 子串（书名或作者）。 */
export function findBooks(index, query) {
  const list = [...index.values()];
  const needle = String(query ?? '').trim();
  if (!needle) return [];
  const byId = list.filter(book => book.bookId === needle);
  if (byId.length) return byId;
  const byTitle = list.filter(book => book.title === needle);
  if (byTitle.length) return byTitle;
  return list.filter(book => String(book.title ?? '').includes(needle) || String(book.author ?? '').includes(needle));
}

export function requireBook(index, query) {
  const hits = findBooks(index, query);
  if (!hits.length) {
    fail('notfound', `书架/笔记本里没有「${query}」`, `${cliCommand()} search <关键词> 先搜书城；或直接传 bookId（纯数字或 CB_ 开头）`);
  }
  if (hits.length > 1) {
    fail('conflict', `「${query}」匹配到 ${hits.length} 本：${hits.slice(0, 4).map(book => book.title).join(' / ')}`, '写更完整的书名，或直接用 bookId');
  }
  return hits[0];
}
