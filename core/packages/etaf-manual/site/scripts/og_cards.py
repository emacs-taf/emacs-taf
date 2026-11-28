#!/usr/bin/env python3
"""Render per-page 1200x630 OpenGraph preview cards for https://etaf.top.

Every page family on etaf.top (bilingual landing pages, Reference Manual
chapters, package archive index and detail pages, prebuilt native modules,
and the hosted media library) shares this single renderer so all link preview
cards keep the same editorial charcoal-and-violet visual language while
displaying each page's own URL path, title, summary and live metadata.

Cards are generated at build/publish time (never committed to Git).
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import unicodedata
import zlib

WIDTH = 1200
HEIGHT = 630
RENDERER_VERSION = 1

SITE_DIR = Path(__file__).resolve().parents[1]
ICON_SVG_PATH = SITE_DIR / "src/assets/etaf-icon.svg"

# Brand palette mirrored from site/src/styles/brand.css (dark default).
PAPER = "#191a1c"
PAPER_ELEVATED = "#202225"
RULE = "#2f3135"
INK = "#e3e1db"
INK_2 = "#b8b6af"
INK_3 = "#89877f"
ACCENT = "#c3b0ff"

# Font stacks aligned with brand.css and local system fallbacks for librsvg/pango.
FONT_DISPLAY_EN = (
    "Source Serif 4, Noto Serif, Georgia, Source Han Serif SC, "
    "Noto Serif CJK SC, Songti SC, serif"
)
FONT_DISPLAY_ZH = (
    "Source Han Serif SC, Noto Serif CJK SC, Songti SC, "
    "Source Serif 4, Georgia, serif"
)
FONT_BODY_EN = (
    "Source Serif 4, Noto Serif, Georgia, LXGW WenKai, "
    "Source Han Serif SC, serif"
)
FONT_BODY_ZH = (
    "LXGW WenKai, Source Han Serif SC, PingFang SC, "
    "Source Serif 4, Georgia, serif"
)
FONT_MONO = (
    "IBM Plex Mono, JetBrains Mono, LXGW WenKai Mono, "
    "SF Mono, Menlo, monospace"
)


@dataclass(frozen=True)
class CardSpec:
    """Data model for one 1200x630 OpenGraph preview card."""

    title: str
    subtitle: str
    url_label: str
    footer_left: str
    footer_right: str
    lang: str = "en"
    eyebrow: str = ""

    def digest(self) -> str:
        """Stable 8-hex digest of this card's visual content and renderer."""
        payload = json.dumps(
            {"v": RENDERER_VERSION, **asdict(self)},
            sort_keys=True,
            ensure_ascii=False,
        ).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()[:8]


def _char_units(ch: str) -> float:
    """Approximate proportional glyph width in Latin-em units."""
    if ch.isspace():
        return 0.32
    ea = unicodedata.east_asian_width(ch)
    if ea in ("W", "F"):
        return 1.72
    if ch in "ilIjtfr.,:;!|'\"()[]{}":
        return 0.45
    if ch in "mwMW@%":
        return 1.25
    if ch.isupper():
        return 0.95
    return 0.78


def _text_units(text: str) -> float:
    return sum(_char_units(ch) for ch in text)


def _is_cjk_char(ch: str) -> bool:
    return unicodedata.east_asian_width(ch) in ("W", "F")


def _clean_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip())


def _tokenize_for_wrap(text: str) -> list[str]:
    """Split text into wrappable tokens: Latin words/spaces and individual CJK glyphs.

    Keeps opening/closing CJK punctuation attached gently where possible while
    preventing mid-word breaks inside Latin identifiers and words.
    """
    tokens: list[str] = []
    buf: list[str] = []
    for ch in text:
        if ch.isspace():
            if buf:
                tokens.append("".join(buf))
                buf.clear()
            if not tokens or tokens[-1] != " ":
                tokens.append(" ")
        elif _is_cjk_char(ch):
            if buf:
                tokens.append("".join(buf))
                buf.clear()
            tokens.append(ch)
        else:
            buf.append(ch)
    if buf:
        tokens.append("".join(buf))
    return tokens


_NO_LINE_START = frozenset("，。、；：！？）》】」』”’.,;:!?)]}")


def _trim_ellipsis(line: str, max_units: float) -> str:
    """Truncate LINE to fit within MAX_UNITS, appending an ellipsis cleanly."""
    ellipsis_units = 1.1
    budget = max(2.0, max_units - ellipsis_units)
    out: list[str] = []
    used = 0.0
    for ch in line:
        w = _char_units(ch)
        if used + w > budget:
            break
        out.append(ch)
        used += w
    trimmed = "".join(out).rstrip(" ,.;:!?-—·、，。；：！？（([{")
    # Avoid cutting mid-Latin-word if we can trim back to the last space.
    if trimmed and not _is_cjk_char(trimmed[-1]) and " " in trimmed:
        head, tail = trimmed.rsplit(" ", 1)
        if head and len(tail) <= 12 and _text_units(head) >= budget * 0.55:
            trimmed = head.rstrip(" ,.;:!?-—·")
    return trimmed + "…"


def wrap_text(text: str, max_units: float, max_lines: int) -> list[str]:
    """Wrap TEXT into at most MAX_LINES lines within MAX_UNITS per line."""
    cleaned = _clean_whitespace(text)
    if not cleaned:
        return []
    tokens = _tokenize_for_wrap(cleaned)
    lines: list[str] = []
    current = ""
    current_units = 0.0
    truncated = False

    idx = 0
    while idx < len(tokens):
        tok = tokens[idx]
        if tok == " " and not current:
            idx += 1
            continue
        tok_units = _text_units(tok)
        if not current:
            if tok_units <= max_units:
                current = tok
                current_units = tok_units
                idx += 1
            else:
                # Overlong single token (e.g. a very long Lisp symbol): hard split.
                part = ""
                part_u = 0.0
                for ch in tok:
                    cw = _char_units(ch)
                    if part and part_u + cw > max_units:
                        break
                    part += ch
                    part_u += cw
                current = part or tok[:1]
                current_units = _text_units(current)
                rest = tok[len(current):]
                if rest:
                    tokens[idx] = rest
                else:
                    idx += 1
            continue

        if current_units + tok_units <= max_units:
            current += tok
            current_units += tok_units
            idx += 1
            continue

        # Allow CJK closing punctuation to squeeze onto current line slightly.
        if len(tok) == 1 and tok in _NO_LINE_START and current_units + tok_units <= max_units + 1.1:
            current += tok
            current_units += tok_units
            idx += 1
            continue

        # Line full.
        if len(lines) + 1 >= max_lines:
            truncated = True
            break
        lines.append(current.rstrip())
        current = ""
        current_units = 0.0

    if current:
        lines.append(current.rstrip())

    if truncated and lines:
        lines[-1] = _trim_ellipsis(lines[-1], max_units)
    return lines


def truncate_single_line(text: str, max_units: float) -> str:
    cleaned = _clean_whitespace(text)
    if _text_units(cleaned) <= max_units:
        return cleaned
    return _trim_ellipsis(cleaned, max_units)


def _load_icon_inner() -> str:
    """Extract the inner elements of site/src/assets/etaf-icon.svg with scoped IDs."""
    raw = ICON_SVG_PATH.read_text(encoding="utf-8")
    # Strip outer <svg ...> and </svg> plus <title>.
    inner = re.sub(r"\A.*?<svg[^>]*>", "", raw, count=1, flags=re.S)
    inner = re.sub(r"</svg>\s*\Z", "", inner, count=1, flags=re.S)
    inner = re.sub(r"<title>.*?</title>", "", inner, flags=re.S)
    inner = re.sub(r"<!--.*?-->", "", inner, flags=re.S)
    # Scope gradient/filter IDs so they never clash.
    inner = inner.replace('id="etaf-bg"', 'id="og-etaf-bg"')
    inner = inner.replace("url(#etaf-bg)", "url(#og-etaf-bg)")
    inner = inner.replace('id="block-shadow"', 'id="og-block-shadow"')
    inner = inner.replace("url(#block-shadow)", "url(#og-block-shadow)")
    return inner.strip()


_ICON_INNER_CACHE: str | None = None


def _icon_inner() -> str:
    global _ICON_INNER_CACHE
    if _ICON_INNER_CACHE is None:
        _ICON_INNER_CACHE = _load_icon_inner()
    return _ICON_INNER_CACHE


def _layout_title(title: str, is_zh: bool) -> tuple[int, int, list[str]]:
    """Choose (font_size, line_height, wrapped_lines) for the main heading."""
    cleaned = _clean_whitespace(title)
    units = _text_units(cleaned)
    # Content width is 1056px. Estimate usable units at each size conservatively.
    if is_zh:
        if units <= 21.5:
            return 72, 86, [cleaned]
        if units <= 25.5:
            return 62, 76, [cleaned]
        if units <= 46.0:
            lines = wrap_text(cleaned, 24.5, 2)
            return 60, 74, lines
        lines = wrap_text(cleaned, 28.5, 2)
        return 52, 65, lines

    if units <= 19.5:
        return 80, 92, [cleaned]
    if units <= 24.0:
        return 68, 80, [cleaned]
    if units <= 44.0:
        lines = wrap_text(cleaned, 24.0, 2)
        return 62, 74, lines
    lines = wrap_text(cleaned, 29.0, 2)
    return 52, 64, lines


def build_svg(spec: CardSpec) -> str:
    """Return a deterministic 1200x630 editorial OpenGraph SVG for SPEC."""
    is_zh = spec.lang.lower().startswith("zh")
    display_font = FONT_DISPLAY_ZH if is_zh else FONT_DISPLAY_EN
    body_font = FONT_BODY_ZH if is_zh else FONT_BODY_EN

    url_text = _clean_whitespace(spec.url_label)
    url_len = len(url_text)
    if url_len <= 28:
        url_size = 24
    elif url_len <= 38:
        url_size = 20
    else:
        url_size = 17
        url_text = truncate_single_line(url_text, 44.0)

    title_size, title_lh, title_lines = _layout_title(spec.title, is_zh)
    has_eyebrow = bool(_clean_whitespace(spec.eyebrow))

    # Position the editorial block comfortably between header (y=144) and footer rule (y=520).
    if len(title_lines) == 1:
        eyebrow_y = 216
        title_y0 = 278 if has_eyebrow else 284
        sub_max_lines = 3
        sub_size = 28 if is_zh else 30
        sub_lh = 45 if is_zh else 45
        sub_gap = 58
    else:
        eyebrow_y = 198
        title_y0 = 252 if has_eyebrow else 250
        sub_max_lines = 2
        sub_size = 26 if is_zh else 28
        sub_lh = 42 if is_zh else 42
        sub_gap = 50

    sub_units_budget = (1020.0 / sub_size) * (1.46 if is_zh else 1.52)
    subtitle_lines = wrap_text(spec.subtitle, sub_units_budget, sub_max_lines)
    title_bottom = title_y0 + (len(title_lines) - 1) * title_lh
    sub_y0 = title_bottom + sub_gap

    # Guard against subtitle ever colliding with the footer divider at y=520.
    while subtitle_lines and (sub_y0 + (len(subtitle_lines) - 1) * sub_lh) > 494:
        subtitle_lines.pop()
        if subtitle_lines:
            subtitle_lines[-1] = _trim_ellipsis(subtitle_lines[-1], sub_units_budget)

    footer_right = _clean_whitespace(spec.footer_right)
    footer_right_units = _text_units(footer_right)
    # Leave room on the right for the badge so left and right never overlap.
    left_max_units = max(20.0, 56.0 - footer_right_units)
    footer_left = truncate_single_line(spec.footer_left, left_max_units)

    parts: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}">',
        # Matte charcoal paper surface matching site/src/styles/brand.css (no gradients or glows).
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{PAPER}"/>',
        # Crisp hairline inner frame so dark cards separate cleanly on dark chat themes.
        f'<rect x="1" y="1" width="{WIDTH - 2}" height="{HEIGHT - 2}" fill="none" '
        f'stroke="{RULE}" stroke-width="2" opacity="0.65"/>',
        # Brand icon (84x84 at x=72, y=60) + ETAF wordmark.
        '<g transform="translate(72, 60) scale(0.1640625)">',
        _icon_inner(),
        "</g>",
        f'<text x="180" y="116" fill="{INK}" font-family="{FONT_MONO}" '
        f'font-size="40" font-weight="600" letter-spacing="8">ETAF</text>',
        f'<text x="1128" y="111" text-anchor="end" fill="{INK_3}" '
        f'font-family="{FONT_MONO}" font-size="{url_size}" letter-spacing="1">'
        f"{html.escape(url_text)}</text>",
    ]

    if has_eyebrow:
        eyebrow = truncate_single_line(spec.eyebrow, 48.0)
        parts.append(
            f'<text x="72" y="{eyebrow_y}" fill="{ACCENT}" font-family="{FONT_MONO}" '
            f'font-size="20" font-weight="500" letter-spacing="2.2">'
            f"{html.escape(eyebrow)}</text>"
        )

    title_weight = "500"
    for idx, line in enumerate(title_lines):
        y = title_y0 + idx * title_lh
        parts.append(
            f'<text x="72" y="{y}" fill="{INK}" font-family="{display_font}" '
            f'font-size="{title_size}" font-weight="{title_weight}">'
            f"{html.escape(line)}</text>"
        )

    for idx, line in enumerate(subtitle_lines):
        y = sub_y0 + idx * sub_lh
        parts.append(
            f'<text x="72" y="{y}" fill="{INK_2}" font-family="{body_font}" '
            f'font-size="{sub_size}">{html.escape(line)}</text>'
        )

    left_ls = "1.2" if is_zh else "2.2"
    right_ls = "1.2" if is_zh else "2"
    parts.extend([
        f'<line x1="72" y1="520" x2="1128" y2="520" stroke="{RULE}" stroke-width="1.5"/>',
        f'<text x="72" y="572" fill="{INK_3}" font-family="{FONT_MONO}" '
        f'font-size="20" letter-spacing="{left_ls}">{html.escape(footer_left)}</text>',
        f'<text x="1128" y="572" text-anchor="end" fill="{ACCENT}" '
        f'font-family="{FONT_MONO}" font-size="20" font-weight="500" '
        f'letter-spacing="{right_ls}">{html.escape(footer_right)}</text>',
        "</svg>",
    ])
    return "\n".join(parts) + "\n"


def _minimal_png_bytes(width: int = WIDTH, height: int = HEIGHT) -> bytes:
    """Return a valid solid-charcoal PNG when rsvg-convert is explicitly stubbed in tests."""
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    # RGB #191a1c
    row = b"\x00" + (b"\x19\x1a\x1c" * width)
    raw = zlib.compress(row * height, level=6)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", raw)
        + chunk(b"IEND", b"")
    )


def render_png_bytes(spec: CardSpec) -> bytes:
    """Render SPEC to 1200x630 PNG bytes via rsvg-convert."""
    rsvg = shutil.which("rsvg-convert")
    if not rsvg:
        if os.environ.get("ETAF_OG_ALLOW_FALLBACK") == "1":
            return _minimal_png_bytes()
        raise RuntimeError(
            "rsvg-convert is required to render OpenGraph cards (install librsvg)"
        )
    svg = build_svg(spec).encode("utf-8")
    proc = subprocess.run(
        [rsvg, "-w", str(WIDTH), "-h", str(HEIGHT), "-f", "png"],
        input=svg,
        capture_output=True,
        check=False,
        timeout=30,
    )
    if proc.returncode != 0 or not proc.stdout.startswith(b"\x89PNG\r\n\x1a\n"):
        stderr = proc.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"rsvg-convert failed (exit {proc.returncode}): {stderr}")
    return proc.stdout


def render_card(spec: CardSpec, output: Path) -> str:
    """Write a 1200x630 PNG card for SPEC to OUTPUT and return its 8-hex SHA-256."""
    data = render_png_bytes(spec)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    return hashlib.sha256(data).hexdigest()[:8]


def render_batch(entries: list[tuple[str, CardSpec, Path]], *,
                 cache_path: Path | None = None,
                 workers: int | None = None) -> dict[str, str]:
    """Render ENTRIES = [(key, spec, output_path), ...] in parallel with digest caching.

    Returns {key: sha256_8hex} for every entry.  When CACHE_PATH already records
    the same spec digest and OUTPUT_PATH exists with matching PNG hash, the card
    is reused without invoking rsvg-convert again.
    """
    prior_cache: dict[str, dict[str, str]] = {}
    if cache_path and cache_path.is_file():
        try:
            loaded = json.loads(cache_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                prior_cache = loaded
        except (OSError, json.JSONDecodeError):
            prior_cache = {}

    hashes: dict[str, str] = {}
    next_cache: dict[str, dict[str, str]] = {}
    todo: list[tuple[str, CardSpec, Path, str]] = []

    for key, spec, output in entries:
        spec_digest = spec.digest()
        cached = prior_cache.get(key)
        if (cached and cached.get("spec") == spec_digest
                and isinstance(cached.get("png"), str)
                and output.is_file()):
            png_hash = hashlib.sha256(output.read_bytes()).hexdigest()[:8]
            if png_hash == cached["png"]:
                hashes[key] = png_hash
                next_cache[key] = {"spec": spec_digest, "png": png_hash}
                continue
        todo.append((key, spec, output, spec_digest))

    if todo:
        max_workers = workers or min(8, max(1, os.cpu_count() or 4))

        def _work(item: tuple[str, CardSpec, Path, str]) -> tuple[str, str, str]:
            key, spec, output, spec_digest = item
            png_hash = render_card(spec, output)
            return key, spec_digest, png_hash

        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            for key, spec_digest, png_hash in pool.map(_work, todo):
                hashes[key] = png_hash
                next_cache[key] = {"spec": spec_digest, "png": png_hash}

    if cache_path:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(
            json.dumps(next_cache, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    return hashes


def render_site_manifest(site_dir: Path, *, output_dir: Path | None = None,
                         manifest_path: Path | None = None,
                         hashes_path: Path | None = None) -> dict[str, str]:
    """Render all cards listed in SITE_DIR/src/og-manifest.json into OUTPUT_DIR.

    Removes stale PNG files under OUTPUT_DIR that are no longer in the manifest,
    and writes KEY -> 8-hex-hash JSON to HASHES_PATH for Astro templates.
    """
    site_dir = site_dir.resolve()
    manifest_file = manifest_path or (site_dir / "src/og-manifest.json")
    out_root = output_dir or (site_dir / "public/og")
    hashes_file = hashes_path or (site_dir / "src/og-hashes.json")
    cache_file = site_dir / ".astro/og-cache.json"

    raw = json.loads(manifest_file.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError(f"Expected a JSON array in {manifest_file}")

    entries: list[tuple[str, CardSpec, Path]] = []
    expected_outputs: set[Path] = set()
    for item in raw:
        key = str(item["key"])
        rel = str(item["output"]).lstrip("/")
        if ".." in Path(rel).parts:
            raise ValueError(f"Unsafe OG card output path: {rel}")
        out_path = (out_root / rel).resolve()
        expected_outputs.add(out_path)
        spec = CardSpec(
            title=str(item["title"]),
            subtitle=str(item.get("subtitle", "")),
            url_label=str(item["url_label"]),
            footer_left=str(item.get("footer_left", "")),
            footer_right=str(item.get("footer_right", "")),
            lang=str(item.get("lang", "en")),
            eyebrow=str(item.get("eyebrow", "")),
        )
        entries.append((key, spec, out_path))

    # Remove stale cards from previous builds.
    if out_root.is_dir():
        for existing in list(out_root.rglob("*.png")):
            if existing.resolve() not in expected_outputs:
                existing.unlink()

    hashes = render_batch(entries, cache_path=cache_file)
    hashes_file.parent.mkdir(parents=True, exist_ok=True)
    hashes_file.write_text(
        json.dumps(hashes, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return hashes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_site = sub.add_parser("site", help="Render all landing and manual cards from src/og-manifest.json")
    p_site.add_argument("--site", type=Path, default=SITE_DIR)
    p_site.add_argument("--output-dir", type=Path, help="Override PNG output directory (default: SITE/public/og)")

    p_one = sub.add_parser("one", help="Render one preview card PNG from CLI flags")
    p_one.add_argument("--output", type=Path, required=True)
    p_one.add_argument("--title", required=True)
    p_one.add_argument("--subtitle", default="")
    p_one.add_argument("--url-label", required=True)
    p_one.add_argument("--footer-left", default="")
    p_one.add_argument("--footer-right", default="")
    p_one.add_argument("--lang", default="en")
    p_one.add_argument("--eyebrow", default="")

    args = parser.parse_args()
    if args.command == "site":
        hashes = render_site_manifest(args.site, output_dir=args.output_dir)
        print(json.dumps({"cards": len(hashes)}, indent=2))
        return 0
    if args.command == "one":
        spec = CardSpec(
            title=args.title,
            subtitle=args.subtitle,
            url_label=args.url_label,
            footer_left=args.footer_left,
            footer_right=args.footer_right,
            lang=args.lang,
            eyebrow=args.eyebrow,
        )
        digest = render_card(spec, args.output)
        print(json.dumps({"output": str(args.output), "sha256_8": digest}, indent=2))
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, RuntimeError) as error:
        print(f"error=og-cards\nhint={error}", file=sys.stderr)
        sys.exit(1)
