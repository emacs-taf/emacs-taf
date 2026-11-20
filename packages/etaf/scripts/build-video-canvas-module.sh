#!/bin/sh
# Build the optional native canvas reader used by the `canvas' backend.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
emacs=${EMACS:-emacs}
include=${EMACS_MODULE_INCLUDE:-$("$emacs" --batch --eval \
  '(princ (expand-file-name "../include" data-directory))' 2>/dev/null)}
extension=so
case "$(uname -s)" in
  Darwin) extension=dylib ;;
  MINGW*|CYGWIN*) extension=dll ;;
esac
"${CC:-cc}" -shared -fPIC -O2 -I "$include" \
  "$root/native/etaf-video-canvas.c" \
  -o "$root/native/etaf-video-canvas.$extension"
printf 'built %s\n' "$root/native/etaf-video-canvas.$extension"
