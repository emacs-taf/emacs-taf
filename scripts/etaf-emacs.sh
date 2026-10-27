#!/usr/bin/env bash
# etaf-emacs.sh --- start a throwaway Emacs for manual ETAF installation.
#
# Creates a disposable profile, points package.el at ETAF/GNU/NonGNU/MELPA and
# fetches their package lists in the background; once they are down it installs
# etaf-install and opens its manager.  The frame stays usable meanwhile: a
# synchronous fetch blocks the command loop, so typing and completion stall for
# as long as the downloads take.  Only that throwaway profile is touched.

set -euo pipefail

usage() {
    cat <<'USAGE'
etaf-emacs --- try ETAF in a throwaway Emacs

Usage: etaf-emacs [-h|--help] [--dev]

Starts Emacs with a fresh profile (-Q, no init file), points package.el at
GNU/NonGNU/MELPA and the ETAF archive, then installs etaf-install and opens
M-x etaf-install-manage once the archives are downloaded.  Nothing installed
here touches your own configuration.

--dev builds the trial archive from this workspace instead of downloading it,
so changes in the working copies show up without publishing a release.

Environment:
  ETAF_ISOLATED_PROFILE  reuse this profile directory instead of a new one
  ETAF_INSTALL_ARCHIVE   archive URL or directory (default https://etaf.top/packages/)
  ETAF_EMACS_APP         Emacs.app path (default /Applications/Emacs.app)
USAGE
}

DEV=
case ${1:-} in
    -h|--help|help) usage; exit 0 ;;
    --dev) DEV=1 ;;
    '') ;;
    *) printf 'unexpected argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

# Resolve the script's own location through any symlink, so --dev finds the
# workspace the link points at rather than the directory that holds the link.
SCRIPT=$0
while [ -L "$SCRIPT" ]; do
    LINKED=$(cd "$(dirname "$SCRIPT")" && pwd -P)
    SCRIPT=$(readlink "$SCRIPT")
    case $SCRIPT in
        /*) ;;
        *) SCRIPT="$LINKED/$SCRIPT" ;;
    esac
done
WORKSPACE=$(cd "$(dirname "$SCRIPT")/.." && pwd -P)
PROFILE=${ETAF_ISOLATED_PROFILE:-$(mktemp -d "${TMPDIR:-/tmp}/etaf-emacs.XXXXXX")}
ARCHIVE=${ETAF_INSTALL_ARCHIVE:-https://etaf.top/packages/}
APP=${ETAF_EMACS_APP:-/Applications/Emacs.app}

mkdir -p "$PROFILE"

if [ -n "$DEV" ]; then
    if [ ! -f "$WORKSPACE/release-dependencies.json" ]; then
        printf '--dev needs an ETAF checkout; %s is not one\n' "$WORKSPACE" >&2
        exit 2
    fi
    # The archive builder creates its own output directory, so this names one
    # inside a fresh parent; package.el needs the trailing slash.
    ARCHIVE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/etaf-dev-archive.XXXXXX")/archive
    printf 'Building the trial archive from %s\n' "$WORKSPACE"
    python3 - "$WORKSPACE" "$ARCHIVE_DIR" <<'PYTHON'
import json
from pathlib import Path
import subprocess
import sys

workspace, target = (Path(argument) for argument in sys.argv[1:3])
selection = json.loads((workspace / "release-dependencies.json").read_text())["packages"]
sources = {name: workspace / name for name in selection}
# The installer is not one of the registry's targets: the release builds it from
# the workspace root, and a trial needs it to reach the manager.
sources["etaf-install"] = workspace
command = [sys.executable, str(workspace / "scripts/package_archive.py"),
           "build", "--directory", str(target)]
for name, source in sources.items():
    command.extend(["--package", f"{name}={source}"])
    for resource in selection.get(name, {}).get("resources", []):
        command.extend(["--resource", f"{name}={resource}"])
# The archive tool reports its own error= and hint= lines; a traceback on top
# would only bury them, so stop the script with that status instead.
sys.exit(subprocess.run(command, cwd=workspace).returncode)
PYTHON
    ARCHIVE="$ARCHIVE_DIR/"
    printf 'Trial archive:    %s\n' "$ARCHIVE"
fi

if [ ! -d "$APP" ]; then
    printf 'Emacs.app not found: %s\n' "$APP" >&2
    printf 'Set ETAF_EMACS_APP to the app path.\n' >&2
    exit 1
fi

elisp=$(cat <<ELISP
(progn
  (setq user-emacs-directory "$PROFILE/"
        package-user-dir "$PROFILE/elpa"
        package-directory-list nil)
  (make-directory package-user-dir t)
  (require 'package)
  (setq package-archives
        '(("gnu" . "https://elpa.gnu.org/packages/")
          ("nongnu" . "https://elpa.nongnu.org/nongnu/")
          ("melpa" . "https://melpa.org/packages/")
          ("etaf" . "$ARCHIVE")))
  ;; Reach the public archives directly.  A proxy inherited from the caller can
  ;; stall or break these downloads (measured: a local TLS-terminating proxy
  ;; fails elpa.gnu.org, turning one fetch into a minute-long hang).
  (setq url-proxy-services
        (cons (cons "no_proxy"
                    (regexp-opt '("elpa.gnu.org" "elpa.nongnu.org"
                                  "melpa.org" "etaf.top")))
              (assoc-delete-all "no_proxy" url-proxy-services)))
  (package-initialize)
  ;; Installing from a source archive makes package.el byte-compile in the main
  ;; thread, and the stock 800 kB GC threshold thrashes while it does: etaf-ui
  ;; took 8.2s with a 2.0s freeze, 6.4s with a 1.1s one.  A normal init raises
  ;; it as well.
  (setq gc-cons-threshold (* 256 1024 1024))
  ;; Native-compiling the ~100 files an ETAF install brings in ran for minutes
  ;; afterwards and kept the session unresponsive.  This is a throwaway trial
  ;; profile, so it runs the byte-code the install already produced; delete this
  ;; line to compile natively.
  (setq native-comp-jit-compilation nil)
  ;; Install the installer and show its manager once the archives are down, or
  ;; once the fallback deadline passes with whatever arrived.  This happens once:
  ;; the hook removes itself afterwards, because a later refresh, such as the
  ;; manager's g key, must not take over whatever page is open.
  (defvar etaf-trial--started nil)
  (defvar etaf-trial--start-timer nil)
  (defun etaf-trial--start ()
    (unless etaf-trial--started
      (setq etaf-trial--started t)
      (remove-hook 'package--post-download-archives-hook #'etaf-trial--start)
      (when (timerp etaf-trial--start-timer)
        (cancel-timer etaf-trial--start-timer))
      (condition-case failure
          (progn
            (unless (package-installed-p 'etaf-install)
              (message "Installing etaf-install from the archive…")
              (package-install 'etaf-install))
            (require 'etaf-install)
            (etaf-install-manage))
        (error
         (message "ETAF: could not install etaf-install: %s"
                  (error-message-string failure))
         (package-list-packages t)))))
  (when (boundp 'package--post-download-archives-hook)
    (add-hook 'package--post-download-archives-hook #'etaf-trial--start))
  (setq etaf-trial--start-timer
        (run-with-timer 45 nil #'etaf-trial--start))
  (message "Fetching package archives (the ETAF manager opens when they are ready)")
  (package-refresh-contents t))
ELISP
)

printf 'Isolated profile: %s\n' "$PROFILE"
printf 'Archive:          %s\n' "$ARCHIVE"
printf 'Remove when done: rm -rf %q\n' "$PROFILE"

open -n -a "$APP" --args -Q --eval "$elisp"
