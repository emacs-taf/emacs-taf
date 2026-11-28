#!/bin/sh

# Select an owned frame each time: fullscreen transitions can replace its
# WindowServer ID.  Never fall back to capturing the desktop.
set -eu

usage() {
    echo "usage: $0 --window-id PID | -x OUTPUT" >&2
    exit 2
}

window_id() {
    case $1 in
        ''|*[!0-9]*) echo "invalid Emacs capture PID: $1" >&2; return 1 ;;
    esac
    [ "$1" -gt 1 ] && kill -0 "$1" 2>/dev/null || {
        echo "Emacs capture process is not alive: $1" >&2
        return 1
    }
    osascript -l JavaScript - "$1" <<'JXA'
ObjC.import("CoreGraphics");
function run(argv) {
    var pid = Number(argv[0]);
    var windows = ObjC.deepUnwrap(ObjC.castRefToObject(
        $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll,
                                    $.kCGNullWindowID)));
    var candidates = windows.filter(function (window) {
        var bounds = window.kCGWindowBounds;
        return window.kCGWindowOwnerPID === pid &&
            window.kCGWindowOwnerName === "Emacs" &&
            window.kCGWindowLayer === 0 && window.kCGWindowAlpha > 0 &&
            window.kCGWindowName && bounds &&
            bounds.Width > 0 && bounds.Height > 0;
    });
    candidates.sort(function (a, b) {
        return b.kCGWindowBounds.Width * b.kCGWindowBounds.Height -
            a.kCGWindowBounds.Width * a.kCGWindowBounds.Height;
    });
    if (!candidates.length) {
        throw new Error("No named Emacs frame owned by PID " + pid);
    }
    if (candidates.length > 1 &&
        candidates[0].kCGWindowBounds.Width * candidates[0].kCGWindowBounds.Height ===
        candidates[1].kCGWindowBounds.Width * candidates[1].kCGWindowBounds.Height) {
        throw new Error("Ambiguous largest Emacs frame for PID " + pid);
    }
    return String(candidates[0].kCGWindowNumber);
}
JXA
}

# Linux has no per-window identifiers for this tool: the engine passes the
# selected frame's X11 rectangle as X,Y,W,H and ffmpeg grabs exactly that.
capture_linux() {
    GUI_LINUX_OUTPUT=$1
    GUI_LINUX_DISPLAY=${DISPLAY:-}
    [ -n "$GUI_LINUX_DISPLAY" ] || {
        echo "DISPLAY is required for Linux window capture" >&2
        exit 1
    }
    GUI_LINUX_GEOMETRY=${ETAF_GUI_CAPTURE_GEOMETRY:-}
    GUI_LINUX_SAVED_IFS=$IFS
    IFS=,
    # shellcheck disable=SC2086
    set -- $GUI_LINUX_GEOMETRY
    IFS=$GUI_LINUX_SAVED_IFS
    [ "$#" -eq 4 ] || {
        echo "ETAF_GUI_CAPTURE_GEOMETRY must be X,Y,W,H: ${GUI_LINUX_GEOMETRY:-<unset>}" >&2
        exit 2
    }
    GUI_LINUX_X=$1
    GUI_LINUX_Y=$2
    GUI_LINUX_WIDTH=$3
    GUI_LINUX_HEIGHT=$4
    for GUI_LINUX_VALUE in "$GUI_LINUX_X" "$GUI_LINUX_Y" "$GUI_LINUX_WIDTH" "$GUI_LINUX_HEIGHT"; do
        case $GUI_LINUX_VALUE in
            ''|*[!0-9]*)
                echo "ETAF_GUI_CAPTURE_GEOMETRY must be X,Y,W,H: $GUI_LINUX_GEOMETRY" >&2
                exit 2
                ;;
        esac
    done
    [ "$GUI_LINUX_WIDTH" -gt 0 ] && [ "$GUI_LINUX_HEIGHT" -gt 0 ] || {
        echo "empty capture rectangle: $GUI_LINUX_GEOMETRY" >&2
        exit 2
    }
    GUI_LINUX_FFMPEG=$(command -v ffmpeg 2>/dev/null) || {
        echo "ffmpeg is required for Linux window capture" >&2
        exit 1
    }
    "$GUI_LINUX_FFMPEG" -loglevel error -y -f x11grab \
        -video_size "${GUI_LINUX_WIDTH}x${GUI_LINUX_HEIGHT}" \
        -i "$GUI_LINUX_DISPLAY+$GUI_LINUX_X,$GUI_LINUX_Y" \
        -frames:v 1 \
        "$GUI_LINUX_OUTPUT"
}

[ "$#" -eq 2 ] || usage
case $1 in
    --window-id)
        if [ "$(uname -s)" = Darwin ]; then
            window_id "$2"
        else
            echo "window identifiers are only available on macOS" >&2
            exit 1
        fi
        ;;
    -x)
        GUI_CAPTURE_PID=${ETAF_GUI_CAPTURE_PID:?ETAF_GUI_CAPTURE_PID is required}
        case $(uname -s) in
            Darwin)
                GUI_CAPTURE_ID=$(window_id "$GUI_CAPTURE_PID")
                GUI_CAPTURE_BIN=${ETAF_GUI_SCREENCAPTURE:-/usr/sbin/screencapture}
                "$GUI_CAPTURE_BIN" -l "$GUI_CAPTURE_ID" -o -x "$2"
                # Reject a capture made while macOS replaced the intended frame.
                GUI_CAPTURE_AFTER=$(window_id "$GUI_CAPTURE_PID")
                if [ "$GUI_CAPTURE_ID" != "$GUI_CAPTURE_AFTER" ]; then
                    rm -f -- "$2"
                    echo "Emacs frame changed during screenshot; capture again" >&2
                    exit 1
                fi
                ;;
            Linux) capture_linux "$2" ;;
            *)
                echo "unsupported platform: $(uname -s)" >&2
                exit 1
                ;;
        esac
        ;;
    *) usage ;;
esac
