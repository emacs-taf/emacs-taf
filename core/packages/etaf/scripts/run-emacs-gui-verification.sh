#!/bin/sh

set -eu

GUI_CORE_SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
GUI_ENGINE="$GUI_CORE_SCRIPT_DIR/emacs-gui-verifier.el"
GUI_RECORDER_SOURCE="$GUI_CORE_SCRIPT_DIR/record-emacs-window.swift"
GUI_CAPTURE="$GUI_CORE_SCRIPT_DIR/capture-emacs-window.sh"
GUI_EMACS_APP=${EMACS_APP:-/Applications/Emacs.app}
GUI_EMACS_BIN="$GUI_EMACS_APP/Contents/MacOS/Emacs"
GUI_EMACSCLIENT="$GUI_EMACS_APP/Contents/MacOS/bin/emacsclient"
GUI_CODEX_ROOT=${CODEX_HOME:-${HOME}/.codex}
GUI_DYNAMIC_SKILL=${EMACS_DYNAMIC_UI_SKILL_DIR:-$GUI_CODEX_ROOT/skills/emacs-dynamic-ui-verification}
GUI_EVIDENCE_PY="$GUI_DYNAMIC_SKILL/scripts/evidence.py"

usage() {
    echo "usage:" >&2
    echo "  $0 doctor" >&2
    echo "  $0 review RUN_DIR" >&2
    echo "  $0 run ADAPTER_EL ENTRY_FUNCTION [--initialize-function FUNCTION] [--run-dir DIR] [--load-path DIR]..." >&2
    exit 2
}

require_file() {
    [ -f "$1" ] || {
        echo "required file is missing: $1" >&2
        exit 1
    }
}

doctor() {
    require_file "$GUI_EMACS_BIN"
    require_file "$GUI_EMACSCLIENT"
    require_file "$GUI_ENGINE"
    require_file "$GUI_RECORDER_SOURCE"
    require_file "$GUI_CAPTURE"
    require_file "$GUI_EVIDENCE_PY"
    command -v osascript >/dev/null 2>&1
    xcrun --find swiftc >/dev/null 2>&1
    command -v ffmpeg >/dev/null 2>&1
    command -v python3 >/dev/null 2>&1
    echo "EMACS-GUI-VERIFIER DOCTOR PASS"
}

review_run() {
    [ "$#" -eq 1 ] || usage
    GUI_REVIEW_DIR=$1
    require_file "$GUI_REVIEW_DIR/manifest.jsonl"
    require_file "$GUI_REVIEW_DIR/recording.mov"
    python3 "$GUI_EVIDENCE_PY" finalize \
        --run-dir "$GUI_REVIEW_DIR" --temporal-reviewed
}

GUI_DAEMON=""
GUI_DAEMON_PID=""
GUI_RECORDER_PID=""
GUI_DAEMON_STARTED=false

valid_pid() {
    case $1 in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 1 ] ;;
    esac
}

process_alive() {
    valid_pid "$1" && kill -0 "$1" 2>/dev/null
}

wait_for_exit() {
    GUI_WAIT_PID=$1
    GUI_WAIT_LIMIT=$2
    GUI_WAIT_ATTEMPT=0
    while process_alive "$GUI_WAIT_PID"; do
        [ "$GUI_WAIT_ATTEMPT" -lt "$GUI_WAIT_LIMIT" ] || return 1
        sleep 0.1
        GUI_WAIT_ATTEMPT=$((GUI_WAIT_ATTEMPT + 1))
    done
}

force_owned_exit() {
    GUI_FORCE_PID=$1
    GUI_FORCE_LABEL=$2
    process_alive "$GUI_FORCE_PID" || return 0
    echo "forcing owned $GUI_FORCE_LABEL process to exit: $GUI_FORCE_PID" >&2
    kill -TERM "$GUI_FORCE_PID" 2>/dev/null || return 1
    if ! wait_for_exit "$GUI_FORCE_PID" 20; then
        kill -KILL "$GUI_FORCE_PID" 2>/dev/null || return 1
        wait_for_exit "$GUI_FORCE_PID" 10 || return 1
    fi
    return 0
}

stop_recorder() {
    [ -n "$GUI_RECORDER_PID" ] || return 0
    GUI_RECORDER_STOP_FAILED=0
    if process_alive "$GUI_RECORDER_PID"; then
        if ! kill -TERM "$GUI_RECORDER_PID"; then
            GUI_RECORDER_STOP_FAILED=1
        elif ! wait_for_exit "$GUI_RECORDER_PID" 50; then
            GUI_RECORDER_STOP_FAILED=1
            if ! force_owned_exit "$GUI_RECORDER_PID" "window recorder"; then
                GUI_RECORDER_STOP_FAILED=1
            fi
        fi
    fi
    if ! wait "$GUI_RECORDER_PID" 2>/dev/null; then
        GUI_RECORDER_STOP_FAILED=1
    fi
    GUI_RECORDER_PID=""
    [ "$GUI_RECORDER_STOP_FAILED" -eq 0 ]
}

stop_daemon() {
    [ "$GUI_DAEMON_STARTED" = true ] || return 0
    GUI_DAEMON_STOP_FAILED=0
    if ! "$GUI_EMACSCLIENT" -n -s "$GUI_DAEMON" -e '(kill-emacs 0)' \
        >"$GUI_RUN_DIR/daemon-shutdown.log" 2>&1; then
        GUI_DAEMON_STOP_FAILED=1
    fi
    if ! wait_for_exit "$GUI_DAEMON_PID" 50; then
        GUI_DAEMON_STOP_FAILED=1
        if ! force_owned_exit "$GUI_DAEMON_PID" "Emacs daemon"; then
            GUI_DAEMON_STOP_FAILED=1
        fi
    fi
    GUI_DAEMON_STARTED=false
    GUI_DAEMON_PID=""
    GUI_DAEMON=""
    [ "$GUI_DAEMON_STOP_FAILED" -eq 0 ]
}

cleanup() {
    GUI_CLEANUP_FAILED=0
    if ! stop_recorder; then
        echo "GUI recorder cleanup failed" >&2
        GUI_CLEANUP_FAILED=1
    fi
    if ! stop_daemon; then
        echo "GUI daemon cleanup failed" >&2
        GUI_CLEANUP_FAILED=1
    fi
    [ "$GUI_CLEANUP_FAILED" -eq 0 ]
}

on_exit() {
    GUI_MAIN_STATUS=$?
    trap - EXIT HUP INT TERM
    if ! cleanup; then
        [ "$GUI_MAIN_STATUS" -ne 0 ] || GUI_MAIN_STATUS=1
    fi
    exit "$GUI_MAIN_STATUS"
}

trap on_exit EXIT
trap 'exit 130' HUP INT TERM

activate_emacs() {
    osascript -e "tell application \"System Events\" to set frontmost of first application process whose unix id is $GUI_DAEMON_PID to true"
    GUI_ACTIVATE_ATTEMPTS=0
    while [ "$GUI_ACTIVATE_ATTEMPTS" -lt 30 ]; do
        GUI_FRONTMOST=$(osascript -e \
            'tell application "System Events" to get unix id of first application process whose frontmost is true')
        if [ "$GUI_FRONTMOST" = "$GUI_DAEMON_PID" ]; then
            # macOS fullscreen/Space animations continue after focus changes.
            sleep 1
            return 0
        fi
        sleep 0.1
        GUI_ACTIVATE_ATTEMPTS=$((GUI_ACTIVATE_ATTEMPTS + 1))
    done
    echo "Emacs did not become the frontmost application" >&2
    exit 1
}

start_recorder() {
    "$GUI_RECORDER" "$GUI_DAEMON_PID" "$GUI_RUN_DIR/recording.mov" \
        "$GUI_RUN_DIR/recorder.ready" \
        >"$GUI_RUN_DIR/recorder.log" 2>&1 &
    GUI_RECORDER_PID=$!
    GUI_RECORDER_ATTEMPTS=0
    while [ "$GUI_RECORDER_ATTEMPTS" -lt 150 ]; do
        if ! kill -0 "$GUI_RECORDER_PID" 2>/dev/null; then
            echo "screen recorder exited before the scenario started" >&2
            exit 1
        fi
        if [ -s "$GUI_RUN_DIR/recorder.ready" ]; then
            return 0
        fi
        sleep 0.1
        GUI_RECORDER_ATTEMPTS=$((GUI_RECORDER_ATTEMPTS + 1))
    done
    echo "window recorder did not produce a verified frame" >&2
    exit 1
}

parse_run_arguments() {
    [ "$#" -ge 2 ] || usage
    GUI_ADAPTER=$1
    GUI_ENTRY=$2
    shift 2
    GUI_RUN_DIR=""
    GUI_LOAD_PATHS=""
    GUI_INITIALIZE_FUNCTION=""
    while [ "$#" -gt 0 ]; do
        case $1 in
            --initialize-function)
                [ "$#" -ge 2 ] || usage
                GUI_INITIALIZE_FUNCTION=$2
                shift 2
                ;;
            --run-dir)
                [ "$#" -ge 2 ] || usage
                GUI_RUN_DIR=$2
                shift 2
                ;;
            --load-path)
                [ "$#" -ge 2 ] || usage
                case $2 in *:*)
                    echo "load path cannot contain a colon: $2" >&2
                    exit 1
                    ;;
                esac
                if [ -n "$GUI_LOAD_PATHS" ]; then
                    GUI_LOAD_PATHS="$GUI_LOAD_PATHS:$2"
                else
                    GUI_LOAD_PATHS=$2
                fi
                shift 2
                ;;
            *) usage ;;
        esac
    done
    require_file "$GUI_ADAPTER"
    if [ -z "$GUI_RUN_DIR" ]; then
        GUI_RUN_DIR=$(mktemp -d /private/tmp/emacs-gui-verification.XXXXXX)
    else
        mkdir -p "$GUI_RUN_DIR"
    fi
    if [ -e "$GUI_RUN_DIR/manifest.jsonl" ] || [ -e "$GUI_RUN_DIR/recording.mov" ]; then
        echo "run directory already contains GUI evidence: $GUI_RUN_DIR" >&2
        exit 1
    fi
}

run_adapter() {
    doctor >/dev/null
    GUI_RECORDER="$GUI_RUN_DIR/record-emacs-window"
    xcrun swiftc -parse-as-library -warnings-as-errors -O \
        "$GUI_RECORDER_SOURCE" -o "$GUI_RECORDER"
    export ETAF_GUI_RUN_DIR="$GUI_RUN_DIR"
    export ETAF_GUI_LOAD_PATHS="$GUI_LOAD_PATHS"
    export ETAF_GUI_ENTRY="$GUI_ENTRY"
    export ETAF_GUI_INITIALIZE_FUNCTION="$GUI_INITIALIZE_FUNCTION"
    export SCREENCAPTURE="$GUI_CAPTURE"
    GUI_DAEMON="emacs-gui-verify-$$"
    "$GUI_EMACS_BIN" -Q --daemon="$GUI_DAEMON" \
        --eval '(setq native-comp-jit-compilation nil load-prefer-newer t)'
    GUI_DAEMON_STARTED=true
    GUI_DAEMON_PID=$(
        "$GUI_EMACSCLIENT" -n -s "$GUI_DAEMON" -e '(emacs-pid)'
    )
    valid_pid "$GUI_DAEMON_PID" || {
        echo "Emacs daemon returned an invalid process id: $GUI_DAEMON_PID" >&2
        exit 1
    }
    "$GUI_EMACSCLIENT" -n -s "$GUI_DAEMON" -c -e \
        "(progn
           (dolist (path (split-string (or (getenv \"ETAF_GUI_LOAD_PATHS\") \"\") path-separator t))
             (add-to-list 'load-path path))
           (load \"$GUI_ENGINE\" nil nil t)
           (load \"$GUI_ADAPTER\" nil nil t)
           (when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
           (when (fboundp 'menu-bar-mode) (menu-bar-mode -1))
           (when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
           (setenv \"ETAF_GUI_CAPTURE_PID\" (number-to-string (emacs-pid)))
           (set-frame-parameter nil 'fullscreen 'fullboth)
           (when-let* ((initialize (getenv \"ETAF_GUI_INITIALIZE_FUNCTION\"))
                       ((> (length initialize) 0)))
             (funcall (intern initialize)))
           (select-frame-set-input-focus (selected-frame))
           (message nil)
           (redisplay t)
           t)" >"$GUI_RUN_DIR/bootstrap.out"
    activate_emacs
    start_recorder
    "$GUI_EMACSCLIENT" -n -s "$GUI_DAEMON" -e \
        '(funcall (intern (getenv "ETAF_GUI_ENTRY")))' \
        >"$GUI_RUN_DIR/scenario.out"
    stop_recorder
    require_file "$GUI_RUN_DIR/recording.mov"
    [ -s "$GUI_RUN_DIR/recording.mov" ] || {
        echo "screen recording is empty" >&2
        exit 1
    }
    stop_daemon

    set +e
    python3 "$GUI_EVIDENCE_PY" finalize --run-dir "$GUI_RUN_DIR" \
        >"$GUI_RUN_DIR/finalize.out" 2>&1
    GUI_FINALIZE_STATUS=$?
    set -e
    cat "$GUI_RUN_DIR/finalize.out"
    if [ "$GUI_FINALIZE_STATUS" -eq 1 ]; then
        echo "GUI verification assertions failed: $GUI_RUN_DIR" >&2
        exit 1
    fi
    if [ "$GUI_FINALIZE_STATUS" -ne 2 ]; then
        echo "fresh capture unexpectedly bypassed temporal review" >&2
        exit 1
    fi
    echo "EMACS-GUI-VERIFIER CAPTURE COMPLETE verdict=INCOMPLETE entry=$GUI_ENTRY run-dir=$GUI_RUN_DIR"
}

[ "$#" -ge 1 ] || usage
GUI_COMMAND=$1
shift

case $GUI_COMMAND in
    doctor)
        [ "$#" -eq 0 ] || usage
        doctor
        ;;
    review)
        review_run "$@"
        ;;
    run)
        parse_run_arguments "$@"
        run_adapter
        ;;
    *) usage ;;
esac
