#!/usr/bin/env python3
"""Print fake ffprobe metadata for ETAF native-video contract tests.

Supports both default=nw=1 key=value output (used by etaf-video-source)
and -of json output (used by etaf-video-player-media async inspection).
"""

import json
import os
import sys


def main():
    log = os.environ.get("FAKE_FFPROBE_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as sink:
            sink.write("\0".join(sys.argv[1:]) + "\n")
    width = os.environ.get("FAKE_FFPROBE_WIDTH", "640")
    height = os.environ.get("FAKE_FFPROBE_HEIGHT", "360")
    fps = os.environ.get("FAKE_FFPROBE_FPS", "25/1")
    duration = os.environ.get("FAKE_FFPROBE_DURATION", "2.0")
    has_audio = bool(os.environ.get("FAKE_FFPROBE_AUDIO"))

    if "json" in sys.argv:
        streams = [
            {
                "codec_type": "video",
                "codec_name": "h264",
                "profile": "High",
                "width": int(width),
                "height": int(height),
                "r_frame_rate": fps,
                "avg_frame_rate": fps,
                "pix_fmt": "yuv420p",
                "color_space": "bt709",
                "bit_rate": "4200000",
            }
        ]
        if has_audio:
            streams.append(
                {
                    "codec_type": "audio",
                    "codec_name": "aac",
                    "channels": 2,
                    "channel_layout": "stereo",
                    "sample_rate": "48000",
                    "bit_rate": "192000",
                }
            )
        chapters = []
        raw_chapters = os.environ.get("FAKE_FFPROBE_CHAPTERS")
        if raw_chapters:
            chapters = json.loads(raw_chapters)
        payload = {
            "format": {
                "format_name": "mov,mp4",
                "duration": duration,
                "size": "12582912",
                "bit_rate": "4400000",
            },
            "streams": streams,
            "chapters": chapters,
        }
        print(json.dumps(payload))
    else:
        print("width=%s" % width)
        print("height=%s" % height)
        print("r_frame_rate=%s" % fps)
        print("duration=%s" % duration)
        if has_audio:
            print("index=1")
    return int(os.environ.get("FAKE_FFPROBE_STATUS", "0"))


if __name__ == "__main__":
    sys.exit(main())
