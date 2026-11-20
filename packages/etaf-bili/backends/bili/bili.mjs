#!/usr/bin/env node
// Bilibili account backend: sign-in, sign-out and status for the ETAF client.
//
// The client's data requests run through curl with a Netscape cookie jar; this
// backend reads and writes that same jar so a sign-in made here is immediately
// visible to every later request. Only Node.js is required: the QR encoder is
// vendored beside this file (MIT, Kazuhiko Arase).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const qrcode = require('./vendor/qrcode.js');

const ORIGIN = 'https://www.bilibili.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const JAR = process.env.ETAF_BILI_COOKIE_FILE
  || path.join(process.env.ETAF_BILI_STATE_DIRECTORY || path.join(os.homedir(), '.emacs.d', 'etaf-bili'), 'cookies.txt');

const emit = value => { process.stdout.write(JSON.stringify(value) + '\n'); };
const fail = (error, message, hint) => { emit({ ok: false, error, message, hint }); process.exit(0); };

function readJar() {
  try {
    return fs.readFileSync(JAR, 'utf8').split('\n').filter(Boolean).flatMap(line => {
      if (line.startsWith('#')) return [];
      const httpOnly = line.startsWith('#HttpOnly_');
      const fields = (httpOnly ? line.slice('#HttpOnly_'.length) : line).split('\t');
      if (fields.length !== 7) return [];
      const [domain, tail, pathname, secure, expires, name, value] = fields;
      return [{ domain, tail, pathname, secure, expires, name, value }];
    });
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

function jarHeader(cookies) {
  return cookies.map(c => `${c.name}=${c.value}`).join('; ');
}

function writeJar(cookies) {
  fs.mkdirSync(path.dirname(JAR), { recursive: true, mode: 0o700 });
  const header = '# Netscape HTTP Cookie File\n# Written by etaf-bili; curl reads this file.\n';
  const lines = cookies.map(c => `${c.tail ? '#HttpOnly_' : ''}${c.domain}\t${c.tail ? 'TRUE' : 'FALSE'}\t${c.pathname}\t${c.secure ? 'TRUE' : 'FALSE'}\t${c.expires}\t${c.name}\t${c.value}`);
  fs.writeFileSync(JAR, header + lines.join('\n') + '\n', { mode: 0o600 });
}

function bilibili(cookies) {
  return cookies.filter(c => /(^|\.)bilibili\.(com|tv)$/.test(c.domain) || c.domain === 'bilibili.com');
}

async function get(url, cookies) {
  const response = await fetch(url, {
    headers: { 'user-agent': UA, referer: `${ORIGIN}/`, cookie: jarHeader(cookies) },
  });
  const text = await response.text();
  try { return { body: JSON.parse(text), response }; }
  catch { fail('external', `Bilibili 返回了无法解析的内容（HTTP ${response.status}）`, '稍后重试'); }
}

function collectSetCookies(response, previous) {
  const now = Math.floor(Date.now() / 1000);
  const merged = new Map(previous.map(c => [`${c.domain}\t${c.name}`, c]));
  const headers = typeof response.headers.getSetCookie === 'function'
    ? response.headers.getSetCookie()
    : (response.headers.get('set-cookie') ? [response.headers.get('set-cookie')] : []);
  for (const header of headers) {
    const [pair, ...attributes] = header.split(';');
    const index = pair.indexOf('=');
    if (index < 0) continue;
    const name = pair.slice(0, index).trim();
    const value = pair.slice(index + 1).trim();
    if (!name) continue;
    let domain = '.bilibili.com';
    let pathname = '/';
    let expires = now + 30 * 24 * 3600;
    let secure = true;
    let httpOnly = false;
    for (const attribute of attributes) {
      const [rawKey, ...rest] = attribute.split('=');
      const key = rawKey.trim().toLowerCase();
      const attributeValue = rest.join('=').trim();
      if (key === 'domain' && attributeValue) domain = attributeValue.startsWith('.') ? attributeValue : `.${attributeValue}`;
      else if (key === 'path' && attributeValue) pathname = attributeValue;
      else if (key === 'expires') {
        const stamp = Date.parse(attributeValue);
        if (!Number.isNaN(stamp)) expires = Math.floor(stamp / 1000);
      } else if (key === 'max-age' && Number(attributeValue)) expires = now + Number(attributeValue);
      else if (key === 'secure') secure = true;
      else if (key === 'httponly') httpOnly = true;
    }
    merged.set(`${domain}\t${name}`, { domain, tail: httpOnly, pathname, secure, expires, name, value });
  }
  return [...merged.values()];
}

/** Cookies carried by the success URL the poll returns. */
function cookiesFromUrl(url, previous) {
  const now = Math.floor(Date.now() / 1000);
  const merged = new Map(previous.map(c => [`${c.domain}\t${c.name}`, c]));
  const query = new URL(url).searchParams;
  for (const [name, value] of query) {
    if (!value || ['gourl', 'timestamp', 'refresh_token', 'expires'].includes(name)) continue;
    merged.set(`.bilibili.com\t${name}`, {
      domain: '.bilibili.com', tail: name === 'SESSDATA', pathname: '/', secure: true,
      expires: now + 180 * 24 * 3600, name, value,
    });
  }
  return [...merged.values()];
}

function matrixFor(text) {
  const code = qrcode(0, 'M');
  code.addData(text);
  code.make();
  const size = code.getModuleCount();
  const rows = [];
  for (let row = 0; row < size; row += 1) {
    let line = '';
    for (let column = 0; column < size; column += 1) line += code.isDark(row, column) ? '1' : '0';
    rows.push(line);
  }
  return { size, rows };
}

async function check() {
  const cookies = readJar();
  const { body } = await get('https://api.bilibili.com/x/web-interface/nav', cookies);
  const data = body?.data || {};
  emit({ ok: true, signed_in: !!data.isLogin, name: data.uname || null, account: data.mid || null });
}

async function loginStart() {
  const { body } = await get('https://passport.bilibili.com/x/passport-login/web/qrcode/generate', readJar());
  if (body?.code !== 0 || !body?.data?.qrcode_key) {
    fail('external', body?.message || 'Bilibili 没有返回登录二维码', '稍后重试');
  }
  const { url, qrcode_key: key } = body.data;
  const { size, rows } = matrixFor(url);
  emit({ ok: true, key, url, size, rows });
}

async function loginPoll(key) {
  if (!key) fail('usage', '缺少 qrcode_key', 'etaf-bili-login');
  const { body, response } = await get(
    `https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=${encodeURIComponent(key)}`,
    readJar(),
  );
  const data = body?.data || {};
  if (body?.code !== 0) fail('external', body?.message || 'Bilibili 登录查询失败', '稍后重试');
  switch (data.code) {
    case 86101: emit({ ok: true, state: 'waiting' }); return;
    case 86090: emit({ ok: true, state: 'scanned' }); return;
    case 86038: emit({ ok: true, state: 'expired' }); return;
    case 0: break;
    default: emit({ ok: true, state: 'waiting' }); return;
  }
  const cookies = cookiesFromUrl(data.url || '', collectSetCookies(response, readJar()));
  writeJar(bilibili(cookies));
  const { body: nav } = await get('https://api.bilibili.com/x/web-interface/nav', readJar());
  emit({ ok: true, state: 'signed-in', signed_in: !!nav?.data?.isLogin, name: nav?.data?.uname || null });
}

function phoneDigits(phone) {
  return String(phone || '').replace(/[^0-9]/g, '').replace(/^86(?=1\d{10}$)/, '');
}

async function smsSend(phone) {
  const tel = phoneDigits(phone);
  if (!/^1\d{10}$/.test(tel)) fail('usage', '手机号格式不对', '例如 +86 13800000000');
  const cookies = readJar();
  const csrf = cookies.find(c => c.name === 'bili_jct')?.value || '';
  const response = await fetch('https://passport.bilibili.com/x/passport-login/web/sms/send', {
    method: 'POST',
    headers: {
      'user-agent': UA, referer: `${ORIGIN}/`, cookie: jarHeader(cookies),
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ cid: '86', tel, source: 'main-fe-header', platform: 'web', csrf }),
  });
  const body = await response.json().catch(() => ({}));
  if (body.code === 0) emit({ ok: true, message: '验证码已发送' });
  else emit({ ok: false, error: body.code === -105 ? 'captcha' : 'external',
              message: body.message || '发送验证码失败' });
}

async function smsLogin(phone, code) {
  const tel = phoneDigits(phone);
  if (!/^1\d{10}$/.test(tel)) fail('usage', '手机号格式不对', '例如 +86 13800000000');
  if (!/^\d{4,8}$/.test(String(code || ''))) fail('usage', '验证码格式不对', '输入短信里的数字');
  const cookies = readJar();
  const csrf = cookies.find(c => c.name === 'bili_jct')?.value || '';
  const response = await fetch('https://passport.bilibili.com/x/passport-login/web/login/sms', {
    method: 'POST',
    headers: {
      'user-agent': UA, referer: `${ORIGIN}/`, cookie: jarHeader(cookies),
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ cid: '86', tel, code: String(code), source: 'main-fe-header', platform: 'web', csrf }),
  });
  const body = await response.json().catch(() => ({}));
  if (body.code !== 0) {
    emit({ ok: false, error: body.code === -105 ? 'captcha' : 'auth',
           message: body.message || '手机号登录失败' });
    return;
  }
  writeJar(bilibili(cookiesFromUrl(body.data?.url || '', collectSetCookies(response, readJar()))));
  const { body: nav } = await get('https://api.bilibili.com/x/web-interface/nav', readJar());
  emit({ ok: true, signed_in: !!nav?.data?.isLogin, name: nav?.data?.uname || null });
}

async function logout() {
  const cookies = readJar();
  const csrf = cookies.find(c => c.name === 'bili_jct')?.value;
  if (csrf) {
    await fetch('https://passport.bilibili.com/login/exit/v2', {
      method: 'POST',
      headers: {
        'user-agent': UA, referer: `${ORIGIN}/`, cookie: jarHeader(cookies),
        'content-type': 'application/x-www-form-urlencoded',
      },
      body: `biliCSRF=${encodeURIComponent(csrf)}`,
    }).catch(() => {});
  }
  writeJar(readJar().filter(c => !/(^|\.)bilibili\.(com|tv)$/.test(c.domain)));
  emit({ ok: true, signed_in: false });
}

const [command, ...args] = process.argv.slice(2);
try {
  if (command === 'check') await check();
  else if (command === 'login-start') await loginStart();
  else if (command === 'login-poll') await loginPoll(args[0]);
  else if (command === 'sms-send') await smsSend(args[0]);
  else if (command === 'sms-login') await smsLogin(args[0], args[1]);
  else if (command === 'logout') await logout();
  else fail('usage', `未知命令 ${command || '(空)'}`, 'check | login-start | login-poll KEY | sms-send PHONE | sms-login PHONE CODE | logout');
} catch (error) {
  fail('external', String(error?.message || error), '检查网络后重试');
}
