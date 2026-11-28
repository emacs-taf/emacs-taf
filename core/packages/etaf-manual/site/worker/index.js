import { DurableObject } from "cloudflare:workers";
import { StatsStore, handleRequest } from "./router.js";

export class DownloadStatsDO extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.store = new StatsStore(ctx.storage.sql);
    this.seedPromise = null;
    ctx.blockConcurrencyWhile(async () => {
      this.store.initSchema();
    });
  }

  async ensureSeeded() {
    if (this.store.isSeeded()) return;
    if (!this.seedPromise) {
      this.seedPromise = (async () => {
        const originHost = this.env.ORIGIN_HOST || "cn.etaf.top";
        const resp = await fetch(`https://${originHost}/packages/downloads.json`, {
          headers: { "cache-control": "no-cache" },
        });
        if (!resp.ok) {
          throw new Error(`seed fetch failed: ${resp.status}`);
        }
        const payload = await resp.json();
        this.store.applyBaseline(payload);
      })().finally(() => {
        this.seedPromise = null;
      });
    }
    await this.seedPromise;
  }

  async recordEvent(clientHash, pkg, kind, tsSec) {
    try {
      await this.ensureSeeded();
    } catch {
      // Proceed recording live installs even if baseline fetch had a transient error.
    }
    return this.store.recordEvent(clientHash, pkg, kind, tsSec);
  }

  async getSummary() {
    try {
      await this.ensureSeeded();
    } catch {
      // Return whatever live counts we have if origin baseline is unreachable.
    }
    return this.store.getSummary(Date.now());
  }
}

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, env, ctx);
  },
};
