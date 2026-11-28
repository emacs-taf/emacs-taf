#!/usr/bin/env python3
"""Bake the bundled poem reels from one typewriter animation (development tool).

Every poem is one line typed at the foot of an 80x24 page, lifted to the
centre, held long enough to read, then faded into the paper.  A blank frame
opens and closes the recording, so the last frame equals the first and a
single poem can loop without a hold or a hard cut.  Frames are written directly
as TTEREC version 1 containers; no Terminal Text Effects installation is
needed.

Usage:
  python3 bake-poems.py [--data scripts/poems.json] [--out lisp/reels]
      [--force] [--hold 2.0] [--fade 0.5] [--rate 20]

Without --force, an existing recording is left untouched and only its reel
spec is refreshed.  The generated `.esr` spec names the recording next to it.
"""

import argparse
import json
import sys
import unicodedata
import zlib
from pathlib import Path

MAGIC = b"TTEREC"
VERSION = 1
WIDTH = 80
HEIGHT = 24
INK_RGB = "#2b3036"
INK = "\x1b[38;2;43;48;54m"
BACKGROUND = "#F4F1EA"
RESET = "\x1b[0m"
BOTTOM = 22
CENTRE = 12
RISE_FRAMES = 18
BOTTOM_HOLD = 3


def display_width(text: str) -> int:
    """Return TEXT's terminal cell width."""
    return sum(2 if unicodedata.east_asian_width(char) in "WF" else 1
               for char in text)


def row(line: str, visible: str, y: int, color: str = INK) -> list[str]:
    """Return the 24 rows of one frame with VISIBLE on row Y."""
    width = display_width(line)
    if width > WIDTH - 4:
        raise ValueError(f"line is too wide for {WIDTH} cells: {line}")
    left = (WIDTH - width) // 2
    blank = " " * WIDTH
    rows = [blank for _ in range(HEIGHT)]
    cells = " " * left + visible
    cells += " " * (WIDTH - display_width(cells))
    rows[y] = f"{color}{cells}{RESET}"
    return rows


def sgr(color: str) -> str:
    """Return the true-colour SGR sequence for a #RRGGBB COLOR."""
    return (f"\x1b[38;2;{int(color[1:3], 16)};"
            f"{int(color[3:5], 16)};{int(color[5:7], 16)}m")


def blank_frame() -> str:
    """Return one frame with an empty 80x24 page."""
    return "\n".join(" " * WIDTH for _ in range(HEIGHT))


def blend(color: str, amount: float) -> str:
    """Blend COLOR toward the paper by AMOUNT and return #RRGGBB."""
    foreground = [int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)]
    paper = [int(BACKGROUND[1:3], 16), int(BACKGROUND[3:5], 16), int(BACKGROUND[5:7], 16)]
    return "#%02x%02x%02x" % tuple(
        round(back + (front - back) * amount)
        for front, back in zip(foreground, paper))


def frames_for(line: str, rate: int, hold: float, fade: float) -> list[str]:
    """Return a loopable typed, lifted, held and faded animation of LINE.

    The first and last frames are empty.  The fade ends at the paper colour,
    so the final visible frame blends into the empty opening frame instead of
    holding a still image or cutting back to the start.
    """
    frames = [blank_frame()]
    for count in range(1, len(line) + 1):
        frames.append("\n".join(row(line, line[:count], BOTTOM)))
    for _ in range(BOTTOM_HOLD):
        frames.append("\n".join(row(line, line, BOTTOM)))
    for step in range(1, RISE_FRAMES + 1):
        y = round(BOTTOM - (BOTTOM - CENTRE) * step / RISE_FRAMES)
        frames.append("\n".join(row(line, line, y)))
    held = max(1, round(hold * rate))
    frames.extend("\n".join(row(line, line, CENTRE)) for _ in range(held))
    faded = max(1, round(fade * rate))
    for step in range(1, faded + 1):
        frames.append("\n".join(row(line, line, CENTRE,
                                    sgr(blend(INK_RGB, 1 - step / faded)))))
    frames.append(blank_frame())
    return frames


def write_recording(path: Path, frames: list[str], rate: int) -> None:
    """Write FRAMES as a TTEREC version 1 recording at PATH."""
    header = json.dumps({"tte_version": "0.15.0", "width": WIDTH,
                         "height": HEIGHT, "frame_rate": rate})
    segment = json.dumps({"effect": "print"})
    trailer = json.dumps({"frame_count": len(frames)})
    records = [(b"H", header.encode()), (b"S", segment.encode())]
    records.extend((b"F", frame.encode()) for frame in frames)
    records.append((b"E", trailer.encode()))
    payload = b"".join(tag + len(body).to_bytes(4, "little") + body
                       for tag, body in records)
    path.write_bytes(MAGIC + bytes([VERSION]) + zlib.compress(payload, 9))


def check_loop(frames: list[str]) -> None:
    """Raise when FRAMES would not close on itself.

    The last frame must equal the first, and the recording must not end with
    more than one repeated frame: that repetition is the still hold a looping
    screensaver must not show.
    """
    if len(frames) < 3:
        raise ValueError("a loop needs at least three frames")
    if frames[0] != frames[-1]:
        raise ValueError("the loop's first and last frames differ")
    if frames[-2] == frames[-1]:
        raise ValueError("the loop ends with a repeated still frame")


def spec(item: dict, count: int, rate: int) -> str:
    """Return the .esr form for ITEM with COUNT frames at RATE."""
    return (";;; -*- lisp-data -*-\n"
            f"(:id {item['id']} :title {json.dumps(item['title'], ensure_ascii=False)}"
            f" :summary {json.dumps(item['summary'], ensure_ascii=False)}"
            " :tags (imported ink poem) :provider tte"
            f" :recording {json.dumps(item['recording'])}"
            f" :kind text :width {WIDTH} :height {HEIGHT} :frame-rate {rate}"
            f" :frame-count {count}"
            f" :source {json.dumps('ink: ' + item['line'], ensure_ascii=False)}"
            " :license \"MIT\" :background \"#F4F1EA\")\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path,
                        default=Path(__file__).with_name("poems.json"))
    parser.add_argument("--out", type=Path,
                        default=Path(__file__).resolve().parent.parent / "lisp/reels")
    parser.add_argument("--force", action="store_true",
                        help="replace existing recordings")
    parser.add_argument("--hold", type=float, default=2.0,
                        help="seconds the settled line is held (default 2.0)")
    parser.add_argument("--fade", type=float, default=0.5,
                        help="seconds the settled line fades into the page (default 0.5)")
    parser.add_argument("--rate", type=int, default=20,
                        help="frames per second (default 20)")
    arguments = parser.parse_args()

    poems = json.loads(arguments.data.read_text())
    arguments.out.mkdir(parents=True, exist_ok=True)
    written = 0
    for item in poems:
        recording = arguments.out / item["recording"]
        reel = arguments.out / item.get(
            "spec", f"{item['recording'][:-len('.tterec')]}.esr")
        if recording.exists() and not arguments.force:
            count = int(reel.read_text().split(":frame-count ", 1)[1].split()[0]) \
                if reel.exists() else 0
            print(f"{recording.name}: exists, keeping {count} frames")
            continue
        frames = frames_for(item["line"], arguments.rate, arguments.hold,
                            arguments.fade)
        check_loop(frames)
        write_recording(recording, frames, arguments.rate)
        reel.write_text(spec(item, len(frames), arguments.rate))
        print(f"{recording.name}: {len(frames)} frames, {len(frames) / arguments.rate:.1f}s")
        written += 1
    print(f"{written}/{len(poems)} recordings written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
