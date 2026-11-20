#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
emacsclient_bin=${EMACSCLIENT:-emacsclient}
mkdir -p "$root/.omx"
report=$(mktemp "$root/.omx/icon-check.XXXXXX")
trap 'rm -f "$report" "$report.status"' EXIT HUP INT TERM
if ! "$emacsclient_bin" --eval "(progn (load \"$root/tests/etaf-ui-icon-gui.el\" nil t t) (etaf-ui-icon-gui-start \"$report\"))"; then
    printf '%s\n' 'icon-check could not start; a graphical Emacs server is required.' >&2
    exit 1
fi
end=$(( $(date +%s) + ${GUI_TIMEOUT:-120} ))
while [ "$(date +%s)" -lt "$end" ]; do
    if [ -s "$report.status" ]; then
        cat "$report"
        exit "$(cat "$report.status")"
    fi
    sleep 1
done
printf '%s\n' 'icon-check timed out waiting for the graphical Emacs server.' >&2
exit 2
