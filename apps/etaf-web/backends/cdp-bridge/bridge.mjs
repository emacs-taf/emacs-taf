#!/usr/bin/env node
// Persistent single-Chromium CDP bridge for ETAF Web Tier 3.
// Protocol: line-delimited JSON (NDJSON) over stdin/stdout.
// Requires Node.js 22+ (native WebSocket); zero external npm dependencies.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DISTILLER_SOURCE = fs.readFileSync(path.join(__dirname, "distiller.js"), "utf8");

const IDLE_SHUTDOWN_MS = 5 * 60 * 1000;
const POLL_INTERVAL_MS = 650;

const CHROME_CANDIDATES = [
  process.env.ETAF_WEB_CHROME,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome",
  "/usr/bin/google-chrome-stable",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
].filter(Boolean);

function findChrome() {
  for (const p of CHROME_CANDIDATES) {
    try {
      if (fs.existsSync(p)) return p;
    } catch (_) {}
  }
  return null;
}

function send(obj) {
  try {
    process.stdout.write(JSON.stringify(obj) + "\n");
  } catch (_) {}
}

class CDPClient {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.ws = null;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Set();
  }

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.wsUrl);
      this.ws = ws;
      let opened = false;
      ws.addEventListener("open", () => {
        opened = true;
        resolve();
      });
      ws.addEventListener("error", (ev) => {
        if (!opened) reject(new Error(`WebSocket connection failed: ${ev.message || "error"}`));
      });
      ws.addEventListener("close", () => {
        for (const { reject: rej } of this.pending.values()) {
          rej(new Error("CDP WebSocket closed"));
        }
        this.pending.clear();
      });
      ws.addEventListener("message", (ev) => {
        let msg;
        try {
          msg = JSON.parse(String(ev.data));
        } catch (_) {
          return;
        }
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve: res, reject: rej } = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          if (msg.error) rej(new Error(msg.error.message || JSON.stringify(msg.error)));
          else res(msg.result || {});
        } else if (msg.method) {
          for (const fn of this.listeners) {
            try { fn(msg); } catch (_) {}
          }
        }
      });
    });
  }

  call(method, params = {}, sessionId = undefined) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("CDP client is not connected"));
    }
    const id = this.nextId++;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout on ${method}`));
        }
      }, 15000);
      this.pending.set(id, {
        resolve: (val) => { clearTimeout(timer); resolve(val); },
        reject: (err) => { clearTimeout(timer); reject(err); },
      });
      this.ws.send(JSON.stringify(payload));
    });
  }

  close() {
    try { this.ws && this.ws.close(); } catch (_) {}
    this.ws = null;
  }
}

class Bridge {
  constructor() {
    this.chrome = null;
    this.cdp = null;
    this.starting = null;
    this.shuttingDown = false;
    this.tabs = new Map(); // tabId -> { targetId, sessionId, rev, lastDirtyRev, lastUrl, polling }
    this.idleTimer = null;
    this.profileDir = process.env.ETAF_WEB_CDP_PROFILE || "";
  }

  cancelIdleTimer() {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
  }

  scheduleIdleShutdown() {
    this.cancelIdleTimer();
    if (this.tabs.size > 0) return;
    this.idleTimer = setTimeout(() => {
      if (this.tabs.size === 0) this.stopChrome();
    }, IDLE_SHUTDOWN_MS);
  }

  stopChrome() {
    this.cancelIdleTimer();
    for (const tab of this.tabs.values()) {
      if (tab.pollTimer) clearInterval(tab.pollTimer);
    }
    this.tabs.clear();
    if (this.cdp) {
      this.cdp.close();
      this.cdp = null;
    }
    if (this.chrome) {
      try { this.chrome.kill("SIGTERM"); } catch (_) {}
      this.chrome = null;
    }
  }

  async stopChromeAsync(timeoutMs = 1500) {
    this.shuttingDown = true;
    this.cancelIdleTimer();
    for (const tab of this.tabs.values()) {
      if (tab.pollTimer) clearInterval(tab.pollTimer);
    }
    this.tabs.clear();
    const proc = this.chrome;
    const cdp = this.cdp;
    this.chrome = null;
    this.cdp = null;

    let exitPromise = Promise.resolve();
    if (proc && proc.exitCode === null && proc.signalCode === null) {
      exitPromise = new Promise((resolve) => {
        const timer = setTimeout(() => {
          try { proc.kill("SIGKILL"); } catch (_) {}
          resolve();
        }, timeoutMs);
        proc.once("exit", () => {
          clearTimeout(timer);
          resolve();
        });
      });
    }

    if (cdp) {
      try { await Promise.race([cdp.call("Browser.close"), new Promise((r) => setTimeout(r, 400))]); } catch (_) {}
      cdp.close();
    }
    if (proc && proc.exitCode === null && proc.signalCode === null) {
      try { proc.kill("SIGTERM"); } catch (_) {}
    }
    await exitPromise;
  }

  async ensureChrome(chromePath, profileDir) {
    if (this.cdp && this.chrome && !this.chrome.killed) return;
    if (this.starting) return this.starting;

    const exe = chromePath || findChrome();
    if (!exe) throw new Error("No Chromium/Chrome executable found");

    const userDataDir = profileDir || this.profileDir;
    if (userDataDir) fs.mkdirSync(userDataDir, { recursive: true });

    this.starting = new Promise((resolve, reject) => {
      const args = [
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--hide-scrollbars",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-sync",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-default-apps",
        "--mute-audio",
        "--blink-settings=imagesEnabled=false",
        "--remote-debugging-port=0",
        "--window-size=1280,900",
      ];
      if (userDataDir) args.push(`--user-data-dir=${userDataDir}`);
      if (process.env.ETAF_WEB_NO_PROXY === "1") args.push("--no-proxy-server");
      args.push("about:blank");

      const proc = spawn(exe, args, { stdio: ["ignore", "ignore", "pipe"] });
      this.chrome = proc;
      let settled = false;
      let errBuf = "";

      const timeout = setTimeout(() => {
        if (!settled) {
          settled = true;
          this.stopChrome();
          reject(new Error(`Timed out waiting for Chromium DevTools endpoint: ${errBuf.slice(-300)}`));
        }
      }, 15000);

      proc.stderr.on("data", async (chunk) => {
        errBuf += chunk.toString("utf8");
        const m = errBuf.match(/DevTools listening on (ws:\/\/[^\s]+)/);
        if (m && !settled) {
          settled = true;
          clearTimeout(timeout);
          try {
            const client = new CDPClient(m[1]);
            await client.connect();
            this.cdp = client;
            resolve();
          } catch (e) {
            this.stopChrome();
            reject(e);
          }
        }
      });

      proc.on("exit", (code, sig) => {
        if (!settled) {
          settled = true;
          clearTimeout(timeout);
          reject(new Error(`Chromium exited early (${code ?? sig}): ${errBuf.slice(-300)}`));
        } else if (!this.shuttingDown) {
          this.stopChrome();
          send({ event: "bridge_closed", reason: `Chromium exited (${code ?? sig})` });
        }
      });
    }).finally(() => {
      this.starting = null;
    });

    return this.starting;
  }

  async evalInTab(sessionId, expression) {
    const res = await this.cdp.call("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    }, sessionId);
    if (res.exceptionDetails) {
      throw new Error(res.exceptionDetails.text || "Page script exception");
    }
    return res.result ? res.result.value : null;
  }

  async injectDistiller(sessionId) {
    await this.evalInTab(sessionId, DISTILLER_SOURCE);
  }

  async distillTab(tabId) {
    const tab = this.tabs.get(tabId);
    if (!tab) return null;
    await this.injectDistiller(tab.sessionId);
    const ir = await this.evalInTab(tab.sessionId, "window.__etafWebDistiller.distill({ maxNodes: 320 })");
    if (!ir) return null;
    tab.rev += 1;
    tab.lastDirtyRev = ir.dirtyRev || 0;
    tab.lastUrl = ir.url || tab.lastUrl;
    return { rev: tab.rev, ir };
  }

  async waitForSubstantiveDom(sessionId, maxWaitMs = 4500) {
    const start = Date.now();
    let lastLen = -1;
    let stableAt = 0;
    while (Date.now() - start < maxWaitMs) {
      await new Promise((r) => setTimeout(r, 250));
      let probe;
      try {
        probe = await this.evalInTab(
          sessionId,
          "({ rs: document.readyState, len: (document.body && document.body.innerText ? document.body.innerText.trim().length : 0), controls: document.querySelectorAll('a[href],button,input,select,textarea').length })"
        );
      } catch (_) {
        // Page is mid-navigation; wait a bit more.
        continue;
      }
      if (!probe) continue;
      const substantive = probe.len >= 120 || probe.controls >= 6;
      if (substantive && probe.rs !== "loading") {
        if (probe.len === lastLen) {
          if (!stableAt) stableAt = Date.now();
          if (Date.now() - stableAt >= 350) return;
        } else {
          lastLen = probe.len;
          stableAt = 0;
        }
      }
    }
  }

  startPolling(tabId) {
    const tab = this.tabs.get(tabId);
    if (!tab || tab.pollTimer) return;
    tab.pollTimer = setInterval(async () => {
      if (tab.polling || !this.tabs.has(tabId)) return;
      tab.polling = true;
      try {
        const probe = await this.evalInTab(
          tab.sessionId,
          "window.__etafWebDistiller ? { rev: window.__etafWebDistiller.getDirtyRev(), url: location.href } : { reinject: true, url: location.href }"
        );
        if (!probe) return;
        if (probe.reinject || probe.rev !== tab.lastDirtyRev || probe.url !== tab.lastUrl) {
          const snap = await this.distillTab(tabId);
          if (snap) send({ event: "snapshot", tab: tabId, rev: snap.rev, ir: snap.ir });
        }
      } catch (_) {
        // Ignore transient navigation races.
      } finally {
        tab.polling = false;
      }
    }, POLL_INTERVAL_MS);
  }

  async handleOpen(req) {
    const tabId = String(req.tab);
    await this.ensureChrome(req.chrome, req.profile);
    this.cancelIdleTimer();

    let tab = this.tabs.get(tabId);
    if (!tab) {
      const { targetId } = await this.cdp.call("Target.createTarget", { url: "about:blank" });
      const { sessionId } = await this.cdp.call("Target.attachToTarget", { targetId, flatten: true });
      await this.cdp.call("Page.enable", {}, sessionId);
      await this.cdp.call("Runtime.enable", {}, sessionId);
      tab = { targetId, sessionId, rev: 0, lastDirtyRev: -1, lastUrl: "", polling: false, pollTimer: null };
      this.tabs.set(tabId, tab);
    }

    if (req.width && req.height) {
      await this.cdp.call("Emulation.setDeviceMetricsOverride", {
        width: Math.max(480, Math.min(1600, Number(req.width))),
        height: Math.max(600, Math.min(1200, Number(req.height))),
        deviceScaleFactor: 1,
        mobile: false,
      }, tab.sessionId).catch(() => {});
    }

    await this.cdp.call("Page.navigate", { url: req.url }, tab.sessionId);
    await this.waitForSubstantiveDom(tab.sessionId, Number(req.waitMs || 4500));
    const snap = await this.distillTab(tabId);
    let html = null;
    if (req.includeHtml) {
      html = await this.evalInTab(
        tab.sessionId,
        "document.documentElement ? document.documentElement.outerHTML : ''"
      ).catch(() => null);
    }
    this.startPolling(tabId);
    if (snap) {
      return html ? { rev: snap.rev, ir: snap.ir, html } : snap;
    }
    return html ? { rev: tab.rev, ir: null, html } : { rev: tab.rev, ir: null };
  }

  async handleAct(req) {
    const tabId = String(req.tab);
    const tab = this.tabs.get(tabId);
    if (!tab) throw new Error(`Unknown tab: ${tabId}`);
    await this.injectDistiller(tab.sessionId);
    const actRes = await this.evalInTab(
      tab.sessionId,
      `window.__etafWebDistiller.act(${JSON.stringify({
        kind: req.kind,
        wid: req.wid,
        value: req.value,
        submit: Boolean(req.submit),
        deltaY: req.deltaY,
      })})`
    );
    if (actRes && actRes.ok === false) {
      throw new Error(actRes.error || "Action failed");
    }
    // Brief settle for SPA state transitions or navigation.
    await new Promise((r) => setTimeout(r, 320));
    const snap = await this.distillTab(tabId);
    return { action: actRes, snapshot: snap };
  }

  async handleSnapshot(req) {
    const tabId = String(req.tab);
    const snap = await this.distillTab(tabId);
    if (!snap) throw new Error(`Unknown tab: ${tabId}`);
    return snap;
  }

  async handleClose(req) {
    const tabId = String(req.tab);
    const tab = this.tabs.get(tabId);
    if (!tab) return { closed: false };
    if (tab.pollTimer) clearInterval(tab.pollTimer);
    this.tabs.delete(tabId);
    if (this.cdp) {
      await this.cdp.call("Target.closeTarget", { targetId: tab.targetId }).catch(() => {});
    }
    this.scheduleIdleShutdown();
    return { closed: true };
  }

  async dispatch(req) {
    try {
      let result;
      switch (req.op) {
        case "ping": result = { ok: true, node: process.version }; break;
        case "open": result = await this.handleOpen(req); break;
        case "act": result = await this.handleAct(req); break;
        case "snapshot": result = await this.handleSnapshot(req); break;
        case "close": result = await this.handleClose(req); break;
        case "shutdown":
          await this.stopChromeAsync(1500);
          send({ id: req.id, ok: true, result: { shutdown: true } });
          process.exit(0);
        default:
          throw new Error(`Unsupported op: ${req.op}`);
      }
      send({ id: req.id, ok: true, result });
    } catch (err) {
      send({ id: req.id, ok: false, error: err && err.message ? err.message : String(err) });
    }
  }
}

const bridge = new Bridge();

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let req;
  try {
    req = JSON.parse(trimmed);
  } catch (err) {
    send({ id: null, ok: false, error: `Invalid JSON: ${err.message}` });
    return;
  }
  bridge.dispatch(req);
});

let exiting = false;
function cleanupAndExit() {
  if (exiting) return;
  exiting = true;
  bridge.stopChromeAsync(800).finally(() => process.exit(0));
}

rl.on("close", cleanupAndExit);
process.on("SIGTERM", cleanupAndExit);
process.on("SIGINT", cleanupAndExit);

send({ event: "ready", node: process.version });
