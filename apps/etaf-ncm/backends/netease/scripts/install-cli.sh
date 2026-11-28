#!/bin/sh
# standalone 安装：把本技能目录当纯 CLI 用（不需要 Pi）。
# 用法：scripts/install-cli.sh [--prefix DIR]；默认 ~/.local。
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$HOME/.local"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    -h|--help) printf '用法：%s [--prefix DIR]（默认 ~/.local；链接 <prefix>/bin/netease-music）\n' "$0"; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done
bindir="$prefix/bin"
mkdir -p "$bindir"
ln -sfn "$here/scripts/netease-music.sh" "$bindir/netease-music"
printf 'linked: %s/netease-music -> %s/scripts/netease-music.sh\n' "$bindir" "$here"
missing=""
for tool in node mpv python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -z "$missing" ] || printf '缺少依赖:%s（macOS: brew install node mpv python3）\n' "$missing"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) printf '提示：把 %s 加进 PATH，例如 export PATH="%s:$PATH"\n' "$bindir" "$bindir" ;;
esac
printf '下一步：netease-music check（自检）；未登录再跑 netease-music login（手机扫码）\n'
printf '状态目录默认 ${XDG_STATE_HOME:-~/.local/state}/netease-music；可用 NETEASE_MUSIC_STATE_DIR 指走\n'
