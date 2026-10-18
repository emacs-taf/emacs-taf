#!/usr/bin/env bash
# etaf-clean-emacs.sh --- open a clean Emacs for manual ETAF installation.
#
# Creates a disposable profile, points package.el at ETAF/GNU/NonGNU/MELPA,
# refreshes the package list and opens it.  Nothing is installed for you:
# install etaf-install from the list, then M-x etaf-install-manage.

set -euo pipefail

PROFILE=${ETAF_CLEAN_PROFILE:-$(mktemp -d "${TMPDIR:-/tmp}/etaf-clean-emacs.XXXXXX")}
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
  (package-initialize)
  (package-refresh-contents)
  (message "Clean profile: %s" "$PROFILE")
  (package-list-packages))
ELISP
)

printf 'Clean profile: %s\n' "$PROFILE"
printf 'Archive:       %s\n' "$ARCHIVE"
printf 'Remove when done: rm -rf %q\n' "$PROFILE"

open -n -a "$APP" --args -Q --eval "$elisp"
