#!/usr/bin/env node
/**
 * skill-state — 本机私有状态文件（`local/skills/<技能>/state.json`）的版本化原语（库，不是 CLI）。
 *
 * 为什么需要：状态文件随技能演进会换形状（字段改名、结构升级）。没有版本号时，
 * 升级后的技能读到老文件只能猜——猜错就静默丢数据。约定：
 *   - 每条状态都带 `_schemaVersion`；当前版本由调用方声明；
 *   - 读到的版本比当前低 → 调 migrate 升上来，升级前先备份（<file>.v<旧版本>.bak.json）；
 *   - 比当前高（用户装了更新的技能、又回退）→ 不猜、不写，返回 error='newer'；
 *   - dryRun 只报告要做的事，不落盘（迁移前先给人看）。
 *
 * 用法（技能脚本里）:
 *   import { loadState, saveState } from '../skill-interface/scripts/skill-state.mjs';
 *   const state = loadState(file, { version: 2, migrate: (data, from) => ({ data: { ...data, hits: data.count ?? 0 }, notes: [`count → hits`] }) });
 *   if (state.error) exitWithConfigHint(state);
 *   saveState(file, { ...state.data, hits: 3 });
 */
import fs from 'node:fs';
import path from 'node:path';

export const STATE_VERSION_KEY = '_schemaVersion';

const readJson = file => {
  try { return { value: JSON.parse(fs.readFileSync(file, 'utf8')), error: null }; }
  catch (error) {
    if (error.code === 'ENOENT') return { value: undefined, error: null };
    return { value: undefined, error: error.message };
  }
};

/** 原子私有写：0600 + tmp + rename（避免半截文件）。 */
export function writeStateFile(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, file);
  try { fs.chmodSync(file, 0o600); } catch { /* 某些文件系统不支持 */ }
  return file;
}

/** 备份：<file>.v<旧版本>.bak.json（保留一份，覆盖旧的同版本备份）。 */
export function backupStateFile(file, fromVersion) {
  if (!fs.existsSync(file)) return null;
  const target = `${file}.v${fromVersion ?? 'none'}.bak.json`;
  fs.copyFileSync(file, target);
  return target;
}

/**
 * 读状态并（必要时）迁移。返回:
 *   { data, version, from, migrated, notes, backup, file, existed, dryRun, error, newer }
 * error: null | 'newer' | 'unreadable' | 'migrate-failed'
 */
export function loadState(file, { version = 1, migrate = null, dryRun = false, keepBackup = true } = {}) {
  const base = { file, version, from: null, migrated: false, notes: [], backup: null, existed: false, dryRun, error: null, newer: false };
  const { value, error } = readJson(file);
  if (error) return { ...base, data: null, error: 'unreadable', message: error };
  if (value === undefined) return { ...base, data: null }; // 还没有状态文件：调用方用默认值起手
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return { ...base, data: null, error: 'unreadable', message: '状态文件不是对象' };

  const rawVersion = value[STATE_VERSION_KEY];
  const from = Number.isInteger(rawVersion) ? rawVersion : 0;
  if (from === version) return { ...base, data: value, from, existed: true };
  if (from > version) return { ...base, data: value, from, existed: true, error: 'newer', newer: true, message: `状态文件版本 ${from} 比本技能支持的 ${version} 新（技能可能被回退过）；不迁移、不覆盖` };

  let next = { ...value };
  const notes = [];
  try {
    if (migrate) {
      const result = migrate(next, from) ?? {};
      next = result.data ?? next;
      notes.push(...(result.notes ?? []));
    }
  } catch (migrationError) {
    return { ...base, data: value, from, existed: true, error: 'migrate-failed', message: migrationError.message };
  }
  next[STATE_VERSION_KEY] = version;
  const plan = { ...base, data: next, from, existed: true, migrated: true, notes };
  if (dryRun) return plan; // 只看计划：不动文件、不备份
  const backup = keepBackup ? backupStateFile(file, from) : null;
  writeStateFile(file, next);
  return { ...plan, backup };
}

/** 写状态：自动带上当前版本号。 */
export function saveState(file, data, { version = 1 } = {}) {
  return writeStateFile(file, { ...data, [STATE_VERSION_KEY]: version });
}

/** 给人/模型看的一行摘要（放进 check 命令或日志）。 */
export function describeState(result) {
  if (!result.existed) return `状态文件还没有：${result.file}（首次跑主命令时创建）`;
  if (result.error === 'newer') return `状态文件版本过新，未迁移：${result.message}`;
  if (result.error) return `状态文件读不了（${result.error}）：${result.message ?? ''}`;
  if (!result.migrated) return `状态版本 ${result.version}（无需迁移）：${result.file}`;
  const what = result.notes.length ? result.notes.join('；') : '结构升级';
  return `${result.dryRun ? '将迁移' : '已迁移'} ${result.from} → ${result.version}：${what}${result.backup ? `（备份 ${path.basename(result.backup)}）` : ''}`;
}
