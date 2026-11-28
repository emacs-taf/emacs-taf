// 通道层：CDP 传输 + 浏览器生命周期 + 选择器解析。
// 只做「把参数变成协议调用」，不含任何站点业务逻辑。

import { spawn, spawnSync } from 'node:child_process';
import { closeSync, existsSync, mkdirSync, openSync, readSync, statSync } from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

export const PROFILE_NAME = 'Chrome-CDP-Automation';

const sleep = ms => new Promise(r => setTimeout(r, ms));

/** 页面无响应时统一的提示：对话框阻塞是最常见原因，且残留后无法从新连接救援。 */
export const DIALOG_HINT = '页面可能被 JavaScript 对话框（alert/confirm/prompt/beforeunload）或死循环阻塞；残留的对话框无法从新连接处理，需 cdpctl stop && cdpctl launch 重启浏览器。';

/** 固定端口，可用 CDPCTL_PORT 覆盖。 */
export function port() {
  return Number(process.env.CDPCTL_PORT || 9222);
}

/** 本机自动化 profile 目录（持久，含登录态）。绝不放共享仓库内。 */
export function profileDir() {
  if (process.env.CDPCTL_PROFILE) return process.env.CDPCTL_PROFILE;
  const home = os.homedir();
  if (process.platform === 'darwin') {
    return path.join(home, 'Library', 'Application Support', PROFILE_NAME);
  }
  if (process.platform === 'win32') {
    const base = process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
    return path.join(base, PROFILE_NAME);
  }
  const base = process.env.XDG_DATA_HOME || path.join(home, '.local', 'share');
  return path.join(base, PROFILE_NAME);
}

function which(bin) {
  const exts = process.platform === 'win32' ? ['.exe', '.cmd', ''] : [''];
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    for (const ext of exts) {
      const p = path.join(dir, bin + ext);
      if (existsSync(p)) return p;
    }
  }
  return null;
}

/** 默认的 Chrome 候选路径（按平台）。可单独调用来排查探测问题。 */
export function chromeCandidates() {
  const tried = [];
  const add = (...p) => tried.push(...p.filter(Boolean));

  if (process.platform === 'darwin') {
    add('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser');
  } else if (process.platform === 'win32') {
    for (const root of [process.env['ProgramFiles'], process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA]) {
      add(root && path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'),
          root && path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe'));
    }
  } else {
    for (const b of ['google-chrome-stable', 'google-chrome', 'chromium', 'chromium-browser', 'microsoft-edge']) {
      add(which(b));
    }
  }
  return tried;
}

/**
 * Chrome/Chromium/Edge 可执行文件。
 * CDPCTL_CHROME 优先；否则依次检查 chromeCandidates()。
 * candidates 参数是可注入接缝，便于独立测试「找不到」的错误分支。
 */
export function chromePath(candidates = chromeCandidates()) {
  if (process.env.CDPCTL_CHROME) return process.env.CDPCTL_CHROME;
  for (const p of candidates) if (existsSync(p)) return p;
  throw new Error(
    '找不到 Chrome/Chromium 可执行文件。\n  用 CDPCTL_CHROME=<绝对路径> 指定。\n  已尝试:\n    ' + candidates.join('\n    ')
  );
}

export async function httpJson(route, method = 'GET') {
  let res;
  try {
    res = await fetch(`http://127.0.0.1:${port()}${route}`, { method });
  } catch (e) {
    throw new Error(
      `连不上 CDP 127.0.0.1:${port()}（${e.cause?.code || e.message}）。\n` +
      `  先启动: cdpctl launch --url <URL>\n` +
      `  看状态: cdpctl status`
    );
  }
  if (!res.ok) throw new Error(`CDP 返回 HTTP ${res.status}: ${route}`);
  const text = await res.text();
  if (!text) return null;
  try { return JSON.parse(text); } catch { return text; }
}

/** 浏览器是否在跑；返回 version 对象或 null。 */
export async function version(timeoutMs = 1500) {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), timeoutMs);
    const res = await fetch(`http://127.0.0.1:${port()}/json/version`, { signal: ctl.signal });
    clearTimeout(t);
    if (!res.ok) return null;
    return await res.json();
  } catch { return null; }
}

/** 列出所有调试目标；未启动时给出可操作的报错。 */
export async function listTargets() {
  return (await httpJson('/json/list')) || [];
}

/**
 * 选页面目标。
 * 无 match 时：优先排除 about:blank，唯一命中才自动采用，否则报错并列出候选。
 */
export function pickPage(targets, match, target) {
  const pages = targets.filter(t => t.type === 'page');
  if (!pages.length) throw new Error('没有 page 目标。先运行: cdpctl launch --url <URL>');

  // 按 targetId 精确定位：编排多个标签页时比 --match 可靠
  // （--match 命中 URL/标题片段，重定向后会失配，同名页面会歧义）。
  if (target) {
    const hit = pages.find(t => t.id === target);
    if (!hit) {
      throw new Error(`--target "${target}" 不存在（页面可能已关闭或被导航走）。当前页面:\n` +
        pages.map(t => `  id=${t.id}  ${t.title || '(无标题)'}  ${t.url}`).join('\n') +
        '\n用 cdpctl status 或 targets 取最新的 id。');
    }
    return hit;
  }

  if (match) {
    const hit = pages.filter(t => (t.url || '').includes(match) || (t.title || '').includes(match));
    if (!hit.length) {
      throw new Error(`--match "${match}" 无命中。当前页面:\n` + pages.map(t => `  ${t.title}  ${t.url}`).join('\n'));
    }
    if (hit.length > 1) {
      throw new Error(`--match "${match}" 命中 ${hit.length} 个，请写得更精确:\n` + hit.map(t => `  ${t.url}`).join('\n'));
    }
    return hit[0];
  }

  const real = pages.filter(t => !/^about:blank$/.test(t.url || ''));
  const pool = real.length ? real : pages;
  if (pool.length === 1) return pool[0];
  throw new Error(
    `有 ${pages.length} 个页面，无法自动选择。用 --match <URL或标题片段> 指定:\n` +
    pages.map(t => `  ${t.title || '(无标题)'}  ${t.url}`).join('\n')
  );
}

/** 最小 CDP 客户端（零依赖，用 Node 内置 WebSocket）。 */
export class CDP {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.seq = 0;
    this.pending = new Map();
    this.listeners = new Set();
  }

  static connect(wsUrl) {
    return new Promise((resolve, reject) => {
      const c = new CDP(wsUrl);
      c.ws = new WebSocket(wsUrl);
      const to = setTimeout(() => reject(new Error('WebSocket 连接超时: ' + wsUrl)), 10000);
      c.ws.onopen = () => { clearTimeout(to); resolve(c); };
      c.ws.onerror = () => { clearTimeout(to); reject(new Error('WebSocket 连接失败: ' + wsUrl)); };
      c.ws.onmessage = ev => {
        const m = JSON.parse(ev.data);
        if (m.id && c.pending.has(m.id)) {
          const { resolve: res, reject: rej } = c.pending.get(m.id);
          c.pending.delete(m.id);
          m.error ? rej(new Error(`${m.error.message} ${JSON.stringify(m.error.data ?? '')}`))
                  : res(m.result);
          return;
        }
        if (m.method) for (const fn of c.listeners) fn(m);
      };
    });
  }

  on(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }

  /**
   * 发一条 CDP 命令。timeoutMs>0 时超时会拒绝并带上 timeoutHint——
   * 页面被对话框/死循环阻塞时 CDP 调用会永久挂起，超时兜底把「挂死」变成可操作的报错。
   */
  send(method, params = {}, { timeoutMs = 0, timeoutHint = '' } = {}) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      let timer = null;
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          if (!this.pending.has(id)) return;
          this.pending.delete(id);
          reject(new Error(`CDP ${method} ${timeoutMs}ms 无响应${timeoutHint ? '。' + timeoutHint : ''}`));
        }, timeoutMs);
      }
      this.pending.set(id, {
        resolve: v => { if (timer) clearTimeout(timer); resolve(v); },
        reject: e => { if (timer) clearTimeout(timer); reject(e); },
      });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  close() { try { this.ws.close(); } catch { /* 已关闭 */ } }
}

/** 连到浏览器级 endpoint（用于 Browser.close / 新建目标）。 */
export async function connectBrowser() {
  const v = await version();
  if (!v?.webSocketDebuggerUrl) throw new Error(`CDP 未就绪于 127.0.0.1:${port()}。先运行: cdpctl launch`);
  return CDP.connect(v.webSocketDebuggerUrl);
}

/**
 * 对话框自动处理。实测结论（Chrome 153）：
 * - 对话框打开会阻塞后续 CDP 调用：Page.enable / Runtime.evaluate / Input.* 全部挂起，
 *   连触发弹窗那次 mouseReleased 的响应都要等对话框被处理后才返回；
 * - 对话框残留后，新连接既收不到事件也 handle 不掉（Page.enable 先挂死）——
 *   所以必须在动作之前装好处理器，绝不能让它残留。
 * mode: accept（默认，自动化合理默认）| dismiss | ignore（不装处理器，保留原生行为）。
 * prompt 的自动应答文本用 CDPCTL_DIALOG_TEXT 指定，缺省用页面给的 defaultPrompt。
 */
export function installDialogHandler(cdp, mode = 'accept') {
  if (!['accept', 'dismiss', 'ignore'].includes(mode)) {
    throw new Error(`CDPCTL_DIALOG 只支持 accept / dismiss / ignore，收到 "${mode}"`);
  }
  if (mode === 'ignore') return { enable: Promise.resolve() };
  const enable = cdp.send('Page.enable', {}, { timeoutMs: 5000, timeoutHint: DIALOG_HINT });
  enable.catch(() => {}); // 让 connectPage 的警告提示接管错误
  cdp.on(m => {
    if (m.method !== 'Page.javascriptDialogOpening') return;
    const p = { accept: mode === 'accept' };
    if (p.accept && m.params.type === 'prompt') {
      p.promptText = process.env.CDPCTL_DIALOG_TEXT ?? m.params.defaultPrompt ?? '';
    }
    cdp.send('Page.handleJavaScriptDialog', p).catch(() => {});
  });
  return { enable };
}

/** 连到某个页面；默认自动装对话框处理器。 */
export async function connectPage(match, target, { dialogs = process.env.CDPCTL_DIALOG || 'accept' } = {}) {
  const t = pickPage(await listTargets(), match, target);
  const cdp = await CDP.connect(t.webSocketDebuggerUrl);
  const h = installDialogHandler(cdp, dialogs);
  await h.enable.catch(e => {
    console.error('警告: 对话框保护未就绪 — ' + e.message);
  });
  return { cdp, target: t };
}

/** 在页面执行 JS。timeoutMs>0 时超时拒绝（用于页面被阻塞时快速报错）。 */
export async function evaluate(cdp, expression, { awaitPromise = true, userGesture = true, timeoutMs = 0 } = {}) {
  const r = await cdp.send('Runtime.evaluate', {
    expression, awaitPromise, returnByValue: true, userGesture, includeCommandLineAPI: true,
  }, timeoutMs ? { timeoutMs, timeoutHint: DIALOG_HINT } : {});
  if (r.exceptionDetails) {
    const d = r.exceptionDetails;
    throw new Error('页面内异常: ' + (d.exception?.description || d.text));
  }
  return r.result.value;
}

/** 等待页面 load 事件。 */
export function waitLoad(cdp, timeout = 30000) {
  return new Promise(resolve => {
    let off = () => {};
    const t = setTimeout(() => { off(); resolve('timeout'); }, timeout);
    off = cdp.on(m => {
      if (m.method === 'Page.loadEventFired') { clearTimeout(t); off(); resolve('load'); }
    });
    cdp.send('Page.enable').catch(() => {});
  });
}

/**
 * 选择器语法 -> 返回元素的 JS 表达式。支持三种：
 *   css        querySelector 语法
 *   text=文本  文本内容完全相等（取最内层匹配，避免命中外层容器）
 *   xpath=表达式
 * root 是解析起点：主文档用 'document'，iframe 内用其 contentDocument 变量名。
 * win  是该 realm 的 window：主文档 'window'，iframe 内 'w'（跨 realm 调 getComputedStyle 会抛错）。
 */
export function selectorExpr(sel, root = 'document', win = 'window') {
  if (sel.startsWith('@')) {
    // 快照引用：snapshot 给元素打的 data-cdpctl-ref。
    // 引用可能落在 open shadow root 里，querySelector 不穿透，所以用 JS 递归查找。
    const n = sel.slice(1);
    if (!/^\d+$/.test(n)) {
      throw new Error(`快照引用格式是 @数字（如 @3），收到 "${sel}"。跑 cdpctl snapshot 获取当前页面的引用。`);
    }
    return `(() => {
      const find = r => {
        const hit = r.querySelector('[data-cdpctl-ref="${n}"]');
        if (hit) return hit;
        for (const e of r.querySelectorAll('*')) if (e.shadowRoot) { const h = find(e.shadowRoot); if (h) return h; }
        return null;
      };
      return find(${root});
    })()`;
  }
  if (sel.startsWith('text=')) {
    return `(() => {
      const want = ${JSON.stringify(sel.slice(5))};
      const tt = s => (s || '').trim().replace(/\\s+/g, ' ');
      const all = [...${root}.querySelectorAll('*')].filter(e => tt(e.textContent) === want);
      if (!all.length) return null;
      // 必须取最内层：外层容器（如包着按钮的 div）的 textContent 也相等，
      // 选中它会让点击落在容器空白处，静默不生效。
      const inner = all.filter(e => !all.some(o => o !== e && e.contains(o)));
      // 真页面上常有隐藏的重复项（折叠菜单、移动端导航副本）排在前面（DeepSeek 实测）；
      // 只看「第一个最内层」会选中不可见元素，导致 wait/click 静默失败。优先取可见的。
      const visible = e => {
        const r = e.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return false;
        const cs = ${win}.getComputedStyle(e);
        return cs.visibility !== 'hidden' && cs.display !== 'none';
      };
      return inner.find(visible) || inner[0] || all[0];
    })()`;
  }
  if (sel.startsWith('xpath=')) {
    return `${root}.evaluate(${JSON.stringify(sel.slice(6))}, ${root}, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue`;
  }
  return `${root}.querySelector(${JSON.stringify(sel)})`;
}

/**
 * 页面结构快照：把可见的「交互 + 结构」元素打上 data-cdpctl-ref，返回缩进文本树。
 * 所有命令的选择器都支持 @N（见 selectorExpr），一次调用看懂整页。
 * all=true 额外纳入带可见文本的叶子节点；max 限制输出节点数（0=不限）。
 * 引用会在页面重渲染后失效，届时重跑 snapshot 即可。
 */
export function snapshotExpr({ all = false, max = 250 } = {}) {
  const limit = Number(max) > 0 ? Math.floor(Number(max)) : Number.MAX_SAFE_INTEGER;
  return `(() => {
    const REF = 'data-cdpctl-ref';
    const MAX = ${limit};
    const ALL = ${all ? 'true' : 'false'};
    const txt = (s, n) => String(s == null ? '' : s).trim().replace(/\\s+/g, ' ').slice(0, n);
    const TAG = new Set(['A','BUTTON','INPUT','SELECT','TEXTAREA','SUMMARY','IFRAME']);
    const STRUCT = new Set(['MAIN','NAV','HEADER','FOOTER','ASIDE','FORM','TABLE','DETAILS']);
    const ROLES = new Set(['button','link','textbox','searchbox','combobox','listbox','checkbox','radio','switch','slider','spinbutton','menuitem','menuitemcheckbox','menuitemradio','tab','option','treeitem','dialog','alertdialog','alert','status','progressbar']);
    const isField = el => el.tagName === 'INPUT' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA';
    const visible = el => {
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return false;
      const cs = getComputedStyle(el);
      return cs.display !== 'none' && cs.visibility !== 'hidden';
    };
    const nameOf = el => {
      const aria = el.getAttribute('aria-label');
      if (aria) return txt(aria, 90);
      const by = el.getAttribute('aria-labelledby');
      if (by) {
        const t = by.split(/\\s+/).map(id => { const x = document.getElementById(id); return x ? (x.innerText || x.textContent) : ''; }).join(' ');
        if (txt(t, 90)) return txt(t, 90);
      }
      if (isField(el)) {
        const l = el.labels && el.labels[0];
        if (l) return txt(l.innerText || l.textContent, 90);
        if (el.placeholder) return 'placeholder: ' + txt(el.placeholder, 70);
        if (el.title) return txt(el.title, 90);
        if (['submit','reset','button'].includes(String(el.type ?? '').toLowerCase())) return txt(el.value, 90);
        return '';
      }
      if (el.tagName === 'IMG') return txt(el.alt, 90);
      if (STRUCT.has(el.tagName) || el.tagName === 'IFRAME') return txt(el.title, 90);
      let direct = '';
      for (const n of el.childNodes) if (n.nodeType === 3) direct += n.textContent;
      return txt(direct.trim() ? direct : (el.innerText || el.textContent), 90);
    };
    const keep = el => {
      const tag = el.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') return false;
      if (tag === 'INPUT' && String(el.type ?? '').toLowerCase() === 'hidden') return false;
      if (TAG.has(tag) || /^H[1-6]$/.test(tag) || STRUCT.has(tag)) return true;
      if (el.isContentEditable) return true;
      if (tag === 'IMG') return !!el.alt;
      if (ROLES.has((el.getAttribute('role') || '').toLowerCase())) return true;
      if (ALL) for (const n of el.childNodes) if (n.nodeType === 3 && n.textContent.trim()) return true;
      return false;
    };
    const describe = el => {
      const tag = el.tagName.toLowerCase();
      const type = String(el.type ?? '').toLowerCase();
      const head = tag === 'a' ? 'link' : (tag === 'input' ? 'input[' + (type || 'text') + ']' : tag);
      const nm = nameOf(el);
      let s = head + (nm ? ' "' + nm + '"' : '');
      if (tag === 'a' && el.href) s += ' → ' + txt(el.href, 110);
      if (tag === 'iframe' && el.src) s += ' → ' + txt(el.src, 110);
      if (tag === 'input') {
        if (type === 'checkbox' || type === 'radio') { if (el.checked) s += ' [checked]'; }
        else if (type === 'password') { if (el.value) s += ' [len=' + el.value.length + ']'; }
        else if (el.value) s += ' [value=' + JSON.stringify(txt(el.value, 60)) + ']';
      }
      if (tag === 'textarea' && el.value) s += ' [len=' + el.value.length + ']';
      if (tag === 'select' && el.selectedOptions && el.selectedOptions[0]) s += ' [selected=' + JSON.stringify(txt(el.selectedOptions[0].textContent, 50)) + ']';
      if (el.disabled) s += ' [disabled]';
      return s;
    };
    const clear = root => {
      for (const e of root.querySelectorAll('[' + REF + ']')) e.removeAttribute(REF);
      for (const e of root.querySelectorAll('*')) if (e.shadowRoot) clear(e.shadowRoot);
    };
    clear(document);
    const lines = [];
    let ref = 0, kept = 0, truncated = 0;
    const walk = (el, depth) => {
      let d = depth;
      if (keep(el) && visible(el)) {
        kept++;
        if (kept <= MAX) {
          el.setAttribute(REF, String(++ref));
          lines.push('  '.repeat(Math.min(depth, 12)) + '@' + ref + ' ' + describe(el));
          d = depth + 1;
        } else truncated++;
      }
      for (const c of el.children) walk(c, d);
      if (el.shadowRoot) for (const c of el.shadowRoot.children) walk(c, d);
    };
    walk(document.body || document.documentElement, 0);
    return { url: location.href, title: document.title, kept, truncated, lines };
  })()`;
}

/**
 * 元素几何（页面坐标，左上角）。命中返回 {x,y,w,h,tag}；不存在/不可见返回 null。
 * frameSel 非空时先在 iframe 内解析，再把坐标换算成宿主页面的坐标；iframe 跨域返回 {frameError}。
 *
 * 必须是纯同步求值（见 visibleRectExpr 的禁用 rAF 说明），
 * 求值返回的是本次布局的坐标，所以紧接着派发鼠标事件是安全的。
 */
export function boxExpr(sel, frameSel) {
  if (!frameSel) {
    return `(() => {
      const el = ${selectorExpr(sel)};
      if (!el) return null;
      const measure = () => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height, tag: el.tagName }; };
      const first = measure();
      if (first.w === 0 || first.h === 0) return null;
      const cs = getComputedStyle(el);
      if (cs.visibility === 'hidden' || cs.display === 'none') return null;
      // 只在确实看不见时才滚动：已可见的元素保持原布局，
      // 否则「滚动改变布局 → 坐标过期 → 点空」会在真实站点上静默发生。
      let box = first;
      const cx = box.x + box.w / 2, cy = box.y + box.h / 2;
      if (cx < 0 || cy < 0 || cx > innerWidth || cy > innerHeight) {
        el.scrollIntoView({ block: 'center', inline: 'center' });
        box = measure();
      }
      const c2x = box.x + box.w / 2, c2y = box.y + box.h / 2;
      return { ...box, inView: c2x >= 0 && c2y >= 0 && c2x <= innerWidth && c2y <= innerHeight };
    })()`;
  }
  return `(() => {
    const f = document.querySelector(${JSON.stringify(frameSel)});
    if (!f) return null;
    if (!f.contentDocument) return { frameError: 'cross-origin' };
    const d = f.contentDocument;
    const w = f.contentWindow;
    const el = ${selectorExpr(sel, 'd', 'w')};
    if (!el) return null;
    // clientLeft/Top = iframe 边框宽度，加上它才是内容区原点
    const measure = () => {
      const r = el.getBoundingClientRect();
      const fr = f.getBoundingClientRect();
      return { x: fr.left + f.clientLeft + r.x, y: fr.top + f.clientTop + r.y, w: r.width, h: r.height, tag: el.tagName, inFrameY: r.y };
    };
    const first = measure();
    if (first.w === 0 || first.h === 0) return null;
    const cs = f.contentWindow.getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return null;
    // 内层先居中：iframe 常常比宿主视口高，元素落在 iframe 中部才好对齐。
    // 之后迭代收敛：每轮重新量一次坐标再滚一次，因为 iframe 内的 scrollIntoView
    // 可能连带滚动宿主容器（跨 frame 滚动链），单次计算的 delta 会过期。
    el.scrollIntoView({ block: 'center', inline: 'center' });
    let box = measure();
    const inView = b => {
      const x = b.x + b.w / 2, y = b.y + b.h / 2;
      return x >= 0 && y >= 0 && x <= innerWidth && y <= innerHeight;
    };
    for (let i = 0; i < 4 && !inView(box); i++) {
      const delta = (innerHeight / 2 - (box.inFrameY + box.h / 2)) - f.getBoundingClientRect().top;
      if (Math.abs(delta) < 1) break;
      let sc = f.parentElement;
      while (sc && sc !== document.body && sc !== document.documentElement) {
        const c2 = getComputedStyle(sc);
        if (/(auto|scroll)/.test(c2.overflowY) && sc.scrollHeight > sc.clientHeight) break;
        sc = sc.parentElement;
      }
      if (sc && sc !== document.body && sc !== document.documentElement) {
        const before = sc.scrollTop;
        sc.scrollTop = before + delta;
        if (sc.scrollTop === before) break;
      } else {
        const before = window.scrollY;
        window.scrollBy(0, delta);
        if (window.scrollY === before) break;
      }
      box = measure();
    }
    return { x: box.x, y: box.y, w: box.w, h: box.h, tag: box.tag, inView: inView(box) };
  })()`;
}

/** 把 boxExpr 的跨域标记转成可读异常，其余原样返回。 */
export function assertFrameAccess(box, frameSel) {
  if (box && typeof box === 'object' && box.frameError) {
    const why = box.frameError === 'cross-origin' ? '跨域 iframe，受同源策略限制' : box.frameError;
    throw new Error(`无法访问 --frame "${frameSel}" 内部：${why}。跨域 iframe 只能操作其外部宿主元素。`);
  }
  return box;
}

/**
 * 真实鼠标点击（isTrusted=true）。
 * box 来自 visibleRectExpr/waitForElement 的同步求值结果，因此紧接着派发是安全的。
 */
const INPUT_OPTS = { timeoutMs: 15000, timeoutHint: DIALOG_HINT };

export async function clickAt(cdp, box) {
  for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
    await cdp.send('Input.dispatchMouseEvent', {
      type, x: box.x, y: box.y, button: 'left', clickCount: 1,
      buttons: type === 'mousePressed' ? 1 : 0,
    }, INPUT_OPTS);
  }
}

/**
 * 真实鼠标拖拽：按下 -> 分步移动 -> 松开。
 * 分步是为了让页面的 mousemove 监听与浏览器原生 HTML5 拖拽控制器都能收到过程事件。
 * 两端坐标必须已在同一视口内（调用方负责检查）。
 */
export async function dragBetween(cdp, from, to, steps = 10) {
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: from.x, y: from.y, buttons: 0 }, INPUT_OPTS);
  await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: from.x, y: from.y, button: 'left', clickCount: 1, buttons: 1 }, INPUT_OPTS);
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchMouseEvent', {
      type: 'mouseMoved', button: 'left', buttons: 1,
      x: from.x + (to.x - from.x) * (i / steps),
      y: from.y + (to.y - from.y) * (i / steps),
    }, INPUT_OPTS);
    await sleep(10); // 给原生拖拽控制器消化过程事件的时间
  }
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: to.x, y: to.y, button: 'left', clickCount: 1, buttons: 0 }, INPUT_OPTS);
}

/**
 * 把文本插入**当前焦点元素**（CDP Input.insertText，走浏览器原生编辑管线）。
 * 这是自绘编辑器（Monaco / ProseMirror / CodeMirror / React contenteditable）唯一可靠的输入方式，
 * 因为那些控件不是 input/textarea，原生 value setter 那套（setInputValue）对它们无效。
 * 前置条件：页面里已经有焦点元素——先自己 clickAt 聚焦，或让调用方负责。
 */
export async function insertText(cdp, text) {
  await cdp.send('Input.insertText', { text }, INPUT_OPTS);
}

/** 按键表：真实键盘事件用。单字符可直接写，修饰键用 ctrl+a / cmd+enter 形式。 */
export const KEYS = {
  enter: { key: 'Enter', code: 'Enter', keyCode: 13, text: '\r' },
  tab: { key: 'Tab', code: 'Tab', keyCode: 9 },
  escape: { key: 'Escape', code: 'Escape', keyCode: 27 },
  esc: { key: 'Escape', code: 'Escape', keyCode: 27 },
  backspace: { key: 'Backspace', code: 'Backspace', keyCode: 8 },
  delete: { key: 'Delete', code: 'Delete', keyCode: 46 },
  space: { key: ' ', code: 'Space', keyCode: 32, text: ' ' },
  arrowup: { key: 'ArrowUp', code: 'ArrowUp', keyCode: 38 },
  arrowdown: { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40 },
  arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37 },
  arrowright: { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39 },
  home: { key: 'Home', code: 'Home', keyCode: 36 },
  end: { key: 'End', code: 'End', keyCode: 35 },
  pageup: { key: 'PageUp', code: 'PageUp', keyCode: 33 },
  pagedown: { key: 'PageDown', code: 'PageDown', keyCode: 34 },
};
const MOD_BITS = { alt: 1, ctrl: 2, control: 2, meta: 4, cmd: 4, command: 4, shift: 8 };

/** 'ctrl+a' / 'enter' / 'a' → 协议参数。 */
export function parseKey(spec) {
  const parts = spec.toLowerCase().split('+');
  const base = parts.pop();
  let modifiers = 0;
  for (const p of parts) {
    if (!(p in MOD_BITS)) throw new Error(`未知修饰键 "${p}" (可用 ctrl/cmd/shift/alt)`);
    modifiers |= MOD_BITS[p];
  }
  const k = KEYS[base] || (base.length === 1 ? { key: base, code: `Key${base.toUpperCase()}`, keyCode: base.toUpperCase().charCodeAt(0), text: base } : null);
  if (!k) throw new Error(`未知按键 "${base}"。可用: ${Object.keys(KEYS).join(', ')}，或单字符，或 ctrl+a 形式`);
  return { ...k, modifiers };
}

/**
 * 发真实按键（keyDown + keyUp）。这是让目标控件自己的按键处理生效的唯一方式：
 * 清空自绘编辑器（ctrl+a 后 backspace）、回车提交、Esc 关弹层等。
 * 注意修饰键组合也带 text（如 ctrl+a 带 text:'a'），浏览器靠 modifiers 判定为快捷键，不会插入字符。
 */
export async function pressKey(cdp, spec) {
  const k = parseKey(spec);
  const base = { modifiers: k.modifiers, key: k.key, code: k.code, windowsVirtualKeyCode: k.keyCode, nativeVirtualKeyCode: k.keyCode };
  await cdp.send('Input.dispatchKeyEvent', { ...base, type: k.text ? 'keyDown' : 'rawKeyDown', text: k.text, unmodifiedText: k.text }, INPUT_OPTS);
  await cdp.send('Input.dispatchKeyEvent', { ...base, type: 'keyUp' }, INPUT_OPTS);
}

/**
 * 元素是否可见可交互。
 *
 * 必须是纯同步求值：不得包含 requestAnimationFrame / await / 定时器。
 * 实测结论（见 REFERENCE.md「禁用 rAF 探针」）：在页面里跑 rAF 会让 Chrome
 * 永久丢弃此后所有 Input.dispatchMouseEvent 的 mousePressed/mouseReleased，
 * 只保留 mouseMoved，导致不合成 click——表现为「点击报成功但毫无效果」。
 */
export function visibleRectExpr(sel, frameSel) {
  return `(() => {
    const b = ${boxExpr(sel, frameSel)};
    if (!b) return null;
    if (b.frameError) return b;
    return { x: b.x + b.w / 2, y: b.y + b.h / 2, w: b.w, h: b.h, tag: b.tag, inView: b.inView };
  })()`;
}

/**
 * 轮询等待元素可见可交互。
 * 返回值来自最后一次「同步求值」，因此紧接着派发鼠标事件是安全的。
 * 等待发生在 Node 侧（setTimeout），不让页面让出渲染帧。
 */
export async function waitForElement(cdp, sel, timeoutMs = 15000, intervalMs = 150, frameSel) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    // 单次求值 5s 兜底：页面被对话框/死循环阻塞时，这里会报「无响应」而不是永久挂起。
    const box = assertFrameAccess(await evaluate(cdp, visibleRectExpr(sel, frameSel), { timeoutMs: 5000 }), frameSel);
    // inView=false 表示元素可见但不在宿主视口内，此时派发鼠标事件会落空。
    if (box && box.inView !== false) return box;
    if (Date.now() >= deadline) {
      throw new Error(`等待超时(${timeoutMs}ms)：找不到可见可点击的元素 ${sel}${frameSel ? `（--frame ${frameSel}）` : ''}\n` +
        (String(sel).startsWith('@') ? `提示：@ 引用可能已失效（页面重渲染后旧引用会被清掉）。跑 cdpctl snapshot 拿新引用。\n` : '') +
        `提示：用 cdpctl snapshot 看页面结构；用 cdpctl text / html 查看当前页面文本，或 cdpctl eval 检查是否还在 loading。`);
    }
    await new Promise(r => setTimeout(r, intervalMs));
  }
}

/**
 * Win32 焦点辅助：有头启动的 Chrome 会抢前台，把用户正在干活的窗口顶掉。
 * 本机硬约束是「默认绝不动前台」，做法与 windows-terminal-control 一致：
 * 新窗口压到 z-order 底部（SetWindowPos HWND_BOTTOM + SWP_NOACTIVATE），
 * 只在它确实抢走了前台时，再把前台还给启动前的窗口（AttachThreadInput 兜底）。
 *
 * 实现落在 PowerShell（Node 没有 Win32 绑定）：脚本用 -EncodedCommand 整体执行、
 * 参数走环境变量，避开引号与中文路径的转义；脚本保持纯 ASCII。所有失败都是尽力而为——
 * 焦点处理不能把 launch 拖失败，结果交给调用方展示。
 */
const WIN_FOCUS_PS = String.raw`
$ErrorActionPreference = 'Stop'
Add-Type -Namespace CdpFocus -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@

function Emit($obj) { $obj | ConvertTo-Json -Compress }

if ($env:CDP_FOCUS_MODE -eq 'capture') {
  Emit @{ mode = 'capture'; hwnd = [CdpFocus.Win]::GetForegroundWindow().ToInt64() }
  exit 0
}

$pidWanted = 0
if ($env:CDP_FOCUS_PID) { [void][int]::TryParse($env:CDP_FOCUS_PID, [ref]$pidWanted) }
$prev = [int64]0
if ($env:CDP_FOCUS_PREV) { [void][int64]::TryParse($env:CDP_FOCUS_PREV, [ref]$prev) }

# 找窗口：启新实例用 pid；复用已跑实例时按 profile 目录匹配命令行。
$hwnd = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline -and $hwnd -eq [IntPtr]::Zero) {
  if ($pidWanted -gt 0) {
    $p = Get-Process -Id $pidWanted -ErrorAction SilentlyContinue
    if ($p -and $p.MainWindowHandle -ne 0) { $hwnd = $p.MainWindowHandle }
  }
  if ($hwnd -eq [IntPtr]::Zero -and $env:CDP_FOCUS_PROFILE) {
    $owned = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine.Contains($env:CDP_FOCUS_PROFILE) } |
      Select-Object -First 1
    if ($owned) {
      $p2 = Get-Process -Id $owned.ProcessId -ErrorAction SilentlyContinue
      if ($p2 -and $p2.MainWindowHandle -ne 0) { $hwnd = $p2.MainWindowHandle }
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
}

if ($hwnd -eq [IntPtr]::Zero) { Emit @{ found = $false }; exit 0 }

# 用户本来就在自动化窗口里干活：别动（压到后面反而是打扰）。
if ($prev -ne 0 -and $prev -eq $hwnd.ToInt64()) {
  Emit @{ found = $true; demoted = $false; restored = $false; already = $true }
  exit 0
}

$demoted = [CdpFocus.Win]::SetWindowPos($hwnd, [IntPtr]1, 0, 0, 0, 0, 0x0013)
$restored = $false
$fgNow = [CdpFocus.Win]::GetForegroundWindow()
if ($prev -ne 0 -and $fgNow.ToInt64() -eq $hwnd.ToInt64()) {
  for ($i = 0; $i -lt 4 -and -not $restored; $i++) {
    [void][CdpFocus.Win]::SetForegroundWindow([IntPtr]$prev)
    Start-Sleep -Milliseconds 80
    $restored = ([CdpFocus.Win]::GetForegroundWindow().ToInt64() -eq $prev)
    if (-not $restored) {
      $t = [CdpFocus.Win]::GetWindowThreadProcessId([IntPtr]$prev, [IntPtr]::Zero)
      $me = [CdpFocus.Win]::GetCurrentThreadId()
      if ($t -and $t -ne $me) {
        [void][CdpFocus.Win]::AttachThreadInput($me, $t, $true)
        [void][CdpFocus.Win]::SetForegroundWindow([IntPtr]$prev)
        [void][CdpFocus.Win]::AttachThreadInput($me, $t, $false)
        Start-Sleep -Milliseconds 80
        $restored = ([CdpFocus.Win]::GetForegroundWindow().ToInt64() -eq $prev)
      }
    }
  }
}
Emit @{ mode = 'demote'; found = $true; demoted = [bool]$demoted; restored = [bool]$restored; already = $false }
`;

// 别裸写 'powershell.exe'：pi 进程的 PATH 可能没有 System32\WindowsPowerShell\v1.0
// （2026-10-15 实测 spawnSync ENOENT，而同一个 shell 里 Get-Command 找得到）。
function powershellExe() {
  const root = process.env.SystemRoot || process.env.windir || 'C:\\Windows';
  const full = path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return existsSync(full) ? full : 'powershell.exe';
}

function win32FocusRun(env, timeoutMs = 20000) {
  try {
    // -EncodedCommand（UTF-16LE base64）：脚本整体执行。
    // 不用 `-Command -`（stdin）：多行 here-string 会被拆行，Add-Type 拿到空定义（2026-10-15 实测）。
    const encoded = Buffer.from(WIN_FOCUS_PS, 'utf16le').toString('base64');
    const r = spawnSync(powershellExe(), ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], {
      encoding: 'utf8', timeout: timeoutMs, windowsHide: true,
      env: { ...process.env, ...env },
    });
    if (r.error) return { error: r.error.message };
    if (r.status !== 0) return { error: `powershell 退出码 ${r.status}: ${String(r.stderr || '').trim().split(/\r?\n/).slice(-2).join(' / ')}` };
    const line = String(r.stdout || '').trim().split(/\r?\n/).filter(Boolean).pop();
    return JSON.parse(line);
  } catch (e) {
    return { error: e.message };
  }
}

/** 启动前记下当前前台窗口（Win32 专用，其它平台返回 null）。 */
export function win32Foreground() {
  if (process.platform !== 'win32') return null;
  const r = win32FocusRun({ CDP_FOCUS_MODE: 'capture' }, 10000);
  return r && !r.error && r.hwnd ? r : null;
}

/**
 * 把有头 Chrome 窗口压到 z-order 底部，并在它抢了前台时把前台还回去。
 * Win32 专用、尽力而为；返回 {found, demoted, restored, already} 或 {error}。
 */
export function win32DemoteHeaded({ pid, profile, previous } = {}) {
  if (process.platform !== 'win32') return null;
  return win32FocusRun({
    CDP_FOCUS_MODE: 'demote',
    CDP_FOCUS_PID: pid ? String(pid) : '',
    CDP_FOCUS_PROFILE: profile || '',
    CDP_FOCUS_PREV: previous ? String(previous) : '',
  });
}

/**
 * 打开一个新标签页（PUT /json/new?url）。
 * 只在确实需要新页面时调用；不要把 about:blank 当占位符 ——
 * 那会在用户的窗口里留下一个空白标签页，每次运行都多一个。
 */
export async function openTab(url) {
  return httpJson(`/json/new?${encodeURIComponent(url)}`, 'PUT');
}

/**
 * 启动浏览器（幂等）。已在跑则直接复用，并按需新开页面。
 *
 * 关键：不带 url 时**不再**传 '--new-window' / 'about:blank'。
 * 传了会让 Chrome 在恢复上次会话之外**再**开一个空窗口，用户每次都看到
 * 多余的 about:blank（实测：launch 后立刻有 2 个 page 目标，其中一个是空的）。
 * 需要页面时用 url 参数新开一个已有内容的标签页，不留空页。
 *
 * 失败处理：刚 stop 过时端口可能还没释放，新 Chrome 会因绑不上调试端口
 * 而「活着但 CDP 不通」——干等超时还留下孤儿进程（实测遇到过）。
 * 所以：超时就杀掉本次启的进程、确认端口释放、重试一次，失败给可操作的错误。
 */
export async function launch({ url, headless = false, activate = false } = {}) {
  // Win32 + 有头：默认不抢前台（窗口压到 z 序底部、前台还回原窗口）；--activate 是唯一例外。
  const manageFocus = process.platform === 'win32' && !headless && !activate;
  const existing = await version();
  if (existing && url) {
    const prev = manageFocus ? win32Foreground() : null;
    await openTab(url);
    const focus = manageFocus ? win32DemoteHeaded({ profile: profileDir(), previous: prev?.hwnd }) : null;
    return { started: false, version: existing, focus };
  }
  if (existing) return { started: false, version: existing };

  const exe = chromePath();
  const dir = profileDir();
  mkdirSync(dir, { recursive: true });
  const logPath = path.join(dir, 'chrome-launch.log');
  const waitMs = Number(process.env.CDPCTL_LAUNCH_TIMEOUT_MS || 30000);
  const prevFocus = manageFocus ? win32Foreground() : null;

  const attempt = async () => {
    const log = openSync(logPath, 'a');
    const args = [
      `--user-data-dir=${dir}`,
      `--remote-debugging-port=${port()}`,
      '--remote-allow-origins=*',
      '--no-first-run',
      '--no-default-browser-check',
      // 关掉翻译气泡：中英混排页面 + 英文 UI 时 Chrome 会反复弹「要不要翻译」，
      // 对自动化毫无用处，只会挡住页面。
      '--disable-features=Translate,TranslateUI',
      ...(headless ? ['--headless=new'] : []),
      // 只有显式给了 url 才开窗口；否则让 Chrome 自己恢复会话，避免空标签页。
      ...(url ? ['--new-window', url] : []),
    ];
    const child = spawn(exe, args, { detached: true, stdio: ['ignore', log, log] });
    child.unref();

    const deadline = Date.now() + waitMs;
    while (Date.now() < deadline) {
      const v = await version();
      if (v) return { started: true, pid: child.pid, version: v };
      if (child.exitCode !== null || child.signalCode !== null) return { failed: 'exited', child };
      await new Promise(r => setTimeout(r, 400));
    }
    return { failed: 'timeout', child };
  };

  const first = await attempt();
  if (!first.failed) {
    if (manageFocus) first.focus = win32DemoteHeaded({ pid: first.pid, profile: dir, previous: prevFocus?.hwnd });
    return first;
  }
  await killAndWait(first.child);

  // 端口是不是被别的进程占着（而不是我们刚杀掉的那个）
  let freed = false;
  for (let i = 0; i < 25; i++) {
    if (!(await portInUse(port()))) { freed = true; break; }
    await new Promise(r => setTimeout(r, 200));
  }
  if (!freed) {
    throw new Error(
      `CDP 端口 ${port()} 被别的进程占着，自动化浏览器起不来。\n` +
      `  处理: 关掉占用者，或用 CDPCTL_PORT 换一个端口。\n` +
      `  查看占用: lsof -nP -iTCP:${port()} -sTCP:LISTEN`
    );
  }
  if (first.failed === 'exited') {
    throw new Error(
      `Chrome 启动即退出。\n  可执行文件: ${exe}\n  profile: ${dir}\n` +
      `  日志尾部:\n${logTail(logPath)}\n  完整日志: ${logPath}`
    );
  }

  // 端口刚释放，重试一次
  const second = await attempt();
  if (!second.failed) {
    if (manageFocus) second.focus = win32DemoteHeaded({ pid: second.pid, profile: dir, previous: prevFocus?.hwnd });
    return second;
  }
  await killAndWait(second.child);
  const tail = logTail(logPath);
  throw new Error(
    `启动后 ${Math.round(waitMs / 1000)}s 内 CDP 仍未就绪（已重试 1 次，未就绪的进程已清理）。\n` +
    `  可执行文件: ${exe}\n  profile: ${dir}\n  端口: ${port()}\n` +
    (tail ? `  日志尾部:\n${tail}\n` : '') +
    `  完整日志: ${logPath}`
  );
}

/** 端口上有没有人在监听（不判断对方是不是 Chrome）。 */
function portInUse(p) {
  return new Promise(resolve => {
    const s = net.connect({ host: '127.0.0.1', port: p });
    const done = v => { s.destroy(); resolve(v); };
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
    s.setTimeout(1000, () => done(false));
  });
}

/** 优雅结束我们自己启的进程（先 SIGTERM，最多等 5s，再 SIGKILL）。 */
async function killAndWait(child, ms = 5000) {
  if (!child || !child.pid) return;
  if (child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(child.pid, 'SIGTERM'); } catch { return; }
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) return;
    try { process.kill(child.pid, 0); } catch { return; }
    await new Promise(r => setTimeout(r, 200));
  }
  try { process.kill(child.pid, 'SIGKILL'); } catch { /* 已经退了 */ }
}

/** 日志尾部若干字节，失败时用来解释原因（日志会一直追加，所以只读末尾）。 */
function logTail(logPath, bytes = 800) {
  try {
    const size = statSync(logPath).size;
    const start = Math.max(0, size - bytes);
    const fd = openSync(logPath, 'r');
    const buf = Buffer.alloc(size - start);
    readSync(fd, buf, 0, buf.length, start);
    closeSync(fd);
    return buf.toString('utf8').trim().split('\n').slice(-6).join('\n');
  } catch { return ''; }
}

/**
 * 优雅关闭自动化浏览器（走 CDP Browser.close，跨平台且无需记录 PID）。
 * 不会影响用户自己开的 Chrome（不同 user-data-dir / 端口）。
 */
export async function stop() {
  const v = await version();
  if (!v) return { stopped: false, reason: '未在运行' };
  const b = await connectBrowser();
  await b.send('Browser.close').catch(() => {});
  b.close();
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (!(await version())) return { stopped: true };
    await new Promise(r => setTimeout(r, 400));
  }
  return { stopped: false, reason: '20s 内未退出' };
}

/** 自动化 profile 的 Cookies 数据库路径（兼容新旧布局）。 */
export function cookiesDbPath() {
  const base = profileDir();
  for (const rel of ['Default/Network/Cookies', 'Default/Cookies', 'Cookies']) {
    const p = path.join(base, rel);
    if (existsSync(p)) return p;
  }
  throw new Error(`找不到 Cookies 数据库。profile=${base}\n提示：先 launch 一次让 Chrome 建立 profile。`);
}
