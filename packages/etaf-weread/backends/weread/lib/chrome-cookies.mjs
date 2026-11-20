// 从本机浏览器（Chrome / Edge / Brave，macOS）读出某个域的 cookie。
// 解密方案与 x-social/scripts/lib/chrome-cookies.mjs 同源（D10：这是第二次出现，先按原样拷贝，
// 第三次再提取到共享库）：
//   AES-128-CBC，key = PBKDF2-HMAC-SHA1(钥匙串「<浏览器> Safe Storage」口令, "saltysalt", 1003, 16)，
//   IV = 16 个空格，密文去掉 "v10" 前缀，明文去掉开头 32 字节（Chromium 的域哈希）。
// 钥匙串口令由 /usr/bin/security 读取：第一次会弹一次授权，选「始终允许」后不再弹。
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createDecipheriv, pbkdf2Sync } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { fail } from './render.mjs';
import { cliCommand } from './cli.mjs';

const HOME = os.homedir();
export const AUTO_LOGIN_PLATFORM = 'darwin';
/** 测试钩子：把平台当成别的（验证非 macOS 时给的是可执行提示，不是堆栈）。 */
export const currentPlatform = () => process.env.WEREAD_TEST_PLATFORM || process.platform;
export const MANUAL_COOKIE_HINT = '从浏览器里抄：登录 weread.qq.com → F12 → Application → Cookies → https://weread.qq.com，'
  + `复制 wr_vid 与 wr_skey 两个值，然后 ${cliCommand()} login --cookie "wr_vid=…; wr_skey=…"`;

export const BROWSERS = [
  { id: 'chrome', label: 'Chrome', dir: path.join(HOME, 'Library/Application Support/Google/Chrome'), keychain: { service: 'Chrome Safe Storage', account: 'Chrome' } },
  { id: 'edge', label: 'Edge', dir: path.join(HOME, 'Library/Application Support/Microsoft Edge'), keychain: { service: 'Microsoft Edge Safe Storage', account: 'Microsoft Edge' } },
  { id: 'brave', label: 'Brave', dir: path.join(HOME, 'Library/Application Support/BraveSoftware/Brave-Browser'), keychain: { service: 'Brave Safe Storage', account: 'Brave' } },
];

export const browserById = (id) => BROWSERS.find(item => item.id === id);

/** 列出有 cookie 库的 profile（按 Local State 顺序，Default 在前）。 */
export function listProfiles({ browser } = {}) {
  if (currentPlatform() !== AUTO_LOGIN_PLATFORM) return [];
  const out = [];
  for (const item of BROWSERS) {
    if (browser && item.id !== browser) continue;
    if (!existsSync(item.dir)) continue;
    let profiles = [];
    try {
      const state = JSON.parse(readFileSync(path.join(item.dir, 'Local State'), 'utf8'));
      profiles = Object.keys(state?.profile?.info_cache ?? {});
    } catch { /* 没有 Local State 就退回扫目录 */ }
    if (!profiles.length) profiles = ['Default', 'Profile 1', 'Profile 2', 'Profile 3'];
    for (const profile of profiles) {
      const dbPath = ['Network/Cookies', 'Cookies'].map(rel => path.join(item.dir, profile, rel)).find(existsSync);
      if (dbPath) out.push({ browser: item.id, browserLabel: item.label, profile, dbPath });
    }
  }
  return out;
}

function copyToTemp(dbPath) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'weread-ck-'));
  const tmp = path.join(dir, 'Cookies');
  copyFileSync(dbPath, tmp);
  return tmp;
}

/** 该 profile 里某域有多少条 cookie（用来看哪个 profile 登录过）。 */
export function countDomainCookies(dbPath, domain) {
  const tmp = copyToTemp(dbPath);
  try {
    const raw = execFileSync('sqlite3', [tmp, `select count(*) from cookies where host_key like '%${domain}%';`], { encoding: 'utf8' }).trim();
    return Number(raw || 0);
  } catch {
    return 0;
  } finally {
    rmSync(path.dirname(tmp), { recursive: true, force: true });
  }
}

const keyCache = new Map();
/** 钥匙串里的 Safe Storage 口令（第一次会弹授权框；之后系统记住）。 */
export function safeStoragePassword({ service, account }) {
  if (currentPlatform() !== AUTO_LOGIN_PLATFORM) {
    fail('platform', `自动读浏览器 cookie 只有 macOS 上实现了（当前平台 ${currentPlatform()}）`, MANUAL_COOKIE_HINT, { needHuman: true });
  }
  if (keyCache.has(service)) return keyCache.get(service);
  // 测试/自动化用：跳过钥匙串，直接用给定口令（见 tests/）
  const injected = process.env.WEREAD_TEST_SAFE_STORAGE_PASSWORD;
  let password = injected;
  if (!password) {
    try {
      password = execFileSync('security', ['find-generic-password', '-w', '-s', service, '-a', account], { encoding: 'utf8' }).trim();
    } catch (error) {
      fail('deps', `读不到钥匙串口令「${service}」：${String(error.stderr ?? error.message).trim().slice(0, 200)}`,
        `在弹窗上点「始终允许」；或改用内置扫码登录：${cliCommand()} login`);
    }
  }
  if (!password) fail('deps', `钥匙串条目「${service}」是空的`, `或改用内置扫码登录：${cliCommand()} login`);
  keyCache.set(service, password);
  return password;
}

function deriveKey(password) {
  return pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
}

/** v10/v11 密文 → 明文；非 v10 前缀按明文处理。 */
export function decryptCookieValue(buf, key) {
  const head = buf.subarray(0, 3).toString('latin1');
  if (head !== 'v10' && head !== 'v11') return buf.toString('utf8');
  const decipher = createDecipheriv('aes-128-cbc', key, Buffer.alloc(16, ' '));
  const plain = Buffer.concat([decipher.update(buf.subarray(3)), decipher.final()]);
  // Chromium macOS：明文前 32 字节是域哈希；极老版本没有前缀，按可打印性兜底判断。
  if (plain.length > 32) return plain.subarray(32).toString('utf8');
  return plain.toString('utf8');
}

/**
 * 读出一个 profile 里某域的 cookie。
 * @returns {{cookies: Record<string,string>, count: number, profile: string, failed: string[]}|null} 没有 Cookie 库时 null
 */
export function readChromeCookies({ domain, browser = 'chrome', profile = '' }) {
  const target = listProfiles({ browser }).find(item => (profile ? item.profile === profile : true));
  if (!target) return null;
  const item = browserById(target.browser) ?? BROWSERS[0];
  const password = safeStoragePassword(item.keychain);
  const key = deriveKey(password);
  const tmp = copyToTemp(target.dbPath);
  let rows;
  try {
    const raw = execFileSync('sqlite3', ['-json', tmp,
      `select name, host_key, value, hex(encrypted_value) as enc from cookies where host_key like '%${domain}%' order by length(host_key) desc;`],
      { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
    rows = JSON.parse(raw || '[]');
  } catch (error) {
    fail('deps', `读 cookie 库失败：${String(error.stderr ?? error.message).trim().slice(0, 200)}`, '确认 sqlite3 可用：which sqlite3');
  } finally {
    rmSync(path.dirname(tmp), { recursive: true, force: true });
  }
  const cookies = {};
  const failed = [];
  for (const row of rows) {
    if (cookies[row.name] !== undefined) continue; // 同名只取一次（更具体的域优先，见 order by）
    try {
      if (row.value) { cookies[row.name] = row.value; continue; }
      if (!row.enc) continue;
      cookies[row.name] = decryptCookieValue(Buffer.from(row.enc, 'hex'), key);
    } catch (error) {
      failed.push(`${row.name}: ${error.message}`);
    }
  }
  return { cookies, count: Object.keys(cookies).length, profile: target.profile, browser: target.browser, failed };
}
