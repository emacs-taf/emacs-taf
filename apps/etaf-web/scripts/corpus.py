#!/usr/bin/env python3
"""Multi-archetype benchmark, golden-corpus regression harness, and cache auditor for etaf-web.

Subcommands:
  check-fixtures     Verify universal render-quality invariants across tests/fixtures/.
  add SLUG URL       Freeze a real webpage (live fetch, --from-cache, or --file) into
                     the local golden corpus (~/.cache/etaf-web/golden-corpus/).
  diff               Recompile every golden-corpus page, run universal invariants, and
                     report UNCHANGED / CHANGED / REGRESSED against baseline.md.
  update [SLUG ...]  Accept current compiled output as the new baseline.md.
  audit-cache        Audit cached pages in ~/.cache/etaf-web/pages/ and rank systemic
                     rendering anomalies (giant links, glued text, chrome leaks, etc.).
  benchmark          Fetch/reuse a 79-site multi-archetype web matrix spanning
                     mainstream news media (BBC, Guardian, Ars Technica, The Verge,
                     TechCrunch, Wired, Slashdot, Nature), Chinese tech/communities
                     (SSPai, ITHome, Cnblogs, OSChina, Ifanr, Douban, V2EX, Ruanyifeng),
                     developer/AI hubs (GitHub README/Trending/Releases, Hugging Face,
                     PyPI, DEV.to, Rust Users Discourse), 16+ docs frameworks (React,
                     Next.js, Vue, Svelte, TypeScript, Bun, Deno, Kubernetes, Docker,
                     Stripe, Starlight, VitePress, Docusaurus, Nextra, Astro, Cloudflare,
                     Sphinx, RTD, mdBook, MkDocs, Rustdoc, Go Docs, Texinfo), specs,
                     arXiv MathML papers, wikis, search (DuckDuckGo), blogs & landing
                     pages; evaluate routing + compilation + universal quality invariants.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import difflib
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CACHE_DIR = Path.home() / ".cache" / "etaf-web" / "pages"
DEFAULT_CORPUS_DIR = Path.home() / ".cache" / "etaf-web" / "golden-corpus"
DEFAULT_BENCH_DIR = Path.home() / ".cache" / "etaf-web" / "benchmark-corpus"
USER_AGENT = "etaf-web/0.1 (Emacs; +https://etaf.top)"

MAX_SAFE_LINK_LABEL = 240

# Diverse real-world web architecture matrix spanning 12+ frameworks & page archetypes.
BENCHMARK_SITES: list[dict[str, str]] = [
    {
        "slug": "claude-bp-home",
        "archetype": "landing-cards",
        "url": "https://claude-best-practices-zh.vercel.app/",
        "expect_route": "t1",
    },
    {
        "slug": "claude-bp-wiki",
        "archetype": "docs-custom",
        "url": "https://claude-best-practices-zh.vercel.app/wiki/INDEX.html",
        "expect_route": "t2:docs",
    },
    {
        "slug": "etaf-views",
        "archetype": "docs-starlight",
        "url": "https://etaf.top/views/",
        "expect_route": "t2:docs",
    },
    {
        "slug": "vitepress-guide",
        "archetype": "docs-vitepress",
        "url": "https://vitepress.dev/guide/what-is-vitepress",
        "expect_route": "t2:docs",
    },
    {
        "slug": "docusaurus-intro",
        "archetype": "docs-docusaurus",
        "url": "https://docusaurus.io/docs",
        "expect_route": "t2:docs",
    },
    {
        "slug": "python-json",
        "archetype": "docs-sphinx",
        "url": "https://docs.python.org/3/library/json.html",
        "expect_route": "t2:docs",
    },
    {
        "slug": "rust-book",
        "archetype": "docs-mdbook",
        "url": "https://doc.rust-lang.org/book/ch01-01-installation.html",
        "expect_route": "t1",
    },
    {
        "slug": "mkdocs-material",
        "archetype": "docs-mkdocs",
        "url": "https://squidfunk.github.io/mkdocs-material/getting-started/",
        "expect_route": "t2:docs",
    },
    {
        "slug": "w3c-box4",
        "archetype": "spec-w3c",
        "url": "https://www.w3.org/TR/css-box-4/",
        "expect_route": "t1",
    },
    {
        "slug": "mdn-box-model",
        "archetype": "ref-mdn",
        "url": "https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_box_model/Introduction_to_the_CSS_box_model",
        "expect_route": "t2:docs",
    },
    {
        "slug": "wiki-emacs",
        "archetype": "wiki-mediawiki",
        "url": "https://en.wikipedia.org/wiki/Emacs",
        "expect_route": "t1",
    },
    {
        "slug": "hacker-news",
        "archetype": "news-table",
        "url": "https://news.ycombinator.com/",
        "expect_route": "t1",
    },
    {
        "slug": "lobsters",
        "archetype": "news-semantic",
        "url": "https://lobste.rs/",
        "expect_route": "t1",
    },
    {
        "slug": "paul-graham",
        "archetype": "essay-table",
        "url": "https://paulgraham.com/read.html",
        "expect_route": "t1",
    },
    {
        "slug": "github-ripgrep",
        "archetype": "code-github",
        "url": "https://github.com/BurntSushi/ripgrep",
        "expect_route": "t1",
    },
    {
        "slug": "anthropic-agents",
        "archetype": "editorial-modern",
        "url": "https://www.anthropic.com/engineering/building-effective-agents",
        "expect_route": "t1",
    },
    {
        "slug": "ruanyifeng-weekly",
        "archetype": "blog-zh",
        "url": "https://www.ruanyifeng.com/blog/2024/05/weekly-issue-300.html",
        "expect_route": "t1",
    },
    {
        "slug": "astro-docs",
        "archetype": "docs-astro",
        "url": "https://docs.astro.build/en/getting-started/",
        "expect_route": "t2:docs",
    },
    {
        "slug": "cf-workers",
        "archetype": "docs-cloudflare",
        "url": "https://developers.cloudflare.com/workers/",
        "expect_route": "t2:docs",
    },
    {
        "slug": "pytest-docs",
        "archetype": "docs-sphinx-rtd",
        "url": "https://docs.pytest.org/en/stable/getting-started.html",
        "expect_route": "t2:docs",
    },
    {
        "slug": "nextra-docs",
        "archetype": "docs-nextra",
        "url": "https://nextra.site/docs",
        "expect_route": "t2:docs",
    },
    {
        "slug": "rust-vec",
        "archetype": "docs-rustdoc",
        "url": "https://doc.rust-lang.org/std/vec/struct.Vec.html",
        "expect_route": "t1",
    },
    {
        "slug": "go-effective",
        "archetype": "docs-godoc",
        "url": "https://go.dev/doc/effective_go",
        "expect_route": "t2:docs",
    },
    {
        "slug": "gnu-elisp",
        "archetype": "docs-texinfo",
        "url": "https://www.gnu.org/software/emacs/manual/html_node/elisp/Lists.html",
        "expect_route": "t1",
    },
    {
        "slug": "arch-emacs",
        "archetype": "wiki-arch",
        "url": "https://wiki.archlinux.org/title/Emacs",
        "expect_route": "t1",
    },
    {
        "slug": "zhwiki-emacs",
        "archetype": "wiki-zh",
        "url": "https://zh.wikipedia.org/wiki/Emacs",
        "expect_route": "t1",
    },
    {
        "slug": "rfc-9110",
        "archetype": "spec-rfc",
        "url": "https://www.rfc-editor.org/rfc/rfc9110.html",
        "expect_route": "t1",
    },
    {
        "slug": "arxiv-attention",
        "archetype": "paper-arxiv",
        "url": "https://arxiv.org/html/1706.03762v7",
        "expect_route": "t1",
    },
    {
        "slug": "pypi-requests",
        "archetype": "pkg-pypi",
        "url": "https://pypi.org/project/requests/",
        "expect_route": "t1",
    },
    {
        "slug": "hn-item",
        "archetype": "news-hn-thread",
        "url": "https://news.ycombinator.com/item?id=8863",
        "expect_route": "t1",
    },
    {
        "slug": "lwn-front",
        "archetype": "news-lwn",
        "url": "https://lwn.net/",
        "expect_route": "t1",
    },
    {
        "slug": "martin-fowler",
        "archetype": "blog-fowler",
        "url": "https://martinfowler.com/articles/microservices.html",
        "expect_route": "t1",
    },
    {
        "slug": "julia-evans",
        "archetype": "blog-jvns",
        "url": "https://jvns.ca/blog/2023/11/01/confusing-git-terminology/",
        "expect_route": "t1",
    },
    {
        "slug": "simon-willison",
        "archetype": "blog-simon",
        "url": "https://simonwillison.net/",
        "expect_route": "t1",
    },
    {
        "slug": "ziglang-home",
        "archetype": "landing-zig",
        "url": "https://ziglang.org/",
        "expect_route": "t1",
    },
    {
        "slug": "sqlite-home",
        "archetype": "landing-sqlite",
        "url": "https://sqlite.org/index.html",
        "expect_route": "t1",
    },
    {
        "slug": "tailwind-home",
        "archetype": "landing-tailwind",
        "url": "https://tailwindcss.com/",
        "expect_route": "t1",
    },
    {
        "slug": "v2ex-hot",
        "archetype": "forum-v2ex",
        "url": "https://www.v2ex.com/?tab=tech",
        "expect_route": "t1",
    },
    # Wave 2: Mainstream news media, Chinese popular portals & communities,
    # developer/AI hubs, modern framework docs, search & reference portals.
    {
        "slug": "bbc-news",
        "archetype": "news-bbc",
        "url": "https://www.bbc.com/news",
        "expect_route": "t1",
    },
    {
        "slug": "guardian-tech",
        "archetype": "news-guardian",
        "url": "https://www.theguardian.com/uk/technology",
        "expect_route": "t1",
    },
    {
        "slug": "arstechnica",
        "archetype": "news-ars",
        "url": "https://arstechnica.com/",
        "expect_route": "t1",
    },
    {
        "slug": "theverge",
        "archetype": "news-verge",
        "url": "https://www.theverge.com/",
        "expect_route": "t1",
    },
    {
        "slug": "techcrunch",
        "archetype": "news-tc",
        "url": "https://techcrunch.com/",
        "expect_route": "t1",
    },
    {
        "slug": "wired",
        "archetype": "news-wired",
        "url": "https://www.wired.com/",
        "expect_route": "t1",
    },
    {
        "slug": "slashdot",
        "archetype": "news-slashdot",
        "url": "https://slashdot.org/",
        "expect_route": "t1",
    },
    {
        "slug": "nature-news",
        "archetype": "news-nature",
        "url": "https://www.nature.com/news",
        "expect_route": "t1",
    },
    {
        "slug": "sspai",
        "archetype": "cn-sspai",
        "url": "https://sspai.com/",
        "expect_route": "t1",
    },
    {
        "slug": "ithome",
        "archetype": "cn-ithome",
        "url": "https://www.ithome.com/",
        "expect_route": "t1",
    },
    {
        "slug": "cnblogs",
        "archetype": "cn-cnblogs",
        "url": "https://www.cnblogs.com/",
        "expect_route": "t1",
    },
    {
        "slug": "oschina",
        "archetype": "cn-oschina",
        "url": "https://www.oschina.net/news",
        "expect_route": "t1",
    },
    {
        "slug": "ifanr",
        "archetype": "cn-ifanr",
        "url": "https://www.ifanr.com/",
        "expect_route": "t1",
    },
    {
        "slug": "douban-top250",
        "archetype": "cn-douban",
        "url": "https://movie.douban.com/top250",
        "expect_route": "t1",
    },
    {
        "slug": "v2ex-topic",
        "archetype": "forum-v2ex-post",
        "url": "https://www.v2ex.com/t/1000000",
        "expect_route": "t1",
    },
    {
        "slug": "gh-trending",
        "archetype": "code-gh-trend",
        "url": "https://github.com/trending",
        "expect_route": "t1",
    },
    {
        "slug": "gh-releases",
        "archetype": "code-gh-rel",
        "url": "https://github.com/BurntSushi/ripgrep/releases",
        "expect_route": "t1",
    },
    {
        "slug": "hf-papers",
        "archetype": "ai-hf-papers",
        "url": "https://huggingface.co/papers",
        "expect_route": "t1",
    },
    {
        "slug": "hf-model",
        "archetype": "ai-hf-model",
        "url": "https://huggingface.co/deepseek-ai/DeepSeek-R1",
        "expect_route": "t1",
    },
    {
        "slug": "devto-home",
        "archetype": "blog-devto",
        "url": "https://dev.to/",
        "expect_route": "t1",
    },
    {
        "slug": "rust-users",
        "archetype": "forum-discourse",
        "url": "https://users.rust-lang.org/",
        "expect_route": "t2:discourse",
    },
    {
        "slug": "react-docs",
        "archetype": "docs-react",
        "url": "https://react.dev/learn",
        "expect_route": "t2:docs",
    },
    {
        "slug": "nextjs-docs",
        "archetype": "docs-nextjs",
        "url": "https://nextjs.org/docs",
        "expect_route": "t2:docs",
    },
    {
        "slug": "vuejs-docs",
        "archetype": "docs-vue",
        "url": "https://vuejs.org/guide/introduction.html",
        "expect_route": "t2:docs",
    },
    {
        "slug": "svelte-docs",
        "archetype": "docs-svelte",
        "url": "https://svelte.dev/docs/svelte/overview",
        "expect_route": "t2:docs",
    },
    {
        "slug": "ts-handbook",
        "archetype": "docs-ts",
        "url": "https://www.typescriptlang.org/docs/handbook/intro.html",
        "expect_route": "t2:docs",
    },
    {
        "slug": "bun-docs",
        "archetype": "docs-bun",
        "url": "https://bun.sh/docs",
        "expect_route": "t2:docs",
    },
    {
        "slug": "deno-docs",
        "archetype": "docs-deno",
        "url": "https://docs.deno.com/runtime/",
        "expect_route": "t2:docs",
    },
    {
        "slug": "k8s-docs",
        "archetype": "docs-k8s",
        "url": "https://kubernetes.io/docs/concepts/overview/",
        "expect_route": "t2:docs",
    },
    {
        "slug": "docker-docs",
        "archetype": "docs-docker",
        "url": "https://docs.docker.com/get-started/",
        "expect_route": "t1",
    },
    {
        "slug": "stripe-docs",
        "archetype": "docs-stripe",
        "url": "https://docs.stripe.com/api",
        "expect_route": "t1",
    },
    {
        "slug": "overreacted",
        "archetype": "blog-rsc",
        "url": "https://overreacted.io/",
        "expect_route": "t1",
    },
    {
        "slug": "danluu",
        "archetype": "blog-minimal",
        "url": "https://danluu.com/",
        "expect_route": "t1",
    },
    {
        "slug": "gwern-about",
        "archetype": "essay-gwern",
        "url": "https://gwern.net/about",
        "expect_route": "t1",
    },
    {
        "slug": "css-tricks-flex",
        "archetype": "blog-wp",
        "url": "https://css-tricks.com/snippets/css/a-guide-to-flexbox/",
        "expect_route": "t1",
    },
    {
        "slug": "smashingmag",
        "archetype": "blog-smashing",
        "url": "https://www.smashingmagazine.com/",
        "expect_route": "t1",
    },
    {
        "slug": "ddg-html",
        "archetype": "search-ddg",
        "url": "https://html.duckduckgo.com/html/?q=emacs",
        "expect_route": "t1",
    },
    {
        "slug": "caniuse-flex",
        "archetype": "ref-caniuse",
        "url": "https://caniuse.com/flexbox",
        "expect_route": "t1",
    },
    {
        "slug": "wiktionary",
        "archetype": "ref-wiktionary",
        "url": "https://en.wiktionary.org/wiki/serendipity",
        "expect_route": "t1",
    },
    {
        "slug": "openlibrary",
        "archetype": "ref-openlib",
        "url": "https://openlibrary.org/works/OL45804W",
        "expect_route": "t1",
    },
    {
        "slug": "cloudflare-blog",
        "archetype": "blog-cf",
        "url": "https://blog.cloudflare.com/",
        "expect_route": "t1",
    },
]


def find_load_paths() -> list[str]:
    provider_root = PACKAGE_ROOT.parent
    paths = [
        PACKAGE_ROOT,
        PACKAGE_ROOT / "lisp",
        provider_root / "etaf-md",
        provider_root / "etaf",
        provider_root / "etaf-ui",
        provider_root / "ebox",
        provider_root / "ecss",
        provider_root / "ekp",
    ]
    args: list[str] = []
    for p in paths:
        if p.exists():
            args.extend(["-L", str(p)])
    return args


def compile_batch(entries: list[dict], emacs: str = "emacs", with_route: bool = False) -> list[dict]:
    """Compile (and optionally inspect routing for) entries in one Emacs batch call."""
    if not entries:
        return []
    with tempfile.TemporaryDirectory(prefix="etaf-web-corpus-") as td:
        in_path = Path(td) / "jobs.json"
        out_path = Path(td) / "results.json"
        el_path = Path(td) / "run.el"
        in_path.write_text(json.dumps(entries, ensure_ascii=False), encoding="utf-8")
        el_path.write_text(
            """;;; -*- lexical-binding: t; -*-
(require 'json)
(require 'etaf-web)
(let* ((jobs (let ((json-object-type 'alist)
                   (json-array-type 'list)
                   (json-key-type 'symbol))
               (json-read-file (getenv "CORPUS_IN"))))
       (check-route (equal (getenv "CORPUS_ROUTE") "1"))
       (out nil))
  (dolist (job jobs)
    (let* ((id (alist-get 'id job))
           (html-path (alist-get 'html_path job))
           (url (alist-get 'url job))
           (err nil)
           (md nil)
           (route-str "")
           (docs-leaves 0))
      (condition-case e
          (let ((html (with-temp-buffer
                        (insert-file-contents html-path)
                        (buffer-string))))
            (setq md (etaf-web-to-markdown html :base-url url))
            (when check-route
              (let* ((res (etaf-web--route-html url nil html 'auto))
                     (tier (plist-get res :tier))
                     (adapter (plist-get res :adapter))
                     (aname (and adapter (plist-get adapter :name)))
                     (dom (plist-get res :dom)))
                (setq route-str
                      (if aname
                          (format "%s:%s" tier aname)
                        (format "%s" (or tier "t1"))))
                (when (and (eq aname 'docs) dom)
                  (let* ((sb (etaf-web-docs--find-sidebar dom url))
                         (tr (and sb (etaf-web-docs--extract-tree sb url))))
                    (setq docs-leaves (length (plist-get tr :leaves))))))))
        (error (setq err (error-message-string e))))
      (push `((id . ,id)
              (markdown . ,(or md ""))
              (route . ,route-str)
              (docs_leaves . ,docs-leaves)
              (error . ,err))
            out)))
  (with-temp-file (getenv "CORPUS_OUT")
    (insert (json-encode (nreverse out)))))
""",
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["CORPUS_IN"] = str(in_path)
        env["CORPUS_OUT"] = str(out_path)
        env["CORPUS_ROUTE"] = "1" if with_route else "0"
        cmd = [
            emacs,
            "-Q",
            "--batch",
            *find_load_paths(),
            "--eval",
            "(setq load-prefer-newer t)",
            "-l",
            str(el_path),
        ]
        proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=240)
        if proc.returncode != 0:
            raise RuntimeError(
                f"Emacs batch compile failed (exit {proc.returncode}):\n{proc.stderr}"
            )
        return json.loads(out_path.read_text(encoding="utf-8"))


def strip_front_matter(md: str) -> tuple[dict[str, str], str]:
    meta: dict[str, str] = {}
    if md.startswith("---\n"):
        end = md.find("\n---\n", 4)
        if end != -1:
            for line in md[4:end].splitlines():
                if ":" in line:
                    k, v = line.split(":", 1)
                    meta[k.strip()] = v.strip().strip('"')
            return meta, md[end + 5 :]
    return meta, md


def strip_fenced_code(body: str) -> str:
    """Remove fenced code blocks so code examples don't trigger prose checks."""
    out: list[str] = []
    in_fence = False
    fence_char = ""
    fence_len = 0
    for line in body.splitlines():
        m = re.match(r"^\s*(`{3,}|~{3,})", line)
        if not in_fence and m:
            in_fence = True
            fence_char = m.group(1)[0]
            fence_len = len(m.group(1))
            continue
        if in_fence:
            m2 = re.match(rf"^\s*{re.escape(fence_char)}{{{fence_len},}}\s*$", line)
            if m2:
                in_fence = False
            continue
        out.append(line)
    return "\n".join(out)


def strip_inline_code(text: str) -> str:
    return re.sub(r"`[^`\n]+`", "", text)


def analyze_markdown(md: str, html_bytes: int = 0) -> dict:
    """Compute structural metrics and universal render-quality invariants."""
    meta, body = strip_front_matter(md)
    prose = strip_fenced_code(body)
    prose_no_code = strip_inline_code(prose)

    # 1. Link labels (excluding image syntax `![alt](...)`).
    link_labels = [
        m.group(1)
        for m in re.finditer(r"(?<!!)\[([^\[\]\n]+)\]\(([^)\s]+)\)", prose)
    ]
    max_link_len = max((len(lbl) for lbl in link_labels), default=0)
    giant_links = [lbl[:60] for lbl in link_labels if len(lbl) > MAX_SAFE_LINK_LABEL]

    # 2. Glued text immediately following a Markdown link:
    # - adjacent links `](url)[`
    # - CJK link label glued directly to Latin/digit (`[中文](url)English`)
    # - Latin/digit link label glued directly to CJK (`[English](url)中文`)
    # - Latin link label glued directly to an uppercase/2+ letter word (`[Title](url)Subtitle`)
    glued_matches: list[str] = []
    for m in re.finditer(r"(?<!!)\[([^\[\]\n]+)\]\(([^)\s]+)\)([^\s])?", prose_no_code):
        lbl = m.group(1)
        nxt = m.group(3) or ""
        end_pos = m.end(2) + 1
        tail = prose_no_code[end_pos : end_pos + 3]
        if not nxt:
            continue
        last_ch = lbl[-1]
        is_last_cjk = bool(re.match(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]", last_ch))
        is_last_lat = bool(re.match(r"[A-Za-z0-9]", last_ch))
        if nxt == "[":
            # Allow GFM footnote reference immediately after a link: `[text](url)[^1]`.
            if not tail.startswith("[^"):
                glued_matches.append(m.group(0))
        elif is_last_cjk and re.match(r"[A-Za-z0-9]", nxt):
            glued_matches.append(m.group(0))
        elif is_last_lat and re.match(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]", nxt):
            glued_matches.append(m.group(0))
        elif is_last_lat and re.match(r"[A-Z][A-Za-z]|[a-z]{2}", tail):
            glued_matches.append(m.group(0))

    # 3. Container fence `:::` balance.
    container_depth = 0
    unbalanced_containers = False
    for line in prose.splitlines():
        s = line.strip()
        if re.match(r"^:::[a-zA-Z]", s):
            container_depth += 1
        elif s == ":::":
            container_depth -= 1
            if container_depth < 0:
                unbalanced_containers = True
    if container_depth != 0:
        unbalanced_containers = True

    # 4. Raw HTML tag leak outside code (excluding allowed bounded `<img ...>`).
    raw_html_leaks = re.findall(
        r"<(?:div|span|table|tr|td|th|script|style|iframe|form|svg)\b",
        prose_no_code,
        re.I,
    )

    # 5. Chrome / section-action boilerplate noise leaking into prose.
    chrome_hits: list[str] = []
    if re.search(r"\\\[(?:edit|编辑)\\\]|(?<!\()\[(?:edit|编辑)\](?!\()", prose_no_code):
        chrome_hits.append("edit_marker")
    if re.search(
        r"^(?:Skip to (?:main )?content|Jump to (?:content|navigation)|Toggle navigation)\s*$",
        prose_no_code,
        re.M | re.I,
    ):
        chrome_hits.append("skip_nav")

    # 6. Sparse / misclassified layout pipe tables (> 45% empty cells across >= 6 rows).
    sparse_tables = 0
    table_lines: list[str] = []
    for line in prose.splitlines() + [""]:
        if line.strip().startswith("|") and line.strip().endswith("|"):
            table_lines.append(line.strip())
        else:
            if len(table_lines) >= 6:
                data_rows = table_lines[2:]  # skip header + separator
                total_cells = 0
                empty_cells = 0
                for row in data_rows:
                    cells = [c.strip() for c in row.strip("|").split("|")]
                    total_cells += len(cells)
                    empty_cells += sum(1 for c in cells if not c)
                if total_cells > 0 and (empty_cells / total_cells) > 0.45:
                    sparse_tables += 1
            table_lines = []

    # 7. Duplicate leading H1 matching front-matter title.
    title = meta.get("title", "")
    body_lines = [ln.strip() for ln in prose.splitlines() if ln.strip()]
    dup_h1 = False
    if title and body_lines and body_lines[0].startswith("# "):
        h1_txt = body_lines[0][2:].strip()
        if h1_txt == title or (len(h1_txt) >= 3 and title.startswith(h1_txt)):
            dup_h1 = True

    headings = re.findall(r"^#{1,6}\s+.+$", prose, re.M)
    cards = re.findall(r"^:::card\b", prose, re.M)
    columns = re.findall(r"^:::columns\b", prose, re.M)
    images = re.findall(r"!\[[^\]]*\]\([^)]+\)|<img\s+[^>]+>", prose)

    issues: list[str] = []
    if not body.strip():
        issues.append("empty_body")
    elif html_bytes >= 10000 and len(body.strip()) < 220:
        issues.append(f"thin_extraction({len(body.strip())}c)")
    if giant_links:
        issues.append(f"giant_link({len(giant_links)},max={max_link_len})")
    if glued_matches:
        issues.append(f"glued_after_link({len(glued_matches)})")
    if unbalanced_containers:
        issues.append("unbalanced_container_fences")
    if raw_html_leaks:
        issues.append(f"raw_html_leak({len(raw_html_leaks)})")
    if chrome_hits:
        issues.append(f"chrome_noise({'+'.join(chrome_hits)})")
    if sparse_tables:
        issues.append(f"sparse_pipe_table({sparse_tables})")
    if dup_h1:
        issues.append("duplicate_leading_h1")

    return {
        "title": title,
        "bytes": len(md.encode("utf-8")),
        "headings": len(headings),
        "cards": len(cards),
        "columns": len(columns),
        "links": len(link_labels),
        "images": len(images),
        "max_link_len": max_link_len,
        "glued_after_link": len(glued_matches),
        "unbalanced_fences": unbalanced_containers,
        "raw_html_leaks": len(raw_html_leaks),
        "chrome_noise": chrome_hits,
        "sparse_tables": sparse_tables,
        "duplicate_leading_h1": dup_h1,
        "issues": issues,
    }


def find_cached_html(url: str, cache_dir: Path) -> Path | None:
    target = url.rstrip("/")
    best: tuple[float, Path] | None = None
    for meta_path in glob.glob(str(cache_dir / "*" / "meta.json")):
        try:
            d = json.loads(Path(meta_path).read_text(encoding="utf-8"))
        except Exception:
            continue
        u = (d.get("url") or "").rstrip("/")
        src = Path(meta_path).parent / "source.html"
        if u == target and src.exists() and src.stat().st_size > 0:
            mtime = src.stat().st_mtime
            if best is None or mtime > best[0]:
                best = (mtime, src)
    return best[1] if best else None


def fetch_url_bytes(url: str, timeout: int = 20) -> bytes:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def cmd_add(args: argparse.Namespace) -> int:
    corpus_dir = Path(args.corpus_dir)
    entry_dir = corpus_dir / args.slug
    entry_dir.mkdir(parents=True, exist_ok=True)
    html_dst = entry_dir / "source.html"

    if args.file:
        shutil.copyfile(args.file, html_dst)
    elif args.from_cache:
        src = find_cached_html(args.url, Path(args.cache_dir))
        if not src:
            print(f"No cached HTML found for {args.url} in {args.cache_dir}", file=sys.stderr)
            return 1
        shutil.copyfile(src, html_dst)
    else:
        html_dst.write_bytes(fetch_url_bytes(args.url, timeout=25))

    res = compile_batch(
        [{"id": args.slug, "html_path": str(html_dst), "url": args.url}],
        emacs=args.emacs,
    )[0]
    if res["error"]:
        print(f"Compile error for {args.slug}: {res['error']}", file=sys.stderr)
        return 1

    md = res["markdown"]
    stats = analyze_markdown(md, html_dst.stat().st_size)
    (entry_dir / "baseline.md").write_text(md, encoding="utf-8")
    meta = {
        "slug": args.slug,
        "url": args.url,
        "archetype": args.archetype or "general",
        "baseline_stats": stats,
    }
    (entry_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    status = "OK" if not stats["issues"] else ",".join(stats["issues"])
    print(
        f"Added {args.slug}: {stats['bytes']}B, h={stats['headings']}, "
        f"cards={stats['cards']}, links={stats['links']}, max_link={stats['max_link_len']} [{status}]"
    )
    return 0


def load_corpus_entries(corpus_dir: Path, slugs: list[str] | None = None) -> list[dict]:
    entries: list[dict] = []
    if not corpus_dir.exists():
        return entries
    for meta_file in sorted(corpus_dir.glob("*/meta.json")):
        d = json.loads(meta_file.read_text(encoding="utf-8"))
        slug = d["slug"]
        if slugs and slug not in slugs:
            continue
        html_path = meta_file.parent / "source.html"
        if html_path.exists():
            entries.append(
                {
                    "id": slug,
                    "html_path": str(html_path),
                    "url": d["url"],
                    "dir": meta_file.parent,
                    "meta": d,
                }
            )
    return entries


def cmd_diff(args: argparse.Namespace) -> int:
    corpus_dir = Path(args.corpus_dir)
    entries = load_corpus_entries(corpus_dir, args.slugs or None)
    if not entries:
        print(f"No golden-corpus entries found under {corpus_dir}.")
        return 0

    results = compile_batch(
        [{"id": e["id"], "html_path": e["html_path"], "url": e["url"]} for e in entries],
        emacs=args.emacs,
    )
    res_map = {r["id"]: r for r in results}

    print(
        f"{'SLUG':<24} {'STATUS':<11} {'BYTES':>7} {'HEAD':>4} {'CARD':>4} "
        f"{'LINK':>4} {'MAXL':>4} {'ISSUES'}"
    )
    print("-" * 88)
    regressed = 0
    for e in entries:
        slug = e["id"]
        r = res_map[slug]
        if r["error"]:
            regressed += 1
            print(f"{slug:<24} {'ERROR':<11} {'-':>7} {'-':>4} {'-':>4} {'-':>4} {'-':>4} {r['error']}")
            continue
        md = r["markdown"]
        stats = analyze_markdown(md, Path(e["html_path"]).stat().st_size)
        base_file = e["dir"] / "baseline.md"
        base_md = base_file.read_text(encoding="utf-8") if base_file.exists() else ""
        changed = md != base_md
        if stats["issues"]:
            status = "REGRESSED"
            regressed += 1
        elif changed:
            status = "CHANGED"
        else:
            status = "UNCHANGED"
        issue_str = ", ".join(stats["issues"]) if stats["issues"] else "-"
        print(
            f"{slug:<24} {status:<11} {stats['bytes']:>7} {stats['headings']:>4} "
            f"{stats['cards']:>4} {stats['links']:>4} {stats['max_link_len']:>4} {issue_str}"
        )
        if args.show_diff and changed:
            diff_lines = list(
                difflib.unified_diff(
                    base_md.splitlines(),
                    md.splitlines(),
                    fromfile=f"{slug}/baseline.md",
                    tofile=f"{slug}/current.md",
                    lineterm="",
                    n=2,
                )
            )
            for line in diff_lines[:60]:
                print("  " + line)
            if len(diff_lines) > 60:
                print(f"  ... ({len(diff_lines) - 60} more diff lines)")
    return 1 if regressed else 0


def cmd_update(args: argparse.Namespace) -> int:
    corpus_dir = Path(args.corpus_dir)
    entries = load_corpus_entries(corpus_dir, args.slugs or None)
    if not entries:
        print(f"No golden-corpus entries found under {corpus_dir}.")
        return 0
    results = compile_batch(
        [{"id": e["id"], "html_path": e["html_path"], "url": e["url"]} for e in entries],
        emacs=args.emacs,
    )
    res_map = {r["id"]: r for r in results}
    for e in entries:
        slug = e["id"]
        r = res_map[slug]
        if r["error"]:
            print(f"Skip {slug}: {r['error']}", file=sys.stderr)
            continue
        md = r["markdown"]
        stats = analyze_markdown(md, Path(e["html_path"]).stat().st_size)
        (e["dir"] / "baseline.md").write_text(md, encoding="utf-8")
        e["meta"]["baseline_stats"] = stats
        (e["dir"] / "meta.json").write_text(
            json.dumps(e["meta"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"Updated {slug}: {stats['bytes']}B, issues={stats['issues'] or 'none'}")
    return 0


def cmd_check_fixtures(args: argparse.Namespace) -> int:
    fixtures_dir = PACKAGE_ROOT / "tests" / "fixtures"
    jobs = []
    for html_file in sorted(fixtures_dir.glob("*.html")):
        jobs.append(
            {
                "id": html_file.name,
                "html_path": str(html_file),
                "url": f"https://example.com/{html_file.name}",
            }
        )
    results = compile_batch(jobs, emacs=args.emacs)
    failed = 0
    for r in results:
        if r["error"]:
            failed += 1
            print(f"FAIL {r['id']}: {r['error']}")
            continue
        stats = analyze_markdown(r["markdown"])
        hard_issues = [
            i
            for i in stats["issues"]
            if i not in ("empty_body", "duplicate_leading_h1")
            and not i.startswith("thin_extraction")
        ]
        if hard_issues:
            failed += 1
            print(f"FAIL {r['id']}: {', '.join(hard_issues)}")
    if failed:
        print(f"Fixture quality check FAILED ({failed}/{len(results)} fixtures).")
        return 1
    print(f"Fixture quality check OK ({len(results)} fixtures, 0 structural anomalies).")
    return 0


def cmd_audit_cache(args: argparse.Namespace) -> int:
    cache_dir = Path(args.cache_dir)
    seen_urls: dict[str, tuple[float, Path]] = {}
    for meta_path in glob.glob(str(cache_dir / "*" / "meta.json")):
        try:
            d = json.loads(Path(meta_path).read_text(encoding="utf-8"))
        except Exception:
            continue
        url = d.get("url") or ""
        if not url.startswith(("http://", "https://")):
            continue
        if url.lower().endswith((".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")):
            continue
        src = Path(meta_path).parent / "source.html"
        if not src.exists() or src.stat().st_size == 0 or src.stat().st_size > 1_000_000:
            continue
        mtime = src.stat().st_mtime
        if url not in seen_urls or mtime > seen_urls[url][0]:
            seen_urls[url] = (mtime, src)

    items = sorted(seen_urls.items(), key=lambda kv: kv[1][0], reverse=True)[: args.limit]
    jobs = [{"id": url, "html_path": str(src), "url": url} for url, (_, src) in items]
    sizes = {url: src.stat().st_size for url, (_, src) in items}
    results = compile_batch(jobs, emacs=args.emacs)

    flagged = []
    clean = 0
    for r in results:
        if r["error"]:
            flagged.append((100, r["id"], f"error: {r['error']}", {}))
            continue
        stats = analyze_markdown(r["markdown"], sizes.get(r["id"], 0))
        if stats["issues"]:
            score = (
                (50 if "unbalanced_container_fences" in stats["issues"] else 0)
                + (30 if any(i.startswith("giant_link") for i in stats["issues"]) else 0)
                + (25 if any(i.startswith("thin_extraction") for i in stats["issues"]) else 0)
                + (20 if any(i.startswith("chrome_noise") for i in stats["issues"]) else 0)
                + (15 if any(i.startswith("sparse_pipe_table") for i in stats["issues"]) else 0)
                + (10 * stats["glued_after_link"])
                + (20 if "empty_body" in stats["issues"] else 0)
            )
            flagged.append((score, r["id"], ", ".join(stats["issues"]), stats))
        else:
            clean += 1

    flagged.sort(key=lambda x: x[0], reverse=True)
    print(f"Audited {len(results)} cached HTTP(S) pages: {clean} clean, {len(flagged)} flagged.")
    if flagged:
        print()
        for _, url, issues, _ in flagged:
            print(f"  [{issues}]  {url}")
    return 0


def cmd_benchmark(args: argparse.Namespace) -> int:
    bench_dir = Path(args.bench_dir)
    bench_dir.mkdir(parents=True, exist_ok=True)
    sites = BENCHMARK_SITES
    if args.urls:
        sites = json.loads(Path(args.urls).read_text(encoding="utf-8"))

    # Fetch missing (or --refresh) snapshots in parallel so 17 sites complete in ~4s.
    def ensure_snapshot(site: dict[str, str]) -> tuple[str, Path | None, str | None]:
        slug = site["slug"]
        dst = bench_dir / f"{slug}.html"
        if dst.exists() and dst.stat().st_size > 0 and not args.refresh:
            return slug, dst, None
        try:
            data = fetch_url_bytes(site["url"], timeout=18)
            dst.write_bytes(data)
            return slug, dst, None
        except Exception as exc:
            return slug, None, str(exc)

    fetched: dict[str, tuple[Path | None, str | None]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for slug, path, err in pool.map(ensure_snapshot, sites):
            fetched[slug] = (path, err)

    jobs = []
    for s in sites:
        p, err = fetched[s["slug"]]
        if p and not err:
            jobs.append({"id": s["slug"], "html_path": str(p), "url": s["url"]})

    results = compile_batch(jobs, emacs=args.emacs, with_route=True)
    res_map = {r["id"]: r for r in results}

    print(
        f"{'ARCHETYPE':<17} {'SLUG':<18} {'ROUTE':<10} {'LEAVES':>6} "
        f"{'BYTES':>7} {'HEAD':>4} {'LINK':>4} {'ISSUES'}"
    )
    print("-" * 104)

    cause_counter: collections.Counter[str] = collections.Counter()
    clean_count = 0
    total_count = len(sites)

    for s in sites:
        slug = s["slug"]
        arch = s["archetype"]
        exp_route = s.get("expect_route", "")
        p, ferr = fetched[slug]
        if ferr or not p:
            cause_counter["fetch_error"] += 1
            print(f"{arch:<17} {slug:<18} {'FETCH-ERR':<10} {'-':>6} {'-':>7} {'-':>4} {'-':>4} {ferr}")
            continue
        r = res_map[slug]
        if r["error"]:
            cause_counter["compile_error"] += 1
            print(f"{arch:<17} {slug:<18} {'ERR':<10} {'-':>6} {'-':>7} {'-':>4} {'-':>4} {r['error']}")
            continue

        md = r["markdown"]
        route = r["route"]
        leaves = r["docs_leaves"]
        stats = analyze_markdown(md, p.stat().st_size)
        issues = list(stats["issues"])
        if exp_route and route != exp_route:
            issues.append(f"route_mismatch(got={route},want={exp_route})")

        # Save compiled snapshot for easy inspection
        (bench_dir / f"{slug}.md").write_text(md, encoding="utf-8")

        if not issues:
            clean_count += 1
        else:
            for iss in issues:
                cause_counter[iss.split("(")[0]] += 1

        issue_str = ", ".join(issues) if issues else "OK"
        print(
            f"{arch:<17} {slug:<18} {route:<10} {leaves:>6} "
            f"{stats['bytes']:>7} {stats['headings']:>4} {stats['links']:>4} {issue_str}"
        )

    print("-" * 104)
    print(f"Benchmark summary: {clean_count}/{total_count} sites completely clean.")
    if cause_counter:
        top = ", ".join(f"{k}={v}" for k, v in cause_counter.most_common())
        print(f"Systemic defect clusters: {top}")
    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps(
                {
                    "clean": clean_count,
                    "total": total_count,
                    "causes": dict(cause_counter),
                },
                ensure_ascii=False,
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="ETAF Web multi-archetype benchmark & corpus harness")
    parser.add_argument("--emacs", default="emacs", help="Emacs executable")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_fix = sub.add_parser("check-fixtures", help="Check universal invariants on tests/fixtures/")
    p_fix.set_defaults(func=cmd_check_fixtures)

    p_add = sub.add_parser("add", help="Add a real webpage to the local golden corpus")
    p_add.add_argument("slug", help="Short directory slug (e.g. claude-bp-home)")
    p_add.add_argument("url", help="Canonical page URL")
    p_add.add_argument("--archetype", help="Optional archetype tag (landing, docs, blog, spec)")
    p_add.add_argument("--from-cache", action="store_true", help="Copy source.html from etaf-web cache")
    p_add.add_argument("--file", help="Copy HTML from local file path")
    p_add.add_argument("--cache-dir", default=str(DEFAULT_CACHE_DIR))
    p_add.add_argument("--corpus-dir", default=str(DEFAULT_CORPUS_DIR))
    p_add.set_defaults(func=cmd_add)

    p_diff = sub.add_parser("diff", help="Diff current compiler output against golden corpus")
    p_diff.add_argument("slugs", nargs="*")
    p_diff.add_argument("--show-diff", action="store_true")
    p_diff.add_argument("--corpus-dir", default=str(DEFAULT_CORPUS_DIR))
    p_diff.set_defaults(func=cmd_diff)

    p_upd = sub.add_parser("update", help="Update golden corpus baselines after verifying improvements")
    p_upd.add_argument("slugs", nargs="*")
    p_upd.add_argument("--corpus-dir", default=str(DEFAULT_CORPUS_DIR))
    p_upd.set_defaults(func=cmd_update)

    p_aud = sub.add_parser("audit-cache", help="Audit real cached pages for systemic quality issues")
    p_aud.add_argument("--cache-dir", default=str(DEFAULT_CACHE_DIR))
    p_aud.add_argument("--limit", type=int, default=40)
    p_aud.set_defaults(func=cmd_audit_cache)

    p_bench = sub.add_parser("benchmark", help="Run multi-archetype real-web benchmark & cluster root causes")
    p_bench.add_argument("--bench-dir", default=str(DEFAULT_BENCH_DIR))
    p_bench.add_argument("--urls", help="Optional JSON file of [{slug, archetype, url, expect_route}]")
    p_bench.add_argument("--refresh", action="store_true", help="Re-fetch HTML snapshots from network")
    p_bench.add_argument("--json-out", help="Write summary metrics JSON to path")
    p_bench.set_defaults(func=cmd_benchmark)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
