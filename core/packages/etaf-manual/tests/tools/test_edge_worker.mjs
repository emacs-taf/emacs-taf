import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { classifyPath, handleRequest, StatsStore } from "../../site/worker/router.js";

function makeSqlAdapter() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query, ...params) {
      if (params.length === 0 && query.includes(";")) {
        db.exec(query);
        return { toArray: () => [] };
      }
      const stmt = db.prepare(query);
      if (/^\s*(SELECT|WITH)|RETURNING\b/i.test(query)) {
        const rows = stmt.all(...params);
        return { toArray: () => rows };
      }
      stmt.run(...params);
      return { toArray: () => [] };
    },
  };
}

test("classifyPath separates immutable, media, fresh manifests and docs", () => {
  const tar = classifyPath("/packages/etaf-0.8.2.tar");
  assert.equal(tar.kind, "immutable");
  assert.equal(tar.cnRedirect, true);
  assert.equal(tar.edgeTtl, 31536000);
  assert.deepEqual(tar.packageEvent, { pkg: "etaf", kind: "tar" });

  const sig = classifyPath("/packages/etaf-0.8.2.tar.sig");
  assert.equal(sig.kind, "fresh");
  assert.equal(sig.cnRedirect, false);
  assert.deepEqual(sig.packageEvent, { pkg: "etaf", kind: "sig" });

  const nativeBin = classifyPath("/native/ekp/0.1.0/ekp-module-darwin-arm64.dylib");
  assert.equal(nativeBin.kind, "immutable");
  assert.equal(nativeBin.cnRedirect, true);

  const nativeManifest = classifyPath("/native/manifest.json");
  assert.equal(nativeManifest.kind, "fresh");
  assert.equal(nativeManifest.cnRedirect, false);
  assert.equal(nativeManifest.edgeTtl, 0);

  const mediaVideo = classifyPath("/media/etaf-md/demo.mp4");
  assert.equal(mediaVideo.kind, "media");
  assert.equal(mediaVideo.cnRedirect, true);
  assert.equal(mediaVideo.edgeTtl, 3600);

  for (const ogPath of [
    "/og/landing.png",
    "/og/zh-cn.png",
    "/og/manual.png",
    "/og/manual-zh.png",
    "/packages/og.png",
    "/native/og.png",
    "/media/og.png",
  ]) {
    const og = classifyPath(ogPath);
    assert.equal(og.kind, "og", `expected og route for ${ogPath}`);
    assert.equal(og.cnRedirect, false, `OG card must not 302-redirect in CN: ${ogPath}`);
    assert.equal(og.edgeTtl, 3600);
    assert.equal(og.browserCacheControl, "public, max-age=3600");
  }

  const mediaManifest = classifyPath("/media/manifest.json");
  assert.equal(mediaManifest.kind, "fresh");
  assert.equal(mediaManifest.cnRedirect, false);

  const pkgIndex = classifyPath("/packages/archive-contents");
  assert.equal(pkgIndex.kind, "fresh");
  assert.equal(pkgIndex.edgeTtl, 0);

  const astroAsset = classifyPath("/_astro/app.abc123.js");
  assert.equal(astroAsset.kind, "immutable");
  assert.equal(astroAsset.cnRedirect, false);

  const docs = classifyPath("/zh-cn/introduction/");
  assert.equal(docs.kind, "docs");
  assert.equal(docs.cnRedirect, false);
  assert.equal(docs.edgeTtl, 300);
});

test("CN requests for large assets return 302 to cn.etaf.top and still record tar events", async () => {
  const recorded = [];
  const pending = [];
  const env = {
    ORIGIN_HOST: "cn.etaf.top",
    CN_REDIRECT_HOST: "cn.etaf.top",
    CN_REDIRECT_ENABLED: "true",
  };
  const req = new Request("https://etaf.top/packages/etaf-0.8.2.tar", {
    headers: { "cf-ipcountry": "CN", "cf-connecting-ip": "1.2.3.4" },
  });
  const resp = await handleRequest(
    req,
    env,
    { waitUntil: (p) => pending.push(p) },
    {
      fetch: () => {
        throw new Error("should not hit origin on CN redirect");
      },
      statsStub: {
        recordEvent: async (...args) => {
          recorded.push(args);
        },
      },
    },
  );
  await Promise.all(pending);

  assert.equal(resp.status, 302);
  assert.equal(resp.headers.get("location"), "https://cn.etaf.top/packages/etaf-0.8.2.tar");
  assert.equal(resp.headers.get("x-etaf-edge"), "cn-redirect");
  assert.equal(resp.headers.get("cache-control"), "private, no-store");
  assert.equal(recorded.length, 1);
  assert.equal(recorded[0][1], "etaf");
  assert.equal(recorded[0][2], "tar");
});

test("deployment verification query bypasses CN redirect, cache and counting", async () => {
  const calls = [];
  const env = { ORIGIN_HOST: "cn.etaf.top", CN_REDIRECT_ENABLED: "true" };
  const req = new Request("https://etaf.top/packages/etaf-0.8.2.tar?deployment=20261128T000000Z", {
    headers: { "cf-ipcountry": "CN" },
  });
  const resp = await handleRequest(
    req,
    env,
    { waitUntil: () => {} },
    {
      fetch: async (url, init) => {
        calls.push({ url, init });
        return new Response("tar-bytes", { status: 200 });
      },
      statsStub: {
        recordEvent: async () => {
          throw new Error("deployment checks must not be counted");
        },
      },
    },
  );

  assert.equal(resp.status, 200);
  assert.equal(await resp.text(), "tar-bytes");
  assert.equal(resp.headers.get("x-etaf-edge"), "bypass");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://cn.etaf.top/packages/etaf-0.8.2.tar?deployment=20261128T000000Z");
  assert.equal(calls[0].init.cf.cacheTtl, 0);
});

test("overseas tarball fetch uses 1-year CF edge cache and records install event", async () => {
  const calls = [];
  const recorded = [];
  const pending = [];
  const env = { ORIGIN_HOST: "cn.etaf.top", CN_REDIRECT_ENABLED: "true" };
  const req = new Request("https://etaf.top/packages/ebox-0.5.0.tar", {
    headers: { "cf-ipcountry": "US", "cf-connecting-ip": "8.8.8.8" },
  });
  const resp = await handleRequest(
    req,
    env,
    { waitUntil: (p) => pending.push(p) },
    {
      fetch: async (url, init) => {
        calls.push({ url, init });
        return new Response("ebox-tar", { status: 200 });
      },
      statsStub: {
        recordEvent: async (...args) => recorded.push(args),
      },
    },
  );
  await Promise.all(pending);

  assert.equal(resp.status, 200);
  assert.equal(resp.headers.get("x-etaf-edge"), "immutable");
  assert.equal(resp.headers.get("cache-control"), "public, max-age=31536000, immutable");
  assert.equal(calls[0].init.cf.cacheEverything, true);
  assert.equal(calls[0].init.cf.cacheTtlByStatus["200-299"], 31536000);
  assert.equal(recorded.length, 1);
  assert.equal(recorded[0][1], "ebox");
  assert.equal(recorded[0][2], "tar");
});

test("404 responses on immutable routes never emit long-lived Cache-Control", async () => {
  const env = { ORIGIN_HOST: "cn.etaf.top", CN_REDIRECT_ENABLED: "true" };
  const req = new Request("https://etaf.top/packages/missing-1.0.0.tar", {
    headers: { "cf-ipcountry": "US" },
  });
  const resp = await handleRequest(
    req,
    env,
    { waitUntil: () => {} },
    {
      fetch: async () =>
        new Response("Not Found", {
          status: 404,
          headers: { "cache-control": "public, max-age=31536000, immutable" },
        }),
    },
  );
  assert.equal(resp.status, 404);
  assert.equal(resp.headers.get("cache-control"), "no-store");
});

test("StatsStore pairs tar + sig within 60s, deduplicates daily, and merges baseline", () => {
  const store = new StatsStore(makeSqlAdapter());
  store.initSchema();
  assert.equal(store.isSeeded(), false);

  store.applyBaseline({
    schema: 1,
    since: "2026-10-27T13:56:28Z",
    total: 10,
    packages: { etaf: 7, ebox: 3 },
  });
  assert.equal(store.isSeeded(), true);

  // Unpaired tar (crawler/curl) does not count.
  assert.equal(store.recordEvent("h1", "etaf", "tar", 1_700_000_000), false);
  // Matching sig 15s later pairs and counts once.
  assert.equal(store.recordEvent("h1", "etaf", "sig", 1_700_000_015), true);
  // Same client same UTC day reinstalling does not double-count.
  assert.equal(store.recordEvent("h1", "etaf", "tar", 1_700_000_200), false);
  assert.equal(store.recordEvent("h1", "etaf", "sig", 1_700_000_205), false);
  // Sig arriving more than 60s apart does not pair.
  assert.equal(store.recordEvent("h2", "ebox", "sig", 1_700_000_000), false);
  assert.equal(store.recordEvent("h2", "ebox", "tar", 1_700_000_120), false);
  // Different client on same day DOES count (reverse order: sig then tar).
  assert.equal(store.recordEvent("h3", "etaf-md", "sig", 1_700_000_500), false);
  assert.equal(store.recordEvent("h3", "etaf-md", "tar", 1_700_000_510), true);

  const summary = store.getSummary(1_700_000_600_000);
  assert.equal(summary.schema, 1);
  assert.equal(summary.since, "2026-10-27T13:56:28Z");
  assert.equal(summary.total, 12);
  assert.deepEqual(summary.packages, { ebox: 3, etaf: 8, "etaf-md": 1 });
});
