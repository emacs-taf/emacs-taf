#!/usr/bin/env node
// cdn-url.mjs — 给网易云直链换到可用的 CDN 节点（内部原语，被 netease-music.sh 与 refresh-urls.sh 调用）
//
// 背景（2026-10-07 实测）：直链签名只签「路径 + 查询」，与主机名无关 —— 同一条 path+query
// 在 m801 是 206、在 m804 是 403。而两族地址各自只在自己的节点组上有效：
//   /jdymusic/（新链路）: m801 m802 m803 m701 m702 m703（m804/m704 可能整片 403）
//   /ymusic/（旧链路）  : m10 m11
// 所以拿到地址后先探一探：整族坏节点就整族换；修不好的条目原样保留（交给 build-queue 去跳过）。
//
// 用法：
//   node cdn-url.mjs [--all | --sample N] [--timeout MS] [--concurrency N] < urls.txt > fixed.txt
// 输入/输出都是每行 "<id>\t<level>\t<url>"（URL 必须是最后一个字段；没有 level 也可以）。
//   --sample N（默认 1）：每族只探 N 个样本，决定整族用哪个节点；快，给起播路径用。
//   --all：逐条探测并修复，修不好的行不输出；给地址保活的存量场景用。
// stderr：probed=<n> fixed=<n> dropped=<n> unverified=<n>
import process from 'node:process';

const DEFAULT_HOSTS = {
  jd: ['m801.music.126.net', 'm802.music.126.net', 'm803.music.126.net',
       'm701.music.126.net', 'm702.music.126.net', 'm703.music.126.net'],
  ym: ['m10.music.126.net', 'm11.music.126.net'],
};

function hostsFor(family) {
  const override = process.env[family === 'jd' ? 'NETEASE_CDN_HOSTS_JD' : 'NETEASE_CDN_HOSTS_YM'];
  const list = (override || '').split(',').map((s) => s.trim()).filter(Boolean);
  return list.length ? list : DEFAULT_HOSTS[family];
}

function familyOf(url) {
  if (url.includes('/jdymusic/')) return 'jd';
  if (url.includes('/ymusic/')) return 'ym';
  return null;
}

function hostOf(url) {
  try { return new URL(url).host; } catch { return ''; }
}

function withHost(url, host) {
  const u = new URL(url);
  u.host = host;
  return u.toString();
}

async function probe(url, timeoutMs) {
  try {
    const res = await fetch(url, {
      headers: { Range: 'bytes=0-1' },
      signal: AbortSignal.timeout(timeoutMs),
    });
    try { await res.body?.cancel(); } catch { /* ignore */ }
    if (process.env.NETEASE_CDN_DEBUG) console.error(`probe ${res.status} ${url.slice(0, 100)}`);
    return res.status === 200 || res.status === 206;
  } catch (error) {
    if (process.env.NETEASE_CDN_DEBUG) console.error(`probe ERR ${error.message} ${url.slice(0, 100)}`);
    return false;
  }
}

async function allProbes(urls, timeoutMs) {
  return Promise.all(urls.map((url) => probe(url, timeoutMs)));
}

// 候选节点并行试：第一个能服务全部样本的节点胜出。串行下「当前节点坏」要先等它超时
// 才轮到下一个，起播探测实测多花半秒；并行后只等最快的一个回合。
async function pickHost(family, samples, timeoutMs) {
  const candidates = [];
  for (const url of samples) {
    const host = hostOf(url);
    if (host && !candidates.includes(host)) candidates.push(host);
  }
  for (const host of hostsFor(family)) {
    if (!candidates.includes(host)) candidates.push(host);
  }
  if (!candidates.length) return null;
  return new Promise((resolve) => {
    let left = candidates.length;
    for (const host of candidates) {
      allProbes(samples.map((url) => withHost(url, host)), timeoutMs).then((ok) => {
        if (ok.every(Boolean)) resolve(host);
        else if (--left === 0) resolve(null);
      });
    }
  });
}

function parseArgs(argv) {
  const opts = { all: false, sample: 1, timeout: 2500, concurrency: 8 };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--all') opts.all = true;
    else if (arg === '--sample') opts.sample = Math.max(1, parseInt(argv[++i], 10) || 1);
    else if (arg === '--timeout') opts.timeout = Math.max(200, parseInt(argv[++i], 10) || 2500);
    else if (arg === '--concurrency') opts.concurrency = Math.max(1, parseInt(argv[++i], 10) || 8);
    else if (arg === '--help' || arg === '-h') {
      console.log('用法：cdn-url.mjs [--all | --sample N] [--timeout MS] [--concurrency N] < urls.txt > fixed.txt');
      process.exit(0);
    }
  }
  return opts;
}

function readStdin() {
  return new Promise((resolve) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
  });
}

async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await fn(items[index], index);
    }
  });
  await Promise.all(workers);
  return results;
}

function parseLine(line) {
  const parts = line.split('\t');
  return { prefix: parts.slice(0, -1), url: parts[parts.length - 1] };
}

function emit(entry) {
  return [...entry.prefix, entry.url].join('\t');
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const entries = (await readStdin())
    .split('\n')
    .filter((line) => line.trim())
    .map((line) => {
      const { prefix, url } = parseLine(line);
      return { prefix, url, original: url, family: familyOf(url), fixed: false };
    });

  let probed = 0;
  let fixed = 0;
  let dropped = 0;
  let unverified = 0;

  if (opts.all) {
    // 只探真实 CDN 地址；本地文件路径/其它地址原样保留
    const results = await mapLimit(
      entries,
      opts.concurrency,
      (entry) => (entry.family ? probe(entry.url, opts.timeout) : true),
    );
    probed += entries.filter((entry) => entry.family).length;
    const bad = entries.filter((entry, index) => !results[index] && entry.family);
    for (const family of ['jd', 'ym']) {
      const broken = bad.filter((entry) => entry.family === family);
      if (!broken.length) continue;
      const host = await pickHost(family, broken.slice(0, opts.sample).map((entry) => entry.url), opts.timeout);
      if (!host) { unverified += broken.length; continue; }
      const probes = await mapLimit(broken, opts.concurrency, (entry) => {
        probed += 1;
        return probe(withHost(entry.url, host), opts.timeout);
      });
      broken.forEach((entry, index) => {
        if (probes[index]) {
          entry.url = withHost(entry.url, host);
          entry.fixed = true;
        } else {
          entry.drop = true;
        }
      });
    }
    for (const entry of entries) {
      if (entry.drop) { dropped += 1; continue; }
      if (entry.fixed) fixed += 1;
      console.log(emit(entry));
    }
  } else {
    for (const family of ['jd', 'ym']) {
      const group = entries.filter((entry) => entry.family === family);
      if (!group.length) continue;
      const samples = group.slice(0, opts.sample).map((entry) => entry.url);
      probed += samples.length;
      const ok = await allProbes(samples, opts.timeout);
      if (ok.every(Boolean)) continue; // 原节点就能用，整族不动
      const host = await pickHost(family, samples, opts.timeout);
      if (!host) { unverified += group.length; continue; }
      const before = group.map((entry) => entry.url);
      group.forEach((entry) => { entry.url = withHost(entry.url, host); });
      // 换完抽查：节点服务不齐（个别文件 404）就退回原样，宁可不换
      const tail = [group[0].url];
      if (group.length > 1) tail.push(group[group.length - 1].url);
      probed += tail.length;
      const verified = await allProbes(tail, opts.timeout);
      if (!verified.every(Boolean)) {
        group.forEach((entry, index) => { entry.url = before[index]; });
        unverified += group.length;
      } else {
        fixed += group.filter((entry, index) => entry.url !== before[index]).length;
      }
    }
    for (const entry of entries) console.log(emit(entry));
  }

  console.error(`probed=${probed} fixed=${fixed} dropped=${dropped} unverified=${unverified}`);
}

main().catch((error) => {
  console.error(`error=${error.message}`);
  process.exit(1);
});
