// 导出：划线/想法 → Markdown。含单写入者锁、断点续跑（resume）、写后回读。
import fs from 'node:fs';
import path from 'node:path';
import { fail } from './render.mjs';
import { shapeHighlight, shapeReview, formatDuration } from './api.mjs';
import { mergeNotes } from './notes.mjs';

export const EXPORT_FILE = '笔记.md';
export const LOCK_NAME = '.weread-export.lock';
const LOCK_STALE_MS = 30 * 60 * 1000;

export const sanitizeName = (name) => String(name ?? '')
  .replace(/[/\\:*?"<>|]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim()
  .slice(0, 80) || '未命名';

const pidAlive = (pid) => {
  try { process.kill(pid, 0); return true; } catch (error) { return error?.code === 'EPERM'; }
};

/** 取单写入者锁（lockfile）；同目录已有活锁 → error=conflict。返回释放函数。 */
export function acquireLock(outDir) {
  const file = path.join(outDir, LOCK_NAME);
  fs.mkdirSync(outDir, { recursive: true });
  let existing = null;
  try { existing = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* 没有或坏了都当没有 */ }
  if (existing?.pid && pidAlive(existing.pid) && Date.now() - Number(existing.at ?? 0) < LOCK_STALE_MS) {
    fail('conflict', `导出目录正被另一个进程占用（pid=${existing.pid}）`, `等它结束；确认没在跑就删掉 ${file}`);
  }
  fs.writeFileSync(file, `${JSON.stringify({ pid: process.pid, at: Date.now() })}\n`, { mode: 0o600 });
  return () => fs.rmSync(file, { force: true });
}

export function countNotes(merged) {
  let highlights = 0;
  let notes = merged.loose.length;
  for (const chapter of merged.chapters) {
    highlights += chapter.items.length;
    for (const item of chapter.items) notes += item.notes.length;
  }
  return { highlights, notes };
}

/** 一本书的 Markdown：元信息 + 按章分组的划线/想法。 */
export function buildBookMarkdown({ book, merged, progress = null, exportedAt = '' }) {
  const lines = [`# ${book.title}`, ''];
  if (book.author) lines.push(`- 作者：${book.author}`);
  const link = book.deepLink || '';
  if (link) lines.push(`- 来源：微信读书 ${link}`);
  if (book.category) lines.push(`- 分类：${book.category}${book.wordCount ? ` · ${(book.wordCount / 10000).toFixed(1)} 万字` : ''}`);
  if (progress) {
    const parts = [`${progress.progress ?? 0}%`];
    if (progress.chapterIdx) parts.push(`第 ${progress.chapterIdx} 章`);
    if (progress.readingTime) parts.push(`阅读 ${formatDuration(progress.readingTime)}`);
    lines.push(`- 我的进度：${parts.join(' · ')}`);
  }
  const counts = countNotes(merged);
  lines.push(`- 划线 ${counts.highlights} 条 · 想法 ${counts.notes} 条`);
  if (exportedAt) lines.push(`- 导出时间：${exportedAt}`);
  lines.push('');
  for (const chapter of merged.chapters) {
    lines.push(`## ${chapter.chapterName || (chapter.chapterIdx ? `第 ${chapter.chapterIdx} 章` : '未分章')}`, '');
    for (const item of chapter.items) {
      const markLines = String(item.highlight.markText ?? '').split('\n');
      if (markLines.length === 1) {
        lines.push(`- **${markLines[0]}**`);
      } else {
        lines.push(`- ${markLines[0]}`);
        for (const line of markLines.slice(1)) lines.push(`  ${line}`);
      }
      const context = String(item.highlight.contextAbstract ?? '').trim();
      if (context) for (const part of context.split('\n')) lines.push(`  > ${part}`);
      for (const note of item.notes) {
        lines.push(`  - 想法${note.createTime ? `（${new Date(note.createTime * 1000).toISOString().slice(0, 10)}）` : ''}：${note.content || note.abstract || note.drawing || '（手绘）'}`);
      }
    }
    lines.push('');
  }
  if (merged.loose.length) {
    lines.push('## 其他想法', '');
    for (const note of merged.loose) {
      lines.push(`- ${note.content || note.abstract || note.drawing || '（手绘）'}${note.createTime ? `（${new Date(note.createTime * 1000).toISOString().slice(0, 10)}）` : ''}`);
    }
    lines.push('');
  }
  return `${lines.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd()}\n`;
}

/**
 * 逐本导出。默认断点续跑（resume）：目标文件已存在就跳过，--force 才重写；
 * 单写入者锁在入口 acquireLock；每本书失败只记一笔，不拖垮批量。
 */
export async function exportBooks({ api, books, outDir, force = false, exportedAt = '', log = () => {} }) {
  const release = acquireLock(outDir);
  const result = { out: outDir, written: [], skipped: [], failed: [] };
  try {
    for (const book of books) {
      const dir = path.join(outDir, sanitizeName(book.title));
      const file = path.join(dir, EXPORT_FILE);
      if (!force && fs.existsSync(file)) {
        result.skipped.push(book.title);
        log(`skip ${path.relative(outDir, file)}（已存在，断点续跑；--force 重导）`);
        continue;
      }
      try {
        const rawHighlights = await api.highlights(book.bookId);
        const rawReviews = await api.reviews(book.bookId);
        const merged = mergeNotes(
          (rawHighlights.updated ?? []).map(shapeHighlight),
          (rawReviews.reviews ?? []).map(shapeReview),
        );
        const markdown = buildBookMarkdown({ book, merged, progress: book.progressEntry ?? null, exportedAt });
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(file, markdown, 'utf8');
        const back = fs.readFileSync(file, 'utf8'); // 写后回读，防止「报了成功其实没写」
        if (!back.includes(book.title)) fail('internal', `写入后回读校验失败：${file}`, '重跑；持续失败报维护者');
        const counts = countNotes(merged);
        result.written.push({ title: book.title, file, highlights: counts.highlights, notes: counts.notes });
        log(`write ${path.relative(outDir, file)}（划线 ${counts.highlights} · 想法 ${counts.notes}）`);
      } catch (error) {
        result.failed.push({ title: book.title, error: `${error?.code ?? 'internal'}: ${error?.message ?? error}` });
        log(`fail ${book.title}：${error?.code ?? 'internal'}: ${error?.message ?? error}`);
      }
    }
  } finally {
    release();
  }
  return result;
}
