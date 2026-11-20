#!/usr/bin/env python3
"""Export registered etaf-ui icon sets as standalone image assets.

Reads the icon registry from a batch Emacs and writes one file per icon.
SVG sets export vector SVG plus raster PNG; font sets export PNG rendered
from the exact installed font.  Also writes an index.html contact sheet.

Usage:
  python3 etaf-ui/scripts/export-icons.py                 # ~/Desktop/etaf-icons
  python3 etaf-ui/scripts/export-icons.py --out DIR
  python3 etaf-ui/scripts/export-icons.py --sets svg,nerd --size 128,256
  python3 etaf-ui/scripts/export-icons.py --color '#1a1a1a' --clean

Exit status is non-zero when the registry cannot be read or a set names no
icon, so the command is usable in a script.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parents[2]
ELISP = WORKSPACE / "scripts" / "elisp.py"
DEFAULT_OUT = Path.home() / "Desktop" / "etaf-icons"
DEFAULT_SIZES = (128, 256)

DUMP_FORM = r"""
(require 'etaf-ui)
(let ((sets nil))
  (dolist (set (etaf-ui-icon-sets))
    (let* ((spec (etaf-ui-icon-set-spec set))
           (kind (plist-get spec :kind))
           (names (let (ns)
                    (dolist (e (plist-get spec :paths)) (push (car e) ns))
                    (dolist (e (plist-get spec :draw)) (push (car e) ns))
                    (dolist (e (plist-get spec :glyphs)) (push (car e) ns))
                    (nreverse ns)))
           (icons nil))
      (dolist (name names)
        (let ((value (if (eq kind 'svg)
                         (or (cdr (assq name (plist-get spec :paths)))
                             (and (cdr (assq name (plist-get spec :draw)))
                                  (funcall (cdr (assq name (plist-get spec :draw))))))
                       (let ((glyph (cdr (assq name (plist-get spec :glyphs)))))
                         (and glyph (format "%x" (string-to-char glyph)))))))
          (push (cons (symbol-name name) (or value "")) icons)))
      (push (list (cons "set" (symbol-name set))
                  (cons "kind" (symbol-name kind))
                  (cons "family" (or (plist-get spec :family) ""))
                  (cons "height" (or (plist-get spec :height) 1))
                  (cons "viewbox" (or (and (plist-get spec :viewbox)
                                           (vconcat (plist-get spec :viewbox)))
                                      []))
                  (cons "icons" (nreverse icons)))
            sets)))
  (princ (json-encode (nreverse sets))))
"""

SVG_DOC = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}"'
    ' viewBox="{viewbox}" fill="none" stroke="{color}" stroke-width="1.4"'
    ' stroke-linecap="round" stroke-linejoin="round">{body}</svg>\n'
)


def read_registry():
    """Return the icon registry as a list of set dictionaries."""
    with tempfile.NamedTemporaryFile("w", suffix=".el", delete=False) as handle:
        handle.write(";;; -*- lexical-binding: t; -*-\n" + DUMP_FORM)
        dump_file = handle.name
    try:
        result = subprocess.run(
            [sys.executable, str(ELISP), "run", "-p", "etaf-ui",
             "-l", dump_file, "--max-output-kb", "1024"],
            cwd=WORKSPACE, capture_output=True, text=True, timeout=180,
        )
    finally:
        Path(dump_file).unlink(missing_ok=True)
    if result.returncode != 0:
        sys.exit("Could not read the icon registry:\n" + (result.stderr or result.stdout))
    # `elisp.py run` prints everything Emacs wrote, warnings included, and adds a
    # `status=ok exit=0 ...` summary after the value, so the JSON array is the
    # one line that starts with a bracket.
    raw = result.stdout
    start = re.search(r"^\[", raw, re.M)
    end = raw.rfind("]")
    if not start or end < start.start():
        sys.exit("Unexpected registry output:\n" + raw[:2000])
    return json.loads(raw[start.start() : end + 1])


GENERIC_FAMILIES = {"monospace", "sans-serif", "serif", "system-ui"}


def font_path(family):
    """Return the installed file for FAMILY, or None when it is absent.

    A generic alias such as monospace accepts whatever fontconfig resolves it
    to; a concrete family must match by name so a missing icon font is not
    silently replaced by unrelated glyphs.
    """
    match = shutil.which("fc-match")
    if not match:
        return None
    probe = subprocess.run(
        [match, "--format", "%{file}\n%{family}\n", family],
        capture_output=True, text=True,
    )
    lines = probe.stdout.splitlines()
    if len(lines) < 2:
        return None
    if lines[1].strip().lower() != family.lower() and family.lower() not in GENERIC_FAMILIES:
        return None
    path = Path(lines[0])
    return path if path.is_file() else None


def render_glyph(font_file, codepoint, size, color):
    """Render one glyph centred on a transparent square of SIZE pixels."""
    from PIL import Image, ImageDraw, ImageFont

    character = chr(codepoint)
    scale = 512
    font = ImageFont.truetype(str(font_file), scale)
    left, top, right, bottom = font.getbbox(character)
    if right <= left or bottom <= top:
        raise ValueError(f"{font_file.name} has no outline for U+{codepoint:04X}")
    canvas = Image.new("L", (scale * 3, scale * 3), 0)
    ImageDraw.Draw(canvas).text(
        (scale - left, scale - top), character, font=font, fill=255
    )
    ink = canvas.getbbox()
    glyph = canvas.crop(ink)
    target = max(1, round(size * 0.86))
    ratio = min(target / glyph.width, target / glyph.height)
    glyph = glyph.resize(
        (max(1, round(glyph.width * ratio)), max(1, round(glyph.height * ratio))),
        Image.LANCZOS,
    )
    rgba = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tinted = Image.new("RGBA", glyph.size, color)
    rgba.paste(tinted, ((size - glyph.width) // 2, (size - glyph.height) // 2), glyph)
    return rgba


def rasterize(svg_path, out_path, size, color):
    """Rasterize SVG_PATH to a PNG of SIZE pixels."""
    converter = shutil.which("rsvg-convert")
    if not converter:
        raise SystemExit("rsvg-convert is required for PNG output: brew install librsvg")
    probe = subprocess.run(
        [converter, "-w", str(size), "-h", str(size), "-o", str(out_path), str(svg_path)],
        capture_output=True, text=True,
    )
    if probe.returncode != 0 or not out_path.is_file():
        raise SystemExit(f"rsvg-convert failed for {svg_path.name}: {probe.stderr.strip()}")


def write_index(out_dir, sets, sizes, color):
    """Write a contact sheet of every exported icon."""
    cells = []
    for entry in sets:
        icons = entry["icons"]
        tiles = "".join(
            f'<figure><img src="png/{entry["set"]}/{sizes[0]}/{name}.png" alt="{name}">'
            f"<figcaption>{name}</figcaption></figure>"
            for name in icons
        )
        cells.append(
            f'<section><h2>{entry["set"]}<span>{entry["kind"]}'
            + (f' · {entry["family"]}' if entry["kind"] == "font" else "")
            + f" · {len(icons)} 个</span></h2>"
            f'<div class="grid dark">{tiles}</div>'
            f'<div class="grid light">{tiles}</div></section>'
        )
    html = f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>ETAF 图标素材</title>
<style>
 body {{ margin: 0; padding: 32px 40px; background: #f6f6f4; color: #16161a;
        font: 14px/1.6 -apple-system, "Helvetica Neue", "PingFang SC", sans-serif; }}
 h1 {{ font-size: 22px; margin: 0 0 4px; }}
 p.meta {{ margin: 0 0 28px; color: #6b6b70; }}
 section {{ margin: 0 0 36px; }}
 h2 {{ font-size: 15px; margin: 0 0 10px; font-weight: 600; }}
 h2 span {{ margin-left: 10px; font-weight: 400; color: #6b6b70; font-size: 13px; }}
 .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr));
          gap: 2px; padding: 14px; border-radius: 10px; }}
 .dark {{ background: #1b1b1f; }}
 .dark figure {{ color: #d8d8dc; }}
 .dark img {{ filter: invert(1); }}
 .light {{ background: #fff; border: 1px solid #e4e4e0; margin-top: 2px; }}
 figure {{ margin: 0; display: flex; flex-direction: column; align-items: center;
           gap: 6px; padding: 8px 2px; }}
 img {{ width: 40px; height: 40px; image-rendering: auto; }}
 figcaption {{ font-size: 10px; letter-spacing: .02em; opacity: .75;
               word-break: break-all; text-align: center; }}
</style></head><body>
<h1>ETAF 图标素材</h1>
<p class="meta">{sum(len(e["icons"]) for e in sets)} 个图标 ·
 {len(sets)} 套 · PNG {", ".join(str(s) for s in sizes)} px · SVG 描边 {color}</p>
{"".join(cells)}
</body></html>
"""
    (out_dir / "index.html").write_text(html, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(
        description="Export etaf-ui icon registry as SVG and PNG assets.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="output directory")
    parser.add_argument("--sets", default="", help="comma separated set names (default: all)")
    parser.add_argument("--size", default=",".join(str(s) for s in DEFAULT_SIZES),
                        help="comma separated PNG sizes in pixels")
    parser.add_argument("--color", default="#111111", help="stroke and glyph colour")
    parser.add_argument("--clean", action="store_true", help="remove the output directory first")
    args = parser.parse_args()

    sizes = [int(s) for s in args.size.split(",") if s.strip()]
    wanted = [s.strip() for s in args.sets.split(",") if s.strip()]
    out_dir = Path(args.out).expanduser()
    if args.clean and out_dir.exists():
        home = Path.home().resolve()
        if out_dir.resolve() in (home, home.parent, Path("/")):
            sys.exit(f"Refusing to remove {out_dir}")
        shutil.rmtree(out_dir)

    registry = read_registry()
    if wanted:
        unknown = sorted(set(wanted) - {e["set"] for e in registry})
        if unknown:
            sys.exit("Unknown icon sets: " + ", ".join(unknown))
        registry = [e for e in registry if e["set"] in wanted]

    written, skipped, exported = 0, [], []
    for entry in registry:
        name = entry["set"]
        kind = entry["kind"]
        icons = [(n, v) for n, v in entry["icons"].items() if v]
        if not icons:
            skipped.append(f"{name} (no glyphs)")
            continue
        family = entry["family"]
        source = None if kind == "svg" else font_path(family)
        if kind != "svg" and source is None:
            skipped.append(f"{name} (font {family!r} not installed)")
            continue

        png_dirs = {size: out_dir / "png" / name / str(size) for size in sizes}
        for png_dir in png_dirs.values():
            png_dir.mkdir(parents=True, exist_ok=True)
        if kind == "svg":
            svg_dir = out_dir / "svg" / name
            svg_dir.mkdir(parents=True, exist_ok=True)
            viewbox = " ".join(str(v) for v in (entry["viewbox"] or [0, 0, 14, 14]))
            for icon, body in icons:
                body = body.replace("currentColor", args.color)
                doc = SVG_DOC.format(size=max(sizes), viewbox=viewbox,
                                     color=args.color, body=body)
                svg_path = svg_dir / f"{icon}.svg"
                svg_path.write_text(doc, encoding="utf-8")
                for size in sizes:
                    rasterize(svg_path, png_dirs[size] / f"{icon}.png", size, args.color)
                written += 1
            exported.append(entry)
        else:
            from PIL import Image

            for icon, hexcode in icons:
                image = render_glyph(source, int(hexcode, 16), max(sizes), args.color)
                for size in sorted(sizes, reverse=True):
                    scaled = image if size == max(sizes) else image.resize(
                        (size, size), Image.LANCZOS)
                    scaled.save(png_dirs[size] / f"{icon}.png")
                written += 1
            exported.append(entry)

    if not written:
        sys.exit("Nothing exported. " + ("; ".join(skipped) if skipped else "Registry empty."))
    write_index(out_dir, exported, sizes, args.color)
    print(f"ok: {written} icons -> {out_dir}")
    print("     png/" + "/".join(e["set"] for e in exported)
          + " + svg (vector sets only) + index.html")
    for line in skipped:
        print(f"skip: {line}", file=sys.stderr)


if __name__ == "__main__":
    main()
