// 输出与错误契约：首行结论 + 稳定 k=v（或 --json 等价 JSON），错误按封闭错误码。
//
// 退出码约定：2 = 用法错（调用方看 help 就能修），3 = 执行失败。
import process from 'node:process';

export const EXIT = { usage: 2, fail: 3 };
export const ERROR_CODES = ['usage', 'deps', 'platform', 'auth', 'config', 'notfound', 'conflict', 'blocked', 'timeout', 'external', 'internal'];

export class SkillError extends Error {
  constructor(code, message, { hint = '', needHuman = false, asks = [], extraLines = [] } = {}) {
    super(message);
    this.code = code;
    this.hint = hint;
    this.needHuman = needHuman;
    this.asks = asks;
    this.extraLines = extraLines;
  }
}

export function fail(code, message, hint = '', extra = {}) {
  throw new SkillError(code, message, { hint, ...extra });
}

/** 读取类输出统一带 as_of：只留到秒的 UTC ISO（机器可判、人不困惑）。 */
export function nowIso() {
  return `${new Date().toISOString().slice(0, 19)}Z`;
}

/** 值 → key=value 里的字符串（单行，空值给 "-"）。 */
export function cell(value) {
  if (value === undefined || value === null || value === '') return '-';
  if (value === true || value === false) return String(value);
  return String(value).replace(/[\r\n\t]+/g, ' ').trim();
}

function coerce(value) {
  if (value === 'true') return true;
  if (value === 'false') return false;
  if (/^-?\d+$/.test(String(value)) && String(value).length < 12) return Number(value);
  return value;
}

/**
 * 打印结果：{ conclusion, fields, items, text, json, source, asOf }
 * human: 结论行 → k=v 行 → items 行 → text 块 → source= / as_of=
 */
export function emit(report, { json = false, quiet = false, source = 'weread.qq.com' } = {}) {
  const { conclusion = '', fields = {}, items = [], text = '', json: rich = {}, asOf = '' } = report;
  const origin = report.source ?? source ?? '';
  const payload = {
    ok: true,
    conclusion,
    ...Object.fromEntries(Object.entries(fields)
      .filter(([, value]) => value !== undefined && value !== null && value !== '')
      .map(([key, value]) => [key, coerce(String(value))])),
    ...(items.length ? { items } : {}),
    ...(rich ?? {}),
    source: origin,
    ...(asOf ? { as_of: asOf } : {}),
  };
  if (json) {
    console.log(JSON.stringify(payload, null, 2));
    return;
  }
  if (quiet) return;
  if (conclusion) console.log(conclusion);
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined || value === null || value === '') continue;
    console.log(`${key}=${cell(value)}`);
  }
  for (const item of items) console.log(item);
  if (text) console.log(text);
  console.log(`source=${origin}`);
  if (asOf) console.log(`as_of=${asOf}`);
}

/** 错误 → 封闭错误码 + 可执行 hint；人读走 stderr，--json 走 stdout。 */
export function reportError(error, { json = false } = {}) {
  const code = error instanceof SkillError ? error.code : 'internal';
  const message = error?.message ?? String(error);
  const hint = error?.hint ?? '';
  const needHuman = error?.needHuman === true;
  const asks = (error?.asks ?? []).filter(Boolean);
  const extraLines = (error?.extraLines ?? []).filter(Boolean);
  if (json) {
    console.log(JSON.stringify({
      ok: false,
      error: code,
      message,
      ...(asks.length ? { ask: asks } : {}),
      ...(hint ? { hint } : {}),
      ...(needHuman ? { need: 'human' } : {}),
      ...(extraLines.length ? { detail: extraLines } : {}),
    }, null, 2));
  } else {
    console.error(`error=${code} ${message}`);
    for (const ask of asks) console.error(`ask="${ask}"`);
    for (const line of extraLines) console.error(line);
    if (hint) console.error(`hint=${hint}`);
    if (needHuman) console.error('need=human');
  }
  process.exitCode = code === 'usage' ? EXIT.usage : EXIT.fail;
  return process.exitCode;
}
