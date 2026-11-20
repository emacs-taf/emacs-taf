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
    time.sleep(60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
