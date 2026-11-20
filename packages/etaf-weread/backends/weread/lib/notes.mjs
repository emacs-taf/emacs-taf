// 划线 + 想法的合并与呈现：笔记命令与导出共用。
// 数据来源：/web/book/bookmarklist（划线，updated[]） + /web/review/list（我的想法，reviews[]）。
const rangeStart = (range) => Number(String(range ?? '').split('-')[0]) || 0;

/**
 * 想法按 range 挂到对应划线上；挂不上的进 loose（例如手绘笔记、整章点评）。
 * @returns {{chapters: Array<{chapterUid, chapterName, chapterIdx, items: Array<{highlight, notes}>}>, loose: Array}}
 */
export function mergeNotes(highlights = [], reviews = []) {
  const items = highlights.map(highlight => ({ highlight, notes: [] }));
  const loose = [];
  for (const review of reviews) {
    const match = items.find(item => item.highlight.range && review.range && item.highlight.range === review.range);
    if (match) match.notes.push(review);
    else loose.push(review);
  }
  const chapters = new Map();
  for (const item of items) {
    const key = item.highlight.chapterUid ?? item.highlight.chapterName ?? 'unknown';
    if (!chapters.has(key)) {
      chapters.set(key, {
        chapterUid: item.highlight.chapterUid,
        chapterName: item.highlight.chapterName,
        chapterIdx: item.highlight.chapterIdx,
        items: [],
      });
    }
    chapters.get(key).items.push(item);
  }
  const grouped = [...chapters.values()].sort((a, b) => (a.chapterIdx ?? 0) - (b.chapterIdx ?? 0));
  for (const chapter of grouped) chapter.items.sort((a, b) => rangeStart(a.highlight.range) - rangeStart(b.highlight.range));
  return { chapters: grouped, loose };
}

/** 终端列表示（notes 命令的人读输出）。 */
export function notesText(book, merged) {
  const lines = [];
  if (book) lines.push(`${book.title}${book.author ? ` — ${book.author}` : ''}`);
  let count = 0;
  for (const chapter of merged.chapters) {
    lines.push('', `## ${chapter.chapterName || (chapter.chapterIdx ? `第${chapter.chapterIdx}章` : '未分章')}`);
    for (const item of chapter.items) {
      count += 1;
      lines.push(`- ${item.highlight.markText}${item.highlight.contextAbstract ? `\n  > ${item.highlight.contextAbstract.replace(/\n/g, '\n  > ')}` : ''}`);
      for (const note of item.notes) lines.push(`  · 想法：${note.content || note.abstract || note.drawing || '(手绘)'}`);
    }
  }
  for (const note of merged.loose) {
    count += 1;
    lines.push('', `- （未挂在划线上）${note.content || note.abstract || note.drawing || '(手绘)'}`);
  }
  if (!count) lines.push('（这本书还没有划线或想法）');
  return lines.join('\n');
}
