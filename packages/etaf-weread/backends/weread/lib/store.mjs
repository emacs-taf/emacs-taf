// 本机私有数据：登录态（auth.json，0600）、巡检状态（state.json）、配置（config.json）。
// 默认放在 XDG 数据目录下的 `etaf-weread/`，ETAF_WEREAD_HOME 可以把它整体挪到别处
// （测试与多账号用）。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fail } from './render.mjs';
import { cliCommand } from './cli.mjs';

export const dataDir = () => process.env.ETAF_WEREAD_HOME
  || path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share'), 'etaf-weread');
export const authPath = () => path.join(dataDir(), 'auth.json');
export const statePath = () => path.join(dataDir(), 'state.json');
export const configPath = () => path.join(dataDir(), 'config.json');

const readJson = (file) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
};

/** 原子私有写：0600 + tmp + rename（避免半截文件）。 */
function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file);
  try { fs.chmodSync(file, 0o600); } catch { /* 某些文件系统不支持 */ }
}

/** 登录态：{ cookies, ua, name, vid, avatar, source, syncedAt, verifiedAt }。 */
export const loadAuth = () => readJson(authPath());

/** 写登录态：0600，写完回读校验（读不回来就当写失败）。 */
export function saveAuth(auth) {
  writeJson(authPath(), auth);
  const back = loadAuth();
  if (!back?.cookies || Object.keys(back.cookies).length === 0) {
    fail('internal', `登录态写入后读不回来：${authPath()}`,
         `检查 ${dataDir()} 的磁盘权限后重跑 ${cliCommand()} login`);
  }
  return back;
}

export function clearAuth() {
  fs.rmSync(authPath(), { force: true });
}

/** 巡检/上次动作状态：只放少量字段（status/at/lastExport...）。 */
export const loadState = () => readJson(statePath()) ?? {};

export function saveState(patch) {
  const next = { ...loadState(), ...patch };
  writeJson(statePath(), next);
  return next;
}

/** cookie 串：给 HTTP 请求用（按名字排序，稳定可对比）。 */
export function cookieHeader(auth) {
  const cookies = auth?.cookies ?? {};
  return Object.keys(cookies).sort().map(name => `${name}=${cookies[name]}`).join('; ');
}

const expandHome = (value) => {
  const text = String(value ?? '').trim();
  if (text === '~') return os.homedir();
  if (text.startsWith('~/')) return path.join(os.homedir(), text.slice(2));
  return text;
};

/** 配置：config.json 的键值，CLI/环境变量在各自的读取处优先。 */
export const loadConfig = () => readJson(configPath()) ?? {};

/** 导出根目录：CLI --out > ETAF_WEREAD_EXPORT_DIR > config.json 的 exportDir > 数据目录的 exports/。 */
export function resolveExportDir(flags = {}) {
  const dir = expandHome(flags.out || process.env.ETAF_WEREAD_EXPORT_DIR || loadConfig().exportDir
    || path.join(dataDir(), 'exports'));
  if (!dir) {
    fail('config', '导出目录没有解析出来', `加 --out <目录>，或在 ${configPath()} 里设置 exportDir`);
  }
  return dir;
}
