#!/bin/sh
# Build the optional cross-platform libmpv dynamic module for etaf-video.
# Requires only emacs-module.h at compile time; libmpv is loaded dynamically
# at runtime on macOS (.dylib), Linux (.so) and Windows (.dll).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
emacs=${EMACS:-emacs}
include=${EMACS_MODULE_INCLUDE:-${EMACS_INCLUDE:-$("$emacs" -Q --batch --eval \
  '(princ (file-name-directory (or (locate-file "emacs-module.h" (list (expand-file-name "../include" invocation-directory) (expand-file-name "../../../include" invocation-directory) (expand-file-name "../include" data-directory) "/Applications/Emacs.app/Contents/Resources/include" "/opt/homebrew/include" "/usr/local/include" "/usr/include")) "./emacs-module.h")))' 2>/dev/null)}}
extension=so
extra_flags=""
arch_flags=""
extra_sources=""
case "$(uname -s)" in
  Darwin)
    extension=dylib
    arch_flags="-Wl,-install_name,etaf-video-mpv.dylib"
    extra_sources="$root/native/etaf-video-mpv-macos.m"
    extra_flags="-fobjc-arc -Wno-deprecated-declarations -framework Cocoa -framework QuartzCore -framework OpenGL"
    if [ "${PORTABLE:-0}" = "1" ]; then
      arch_flags="$arch_flags -mmacosx-version-min=12.0"
    fi
    if [ -n "${ARCH:-}" ]; then
      arch_flags="$arch_flags -arch $ARCH"
    fi
    ;;
  MINGW*|CYGWIN*|MSYS*)
    extension=dll
    extra_sources="$root/native/etaf-video-mpv-win32.c"
    extra_flags="-lgdi32 -luser32 -lopengl32"
    if [ "${PORTABLE:-0}" = "1" ]; then
      extra_flags="-static-libgcc $extra_flags"
    fi
    ;;
  Linux)
    extra_sources="$root/native/etaf-video-mpv-linux.c"
    extra_flags="-ldl -lpthread -lm"
    ;;
  *) extra_flags="-ldl -lpthread" ;;
esac
canvas_flag=""
if [ "${PORTABLE:-0}" != "1" ] && [ -f "$include/emacs-module.h" ] && grep -q "canvas_data" "$include/emacs-module.h"; then
  canvas_flag="-DETAF_EMACS_HAS_CANVAS=1"
fi
"${CC:-cc}" -std=c11 -shared -fPIC -O2 -Wall -Wextra \
  $arch_flags \
  $canvas_flag \
  -I "$include" \
  -I "$root/native" \
  "$root/native/etaf-video-mpv.c" \
  $extra_sources \
  $extra_flags \
  -o "$root/native/etaf-video-mpv.$extension"
printf 'built %s\n' "$root/native/etaf-video-mpv.$extension"
