#!/bin/sh
# Stand in for the bundled backend while a phone scans the code.
# The answer advances with each poll so a client that stops polling after the
# first reply never reaches "signed-in": 1st waiting, 2nd scanned, 3rd+ confirmed.
# BILI_FAKE_COUNTER names the file holding the poll count.
counter=${BILI_FAKE_COUNTER:-}
case "$1" in
  login-start)
    [ -n "$counter" ] && printf '0\n' > "$counter"
    printf '%s\n' '{"ok":true,"key":"key-scan","size":3,"rows":["111","101","111"]}' ;;
  login-poll)
    count=0
    [ -n "$counter" ] && [ -f "$counter" ] && count=$(cat "$counter")
    count=$((count + 1))
    [ -n "$counter" ] && printf '%s\n' "$count" > "$counter"
    if [ "$count" -le 1 ]; then
      printf '%s\n' '{"ok":true,"state":"waiting"}'
    elif [ "$count" -eq 2 ]; then
      printf '%s\n' '{"ok":true,"state":"scanned"}'
    else
      printf '%s\n' '{"ok":true,"state":"signed-in","signed_in":true,"name":"扫码用户"}'
    fi ;;
  check)
    printf '%s\n' '{"ok":true,"signed_in":true,"name":"扫码用户"}' ;;
  *)
    printf '%s\n' '{"ok":false,"error":"usage","message":"unknown command"}' ;;
esac
