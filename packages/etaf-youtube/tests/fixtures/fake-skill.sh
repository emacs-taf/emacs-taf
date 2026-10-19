#!/bin/sh
# Stand in for `pi-skill youtube' in the process-runner test.
case "$1" in
  check|login) printf '%s\n' '{"ok":true,"protocol":1,"conclusion":"fake","name":"Process Runner","signed_in":true}'; exit 0 ;;
  *) printf '%s\n' '{"ok":false,"message":"unknown command"}' >&2; exit 3 ;;
esac
