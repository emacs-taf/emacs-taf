#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
emacsclient_bin=${EMACSCLIENT:-emacsclient}
case "${1:-surfaces}" in
    surfaces) entry=etaf-ui-gui-interactions-start ;;
    gallery) entry=etaf-ui-gallery-gui-interactions-start ;;
    fonts) entry=etaf-ui-font-gui-interactions-start ;;
    *) printf '%s\n' 'usage: run-gui-check.sh [surfaces|gallery|fonts]' >&2; exit 2 ;;
esac
"$emacsclient_bin" --eval "(progn (load \"$root/scripts/etaf-ui-gui.el\" nil t t) ($entry))" >/dev/null
end=$(( $(date +%s) + ${GUI_TIMEOUT:-90} ))
while [ "$(date +%s)" -lt "$end" ]; do
  result=$("$emacsclient_bin" --eval 'etaf-ui-gui-interactions' 2>/dev/null || true)
  case "$result" in
    *"(complete passed)"*) "$emacsclient_bin" --eval '(format "GUI interactions: %d passed" (1- (length etaf-ui-gui-interactions)))'; exit 0 ;;
    *failed*) printf '%s\n' "$result" >&2; exit 1 ;;
  esac
  sleep 1
done
printf '%s\n' "ETAF UI GUI check timed out" >&2
exit 2
