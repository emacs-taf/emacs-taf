/**
 * Pure routing, caching and install-counting logic for the etaf.top edge Worker.
 *
 * Kept free of `cloudflare:*` imports so Node's built-in test runner can verify
 * every route, header, redirect and counting rule directly without mocks.
 */

export const ARCHIVE_RE = /^\/packages\/([a-z][a-z0-9-]*)-[0-9]+(?:\.[0-9]+)*\.tar$/;
export const SIGNATURE_RE = /^\/packages\/([a-z][a-z0-9-]*)-[0-9]+(?:\.[0-9]+)*\.tar\.sig$/;
export const NATIVE_ASSET_RE = /^\/native\/[a-z][a-z0-9-]*\/[0-9]+(?:\.[0-9]+)*\/[a-z0-9][a-z0-9._-]*\.(?:dylib|so|dll)$/;
export const OG_IMAGE_RE = /^(?:\/og\/[a-z0-9-]+\.png|\/(?:packages|native|media)\/og\.png)$/;
export const MEDIA_ASSET_RE = /^\/media\/(?!manifest\.json$|index\.html$|og\.png$).+\.(?:webp|png|jpe?g|gif|svg|avif|mp4|webm|mov|pdf)$/i;
export const PAIRING_SECONDS = 60;

/**
 * Classify a URL pathname into its caching and geo-routing policy.
 *
 * Returns:
 * - kind: "health" | "stats" | "immutable" | "og" | "media" | "fresh" | "docs"
 * - cnRedirect: true when Mainland China clients should receive a 302 to cn.etaf.top
 * - edgeTtl: Cloudflare edge cache TTL in seconds (0 = do not edge-cache)
 * - browserCacheControl: Cache-Control returned to clients
 * - packageEvent: { pkg, kind: "tar" | "sig" } | null
 */
export function classifyPath(pathname) {
  if (pathname === "/_edge/health") {
    return {
      kind: "health",
      cnRedirect: false,
      edgeTtl: 0,
      browserCacheControl: "no-store",
      packageEvent: null,
    };
  }

  if (pathname === "/packages/downloads.json") {
    return {
      kind: "stats",
      cnRedirect: false,
      edgeTtl: 60,
      browserCacheControl: "public, max-age=60",
      packageEvent: null,
    };
  }

  const tarMatch = ARCHIVE_RE.exec(pathname);
  if (tarMatch) {
    return {
      kind: "immutable",
      cnRedirect: true,
      edgeTtl: 31536000,
      browserCacheControl: "public, max-age=31536000, immutable",
      packageEvent: { pkg: tarMatch[1], kind: "tar" },
    };
  }

  const sigMatch = SIGNATURE_RE.exec(pathname);
  if (sigMatch) {
    return {
      kind: "fresh",
      cnRedirect: false,
      edgeTtl: 0,
      browserCacheControl: "no-cache",
      packageEvent: { pkg: sigMatch[1], kind: "sig" },
    };
  }

  if (NATIVE_ASSET_RE.test(pathname)) {
    return {
      kind: "immutable",
      cnRedirect: true,
      edgeTtl: 31536000,
      browserCacheControl: "public, max-age=31536000, immutable",
      packageEvent: null,
    };
  }

  if (pathname.startsWith("/_astro/")) {
    return {
      kind: "immutable",
      cnRedirect: false,
      edgeTtl: 31536000,
      browserCacheControl: "public, max-age=31536000, immutable",
      packageEvent: null,
    };
  }

  if (OG_IMAGE_RE.test(pathname)) {
    return {
      kind: "og",
      cnRedirect: false,
      edgeTtl: 3600,
      browserCacheControl: "public, max-age=3600",
      packageEvent: null,
    };
  }

  if (MEDIA_ASSET_RE.test(pathname)) {
    return {
      kind: "media",
      cnRedirect: true,
      edgeTtl: 3600,
      browserCacheControl: "public, max-age=3600",
      packageEvent: null,
    };
  }

  // Archive, native and media manifests + generated HTML indices must reflect
  // releases immediately so check-archive.py and M-x etaf-install never read
  // stale metadata or mismatched pages.
  if (
    pathname === "/packages" ||
    pathname.startsWith("/packages/") ||
    pathname === "/native" ||
    pathname.startsWith("/native/") ||
    pathname === "/media" ||
    pathname.startsWith("/media/")
  ) {
    return {
      kind: "fresh",
      cnRedirect: false,
      edgeTtl: 0,
      browserCacheControl: "no-cache",
      packageEvent: null,
    };
  }

  // Bilingual landing page and reference manual HTML/assets: cached 5 minutes
  // at Cloudflare global PoPs while browsers revalidate on demand.
  return {
    kind: "docs",
    cnRedirect: false,
    edgeTtl: 300,
    browserCacheControl: "no-cache",
    packageEvent: null,
  };
}

export function formatUtcIso(epochMs) {
  return new Date(epochMs).toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function utcDayString(epochSec) {
  return new Date(epochSec * 1000).toISOString().slice(0, 10);
}

export async function hashClientIp(ip) {
  const bytes = new TextEncoder().encode(ip || "unknown");
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const view = new Uint8Array(digest);
  let hex = "";
  for (let i = 0; i < 8; i++) {
    hex += view[i].toString(16).padStart(2, "0");
  }
  return hex;
}

/**
 * SQLite-backed download counter matching site/scripts/download-stats.py rules:
 * - Pairs a .tar and .tar.sig from the same hashed client within 60 seconds
 *   (in either arrival order).
 * - Counts each (package, client, UTC day) at most once.
 * - Merges cleanly with one-time historical baseline seeded from origin.
 */
export class StatsStore {
  constructor(sql) {
    this.sql = sql;
  }

  initSchema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS baseline (
        pkg TEXT PRIMARY KEY,
        count INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS pending (
        client_hash TEXT NOT NULL,
        pkg TEXT NOT NULL,
        kind TEXT NOT NULL,
        ts INTEGER NOT NULL,
        PRIMARY KEY (client_hash, pkg, kind)
      );
      CREATE TABLE IF NOT EXISTS installs (
        pkg TEXT NOT NULL,
        client_hash TEXT NOT NULL,
        day TEXT NOT NULL,
        PRIMARY KEY (pkg, client_hash, day)
      );
      CREATE TABLE IF NOT EXISTS live_counts (
        pkg TEXT PRIMARY KEY,
        count INTEGER NOT NULL
      );
    `);
  }

  isSeeded() {
    const rows = this.sql.exec("SELECT value FROM meta WHERE key = 'seeded'").toArray();
    return rows.length > 0 && rows[0].value === "1";
  }

  applyBaseline(payload) {
    if (this.isSeeded()) return false;
    const pkgs = payload && typeof payload.packages === "object" && payload.packages !== null
      ? payload.packages
      : {};
    for (const [pkg, rawCount] of Object.entries(pkgs)) {
      const count = Number(rawCount);
      if (Number.isInteger(count) && count > 0) {
        this.sql.exec(
          "INSERT OR REPLACE INTO baseline (pkg, count) VALUES (?, ?)",
          pkg,
          count,
        );
      }
    }
    if (typeof payload?.since === "string" && payload.since.length > 0) {
      this.sql.exec(
        "INSERT OR IGNORE INTO meta (key, value) VALUES ('since', ?)",
        payload.since,
      );
    }
    this.sql.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('seeded', '1')");
    return true;
  }

  recordEvent(clientHash, pkg, kind, tsSec) {
    if (kind !== "tar" && kind !== "sig") return false;
    const nowSec = Math.floor(tsSec);
    // Keep pending table bounded to recent pairing candidates.
    this.sql.exec("DELETE FROM pending WHERE ts < ?", nowSec - PAIRING_SECONDS * 5);
    this.sql.exec(
      "INSERT OR REPLACE INTO pending (client_hash, pkg, kind, ts) VALUES (?, ?, ?, ?)",
      clientHash,
      pkg,
      kind,
      nowSec,
    );

    const otherKind = kind === "tar" ? "sig" : "tar";
    const match = this.sql
      .exec(
        "SELECT ts FROM pending WHERE client_hash = ? AND pkg = ? AND kind = ?",
        clientHash,
        pkg,
        otherKind,
      )
      .toArray();
    if (match.length === 0) return false;

    const otherTs = Number(match[0].ts);
    if (Math.abs(otherTs - nowSec) > PAIRING_SECONDS) return false;

    const tarTs = kind === "tar" ? nowSec : otherTs;
    const day = utcDayString(tarTs);
    const inserted = this.sql
      .exec(
        "INSERT OR IGNORE INTO installs (pkg, client_hash, day) VALUES (?, ?, ?) RETURNING pkg",
        pkg,
        clientHash,
        day,
      )
      .toArray();
    if (inserted.length === 0) return false;

    this.sql.exec(
      `INSERT INTO live_counts (pkg, count) VALUES (?, 1)
       ON CONFLICT(pkg) DO UPDATE SET count = count + 1`,
      pkg,
    );
    const sinceRows = this.sql.exec("SELECT value FROM meta WHERE key = 'since'").toArray();
    if (sinceRows.length === 0) {
      this.sql.exec(
        "INSERT OR IGNORE INTO meta (key, value) VALUES ('since', ?)",
        formatUtcIso(tarTs * 1000),
      );
    }
    return true;
  }

  getSummary(nowMs = Date.now()) {
    const merged = new Map();
    for (const row of this.sql.exec("SELECT pkg, count FROM baseline").toArray()) {
      merged.set(row.pkg, (merged.get(row.pkg) || 0) + Number(row.count));
    }
    for (const row of this.sql.exec("SELECT pkg, count FROM live_counts").toArray()) {
      merged.set(row.pkg, (merged.get(row.pkg) || 0) + Number(row.count));
    }
    const packages = {};
    let total = 0;
    for (const pkg of [...merged.keys()].sort()) {
      const count = merged.get(pkg);
      if (count > 0) {
        packages[pkg] = count;
        total += count;
      }
    }
    const sinceRows = this.sql.exec("SELECT value FROM meta WHERE key = 'since'").toArray();
    return {
      as_of: formatUtcIso(nowMs),
      packages,
      schema: 1,
      since: sinceRows.length > 0 ? sinceRows[0].value : null,
      total,
    };
  }
}

function buildOriginHeaders(request) {
  const headers = new Headers();
  for (const name of ["accept", "range", "if-range", "if-none-match", "if-modified-since"]) {
    const val = request.headers.get(name);
    if (val !== null) headers.set(name, val);
  }
  headers.set("user-agent", request.headers.get("user-agent") || "etaf-edge-worker");
  return headers;
}

function buildClientResponse(originResp, method, edgeLabel, browserCacheControl) {
  const headers = new Headers(originResp.headers);
  if (originResp.status >= 400) {
    headers.set("cache-control", "no-store");
  } else if (originResp.status >= 200 && originResp.status < 400 && browserCacheControl) {
    headers.set("cache-control", browserCacheControl);
  }
  headers.set("x-etaf-edge", edgeLabel);
  const noBody = method === "HEAD" || originResp.status === 204 || originResp.status === 304;
  return new Response(noBody ? null : originResp.body, {
    status: originResp.status,
    statusText: originResp.statusText,
    headers,
  });
}

/**
 * Main edge request handler.
 *
 * Dependencies (`fetchFn`, `statsStub`, `waitUntil`) are injectable for unit tests.
 */
export async function handleRequest(request, env, ctx, deps = {}) {
  const fetchFn = deps.fetch || fetch;
  const url = new URL(request.url);
  const method = request.method.toUpperCase();

  if (method !== "GET" && method !== "HEAD") {
    return new Response("Method Not Allowed\n", {
      status: 405,
      headers: { allow: "GET, HEAD", "content-type": "text/plain; charset=utf-8" },
    });
  }

  const originHost = env.ORIGIN_HOST || "cn.etaf.top";
  const cnRedirectHost = env.CN_REDIRECT_HOST || originHost;
  const cnRedirectEnabled = String(env.CN_REDIRECT_ENABLED ?? "true").toLowerCase() === "true";
  const country = (request.cf && request.cf.country) || request.headers.get("cf-ipcountry") || "XX";
  const colo = (request.cf && request.cf.colo) || "LOCAL";
  const route = classifyPath(url.pathname);

  if (route.kind === "health") {
    return new Response(
      JSON.stringify(
        {
          ok: true,
          country,
          colo,
          origin_host: originHost,
          cn_redirect_host: cnRedirectHost,
          cn_redirect_enabled: cnRedirectEnabled,
        },
        null,
        2,
      ) + "\n",
      {
        status: 200,
        headers: {
          "content-type": "application/json; charset=utf-8",
          "cache-control": "no-store",
          "x-etaf-edge": "health",
        },
      },
    );
  }

  // Deployment byte verification (?deployment=<stamp>) and explicit ?origin=1
  // always bypass edge cache, CN redirect and install counting.
  const isBypass = url.searchParams.has("deployment") || url.searchParams.has("origin");
  const originUrl = `https://${originHost}${url.pathname}${url.search}`;

  if (isBypass) {
    const resp = await fetchFn(originUrl, {
      method,
      headers: buildOriginHeaders(request),
      cf: { cacheTtl: 0 },
    });
    return buildClientResponse(resp, method, "bypass", "no-store");
  }

  const getStatsStub = () => {
    if (deps.statsStub) return deps.statsStub;
    if (env.DOWNLOAD_STATS) return env.DOWNLOAD_STATS.getByName("global");
    return null;
  };

  if (route.kind === "stats") {
    const stub = getStatsStub();
    if (stub) {
      try {
        const summary = await stub.getSummary();
        return new Response(
          method === "HEAD" ? null : JSON.stringify(summary, null, 2) + "\n",
          {
            status: 200,
            headers: {
              "content-type": "application/json; charset=utf-8",
              "cache-control": route.browserCacheControl,
              "x-etaf-edge": "stats",
            },
          },
        );
      } catch {
        // Fall through to origin downloads.json if DO is temporarily unavailable.
      }
    }
    const resp = await fetchFn(originUrl, {
      method,
      headers: buildOriginHeaders(request),
      cf: { cacheEverything: true, cacheTtlByStatus: { "200-299": 60, "404": 0, "500-599": 0 } },
    });
    return buildClientResponse(resp, method, "stats-origin", route.browserCacheControl);
  }

  const schedulePackageEvent = (event) => {
    if (!event || method !== "GET") return;
    const stub = getStatsStub();
    if (!stub) return;
    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    const nowSec = Math.floor(Date.now() / 1000);
    const work = hashClientIp(ip)
      .then((clientHash) => stub.recordEvent(clientHash, event.pkg, event.kind, nowSec))
      .catch(() => {});
    if (ctx && typeof ctx.waitUntil === "function") {
      ctx.waitUntil(work);
    }
  };

  // Mainland China clients requesting large tarballs, native modules or media
  // assets get an immediate 302 to grey-cloud cn.etaf.top (aliyun-hk direct).
  if (cnRedirectEnabled && route.cnRedirect && country === "CN") {
    if (route.packageEvent && route.packageEvent.kind === "tar") {
      schedulePackageEvent(route.packageEvent);
    }
    return new Response(null, {
      status: 302,
      headers: {
        location: `https://${cnRedirectHost}${url.pathname}${url.search}`,
        "cache-control": "private, no-store",
        vary: "CF-IPCountry",
        "x-etaf-edge": "cn-redirect",
      },
    });
  }

  // Overseas and small-file traffic: proxy from origin with path-appropriate
  // Cloudflare global edge caching.
  const cfCache =
    route.edgeTtl > 0
      ? {
          cacheEverything: true,
          cacheTtlByStatus: {
            "200-299": route.edgeTtl,
            "404": route.kind === "docs" ? 30 : 0,
            "500-599": 0,
          },
        }
      : { cacheTtl: 0 };

  const originResp = await fetchFn(originUrl, {
    method,
    headers: buildOriginHeaders(request),
    cf: cfCache,
  });

  if (route.packageEvent) {
    if (route.packageEvent.kind === "sig" || originResp.status === 200) {
      schedulePackageEvent(route.packageEvent);
    }
  }

  return buildClientResponse(originResp, method, route.kind, route.browserCacheControl);
}
