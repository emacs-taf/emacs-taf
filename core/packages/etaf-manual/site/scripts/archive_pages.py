#!/usr/bin/env python3
"""Write the browsable archive pages from a verifiable package archive.

The pages describe what the archive actually serves, so they cannot drift from
the download bytes: `manifest.json` supplies versions, requirements, provenance
and each package's newest-change date, and every tarball is read for its size,
file count and newest changelog entries. No checkout, network access or release
workspace is involved, which is what lets a published archive regenerate its
pages alone.

`write --directory DIR` creates `DIR/index.html`, `DIR/og.png` and
`DIR/<name>/index.html` and nothing else, because the deployer accepts only
those files next to the indexed tarballs. Download counts are filled from
`downloads.json` by the browser; the markup keeps its placeholder so the archive
still reads without JavaScript.
"""
from __future__ import annotations

import argparse
from datetime import date
import html
import json
from pathlib import Path
import re
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import og_cards

MONTHS = ("January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December")

# The archive records commit dates in strict ISO 8601, so a rendered page never
# has to guess a time zone or re-derive a date from an ambiguous string.
STAMP = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[+-][0-9]{2}:[0-9]{2}|Z)\Z")

MONOREPO = "emacs-taf/emacs-taf"
CORE_REPO = "emacs-taf/etaf"
# Core framework, extension, installer and manual packages live together in
# `emacs-taf/etaf` under `packages/<name>` (and `core/packages/<name>` in the
# canonical monorepo).
CORE_PACKAGES = {
    "ecss", "ekp", "ebox", "etaf", "etaf-media", "etaf-ui", "etaf-doc", "etaf-posframe", "etaf-ext",
    "etaf-db", "etaf-gamekit", "etaf-install", "etaf-manual", "etaf-devtools",
    "etaf-translate", "etaf-highlight", "etaf-hints", "etaf-export",
}
GAME_PACKAGES = {
    "etaf-balatro", "etaf-solitaire", "etaf-xiangqi", "etaf-tanks", "etaf-salvage",
}
REPOSITORIES = {"etaf-web": MONOREPO}

# Where the page files each package this project publishes.  A new archive
# package must be placed here: the writer refuses to publish pages while a
# package is left over, because a silent "Other" section hides the omission
# from readers.  A package another author publishes states its own group.
GROUPS = (
    ("Framework", {"etaf-install", "etaf-ui", "etaf-doc", "etaf-media", "etaf", "ebox", "ecss", "ekp", "etaf-db",
                   "etaf-posframe", "etaf-ext", "etaf-gamekit", "etaf-devtools", "etaf-manual"}),
    ("Extensions", {"etaf-translate", "etaf-highlight", "etaf-hints", "etaf-export"}),
    ("Applications", {"etaf-md", "etaf-org", "etaf-org-preview", "etaf-rss", "etaf-reader", "etaf-algo-lab",
                      "etaf-screensaver", "etaf-desktop", "etaf-miniflux", "etaf-ncm",
                      "etaf-weread", "etaf-bili", "etaf-youtube", "etaf-pi", "etaf-telega",
                      "etaf-ascii-video", "etaf-video-player", "etaf-video-studio",
                      "etaf-pomodoro", "etaf-web", "etaf-agenda", "etaf-island", "maillist"}),
    ("Games", {"etaf-balatro", "etaf-solitaire", "etaf-xiangqi", "etaf-tanks", "etaf-salvage"}),
)

MANUAL = "https://etaf.top/introduction/"
INSTALL = "https://etaf.top/introduction/#installation"
BOOTSTRAP = """(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)"""


TAR_ICON = ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
            'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
            '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg>')

HEADER = """<header class="site-header">
<div class="wrap bar">
<a class="brand" href="/"><img src="/favicon.svg" alt="" width="24" height="24"><span>ETAF</span></a>
<button class="theme" type="button" data-theme-toggle aria-label="Toggle colour theme" title="Toggle colour theme">
<svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
<svg class="moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11Z"/></svg>
</button>
</div>
</header>"""

THEME_SCRIPT = """(() => {
  const root = document.documentElement;
  const resolveTheme = () => {
    let stored = null;
    try { stored = localStorage.getItem('starlight-theme'); } catch (error) {}
    return stored === 'light' || stored === 'dark' ? stored
      : matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
  };
  root.dataset.theme = resolveTheme();
  window.addEventListener('pageshow', () => { root.dataset.theme = resolveTheme(); });
  window.addEventListener('storage', (event) => {
    if (event.key === 'starlight-theme') root.dataset.theme = resolveTheme();
  });
  document.addEventListener('click', (event) => {
    if (!(event.target instanceof Element)) return;
    const button = event.target.closest('[data-theme-toggle]');
    if (!button) return;
    const next = root.dataset.theme === 'dark' ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('starlight-theme', next); } catch (error) {}
  });
})();"""

PAGE_SCRIPT = """(() => {
  const number = new Intl.NumberFormat('en-US');
  const setCount = (node, value) => {
    node.textContent = number.format(value);
    node.classList.add('is-known');
  };
  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', async () => {
      const target = document.querySelector(button.dataset.copy);
      if (!target) return;
      try { await navigator.clipboard.writeText(target.textContent); }
      catch (error) {
        const range = document.createRange();
        range.selectNodeContents(target);
        const selection = getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        document.execCommand('copy');
        selection.removeAllRanges();
      }
      button.textContent = 'Copied';
      button.classList.add('done');
      setTimeout(() => { button.textContent = 'Copy'; button.classList.remove('done'); }, 1600);
    });
  });
  filterPackages();
  countDownloads();
})();

function filterPackages() {
  const box = document.querySelector('[data-filter-box]');
  const field = document.querySelector('[data-filter]');
  const empty = document.querySelector('[data-filter-empty]');
  if (!box || !field) return;
  box.hidden = false;
  const rows = Array.from(document.querySelectorAll('tr[data-search]'));
  const groups = Array.from(document.querySelectorAll('section.group'));
  const apply = () => {
    const terms = field.value.toLowerCase().split(/\\s+/).filter(Boolean);
    let shown = 0;
    for (const row of rows) {
      row.hidden = !terms.every((term) => row.dataset.search.includes(term));
      if (!row.hidden) shown += 1;
    }
    for (const group of groups) {
      const tag = group.querySelector('[data-count]');
      const total = Number(tag ? tag.dataset.count : 0);
      const visible = Array.from(group.querySelectorAll('tr[data-search]')).filter((row) => !row.hidden).length;
      group.hidden = visible === 0;
      if (tag) tag.textContent = visible === total ? total + ' packages' : visible + ' of ' + total + ' packages';
    }
    if (empty) empty.hidden = shown > 0 || terms.length === 0;
  };
  field.addEventListener('input', apply);
  field.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    field.value = '';
    apply();
    field.blur();
  });
  document.addEventListener('keydown', (event) => {
    const active = document.activeElement;
    if (event.key !== '/' || event.metaKey || event.ctrlKey || event.altKey) return;
    if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) return;
    event.preventDefault();
    field.focus();
  });
}

function countDownloads() {
  const source = document.body.dataset.downloadsUrl;
  if (!source) return;
  fetch(source, {cache: 'no-store'}).then((response) => response.ok ? response.json() : null)
    .then((data) => {
      if (!data) return;
      const counts = data.packages || {};
      document.querySelectorAll('[data-downloads]').forEach((node) => {
        const value = counts[node.dataset.downloads];
        if (Number.isFinite(value)) setDownloads(node, value);
      });
      const total = Number.isFinite(data.total) ? data.total
        : Object.values(counts).reduce((sum, value) => sum + value, 0);
      document.querySelectorAll('[data-downloads-total]').forEach((node) => setDownloads(node, total));
      document.querySelectorAll('[data-downloads-asof]').forEach((node) => {
        if (!data.as_of) return;
        node.textContent = 'Download counts updated ' + data.as_of.replace('T', ' ').replace('Z', ' UTC');
        node.hidden = false;
      });
    }).catch(() => {});
}

function setDownloads(node, value) {
  node.textContent = new Intl.NumberFormat('en-US').format(value);
  node.classList.add('is-known');
}"""

STYLE = """*, *::before, *::after { box-sizing: border-box; }
:root {
  color-scheme: light;
  --paper: #faf8f3;
  --paper-2: #f3f0e8;
  --rule: #e2ddd1;
  --rule-strong: #c9c3b5;
  --ink: #1c1a16;
  --ink-2: #45413a;
  --ink-3: #7a7468;
  --accent: #5b3ea8;
  --font-text: "Source Serif 4", "Iowan Old Style", "Palatino Linotype", Palatino,
    Georgia, "Songti SC", "Noto Serif SC", serif;
  --font-mono: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --paper: #191a1c;
  --paper-2: #202225;
  --rule: #2f3135;
  --rule-strong: #43464b;
  --ink: #e3e1db;
  --ink-2: #b8b6af;
  --ink-3: #89877f;
  --accent: #c3b0ff;
}
:root[data-theme="dark"],
:root[data-theme="dark"] body {
  background-color: var(--paper);
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.055'/%3E%3C/svg%3E");
  background-size: 160px 160px;
}
html { -webkit-text-size-adjust: 100%; background-color: var(--paper); }
body { margin: 0; min-height: 100vh; background-color: var(--paper); color: var(--ink);
  font-family: var(--font-text); font-size: 1rem; line-height: 1.65; }
[hidden] { display: none !important; }
a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }
a:hover { text-decoration-thickness: 2px; }
code { font-family: var(--font-mono); font-size: .86em; background: var(--paper-2);
  border: 1px solid var(--rule); border-radius: 2px; padding: .05em .3em; }
pre { margin: .8rem 0 0; padding: 1rem 1.1rem; border: 1px solid var(--rule);
  border-left: 3px solid var(--accent); background: var(--paper-2);
  white-space: pre-wrap; overflow-wrap: anywhere;
  font-family: var(--font-mono); font-size: .82rem; line-height: 1.7; }
pre code { background: none; border: 0; padding: 0; font: inherit; }
.wrap { width: 100%; max-width: 76rem; margin: 0 auto; padding: 0 clamp(1.1rem, 4vw, 2.5rem); }
.visually-hidden { position: absolute; width: 1px; height: 1px; margin: -1px;
  padding: 0; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0; }
.site-header { border-bottom: 1px solid var(--rule); }
.bar { display: flex; align-items: center; justify-content: space-between;
  gap: 1rem; height: 3.6rem; }
.brand { display: inline-flex; align-items: center; gap: .55rem; color: var(--ink);
  text-decoration: none; font-size: .95rem; font-weight: 600;
  letter-spacing: .14em; text-transform: uppercase; }
.brand img { display: block; }
.theme { display: inline-flex; align-items: center; justify-content: center;
  width: 2rem; height: 2rem; padding: 0; border: 1px solid var(--rule);
  border-radius: 50%; background: transparent; color: var(--ink-2); cursor: pointer; }
.theme:hover { color: var(--accent); border-color: var(--accent); }
.theme svg { width: 1rem; height: 1rem; }
.theme .sun, .theme .moon { display: none; }
:root[data-theme="dark"] .theme .moon { display: block; }
:root[data-theme="light"] .theme .sun { display: block; }
.hero { padding: clamp(3rem, 7vw, 5rem) 0 1.6rem; }
.eyebrow { margin: 0 0 .9rem; font-family: var(--font-mono); font-size: .72rem;
  letter-spacing: .16em; text-transform: uppercase; color: var(--accent); }
h1 { margin: 0; font-size: clamp(2.3rem, 6vw, 3.6rem); line-height: 1.05;
  font-weight: 600; letter-spacing: -.02em; overflow-wrap: anywhere; }
h2 { margin: 0; font-size: 1.4rem; line-height: 1.25; font-weight: 600; letter-spacing: -.01em; }
.lead { margin: 1rem 0 0; max-width: 48rem; font-size: clamp(1.05rem, 2.2vw, 1.22rem);
  line-height: 1.6; color: var(--ink-2); }
.meta { display: flex; flex-wrap: wrap; align-items: baseline; gap: .55rem;
  margin: 1.4rem 0 0; font-family: var(--font-mono); font-size: .8rem; color: var(--ink-3); }
.meta strong { font-weight: 600; color: var(--ink); font-variant-numeric: tabular-nums; }
.meta .dot { color: var(--rule-strong); }
.install { padding: 1.6rem 0 0; border-top: 1px solid var(--rule); }
.install-head { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; }
.copy { padding: .25rem .6rem; border: 1px solid var(--rule-strong); border-radius: 2px;
  background: transparent; color: var(--ink-3); font-family: var(--font-mono);
  font-size: .68rem; letter-spacing: .08em; text-transform: uppercase; cursor: pointer; }
.copy:hover, .copy.done { color: var(--accent); border-color: var(--accent); }
.note { margin: .75rem 0 0; max-width: 54rem; color: var(--ink-3); font-size: .9rem; }
.filter { display: flex; align-items: center; gap: .7rem; margin: 2.6rem 0 0;
  padding: .45rem .7rem; border: 1px solid var(--rule); background: var(--paper-2); }
.filter:focus-within { border-color: var(--accent); }
.filter input { width: 100%; min-width: 0; padding: .1rem 0; border: 0; background: none;
  color: var(--ink); font-family: var(--font-mono); font-size: .82rem; outline: none; }
.filter input::placeholder { color: var(--ink-3); }
.filter kbd { padding: .05rem .35rem; border: 1px solid var(--rule-strong); border-radius: 2px;
  color: var(--ink-3); font-family: var(--font-mono); font-size: .66rem; }
.group { margin-top: 2.6rem; }
.group-head { display: flex; align-items: baseline; gap: .7rem; }
.group-head h2 { font-size: 1.5rem; }
.tag { font-family: var(--font-mono); font-size: .7rem; color: var(--ink-3); }
table { width: 100%; border-collapse: collapse; margin-top: .4rem; }
thead th { padding: .55rem .7rem .5rem; border-bottom: 1px solid var(--rule-strong);
  color: var(--ink-3); font-family: var(--font-mono); font-size: .66rem; font-weight: 500;
  letter-spacing: .11em; text-transform: uppercase; text-align: left; }
tbody td { padding: .8rem .7rem; border-bottom: 1px solid var(--rule); vertical-align: top; text-align: left; }
tbody tr:hover td { background: var(--paper-2); }
th:first-child, td:first-child { padding-left: 0; }
th:last-child, td:last-child { padding-right: 0; }
.pkg a { color: var(--ink); font-size: 1.03rem; font-weight: 600; text-decoration: none; }
.pkg a:hover { color: var(--accent); }
.summary { display: block; margin-top: .1rem; color: var(--ink-3); font-size: .86rem;
  line-height: 1.5; overflow-wrap: anywhere; }
.version { padding: .1rem .4rem; border: 1px solid var(--rule); border-radius: 2px;
  background: var(--paper-2); color: var(--ink-2); font-family: var(--font-mono);
  font-size: .74rem; white-space: nowrap; }
td.updated { color: var(--ink-3); font-family: var(--font-mono); font-size: .76rem;
  white-space: nowrap; }
td.author { color: var(--ink-3); font-family: var(--font-mono); font-size: .74rem;
  white-space: nowrap; }
td.author a { color: var(--ink-2); text-decoration-color: var(--rule-strong); }
td.author a:hover { color: var(--accent); }
td.updated time { color: var(--ink-2); font-variant-numeric: tabular-nums; }
.requires { max-width: 18rem; color: var(--ink-3); font-family: var(--font-mono);
  font-size: .72rem; line-height: 1.6; overflow-wrap: anywhere; }
.requires a { color: var(--ink-2); text-decoration-color: var(--rule-strong); }
.requires a:hover { color: var(--accent); }
th.num, td.num { text-align: right; }
td.num { color: var(--ink-3); font-family: var(--font-mono); font-size: .85rem;
  font-variant-numeric: tabular-nums; white-space: nowrap; }
td.num.is-known { color: var(--ink); }
th.src, td.src { width: 1%; text-align: right; white-space: nowrap; }
.tar { display: inline-flex; align-items: center; gap: .35rem; padding: .2rem .5rem;
  border: 1px solid var(--rule); border-radius: 2px; color: var(--ink-2);
  font-family: var(--font-mono); font-size: .72rem; text-decoration: none; }
.tar:hover { color: var(--accent); border-color: var(--accent); }
.tar svg { width: .85rem; height: .85rem; }
.crumbs { display: flex; align-items: center; gap: .45rem; padding: 1.8rem 0 0;
  color: var(--ink-3); font-family: var(--font-mono); font-size: .73rem; }
.crumbs a { color: var(--ink-3); text-decoration: none; }
.crumbs a:hover { color: var(--accent); }
.hero.detail { padding: 1.2rem 0; }
.details { margin-top: 2.5rem; padding-top: 1.6rem; border-top: 1px solid var(--rule); }
.title-row { display: flex; align-items: baseline; flex-wrap: wrap; gap: 1rem; }
.title-row .version { font-size: .85rem; padding: .15rem .5rem; }
.when { color: var(--ink-3); font-family: var(--font-mono); font-size: .78rem; }
.actions { display: flex; align-items: center; flex-wrap: wrap; gap: .6rem; margin-top: 1.3rem; }
.button { display: inline-flex; align-items: center; gap: .4rem; padding: .4rem .8rem;
  border: 1px solid var(--rule-strong); border-radius: 2px; color: var(--ink-2);
  font-family: var(--font-mono); font-size: .76rem; text-decoration: none; }
.button:hover { color: var(--accent); border-color: var(--accent); }
.button.primary { background: var(--ink); border-color: var(--ink); color: var(--paper); }
.button.primary:hover { background: var(--accent); border-color: var(--accent); color: var(--paper); }
.button svg { width: .9rem; height: .9rem; }
.stat { color: var(--ink-3); font-family: var(--font-mono); font-size: .76rem; }
.changes { margin-top: 2.5rem; padding-top: 1.6rem; border-top: 1px solid var(--rule); }
.changes ul { margin: .9rem 0 0; padding-left: 1.1rem; max-width: 54rem; }
.changes li { margin: .6rem 0 0; color: var(--ink-2); font-size: .95rem; line-height: 1.6; }
.changes li::marker { color: var(--accent); }
.changes .more { display: inline-block; margin-top: 1rem; font-family: var(--font-mono);
  font-size: .74rem; }
.facts { margin: .8rem 0 0; }
.facts > div { display: grid; grid-template-columns: 9.5rem minmax(0, 1fr); gap: 1rem;
  padding: .65rem 0; border-top: 1px solid var(--rule); }
.facts > div:first-child { border-top: 0; }
.facts dt { padding-top: .15rem; color: var(--ink-3); font-family: var(--font-mono);
  font-size: .66rem; letter-spacing: .1em; text-transform: uppercase; }
.facts dd { margin: 0; color: var(--ink-2); overflow-wrap: anywhere; }
.fact-note { display: block; margin-top: .25rem; color: var(--ink-3);
  font-family: var(--font-mono); font-size: .74rem; }
.site-footer { margin-top: 3.5rem; padding: 1.4rem 0 3rem; border-top: 1px solid var(--rule);
  color: var(--ink-3); font-size: .86rem; }
.site-footer p { margin: 0; max-width: 56rem; }
.site-footer p + p { margin-top: .5rem; }
.site-footer .asof { font-family: var(--font-mono); font-size: .7rem; }
@media (max-width: 720px) {
  thead { display: none; }
  tbody tr { display: grid; grid-template-columns: auto minmax(0, 1fr) auto auto;
    grid-template-areas: "pkg pkg pkg pkg" "ver auth when tar" "dl dl dl dl";
    gap: .35rem .8rem;
    align-items: center; padding: .85rem 0; border-bottom: 1px solid var(--rule); }
  tbody td { padding: 0; border-bottom: 0; }
  tbody tr:hover td { background: none; }
  td.pkg { grid-area: pkg; }
  td.version-cell { grid-area: ver; }
  td.author { grid-area: auth; font-size: .72rem; }
  td.updated { grid-area: when; font-size: .72rem; }
  td.requires { display: none; }
  td.num { grid-area: dl; justify-self: start; text-align: left; font-size: .78rem; }
  td.num::before { content: attr(data-label); margin-right: .3rem; color: var(--ink-3);
    font-size: .62rem; letter-spacing: .1em; text-transform: uppercase; }
  td.src { grid-area: tar; justify-self: end; width: auto; }
  .facts > div { grid-template-columns: 1fr; gap: .1rem; }
}
"""


def page(title, body, downloads="downloads.json", *, canonical, description,
         og_image, og_image_alt=None, extra_style="", script=None):
    title = html.escape(title)
    description = html.escape(description)
    canonical = html.escape(canonical)
    og_image_esc = html.escape(og_image)
    og_alt_esc = html.escape(og_image_alt or title)
    page_script = PAGE_SCRIPT if script is None else script
    style = STYLE + ("\n" + extra_style if extra_style else "")
    return f"""<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="canonical" href="{canonical}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="ETAF">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{og_image_esc}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{og_alt_esc}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title}">
<meta name="twitter:description" content="{description}">
<meta name="twitter:image" content="{og_image_esc}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>{style}</style>
<script>{THEME_SCRIPT}</script>
</head>
<body data-downloads-url="{downloads}">
{HEADER}
{body}
<script>{page_script}</script>
</body>
</html>
"""


def stamp_date(value):
    """Return the calendar date recorded in an ISO 8601 commit timestamp."""
    match = STAMP.fullmatch(value) if isinstance(value, str) else None
    if not match:
        return None
    try:
        return date.fromisoformat(match[1])
    except ValueError:
        return None


def short_date(day):
    return f"{day.day} {MONTHS[day.month - 1][:3]} {day.year}"


def long_date(day):
    return f"{day.day} {MONTHS[day.month - 1]} {day.year}"


def update_cell(item, updated, source):
    """Render one package's newest change; the dash keeps older archives readable."""
    value = updated.get(item["name"])
    day = stamp_date(value)
    if not day:
        return '<td class="updated"><span aria-label="not recorded">—</span></td>'
    title = f"Newest change to the files this package ships: {long_date(day)}"
    commit = (source or "")[:12]
    if commit:
        title += f", in commit {commit}"
    return (f'<td class="updated"><time datetime="{html.escape(value)}" '
            f'title="{html.escape(title)}">{short_date(day)}</time></td>')


def requirements_html(item, names, prefix=""):
    """Name each requirement, linking the ones this archive also serves."""
    parts = []
    for dependency, minimum in item["requirements"]:
        label = html.escape(f"{dependency} {minimum}")
        parts.append(f'<a href="{prefix}{html.escape(dependency)}/">{label}</a>'
                     if dependency in names else label)
    return ", ".join(parts) if parts else "Emacs"


ORGANIZATION = ("emacs-taf", "https://github.com/emacs-taf")


def author_cell(item, origin):
    """Name who maintains the package and link to that account or organization."""
    if origin:
        parts = [part for part in origin.get("url", "").split("/") if part]
        account = origin.get("maintainer") or (parts[2] if len(parts) > 3 else "")
        href = f"https://github.com/{account}" if account else origin.get("url", "")
        label = account or "community"
    else:
        label, href = ORGANIZATION
    return f'<td class="author"><a href="{html.escape(href)}">{html.escape(label)}</a></td>'


def source_name(item, origin):
    """Name a community package after its author's repository.

    A package installs under the name its entry file gives it, while the
    project it lives in may be called something else (`exc.el` ships `exc.el`).
    The archive names the repository and states the installable package, so a
    visitor sees the author's own project name.
    """
    if not origin:
        return item["name"]
    repository = origin.get("url", "").rstrip("/").rsplit("/", 1)[-1]
    if repository.endswith(".git"):
        repository = repository[:-4]
    return repository or item["name"]


def download_cell(name):
    """A count cell filled by downloads.json; the dash is the no-JavaScript state."""
    safe = html.escape(name)
    return (f'<td class="num" data-downloads="{safe}" data-label="downloads" '
            f'title="Downloads of every {safe} version">—</td>')


def search_text(item, updated, origin=None):
    """Everything a visitor may type to find this row."""
    day = stamp_date(updated.get(item["name"]))
    requirements = " ".join(f"{dependency} {minimum}"
                            for dependency, minimum in item["requirements"])
    values = [item["name"], source_name(item, origin), item.get("summary", ""), requirements,
              long_date(day) if day else ""]
    return html.escape(" ".join(value for value in values if value).lower(), quote=True)


def tar_icon_link(item, prefix=""):
    name, version = html.escape(item["name"]), html.escape(item["version"])
    return (f'<a class="tar" href="{prefix}{html.escape(item["file"])}" '
            f'title="Download {name} {version}">{TAR_ICON}<span>tar</span></a>')


def groups(packages, community={}, catalog={}):
    """Split packages into the published roles, keeping any unknown name visible.

    A package another author publishes through this archive is never filed
    under our own applications: the section states who maintains it.
    First-party packages read their group from `manifest['catalog']` when
    present, falling back to the curated `GROUPS` table for older archives.
    """
    placed, result = set(), []
    def declared_group(item):
        record = community.get(item["name"])
        if record is not None:
            return record.get("group", "application")
        cat = catalog.get(item["name"])
        if cat is not None:
            return cat.get("group")
        return None

    for label, members in GROUPS:
        key = label.lower().rstrip("s")
        selected = [item for item in packages
                    if (declared_group(item) == key)
                    or (declared_group(item) is None and item["name"] in members)]
        placed.update(item["name"] for item in selected)
        if selected:
            result.append((label, selected))
    other = [item for item in packages if item["name"] not in placed]
    if other:
        result.append(("Other", other))
    return result


def unplaced(packages, community={}, catalog={}):
    """Name the packages no section claims.

    The page files them under Other so a reader sees the omission; the
    publisher refuses to deploy them, because a nameless section is a mistake,
    not a category.
    """
    claimed = set().union(*(members for _, members in GROUPS))
    return sorted(item["name"] for item in packages
                  if item["name"] not in claimed
                  and item["name"] not in community
                  and not (catalog.get(item["name"]) or {}).get("group"))


def inspect_archive(path):
    """Read the facts a page shows without unpacking anything to disk."""
    facts = {"size": path.stat().st_size, "files": 0, "changelog": ""}
    with tarfile.open(path) as stream:
        for member in stream.getmembers():
            if not member.isfile():
                continue
            facts["files"] += 1
            parts = member.name.split("/")
            if len(parts) == 2 and parts[1] == "CHANGELOG.md":
                body = stream.extractfile(member)
                facts["changelog"] = body.read().decode("utf-8", "replace") if body else ""
    return facts


BULLET = re.compile(r"^[-*]\s+(.*)$")
NESTED = re.compile(r"^\s+[-*]\s")
CONTINUATION = re.compile(r"^\s{2,}(\S.*)$")
LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")


def plain(text):
    """Reduce one changelog line to readable text without markup."""
    text = LINK.sub(r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    return " ".join(text.split())


def trim(text, width=220):
    if len(text) <= width:
        return text
    return text[:width].rsplit(" ", 1)[0].rstrip(",;:.") + "…"


def latest_changes(changelog, limit=4):
    """Return the newest section's entries as plain sentences.

    Packages keep work under an `Unreleased` heading, and the heading is not a
    version a visitor can install, so the page shows the entries themselves and
    names the file rather than promising a released version.
    """
    items, inside = [], False
    for line in changelog.splitlines():
        if line.startswith("## "):
            if inside:
                break
            inside = True
            continue
        if not inside or line.startswith("### ") or NESTED.match(line):
            continue
        bullet = BULLET.match(line)
        if bullet:
            if len(items) >= limit:
                break
            items.append(plain(bullet[1]))
            continue
        continuation = CONTINUATION.match(line)
        if continuation and items:
            items[-1] = f"{items[-1]} {plain(continuation[1])}".strip()
    return [trim(text) for text in items[:limit] if text]


def archive_pages(package_dir):
    """Write the archive index and one detail page per package."""
    manifest = json.loads((package_dir / "manifest.json").read_text(encoding="utf-8"))
    sources = manifest.get("sources", {})
    updated = manifest.get("updated", {})
    packages = sorted(manifest["packages"], key=lambda item: item["name"])
    names = {item["name"] for item in packages}
    community = manifest.get("community", {})
    catalog = manifest.get("catalog", {})
    dates = [day for day in (stamp_date(value) for value in updated.values()) if day]
    newest = max(dates) if dates else None
    rows_by_name = {item["name"]: item for item in packages}
    sections = []
    for label, selected in groups(packages, community, catalog):
        rows = []
        for item in selected:
            name = html.escape(item["name"])
            shown = html.escape(source_name(item, community.get(item["name"])))
            version = html.escape(item["version"])
            summary = html.escape(item.get("summary", ""))
            rows.append(
                "<tr"
                f' data-search="{search_text(item, updated, community.get(item["name"]))}">'
                f'<td class="pkg"><a href="{name}/"><strong>{shown}</strong></a>'
                f'<span class="summary">{summary}</span></td>'
                f'<td class="version-cell"><span class="version">{version}</span></td>'
                f"{author_cell(item, community.get(item['name'])) + update_cell(item, updated, sources.get(item['name']))}"
                f'<td class="requires">{requirements_html(item, names)}</td>'
                f"{download_cell(item['name'])}"
                f'<td class="src">{tar_icon_link(item)}</td>'
                "</tr>")
        sections.append(f"""<section class="group" id="{label.lower()}">
<div class="group-head"><h2>{label}</h2><span class="tag" data-count="{len(selected)}">{len(selected)} packages</span></div>
<table>
<thead><tr><th scope="col">Package</th><th scope="col">Version</th>
<th scope="col">Author</th><th scope="col">Updated</th>
<th scope="col" class="requires">Requires</th>
<th scope="col" class="num">Downloads</th>
<th scope="col" class="src"><span class="visually-hidden">Tarball</span></th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody>
</table>
</section>""")
    freshness = (f'<span>latest change <time datetime="{html.escape(str(newest))}">'
                 f"{short_date(newest)}</time></span>"
                 f'<span class="dot" aria-hidden="true">·</span>\n' if newest else "")
    body = f"""<main class="wrap">
<section class="hero">
<p class="eyebrow">package.el archive</p>
<h1>ETAF package archive</h1>
<p class="lead">One archive for all of ETAF: the framework, its extensions, its applications and its games.
Add it once, then <code>M-x etaf-install</code> pulls everything a target needs.</p>
<p class="meta"><span><strong>{len(packages)}</strong> packages</span>
<span class="dot" aria-hidden="true">·</span>
<span><strong data-downloads-total>—</strong> downloads</span>
<span class="dot" aria-hidden="true">·</span>
{freshness}<span>Emacs 29.1 or newer</span></p>
</section>
<section class="install" aria-labelledby="install-title">
<div class="install-head"><h2 id="install-title">Install</h2>
<button class="copy" type="button" data-copy="#bootstrap">Copy</button></div>
<pre id="bootstrap"><code>{BOOTSTRAP}</code></pre>
<p class="note">Evaluate this once; it only bootstraps the installer. Then run
<code>M-x etaf-install</code> and pick a target. Applications and games pull the framework they
need automatically. Read the <a href="{INSTALL}">installation reference</a> or the
<a href="{MANUAL}">ETAF Reference Manual</a> for the supported workflows.</p>
</section>
<div class="filter" data-filter-box hidden>
<label class="visually-hidden" for="package-filter">Filter packages</label>
<input id="package-filter" type="search" data-filter autocomplete="off" spellcheck="false"
 placeholder="Filter by name, summary or requirement">
<kbd>/</kbd>
</div>
<p class="note" data-filter-empty hidden>No package matches that filter.</p>
{chr(10).join(sections)}
<footer class="site-footer">
<p>Updated is the date of the newest commit that changed the files a package ships, so
rebuilding a release or changing something else in a repository does not move it. Every
package page states the exact commit.</p>
<p>Manifest <a href="manifest.json">manifest.json</a> records the sealed workspace and provider
revisions; each package page shows its source commit. Older versions stay downloadable, and a
versioned file never changes bytes.</p>
<p class="asof" data-downloads-asof hidden></p>
</footer>
</main>"""
    pkg_noun = "PACKAGE" if len(packages) == 1 else "PACKAGES"
    archive_og_hash = og_cards.render_card(
        og_cards.CardSpec(
            title="Package archive",
            subtitle="Framework, extensions, applications and games. One package.el entry installs everything.",
            url_label="etaf.top/packages",
            footer_left="PACKAGE.EL ARCHIVE",
            footer_right=f"{len(packages)} {pkg_noun}",
            lang="en",
        ),
        package_dir / "og.png",
    )
    archive_og_url = f"https://etaf.top/packages/og.png?v={archive_og_hash}"

    (package_dir / "index.html").write_text(page(
        "ETAF package archive", body,
        canonical="https://etaf.top/packages/",
        description="ETAF package archive: framework, extensions, applications and games for Emacs 29.1 "
                    "and newer. One package.el entry installs everything.",
        og_image=archive_og_url,
        og_image_alt="ETAF package archive"))
    used_by = {name: [] for name in names}
    for item in packages:
        for dependency, _minimum in item["requirements"]:
            if dependency in used_by and dependency != item["name"]:
                used_by[dependency].append(item["name"])
    workspace = manifest.get("workspace", "")
    for item in packages:
        package_page(item, sources, updated, rows_by_name, used_by,
                     package_dir / item["name"], community.get(item["name"]),
                     og_image=archive_og_url, workspace=workspace)
    return {"packages": len(packages), "updated": str(newest) if newest else None,
            "unplaced": unplaced(packages, community, catalog)}


def package_page(item, sources, updated, rows_by_name, used_by, directory, origin=None, *,
                 og_image="https://etaf.top/packages/og.png", workspace=""):
    """Write one package's detail page.

    ORIGIN names the author of a community package: the page links their
    repository, states the license, and stops promising that `M-x etaf-install`
    owns it.
    """
    name = item["name"]
    safe_name = html.escape(name)
    display = html.escape(source_name(item, origin))
    version = html.escape(item["version"])
    home = (origin or {}).get("url", "")
    community = bool(origin)
    revision = sources.get(name, "")
    if community:
        repo = home
        label = repo.removeprefix("https://").removeprefix("http://")
        commit_url = f"{repo}/commit/{revision}" if revision else ""
        changelog_url = f"{repo}/blob/{revision}/CHANGELOG.md" if revision else ""
    elif name in CORE_PACKAGES:
        repo = (f"https://github.com/{CORE_REPO}" if name == "etaf"
                else f"https://github.com/{CORE_REPO}/tree/main/packages/{name}")
        label = (CORE_REPO if name == "etaf"
                 else f"{CORE_REPO} · packages/{name}")
        if revision and workspace and revision == workspace:
            commit_url = f"https://github.com/{MONOREPO}/commit/{revision}"
            changelog_url = f"https://github.com/{MONOREPO}/blob/{revision}/core/packages/{name}/CHANGELOG.md"
        elif revision:
            commit_url = f"https://github.com/{CORE_REPO}/commit/{revision}"
            changelog_url = f"https://github.com/{CORE_REPO}/blob/{revision}/packages/{name}/CHANGELOG.md"
        else:
            commit_url = ""
            changelog_url = ""
    else:
        slug = REPOSITORIES.get(name, f"emacs-taf/{name}")
        repo = f"https://github.com/{slug}"
        label = slug
        layer = "games" if name in GAME_PACKAGES else "apps"
        if revision and workspace and revision == workspace:
            commit_url = f"https://github.com/{MONOREPO}/commit/{revision}"
            changelog_url = f"https://github.com/{MONOREPO}/blob/{revision}/{layer}/{name}/CHANGELOG.md"
        elif revision:
            commit_url = f"{repo}/commit/{revision}"
            changelog_url = f"{repo}/blob/{revision}/CHANGELOG.md"
        else:
            commit_url = ""
            changelog_url = ""
    facts = inspect_archive(directory.parent / item["file"])
    day = stamp_date(updated.get(name))
    source_line = (
        f'<a href="{html.escape(commit_url)}"><code>{html.escape(revision[:12])}</code></a>'
        if revision and commit_url else "not recorded")
    if day:
        commit_note = (f'<span class="fact-note">newest commit that changed the files this '
                       f"package ships{' — ' + html.escape(revision[:12]) if revision else ''}</span>")
        updated_fact = f'<time datetime="{html.escape(updated[name])}">{long_date(day)}</time>{commit_note}'
        when = (f'<span class="when">updated <time datetime="{html.escape(updated[name])}">'
                f"{short_date(day)}</time></span>")
    else:
        updated_fact = "not recorded"
        when = ""
    pill = ""
    owner = ""
    if community:
        owner = (f"<div><dt>Maintained by</dt><dd>"
                 f"{html.escape((origin or {}).get('maintainer') or label)}</dd></div>"
                 f"<div><dt>License</dt><dd>{html.escape((origin or {}).get('license', 'unspecified'))}</dd></div>")
        if display != safe_name:
            owner += f"<div><dt>Package</dt><dd><code>{safe_name}</code></dd></div>"
    users = sorted(used_by.get(name, []))
    used_by_fact = (", ".join(f'<a href="../{html.escape(other)}/">{html.escape(other)}</a>'
                              for other in users) if users else "nothing else in this archive")
    changes = latest_changes(facts["changelog"])
    changed = ""
    if changes:
        entries = "\n".join(f"<li>{html.escape(text)}</li>" for text in changes)
        more = (f'\n<a class="more" href="{changelog_url}">Read the full changelog</a>'
                if changelog_url else "")
        changed = f"""<section class="changes" aria-labelledby="changes-title">
<div class="group-head"><h2 id="changes-title">Latest changes</h2></div>
<p class="note">Newest entries in the <code>CHANGELOG.md</code> shipped with this version.</p>
<ul>
{entries}
</ul>{more}
</section>
"""
    if community:
        install_note = (
            f"Install <code>{safe_name}</code> with <code>M-x package-install</code> or pick it in "
            "<code>M-x etaf-install</code>; the declared dependencies come from the same archive. "
            f'Read the <a href="{INSTALL}">installation reference</a> for the bootstrap snippet.')
    else:
        install_note = (
            "One entry installs everything ETAF provides. Evaluate this once (it only bootstraps "
            f"the installer), then use <code>M-x etaf-install</code> and pick <code>{safe_name}</code>. "
            "<code>etaf-install</code> checks the required capabilities, installs the framework "
            "dependencies, opens the application and reopens it offline later. Upgrade or remove "
            "with <code>M-x list-packages</code>, then restart Emacs. Read the "
            f'<a href="{INSTALL}">installation reference</a> for the full workflow.')
    body = f"""<main class="wrap">
<nav class="crumbs" aria-label="Breadcrumb"><a href="../">Packages</a>
<span aria-hidden="true">/</span><span>{display}</span></nav>
<section class="hero detail">
<div class="title-row"><h1>{display}</h1><span class="version">{version}</span>{when}{pill}</div>
<p class="lead">{html.escape(item.get("summary", ""))}</p>
<div class="actions">
<a class="button primary" href="../{html.escape(item["file"])}">{TAR_ICON}<span>Download {version}</span></a>
<a class="button" href="{html.escape(repo)}">Repository</a>
<span class="stat"><strong data-downloads="{safe_name}">—</strong> downloads</span>
</div>
</section>
<section class="install" aria-labelledby="install-title">
<div class="install-head"><h2 id="install-title">Install</h2>
<button class="copy" type="button" data-copy="#bootstrap">Copy</button></div>
<pre id="bootstrap"><code>{BOOTSTRAP}</code></pre>
<p class="note">{install_note}</p>
</section>
{changed}<section class="details" aria-labelledby="details-title">
<div class="group-head"><h2 id="details-title">Package details</h2></div>
<dl class="facts">
<div><dt>Version</dt><dd><code>{version}</code></dd></div>
<div><dt>Updated</dt><dd>{updated_fact}</dd></div>
<div><dt>Requires</dt><dd>{requirements_html(item, set(rows_by_name), "../")}</dd></div>
<div><dt>Used by</dt><dd>{used_by_fact}</dd></div>
<div><dt>Installs</dt><dd>{facts["files"]} files, {max(1, round(facts["size"] / 1024))} KB downloaded</dd></div>
<div><dt>Repository</dt><dd><a href="{html.escape(repo)}">{html.escape(label)}</a></dd></div>
<div><dt>Source commit</dt><dd>{source_line}</dd></div>
{owner}<div><dt>SHA-256</dt><dd><code>{html.escape(item["sha256"])}</code></dd></div>
<div><dt>Archive file</dt><dd><a href="../{html.escape(item["file"])}"><code>{html.escape(item["file"])}</code></a>
— the exact bytes <code>package.el</code> installs, byte-compiled locally on install</dd></div>
</dl>
</section>
<footer class="site-footer">
<p>This page is generated from <a href="../manifest.json">manifest.json</a> on every release.
The archive is built from the commit above; rebuild it from that commit to compare the checksum.</p>
<p class="asof" data-downloads-asof hidden></p>
</footer>
</main>"""
    target = directory / "index.html"
    target.parent.mkdir(parents=True, exist_ok=True)
    page_title = f"{source_name(item, origin)} — ETAF package archive"
    target.write_text(page(
        page_title, body, "../downloads.json",
        canonical=f"https://etaf.top/packages/{name}/",
        description=item.get("summary", ""),
        og_image=og_image,
        og_image_alt=page_title))


NATIVE_PLATFORMS = (
    ("darwin-arm64",   "macOS",   "arm64",  "macOS · arm64"),
    ("darwin-x86_64",  "macOS",   "x86_64", "macOS · x86_64"),
    ("linux-x86_64",   "Linux",   "x86_64", "Linux · x86_64"),
    ("linux-arm64",    "Linux",   "arm64",  "Linux · arm64"),
    ("windows-x86_64", "Windows", "x86_64", "Windows · x86_64"),
)
NATIVE_PLATFORM_META = {
    plat_id: {"os": os_name, "arch": arch, "label": label, "order": idx}
    for idx, (plat_id, os_name, arch, label) in enumerate(NATIVE_PLATFORMS)
}
NATIVE_DATE_ONLY = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})\Z")

COPY_ICON = ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
             'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
             '<rect x="9" y="9" width="13" height="13" rx="2"/>'
             '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>')

CHEVRON_ICON = ('<svg class="chev" viewBox="0 0 16 16" fill="none" stroke="currentColor" '
                'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
                '<path d="M6 4l4 4-4 4"/></svg>')

NATIVE_STYLE = """:root {
  --paper-3: #ebe7dd;
  --accent-soft: #ece6f8;
  --ok: #1d6b43;
  --ok-soft: #e6f4ec;
  --warn: #945200;
  --warn-soft: #fdf2e2;
}
:root[data-theme="dark"] {
  --paper-3: #25272b;
  --accent-soft: #2b2540;
  --ok: #6ee7a8;
  --ok-soft: #1a2d24;
  --warn: #f4be6a;
  --warn-soft: #2e2517;
}
.native-hero { padding: clamp(2rem, 4.5vw, 3.2rem) 0 1.4rem; }
.native-hero-grid { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 1.4rem; }
.native-hero-copy { flex: 1 1 28rem; min-width: 0; }
.native-kpis { display: flex; flex-wrap: wrap; gap: .6rem; font-family: var(--font-mono); }
.kpi { padding: .5rem .8rem; border: 1px solid var(--rule); border-radius: 3px; background: var(--paper-2);
  min-width: 6.2rem; }
.kpi-label { display: block; font-size: .64rem; letter-spacing: .1em; text-transform: uppercase; color: var(--ink-3); }
.kpi-val { display: block; margin-top: .15rem; font-size: 1.05rem; font-weight: 600; color: var(--ink);
  font-variant-numeric: tabular-nums; }
.kpi-val.muted { color: var(--ink-2); }
.setup-bar { margin-top: 1.1rem; border: 1px solid var(--rule); border-radius: 3px; background: var(--paper-2); }
.setup-bar > summary { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between;
  gap: .6rem; padding: .6rem .9rem; cursor: pointer; list-style: none; font-size: .88rem; }
.setup-bar > summary::-webkit-details-marker { display: none; }
.setup-bar-left { display: inline-flex; flex-wrap: wrap; align-items: center; gap: .35rem .5rem; min-width: 0; color: var(--ink); }
.setup-bar-hint { color: var(--ink-3); font-size: .84rem; }
.setup-bar-toggle { font-family: var(--font-mono); font-size: .72rem; color: var(--accent); white-space: nowrap; }
.setup-bar[open] .setup-bar-body { padding: .75rem .9rem .95rem; border-top: 1px solid var(--rule); }
.chev { width: .85rem; height: .85rem; flex: none; color: var(--ink-3); transition: transform .15s ease; }
details[open] > summary .chev { transform: rotate(90deg); }
.matrix-card { margin-top: 1.4rem; border: 1px solid var(--rule); border-radius: 3px; background: var(--paper-2);
  padding: .9rem 1rem 1rem; max-width: 100%; }
.matrix-head { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: .5rem; }
.matrix-head h2 { font-family: var(--font-mono); font-size: .72rem; font-weight: 600;
  letter-spacing: .13em; text-transform: uppercase; color: var(--ink-3); }
.matrix-head span { font-size: .8rem; color: var(--ink-3); }
.matrix-scroll { max-width: 100%; overflow-x: auto; margin-top: .55rem; -webkit-overflow-scrolling: touch; }
table.matrix { margin-top: 0; font-family: var(--font-mono); font-size: .75rem; }
table.matrix thead th { padding: .4rem .5rem; font-size: .64rem; white-space: nowrap; }
table.matrix tbody td { padding: .48rem .5rem; vertical-align: middle; }
table.matrix th.m-plat, table.matrix td.m-plat { text-align: center; }
table.matrix tbody tr:hover td { background: var(--paper-3); }
.m-mod { color: var(--ink); font-weight: 600; text-decoration: none; }
.m-mod:hover { color: var(--accent); }
.m-pkg { color: var(--accent); text-decoration: none; }
.m-pkg:hover { text-decoration: underline; }
.m-ok { display: inline-flex; align-items: center; gap: .22rem; padding: .12rem .42rem;
  border: 1px solid transparent; border-radius: 2px; background: var(--ok-soft); color: var(--ok);
  font-family: var(--font-mono); font-size: .72rem; cursor: pointer; }
.m-ok:hover { border-color: var(--ok); }
.m-ok .m-lib { color: var(--ink-2); font-size: .66rem; }
.m-none { color: var(--ink-3); opacity: .5; }
.controls-bar { margin-top: 1.8rem; display: flex; flex-direction: column; gap: .75rem; }
.controls-top { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: .75rem; }
.plat-tabs { display: flex; flex-wrap: wrap; gap: .4rem; }
.plat-tab { display: inline-flex; align-items: center; gap: .4rem; padding: .34rem .68rem;
  border: 1px solid var(--rule); border-radius: 3px; background: var(--paper-2); color: var(--ink-2);
  font-family: var(--font-mono); font-size: .73rem; cursor: pointer; }
.plat-tab:hover { color: var(--ink); border-color: var(--accent); }
.plat-tab[aria-selected="true"] { background: var(--accent-soft); border-color: var(--accent);
  color: var(--accent); font-weight: 600; }
.plat-tab .cnt { font-size: .68rem; opacity: .8; font-variant-numeric: tabular-nums; }
.plat-tab .here { width: .4rem; height: .4rem; border-radius: 50%; background: var(--ok); flex: none; }
.view-switch { display: inline-flex; padding: .18rem; border: 1px solid var(--rule);
  border-radius: 3px; background: var(--paper-2); font-family: var(--font-mono); font-size: .72rem; }
.view-btn { padding: .24rem .62rem; border: 0; border-radius: 2px; background: transparent;
  color: var(--ink-3); font: inherit; cursor: pointer; }
.view-btn:hover { color: var(--ink); }
.view-btn[aria-pressed="true"] { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
.controls-search { display: flex; flex-wrap: wrap; align-items: stretch; gap: .6rem; }
.controls-search .filter { margin: 0; flex: 1 1 20rem; }
.arch-toggle { display: inline-flex; align-items: center; gap: .45rem; padding: .42rem .72rem;
  border: 1px solid var(--rule); border-radius: 2px; background: var(--paper-2); color: var(--ink-2);
  font-family: var(--font-mono); font-size: .74rem; cursor: pointer; user-select: none; }
.arch-toggle:hover { border-color: var(--accent); color: var(--ink); }
.arch-toggle input { margin: 0; accent-color: var(--accent); cursor: pointer; }
.mod-card { margin-top: 1.5rem; border: 1px solid var(--rule); border-radius: 3px;
  background: var(--paper); overflow: hidden; }
.mod-head { padding: 1rem 1.15rem .9rem; background: var(--paper-2); border-bottom: 1px solid var(--rule); }
.mod-head-top { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: .6rem; }
.mod-title-group { display: flex; flex-wrap: wrap; align-items: center; gap: .5rem; }
.mod-title-group h2 { font-family: var(--font-mono); font-size: 1.15rem; font-weight: 600; letter-spacing: -.01em; }
.pill { display: inline-flex; align-items: center; padding: .12rem .48rem; border: 1px solid var(--rule);
  border-radius: 2px; background: var(--paper); color: var(--ink-2); font-family: var(--font-mono);
  font-size: .7rem; white-space: nowrap; text-decoration: none; }
.pill.current { background: var(--accent-soft); border-color: var(--accent); color: var(--accent); font-weight: 600; }
.pill.pkg-link { color: var(--accent); }
.pill.pkg-link:hover { border-color: var(--accent); }
.pill.compat { color: var(--ink-3); }
.pill.archived { color: var(--ink-3); background: var(--paper-2); }
.mod-desc { margin: .55rem 0 0; color: var(--ink-2); font-size: .92rem; line-height: 1.55; max-width: 58rem; }
.mod-submeta { margin: .55rem 0 0; display: flex; flex-wrap: wrap; align-items: baseline; gap: .35rem 1.2rem;
  font-size: .8rem; color: var(--ink-3); }
.mod-submeta strong { color: var(--ink-2); font-weight: 600; }
.used-list { font-family: var(--font-mono); font-size: .73rem; }
.used-list a { color: var(--ink-2); text-decoration-color: var(--rule-strong); }
.used-list a:hover { color: var(--accent); }
.mod-table-wrap { overflow-x: auto; }
table.native-tbl { margin-top: 0; }
table.native-tbl thead th { padding: .5rem .8rem; background: var(--paper); border-bottom: 1px solid var(--rule); }
table.native-tbl tbody td { padding: .72rem .8rem; border-bottom: 1px solid var(--rule); vertical-align: top; }
table.native-tbl tbody tr:last-child td { border-bottom: 0; }
table.native-tbl th:first-child, table.native-tbl td:first-child { padding-left: 1.15rem; }
table.native-tbl th:last-child, table.native-tbl td:last-child { padding-right: 1.15rem; }
.bin-main { display: flex; flex-wrap: wrap; align-items: center; gap: .45rem; }
.bin-prefix { color: var(--ink-3); font-family: var(--font-mono); user-select: none; }
.bin-name { font-family: var(--font-mono); font-size: .82rem; font-weight: 600; color: var(--ink);
  text-decoration: none; overflow-wrap: anywhere; }
.bin-name:hover { color: var(--accent); text-decoration: underline; }
.role-badge { display: inline-flex; align-items: center; padding: .06rem .38rem; border-radius: 2px;
  font-family: var(--font-mono); font-size: .66rem; white-space: nowrap; }
.role-badge.role-module { border: 1px solid var(--rule); background: var(--paper-2); color: var(--ink-3); }
.role-badge.role-library { border: 1px solid var(--warn); background: var(--warn-soft); color: var(--warn); font-weight: 500; }
.bin-note { display: block; margin-top: .22rem; color: var(--ink-3); font-size: .8rem; line-height: 1.45; }
.bin-note code { font-size: .74rem; }
.plat-btn { display: inline-flex; align-items: center; padding: .14rem .48rem; border: 1px solid var(--rule);
  border-radius: 2px; background: var(--paper-2); color: var(--ink-2); font-family: var(--font-mono);
  font-size: .73rem; white-space: nowrap; cursor: pointer; }
.plat-btn:hover { border-color: var(--accent); color: var(--accent); }
.built-cell { font-family: var(--font-mono); font-size: .74rem; color: var(--ink-3); white-space: nowrap; }
.sha-cell { white-space: nowrap; }
.sha-wrap { display: inline-flex; align-items: center; gap: .38rem; }
.sha-code { font-family: var(--font-mono); font-size: .72rem; color: var(--ink-3); }
.copy-mini { display: inline-flex; align-items: center; gap: .25rem; padding: .16rem .42rem;
  border: 1px solid var(--rule); border-radius: 2px; background: transparent; color: var(--ink-3);
  font-family: var(--font-mono); font-size: .66rem; cursor: pointer; }
.copy-mini:hover, .copy-mini.done { border-color: var(--accent); color: var(--accent); }
.copy-mini svg { width: .72rem; height: .72rem; }
.dl-btn { display: inline-flex; align-items: center; gap: .32rem; padding: .24rem .58rem;
  border: 1px solid var(--rule-strong); border-radius: 2px; background: var(--paper-2); color: var(--ink-2);
  font-family: var(--font-mono); font-size: .72rem; text-decoration: none; white-space: nowrap; }
.dl-btn:hover { border-color: var(--accent); color: var(--accent); }
.dl-btn svg { width: .82rem; height: .82rem; flex: none; }
.mod-empty { padding: .85rem 1.15rem; font-size: .84rem; color: var(--ink-3);
  display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: .5rem; }
.link-btn { padding: 0; border: 0; background: none; color: var(--accent); font-family: var(--font-mono);
  font-size: .74rem; cursor: pointer; text-decoration: underline; }
.archived-drawer { border-top: 1px solid var(--rule); background: var(--paper-2); }
.archived-drawer > summary { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between;
  gap: .5rem; padding: .62rem 1.15rem; cursor: pointer; list-style: none; font-size: .8rem; color: var(--ink-3); }
.archived-drawer > summary::-webkit-details-marker { display: none; }
.archived-drawer > summary:hover { background: var(--paper-3); color: var(--ink-2); }
.archived-summary-left { display: inline-flex; flex-wrap: wrap; align-items: center; gap: .45rem;
  font-family: var(--font-mono); font-size: .74rem; }
.archived-ver-bar { padding: .48rem 1.15rem; border-top: 1px solid var(--rule); background: var(--paper-3);
  display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: .5rem;
  font-size: .78rem; color: var(--ink-3); }
.archived-ver-left { display: inline-flex; flex-wrap: wrap; align-items: center; gap: .45rem;
  font-family: var(--font-mono); font-size: .73rem; }
.archived-drawer table.native-tbl { background: var(--paper); }
.archived-drawer table.native-tbl tbody tr { opacity: .88; }
.empty-banner { margin-top: 1.5rem; padding: 1.5rem; border: 1px solid var(--rule); border-radius: 3px;
  background: var(--paper-2); text-align: center; }
.empty-banner p { margin: 0 0 .7rem; color: var(--ink-2); font-size: .92rem; }
@media (max-width: 760px) {
  .native-hero { padding: 1.5rem 0 1rem; }
  .native-hero-copy { flex: 1 1 100%; }
  .native-hero h1 { font-size: 2rem; }
  .native-kpis { width: 100%; }
  .kpi { flex: 1 1 calc(50% - .4rem); min-width: 0; }
  .setup-bar-hint { display: none; }
  .matrix-card { padding: .8rem .85rem .85rem; }
  table.matrix { min-width: 34rem; }
  table.matrix thead { display: table-header-group; }
  table.matrix tbody tr { display: table-row; padding: 0; border-bottom: 0; }
  table.matrix tbody td { display: table-cell; padding: .44rem .45rem; border-bottom: 1px solid var(--rule); }
  table.matrix tbody tr:last-child td { border-bottom: 0; }
  .mod-table-wrap { overflow-x: visible; }
  table.native-tbl thead { display: none; }
  table.native-tbl tbody tr { display: grid; grid-template-columns: minmax(0, 1fr) auto;
    grid-template-areas: "bin bin" "plat meta" "sha dl";
    gap: .45rem .65rem; align-items: center; padding: .8rem .9rem; border-bottom: 1px solid var(--rule); }
  table.native-tbl tbody td { padding: 0 !important; border-bottom: 0; }
  table.native-tbl tbody tr:hover td { background: none; }
  table.native-tbl td.bin-cell { grid-area: bin; min-width: 0; }
  table.native-tbl td.plat-cell, table.native-tbl td.ver-cell { grid-area: plat; justify-self: start; }
  table.native-tbl td.size-cell { grid-area: meta; justify-self: end; text-align: right; font-size: .76rem; }
  table.native-tbl td.built-cell { display: none; }
  table.native-tbl td.sha-cell { grid-area: sha; min-width: 0; white-space: normal; }
  table.native-tbl td.dl-cell { grid-area: dl; justify-self: end; width: auto; }
  .sha-wrap { flex-wrap: wrap; }
  .sha-code { font-size: .68rem; }
  .mod-head { padding: .85rem .9rem; }
  .archived-drawer > summary, .archived-ver-bar { padding-left: .9rem; padding-right: .9rem; }
}"""

NATIVE_SCRIPT = """(() => {
  const copyText = async (text, button, idleLabel) => {
    try {
      await navigator.clipboard.writeText(text);
    } catch (error) {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      document.execCommand('copy');
      area.remove();
    }
    const label = button.querySelector('[data-copy-label]') || button;
    label.textContent = 'Copied';
    button.classList.add('done');
    setTimeout(() => {
      label.textContent = idleLabel;
      button.classList.remove('done');
    }, 1500);
  };

  document.addEventListener('click', (event) => {
    if (!(event.target instanceof Element)) return;
    const copySel = event.target.closest('[data-copy]');
    if (copySel) {
      const target = document.querySelector(copySel.dataset.copy);
      if (target) copyText(target.textContent, copySel, 'Copy');
      return;
    }
    const copyRaw = event.target.closest('[data-copy-text]');
    if (copyRaw) {
      copyText(copyRaw.dataset.copyText, copyRaw, 'Copy');
      return;
    }
  });

  const controls = document.querySelector('[data-native-controls]');
  const modView = document.getElementById('native-module-view');
  const platView = document.getElementById('native-platform-view');
  const searchInput = document.getElementById('native-filter');
  const archToggle = document.getElementById('native-expand-archived');
  const emptyBanner = document.querySelector('[data-filter-empty]');
  if (!controls || !modView || !platView || !searchInput) return;

  controls.hidden = false;

  // Detect visitor OS family for a gentle hint dot on matching platform tab(s).
  const ua = (navigator.userAgent || '') + ' ' + (navigator.platform || '');
  const detectedOs = /Mac/i.test(ua) ? 'darwin' : /Win/i.test(ua) ? 'windows' : /Linux|X11/i.test(ua) ? 'linux' : '';
  if (detectedOs) {
    controls.querySelectorAll('[data-plat-tab]').forEach((btn) => {
      if (btn.dataset.platTab.startsWith(detectedOs + '-')) {
        const dot = document.createElement('span');
        dot.className = 'here';
        dot.title = 'Matches your operating system';
        btn.prepend(dot);
      }
    });
  }

  const state = { platform: 'all', mode: 'module', query: '', expandArchived: false };
  const allRows = Array.from(modView.querySelectorAll('tr[data-artifact-path]'));
  const modCards = Array.from(modView.querySelectorAll('section.mod-card'));

  const platLabels = {};
  controls.querySelectorAll('[data-plat-tab]').forEach((btn) => {
    if (btn.dataset.platTab !== 'all') {
      platLabels[btn.dataset.platTab] = btn.dataset.platLabel || btn.dataset.platTab;
    }
  });
  const platOrder = Object.keys(platLabels);

  const rowMatches = (row) => {
    if (state.platform !== 'all' && row.dataset.platform !== state.platform) return false;
    const terms = state.query.trim().toLowerCase().split(/\\s+/).filter(Boolean);
    if (!terms.length) return true;
    const hay = row.dataset.search || '';
    return terms.every((term) => hay.includes(term));
  };

  const renderPlatformView = () => {
    const targets = state.platform === 'all' ? platOrder : [state.platform];
    const queryActive = state.query.trim().length > 0;
    const frag = document.createDocumentFragment();
    let visibleSections = 0;

    for (const plat of targets) {
      const matched = allRows.filter((row) => row.dataset.platform === plat && rowMatches(row));
      if (!matched.length) continue;
      visibleSections += 1;
      const cur = matched.filter((r) => r.dataset.current === '1');
      const arch = matched.filter((r) => r.dataset.current !== '1');

      const section = document.createElement('section');
      section.className = 'mod-card';

      const head = document.createElement('div');
      head.className = 'mod-head';
      const top = document.createElement('div');
      top.className = 'mod-head-top';
      const titleGroup = document.createElement('div');
      titleGroup.className = 'mod-title-group';
      const h2 = document.createElement('h2');
      h2.textContent = platLabels[plat] || plat;
      const code = document.createElement('span');
      code.className = 'pill';
      code.textContent = plat;
      titleGroup.append(h2, code);

      const countTag = document.createElement('span');
      countTag.className = 'tag';
      countTag.textContent = cur.length + ' current' + (arch.length ? ' · ' + arch.length + ' archived' : '');
      top.append(titleGroup, countTag);
      head.append(top);
      section.append(head);

      const makeTable = (rows, withHead) => {
        const wrap = document.createElement('div');
        wrap.className = 'mod-table-wrap';
        const tbl = document.createElement('table');
        tbl.className = 'native-tbl';
        if (withHead) {
          tbl.innerHTML = '<thead><tr><th scope="col">Binary</th><th scope="col">Version</th>'
            + '<th scope="col" class="num">Size</th><th scope="col">Built</th>'
            + '<th scope="col">SHA-256</th><th scope="col" class="src">Download</th></tr></thead>';
        }
        const tbody = document.createElement('tbody');
        for (const orig of rows) {
          const clone = orig.cloneNode(true);
          clone.hidden = false;
          clone.removeAttribute('data-artifact-path');
          const platCell = clone.querySelector('td.plat-cell');
          if (platCell) {
            platCell.className = 'ver-cell';
            platCell.innerHTML = '';
            const vp = document.createElement('span');
            vp.className = 'pill';
            vp.textContent = orig.dataset.module + ' v' + orig.dataset.version;
            platCell.append(vp);
          }
          tbody.append(clone);
        }
        tbl.append(tbody);
        wrap.append(tbl);
        return wrap;
      };

      if (cur.length) section.append(makeTable(cur, true));

      if (arch.length) {
        const details = document.createElement('details');
        details.className = 'archived-drawer';
        if (state.expandArchived || (queryActive && cur.length === 0)) details.open = true;
        const summary = document.createElement('summary');
        const left = document.createElement('span');
        left.className = 'archived-summary-left';
        left.innerHTML = '<svg class="chev" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 4l4 4-4 4"/></svg>'
          + '<span>Archived versions</span><span class="pill archived">' + arch.length + (arch.length === 1 ? ' binary' : ' binaries') + '</span>';
        summary.append(left);
        details.append(summary, makeTable(arch, cur.length === 0));
        section.append(details);
      }

      frag.append(section);
    }

    platView.innerHTML = '';
    platView.append(frag);
    if (emptyBanner) emptyBanner.hidden = visibleSections > 0;
  };

  const apply = () => {
    controls.querySelectorAll('[data-plat-tab]').forEach((btn) => {
      btn.setAttribute('aria-selected', String(btn.dataset.platTab === state.platform));
    });
    controls.querySelectorAll('[data-view-mode]').forEach((btn) => {
      btn.setAttribute('aria-pressed', String(btn.dataset.viewMode === state.mode));
    });

    if (state.mode === 'platform') {
      modView.hidden = true;
      platView.hidden = false;
      renderPlatformView();
      return;
    }

    modView.hidden = false;
    platView.hidden = true;
    const queryActive = state.query.trim().length > 0;
    let visibleCards = 0;

    for (const card of modCards) {
      const curRows = Array.from(card.querySelectorAll('tbody[data-current-body] tr[data-artifact-path]'));
      const archDrawer = card.querySelector('details[data-archived-drawer]');
      const archRows = archDrawer ? Array.from(archDrawer.querySelectorAll('tr[data-artifact-path]')) : [];
      let curVisible = 0;
      let archVisible = 0;

      for (const row of curRows) {
        const ok = rowMatches(row);
        row.hidden = !ok;
        if (ok) curVisible += 1;
      }
      for (const row of archRows) {
        const ok = rowMatches(row);
        row.hidden = !ok;
        if (ok) archVisible += 1;
      }

      if (archDrawer) {
        archDrawer.querySelectorAll('[data-archived-version-group]').forEach((grp) => {
          const any = Array.from(grp.querySelectorAll('tr[data-artifact-path]')).some((r) => !r.hidden);
          grp.hidden = !any;
        });
        archDrawer.hidden = archVisible === 0;
        const archBadge = archDrawer.querySelector('[data-archived-count]');
        if (archBadge) {
          const vers = archBadge.dataset.archivedVersions || '';
          archBadge.textContent = (vers ? vers + ' · ' : '') + archVisible + (archVisible === 1 ? ' binary' : ' binaries');
        }
        if (state.expandArchived || (queryActive && archVisible > 0)) {
          archDrawer.open = true;
        } else if (!queryActive) {
          archDrawer.open = false;
        }
      }

      const curWrap = card.querySelector('[data-current-table-wrap]');
      const modEmpty = card.querySelector('[data-mod-empty]');
      if (curWrap) curWrap.hidden = curVisible === 0;
      if (modEmpty) {
        const showPlatformNotice = !queryActive && state.platform !== 'all' && curVisible === 0;
        modEmpty.hidden = !showPlatformNotice;
        const slot = modEmpty.querySelector('[data-missing-plat]');
        if (slot) slot.textContent = platLabels[state.platform] || state.platform;
      }

      const cardVisible = queryActive ? (curVisible + archVisible > 0) : true;
      card.hidden = !cardVisible;
      if (cardVisible) visibleCards += 1;

      const tag = card.querySelector('[data-mod-count]');
      if (tag) {
        tag.textContent = curVisible + ' current' + (archVisible ? ' · ' + archVisible + ' archived' : '');
      }
    }

    if (emptyBanner) emptyBanner.hidden = visibleCards > 0;
  };

  document.addEventListener('click', (event) => {
    if (!(event.target instanceof Element)) return;
    const tab = event.target.closest('[data-plat-tab]');
    if (tab) {
      state.platform = tab.dataset.platTab;
      apply();
      return;
    }
    const pick = event.target.closest('[data-pick-platform]');
    if (pick) {
      const next = pick.dataset.pickPlatform;
      state.platform = state.platform === next ? 'all' : next;
      apply();
      return;
    }
    const modeBtn = event.target.closest('[data-view-mode]');
    if (modeBtn) {
      state.mode = modeBtn.dataset.viewMode;
      apply();
      return;
    }
    if (event.target.closest('[data-reset-filters]')) {
      state.platform = 'all';
      state.query = '';
      searchInput.value = '';
      apply();
    }
  });

  searchInput.addEventListener('input', () => {
    state.query = searchInput.value;
    apply();
  });

  if (archToggle) {
    archToggle.addEventListener('change', () => {
      state.expandArchived = archToggle.checked;
      apply();
    });
  }

  document.addEventListener('keydown', (event) => {
    const active = document.activeElement;
    if (event.key === '/' && !event.metaKey && !event.ctrlKey && !event.altKey) {
      if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) return;
      event.preventDefault();
      searchInput.focus();
    } else if (event.key === 'Escape' && active === searchInput) {
      searchInput.value = '';
      state.query = '';
      apply();
      searchInput.blur();
    }
  });

  apply();
})();"""


def format_bytes(size):
    """Return a concise human-readable byte size string."""
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.2f} MB"
    return f"{max(1, round(size / 1024))} KB"


def native_version_key(version):
    """Return numeric sort key for a dotted native version string."""
    return tuple(int(part) for part in str(version).split("."))


def native_date_cell(value):
    """Format an ISO timestamp or YYYY-MM-DD date string for native tables."""
    day = stamp_date(value)
    if not day and isinstance(value, str):
        match = NATIVE_DATE_ONLY.fullmatch(value)
        if match:
            try:
                day = date.fromisoformat(match[1])
            except ValueError:
                day = None
    if not day:
        return '<td class="built-cell"><span aria-label="not recorded">—</span></td>'
    return (f'<td class="built-cell"><time datetime="{html.escape(value)}" '
            f'title="{html.escape(long_date(day))}">{short_date(day)}</time></td>')


def _native_short_date(value):
    day = stamp_date(value)
    if not day and isinstance(value, str) and NATIVE_DATE_ONLY.fullmatch(value):
        try:
            day = date.fromisoformat(value)
        except ValueError:
            day = None
    return short_date(day) if day else ""


def _native_platform_order(plat):
    meta = NATIVE_PLATFORM_META.get(plat)
    return (meta["order"], plat) if meta else (99, plat)


def _native_platform_label(plat):
    meta = NATIVE_PLATFORM_META.get(plat)
    return meta["label"] if meta else plat


def _native_artifact_row(item, owner_module, is_current):
    """Render one binary artifact row with binary filename as primary identity."""
    plat = item["platform"]
    plat_label = _native_platform_label(plat)
    pkg = item["package"]
    mod = item["module"]
    ver = item["version"]
    role = item.get("role", "module")
    path = item["path"]
    filename = Path(path).name
    sha = item["sha256"]
    size_label = format_bytes(item["size"])
    runtime_name = item.get("runtime_name", "")
    note = item.get("note", "")

    role_label = "Runtime lib" if role == "library" else "Module"
    role_cls = "role-library" if role == "library" else "role-module"
    prefix_html = '<span class="bin-prefix" aria-hidden="true">↳</span>' if role == "library" else ""
    note_parts = []
    if role == "library" and runtime_name:
        note_parts.append(f"cached as <code>{html.escape(runtime_name)}</code>")
    if note:
        note_parts.append(html.escape(note))
    note_html = f'<span class="bin-note">{" — ".join(note_parts)}</span>' if note_parts else ""

    search_terms = " ".join(filter(None, [
        pkg, owner_module, mod, f"v{ver}", ver, plat, plat_label,
        filename, role, role_label, runtime_name, sha,
    ])).lower()

    return (
        f'<tr data-artifact-path="{html.escape(path, quote=True)}"'
        f' data-platform="{html.escape(plat, quote=True)}"'
        f' data-module="{html.escape(owner_module, quote=True)}"'
        f' data-package="{html.escape(pkg, quote=True)}"'
        f' data-version="{html.escape(ver, quote=True)}"'
        f' data-role="{html.escape(role, quote=True)}"'
        f' data-current="{"1" if is_current else "0"}"'
        f' data-search="{html.escape(search_terms, quote=True)}">'
        f'<td class="bin-cell"><div class="bin-main">{prefix_html}'
        f'<a class="bin-name" href="{html.escape(path, quote=True)}">{html.escape(filename)}</a>'
        f'<span class="role-badge {role_cls}">{role_label}</span></div>{note_html}</td>'
        f'<td class="plat-cell"><button class="plat-btn" type="button"'
        f' data-pick-platform="{html.escape(plat, quote=True)}"'
        f' title="Filter by {html.escape(plat, quote=True)}">{html.escape(plat_label)}</button></td>'
        f'<td class="num size-cell">{html.escape(size_label)}</td>'
        f'{native_date_cell(item.get("built_at"))}'
        f'<td class="sha-cell"><span class="sha-wrap">'
        f'<code class="sha-code" title="{html.escape(sha, quote=True)}">{html.escape(sha[:12])}…{html.escape(sha[-6:])}</code>'
        f'<button class="copy-mini" type="button" data-copy-text="{html.escape(sha, quote=True)}"'
        f' title="Copy full SHA-256">{COPY_ICON}<span data-copy-label>Copy</span></button>'
        f'</span></td>'
        f'<td class="src dl-cell"><a class="dl-btn" href="{html.escape(path, quote=True)}"'
        f' title="Download {html.escape(filename, quote=True)}">{TAR_ICON}<span>Download</span></a></td>'
        '</tr>'
    )


def native_pages(native_dir, manifest=None):
    """Write a browsable, data-driven index.html for hosted prebuilt native binaries."""
    if manifest is None:
        manifest = json.loads((native_dir / "manifest.json").read_text(encoding="utf-8"))
    artifacts = list(manifest.get("artifacts", []))
    modules_catalog = manifest.get("modules") or {}

    # Group artifacts by owning module (attaching companion runtime libraries to their module).
    by_module = {}
    for item in artifacts:
        owner = item.get("owner_module") or item["module"]
        by_module.setdefault(owner, []).append(item)

    present_platforms = sorted({item["platform"] for item in artifacts}, key=_native_platform_order)
    matrix_platforms = [p[0] for p in NATIVE_PLATFORMS if p[0] in present_platforms]
    for plat in present_platforms:
        if plat not in matrix_platforms:
            matrix_platforms.append(plat)

    module_names = sorted(by_module)
    current_total = 0
    archived_total = 0
    current_by_platform = {plat: 0 for plat in matrix_platforms}
    matrix_rows = []
    module_sections = []

    for mod_name in module_names:
        items = by_module[mod_name]
        meta = modules_catalog.get(mod_name) or {}
        pkg = meta.get("package") or items[0]["package"]
        versions_present = sorted({item["version"] for item in items}, key=native_version_key, reverse=True)
        declared_current = meta.get("current_version")
        current_ver = declared_current if declared_current in versions_present else versions_present[0]
        archived_vers = [v for v in versions_present if v != current_ver]

        current_items = sorted(
            [i for i in items if i["version"] == current_ver],
            key=lambda i: (_native_platform_order(i["platform"]), 0 if i.get("role", "module") == "module" else 1, i["path"]),
        )
        archived_items = [i for i in items if i["version"] != current_ver]
        current_total += len(current_items)
        archived_total += len(archived_items)
        for i in current_items:
            current_by_platform[i["platform"]] = current_by_platform.get(i["platform"], 0) + 1

        safe_mod = html.escape(mod_name)
        safe_pkg = html.escape(pkg)
        safe_cur = html.escape(current_ver)
        desc = html.escape(meta.get("description") or f"Prebuilt native dynamic module for {pkg}.")
        versions_meta = meta.get("versions") or {}
        cur_vmeta = versions_meta.get(current_ver) or {}
        used_by = meta.get("used_by") or [pkg]

        # Support matrix row
        plat_cells = []
        for plat in matrix_platforms:
            matched = [i for i in current_items if i["platform"] == plat]
            if not matched:
                plat_cells.append(f'<td class="m-plat"><span class="m-none" title="No prebuild for {html.escape(_native_platform_label(plat))}">—</span></td>')
            else:
                has_lib = any(i.get("role") == "library" for i in matched)
                lib_tag = '<span class="m-lib">+lib</span>' if has_lib else ""
                tip = f"Filter by {_native_platform_label(plat)}" + (" (includes companion runtime library)" if has_lib else "")
                plat_cells.append(
                    f'<td class="m-plat"><button class="m-ok" type="button"'
                    f' data-pick-platform="{html.escape(plat, quote=True)}"'
                    f' title="{html.escape(tip, quote=True)}">✓{lib_tag}</button></td>'
                )
        matrix_rows.append(
            f'<tr>'
            f'<td><a class="m-mod" href="#mod-{safe_mod}">{safe_mod}</a></td>'
            f'<td><a class="m-pkg" href="../packages/{safe_pkg}/">{safe_pkg}</a></td>'
            f'<td><span class="pill current">v{safe_cur}</span></td>'
            f'{"".join(plat_cells)}'
            f'</tr>'
        )

        # Module header pills & metadata
        compat_pill = ""
        if cur_vmeta.get("min_package_version"):
            compat_pill = f'<span class="pill compat">{safe_pkg} ≥ {html.escape(cur_vmeta["min_package_version"])}</span>'

        submeta_parts = []
        if cur_vmeta.get("summary"):
            submeta_parts.append(f'<span><strong>Release note:</strong> {html.escape(cur_vmeta["summary"])}</span>')
        cur_rel = _native_short_date(cur_vmeta.get("released"))
        if cur_rel:
            submeta_parts.append(f'<span><strong>Released:</strong> <time datetime="{html.escape(cur_vmeta["released"], quote=True)}">{html.escape(cur_rel)}</time></span>')
        used_links = ", ".join(
            f'<a href="../packages/{html.escape(u, quote=True)}/">{html.escape(u)}</a>'
            for u in used_by
        )
        submeta_parts.append(f'<span class="used-list">Used by: {used_links}</span>')

        count_label = f"{len(current_items)} current" + (f" · {len(archived_items)} archived" if archived_items else "")
        cur_rows_html = "\n".join(_native_artifact_row(i, mod_name, True) for i in current_items)

        # Collapsed archived versions drawer
        archived_html = ""
        if archived_vers:
            ver_blocks = []
            for ver in archived_vers:
                v_items = sorted(
                    [i for i in archived_items if i["version"] == ver],
                    key=lambda i: (_native_platform_order(i["platform"]), 0 if i.get("role", "module") == "module" else 1, i["path"]),
                )
                vmeta = versions_meta.get(ver) or {}
                v_compat = ""
                if vmeta.get("max_package_version"):
                    v_compat = f'<span class="pill compat">{safe_pkg} ≤ {html.escape(vmeta["max_package_version"])}</span>'
                elif vmeta.get("min_package_version"):
                    v_compat = f'<span class="pill compat">{safe_pkg} ≥ {html.escape(vmeta["min_package_version"])}</span>'
                v_rel = _native_short_date(vmeta.get("released"))
                v_rel_html = f'<span>{html.escape(v_rel)}</span>' if v_rel else ""
                v_summary = html.escape(vmeta.get("summary") or "Archived compatibility release retained for older package manifests.")
                v_rows_html = "\n".join(_native_artifact_row(i, mod_name, False) for i in v_items)
                ver_blocks.append(f"""<div data-archived-version-group="{html.escape(ver, quote=True)}">
<div class="archived-ver-bar">
<span class="archived-ver-left"><span class="pill archived">v{html.escape(ver)}</span><span>Archived</span>{v_compat}{v_rel_html}</span>
<span>{v_summary}</span>
</div>
<div class="mod-table-wrap">
<table class="native-tbl">
<tbody>
{v_rows_html}
</tbody>
</table>
</div>
</div>""")
            ver_list_label = ", ".join(f"v{v}" for v in archived_vers)
            arch_noun = "binary" if len(archived_items) == 1 else "binaries"
            archived_html = f"""<details class="archived-drawer" data-archived-drawer>
<summary>
<span class="archived-summary-left">{CHEVRON_ICON}<span>Archived versions</span>
<span class="pill archived" data-archived-count data-archived-versions="{html.escape(ver_list_label, quote=True)}">{html.escape(ver_list_label)} · {len(archived_items)} {arch_noun}</span></span>
<span>Retained immutably for older ELPA package manifests</span>
</summary>
{chr(10).join(ver_blocks)}
</details>"""

        module_sections.append(f"""<section class="mod-card" id="mod-{safe_mod}">
<div class="mod-head">
<div class="mod-head-top">
<div class="mod-title-group">
<h2>{safe_mod}</h2>
<span class="pill current">v{safe_cur} · Current</span>
<a class="pill pkg-link" href="../packages/{safe_pkg}/">package: {safe_pkg} ↗</a>
{compat_pill}
</div>
<span class="tag" data-mod-count>{count_label}</span>
</div>
<p class="mod-desc">{desc}</p>
<div class="mod-submeta">{"".join(submeta_parts)}</div>
</div>
<div class="mod-table-wrap" data-current-table-wrap>
<table class="native-tbl">
<thead><tr><th scope="col">Binary</th><th scope="col">Platform</th>
<th scope="col" class="num">Size</th><th scope="col">Built</th>
<th scope="col">SHA-256</th><th scope="col" class="src">Download</th></tr></thead>
<tbody data-current-body>
{cur_rows_html}
</tbody>
</table>
</div>
<div class="mod-empty" data-mod-empty hidden>
<span>No prebuilt binary published for <strong data-missing-plat></strong> yet. <code>{safe_pkg}</code> falls back cleanly without blocking installation.</span>
<button class="link-btn" type="button" data-plat-tab="all">Show all platforms</button>
</div>
{archived_html}
</section>""")

    # Platform category filter tabs
    plat_tabs = [
        f'<button class="plat-tab" type="button" role="tab" aria-selected="true" data-plat-tab="all">'
        f'<span>All platforms</span><span class="cnt">{current_total}</span></button>'
    ]
    for plat in matrix_platforms:
        label = _native_platform_label(plat)
        plat_tabs.append(
            f'<button class="plat-tab" type="button" role="tab" aria-selected="false"'
            f' data-plat-tab="{html.escape(plat, quote=True)}"'
            f' data-plat-label="{html.escape(label, quote=True)}">'
            f'<span>{html.escape(label)}</span><span class="cnt">{current_by_platform.get(plat, 0)}</span></button>'
        )

    matrix_headers = "".join(
        f'<th scope="col" class="m-plat">{html.escape(_native_platform_label(p))}</th>'
        for p in matrix_platforms
    )

    packages_count = len({item["package"] for item in artifacts})
    archived_kpi = (
        f'<div class="kpi"><span class="kpi-label">Archived</span>'
        f'<span class="kpi-val muted">{archived_total}</span></div>'
        if archived_total else ""
    )

    body = f"""<main class="wrap">
<nav class="crumbs" aria-label="Breadcrumb"><a href="/">ETAF</a>
<span aria-hidden="true">/</span><a href="/packages/">Packages</a>
<span aria-hidden="true">/</span><span>Native binaries</span></nav>
<section class="native-hero">
<div class="native-hero-grid">
<div class="native-hero-copy">
<p class="eyebrow">Prebuilt Emacs dynamic modules</p>
<h1>ETAF native binaries</h1>
<p class="lead">Checksum-verified prebuilt binaries for ETAF packages.
<code>M-x etaf-install</code> downloads, verifies (SHA-256) and activates matching binaries automatically
into <code>~/.cache/emacs-taf/native/</code> — no C compiler or manual build required.</p>
</div>
<div class="native-kpis" aria-label="Summary counts">
<div class="kpi"><span class="kpi-label">Modules</span><span class="kpi-val">{len(module_names)}</span></div>
<div class="kpi"><span class="kpi-label">Current</span><span class="kpi-val">{current_total}</span></div>
{archived_kpi}
<div class="kpi"><span class="kpi-label">ABI</span><span class="kpi-val">Emacs 29.1+</span></div>
</div>
</div>
<details class="setup-bar">
<summary>
<span class="setup-bar-left">{CHEVRON_ICON}<strong>Install automatically inside Emacs</strong>
<span class="setup-bar-hint">— <code>M-x etaf-install</code> or <code>M-x etaf-install-native</code></span></span>
<span class="setup-bar-toggle">Show bootstrap snippet</span>
</summary>
<div class="setup-bar-body">
<div class="install-head"><span class="note" style="margin:0">Evaluate once to bootstrap <code>etaf-install</code>, or press <code>n</code> in <code>M-x etaf-install-manage</code> to manage native modules.</span>
<button class="copy" type="button" data-copy="#bootstrap">Copy</button></div>
<pre id="bootstrap"><code>{BOOTSTRAP}</code></pre>
</div>
</details>
</section>
<section class="matrix-card" aria-labelledby="matrix-title">
<div class="matrix-head">
<h2 id="matrix-title">Current release support matrix</h2>
<span>Click a check mark to filter by platform · <a href="manifest.json">manifest.json</a></span>
</div>
<div class="matrix-scroll">
<table class="matrix">
<thead><tr><th scope="col">Module</th><th scope="col">Package</th><th scope="col">Current</th>{matrix_headers}</tr></thead>
<tbody>
{chr(10).join(matrix_rows)}
</tbody>
</table>
</div>
</section>
<section class="controls-bar" data-native-controls hidden aria-label="Filter and view options">
<div class="controls-top">
<div class="plat-tabs" role="tablist" aria-label="Filter by platform category">
{chr(10).join(plat_tabs)}
</div>
<div class="view-switch" role="group" aria-label="Group binaries by">
<button class="view-btn" type="button" data-view-mode="module" aria-pressed="true">By Module</button>
<button class="view-btn" type="button" data-view-mode="platform" aria-pressed="false">By Platform</button>
</div>
</div>
<div class="controls-search">
<div class="filter">
<label class="visually-hidden" for="native-filter">Filter native binaries</label>
<input id="native-filter" type="search" autocomplete="off" spellcheck="false"
 placeholder="Filter by binary filename, module, package, platform, version (e.g. v1) or SHA-256">
<kbd>/</kbd>
</div>
{f'<label class="arch-toggle"><input id="native-expand-archived" type="checkbox"><span>Expand archived ({archived_total})</span></label>' if archived_total else ''}
</div>
</section>
<div class="empty-banner" data-filter-empty hidden>
<p>No native binary matches the current filter.</p>
<button class="copy" type="button" data-reset-filters>Reset filters</button>
</div>
<div id="native-module-view">
{chr(10).join(module_sections)}
</div>
<div id="native-platform-view" hidden></div>
<footer class="site-footer">
<p>Every binary under <code>/native/&lt;package&gt;/&lt;version&gt;/</code> is immutable and SHA-256 verified before loading.
Older versions stay hosted under <em>Archived versions</em> so existing ELPA releases whose <code>native/manifest.json</code> pins them never break.</p>
<p>Generated deterministically from <a href="manifest.json">manifest.json</a> on every native release.</p>
</footer>
</main>"""
    mod_noun = "MODULE" if len(module_names) == 1 else "MODULES"
    bin_noun = "BINARY" if len(artifacts) == 1 else "BINARIES"
    native_og_hash = og_cards.render_card(
        og_cards.CardSpec(
            title="Prebuilt native modules",
            subtitle="Checksum-verified prebuilt Emacs dynamic modules for ETAF packages (macOS, Linux, Windows).",
            url_label="etaf.top/native",
            footer_left="NATIVE DYNAMIC MODULES",
            footer_right=f"{len(module_names)} {mod_noun} · {len(artifacts)} {bin_noun}",
            lang="en",
        ),
        native_dir / "og.png",
    )
    (native_dir / "index.html").write_text(page(
        "ETAF prebuilt native modules", body, "",
        canonical="https://etaf.top/native/",
        description="Checksum-verified prebuilt Emacs dynamic modules for ETAF packages (macOS, Linux, Windows).",
        og_image=f"https://etaf.top/native/og.png?v={native_og_hash}",
        og_image_alt="ETAF prebuilt native modules",
        extra_style=NATIVE_STYLE,
        script=NATIVE_SCRIPT),
        encoding="utf-8")
    return {
        "packages": packages_count,
        "modules": len(module_names),
        "artifacts": len(artifacts),
        "current": current_total,
        "archived": archived_total,
    }


MEDIA_STYLE = NATIVE_STYLE + """
.media-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr));
  gap: 1rem; padding: 1.15rem; }
.media-card { display: flex; flex-direction: column; border: 1px solid var(--rule);
  border-radius: 3px; background: var(--paper-2); overflow: hidden; }
.media-card:hover { border-color: var(--rule-strong); }
.media-thumb-link { display: flex; align-items: center; justify-content: center;
  aspect-ratio: 16 / 10; background: var(--paper-3); border-bottom: 1px solid var(--rule);
  overflow: hidden; text-decoration: none; }
.media-thumb-link img { width: 100%; height: 100%; object-fit: cover; display: block;
  transition: transform .18s ease; }
.media-thumb-link:hover img { transform: scale(1.02); }
.media-thumb-badge { font-family: var(--font-mono); font-size: .82rem; font-weight: 600;
  color: var(--ink-2); padding: .35rem .7rem; border: 1px solid var(--rule-strong);
  border-radius: 3px; background: var(--paper); }
.media-meta { padding: .75rem .85rem .85rem; display: flex; flex-direction: column; gap: .45rem;
  flex: 1 1 auto; }
.media-name { font-family: var(--font-mono); font-size: .78rem; font-weight: 600; color: var(--ink);
  text-decoration: none; overflow-wrap: anywhere; }
.media-name:hover { color: var(--accent); text-decoration: underline; }
.media-facts { display: flex; flex-wrap: wrap; align-items: center; gap: .35rem .55rem;
  font-family: var(--font-mono); font-size: .7rem; color: var(--ink-3); }
.media-actions { margin-top: auto; padding-top: .35rem; display: flex; flex-wrap: wrap; gap: .4rem; }
@media (max-width: 760px) {
  .media-grid { grid-template-columns: 1fr; padding: .85rem; }
}
"""

MEDIA_SCRIPT = """
(() => {
  const controls = document.querySelector('[data-media-controls]');
  const filterInput = document.getElementById('media-filter');
  const emptyBanner = document.querySelector('[data-media-empty]');
  const sections = Array.from(document.querySelectorAll('section.mod-card[data-namespace]'));
  if (controls) controls.hidden = false;

  const state = { namespace: 'all', query: '' };

  const apply = () => {
    const terms = state.query.trim().toLowerCase().split(/\\s+/).filter(Boolean);
    let visibleTotal = 0;
    for (const sec of sections) {
      const ns = sec.dataset.namespace;
      const cards = Array.from(sec.querySelectorAll('[data-media-path]'));
      let nsVisible = 0;
      const nsOk = state.namespace === 'all' || ns === state.namespace;
      for (const card of cards) {
        const hay = card.dataset.search || '';
        const show = nsOk && (!terms.length || terms.every((t) => hay.includes(t)));
        card.hidden = !show;
        if (show) nsVisible += 1;
      }
      sec.hidden = nsVisible === 0;
      const badge = sec.querySelector('[data-ns-count]');
      if (badge) {
        badge.textContent = nsVisible === cards.length
          ? `${cards.length} ${cards.length === 1 ? 'asset' : 'assets'}`
          : `${nsVisible} of ${cards.length}`;
      }
      visibleTotal += nsVisible;
    }
    if (emptyBanner) emptyBanner.hidden = visibleTotal > 0;
    document.querySelectorAll('[data-ns-tab]').forEach((btn) => {
      btn.setAttribute('aria-selected', btn.dataset.nsTab === state.namespace ? 'true' : 'false');
    });
  };

  document.addEventListener('click', (event) => {
    const tab = event.target.closest('[data-ns-tab]');
    if (tab) {
      state.namespace = tab.dataset.nsTab || 'all';
      apply();
      return;
    }
    if (event.target.closest('[data-reset-media]')) {
      state.namespace = 'all';
      state.query = '';
      if (filterInput) filterInput.value = '';
      apply();
      return;
    }
    const copyBtn = event.target.closest('[data-copy-text]');
    if (copyBtn) {
      const text = copyBtn.dataset.copyText || '';
      const orig = copyBtn.textContent;
      const finish = () => {
        copyBtn.textContent = 'Copied';
        copyBtn.classList.add('done');
        setTimeout(() => { copyBtn.textContent = orig; copyBtn.classList.remove('done'); }, 1500);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(finish, finish);
      } else {
        finish();
      }
    }
  });

  if (filterInput) {
    filterInput.addEventListener('input', () => {
      state.query = filterInput.value;
      apply();
    });
  }
  document.addEventListener('keydown', (event) => {
    if (event.key === '/' && document.activeElement !== filterInput
        && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      if (filterInput) filterInput.focus();
    }
  });
  apply();
})();
"""


def _format_bytes(size):
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.2f} MB"
    if size >= 1024:
        return f"{size / 1024:.1f} KB"
    return f"{size} B"


def media_pages(media_dir, manifest=None):
    """Write a browsable, data-driven index.html gallery for https://etaf.top/media/."""
    if manifest is None:
        manifest = json.loads((media_dir / "manifest.json").read_text(encoding="utf-8"))
    assets = sorted(manifest.get("assets", []), key=lambda item: item["path"])

    by_ns = {}
    for item in assets:
        by_ns.setdefault(item["namespace"], []).append(item)

    namespaces = sorted(by_ns, key=lambda n: (0 if n == "site" else 1, n))
    total_bytes = sum(int(item.get("size", 0)) for item in assets)
    img_exts = {".webp", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".avif"}

    ns_tabs = [
        f'<button class="plat-tab" type="button" role="tab" aria-selected="true" data-ns-tab="all">'
        f'<span>All</span><span class="cnt">{len(assets)}</span></button>'
    ]
    sections = []
    for ns in namespaces:
        items = by_ns[ns]
        safe_ns = html.escape(ns)
        ns_bytes = sum(int(i.get("size", 0)) for i in items)
        ns_tabs.append(
            f'<button class="plat-tab" type="button" role="tab" aria-selected="false"'
            f' data-ns-tab="{html.escape(ns, quote=True)}">'
            f'<span>{safe_ns}</span><span class="cnt">{len(items)}</span></button>'
        )
        pkg_link = (
            f'<a class="pill pkg-link" href="../packages/{safe_ns}/">package: {safe_ns} ↗</a>'
            if ns != "site" else '<span class="pill current">website assets</span>'
        )
        cards = []
        for item in items:
            rel = item["path"]
            safe_rel = html.escape(rel, quote=True)
            name = rel.split("/", 1)[1] if "/" in rel else rel
            safe_name = html.escape(name)
            ext = Path(rel).suffix.lower()
            fmt = html.escape(ext.lstrip(".").upper() or "FILE")
            size_str = html.escape(_format_bytes(int(item.get("size", 0))))
            sha_short = html.escape(str(item.get("sha256", ""))[:12])
            full_url = f"https://etaf.top/media/{rel}"
            stem = Path(name).stem
            md_snippet = f"![{stem}]({full_url})"
            search_hay = html.escape(f"{ns} {rel} {ext} {sha_short}".lower(), quote=True)
            if ext in img_exts:
                thumb = f'<img src="{safe_rel}" alt="{safe_name}" loading="lazy">'
            else:
                thumb = f'<span class="media-thumb-badge">{fmt}</span>'
            cards.append(
                f'<article class="media-card" data-media-path="{safe_rel}" data-search="{search_hay}">'
                f'<a class="media-thumb-link" href="{safe_rel}" target="_blank" rel="noopener">{thumb}</a>'
                f'<div class="media-meta">'
                f'<a class="media-name" href="{safe_rel}" target="_blank" rel="noopener">{safe_name}</a>'
                f'<div class="media-facts">'
                f'<span class="pill">{fmt}</span>'
                f'<span>{size_str}</span>'
                f'<span title="{html.escape(str(item.get("sha256", "")), quote=True)}">{sha_short}</span>'
                f'</div>'
                f'<div class="media-actions">'
                f'<button class="copy-mini" type="button" data-copy-text="{html.escape(full_url, quote=True)}">Copy URL</button>'
                f'<button class="copy-mini" type="button" data-copy-text="{html.escape(md_snippet, quote=True)}">Copy MD</button>'
                f'</div>'
                f'</div></article>'
            )
        noun = "asset" if len(items) == 1 else "assets"
        sections.append(f"""<section class="mod-card" id="ns-{safe_ns}" data-namespace="{html.escape(ns, quote=True)}">
<div class="mod-head">
<div class="mod-head-top">
<div class="mod-title-group">
<h2>{safe_ns}</h2>
{pkg_link}
<span class="pill">{html.escape(_format_bytes(ns_bytes))}</span>
</div>
<span class="tag" data-ns-count>{len(items)} {noun}</span>
</div>
</div>
<div class="media-grid">
{chr(10).join(cards)}
</div>
</section>""")

    body = f"""<main class="wrap">
<nav class="crumbs" aria-label="Breadcrumb"><a href="/">ETAF</a>
<span aria-hidden="true">/</span><a href="/packages/">Packages</a>
<span aria-hidden="true">/</span><span>Media</span></nav>
<section class="native-hero">
<div class="native-hero-grid">
<div class="native-hero-copy">
<p class="eyebrow">Hosted documentation &amp; showcase assets</p>
<h1>ETAF media library</h1>
<p class="lead">Checksum-verified showcase screenshots, OpenGraph cards and demo media for the ETAF
ecosystem. Hosted externally so Git repositories stay lean; publish new assets with
<code>python3 scripts/media-publish.py publish</code>. Machine-readable index:
<a href="manifest.json">manifest.json</a>.</p>
</div>
<div class="native-kpis" aria-label="Summary counts">
<div class="kpi"><span class="kpi-label">Namespaces</span><span class="kpi-val">{len(namespaces)}</span></div>
<div class="kpi"><span class="kpi-label">Assets</span><span class="kpi-val">{len(assets)}</span></div>
<div class="kpi"><span class="kpi-label">Total size</span><span class="kpi-val">{html.escape(_format_bytes(total_bytes))}</span></div>
</div>
</div>
</section>
<section class="controls-bar" data-media-controls hidden aria-label="Filter media assets">
<div class="controls-top">
<div class="plat-tabs" role="tablist" aria-label="Filter by namespace">
{"".join(ns_tabs)}
</div>
</div>
<div class="controls-search">
<div class="filter">
<label class="visually-hidden" for="media-filter">Filter media assets</label>
<input id="media-filter" type="search" autocomplete="off" spellcheck="false"
 placeholder="Filter by package, filename, format (webp, png) or SHA-256">
<kbd>/</kbd>
</div>
</div>
</section>
<div class="empty-banner" data-media-empty hidden>
<p>No media asset matches the current filter.</p>
<button class="copy" type="button" data-reset-media>Reset filters</button>
</div>
{chr(10).join(sections)}
<footer class="site-footer">
<p>Generated deterministically from <a href="manifest.json">manifest.json</a> on every media publication.</p>
</footer>
</main>"""
    ns_noun = "NAMESPACE" if len(namespaces) == 1 else "NAMESPACES"
    asset_noun = "ASSET" if len(assets) == 1 else "ASSETS"
    media_og_hash = og_cards.render_card(
        og_cards.CardSpec(
            title="Media library",
            subtitle="Checksum-verified showcase screenshots, OpenGraph cards and demo assets for the ETAF ecosystem.",
            url_label="etaf.top/media",
            footer_left="HOSTED MEDIA ASSETS",
            footer_right=f"{len(namespaces)} {ns_noun} · {len(assets)} {asset_noun}",
            lang="en",
        ),
        media_dir / "og.png",
    )
    (media_dir / "index.html").write_text(page(
        "ETAF media library", body, "",
        canonical="https://etaf.top/media/",
        description="Hosted showcase screenshots and media assets for the Emacs TAF ecosystem.",
        og_image=f"https://etaf.top/media/og.png?v={media_og_hash}",
        og_image_alt="ETAF media library",
        extra_style=MEDIA_STYLE,
        script=MEDIA_SCRIPT),
        encoding="utf-8")
    return {
        "namespaces": len(namespaces),
        "assets": len(assets),
        "bytes": total_bytes,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command")
    write_parser = command.add_parser("write", help="Write archive pages from a package directory")
    write_parser.add_argument("--directory", type=Path, required=True)
    native_parser = command.add_parser("write-native", help="Write native binary index page from a native directory")
    native_parser.add_argument("--directory", type=Path, required=True)
    media_parser = command.add_parser("write-media", help="Write media gallery index page from a media directory")
    media_parser.add_argument("--directory", type=Path, required=True)
    args_list = sys.argv[1:]
    if not args_list or args_list == ["help"]:
        parser.print_help()
        return 0
    if args_list[0] == "help":
        args_list = [*args_list[1:], "--help"]
    args = parser.parse_args(args_list)
    directory = args.directory.resolve()
    if args.command == "write-native":
        report = native_pages(directory)
    elif args.command == "write-media":
        report = media_pages(directory)
    else:
        report = archive_pages(directory)
    print(json.dumps({"directory": str(directory), **report}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        print(f"error=pages\nhint={error}", file=sys.stderr)
        sys.exit(1)
