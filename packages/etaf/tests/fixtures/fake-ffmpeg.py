#!/usr/bin/env python3
"""Emit synthetic frames for ETAF native-video contract tests.

The video source invokes ffmpeg with the documented argv; this fixture
accepts that argv, optionally records it to FAKE_FFMPEG_LOG (one NUL-joined
line per run), and emits width*height gray or RGB24 bytes per frame, or one
complete JPEG per frame.  Real decoding is deliberately absent: the public
suite exercises the Emacs process, frame mapping and retained publication
path without ffmpeg; only the GUI workflow runs real ffmpeg.

Environment:
  FAKE_FFMPEG_LOG       append the received argv here as one JSON array
                        per run
  FAKE_FFMPEG_FRAMES    frame count (default 40)
  FAKE_FFMPEG_INTERVAL  seconds between frames (default 0.02)
  FAKE_FFMPEG_PATTERN   columns (default), shift or flash
  FAKE_FFMPEG_WIDTH     override the parsed scale width
  FAKE_FFMPEG_HEIGHT    override the parsed scale height
"""

import base64
import json
import os
import re
import sys
import time

JPEG_FRAME = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a"
    "HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA"
    "AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=="
)


def value_for(pattern, x, width, index):
    """Return the deterministic pattern value for one pixel."""
    span = max(1, width - 1)
    if pattern == "flash":
        return 255 if index % 2 == 0 else 0
    if pattern == "shift":
        return ((x + index) % width) * 255 // span
    return x * 255 // span


def main():
    argv = sys.argv[1:]
    log = os.environ.get("FAKE_FFMPEG_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as sink:
            sink.write(json.dumps(argv) + "\n")

    width = height = None
    for argument in argv:
        match = re.fullmatch(r"scale=(\d+):(\d+)(?::flags=\w+)?", argument)
        if match:
            width, height = int(match.group(1)), int(match.group(2))
    width = int(os.environ.get("FAKE_FFMPEG_WIDTH", str(width or 16)))
    height = int(os.environ.get("FAKE_FFMPEG_HEIGHT", str(height or 4)))
    frames = int(os.environ.get("FAKE_FFMPEG_FRAMES", "40"))
    interval = float(os.environ.get("FAKE_FFMPEG_INTERVAL", "0.02"))
    pattern = os.environ.get("FAKE_FFMPEG_PATTERN", "columns")
    pixel_format = "gray"
    for index, argument in enumerate(argv):
        if argument == "-pix_fmt" and index + 1 < len(argv):
            pixel_format = argv[index + 1]
    graphics = "mjpeg" in argv or "image2pipe" in argv

    out = sys.stdout.buffer
    for frame_index in range(frames):
        if graphics:
            # Image mode consumes complete JPEG frames delimited by SOI/EOI.
            out.write(JPEG_FRAME)
            out.flush()
            if interval > 0:
                time.sleep(interval)
            continue
        frame = bytearray()
        for y in range(height):
            row = bytearray()
            for x in range(width):
                value = value_for(pattern, x, width, frame_index)
                if pixel_format == "rgb24":
                    # Even scanlines carry the value in gray; odd scanlines
                    # invert red and keep blue, so a half-block cell has two
                    # distinguishable colors.
                    if y % 2 == 0:
                        row.extend((value, value, value))
                    else:
                        row.extend((255 - value, 0, value))
                else:
                    row.append(value)
            frame.extend(row)
        out.write(bytes(frame))
        out.flush()
        if interval > 0:
            time.sleep(interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
