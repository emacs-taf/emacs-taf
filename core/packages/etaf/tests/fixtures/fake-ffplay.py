#!/usr/bin/env python3
"""Stand in for the ffplay audio sidecar in ETAF native-video tests.

Records its argv and process id to FAKE_FFPLAY_LOG and stays resident like a
playing audio loop until the session terminates it.  Audio content itself is
deliberately absent: the public suite verifies sidecar lifecycle, position and
volume arguments without making sound.

Environment:
  FAKE_FFPLAY_LOG   append the received argv as one JSON array and
                    `pid=...' here, one run each
"""

import json
import os
import signal
import sys
import time


def main():
    log = os.environ.get("FAKE_FFPLAY_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as sink:
            sink.write(json.dumps(sys.argv[1:]) + "\n")
            sink.write("pid=%d\n" % os.getpid())
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if os.environ.get("FAKE_FFPLAY_STATS"):
        nan_ms = int(os.environ.get("FAKE_FFPLAY_NAN_MS", "200"))
        start = float(os.environ.get("FAKE_FFPLAY_START", "10.0"))
        t0 = time.monotonic()
        while (time.monotonic() - t0) * 1000.0 < nan_ms:
            sys.stderr.write("    nan    :  0.000 fd=   0 aq=    0KB vq=    0KB sq=    0B \r")
            sys.stderr.flush()
            time.sleep(0.03)
        t_live = time.monotonic()
        while time.monotonic() - t0 < 60.0:
            clk = start + (time.monotonic() - t_live)
            sys.stderr.write("%7.2f M-A:  0.000 fd=   0 aq=   18KB vq=    0KB sq=    0B \r" % clk)
            sys.stderr.flush()
            time.sleep(0.03)
        return 0
    time.sleep(60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
