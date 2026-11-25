#!/bin/sh
# Build the optional cross-platform libmpv dynamic module for etaf-video.
# Requires only emacs-module.h at compile time; libmpv is loaded dynamically
# at runtime on macOS (.dylib), Linux (.so) and Windows (.dll).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
emacs=${EMACS:-emacs}
include=${EMACS_MODULE_INCLUDE:-$("$emacs" --batch --eval \
  '(princ (expand-file-name "../include" data-directory))' 2>/dev/null)}
extension=so
extra_flags=""
case "$(uname -s)" in
  Darwin) extension=dylib ;;
  MINGW*|CYGWIN*|MSYS*) extension=dll ;;
  *) extra_flags="-ldl" ;;
esac
canvas_flag=""
if [ -f "$include/emacs-module.h" ] && grep -q "canvas_data" "$include/emacs-module.h"; then
  canvas_flag="-DETAF_EMACS_HAS_CANVAS=1"
fi
"${CC:-cc}" -std=c11 -shared -fPIC -O2 -Wall -Wextra \
  $canvas_flag \
  -I "$include" \
  "$root/native/etaf-video-mpv.c" \
  $extra_flags \
  -o "$root/native/etaf-video-mpv.$extension"
printf 'built %s\n' "$root/native/etaf-video-mpv.$extension"
