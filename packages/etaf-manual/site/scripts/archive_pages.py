#!/usr/bin/env python3
"""Write the browsable archive pages from a verifiable package archive.

The pages describe what the archive actually serves, so they cannot drift from
the download bytes: `manifest.json` supplies versions, requirements, provenance
and each package's newest-change date, and every tarball is read for its size,
file count and newest changelog entries. No checkout, network access or release
workspace is involved, which is what lets a published archive regenerate its
pages alone.

`write --directory DIR` creates `DIR/index.html` and `DIR/<name>/index.html` and
nothing else, because the deployer accepts only those files next to the indexed
tarballs. Download counts are filled from `downloads.json` by the browser; the
markup keeps its placeholder so the archive still reads without JavaScript.
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

MONTHS = ("January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December")

# The archive records commit dates in strict ISO 8601, so a rendered page never
# has to guess a time zone or re-derive a date from an ambiguous string.
STAMP = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[+-][0-9]{2}:[0-9]{2}|Z)\Z")

REPOSITORIES = {"etaf-install": "emacs-taf/emacs-taf"}

# Where the page files each package this project publishes.  A new archive
# package must be placed here: the writer refuses to publish pages while a
# package is left over, because a silent "Other" section hides the omission
# from readers.  A package another author publishes states its own group.
GROUPS = (
    ("Framework", {"etaf-install", "etaf-ui", "etaf", "ebox", "ecss", "ekp", "etaf-db",
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
  let stored = null;
  try { stored = localStorage.getItem('starlight-theme'); } catch (error) {}
  const systemDark = matchMedia('(prefers-color-scheme: dark)').matches;
  root.dataset.theme = stored === 'light' || stored === 'dark' ? stored
    : systemDark ? 'dark' : 'light';
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
:root[data-theme="dark"] body {
  background-color: var(--paper);
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.055'/%3E%3C/svg%3E");
  background-size: 160px 160px;
}
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; background: var(--paper); color: var(--ink);
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
:root[data-theme="dark"] .theme .sun { display: block; }
:root[data-theme="light"] .theme .moon { display: block; }
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


def page(title, body, downloads="downloads.json", *, canonical, description):
    title = html.escape(title)
    description = html.escape(description)
    canonical = html.escape(canonical)
    return f"""<!doctype html>
<html lang="en">
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
<meta property="og:image" content="https://etaf.top/og/archive.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="ETAF package archive">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title}">
<meta name="twitter:description" content="{description}">
<meta name="twitter:image" content="https://etaf.top/og/archive.png">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>{STYLE}</style>
<script>{THEME_SCRIPT}</script>
</head>
<body data-downloads-url="{downloads}">
{HEADER}
{body}
<script>{PAGE_SCRIPT}</script>
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


def groups(packages, community={}):
    """Split packages into the published roles, keeping any unknown name visible.

    A package another author publishes through this archive is never filed
    under our own applications: the section states who maintains it.
    """
    placed, result = set(), []
    def declared_group(item):
        # Only a package the archive redistributes for another author has a
        # declared group; ours are grouped by the sections alone, or every
        # package would match the default.
        record = community.get(item["name"])
        return None if record is None else record.get("group", "application")

    for label, members in GROUPS:
        key = label.lower().rstrip("s")
        selected = [item for item in packages
                    if item["name"] in members or declared_group(item) == key]
        placed.update(item["name"] for item in selected)
        if selected:
            result.append((label, selected))
    other = [item for item in packages if item["name"] not in placed]
    if other:
        result.append(("Other", other))
    return result


def unplaced(packages, community={}):
    """Name the packages no section claims.

    The page files them under Other so a reader sees the omission; the
    publisher refuses to deploy them, because a nameless section is a mistake,
    not a category.
    """
    claimed = set().union(*(members for _, members in GROUPS))
    return sorted(item["name"] for item in packages
                  if item["name"] not in claimed and item["name"] not in community)


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
    dates = [day for day in (stamp_date(value) for value in updated.values()) if day]
    newest = max(dates) if dates else None
    rows_by_name = {item["name"]: item for item in packages}
    sections = []
    for label, selected in groups(packages, community):
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
    (package_dir / "index.html").write_text(page(
        "ETAF package archive", body,
        canonical="https://etaf.top/packages/",
        description="ETAF package archive: framework, extensions, applications and games for Emacs 29.1 "
                    "and newer. One package.el entry installs everything."))
    used_by = {name: [] for name in names}
    for item in packages:
        for dependency, _minimum in item["requirements"]:
            if dependency in used_by and dependency != item["name"]:
                used_by[dependency].append(item["name"])
    for item in packages:
        package_page(item, sources, updated, rows_by_name, used_by,
                     package_dir / item["name"], community.get(item["name"]))
    return {"packages": len(packages), "updated": str(newest) if newest else None,
            "unplaced": unplaced(packages, community)}


def package_page(item, sources, updated, rows_by_name, used_by, directory, origin=None):
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
    repo = home or f"https://github.com/{REPOSITORIES.get(name, f'emacs-taf/{name}')}"
    label = repo.removeprefix("https://").removeprefix("http://")
    community = bool(origin)
    revision = sources.get(name, "")
    facts = inspect_archive(directory.parent / item["file"])
    day = stamp_date(updated.get(name))
    source_line = (
        f'<a href="{html.escape(repo)}/commit/{revision}"><code>{html.escape(revision[:12])}</code></a>'
        if revision else "not recorded")
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
    changelog_url = f"{repo}/blob/{revision}/CHANGELOG.md" if revision else ""
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
    target.write_text(page(
        f"{source_name(item, origin)} — ETAF package archive", body, "../downloads.json",
        canonical=f"https://etaf.top/packages/{name}/",
        description=item.get("summary", "")))


NATIVE_DESCRIPTIONS = {
    "etaf-md": "Embedded QuickJS renderer for Mermaid diagrams and MathJax display formulas (CoreText on macOS, runtime dlopen Pango on Linux).",
    "etaf": "Cross-platform libmpv dynamic module for hardware-accelerated native video playback in ETAF buffers.",
    "ekp": "Multi-threaded C Knuth–Plass line-breaking engine for high-throughput paragraph layout.",
}


def format_bytes(size):
    """Return a concise human-readable byte size string."""
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.2f} MB"
    return f"{max(1, round(size / 1024))} KB"


def native_pages(native_dir):
    """Write a browsable index.html for the hosted prebuilt native modules."""
    manifest = json.loads((native_dir / "manifest.json").read_text(encoding="utf-8"))
    artifacts = sorted(manifest.get("artifacts", []),
                       key=lambda item: (item["package"], item["module"], item["version"], item["platform"]))
    by_package = {}
    for item in artifacts:
        by_package.setdefault(item["package"], []).append(item)
    platforms = sorted({item["platform"] for item in artifacts})
    sections = []
    for pkg in sorted(by_package):
        items = by_package[pkg]
        safe_pkg = html.escape(pkg)
        desc = html.escape(NATIVE_DESCRIPTIONS.get(pkg, f"Prebuilt native dynamic module(s) for {pkg}."))
        rows = []
        for item in items:
            plat = html.escape(item["platform"])
            mod = html.escape(item["module"])
            ver = html.escape(item["version"])
            path = html.escape(item["path"])
            filename = html.escape(Path(item["path"]).name)
            sha = html.escape(item["sha256"])
            size = html.escape(format_bytes(item["size"]))
            search = html.escape(f"{pkg} {item['module']} {item['platform']} {filename}".lower())
            rows.append(
                f'<tr data-search="{search}">'
                f'<td class="pkg"><a href="{path}"><strong>{plat}</strong></a>'
                f'<span class="summary"><code>{filename}</code></span></td>'
                f'<td class="version-cell"><span class="version">{mod} v{ver}</span></td>'
                f'<td class="num">{size}</td>'
                f'<td class="requires"><code title="{sha}">{sha[:16]}…{sha[-8:]}</code></td>'
                f'<td class="src"><a class="tar-link" href="{path}" title="Download {filename}" '
                f'aria-label="Download {filename}">{TAR_ICON}</a></td>'
                "</tr>")
        sections.append(f"""<section class="group" id="{safe_pkg}">
<div class="group-head"><h2><a href="../packages/{safe_pkg}/">{safe_pkg}</a></h2>
<span class="tag" data-count="{len(items)}">{len(items)} artifacts</span></div>
<p class="note">{desc}</p>
<table>
<thead><tr><th scope="col">Platform</th><th scope="col">Module</th>
<th scope="col" class="num">Size</th><th scope="col" class="requires">SHA-256</th>
<th scope="col" class="src"><span class="visually-hidden">Download</span></th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody>
</table>
</section>""")
    body = f"""<main class="wrap">
<nav class="crumbs" aria-label="Breadcrumb"><a href="/">ETAF</a>
<span aria-hidden="true">/</span><a href="/packages/">Packages</a>
<span aria-hidden="true">/</span><span>Native modules</span></nav>
<section class="hero">
<p class="eyebrow">Prebuilt Emacs dynamic modules</p>
<h1>ETAF native binaries</h1>
<p class="lead">Checksum-verified prebuilt C dynamic modules for ETAF packages.
<code>M-x etaf-install</code> downloads, verifies (SHA-256) and activates the matching binary automatically
into <code>~/.cache/emacs-taf/native/</code> — no C compiler, Make or manual build required.</p>
<p class="meta"><span><strong>{len(by_package)}</strong> packages</span>
<span class="dot" aria-hidden="true">·</span>
<span><strong>{len(artifacts)}</strong> binaries</span>
<span class="dot" aria-hidden="true">·</span>
<span>{len(platforms)} platforms ({html.escape(", ".join(platforms))})</span>
<span class="dot" aria-hidden="true">·</span>
<span>Emacs 29.1+ ABI</span></p>
</section>
<section class="install" aria-labelledby="install-title">
<div class="install-head"><h2 id="install-title">Automatic installation</h2>
<button class="copy" type="button" data-copy="#bootstrap">Copy</button></div>
<pre id="bootstrap"><code>{BOOTSTRAP}</code></pre>
<p class="note">Selecting a target such as <code>etaf-md</code>, <code>etaf-video-player</code>,
<code>etaf</code> or <code>ekp</code> in <code>M-x etaf-install</code> automatically installs matching
native binaries for the target and its dependencies. You can also run <code>M-x etaf-install-native</code>
(or press <code>n</code> in <code>M-x etaf-install-manage</code>) at any time, or inspect
<a href="manifest.json"><code>manifest.json</code></a> for the full machine-readable index.</p>
</section>
<div class="filter" data-filter-box hidden>
<label class="visually-hidden" for="native-filter">Filter native artifacts</label>
<input id="native-filter" type="search" data-filter autocomplete="off" spellcheck="false"
 placeholder="Filter by package, module or platform (e.g. darwin-arm64, linux-x86_64)">
<kbd>/</kbd>
</div>
<p class="note" data-filter-empty hidden>No native artifact matches that filter.</p>
{chr(10).join(sections)}
<footer class="site-footer">
<p>This page is generated from <a href="manifest.json">manifest.json</a> on every native release.
Every binary is immutable under its versioned path and verified by SHA-256 before loading.</p>
</footer>
</main>"""
    (native_dir / "index.html").write_text(page(
        "ETAF prebuilt native modules", body, "",
        canonical="https://etaf.top/native/",
        description="Checksum-verified prebuilt Emacs dynamic modules for ETAF packages (macOS, Linux, Windows)."),
        encoding="utf-8")
    return {"packages": len(by_package), "artifacts": len(artifacts)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    command = parser.add_subparsers(dest="command")
    write_parser = command.add_parser("write", help="Write archive pages from a package directory")
    write_parser.add_argument("--directory", type=Path, required=True)
    args_list = sys.argv[1:]
    if not args_list or args_list == ["help"]:
        parser.print_help()
        return 0
    if args_list[0] == "help":
        args_list = [*args_list[1:], "--help"]
    args = parser.parse_args(args_list)
    directory = args.directory.resolve()
    report = archive_pages(directory)
    print(json.dumps({"directory": str(directory), **report}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        print(f"error=pages\nhint={error}", file=sys.stderr)
        sys.exit(1)
