#!/usr/bin/env bash
# etaf-emacs.sh --- start a throwaway Emacs for manual ETAF installation.
#
# Creates a disposable profile, points package.el at ETAF/GNU/NonGNU/MELPA and
# fetches their package lists in the background; the *Packages* buffer opens
# once the archives are down.  The frame stays usable meanwhile: a synchronous
# fetch blocks the command loop, so typing and completion stall for as long as
# the downloads take.  It installs nothing: choose etaf-install from the list,
# then M-x etaf-install-manage.

set -euo pipefail

usage() {
    cat <<'USAGE'
etaf-emacs --- try ETAF in a throwaway Emacs

Usage: etaf-emacs [-h|--help]

Starts Emacs with a fresh profile (-Q, no init file), points package.el at
GNU/NonGNU/MELPA and the ETAF archive, and opens *Packages* once the archives
are downloaded.  Choose etaf-install there, then M-x etaf-install-manage.
Nothing installed here touches your own configuration.

Environment:
  ETAF_ISOLATED_PROFILE  reuse this profile directory instead of a new one
  ETAF_INSTALL_ARCHIVE   archive URL (default https://etaf.top/packages/)
  ETAF_EMACS_APP         Emacs.app path (default /Applications/Emacs.app)
USAGE
}

case ${1:-} in
    -h|--help|help) usage; exit 0 ;;
    '') ;;
    *) printf 'unexpected argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

PROFILE=${ETAF_ISOLATED_PROFILE:-$(mktemp -d "${TMPDIR:-/tmp}/etaf-emacs.XXXXXX")}
ARCHIVE=${ETAF_INSTALL_ARCHIVE:-https://etaf.top/packages/}
APP=${ETAF_EMACS_APP:-/Applications/Emacs.app}

mkdir -p "$PROFILE"

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
  ;; List the packages once every download reported back, or whatever arrived if
  ;; one never does; listing without NO-FETCH would download everything again.
  ;; The list is shown once.  The hook comes out after it fires, because a
  ;; later refresh, such as the ETAF manager's `g', would otherwise pop a
  ;; package list over whatever page is open in the selected window.
  (defvar etaf-trial--listed nil)
  (defvar etaf-trial--list-timer nil)
  (defun etaf-trial--list-packages-once ()
    (unless etaf-trial--listed
      (setq etaf-trial--listed t)
      (remove-hook 'package--post-download-archives-hook
                   #'etaf-trial--list-packages-once)
      (when (timerp etaf-trial--list-timer)
        (cancel-timer etaf-trial--list-timer))
      (package-list-packages t)))
  (when (boundp 'package--post-download-archives-hook)
    (add-hook 'package--post-download-archives-hook
              #'etaf-trial--list-packages-once))
  (setq etaf-trial--list-timer
        (run-with-timer 45 nil #'etaf-trial--list-packages-once))
  (message "Fetching package archives (the *Packages* list opens when they are ready)")
  (package-refresh-contents t))
ELISP
)

printf 'Isolated profile: %s\n' "$PROFILE"
printf 'Archive:          %s\n' "$ARCHIVE"
printf 'Remove when done: rm -rf %q\n' "$PROFILE"

open -n -a "$APP" --args -Q --eval "$elisp"
