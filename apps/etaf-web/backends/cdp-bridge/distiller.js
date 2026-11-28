// In-page semantic + layout distiller for ETAF Web Tier 3 (Live CDP).
// Runs inside the live page context; zero external dependencies.
(() => {
  if (window.__etafWebDistiller) return true;

  let nextWid = 1;
  const idToEl = new Map();
  const elToId = new WeakMap();
  let dirtyRev = 1;
  let mutationTimer = null;
  let observer = null;

  function ensureObserver() {
    if (observer || !document.body) return;
    observer = new MutationObserver(() => {
      if (mutationTimer) return;
      mutationTimer = setTimeout(() => {
        mutationTimer = null;
        dirtyRev += 1;
      }, 200);
    });
    observer.observe(document.body, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["class", "style", "hidden", "aria-expanded", "aria-selected", "open", "disabled", "value", "checked"],
    });
  }

  function getWid(el) {
    let wid = elToId.get(el);
    if (!wid) {
      wid = nextWid++;
      elToId.set(el, wid);
      idToEl.set(wid, new WeakRef(el));
    }
    return wid;
  }

  function resolveWid(wid) {
    const ref = idToEl.get(Number(wid));
    if (!ref) return null;
    const el = ref.deref();
    if (!el || !el.isConnected) {
      idToEl.delete(Number(wid));
      return null;
    }
    return el;
  }

  function cleanText(str) {
    return String(str || "")
      .replace(/[\uE000-\uF8FF\uFE0E\uFE0F]/g, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  const SKIP_TAGS = new Set([
    "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "META", "LINK", "HEAD", "SVG", "PATH", "BR", "WBR",
  ]);

  function isVisible(el) {
    if (!el || el.nodeType !== 1) return false;
    if (SKIP_TAGS.has(el.tagName)) return false;
    if (el.hidden || el.getAttribute("aria-hidden") === "true") return false;
    const cls = typeof el.className === "string" ? el.className : "";
    if (/\b(?:sr-only|visually-hidden|screen-reader-text)\b/i.test(cls)) return false;
    const cs = window.getComputedStyle(el);
    if (!cs) return false;
    if (cs.display === "none" || cs.visibility === "hidden") {
      return false;
    }
    const isNativeToggle =
      el.tagName === "INPUT" &&
      (el.type === "checkbox" || el.type === "radio");
    if (parseFloat(cs.opacity) === 0 && !isNativeToggle) {
      return false;
    }
    const r = el.getBoundingClientRect();
    if (r.width < 1 && r.height < 1) {
      // Allow display:contents containers and custom-styled checkboxes whose parent is visible.
      if (cs.display !== "contents" && !isNativeToggle) return false;
    }
    if (isNativeToggle && el.parentElement) {
      const pr = el.parentElement.getBoundingClientRect();
      if (pr.width < 1 && pr.height < 1) return false;
    }
    return true;
  }

  function labelForControl(el, visitedSet) {
    const aria = cleanText(el.getAttribute("aria-label"));
    if (aria) return aria;
    const labelledBy = el.getAttribute("aria-labelledby");
    if (labelledBy) {
      const texts = labelledBy
        .split(/\s+/)
        .map((id) => document.getElementById(id))
        .filter(Boolean)
        .map((n) => cleanText(n.textContent))
        .filter(Boolean);
      if (texts.length) return texts.join(" ");
    }
    if (el.id) {
      const lbl = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (lbl) {
        const t = cleanText(lbl.textContent);
        if (t) {
          if (visitedSet) visitedSet.add(lbl);
          return t;
        }
      }
    }
    const parentLabel = el.closest("label");
    if (parentLabel) {
      const t = cleanText(parentLabel.textContent);
      if (t) return t;
    }
    if (el.tagName === "INPUT" && (el.type === "checkbox" || el.type === "radio")) {
      const next = el.nextElementSibling;
      if (next && next.tagName === "LABEL" && !next.getAttribute("for")) {
        const t = cleanText(next.textContent);
        if (t) {
          if (visitedSet) visitedSet.add(next);
          return t;
        }
      }
    }
    return cleanText(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name") || "");
  }

  function detectCanvasAndChallenge() {
    const vw = Math.max(1, window.innerWidth || 1280);
    const vh = Math.max(1, window.innerHeight || 800);
    const vpArea = vw * vh;
    let mediaArea = 0;
    for (const el of document.querySelectorAll("canvas, video")) {
      if (!isVisible(el)) continue;
      const r = el.getBoundingClientRect();
      mediaArea += Math.max(0, r.width) * Math.max(0, r.height);
    }
    const canvasRatio = Math.min(1, Number((mediaArea / vpArea).toFixed(2)));
    const htmlLow = (document.title + " " + (document.body ? document.body.innerText.slice(0, 600) : "")).toLowerCase();
    const challenge =
      Boolean(document.querySelector('iframe[src*="turnstile"], iframe[src*="recaptcha"], iframe[src*="hcaptcha"], .cf-turnstile, #challenge-running')) ||
      /just a moment|verify you are human|checking your browser|人机验证|安全验证/.test(htmlLow);
    return { canvasRatio, challenge };
  }

  function distill(opts = {}) {
    ensureObserver();
    const maxNodes = Number(opts.maxNodes || 320);
    let nodeCount = 0;
    let controlCount = 0;
    const visited = new WeakSet();

    function budgetOk() {
      return nodeCount < maxNodes;
    }

    function countNode(node, isControl = false) {
      nodeCount += 1;
      if (isControl) controlCount += 1;
      return node;
    }

    function distillTable(tableEl) {
      const headers = [];
      const rows = [];
      const trs = Array.from(tableEl.querySelectorAll("tr")).filter(isVisible).slice(0, 40);
      for (const tr of trs) {
        const ths = Array.from(tr.children).filter((c) => c.tagName === "TH" && isVisible(c));
        const tds = Array.from(tr.children).filter((c) => c.tagName === "TD" && isVisible(c));
        if (ths.length && !headers.length && !tds.length) {
          for (const th of ths.slice(0, 6)) headers.push(cleanText(th.innerText || th.textContent));
          continue;
        }
        const cells = (tds.length ? tds : ths).slice(0, 6);
        if (!cells.length) continue;
        const rowCells = [];
        for (const cell of cells) {
          const link = cell.querySelector("a[href]");
          const btn = cell.querySelector('button, [role="button"]');
          if (link && isVisible(link) && cleanText(link.innerText || link.textContent)) {
            controlCount += 1;
            rowCells.push({
              kind: "link",
              wid: getWid(link),
              text: cleanText(link.innerText || link.textContent).slice(0, 120),
              href: link.href || "",
            });
          } else if (btn && isVisible(btn) && cleanText(btn.innerText || btn.textContent)) {
            controlCount += 1;
            rowCells.push({
              kind: "button",
              wid: getWid(btn),
              text: cleanText(btn.innerText || btn.textContent).slice(0, 60),
            });
          } else {
            rowCells.push({
              kind: "text",
              text: cleanText(cell.innerText || cell.textContent).slice(0, 120),
            });
          }
        }
        rows.push(rowCells);
      }
      if (!headers.length && !rows.length) return null;
      return countNode({ type: "table", headers, rows });
    }

    function distillTabs(tablistEl) {
      const tabEls = Array.from(tablistEl.querySelectorAll('[role="tab"], button, a')).filter(isVisible);
      const items = [];
      const seen = new Set();
      for (const tab of tabEls.slice(0, 10)) {
        const label = cleanText(tab.innerText || tab.textContent);
        if (!label || seen.has(label)) continue;
        seen.add(label);
        const wid = getWid(tab);
        controlCount += 1;
        const active =
          tab.getAttribute("aria-selected") === "true" ||
          tab.getAttribute("aria-current") === "page" ||
          /\b(?:active|selected|current)\b/i.test(String(tab.className || ""));
        items.push({ wid, label: label.slice(0, 40), active });
      }
      if (items.length < 2) return null;
      return countNode({ type: "tabs", items });
    }

    function distillElement(el, depth) {
      if (!el || depth > 14 || !budgetOk()) return null;
      if (visited.has(el) || !isVisible(el)) return null;
      visited.add(el);

      const tag = el.tagName;
      const role = (el.getAttribute("role") || "").toLowerCase();

      // Headings
      if (/^H[1-6]$/.test(tag)) {
        const text = cleanText(el.innerText || el.textContent);
        if (!text) return null;
        const link = el.querySelector("a[href]");
        if (link && isVisible(link) && cleanText(link.textContent) === text) {
          return countNode({
            type: "heading",
            level: Number(tag[1]),
            text: text.slice(0, 160),
            wid: getWid(link),
            href: link.href || "",
          }, true);
        }
        return countNode({ type: "heading", level: Number(tag[1]), text: text.slice(0, 160) });
      }

      // Tabs
      if (role === "tablist") {
        const tabs = distillTabs(el);
        if (tabs) return tabs;
      }

      // Tables
      if (tag === "TABLE") {
        return distillTable(el);
      }

      // Inputs & textarea
      if (tag === "TEXTAREA" || tag === "INPUT") {
        const itype = tag === "TEXTAREA" ? "textarea" : (el.type || "text").toLowerCase();
        if (itype === "hidden") return null;
        if (itype === "checkbox" || itype === "radio") {
          return countNode({
            type: "checkbox",
            wid: getWid(el),
            label: labelForControl(el, visited) || itype,
            checked: Boolean(el.checked),
            disabled: Boolean(el.disabled),
          }, true);
        }
        if (itype === "submit" || itype === "button" || itype === "reset") {
          const text = cleanText(el.value || el.getAttribute("aria-label") || "提交");
          return countNode({
            type: "button",
            wid: getWid(el),
            text: text.slice(0, 48),
            disabled: Boolean(el.disabled),
            primary: itype === "submit",
          }, true);
        }
        return countNode({
          type: "input",
          wid: getWid(el),
          kind: itype === "search" ? "search" : itype === "password" ? "password" : itype === "textarea" ? "textarea" : "text",
          label: labelForControl(el).slice(0, 48),
          placeholder: cleanText(el.getAttribute("placeholder") || "").slice(0, 64),
          value: itype === "password" ? "" : String(el.value || "").slice(0, 200),
          disabled: Boolean(el.disabled),
        }, true);
      }

      // Select
      if (tag === "SELECT") {
        const options = Array.from(el.options || []).slice(0, 30).map((opt) => ({
          value: String(opt.value),
          label: cleanText(opt.textContent || opt.label || opt.value).slice(0, 48),
        })).filter((o) => o.label);
        if (!options.length) return null;
        return countNode({
          type: "select",
          wid: getWid(el),
          label: labelForControl(el).slice(0, 48) || "选择",
          value: String(el.value || options[0].value),
          options,
          disabled: Boolean(el.disabled),
        }, true);
      }

      // Checkbox / Switch via ARIA
      if (role === "checkbox" || role === "switch") {
        return countNode({
          type: role === "switch" ? "switch" : "checkbox",
          wid: getWid(el),
          label: cleanText(el.innerText || labelForControl(el) || role).slice(0, 64),
          checked: el.getAttribute("aria-checked") === "true",
          disabled: el.getAttribute("aria-disabled") === "true",
        }, true);
      }

      // Buttons
      if (tag === "BUTTON" || role === "button") {
        const text = cleanText(el.innerText || el.textContent || el.getAttribute("aria-label") || el.getAttribute("title"));
        if (!text) return null;
        const cls = String(el.className || "");
        return countNode({
          type: "button",
          wid: getWid(el),
          text: text.slice(0, 56),
          disabled: Boolean(el.disabled) || el.getAttribute("aria-disabled") === "true",
          primary: /\b(?:primary|submit|cta|btn-primary)\b/i.test(cls),
        }, true);
      }

      // Links
      if (tag === "A" && el.getAttribute("href")) {
        const text = cleanText(el.innerText || el.textContent || el.getAttribute("aria-label") || el.getAttribute("title"));
        if (!text) return null;
        const active =
          el.getAttribute("aria-current") === "page" ||
          /\b(?:active|current|selected)\b/i.test(String(el.className || ""));
        return countNode({
          type: "link",
          wid: getWid(el),
          text: text.slice(0, 120),
          href: el.href || "",
          active,
        }, true);
      }

      // Code block
      if (tag === "PRE") {
        const code = String(el.innerText || el.textContent || "").trim();
        if (!code) return null;
        return countNode({ type: "code", text: code.slice(0, 1600) });
      }

      // Images
      if (tag === "IMG") {
        const r = el.getBoundingClientRect();
        const alt = cleanText(el.getAttribute("alt") || "");
        if ((r.width < 24 && r.height < 24) || !alt) return null;
        return countNode({ type: "image", alt: alt.slice(0, 80), src: el.currentSrc || el.src || "" });
      }

      // Leaf paragraph / text blocks without interactive descendants
      const hasInteractiveChild = Boolean(
        el.querySelector('a[href], button, input, select, textarea, [role="button"], [role="tab"], [role="checkbox"], [role="switch"], table')
      );
      if (!hasInteractiveChild && (tag === "P" || tag === "BLOCKQUOTE" || tag === "LI" || el.children.length === 0)) {
        const text = cleanText(el.innerText || el.textContent);
        if (!text) return null;
        return countNode({
          type: tag === "BLOCKQUOTE" ? "quote" : "text",
          text: text.slice(0, 800),
        });
      }

      // Container recursion (preserve layout geometry: horizontal row vs vertical column)
      const childNodes = [];
      const childRects = [];
      for (const child of el.childNodes) {
        if (!budgetOk()) break;
        if (child.nodeType === 3) {
          const t = cleanText(child.nodeValue);
          if (t) childNodes.push(countNode({ type: "text", text: t.slice(0, 400) }));
        } else if (child.nodeType === 1) {
          const distilled = distillElement(child, depth + 1);
          if (distilled) {
            childNodes.push(distilled);
            childRects.push(child.getBoundingClientRect());
          }
        }
      }

      if (!childNodes.length) return null;
      // Flatten single-child transparent wrappers!
      if (childNodes.length === 1) return childNodes[0];

      const cs = window.getComputedStyle(el);
      const isFlexRow =
        (cs.display === "flex" || cs.display === "inline-flex") &&
        (cs.flexDirection === "row" || cs.flexDirection === "row-reverse");
      const isGrid = cs.display === "grid" || cs.display === "inline-grid";
      const inlineLeafTypes = new Set(["text", "link", "button", "checkbox", "switch"]);
      const allInlineLeaves = childNodes.every((n) => n && inlineLeafTypes.has(n.type));
      const elRect = el.getBoundingClientRect();
      let sameRow = false;
      if (childNodes.length >= 2 && childNodes.length <= 12) {
        if ((isFlexRow || isGrid) && childRects.length >= 2) {
          const top0 = childRects[0].top;
          const maxDelta = Math.max(...childRects.map((r) => Math.abs(r.top - top0)));
          if (maxDelta < 28 && (childNodes.length <= 5 || allInlineLeaves)) {
            sameRow = true;
          }
        }
        if (!sameRow && allInlineLeaves && elRect.height > 0 && elRect.height <= 44) {
          const totalChars = childNodes.reduce(
            (acc, n) => acc + ((n.text || n.label || "").length),
            0
          );
          if (totalChars <= 240) sameRow = true;
        }
      }

      const bordered =
        parseFloat(cs.borderTopWidth) >= 1 &&
        parseFloat(cs.borderBottomWidth) >= 1 &&
        cs.borderTopStyle !== "none" &&
        childNodes.length >= 2 &&
        depth <= 8;

      return countNode({
        type: sameRow ? "row" : "column",
        bordered: bordered || undefined,
        children: childNodes,
      });
    }

    function pickModal() {
      const cands = Array.from(document.querySelectorAll('dialog[open], [role="dialog"], [role="alertdialog"]')).filter(isVisible);
      return cands.length ? cands[cands.length - 1] : null;
    }

    function pickRegion(selectors, exclude, opts = {}) {
      for (const sel of selectors) {
        for (const el of document.querySelectorAll(sel)) {
          if (exclude && (el === exclude || exclude.contains(el) || el.contains(exclude))) continue;
          if (opts.noNestedIn && el.closest(opts.noNestedIn)) continue;
          if (!isVisible(el)) continue;
          if (cleanText(el.innerText || el.textContent).length < 2 && !el.querySelector("input, button")) continue;
          return el;
        }
      }
      return null;
    }

    const modalEl = pickModal();
    const topbarEl = pickRegion(
      ['header', '[role="banner"]', 'nav[aria-label*="main" i]', 'nav'],
      modalEl,
      { noNestedIn: 'aside, article, section, main' }
    );
    const mainEl = pickRegion(['main', '[role="main"]', 'article', '#main', '#app', '#root'], modalEl);
    const sidebarEl = pickRegion(['aside', '[role="complementary"]', '[class*="sidebar" i]'], modalEl);

    // If `<main>' sits inside a dedicated app shell (e.g. `<section class="todoapp">')
    // alongside interactive `<header>'/`<footer>' controls not claimed by `topbarEl'/`sidebarEl',
    // include the enclosing app container so inputs and filter bars stay visible after state updates.
    let effectiveMainEl = mainEl;
    if (effectiveMainEl && effectiveMainEl.parentElement &&
        effectiveMainEl.parentElement !== document.body &&
        effectiveMainEl.parentElement !== document.documentElement) {
      const parent = effectiveMainEl.parentElement;
      if (parent !== topbarEl && parent !== sidebarEl && parent !== modalEl &&
          (!topbarEl || !parent.contains(topbarEl)) &&
          (!sidebarEl || !parent.contains(sidebarEl))) {
        const hasInteractiveSibling = Array.from(parent.children).some((sib) =>
          sib !== effectiveMainEl &&
          sib !== topbarEl &&
          sib !== sidebarEl &&
          isVisible(sib) &&
          Boolean(sib.querySelector('input:not([type="hidden"]), button, select, a[href]'))
        );
        if (hasInteractiveSibling) {
          effectiveMainEl = parent;
        }
      }
    }

    const modal = modalEl ? distillElement(modalEl, 0) : null;
    const topbar = topbarEl && topbarEl !== effectiveMainEl ? distillElement(topbarEl, 0) : null;
    const sidebar =
      sidebarEl && sidebarEl !== effectiveMainEl && sidebarEl !== topbarEl && (!effectiveMainEl || !sidebarEl.contains(effectiveMainEl))
        ? distillElement(sidebarEl, 0)
        : null;
    const main = effectiveMainEl ? distillElement(effectiveMainEl, 0) : distillElement(document.body, 0);

    const { canvasRatio, challenge } = detectCanvasAndChallenge();
    const textLen = cleanText(document.body ? document.body.innerText : "").length;

    const mainRoot = mainEl || document.body;
    const countInMain = (sel) => {
      if (!mainRoot) return 0;
      let n = 0;
      for (const el of mainRoot.querySelectorAll(sel)) {
        if (topbarEl && topbarEl.contains(el)) continue;
        if (sidebarEl && sidebarEl.contains(el)) continue;
        if (!isVisible(el)) continue;
        n += 1;
      }
      return n;
    };
    const appMetrics = {
      mainInputs: countInMain("input:not([type='hidden']), textarea, select, [contenteditable='true']"),
      mainWidgets: countInMain("[role='tablist'], [role='checkbox'], [role='switch'], [role='slider'], [role='combobox'], [role='listbox'], [role='grid'], [role='treegrid']"),
      mainButtons: countInMain("button:not([aria-label*='copy' i]):not([class*='copy' i]), [role='button']:not([aria-label*='copy' i])"),
      mainForms: countInMain("form"),
      mainTables: countInMain("table"),
      mainLinks: countInMain("a[href]"),
    };

    return {
      url: location.href,
      title: cleanText(document.title || location.hostname),
      dirtyRev,
      textLen,
      nodeCount,
      controlCount,
      canvasRatio,
      challenge,
      appMetrics,
      scrollY: Math.round(window.scrollY || 0),
      scrollHeight: Math.round((document.documentElement && document.documentElement.scrollHeight) || 0),
      viewportHeight: Math.round(window.innerHeight || 800),
      regions: { topbar, sidebar, main, modal },
    };
  }

  function setNativeValue(el, value) {
    const proto =
      el.tagName === "TEXTAREA"
        ? HTMLTextAreaElement.prototype
        : el.tagName === "SELECT"
          ? HTMLSelectElement.prototype
          : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, "value");
    if (desc && typeof desc.set === "function") {
      desc.set.call(el, value);
    } else {
      el.value = value;
    }
  }

  function act(cmd) {
    const kind = cmd && cmd.kind;
    if (kind === "scroll") {
      const dy = Number(cmd.deltaY || 600);
      window.scrollBy(0, dy);
      dirtyRev += 1;
      return { ok: true, scrollY: Math.round(window.scrollY || 0) };
    }
    const el = resolveWid(cmd && cmd.wid);
    if (!el) return { ok: false, error: "Element no longer exists on page" };
    try {
      el.scrollIntoView({ block: "center", inline: "nearest" });
    } catch (_) {}

    if (kind === "click" || kind === "toggle") {
      try { el.focus(); } catch (_) {}
      el.click();
      dirtyRev += 1;
      return { ok: true };
    }
    if (kind === "fill") {
      const value = String(cmd.value ?? "");
      try { el.focus(); } catch (_) {}
      setNativeValue(el, value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      if (cmd.submit) {
        el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true }));
        el.dispatchEvent(new KeyboardEvent("keypress", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true }));
        el.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true }));
        if (el.form) {
          if (typeof el.form.requestSubmit === "function") {
            try { el.form.requestSubmit(); } catch (_) { el.form.submit(); }
          } else {
            el.form.submit();
          }
        }
      }
      dirtyRev += 1;
      return { ok: true };
    }
    if (kind === "select") {
      const value = String(cmd.value ?? "");
      try { el.focus(); } catch (_) {}
      setNativeValue(el, value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      dirtyRev += 1;
      return { ok: true };
    }
    return { ok: false, error: `Unknown action kind: ${kind}` };
  }

  window.__etafWebDistiller = {
    distill,
    act,
    getDirtyRev: () => dirtyRev,
  };
  ensureObserver();
  return true;
})();
