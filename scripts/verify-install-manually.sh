#!/usr/bin/env bash
# verify-install-manually.sh --- try the ETAF installer in disposable profiles.
#
# Neither mode reads your init, your package directory or source checkouts:
# batch starts `emacs -Q` with a temporary profile, gui starts a separate
# `Emacs -Q` instance with a temporary package-user-dir.
#
# Profiles are kept under ${TMPDIR:-/tmp}/etaf-verify.* for inspection;
# `clean` removes them.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SMOKE="$ROOT/scripts/install-smoke.el"
ARCHIVE=${ETAF_INSTALL_ARCHIVE:-https://etaf.top/packages/}
EMACS=${EMACS:-emacs}
APP=${ETAF_EMACS_APP:-/Applications/Emacs.app}
TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    case ${1:-} in
        batch)
            cat <<'EOF'
Usage: scripts/verify-install-manually.sh batch [options]

Install each target through both package.el paths in fresh profiles.

Options:
  --target TARGET           repeatable; default: etaf-ui etaf-telega
  --entry                   only the etaf-install entry path
  --direct                  only package-install
  --archive URL             default: https://etaf.top/packages/
  --standard-archives URL   prefetched GNU/NonGNU/MELPA snapshot base
  -h, --help                show this help

The entry path unsets ETAF_INSTALL_DIRECT; do not set it yourself.
A target's external runtime is not installed: etaf-telega reports
telega-server missing instead of claiming it is ready.
EOF
            ;;
        gui)
            cat <<'EOF'
Usage: scripts/verify-install-manually.sh gui [options]

Start a separate Emacs -Q instance with a temporary package-user-dir,
install etaf-install from the archive, and open etaf-install-manage.

Options:
  --archive URL   default: https://etaf.top/packages/
  --app PATH      default: /Applications/Emacs.app (or ETAF_EMACS_APP)
  -h, --help      show this help

Close the instance before running `clean`.
EOF
            ;;
        clean)
            cat <<'EOF'
Usage: scripts/verify-install-manually.sh clean

Remove the disposable profiles and logs created under
${TMPDIR:-/tmp}/etaf-verify.* by batch and gui.
EOF
            ;;
        '')
            cat <<'EOF'
Usage: scripts/verify-install-manually.sh [batch] [options]
       scripts/verify-install-manually.sh gui [options]
       scripts/verify-install-manually.sh clean
       scripts/verify-install-manually.sh help [batch|gui|clean]

Commands:
  batch (default)  install each target through etaf-install and package-install
  gui              start a separate Emacs -Q and open etaf-install-manage
  clean            remove ${TMPDIR:-/tmp}/etaf-verify.*
  help [COMMAND]   show this help or command help

Environment:
  EMACS                       Emacs executable for batch (default: emacs)
  ETAF_INSTALL_ARCHIVE        default archive (default: https://etaf.top/packages/)
  ETAF_EMACS_APP              Emacs.app for gui (default: /Applications/Emacs.app)

Neither mode reads your init, package directory or source checkouts.
Profiles and logs are kept for inspection until `clean`.
EOF
            ;;
        *)
            die "unknown help topic: $1"
            ;;
    esac
}

batch() {
    local targets=()
    local modes=()
    local archive=$ARCHIVE
    local standard=${ETAF_INSTALL_STANDARD_ARCHIVES:-}

    while [ $# -gt 0 ]; do
        case $1 in
            --target)
                [ $# -ge 2 ] || die "--target needs a value"
                targets+=("$2")
                shift 2
                ;;
            --entry)
                modes+=(entry)
                shift
                ;;
            --direct)
                modes+=(direct)
                shift
                ;;
            --archive)
                [ $# -ge 2 ] || die "--archive needs a value"
                archive=$2
                shift 2
                ;;
            --standard-archives)
                [ $# -ge 2 ] || die "--standard-archives needs a value"
                standard=$2
                shift 2
                ;;
            -h|--help)
                usage batch
                return 0
                ;;
            *)
                die "unknown batch option: $1 (try help)"
                ;;
        esac
    done

    [ -f "$SMOKE" ] || die "missing $SMOKE"
    command -v "$EMACS" >/dev/null 2>&1 ||
        die "Emacs executable not found: $EMACS (set EMACS=...)"

    if [ ${#targets[@]} -eq 0 ]; then
        targets=(etaf-ui etaf-telega)
    fi
    if [ ${#modes[@]} -eq 0 ]; then
        modes=(entry direct)
    fi

    local root
    root=$(mktemp -d "$TMP_BASE/etaf-verify.XXXXXX")
    mkdir -p "$root/logs"

    if [ -n "$standard" ]; then
        export ETAF_INSTALL_STANDARD_ARCHIVES=$standard
    else
        unset ETAF_INSTALL_STANDARD_ARCHIVES || true
    fi

    printf 'ETAF installer manual verification\n'
    printf '  repo:    %s\n' "$ROOT"
    printf '  archive: %s\n' "$archive"
    printf '  emacs:   %s\n' "$(command -v "$EMACS")"
    printf '  temp:    %s\n\n' "$root"

    local total=0 failures=0 target mode profile log started elapsed rc
    for target in "${targets[@]}"; do
        for mode in "${modes[@]}"; do
            total=$((total + 1))
            profile="$root/profile-$mode-$target"
            log="$root/logs/$mode-$target.log"
            mkdir -p "$profile"

            printf '[%d] %-6s %-14s ... ' "$total" "$mode" "$target"
            started=$(date +%s)
            set +e
            if [ "$mode" = direct ]; then
                ETAF_INSTALL_DIRECT=1 \
                ETAF_INSTALL_ARCHIVE="$archive" \
                ETAF_INSTALL_PROFILE="$profile" \
                ETAF_INSTALL_TARGET="$target" \
                    "$EMACS" -Q --batch -l "$SMOKE" >"$log" 2>&1
            else
                env -u ETAF_INSTALL_DIRECT \
                    ETAF_INSTALL_ARCHIVE="$archive" \
                    ETAF_INSTALL_PROFILE="$profile" \
                    ETAF_INSTALL_TARGET="$target" \
                    "$EMACS" -Q --batch -l "$SMOKE" >"$log" 2>&1
            fi
            rc=$?
            set -e
            elapsed=$(( $(date +%s) - started ))

            if [ "$rc" -eq 0 ]; then
                printf 'PASS (%ss)\n' "$elapsed"
                tail -n 1 "$log"
                printf '\n'
            else
                printf 'FAIL (%ss, exit %d)\n' "$elapsed" "$rc"
                tail -n 25 "$log"
                failures=$((failures + 1))
            fi
        done
    done

    printf '\nSummary: %d passed, %d failed\n' \
        "$((total - failures))" "$failures"
    printf 'Profiles and logs: %s\n' "$root"
    printf 'GUI:   %s gui\n' "$0"
    printf 'Clean: %s clean\n' "$0"

    [ "$failures" -eq 0 ]
}

gui() {
    local archive=$ARCHIVE
    local app=$APP

    while [ $# -gt 0 ]; do
        case $1 in
            --archive)
                [ $# -ge 2 ] || die "--archive needs a value"
                archive=$2
                shift 2
                ;;
            --app)
                [ $# -ge 2 ] || die "--app needs a value"
                app=$2
                shift 2
                ;;
            -h|--help)
                usage gui
                return 0
                ;;
            *)
                die "unknown gui option: $1 (try help)"
                ;;
        esac
    done

    [ -d "$app" ] || die "Emacs.app not found: $app (set ETAF_EMACS_APP or --app)"
    command -v open >/dev/null 2>&1 ||
        die "open not found; gui mode is for macOS"

    local root profile elisp
    root=$(mktemp -d "$TMP_BASE/etaf-verify.XXXXXX")
    profile="$root/gui"
    mkdir -p "$profile"

    elisp=$(cat <<EOF
(progn
  (setq user-emacs-directory "$profile/"
        package-user-dir "$profile/elpa"
        package-directory-list nil)
  (make-directory package-user-dir t)
  (require 'package)
  (add-to-list 'package-archives (cons "etaf" "$archive"))
  (package-initialize)
  (package-refresh-contents)
  (package-install 'etaf-install)
  (etaf-install-manage))
EOF
)

    printf 'Starting a separate Emacs -Q instance.\n'
    printf '  archive: %s\n' "$archive"
    printf '  profile: %s\n' "$profile"
    printf '  app:     %s\n\n' "$app"

    open -n -a "$app" --args -Q --eval "$elisp"

    printf 'Leave this instance open while you use etaf-install-manage.\n'
    printf 'After closing it, remove the profile: %s clean\n' "$0"
}

clean() {
    case ${1:-} in
        -h|--help)
            usage clean
            return 0
            ;;
        '')
            ;;
        *)
            die "clean takes no arguments"
            ;;
    esac

    shopt -s nullglob
    local dirs=("$TMP_BASE"/etaf-verify.*)
    if [ ${#dirs[@]} -eq 0 ]; then
        printf 'No disposable ETAF profiles.\n'
        return 0
    fi

    local dir
    for dir in "${dirs[@]}"; do
        rm -rf "$dir"
        printf 'Removed %s\n' "$dir"
    done
}

command=${1:-batch}
case $command in
    batch)
        shift
        batch "$@"
        ;;
    gui)
        shift
        gui "$@"
        ;;
    clean)
        shift
        clean "$@"
        ;;
    help|-h|--help)
        usage "${2:-}"
        ;;
    *)
        die "unknown command: $command (try help)"
        ;;
esac
