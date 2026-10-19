// Browser-session transport. Cookies and authorization hashes never leave Chrome.
import { fail } from '../vendor/render.mjs';

// A replaceable external channel lets offline CLI tests run without Chrome.
const channel = await import(process.env.YOUTUBE_CDP_MODULE || '../vendor/cdp-channel.mjs');
const ORIGIN = 'https://www.youtube.com';

/** Executed in the YouTube page, never in Node. */
async function pageRequest(request) {
  try {
    if (location.origin !== 'https://www.youtube.com' || !window.ytcfg?.get('INNERTUBE_CONTEXT'))
      return { ok: false, error: 'blocked', message: 'YouTube 页面尚未就绪，请重试登录检查' };
    const context = structuredClone(ytcfg.get('INNERTUBE_CONTEXT'));
    if (request.op === 'ready') return { ok: true, data: { signed_in: !!ytcfg.get('LOGGED_IN') } };
    if (!ytcfg.get('LOGGED_IN')) return { ok: false, error: 'auth', message: 'YouTube 账号已退出登录' };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), request.timeout);
    try {
      if (request.op === 'page') {
        const response = await fetch(request.path, { credentials: 'include', signal: controller.signal });
        if (!response.ok) return { ok: false, error: 'external', message: `YouTube HTTP ${response.status}` };
        const html = await response.text();
        function extract(name) {
          const match = html.match(new RegExp(`(?:var ${name}\\s*=|window\\["${name}"\\]\\s*=)\\s*`));
          if (!match) return null;
          const start = match.index + match[0].length;
          let depth = 0, quoted = false, escaped = false;
          for (let i = start; i < html.length; i++) {
            const c = html[i];
            if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; }
            else if (c === '"') quoted = true;
            else if (c === '{') depth++;
            else if (c === '}' && --depth === 0) return JSON.parse(html.slice(start, i + 1));
          }
          return null;
        }
        const initial = extract('ytInitialData');
        const player = extract('ytInitialPlayerResponse');
        if (!initial && !player) return { ok: false, error: 'external', message: 'YouTube 返回了无法解析的页面，可能需要在浏览器中确认登录' };
        return { ok: true, data: { initial, player } };
      }
      const cookie = document.cookie.split('; ').map(x => x.split(/=(.*)/s)).find(x => x[0] === 'SAPISID')?.[1];
      if (!cookie) return { ok: false, error: 'auth', message: 'YouTube 登录凭据不可用，请重新登录' };
      const timestamp = Math.floor(Date.now() / 1000);
      const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-1', new TextEncoder().encode(`${timestamp} ${cookie} ${location.origin}`)))].map(x => x.toString(16).padStart(2, '0')).join('');
      const headers = { 'Content-Type': 'application/json', Authorization: `SAPISIDHASH ${timestamp}_${hash}`, 'X-Goog-AuthUser': String(ytcfg.get('SESSION_INDEX') || 0), 'X-Origin': location.origin };
      if (ytcfg.get('DELEGATED_SESSION_ID')) headers['X-Goog-PageId'] = ytcfg.get('DELEGATED_SESSION_ID');
      const response = await fetch(`/youtubei/v1/${request.endpoint}?prettyPrint=false`, {
        method: 'POST', credentials: 'include', headers, signal: controller.signal,
        body: JSON.stringify({ context, ...request.body }),
      });
      const data = await response.json();
      if (data.responseContext?.mainAppWebResponseContext?.loggedOut === true || response.status === 401)
        return { ok: false, error: 'auth', message: 'YouTube 未接受当前账号登录态' };
      if (!response.ok || data.error)
        return { ok: false, error: response.status === 403 ? 'blocked' : 'external', message: data.error?.message || `YouTube HTTP ${response.status}` };
      return { ok: true, data };
    } finally { clearTimeout(timer); }
  } catch (error) {
    return { ok: false, error: error.name === 'AbortError' ? 'timeout' : 'external', message: String(error.message || error) };
  }
}

/** Borrow an existing YouTube page without navigating or activating it. */
export async function session({ login = false, timeout = 25000 } = {}) {
  let targets;
  try { targets = await channel.listTargets(); }
  catch (error) {
    if (!login) fail('deps', '受控浏览器未启动', 'pi-skill youtube login');
    await channel.launch({});
    targets = await channel.listTargets();
  }
  let target = targets.find(t => t.type === 'page' && /^https:\/\/www\.youtube\.com\//.test(t.url));
  if (!target) {
    // Background creation uses the existing CDP channel, not a second transport.
    const browser = await channel.connectBrowser();
    try {
      const created = await browser.send('Target.createTarget', { url: ORIGIN, background: true }, { timeoutMs: 10000 });
      target = { id: created.targetId };
    } finally { browser.close(); }
  }
  const { cdp } = await channel.connectPage(null, target.id);
  const call = async request => {
    let result;
    try { result = await channel.evaluate(cdp, `(${pageRequest.toString()})(${JSON.stringify({ ...request, timeout })})`, { timeoutMs: timeout + 2000 }); }
    catch (error) { fail('external', error.message, 'pi-skill youtube check'); }
    if (!result?.ok) fail(result?.error || 'external', result?.message || 'YouTube 没有返回结果', 'pi-skill youtube login', { needHuman: ['auth', 'blocked'].includes(result?.error) });
    return result.data;
  };
  try {
    const until = Date.now() + Math.min(timeout, 10000);
    while (true) {
      const ready = await channel.evaluate(cdp, '!!window.ytcfg?.get("INNERTUBE_CONTEXT")', { timeoutMs: 5000 });
      if (ready) break;
      if (Date.now() >= until) fail('blocked', 'YouTube 页面尚未就绪', 'pi-skill youtube login', { needHuman: true });
      await new Promise(resolve => setTimeout(resolve, 150));
    }
    return {
      target: target.id,
      request: (endpoint, body = {}) => call({ op: 'api', endpoint, body }),
      page: path => call({ op: 'page', path }),
      close: () => cdp.close(),
    };
  } catch (error) { cdp.close(); throw error; }
}

/** Sign out of YouTube by clearing the site's own storage in the browser. */
export async function signOut({ timeout = 25000 } = {}) {
  let targets;
  try { targets = await channel.listTargets(); }
  catch (error) { fail('deps', '受控浏览器未启动', 'M-x etaf-youtube-login'); }
  const target = targets.find(t => t.type === 'page' && /^https:\/\/www\.youtube\.com\//.test(t.url));
  if (!target) return { signed_in: false, state: 'already-out' };
  const { cdp } = await channel.connectPage(null, target.id);
  try {
    await cdp.send('Storage.clearDataForOrigin', {
      origin: ORIGIN,
      storageTypes: 'cookies,local_storage,indexeddb,service_workers,cache_storage',
    }, { timeoutMs: timeout });
    await cdp.send('Page.navigate', { url: 'https://www.youtube.com/' }, { timeoutMs: timeout });
  } finally { cdp.close?.(); }
  return { signed_in: false, state: 'signed-out' };
}
