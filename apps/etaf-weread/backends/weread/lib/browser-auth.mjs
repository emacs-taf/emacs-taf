// 扫码登录：自己拉起一个本机 Chromium 系浏览器（包内独立 profile + 调试端口），
// 打开微信读书登录页并从 CDP 读回 cookie。不依赖 Pi 技能、cdp-channel.mjs 或任何
// 外部脚本；机器上有 Chrome / Edge / Brave / Chromium 之一即可。
//
// 只做浏览器侧的最小机制：启动、开关标签页、点「登录」、读 cookie。
// 登录成功与否由调用方用业务接口验证。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { dataDir } from './store.mjs';
import { fail } from './render.mjs';

const WEREAD_SUFFIX = 'weread.qq.com';
const LOGIN_URL = 'https://weread.qq.com/';
const sleep = (ms) => new Promise(resolve => { setTimeout(resolve, ms); });

const profileDir = () => path.join(dataDir(), 'login-browser');
const portFile = () => path.join(profileDir(), 'DevToolsActivePort');

/** 浏览器候选：WEREAD_BROWSER 优先，其次各平台常见安装位置。 */
function browserCandidates() {
  const home = process.env.HOME || process.env.USERPROFILE || '';
  const local = process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
  const programFiles = [process.env.ProgramFiles, process.env['ProgramFiles(x86)']].filter(Boolean);
  const windows = (relative) => programFiles.map(base => path.join(base, relative));
  if (process.platform === 'darwin') {
    return [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    ];
  }
  if (process.platform === 'win32') {
    return [
      ...windows('Google\\Chrome\\Application\\chrome.exe'),
      ...windows('Microsoft\\Edge\\Application\\msedge.exe'),
      ...windows('BraveSoftware\\Brave-Browser\\Application\\brave.exe'),
      path.join(local, 'Chromium\\Application\\chrome.exe'),
    ];
  }
  return [
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/usr/bin/microsoft-edge',
    '/usr/bin/brave-browser',
    '/snap/bin/chromium',
  ];
}

function isExecutable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** 找一台能开调试端口的浏览器；找不到返回 null。 */
export function findBrowser() {
  const explicit = String(process.env.WEREAD_BROWSER ?? '').trim();
  if (explicit) return isExecutable(explicit) ? explicit : null;
  return browserCandidates().find(isExecutable) ?? null;
}

const readPort = () => {
  try {
    return String(fs.readFileSync(portFile(), 'utf8')).split('\n')[0].trim() || null;
  } catch {
    return null;
  }
};

/** 登录浏览器的版本信息（含 UA），没在跑返回 null。 */
async function browserVersion() {
  const port = readPort();
  if (!port) return null;
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/version`,
                                 { signal: AbortSignal.timeout(3000) });
    if (!response.ok) return null;
    const info = await response.json();
    return info?.webSocketDebuggerUrl ? info : null;
  } catch {
    return null;
  }
}

/** 极简 CDP 客户端：一条 WebSocket，命令按 id 配对；不用事件。 */
class Cdp {
  constructor(url) {
    if (typeof WebSocket !== 'function') {
      fail('deps', '当前 Node.js 没有内置 WebSocket',
           '升级到 Node.js 22.4 或更新；或改用 --from-chrome / --cookie 登录', { needHuman: true });
    }
    this.url = url;
    this.socket = null;
    this.nextId = 1;
    this.pending = new Map();
  }

  open() {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(this.url);
      this.socket = socket;
      const timer = setTimeout(() => reject(new Error('CDP 连接超时')), 10000);
      socket.addEventListener('open', () => { clearTimeout(timer); resolve(); });
      socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('CDP 连接失败')); });
      socket.addEventListener('message', (event) => {
        let payload;
        try { payload = JSON.parse(event.data); } catch { return; }
        if (!payload.id) return;
        const entry = this.pending.get(payload.id);
        if (!entry) return;
        this.pending.delete(payload.id);
        clearTimeout(entry.timer);
        if (payload.error) entry.reject(new Error(payload.error.message || 'CDP 命令失败'));
        else entry.resolve(payload.result ?? {});
      });
    });
  }

  send(method, params = {}, sessionId = undefined) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP 命令超时：${method}`));
      }, 15000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params,
                                        ...(sessionId ? { sessionId } : {}) }));
    });
  }

  close() {
    try { this.socket?.close(); } catch { /* 已关闭 */ }
  }
}

/** 连上登录浏览器执行 FN；没在跑返回 null。 */
async function withBrowser(fn) {
  const info = await browserVersion();
  if (!info) return null;
  const cdp = new Cdp(info.webSocketDebuggerUrl);
  await cdp.open();
  try {
    return await fn(cdp, info);
  } finally {
    cdp.close();
  }
}

/** 读登录浏览器里 weread.qq.com 的 cookie（含 HttpOnly 值）+ 浏览器 UA；没在跑返回 null。 */
export async function readBrowserAuth() {
  return withBrowser(async (cdp, info) => {
    const { cookies } = await cdp.send('Storage.getCookies', {}, undefined);
    const jar = {};
    for (const cookie of cookies || []) {
      const host = String(cookie.domain ?? '').replace(/^\./, '').toLowerCase();
      if (host.endsWith(WEREAD_SUFFIX) && !(cookie.name in jar)) jar[cookie.name] = cookie.value;
    }
    return { cookies: jar, ua: String(info['User-Agent'] ?? '').trim() };
  });
}

/** 登录成功的判据：拿到微信读书的身份与会话 cookie。 */
export const isLoggedInJar = (jar = {}) => Boolean(jar.wr_vid && jar.wr_skey);

/** 打开（或复用）一个微信读书标签页，返回它的 targetId。 */
async function ensureWereadTab(cdp, url = LOGIN_URL) {
  const { targetInfos = [] } = await cdp.send('Target.getTargets', {});
  const page = targetInfos.find(t => t.type === 'page' && String(t.url || '').includes(WEREAD_SUFFIX));
  if (page) return page.targetId;
  const { targetId } = await cdp.send('Target.createTarget', { url });
  return targetId;
}

/**
 * 启动登录浏览器（幂等）：没在跑就用包内 profile 起一个独立的浏览器实例，
 * 等调试端口就绪并开好微信读书页。机器上没有 Chromium 系浏览器时返回 false。
 */
export async function launchBrowser(url = LOGIN_URL) {
  const running = await browserVersion();
  if (running) {
    await withBrowser(async (cdp) => { await ensureWereadTab(cdp, url); });
    return true;
  }
  const binary = findBrowser();
  if (!binary) return false;
  fs.mkdirSync(profileDir(), { recursive: true, mode: 0o700 });
  try { fs.rmSync(portFile(), { force: true }); } catch { /* 没有旧端口文件 */ }
  const child = spawn(binary, [
    `--user-data-dir=${profileDir()}`,
    '--remote-debugging-port=0',
    '--no-first-run',
    '--no-default-browser-check',
    'about:blank',
  ], { detached: true, stdio: 'ignore' });
  child.unref();
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    if (await browserVersion()) {
      await withBrowser(async (cdp) => { await ensureWereadTab(cdp, url); });
      return true;
    }
    await sleep(300);
  }
  return false;
}

/**
 * 让页面上出现一张可扫的二维码：打开干净的微信读书标签页，点「登录」拉出扫码弹层。
 * 三条实测教训（都不走）：
 *   ① 复用已开弹层的页面 →「登录」是 toggle，再点会把它关掉；
 *   ② 重设已存在 qrconnect iframe 的 src 想「刷新」→ 会话与 ts 参数绑定，改了会立刻判失效；
 *   ③ 页面刚打开就点 → SPA 未就绪，点击落空；点完要验证弹层真的出现，没出现再点（最多 3 次）。
 * 弹层就绪后把页面标题改成「【请用微信扫码】微信读书登录」，用户一眼能找到该扫哪一页。
 * 打开或点击失败返回 false（调用方给提示），页面本身仍然开着，用户可以自己点「登录」。
 */
export async function openLoginPanel() {
  return withBrowser(async (cdp) => {
    const targetId = await ensureWereadTab(cdp);
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const evaluate = async (expression) => {
      const reply = await cdp.send('Runtime.evaluate',
                                   { expression, returnByValue: true, awaitPromise: true },
                                   sessionId);
      return reply?.result?.value;
    };
    const qrVisible = async () => evaluate(`(() => {
      const qr = [...document.querySelectorAll('iframe')].find(f => String(f.src || '').includes('qrconnect'));
      if (!qr) return false;
      const rect = qr.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    })()`).catch(() => false);
    const clickLogin = async () => {
      const box = await evaluate(`(() => {
        const candidates = [...document.querySelectorAll('div,button,span,a')]
          .filter(el => (el.textContent || '').trim() === '登录');
        for (const el of candidates) {
          const rect = el.getBoundingClientRect();
          if (rect.width > 0 && rect.height > 0) {
            return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
          }
        }
        return null;
      })()`).catch(() => null);
      if (!box) return false;
      for (const type of ['mousePressed', 'mouseReleased']) {
        await cdp.send('Input.dispatchMouseEvent',
                       { type, x: box.x, y: box.y, button: 'left', clickCount: 1 },
                       sessionId);
      }
      return true;
    };
    for (let attempt = 0; attempt < 3; attempt += 1) {
      if (await qrVisible()) break;
      await sleep(attempt === 0 ? 1500 : 500);
      await clickLogin().catch(() => {});
      await sleep(2500);
    }
    if (!(await qrVisible())) return false;
    await evaluate(`document.title = '【请用微信扫码】微信读书登录'`).catch(() => {});
    return true;
  }) ?? false;
}
