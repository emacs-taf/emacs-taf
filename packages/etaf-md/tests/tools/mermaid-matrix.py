#!/usr/bin/env python3
"""Draw every mermaid fixture through the renderer the preview uses.

This is the tool's own check, separate from any application: it takes the
package's diagram configuration for each page palette, sends the whole matrix
to `backends/mermaid-render.mjs` the way the preview does, and asserts what a
picture must satisfy before an application should trust it:

  * every kind draws, at a size that is not degenerate;
  * a category fill carries the page's ink and stands off the page;
  * the vector copy exists and carries its words as text, not as HTML boxes
    that only a browser can draw;
  * a renderer that is not a browser - here `rsvg-convert`, the engine Emacs
    draws SVG with - paints the same picture: same extent, and a similar amount
    of ink, which is what a missing or shrunken text layer shows up as.

`--keep DIR` writes every picture there so a person can look at them.  The
drawings themselves are judged by eye; this gate only refuses the defects that
have a measurement.

Run it with `make mermaid-check`.
"""
import sys

sys.dont_write_bytecode = True

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "mermaid"
RENDERER = ROOT / "backends" / "mermaid-render.mjs"
PROVIDERS = ("etaf", "etaf-ui", "ebox", "ecss")

PALETTES = ("dark", "light", "sepia")
PAGES = {"dark": "#191a1c", "light": "#ffffff", "sepia": "#f5ecd9"}

# A category fill has to carry the page's ink, and to stand off the page itself:
# mermaid derives both from the box colour by darkening it, which turns every
# slice, branch and period black on a dark page.  A line mermaid paints in the
# same fill - a mind map's branch, a timeline's rule - needs the second number.
LABEL_CONTRAST = 3.0
FILL_CONTRAST = 1.5

# How far the browser's raster and the other renderer may disagree: the extent
# of the drawing, and how much ink it lays down.  A text layer drawn smaller,
# in the wrong face or not at all moves both.
EXTENT_TOLERANCE = 0.03
INK_TOLERANCE = 0.25

CONFIG_PROGRAM = """
(progn
  (require 'etaf-md)
  (let ((env (list :theme (quote {palette}))))
    (princ (json-encode (list :config (etaf-md--mermaid-config env)
                              :palette (etaf-md--typeset-palette env))))))
"""

OVERRIDE_COLOURS = {
    "override-init": "#ff00aa",
    "override-frontmatter": "#00aaff",
}


def luminance(colour):
    def channel(value):
        value = value / 255.0
        return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4

    red, green, blue = (channel(part) for part in colour)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def contrast(first, second):
    high, low = sorted((luminance(first), luminance(second)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def rgb(text):
    text = text.lstrip("#")
    return tuple(int(text[index : index + 2], 16) for index in (0, 2, 4))


def hexed(colour):
    return "#%02x%02x%02x" % colour


def emacs_page(emacs, palette):
    """Return the renderer settings the package generates for PALETTE.

The renderer receives the page's palette beside mermaid's configuration, so a
family that writes its own colours is told the page's rather than reading them
out of mermaid's vocabulary."""
    load_path = ["-L", str(ROOT / "lisp")]
    for name in PROVIDERS:
        load_path += ["-L", str(ROOT.parent / name)]
    command = [emacs, "-Q", "--batch", *load_path, "-L", str(ROOT),
               "--eval", "(setq load-prefer-newer t)",
               "--eval", CONFIG_PROGRAM.format(palette=palette)]
    run = subprocess.run(command, capture_output=True, text=True, timeout=300)
    if run.returncode != 0:
        raise SystemExit("Emacs could not build the %s configuration:\n%s"
                         % (palette, run.stderr.strip()))
    try:
        return json.loads(run.stdout.strip())
    except ValueError:
        raise SystemExit("Emacs did not answer with a JSON page for %s:\n%s"
                         % (palette, run.stdout.strip()[:400]))


def draw(requests, outdir):
    """Send REQUESTS to one renderer and return its answers by id."""
    lines = [json.dumps(request, ensure_ascii=False) for request in requests]
    run = subprocess.run(["node", str(RENDERER)], input="\n".join(lines) + "\n",
                         capture_output=True, text=True, timeout=1800)
    answers = {}
    for line in run.stdout.splitlines():
        try:
            reply = json.loads(line)
        except ValueError:
            continue
        if isinstance(reply.get("id"), int):
            answers[reply["id"]] = reply
    if len(answers) != len(requests):
        raise SystemExit("the renderer answered %d of %d requests:\n%s"
                         % (len(answers), len(requests), run.stderr.strip()[-2000:]))
    return answers


def page_image(image, page):
    """Return IMAGE composited onto PAGE, so transparent margins are the page."""
    rgba = image.convert("RGBA")
    return Image.alpha_composite(Image.new("RGBA", rgba.size, page + (255,)), rgba).convert("RGB")


def ink(image):
    """Return the extent of everything that is not the page colour."""
    flat = image.convert("RGB")
    page = Image.new("RGB", flat.size, flat.getpixel((0, 0)))
    box = ImageChops.difference(flat, page).getbbox()
    return None if box is None else (box[2] - box[0], box[3] - box[1])


def inked(image):
    """Return how many pixels differ from the page colour."""
    flat = image.convert("RGB")
    page = Image.new("RGB", flat.size, flat.getpixel((0, 0)))
    return sum(1 for value in ImageChops.difference(flat, page).convert("L").getdata() if value)


def check_colours(palette, config, page):
    """Return the problems with the configuration's categorical colours."""
    try:
        variables = config["themeVariables"]
    except (KeyError, TypeError):
        return ["%s: configuration is not a JSON object" % palette]
    ink_colour = rgb(variables["textColor"])
    problems = []
    fills = []
    for index in range(6):
        fill = rgb(variables["cScale%d" % index])
        hue = rgb(variables["cScaleInv%d" % index])
        label = rgb(variables["cScaleLabel%d" % index])
        fills.append(fill)
        if contrast(label, fill) < LABEL_CONTRAST:
            problems.append("%s: cScale%d label reads %.1f:1 on its fill"
                            % (palette, index, contrast(label, fill)))
        if contrast(fill, rgb(page)) < FILL_CONTRAST:
            problems.append("%s: cScale%d fill is the page (%.2f:1)"
                            % (palette, index, contrast(fill, rgb(page))))
        if contrast(hue, rgb(page)) < FILL_CONTRAST:
            problems.append("%s: cScaleInv%d line is the page" % (palette, index))
        for other in ("pie%d" % (index + 1), "git%d" % index):
            if rgb(variables[other]) != fill:
                problems.append("%s: %s left the categorical series"
                                % (palette, other))
        # The label need not be the page's body ink: on a saturated fill the
        # page colour reads better, and the generator picks whichever does.
        if label not in (ink_colour, rgb(page)):
            problems.append("%s: cScaleLabel%d is neither of the page's inks"
                            % (palette, index))
    for index, fill in enumerate(fills[1:], start=1):
        if fill == fills[index - 1]:
            problems.append("%s: cScale%d repeats the previous fill"
                            % (palette, index - 1))
    return problems


def check_vector(name, raster, vector):
    """Return the problems with a diagram's vector copy."""
    problems = []
    text = vector.read_text()
    if "<foreignObject" in text:
        problems.append("%s: the vector keeps an HTML label" % name)
    if not re.search(r"<text[ >]", text):
        problems.append("%s: the vector carries no text" % name)
    box = re.search(r'viewBox="([-\d.\s,]+)"', text)
    width = re.search(r'\bwidth="([\d.]+)"', text)
    height = re.search(r'\bheight="([\d.]+)"', text)
    if not (box and width and height):
        problems.append("%s: the vector declares no size" % name)
        return problems
    _, _, box_width, box_height = (float(part) for part in re.split(r"[\s,]+", box.group(1).strip()))
    drawn = Image.open(raster).size
    # The vector is placed at the size the raster was taken in, which a picture
    # wider than the drawing area is scaled down from.
    declared = (float(width.group(1)), float(height.group(1)))
    if abs(declared[0] - drawn[0]) > 2 or abs(declared[1] - drawn[1]) > 2:
        problems.append("%s: the vector is declared %gx%g but the raster is %dx%d"
                        % (name, declared[0], declared[1], drawn[0], drawn[1]))
    if abs(declared[0] / declared[1] - box_width / box_height) > 0.02:
        problems.append("%s: the picture's shape leaves the drawing's" % name)
    return problems


def check_agreement(name, raster, vector, workdir, rsvg, palette):
    """Return the problems with another renderer's drawing of the vector."""
    if rsvg is None:
        return []
    size = Image.open(raster).size
    out = workdir / ("%s-rsvg.png" % name.replace("/", "-"))
    run = subprocess.run([rsvg, "-w", str(size[0]), "-h", str(size[1]),
                          "--background-color", PAGES[palette],
                          "-o", str(out), str(vector)],
                         capture_output=True, text=True, timeout=300)
    if not out.exists():
        return ["%s: rsvg could not draw the vector: %s"
                % (name, run.stderr.strip()[:160])]
    browser = page_image(Image.open(raster), rgb(PAGES[palette]))
    other = Image.open(out).convert("RGB")
    if other.size != browser.size:
        other = other.resize(browser.size)
    problems = []
    first, second = ink(browser), ink(other)
    if first is None or second is None:
        return ["%s: one renderer drew nothing" % name]
    for index, side in enumerate("wh"):
        if abs(first[index] - second[index]) > max(6, EXTENT_TOLERANCE * first[index]):
            problems.append("%s: the extent differs by %+d px (%s)"
                            % (name, second[index] - first[index], side))
    counts = (inked(browser), inked(other))
    if counts[0] and abs(counts[1] - counts[0]) / counts[0] > INK_TOLERANCE:
        problems.append("%s: another renderer lays down %d of %d inked pixels"
                        % (name, counts[1], counts[0]))
    return problems


def check_repeat(name, first, second):
    """Return the problems with two drawings of one source disagreeing."""
    if first.size != second.size:
        return ["%s: the second drawing is %dx%d, the first %dx%d"
                % (name, second.size[0], second.size[1], first.size[0], first.size[1])]
    one = first.convert("RGB")
    two = second.convert("RGB")
    difference = sum(ImageChops.difference(one, two)
                     .convert("L").tobytes())
    mean = difference / float(one.size[0] * one.size[1])
    if mean > 2.0:
        return ["%s: the second drawing differs from the first (mean %0.1f)"
                % (name, mean)]
    return []


def check_override(name, colour, image):
    """Return the problems with a document that sets its own diagram colour."""
    wants = rgb(colour)
    flat = image.convert("RGB")
    page = flat.getpixel((0, 0))
    drawn = [(count, pixel) for count, pixel in flat.getcolors(1 << 24) if pixel != page]
    if not drawn:
        return ["%s: nothing drawn" % name]
    common = max(drawn)[1]
    if common != wants:
        return ["%s: document colour %s lost to %s"
                % (name, colour, hexed(common))]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emacs", default=os.environ.get("EMACS", "emacs"))
    parser.add_argument("--only", nargs="*", help="fixture names to draw")
    parser.add_argument("--keep", help="write the pictures to this directory")
    parser.add_argument("--list", action="store_true", help="print the fixtures")
    arguments = parser.parse_args()

    fixtures = sorted(FIXTURES.glob("*.mmd"))
    if arguments.only:
        fixtures = [path for path in fixtures if path.stem in arguments.only]
    if arguments.list:
        for path in fixtures:
            print(path.stem)
        return 0
    if not RENDERER.exists():
        raise SystemExit("%s is missing" % RENDERER)

    rsvg = shutil.which("rsvg-convert")
    failures = []
    with tempfile.TemporaryDirectory(prefix="mermaid-matrix-") as temporary:
        workdir = Path(temporary)
        kept = Path(arguments.keep) if arguments.keep else None
        if kept:
            kept.mkdir(parents=True, exist_ok=True)

        requests, index = [], 0
        # Every drawing is asked for twice.  A diagram measured before the page
        # resolved the reader's face comes out with labels their boxes were not
        # cut for, and only the first drawing on a page pays that cost: the
        # second request of the same source is what exposes it.
        for palette in PALETTES:
            page = emacs_page(arguments.emacs, palette)
            parsed = json.loads(page["config"])
            problems = check_colours(palette, parsed, PAGES[palette])
            for problem in problems:
                print("FAIL %s" % problem)
            failures += problems
            for pass_number in (1, 2):
                for fixture in fixtures:
                    stem = fixture.stem
                    name = "%s-%s.png" % (palette, stem)
                    if pass_number == 2:
                        name = "%s-%s-again.png" % (palette, stem)
                    requests.append({
                        "id": index,
                        "kind": "mermaid",
                        "source": fixture.read_text(),
                        "out": str(workdir / name),
                        "config": page["config"],
                        "palette": page["palette"],
                    })
                    index += 1

        answers = draw(requests, workdir)
        for request in requests:
            answer = answers[request["id"]]
            palette = PALETTES[request["id"] // max(1, 2 * len(fixtures))]
            stem = Path(request["out"]).stem.split("-", 1)[1]
            if stem.endswith("-again"):
                stem = stem[: -len("-again")]
            name = "%s/%s" % (palette, stem)
            if not answer.get("ok"):
                failures.append("%s: %s" % (name, answer.get("error", "no reason")))
                print("FAIL %-26s %s" % (name, answer.get("error", "")))
                continue
            raster = Path(request["out"])
            vector = raster.with_suffix(".svg")
            problems = []
            if vector.exists():
                problems += check_vector(name, raster, vector)
                problems += check_agreement(name, raster, vector, workdir, rsvg, palette)
            elif answer.get("vector", True):
                problems += ["%s: the vector copy is missing" % name]
            image = Image.open(raster)
            extent = ink(page_image(image, rgb(PAGES[palette])))
            if image.size[0] < 100 or image.size[1] < 60:
                problems.append("%s: degenerate %dx%d" % (name, *image.size))
            elif extent is None or extent[0] < 8 or extent[1] < 8:
                problems.append("%s: nothing drawn" % name)
            if stem in OVERRIDE_COLOURS and not raster.stem.endswith("-again"):
                problems += check_override(name, OVERRIDE_COLOURS[stem], image)
            again = raster.with_name(raster.stem + "-again.png")
            if again.exists():
                problems += check_repeat(name, image, Image.open(again))
            for problem in problems:
                print("FAIL %s" % problem)
            failures += problems
            if not problems and not raster.stem.endswith("-again"):
                print("ok   %-26s %4dx%-4d %s ink %s"
                      % (name, *image.size, "svg" if vector.exists() else "png",
                         "%dx%d" % extent if extent else "-"))
            if kept:
                shutil.copyfile(raster, kept / raster.name)
                if vector.exists():
                    shutil.copyfile(vector, kept / vector.name)

    if failures:
        print("\n%d mermaid checks failed" % len(failures))
        return 1
    print("\nmermaid matrix ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
