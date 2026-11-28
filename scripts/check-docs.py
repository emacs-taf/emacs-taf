#!/usr/bin/env python3
"""Layer-1 & Layer-2 documentation gate for the Emacs TAF monorepo.

Checks:
  1. GitHub Actions workflow badges point to existing `.github/workflows/<file>`.
  2. Relative Markdown links and `#heading-anchor` targets across maintained docs
     (including same-file anchors and `core/README*.md` projection-root links).
  3. External `https://etaf.top/...` manual chapter & anchor links via
     `core/packages/etaf-manual/scripts/check-references.py`.
  4. Banned retired documentation patterns (legacy per-core-package `git clone`
     URLs, stale `packages/<core>/scripts/` paths, legacy flat `-L ../<core>`
     flags in apps/games).
  5. Layer-2 Markdown `elisp` code block balanced syntax and public-symbol
     liveness against `scripts/check-api.py`'s public API index.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path, PurePosixPath
import re
import sys
import unicodedata
from urllib.parse import unquote

sys.dont_write_bytecode = True
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import workspace_layout  # noqa: E402

ROOT = SCRIPT_DIR.parent
SKIP_DIRS = {
    ".git", ".jj", "node_modules", "__pycache__", "dist", "build",
    "target", ".worktrees", "vendor", "dictionaries",
}
HEADING_RE = re.compile(r"^[ ]{0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$")
FENCE_RE = re.compile(r"^[ ]{0,3}(`{3,}|~{3,})[ \t]*(.*)$")
LINK_TEXT_RE = re.compile(r"\[([^]]*)\]\([^)]*\)")
WORKFLOW_BADGE_RE = re.compile(
    r"https://github\.com/emacs-taf/emacs-taf/actions/workflows/([A-Za-z0-9_.-]+\.ya?ml)(?:/badge\.svg)?"
)
RETIRED_CORE_CLONE_RE = re.compile(
    r"git\s+clone\s+https://github\.com/emacs-taf/"
    r"(?:ecss|ekp|ebox|etaf-media|etaf-ui|etaf-doc|etaf-db|etaf-posframe|etaf-ext|etaf-gamekit|"
    r"etaf-hints|etaf-highlight|etaf-translate|etaf-export|etaf-install|etaf-manual)(?:\.git)?\b"
)
RETIRED_MONO_SCRIPTS_RE = re.compile(
    r"(?<!core/)packages/(?:ecss|ekp|ebox|etaf|etaf-media|etaf-ui|etaf-doc|etaf-db|etaf-posframe|etaf-ext|etaf-gamekit)/scripts/"
)
RETIRED_MONO_BLOB_RE = re.compile(
    r"https://github\.com/emacs-taf/emacs-taf/(?:blob|tree)/main/packages/"
)
RETIRED_APP_LOAD_PATH_RE = re.compile(
    r"(?:^|\s)-L\s+\.\./(?:ecss|ekp|ebox|etaf|etaf-media|etaf-ui|etaf-doc|etaf-db|etaf-posframe|etaf-ext|etaf-gamekit)(?=\s|$)"
)


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def github_slug(text: str) -> str:
    """GitHub-compatible Markdown heading slug (matching check-references.py)."""
    plain = LINK_TEXT_RE.sub(r"\1", text)
    plain = re.sub(r"`([^`]*)`", r"\1", plain).lower()
    out = []
    for ch in plain:
        cat = unicodedata.category(ch)
        if ch == " ":
            out.append("-")
        elif ch in ("-", "_") or cat[:1] in ("L", "N", "M"):
            out.append(ch)
    return "".join(out)


def markdown_anchors(path: Path) -> set[str]:
    seen: dict[str, int] = {}
    anchors: set[str] = set()
    fence: str | None = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if fence:
            if re.match(r"^[ ]{0,3}" + re.escape(fence) + r"[`~]*[ \t]*$", line):
                fence = None
            continue
        m = FENCE_RE.match(line)
        if m:
            fence = m.group(1)
            continue
        hm = HEADING_RE.match(line)
        if not hm:
            continue
        base = github_slug(hm.group(2))
        if base in seen:
            seen[base] += 1
            anchors.add(f"{base}-{seen[base]}")
        else:
            seen[base] = 0
            anchors.add(base)
    return anchors


def iter_markdown_files(root: Path) -> list[Path]:
    found: list[Path] = []
    for current, dirs, files in os.walk(root):
        rel_parts = Path(current).relative_to(root).parts
        # Skip generated site/ subtrees and vendor/fixtures.
        dirs[:] = sorted(
            d for d in dirs
            if d not in SKIP_DIRS
            and not (rel_parts and rel_parts[-1] == "site" and d in ("src", "public", "dist"))
            and not (rel_parts and rel_parts[-1] == "tests" and d == "fixtures")
        )
        for name in sorted(files):
            if name.endswith(".md"):
                found.append(Path(current) / name)
    return found


def strip_code(text: str) -> list[tuple[int, str]]:
    """Return list of (1-based line_no, text_without_inline_code) outside fenced blocks."""
    out: list[tuple[int, str]] = []
    fence: str | None = None
    for lineno, line in enumerate(text.splitlines(), start=1):
        if fence:
            if re.match(r"^[ ]{0,3}" + re.escape(fence) + r"[`~]*[ \t]*$", line):
                fence = None
            continue
        m = FENCE_RE.match(line)
        if m:
            fence = m.group(1)
            continue
        stripped = re.sub(r"(?<!`)(`+)(?!`).+?(?<!`)\1(?!`)", "", line)
        out.append((lineno, stripped))
    return out


def extract_elisp_blocks(text: str) -> list[tuple[int, str, str]]:
    """Return list of (start_line, info_string, code) for fenced elisp blocks."""
    blocks: list[tuple[int, str, str]] = []
    fence: str | None = None
    info = ""
    start_line = 0
    buf: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if fence:
            if re.match(r"^[ ]{0,3}" + re.escape(fence) + r"[`~]*[ \t]*$", line):
                if info.split()[0].lower() in ("elisp", "emacs-lisp") if info.strip() else False:
                    blocks.append((start_line, info.strip(), "\n".join(buf)))
                fence = None
                buf = []
                continue
            buf.append(line)
            continue
        m = FENCE_RE.match(line)
        if m:
            fence = m.group(1)
            info = m.group(2).strip()
            start_line = lineno + 1
            buf = []
    return blocks


def check_elisp_balance(code: str) -> str | None:
    """Return error string if CODE has unbalanced parens/brackets/strings, else None."""
    stack: list[str] = []
    pairs = {")": "(", "]": "["}
    i, n = 0, len(code)
    while i < n:
        c = code[i]
        if c == ";":
            end = code.find("\n", i)
            i = n if end < 0 else end + 1
            continue
        if c == '"':
            i += 1
            closed = False
            while i < n:
                if code[i] == "\\":
                    i += 2
                elif code[i] == '"':
                    i += 1
                    closed = True
                    break
                else:
                    i += 1
            if not closed:
                return "unclosed string literal in elisp code block"
            continue
        if c == "?" and (i == 0 or code[i - 1] in " \t\r\n(['`,"):
            i += 2
            if i <= n and code[i - 1] == "\\":
                if i < n and code[i] in "xuU":
                    while i < n and code[i] not in " \t\r\n()[]'\"`;":
                        i += 1
                else:
                    i += 1
            continue
        if c in "([":
            stack.append(c)
        elif c in ")]":
            if not stack or stack[-1] != pairs[c]:
                return f"unexpected closing {c!r} in elisp code block"
            stack.pop()
        i += 1
    if stack:
        return f"unclosed {stack[-1]!r} in elisp code block"
    return None


def build_symbol_index(root: Path) -> tuple[set[str], set[str], set[str]]:
    """Return (public_symbols, runtime_defined_symbols, package_prefixes)."""
    check_api = load_module("check_api_docs", SCRIPT_DIR / "check-api.py")
    public: set[str] = set()
    defined: set[str] = set()
    prefixes: set[str] = set()
    for name, pkg_dir in workspace_layout.package_dirs(root).items():
        entry = pkg_dir / f"{name}.el"
        if not entry.is_file():
            continue
        prefixes.add(name + "-")
        public.add(name)
        try:
            api, _errs = check_api.declarations(entry)
        except Exception:
            continue
        public.update(api.keys())
        runtime_files = [entry] + sorted((pkg_dir / "lisp").glob("*.el"))
        for f in runtime_files:
            text = re.sub(r'"(?:\\.|[^"\\])*"|;[^\n]*', lambda m: " " * len(m[0]),
                          f.read_text(encoding="utf-8", errors="replace"))
            defined.update(s for s in check_api.DEFINITION.findall(text) if not s.startswith(","))
            defined.difference_update(re.findall(r"\(defvar\s+([^\s()]+)\s*\)", text))
            defined.update(re.findall(r"\((?:define-error|defalias|defvaralias)\s+'([^\s()]+)", text))
            defined.update(check_api.struct_symbols(text))
            public.update(re.findall(r"\(provide\s+'([^\s()]+)", text))
        defined.update(api.keys())
    return public, defined, prefixes


def _local_block_definitions(code: str) -> set[str]:
    """Return symbol names defined locally inside an example elisp block."""
    local: set[str] = set()
    for pat in (
        r"\((?:defun|cl-defun|defmacro|defvar|defconst|defcustom|etaf-define-component|etaf-define-behavior|etaf-action-define)\s+([^\s()]+)",
        r"\(etaf-define-component\s+([^\s()]+)",
    ):
        local.update(re.findall(pat, code))
    return local


def check_docs(root: Path) -> list[str]:
    root = Path(root).resolve()
    errors: list[str] = []
    workflows_dir = root / ".github" / "workflows"
    anchor_cache: dict[Path, set[str]] = {}
    manuscript = root / "core" / "packages" / "etaf-manual"
    generated_book = set()
    book_json = manuscript / "book" / "book.json"
    if book_json.is_file():
        import json
        try:
            b = json.loads(book_json.read_text(encoding="utf-8"))
            for item in list(b.get("appendices") or []) + list(b.get("indices") or []):
                if isinstance(item, dict) and item.get("id") and item.get("generate"):
                    for lang in b.get("languages") or []:
                        generated_book.add((manuscript / "book" / lang / f"{item['id']}.md").resolve())
        except (OSError, ValueError):
            pass

    def get_anchors(p: Path) -> set[str]:
        rp = p.resolve()
        if rp not in anchor_cache:
            anchor_cache[rp] = markdown_anchors(rp)
        return anchor_cache[rp]

    public_syms, defined_syms, prefixes = build_symbol_index(root)
    internal_syms = defined_syms - public_syms
    check_api = load_module("check_api_docs_tok", SCRIPT_DIR / "check-api.py")

    md_files = iter_markdown_files(root)
    for md in md_files:
        rel = md.relative_to(root).as_posix()
        text = md.read_text(encoding="utf-8", errors="replace")

        # 1. Workflow badges & 2. Relative links + anchors & 4. Banned patterns outside code
        for lineno, line in strip_code(text):
            for wm in WORKFLOW_BADGE_RE.finditer(line):
                wf_name = wm.group(1)
                if workflows_dir.is_dir() and not (workflows_dir / wf_name).is_file():
                    errors.append(f"{rel}:{lineno}: workflow badge references missing .github/workflows/{wf_name}")

            if RETIRED_MONO_BLOB_RE.search(line):
                errors.append(f"{rel}:{lineno}: retired monorepo URL pointing to /packages/ instead of /core/packages/")

            links = re.findall(r"\]\(<?([^\s)>]+)>?(?:\s+\"[^\"]*\")?\)", line)
            links += re.findall(r"^\s*\[[^\]]+\]:\s*<?([^\s>]+)>?", line)
            for link in links:
                if re.match(r"[a-zA-Z][\w+.-]*:", link) or link.startswith("/"):
                    continue
                if link.startswith("#"):
                    anchor = unquote(link[1:])
                    if anchor and anchor not in get_anchors(md):
                        errors.append(f"{rel}:{lineno}: broken same-file heading anchor #{anchor}")
                    continue
                target_part, *frag = link.split("#", 1)
                rel_target = unquote(target_part)
                anchor = unquote(frag[0]) if frag else ""
                resolved = Path(os.path.normpath(str(md.parent / rel_target)))
                try:
                    resolved.relative_to(root)
                except ValueError:
                    errors.append(f"{rel}:{lineno}: relative link escapes repository root: {link}")
                    continue
                if resolved.resolve() in generated_book:
                    continue
                if not resolved.exists():
                    errors.append(f"{rel}:{lineno}: broken relative link: {link}")
                    continue
                if anchor and resolved.is_file() and resolved.suffix.lower() == ".md":
                    if anchor not in get_anchors(resolved):
                        errors.append(f"{rel}:{lineno}: broken heading anchor in {link}")

        # 4. Banned legacy patterns across full file (including fenced shell/elisp blocks)
        is_doc_about_policy = rel in ("AGENTS.md", "docs/manual.md", "docs/manual.zh-CN.md", "docs/architecture.zh-CN.md")
        if not is_doc_about_policy:
            for lineno, line in enumerate(text.splitlines(), start=1):
                if RETIRED_CORE_CLONE_RE.search(line):
                    errors.append(f"{rel}:{lineno}: retired per-core-package git clone URL; clone https://github.com/emacs-taf/etaf.git instead")
                if RETIRED_MONO_SCRIPTS_RE.search(line):
                    errors.append(f"{rel}:{lineno}: retired path packages/<core>/scripts/; use core/packages/<core>/scripts/")
                if rel.startswith(("apps/", "games/")) and RETIRED_APP_LOAD_PATH_RE.search(line):
                    errors.append(f"{rel}:{lineno}: retired flat -L ../<core-pkg> flag; use ../etaf/packages/<pkg> or ../../core/packages/<pkg>")

        # 5. Layer-2 elisp code block checks (skip etaf-manual/book/ which check-book.el evaluates,
        # and skip CHANGELOG/architecture design notes)
        in_book = rel.startswith("core/packages/etaf-manual/book/")
        check_elisp = (
            not in_book
            and (
                Path(rel).name in ("README.md", "README.zh-CN.md", "manual.md", "manual.zh-CN.md")
            )
        )
        if check_elisp:
            for start_line, _info, code in extract_elisp_blocks(text):
                # Skip snippets that intentionally contain interactive M-x commands or ellipses.
                bal_err = check_elisp_balance(code)
                if bal_err:
                    errors.append(f"{rel}:{start_line}: {bal_err}")
                    continue
                local_defs = _local_block_definitions(code)
                for tok in set(check_api.tokens(code)):
                    if tok in local_defs:
                        continue
                    if tok in internal_syms and any(tok.startswith(p) for p in prefixes):
                        errors.append(
                            f"{rel}:{start_line}: elisp example references internal symbol `{tok}` "
                            "(use a declared public API symbol instead)"
                        )

    # 3. Run etaf-manual external reference checker across the monorepo
    ref_script = manuscript / "scripts" / "check-references.py"
    if ref_script.is_file():
        ref_mod = load_module("check_references", ref_script)
        for src, lineno, msg in ref_mod.check(root, manuscript):
            errors.append(f"{src}:{lineno}: {msg}")

    return sorted(set(errors))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    errors = check_docs(args.root)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    print("Documentation checks OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
