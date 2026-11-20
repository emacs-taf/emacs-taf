#!/bin/sh
# Stand in for the bundled Bilibili account backend in the public suite.
[ -n "$BILI_FAKE_LOG" ] && printf '%s\n' "$*" >> "$BILI_FAKE_LOG"
case "$1" in
  login-start)
    printf '%s\n' '{"ok":true,"key":"key-1","size":3,"rows":["111","101","111"]}' ;;
  login-poll)
    printf '%s\n' '{"ok":true,"state":"signed-in","signed_in":true,"name":"测试用户"}' ;;
  check)
    printf '%s\n' '{"ok":true,"signed_in":true,"name":"测试用户"}' ;;
  logout)
    printf '%s\n' '{"ok":true,"signed_in":false}' ;;
  *)
    printf '%s\n' '{"ok":false,"error":"usage","message":"unknown command"}' ;;
esac
