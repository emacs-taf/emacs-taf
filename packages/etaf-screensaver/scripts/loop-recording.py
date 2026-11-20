#!/usr/bin/env python3
"""Close an imported TTEREC recording into a fade-in/fade-out loop.

An external recording usually starts at full strength and ends on a still or
resolved frame.  A screensaver that repeats it needs the last frame to meet
the first.  This tool keeps the recorded motion, wraps it in a short blank
and colour fade at each end, and writes a TTEREC version 1 file whose first
and last frames are identical.  It reads and writes TTEREC directly, so it
needs no Terminal Text Effects installation.

Usage:
  python3 loop-recording.py recording.tterec [--output looped.tterec]
      [--fade 0.35] [--background 05070B]
"""

import argparse
import re
import sys
import zlib
from pathlib import Path

MAGIC = b"TTEREC"
VERSION = 1
SGR = re.compile(r"\x1b\[38;2;(\d+);(\d+);(\d+)m")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def read_records(path: Path) -> tuple[list[tuple[int, bytes]], int]:
    """Return PATH's decompressed records and its container version."""
    data = path.read_bytes()
    if not data.startswith(MAGIC):
        raise ValueError("not a TTE recording")
    version = data[len(MAGIC)]
    if version != VERSION:
        raise ValueError(f"unsupported TTE recording version {version}")
    payload = zlib.decompress(data[len(MAGIC) + 1:])
    records = []
    position = 0
    while position < len(payload):
        if position + 5 > len(payload):
            raise ValueError("truncated record header")
        tag = payload[position]
        length = int.from_bytes(payload[position + 1:position + 5], "little")
        end = position + 5 + length
        if end > len(payload):
            raise ValueError("truncated record payload")
        records.append((tag, payload[position + 5:end]))
        position = end
    return records, version


def write_recording(path: Path, version: int, records: list[tuple[int, bytes]]) -> None:
    """Write RECORDS as a TTEREC container to PATH."""
    payload = b"".join(
        bytes([tag]) + len(body).to_bytes(4, "little") + body
        for tag, body in records)
    path.write_bytes(MAGIC + bytes([version]) + zlib.compress(payload, 9))


def blend(frame: str, amount: float, background: tuple[int, int, int]) -> str:
    """Return FRAME with every true-colour run blended toward BACKGROUND.

    AMOUNT 1 keeps the recorded colour; 0 gives the page background.  Other
    SGR runs, including resets, are left alone.
    """
    def replace(match: re.Match[str]) -> str:
        rgb = [int(match.group(index)) for index in (1, 2, 3)]
        mixed = [round(back + (front - back) * amount)
                 for front, back in zip(rgb, background)]
        return f"\x1b[38;2;{mixed[0]};{mixed[1]};{mixed[2]}m"

    return SGR.sub(replace, frame)


def blank_frame(frame: str) -> str:
    """Return a visually empty frame with FRAME's dimensions."""
    rows = frame.split("\n")
    return "\n".join(" " * len(ANSI.sub("", row)) for row in rows)


def loop_frames(frames: list[str], fade: int, background: tuple[int, int, int]) -> list[str]:
    """Wrap FRAMES in a closed fade and return the loopable frame list."""
    blank = blank_frame(frames[0])
    start = [blank]
    start.extend(blend(frames[0], step / fade, background)
                 for step in range(1, fade + 1))
    end = [blend(frames[-1], step / fade, background)
           for step in range(fade - 1, 0, -1)]
    end.append(blank)
    return start + frames[1:] + end


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fade", type=float, default=0.35,
                        help="seconds of fade at each end (default 0.35)")
    parser.add_argument("--background", default="05070B",
                        help="page background as 6 hex digits (default 05070B)")
    arguments = parser.parse_args()

    records, version = read_records(arguments.recording)
    header = next((body for tag, body in records if tag == ord("H")), None)
    if not header:
        raise ValueError("recording has no header")
    import json
    info = json.loads(header)
    rate = info.get("frame_rate")
    if not isinstance(rate, (int, float)) or rate <= 0:
        raise ValueError("recording has no valid frame rate")
    frames = [body.decode("utf-8") for tag, body in records if tag == ord("F")]
    trailer = [body for tag, body in records if tag == ord("E")]
    if not frames or len(trailer) != 1:
        raise ValueError("recording needs frames and exactly one trailer")
    if len(arguments.background) != 6:
        raise ValueError("--background must be six hex digits")
    background = tuple(int(arguments.background[index:index + 2], 16)
                       for index in (0, 2, 4))
    fade = max(1, round(arguments.fade * rate))
    looped = loop_frames(frames, fade, background)
    if looped[0] != looped[-1]:
        raise ValueError("generated loop does not close")
    if looped[-2] == looped[-1]:
        raise ValueError("generated loop ends with a still frame")

    output = arguments.output or arguments.recording.with_name(
        arguments.recording.stem + ".loop.tterec")
    if output.resolve() == arguments.recording.resolve():
        print(f"{output}: refusing to overwrite the input recording", file=sys.stderr)
        return 1
    if output.exists():
        print(f"{output}: already exists", file=sys.stderr)
        return 1

    before = [(tag, body) for tag, body in records if tag not in (ord("F"), ord("E"))]
    count = json.dumps({"frame_count": len(looped)}).encode("utf-8")
    write_recording(output, version, before
                    + [(ord("F"), frame.encode("utf-8")) for frame in looped]
                    + [(ord("E"), count)])
    print(f"{arguments.recording.name}: frames={len(frames)} "
          f"fade={fade} loop={len(looped)} "
          f"seconds={len(looped) / rate:.1f} -> {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
