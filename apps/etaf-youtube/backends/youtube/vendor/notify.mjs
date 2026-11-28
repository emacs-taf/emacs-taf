// 推手机的唯一实现：调共享通知扩展（Telegram），收 {sent, reason, via}，从不抛异常。
// 使用者：page-change-watch、x-social、weread、feishu 的巡检与摘要。
//
// 为什么这里要自己挑路（2026-10-02 本机实测，两次踩坑换来的）：
//   1. pi 常处于直连模式（`NO_PROXY=*`，境内模型时就这样），而 Telegram 必须走代理；
//      把「继承来的代理变量」当准的，结果就是直连 Telegram 干等超时。
//   2. 环境里**同时**存在 `NO_PROXY` 与 `no_proxy`（小写）两份，只覆盖其中一份，
//      程序照样绕过代理——必须先都清干净再按路线设置。
// 所以：每次调用自己决定路线（直连 / 代理），记住上次成功的那条（15 分钟），
// 失败就换另一条重试；两条都试过才算失败，并把原因带回去。
//
// 约定：**只在异常时推**，正常静默——所以这里不做去重/限流，调用方负责只在有事时调它。
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';

/** 本机常见代理端口；可用 PI_NOTIFY_PROXY 覆盖。 */
export const DEFAULT_PROXY = 'http://127.0.0.1:7890';
const PROXY_KEYS = ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'];
const NO_PROXY_KEYS = ['NO_PROXY', 'no_proxy'];
const ROUTE_TTL_MS = 15 * 60 * 1000;

export function agentDirOf() {
  return process.env.PI_CODING_AGENT_DIR || path.join(process.env.HOME, '.pi', 'agent');
}

export function notifyCliPath(agentDir = agentDirOf()) {
  return path.join(agentDir, 'shared', 'extensions', 'notifications', 'cli.mjs');
}

export function proxyOf(explicit = '') {
  return explicit || process.env.PI_NOTIFY_PROXY || process.env.PI_FEISHU_NOTIFY_PROXY || DEFAULT_PROXY;
}

/** 路线缓存：上次哪条路推成功了，下次先试它。文件坏了就当没有。 */
function routeCacheFile(agentDir) {
  return path.join(agentDir, 'local', 'skills', 'skill-interface', 'notify-route.json');
}

function readCachedRoute(agentDir) {
  try {
    const raw = JSON.parse(readFileSync(routeCacheFile(agentDir), 'utf8'));
    if (!raw?.route || !raw?.at) return null;
    if (Date.now() - Date.parse(raw.at) > ROUTE_TTL_MS) return null;
    return raw.route;
  } catch {
    return null;
  }
}

function writeCachedRoute(agentDir, route, proxy) {
  try {
    const file = routeCacheFile(agentDir);
    mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    writeFileSync(file, `${JSON.stringify({ route, proxy, at: new Date().toISOString() })}\n`, { mode: 0o600 });
  } catch { /* 缓存写不进去不影响推送 */ }
}

/**
 * 构造给子进程的环境：先清掉所有代理变量（含小写），再按路线设置。
 * 用独立 env 而不是改 process.env —— 调用方的环境不该被我们污染。
 */
export function envForRoute(route, proxy) {
  const env = { ...process.env };
  for (const key of [...PROXY_KEYS, ...NO_PROXY_KEYS]) delete env[key];
  if (route === 'proxy') {
    env.HTTP_PROXY = proxy;
    env.http_proxy = proxy;
    env.HTTPS_PROXY = proxy;
    env.https_proxy = proxy;
    env.NO_PROXY = 'localhost,127.0.0.1';
    env.no_proxy = 'localhost,127.0.0.1';
  } else {
    env.NO_PROXY = '*';
    env.no_proxy = '*';
  }
  return env;
}

/**
 * @param {{title: string, body: string, group?: string, agentDir?: string, cli?: string,
 *          timeoutMs?: number, proxy?: string, routes?: string[]}} message
 * @returns {{sent: boolean, via?: string, reason?: string}}
 */
export function notify({ title, body, group = '', agentDir = agentDirOf(), cli = '', timeoutMs = 30000, proxy = '', routes } = {}) {
  const target = cli || notifyCliPath(agentDir);
  if (!existsSync(target)) return { sent: false, reason: `推送入口不存在: ${target}` };
  const resolvedProxy = proxyOf(proxy);
  const cached = routes ? null : readCachedRoute(agentDir);
  const order = routes ?? (cached === 'proxy' ? ['proxy', 'direct'] : cached === 'direct' ? ['direct', 'proxy'] : ['direct', 'proxy']);

  let last = { sent: false, reason: '未尝试' };
  for (const [index, route] of order.entries()) {
    if (!['direct', 'proxy'].includes(route)) return { sent: false, reason: `未知路线 ${route}` };
    // 第一次给短一点的预算：路走错时不该让调用方白等一整个超时
    const budget = index === 0 && !cached ? Math.min(timeoutMs, 15000) : timeoutMs;
    const result = runNotify(target, { title, body, group, timeoutMs: budget, env: envForRoute(route, resolvedProxy) });
    if (result.sent) {
      if (!routes) writeCachedRoute(agentDir, route, route === 'proxy' ? resolvedProxy : '');
      return { ...result, via: route === 'proxy' ? `proxy ${resolvedProxy}` : 'direct' };
    }
    last = { ...result, via: route };
  }
  return last;
}

function runNotify(cli, { title, body, group, timeoutMs, env }) {
  const result = spawnSync(process.execPath, [cli, 'send'], {
    input: JSON.stringify({ title, body: String(body).slice(0, 2900), ...(group ? { group } : {}) }),
    encoding: 'utf8',
    timeout: timeoutMs,
    env,
  });
  return result.status === 0
    ? { sent: true }
    : { sent: false, reason: (result.stderr || result.stdout || '推送失败').trim().slice(0, 200) };
}
