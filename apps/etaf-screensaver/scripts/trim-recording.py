#!/usr/bin/env python3
"""Trim dead frames from a Terminal Text Effects recording (development tool).

A TTE recording usually starts with a blank lead-in and ends with the resolved
text sitting still.  For a screensaver reel that dead time makes the loop look
paused, so this tool can drop leading blank frames and keeps only the moving
part plus a short still tail.  It reads and writes the documented TTEREC
version 1 container directly and needs no Terminal Text Effects installation.

Usage:
  python3 trim-recording.py animation.tterec [--output trimmed.tterec]
      [--skip-blank-lead] [--keep-tail | --hold 0.4] [--min-frames 24]
"""

import argparse
import json
import re
import sys
import zlib
from pathlib import Path

MAGIC = b"TTEREC"
VERSION = 1
SGR = re.compile(r"\x1b\[[0-9;]*m")
RECORD_HEADER = 5


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
        if position + RECORD_HEADER > len(payload):
            raise ValueError("truncated record header")
        tag = payload[position]
        length = int.from_bytes(payload[position + 1:position + 5], "little")
        end = position + RECORD_HEADER + length
        if end > len(payload):
            raise ValueError("truncated record payload")
        records.append((tag, payload[position + RECORD_HEADER:end]))
        position = end
    return records, version


def write_recording(path: Path, version: int, records: list[tuple[int, bytes]]) -> None:
    """Write RECORDS as a TTEREC container to PATH."""
    payload = b"".join(
        bytes([tag]) + len(body).to_bytes(4, "little") + body
        for tag, body in records)
    path.write_bytes(MAGIC + bytes([version]) + zlib.compress(payload))


def blank(frame: str) -> bool:
    """Return non-nil when FRAME has no visible characters."""
    return not SGR.sub("", frame).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--skip-blank-lead", action="store_true",
                        help="drop leading frames without visible characters")
    parser.add_argument("--hold", type=float, default=0.4,
                        help="seconds of the last frame to keep (default 0.4)")
    parser.add_argument("--keep-tail", action="store_true",
                        help="keep the whole still tail; useful when trimming only the lead")
    parser.add_argument("--min-frames", type=int, default=24,
                        help="never keep fewer frames than this (default 24)")
    arguments = parser.parse_args()

    records, version = read_records(arguments.recording)
    header = next((json.loads(body) for tag, body in records if tag == ord("H")), None)
    if not header or not isinstance(header.get("frame_rate"), (int, float)):
        raise ValueError("recording has no valid header")
    frames = [body.decode("utf-8") for tag, body in records if tag == ord("F")]
    if not frames:
        raise ValueError("recording has no frames")
    trailer = [body for tag, body in records if tag == ord("E")]
    if len(trailer) != 1:
        raise ValueError("recording needs exactly one trailer")

    lead = 0
    if arguments.skip_blank_lead:
        while lead < len(frames) and blank(frames[lead]):
            lead += 1
    trimmed = frames[lead:]

    # Compare whole frames: colour-only animation (for example a spotlight
    # sweeping over settled text) is motion too.
    last_change = 0
    previous = trimmed[0]
    for index, frame in enumerate(trimmed[1:], start=1):
        if frame != previous:
            last_change = index
            previous = frame

    hold = max(0, round(arguments.hold * header["frame_rate"]))
    keep = len(trimmed) if arguments.keep_tail else min(
        len(trimmed), max(arguments.min_frames, last_change + 1 + hold))
    kept = trimmed[:keep]
    count = json.dumps({"frame_count": len(kept)}).encode("utf-8")

    output = arguments.output or arguments.recording.with_name(
        arguments.recording.stem + ".trimmed.tterec")
    if output.resolve() == arguments.recording.resolve():
        print(f"{output}: refusing to overwrite the input recording", file=sys.stderr)
        return 1
    if output.exists():
        print(f"{output}: already exists", file=sys.stderr)
        return 1

    before = []
    for tag, body in records:
        if tag == ord("F"):
            break
        if tag != ord("E"):
            before.append((tag, body))
    write_recording(output, version, before + [(ord("F"), frame.encode("utf-8"))
                                                for frame in kept] + [(ord("E"), count)])
    print(f"{arguments.recording.name}: frames={len(frames)} lead={lead} "
          f"last_change={last_change} keep={len(kept)} "
          f"seconds={len(kept) / header['frame_rate']:.1f} -> {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
