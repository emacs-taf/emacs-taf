#!/usr/bin/env python3
"""Print fake ffprobe metadata for ETAF native-video contract tests.

The default=nw=1 format the video source requests is a list of key=value
lines; this fixture produces that exact shape from the environment so
metadata handling can be tested without ffprobe installed.

Environment:
  FAKE_FFPROBE_LOG       append the received argv here, one line per run
  FAKE_FFPROBE_WIDTH, FAKE_FFPROBE_HEIGHT, FAKE_FFPROBE_FPS,
  FAKE_FFPROBE_DURATION   video values to print
  FAKE_FFPROBE_AUDIO      print an audio stream index when set
  FAKE_FFPROBE_STATUS     exit status (default 0)
"""

import os
import sys


def main():
    log = os.environ.get("FAKE_FFPROBE_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as sink:
            sink.write("\0".join(sys.argv[1:]) + "\n")
    print("width=%s" % os.environ.get("FAKE_FFPROBE_WIDTH", "640"))
    print("height=%s" % os.environ.get("FAKE_FFPROBE_HEIGHT", "360"))
    print("r_frame_rate=%s" % os.environ.get("FAKE_FFPROBE_FPS", "25/1"))
    print("duration=%s" % os.environ.get("FAKE_FFPROBE_DURATION", "2.0"))
    if os.environ.get("FAKE_FFPROBE_AUDIO"):
        print("index=1")
    return int(os.environ.get("FAKE_FFPROBE_STATUS", "0"))


if __name__ == "__main__":
    sys.exit(main())
