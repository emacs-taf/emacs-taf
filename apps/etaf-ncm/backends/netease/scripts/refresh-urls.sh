#!/bin/bash
# refresh-urls.sh — 队列地址保活
#
# 网易云的播放直链是限时签名 URL：实测取出来约 5 分钟就 403
# （路径里的时间戳 + vuutv/authSecret 签名，服务端一核，过期就拒绝）。
# 长队列预取一批地址，放到后半段会集体失效，听感是「歌还在放、就是没声音」。
#
# 本脚本由入口的 keepalive_start 拉起（一次只跑一个），每 90 秒看一次：
#   这批地址取出来多久了（urls_at）× mpv 播到第几首（playlist-pos）
# 一到 4 分钟，就把「当前这首之后还没播的」批量重取，原地换掉 m3u 里对应的行。
# mpv 是按需读取下一首的，所以换 URL 不影响正在放的那首。
# 队列被换掉 / 停止 / mpv 退出，脚本自己收工。
set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="${NETEASE_MUSIC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/netease-music}"
QUEUE="$LOCAL_DIR/queue.json"
M3U="$LOCAL_DIR/queue.m3u8"
URLS_AT="$LOCAL_DIR/urls_at"
SOCK="$LOCAL_DIR/mpv.sock"
API="$SKILL_DIR/scripts/netease-api.mjs"
QUALITY="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("quality") or "lossless")
except Exception: print("lossless")' "$LOCAL_DIR/config.json" 2>/dev/null)"
QUALITY="${NETEASE_MUSIC_QUALITY:-$QUALITY}"
COOKIE="${NETEASE_MUSIC_COOKIE:-${NETEASE_COOKIE:-$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("cookie") or "")
except Exception: print("")' "$LOCAL_DIR/config.json" 2>/dev/null)}}"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
mpv_query() { # mpv_query <属性>：拿不到就打印空
  python3 - "$SOCK" "$1" <<'PY' 2>/dev/null
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1])
    s.sendall(json.dumps({"command": ["get_property", sys.argv[2]], "request_id": 1}).encode() + b"\n")
    r = json.loads(s.recv(65536).decode())
    print(r.get("data") if r.get("error") == "success" else "")
except Exception:
    print("")
PY
}
refetch_from() { # refetch_from <起始序号 0-based>：重取这一首之后的地址，原地换 m3u
  local from="$1" tmp_ids tmp_urls n
  tmp_ids="$(mktemp)"; tmp_urls="$(mktemp)"
  python3 - "$QUEUE" "$from" "$LOCAL_DIR/downloads.json" > "$tmp_ids" <<'PY'
import json, os, sys
q = json.load(open(sys.argv[1]))
try:
    downloads = json.load(open(sys.argv[3]))
except Exception:
    downloads = {}
for i, s in enumerate(q["songs"]):
    if i < int(sys.argv[2]):
        continue
    entry = downloads.get(str(s["id"]))
    # 已下载的歌播的是本地文件，不参与直链刷新，也不要覆写它在 m3u 里的那一行。
    if isinstance(entry, dict) and entry.get("file") and os.path.isfile(entry["file"]):
        continue
    print(s["id"])
PY
  [ -s "$tmp_ids" ] || { rm -f "$tmp_ids" "$tmp_urls"; return 1; }
  n="$(wc -l < "$tmp_ids" | tr -d ' ')"
  log "重取地址：从第 $((from + 1)) 首起共 $n 首"
  while read -r chunk; do
    NETEASE_COOKIE="$COOKIE" node "$API" url $chunk --level "$QUALITY" 2>/dev/null \
      | python3 -c 'import json,sys
for it in (json.load(sys.stdin).get("items") or []):
    print("%s\t%s" % (it.get("id"), it.get("url") or ""))' >> "$tmp_urls"
  done < <(python3 -c 'import sys
ids = [l.strip() for l in sys.stdin if l.strip()]
for i in range(0, len(ids), 200): print(" ".join(ids[i:i+200]))' < "$tmp_ids")
  # 与起播路径用同一原语：整族坏节点换到可用节点（修不好的不输出，保留旧地址）
  if [ -s "$tmp_urls" ] && command -v node >/dev/null 2>&1; then
    if node "$SKILL_DIR/scripts/lib/cdn-url.mjs" --all --concurrency 16 --timeout 2000 \
         < "$tmp_urls" > "$tmp_urls.fixed" 2>"$tmp_urls.log"; then
      [ -s "$tmp_urls.fixed" ] && mv "$tmp_urls.fixed" "$tmp_urls"
      [ -s "$tmp_urls.log" ] && log "cdn: $(cat "$tmp_urls.log")"
    fi
    rm -f "$tmp_urls.fixed" "$tmp_urls.log"
  fi
  python3 - "$M3U" "$QUEUE" "$tmp_urls" "$from" <<'PY'
import json, sys
mpath, qpath, upath, start = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
urls = {}
for line in open(upath):
    sid, _, url = line.rstrip("\n").partition("\t")
    if url:
        urls[sid] = url
order = [str(s["id"]) for s in json.load(open(qpath))["songs"]]
lines = open(mpath).read().split("\n")
head = [i for i, l in enumerate(lines) if l.startswith("#EXTINF")]
changed = 0
for pos, i in enumerate(head):
    if pos < start or pos >= len(order) or i + 1 >= len(lines):
        continue
    u = urls.get(order[pos])
    if u:
        lines[i + 1] = u
        changed += 1
open(mpath, "w").write("\n".join(lines))
print("换成新地址的条数：%d/%d" % (changed, len(head) - start))
PY
  # 光改 m3u 不够：mpv 队列是加载时展开的，文件改了对它无效。
  # 用 reload 把「当前之后」的条目按新地址接回去（playlist-clear 保留正在放的那首）。
  node "$SKILL_DIR/scripts/mpv-ctl.mjs" reload "$M3U" >/dev/null 2>&1 || log "mpv 队列重载失败（下轮重试）"
  log "重取完成（从第 $((from + 1)) 首起）"
  rm -f "$tmp_ids" "$tmp_urls"
}
refresh_from_current() { # 重取「当前放到的那首之后」的地址，并让 mpv 接上（播放不断）
  # 「当前放到第几首」按歌认：mpv 开了 shuffle 时 playlist-pos 不是 queue.json 的序号
  local title curl pos
  title="$(mpv_query media-title)"
  curl="$(mpv_query path)"
  pos="$(python3 "$SKILL_DIR/scripts/lib/mpv-map.py" index "$QUEUE" "$LOCAL_DIR/urls.txt" "$title" "$curl" 2>/dev/null)"
  case "$pos" in ''|*[!0-9]*) pos=0 ;; esac
  refetch_from "$pos"
}
log "地址保活启动"
# 起播路径只按族抽样探测（快）；这里马上补一遍逐条修复，把「当前之后」
# 的地址接回 mpv，正在放的那首不受影响。
if refresh_from_current; then date +%s > "$URLS_AT"; else log "首次逐条探测失败，90 秒后再试"; fi
while :; do
  sleep 90
  [ -n "$(mpv_query idle-active)" ] || { log "mpv 没了，收工"; exit 0; }
  [ -s "$QUEUE" ] || { log "队列没了，收工"; exit 0; }
  age=$(( $(date +%s) - $(cat "$URLS_AT" 2>/dev/null || echo 0) ))
  [ "$age" -lt 240 ] && continue
  if refresh_from_current; then date +%s > "$URLS_AT"; else log "重取失败，90 秒后再试"; fi
done