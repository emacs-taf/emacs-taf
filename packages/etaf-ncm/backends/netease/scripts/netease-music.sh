#!/usr/bin/env bash
# netease-music — 直接调接口放网易云音乐（不再模拟鼠标点界面）
#
# 架构（三层，各层可单独验证）：
#   取数  scripts/netease-api.mjs   直连 music.163.com 的 weapi（自包含加密，零 npm 依赖）
#   播放  scripts/mpv-ctl.mjs       常驻 mpv + unix socket JSON IPC（状态是真值，不靠截屏猜）
#   入口  本脚本                     把「用户意图」翻译成上面两层的调用
#
# 实测结论（勿改）：
#   * 搜索必须走明文接口 /api/search/get/web：weapi 版 cloudsearch 对匿名请求回空体（HTTP 200 空）。
#   * weapi 的 aesEncrypt 输出是 base64，不是 hex（用 hex 会得到 HTTP 200 空响应）。
#   * mpv 的 `cycle pause` 会报 invalid parameter，改 set_property。
#   * mpv 的 shuffle 会重排它自己的播放顺序：playlist-pos 不能直接索引 queue.json（实测会报错歌，
#     status 说在放《野心家》、实际在放《All Of Me》）；映射一律走 scripts/lib/mpv-map.py（标题 [#id] → URL → 名字）。
#   * 登录态 = MUSIC_U cookie，来自扫码登录的 Set-Cookie；存 $NETEASE_MUSIC_STATE_DIR/config.json。
set -uo pipefail

# 入口可能被安装成符号链接（install-cli.sh），先解到真实路径再定位仓库根。
SELF="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")"
SKILL_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"

# 网易云是国内服务：显式绕开 shell 里的代理变量。
# 否则 sing-box 一关（7890 端口没了），接口和 mpv/ffmpeg 取音频流会一起挂。
# node 本来就不认这些变量，但 mpv/ffmpeg/curl 认，所以必须显式清掉。
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy 2>/dev/null || true
export NO_PROXY="music.163.com,.163.com,.126.net,.127.net,localhost,127.0.0.1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
# 状态目录（cookie/队列/缓存）：默认在 XDG 状态目录；NETEASE_MUSIC_STATE_DIR 可以指走。
LOCAL_DIR="${NETEASE_MUSIC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/netease-music}"
CFG="$LOCAL_DIR/config.json"
API="$SKILL_DIR/scripts/netease-api.mjs"
MPVCTL="$SKILL_DIR/scripts/mpv-ctl.mjs"
QUEUE="$LOCAL_DIR/queue.json"
M3U="$LOCAL_DIR/queue.m3u8"

JSON=0; QUIET=0
RESULT_KEYS=(); RESULT_VALS=()

usage() {
  cat <<'EOF'
netease-music — 网易云音乐：直接调接口播放与控制（不点界面）

用法：netease-music <命令> [参数] [--json] [--quiet]

播放：
  daily [--limit N] [--shuffle]     每日推荐，整列入队开播
  play <关键词|歌曲id|歌单id|歌单链接> [--shuffle] [--limit N]
                                    关键词取最匹配的一首；给歌单/歌手/专辑链接都能放
  play-ids <id,id,...> [--start N]   按输入顺序替换队列，N 从 1 开始（默认 1；单个逗号分隔参数）
  search <关键词> [--limit N]        只看不播：列出搜索结果
  cover <歌曲关键词|id> [--download PATH] [--force]
                                    封面 JSON；可下载至 PATH（最多 10 MB，覆盖需 --force）
  download <关键词|id> [--level 档] [-o 目录] [--force]
                                    把一首歌下到本地：默认从 hires 往下取最高可用档（best）
  downloads                         只看不播：列出本地已下载、文件还在的歌曲
  liked [--shuffle]                 我喜欢的音乐（整列入队）
  liked-ids [--json]                只读喜欢 ID 全表；JSON 为 {count,total,ids:[数字,...]}
  artist <歌手|id> [--limit N]      歌手热门整列入队（默认 50 首）
  album <专辑|id> [--limit N]       专辑整张按顺序入队（搜不到正版先用 albums 拿 id）
  myplaylists [collected|own] [--limit N] [--offset N]
                                    我的歌单（含「我喜欢的音乐」id；collected 只看收藏的）
  albums <歌手|id> [--limit N]      只看不播：列出歌手的专辑（含搜索里搜不到的老专辑）
歌单与榜单：
  playlist <歌单名|id|链接> [--shuffle]  放一张歌单（别人的也行，名字直接写）
  playlists <关键词> [--limit N]    只看不播：搜歌单（含作者、是否已收藏）
  charts [--limit N]                只看不播：列排行榜（飙升榜/新歌榜/…）
  chart <榜名|id> [--shuffle]       放某个榜单（例：chart 飙升榜）
  myalbums / myartists [--limit N]  只看不播：我收藏的专辑 / 歌手
  fm [--limit N] [--shuffle]        私人 FM（没听过的）
  dislike [歌曲id]                  私人 FM 不喜欢；省略 id 用当前歌曲，只上报，不自动切歌
  recent [--limit N]                只看不播：最近播放
  replay [N]                        再放一次最近第 N 首（默认 1）
  podcasts [--recommend] [--limit N]  只看不播：我的播客订阅（--recommend 看推荐的）
  podcast <播客名|id> [--limit N]   放某播客最新 N 期（默认 3）
  episode <节目id>                  放某一期（id 从 podcast 列表里抄）
队列现场：
  queue [--limit N]                 看队列：每首歌名、时长，标出正在放的那首
  jump <N>                          跳到队列第 N 首（从 1 开始）
  add <歌曲|id>                     把一首加到队尾（不动正在放的那首）
  remove <N>                        删除 queue 显示的第 N 首；当前项选下一首，末尾选上一首，删空停止
  clear                             停止并清空队列及本地队列文件（保留快照）
  queues                            看本地的队列快照（每次换队列会自动留一条「上一条」）
  queue-save [名字]                 把当前队列存成命名快照
  queue-load <名字>                 载入某个快照（当前这条会留成「上一条」）
  back                              切回上一条队列（含当时放到哪儿）
控制：
  pause / resume / toggle           暂停 / 继续 / 切换
  next / prev / stop                下一首 / 上一首 / 停止
  volume [0-130]                    不填=读当前音量，填了=设置
  seek <秒|+n|-n>                   跳进度（相对）
  status                            当前播放状态（mpv 真值 + 曲目信息）
  lyric [--all]                     当前这首歌的歌词（默认只显示当前句与下一句）
  like / unlike [--unlike]          喜欢 / 取消喜欢当前这首歌
  shuffle on|off                    随机开关
  repeat off|list|single            关闭 / 整列循环 / 单曲循环（on = list）；status 带 repeat_mode
配置：
  setup [--cookie 值] [--quality 级别]  写配置（不带参数=告诉你登录的两种办法）
  login [--timeout 300] [--refresh 4]  扫码登录（码 5 分钟过期，自动换新；cookie 只存本机）
  login --sms [手机号] [--sms-code <验证码>]  短信验证码登录（推荐，比扫码稳）：发码后跑 login --sms-code <码>；手机号记在本机
  check                             自检：依赖 / 登录态 / mpv / 音质
  watch [--notify]                  只读巡检登录态：正常安静退 0，掉登录报 error=auth；--notify 额外推手机
  help [命令]

输出：首行是人读结论，随后 key=value；读取类命令都带 source=api 与 as_of=<ISO 时刻>（说清数据来自哪个接口、什么时候取的）。
      cover 始终只输出一个 JSON 对象；liked-ids --json 输出完整数字 ID 数组（均不改变队列或登录态）。
旗标：--json 输出 JSON；--quiet 不打印人读结论行；--notify 只在巡检失败时推手机（watch）
分页：列表用 --limit N --offset N；offset 默认 0，跳过 N 条；后端 JSON 的 count 是本页条数，total 是总数。
      适用 daily / playlist / liked / album / artist / albums / chart / search / playlists / myplaylists / charts / myalbums / myartists / recent / podcasts / podcast。
环境变量（或 local/skills/netease-music/config.json）：
  NETEASE_MUSIC_STATE_DIR         状态目录（cookie/队列/缓存，默认 ~/.local/state/netease-music）
  NETEASE_MUSIC_COOKIE            登录 cookie（MUSIC_U=…）
  NETEASE_MUSIC_QUALITY           音质：standard/higher/exhigh/lossless/hires（默认 lossless）
  NETEASE_MUSIC_DOWNLOAD_DIR      download 默认保存目录（默认 ~/Music，会被自动创建）
退出码：0 成功；2 用法错；3 缺依赖或未登录；4 找不到歌曲/歌单；5 执行失败
EOF
}

cmd_help() {
  case "${1:-}" in
    daily)   echo "daily — 拉今日「每日推荐」整列入队播放；--limit N 只取前 N 首，--shuffle 随机。" ;;
    play)    echo "play <关键词|id|歌单链接> — 关键词→搜最匹配一首；纯数字→歌曲 id；歌单链接或 playlist:<id>→整张列表。会跳过无版权/VIP 不可播的。" ;;
    play-ids) echo "play-ids <id,id,...> [--start N] — id 列表是单个无空格逗号分隔参数，顺序与重复项保留；N 为输入列表的 1 基序号，默认 1。不支持 --shuffle；指定歌曲不可播/详情缺失时报错，旧队列不变；其他无地址项跳过。例：play-ids 1000,1001,1002 --start 2。" ;;
    search)  echo "search <关键词> [--limit N] — 只列出结果（id / 歌名 / 歌手 / 时长 / 是否需 VIP），不播放。" ;;
    cover)   echo "cover <歌曲关键词|id> [--download PATH] [--force] — 输出 {id,name,artist,cover}；下载输出 {id,cover,file,bytes}，最多 10 MB（10000000 字节），覆盖需 --force；不改变队列或登录态。" ;;
    download) echo "download <关键词|id> [--level 档] [-o 目录] [--force] — 把一首歌下到本地：档位 standard/higher/exhigh/lossless/hires，缺省 best（从 hires 往下取第一个有地址的）；目录优先 -o，其次 config download_dir，默认 ~/Music；重名需 --force；--json 字段 id/name/artist/level/br/file/bytes/at。" ;;
    downloads) echo "downloads — 只读：列出本地已下载的歌曲（登记表里文件还在的）；--json 为 {count,total,downloads:[…]}。" ;;
    liked)   echo "liked — 把「我喜欢的音乐」整列入队播放。" ;;
    liked-ids) echo "liked-ids [--json] — 只读喜欢 ID 全表；--json 为 {count,total,ids:[数字,...]}，不分页。歌曲 JSON 有明确布尔 liked 才透传，缺字段时用这张全表按 id 判定。" ;;
    myplaylists) echo "myplaylists [collected|own] [--limit N] [--offset N] — 分页列出我的歌单；collected/own 在本页内筛选。" ;;
    artist)  echo "artist <歌手|id> [--limit N] — 歌手热门整列入队（默认 50 首；也可直接给数字 id，如 6452=周杰伦）。" ;;
    album)   echo "album <专辑|id> [--limit N] — 专辑整张按顺序入队（默认 200 首）。搜不到正版专辑时先跑 albums <歌手> 拿 id。" ;;
    albums)  echo "albums <歌手|id> [--limit N] — 只列出这位歌手的专辑（id / 专辑名 / 年份 / 曲目数），不播放。" ;;
    queue)   echo "queue [--limit N] — 打印队列（mpv 真值）：每首序号、歌名、时长，正在放的那首带 ← 正在放。" ;;
    jump)    echo "jump <N> — 跳到队列第 N 首（从 1 开始），并回读状态确认。" ;;
    remove)  echo "remove <N> — 按 queue 显示的 1 基序号删除；删除当前项选下一首，末尾选上一首，删空则停止；保留暂停状态，同步本地队列文件。" ;;
    clear)   echo "clear — 停止并清空 mpv 和本地队列文件，收掉保活；配置和快照保留，可重复调用。" ;;
    pause|resume|toggle) echo "$1 — 控制播放状态（mpv 真值）。" ;;
    next|prev) echo "$1 — 队列上下首。" ;;
    volume)  echo "volume [0-130] — 不带参数读当前音量，带参数设置。" ;;
    lyric)   echo "lyric [--all] — 打印当前歌曲歌词；默认只显示当前句与下一句（按播放进度对齐）。" ;;
    like)    echo "like / unlike — 把当前播放的这首加入/移出「我喜欢的音乐」。" ;;
    dislike) echo "dislike [歌曲id] — 提交私人 FM 的 fm/trash；省略 id 用当前歌曲，显式 id 必须是正整数。只上报不喜欢，不自动跳歌或改队列；成功以接口 code=200 为准。" ;;
    repeat)  echo "repeat off|list|single — 关闭 / 整列循环 / 单曲循环；on 和无参数沿用 list。status 的 repeat_mode 报 off/list/single，原 repeat 布尔字段仍表示整列循环。" ;;
    setup)   echo "setup [--cookie 值] [--quality 级别] [--dir 目录] — 把 cookie/音质/下载目录写进 config.json；不带参数只打印怎么登录。" ;;
    login)   echo "login [--timeout 300] [--refresh 4] — 扫码登录；login --sms [手机号] 发验证码，再 login --sms-code <验证码> 完成（推荐，比扫码稳）；手机号记在本机，cookie 只存 config.json。" ;;
    status)  echo "status — 当前在放什么/进度/音量/队列位置，全部来自 mpv；repeat_mode 为 off/list/single。" ;;
    check)   echo "check — 只读自检：依赖、登录态、mpv 是否可用、默认音质。" ;;
    watch)   echo "watch [--notify] — 只读巡检登录态（真发一次账号请求）：正常安静退 0；掉登录报 error=auth 并给重新登录命令，--notify 顺手推手机。挂定时任务用。" ;;
    playlist) echo "playlist <歌单名|id|链接> — 放一张歌单，别人的也行（名字直接写：playlist 夜跑）。" ;;
    playlists) echo "playlists <关键词> [--limit N] — 只列出搜到的歌单（id / 名字 / 曲目数 / 作者 / 是否已收藏）。" ;;
    charts)  echo "charts [--limit N] — 只列出排行榜（id / 名字 / 曲目数 / 更新频率）。" ;;
    chart)   echo "chart <榜名|id> [--limit N] — 放某个榜单整列（例：chart 飙升榜）。" ;;
    myalbums|myartists) echo "$1 [--limit N] — 只列出我收藏的专辑 / 歌手（id 可直接喂 album/artist）。" ;;
    fm)      echo "fm [--limit N] — 私人 FM（没听过的），整列入队开播。" ;;
    recent)  echo "recent [--limit N] — 只列出最近播放（一周，含播放次数）。" ;;
    replay)  echo "replay [N] — 再放一次最近第 N 首（默认 1 = 最近那首）。" ;;
    podcasts) echo "podcasts [--recommend] [--limit N] — 只列出我的播客订阅（或推荐的播客）。" ;;
    podcast) echo "podcast <播客名|id> [--limit N] — 放某播客最新 N 期（默认 3）。" ;;
    episode) echo "episode <节目id> — 放某一期节目（id 从 podcast 输出里抄）。" ;;
    queues)  echo "queues — 看本地的队列快照：文件、首数、存的时间、来源。" ;;
    queue-save) echo "queue-save [名字] — 把当前队列存成命名快照（快照只存歌单列表，地址回放时重取）。" ;;
    queue-load) echo "queue-load <名字> — 载入某个快照，回到它当时的位置；当前这条会留成「上一条」。" ;;
    back)    echo "back — 切回上一条队列（含当时的位置与随机状态）；再 back 一次就切回来。" ;;
    add)     echo "add <歌曲|id> — 把一首加到当前队列尾部，不动正在放的那首。" ;;
    *)       usage ;;
  esac
  case "${1:-}" in
    daily|playlist|liked|album|artist|albums|chart|search|playlists|myplaylists|charts|myalbums|myartists|recent|podcasts|podcast)
      echo "分页：--offset N 从 0 起跳过 N 条，--limit N 最多取 N 条；JSON 的 total 优先用接口总数，缺失时用接口返回的条数。" ;;
  esac
}

die() { printf 'error=%s\nhint=%s\n' "$1" "$2" >&2; exit "${3:-1}"; }
kv() { RESULT_KEYS+=("$1"); RESULT_VALS+=("$2"); }
kv_api_total() { # total 只补进 JSON，保留原有人读结果块
  [ "$JSON" = 1 ] || return 0
  kv total "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["total"])' <<<"$1")"
}
flush_result() {
  local head="$1" i
  if [ "$JSON" = 1 ]; then
    local argv=("$head")
    [ "${#RESULT_KEYS[@]}" -gt 0 ] && argv+=("${RESULT_KEYS[@]}")
    argv+=(--sep--)
    [ "${#RESULT_VALS[@]}" -gt 0 ] && argv+=("${RESULT_VALS[@]}")
    python3 - "${argv[@]}" <<'PY'
import json, sys
a = sys.argv[1:]
i = a.index('--sep--')
head, keys, vals = a[0], a[1:i], a[i + 1:]
print(json.dumps({"ok": True, "conclusion": head, **dict(zip(keys, vals))}, ensure_ascii=False))
PY
  else
    [ "$QUIET" = 1 ] || printf '%s\n' "$head"
    [ "${#RESULT_KEYS[@]}" -gt 0 ] || return 0
    for i in "${!RESULT_KEYS[@]}"; do printf '%s=%s\n' "${RESULT_KEYS[$i]}" "${RESULT_VALS[$i]}"; done
  fi
}
now() { date +%Y-%m-%dT%H:%M:%S%z; }
mmss() { local s="${1:-0}"; printf '%d:%02d' $((s / 60)) $((s % 60)); }

env_get() { local v; v="$(env | sed -n "s/^$1=//p" | head -1)"; printf '%s' "$v"; }
conf_get() {
  [ -f "$CFG" ] || return 0
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
v=d.get(sys.argv[2])
print(v if isinstance(v,str) else ("" if v is None else v))' "$CFG" "$1" 2>/dev/null
}
conf_set() { # conf_set <键> <值>
  mkdir -p "$LOCAL_DIR"
  python3 - "$CFG" "$1" "$2" <<'PY'
import json, os, sys
p, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: d = {}
d[k] = v
json.dump(d, open(p, 'w'), indent=2, ensure_ascii=False)
PY
}

download_dir() { # download 默认保存目录：环境变量 > config > ~/Music（~ 展开）
  local d
  d="$(env_get NETEASE_MUSIC_DOWNLOAD_DIR)"
  [ -n "$d" ] || d="$(conf_get download_dir)"
  [ -n "$d" ] || d="$HOME/Music"
  printf '%s' "${d/#\~/$HOME}"
}

need_deps() {
  command -v node >/dev/null 2>&1 || die deps "缺 node" 3
  command -v python3 >/dev/null 2>&1 || die deps "缺 python3" 3
  [ -f "$API" ] || die deps "缺脚本 $API" 3
}

api() { # api <命令> [参数]；stdout=JSON，stderr=错误 JSON
  NETEASE_COOKIE="$COOKIE" node "$API" "$@" --offset "$OFFSET"
}
api_field() { # api_field <stderr-file> <field> <fallback>：取最后一行错误 JSON
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, field, fallback = sys.argv[1:4]
for line in reversed(open(path, encoding="utf-8", errors="replace").read().splitlines()):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        data = json.loads(line)
    except Exception:
        continue
    print(data.get(field) or "")
    break
else:
    print(fallback)
PY
}
api_or_die() {
  local out err rc
  err="$(mktemp)"; out="$(api "$@" 2>"$err")"; rc=$?
  if [ $rc -ne 0 ]; then
    local code hint
    # stderr 也会带进度行（安全验证是一边等手机确认一边输出），
    # 所以按最后一行 JSON 取错误，不能把整份 stderr 当 JSON 解析
    code="$(api_field "$err" error external)"
    hint="$(api_field "$err" hint "接口调用失败")"
    rm -f "$err"
    die "${code:-external}" "${hint:-接口调用失败}" "$rc"
  fi
  rm -f "$err"
  printf '%s' "$out"
}
api_out() { # api_out <参数...>：与 api_or_die 同，但用在 $( ) 里也能让整个脚本停下来
  local out rc
  out="$(api_or_die "$@")"; rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  printf '%s' "$out"
}
mpvctl() { node "$MPVCTL" "$@"; }
mpvctl_or_die() {
  local out rc
  out="$(mpvctl "$@")"; rc=$?
  [ $rc -eq 0 ] || exit $rc
  printf '%s' "$out"
}

# ---------- 队列：把歌曲列表变成 mpv 能放的 m3u8 + 记录 id 的 queue.json ----------
build_queue() { # stdin = 接口返回的歌曲 JSON 数组
  local raw; raw="$(cat)"
  mkdir -p "$LOCAL_DIR"
  local stage rc
  stage="$(mktemp -d "$LOCAL_DIR/.queue-build.XXXXXX")" || return 5
  printf '%s' "$raw" > "$stage/songs.json"
  : > "$stage/urls.txt"
  local chunk=() id
  for id in $(python3 -c 'import json,sys
print(" ".join(str(s["id"]) for s in json.load(open(sys.argv[1]))))' "$stage/songs.json"); do
    chunk+=("$id")
    if [ ${#chunk[@]} -ge 200 ]; then
      collect_urls "$stage" "${chunk[@]}"
      rc=$?; [ "$rc" -eq 0 ] || { rm -rf "$stage"; return "$rc"; }
      chunk=()
    fi
  done
  if [ ${#chunk[@]} -gt 0 ]; then
    collect_urls "$stage" "${chunk[@]}"
    rc=$?; [ "$rc" -eq 0 ] || { rm -rf "$stage"; return "$rc"; }
  fi
  # 直链节点可能整片 403（实测 m804/m704 对我们的出口就整片拒绝，而同一 path+query
  # 在 m801/m802/m803 是 206）：起播前只按族抽一条探一探，坏了整族换到可用节点就走，
  # 避免 mpv 直接把歌跳过去。逐条 --all 的修复放到起播之后的保活里（refresh-urls.sh
  # 启动时先补一遍），起播等待因此只剩一两次探测的时间。
  if [ -s "$stage/urls.txt" ] && command -v node >/dev/null 2>&1; then
    if node "$SKILL_DIR/scripts/lib/cdn-url.mjs" --sample 1 --concurrency 16 --timeout 2000 \
         < "$stage/urls.txt" > "$stage/urls.fixed" 2>"$stage/cdn.log"; then
      mv "$stage/urls.fixed" "$stage/urls.txt"
      local cdn_summary; cdn_summary="$(cat "$stage/cdn.log" 2>/dev/null)"
      case "$cdn_summary" in ''|*"fixed=0 dropped=0"*) ;; *) kv cdn "$cdn_summary" ;; esac
    fi
    rm -f "$stage/urls.fixed" "$stage/cdn.log"
  fi
  python3 "$SKILL_DIR/scripts/lib/build-queue.py" "$stage/songs.json" "$stage/urls.txt" "$stage/queue.json" "$stage/queue.m3u8" "$@"
  rc=$?; [ "$rc" -eq 0 ] || { rm -rf "$stage"; return "$rc"; }
  [ "${SKIP_SNAPSHOT:-0}" = 1 ] || snap_auto
  keepalive_stop
  local file
  for file in songs.json urls.txt queue.json queue.m3u8; do
    mv "$stage/$file" "$LOCAL_DIR/$file" || { rm -rf "$stage"; return 5; }
  done
  rmdir "$stage"
  date +%s > "$LOCAL_DIR/urls_at"     # 这批地址的取用时刻：网易云直链是限时签名，约 5 分钟就 403
}

collect_urls() { # collect_urls <stage> <id...>：本地已下载的直接用本地文件，其余走取地址接口
  local stage="$1"; shift
  local pick="" local_set=" " remaining=() id
  pick="$(python3 "$SKILL_DIR/scripts/lib/downloads.py" "$LOCAL_DIR" pick "$@" 2>/dev/null)" || pick=""
  if [ -n "$pick" ]; then
    printf '%s\n' "$pick" >> "$stage/urls.txt"
    local_set=" $(printf '%s\n' "$pick" | cut -f1 | tr '\n' ' ') "
  fi
  for id in "$@"; do
    case "$local_set" in *" $id "*) ;; *) remaining+=("$id") ;; esac
  done
  [ ${#remaining[@]} -gt 0 ] || return 0
  api_or_die url "${remaining[@]}" --level "$QUALITY" | pick_urls >> "$stage/urls.txt" || return $?
}

pick_urls() { # 从 url 接口的 JSON 里挑出 <id>\t<服务端给的档位>\t<url>，丢掉拿不到地址的
  python3 -c 'import json,sys
for it in json.load(sys.stdin)["items"]:
    if it.get("url"): print("%s\t%s\t%s" % (it["id"], it.get("level") or "", it["url"]))'
}

# ---------- mpv 顺序 ↔ queue.json：开 shuffle 后两者不同，只能按「歌」认，不能按位置 ----------
# 每首歌的稳定身份写在 m3u 标题里（[#id]），旧队列/地址刷新时回退按 URL、标题串认（见 lib/mpv-map.py）。
mpv_map() { python3 "$SKILL_DIR/scripts/lib/mpv-map.py" "$@"; }

song_by_id() { # 从 queue.json 按 id 取歌曲 JSON（单行）；取不到给空
  python3 - "$QUEUE" "${1:-}" <<'PY'
import json, sys
try: songs = json.load(open(sys.argv[1]))["songs"]
except Exception: sys.exit(0)
for s in songs:
    if str(s["id"]) == sys.argv[2]:
        print(json.dumps(s, ensure_ascii=False)); break
PY
}

cur_song_json() { # 当前 mpv 真正在放的那首（JSON）；没有/对不上给空
  local st; st="$(mpvctl status 2>/dev/null)" || return 0
  printf '%s' "$st" > "${TMPDIR:-/tmp}/nm_cur.$$"
  mpv_map now "$QUEUE" "$LOCAL_DIR/urls.txt" "${TMPDIR:-/tmp}/nm_cur.$$" 2>/dev/null
  rm -f "${TMPDIR:-/tmp}/nm_cur.$$"
}

cur_id() { cur_song_json | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null; }

jump_index_of_id() { # <歌曲id> → 该歌在 mpv 当前队列里的序号（1 起）；找不到给空
  local idx; mpvctl_or_die playlist > "${TMPDIR:-/tmp}/nm_pl.$$"
  idx="$(mpv_map find "$QUEUE" "$LOCAL_DIR/urls.txt" "$1" "${TMPDIR:-/tmp}/nm_pl.$$" 2>/dev/null)" || idx=""
  rm -f "${TMPDIR:-/tmp}/nm_pl.$$"
  printf '%s' "$idx"
}

jump_target() { # <队列第 N 首> → mpv 队列序号（随机播放时按歌定位，别跳错歌）
  local n="$1" id idx shuf
  case "$n" in ''|*[!0-9]*) die usage "jump 需要队列序号（例：netease-music jump 3）" 2 ;; esac
  id="$(python3 - "$QUEUE" "$n" <<'PY'
import json, sys
try: songs = json.load(open(sys.argv[1]))["songs"]
except Exception: sys.exit(0)
i = int(sys.argv[2]) - 1
print(songs[i]["id"] if 0 <= i < len(songs) else "")
PY
)"
  [ -n "$id" ] || die notfound "队列里没有第 $n 首（先 queue 看队列）" 4
  idx="$(jump_index_of_id "$id")"
  [ -n "$idx" ] && { printf '%s' "$idx"; return 0; }
  # 兜底：队列没打乱时序号就是序号；打乱了又定位不到就明确报出来，别静默跳错歌
  shuf="$(mpvctl_or_die status | python3 -c 'import json,sys;print(str(json.load(sys.stdin).get("shuffle",False)).lower())')"
  if [ "$shuf" != true ]; then printf '%s' "$n"; else
    die notfound "这首歌在当前 mpv 队列里定位不到（标题是旧格式或地址已刷新），随机播放时不能可靠跳转；先 shuffle off 或重放一次队列" 4
  fi
}

play_queue() { # play_queue [--index N]
  local total; total="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["songs"]))' "$QUEUE" 2>/dev/null || echo 0)"
  [ "${total:-0}" -gt 0 ] || die notfound "没有一首能播（可能都要 VIP 或没版权）：换一首/换张专辑，或先 search 看看" 4
  local sf n
  sf="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["skipped"])' "$QUEUE")"
  n="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["songs"]))' "$QUEUE")"
  kv queue "$n"
  [ "$sf" != "0" ] && kv skipped "${sf}（要 VIP 或没版权）"
  mpvctl_or_die play "$M3U" "$@" >/dev/null
  announce_queue_start "$n"
}

announce_queue_start() { # <n>：回读 mpv 真值并输出结论块（kv queue/skipped 已由调用方设置）
  local n="$1" cur="" i=0
  # mpv 开了 shuffle 时「正在放」不一定是第一首：等它真的开出声再回读（最多 1.5 秒）
  while [ "$i" -lt 10 ]; do
    cur="$(cur_song_json)"; [ -n "$cur" ] && break
    sleep 0.15; i=$((i + 1))
  done
  [ -n "$cur" ] || cur="$(song_by_id "$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]))["songs"];print(s[0]["id"])' "$QUEUE")")"
  local info now_name now_artist now_id now_level
  info="$(python3 -c 'import json,sys
s=json.load(sys.stdin)
print("%s\t%s\t%s\t%s" % (s["name"], s["artist"], s["id"], s.get("level") or ""))' <<<"$cur")"
  IFS=$'\t' read -r now_name now_artist now_id now_level <<<"$info"
  kv now_playing "$now_name - $now_artist"
  kv song_id "$now_id"
  kv quality "${now_level:-$QUALITY}"
  [ -n "$now_level" ] && [ "$now_level" != "$QUALITY" ] && kv quality_requested "$QUALITY"
  kv source mpv; kv as_of "$(now)"
  flush_result "开始播放：$now_name - ${now_artist}（队列 $n 首）"
  keepalive_start
}

resolve_start_url() { # <歌曲id>：本地已下载直接用文件，否则取直链并探一遍；拿不到给空，不退出脚本
  local id="$1" raw tmp fixed pick
  tmp="$(mktemp "${TMPDIR:-/tmp}/nm_start_url.XXXXXX")" || return 0
  fixed="${tmp}.fixed"
  pick="$(python3 "$SKILL_DIR/scripts/lib/downloads.py" "$LOCAL_DIR" pick "$id" 2>/dev/null)" || pick=""
  if [ -n "$pick" ]; then
    printf '%s\n' "$pick" > "$tmp"
  elif raw="$(api url "$id" --level "$QUALITY" 2>/dev/null)"; then
    printf '%s' "$raw" | pick_urls > "$tmp" || true
    # 单条也过一遍逐条探测：只有「这条现在真能放」才值得抢先出声。
    if [ -s "$tmp" ] && command -v node >/dev/null 2>&1 \
       && node "$SKILL_DIR/scripts/lib/cdn-url.mjs" --all --concurrency 8 --timeout 2000 \
            < "$tmp" > "$fixed" 2>/dev/null; then
      mv "$fixed" "$tmp"
    fi
  fi
  cat "$tmp"; rm -f "$tmp" "$fixed"
}

# ---------- 命令 ----------
cmd_daily() {
  local songs; songs="$(api_out daily --limit "$LIMIT")" || exit $?
  kv_api_total "$songs"
  python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$songs" | build_queue >/dev/null || exit $?
  apply_shuffle
  play_queue
}
cmd_liked() {
  local songs; songs="$(api_out liked --limit "${LIMIT:-1000}")" || exit $?
  kv_api_total "$songs"
  python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps(d["songs"]))' <<<"$songs" | build_queue >/dev/null || exit $?
  apply_shuffle
  play_queue
}
cmd_playlist() { # cmd_playlist <id|链接>
  local id="$1" songs
  songs="$(api_out playlist "$id" --limit "${LIMIT:-500}")" || exit $?
  kv_api_total "$songs"
  python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$songs" | build_queue >/dev/null || exit $?
  local name; name="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])' <<<"$songs")"
  apply_shuffle
  play_queue
}
cmd_artist() { # cmd_artist <关键词|id>
  local q="$1" songs
  [ -n "$q" ] || die usage "artist 需要歌手名或 id（例：netease-music artist 陈粒）" 2
  songs="$(api_out artist "$q" --limit "${LIMIT:-50}")" || exit $?
  kv_api_total "$songs"
  python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$songs" | build_queue >/dev/null || exit $?
  apply_shuffle
  play_queue
}
cmd_album() { # cmd_album <关键词|id>
  local q="$1" songs
  [ -n "$q" ] || die usage "album 需要专辑名或 id（找 id：netease-music albums <歌手>）" 2
  songs="$(api_out album "$q" --limit "${LIMIT:-200}")" || exit $?
  kv_api_total "$songs"
  python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$songs" | build_queue >/dev/null || exit $?
  apply_shuffle
  play_queue
}
cmd_albums() { # 歌手的专辑列表（只读）
  local q="$1" j n name
  [ -n "$q" ] || die usage "albums 需要歌手名或 id（例：netease-music albums 周杰伦）" 2
  j="$(api_out albums "$q" --limit "${LIMIT:-60}")" || exit $?
  kv_api_total "$j"
  name="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])' <<<"$j")"
  n="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  kv artist "$name"; kv count "$n"; kv source api; kv as_of "$(now)"
  flush_result "找到 $n 张专辑：$name"
  [ "$JSON" = 1 ] || python3 -c 'import json, sys
for a in json.load(sys.stdin)["albums"]:
    print("  %-10s %s  (%s, %d 首)" % (a["id"], a["name"], a["year"] or "—", a["size"]))' <<<"$j"
}
cmd_queue() { # 看队列（真值来自 mpv 的 playlist；时长对齐 queue.json）
  local st; st="$(mpvctl_or_die playlist)"
  python3 - "$st" "${LIMIT:-0}" "$QUEUE" "${TMPDIR:-/tmp}/nm_queue.$$" "${TMPDIR:-/tmp}/nm_queue_list.$$" "$LOCAL_DIR/urls.txt" <<'INNER_PY_END'
import json, re, sys
st = json.loads(sys.argv[1])
limit = int(sys.argv[2]) if sys.argv[2] else 0
qpath, kvout, listout, urls_path = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
count = st.get("count", 0); pos = st.get("pos", -1); entries = st.get("entries", [])
q = {}
try: q = json.load(open(qpath))
except Exception: pass
songs = q.get("songs") or []
by_id = {str(s["id"]): s for s in songs}
def strip_query(u): return (u or "").split("?")[0]
by_url = {}   # 旧格式标题/地址刷新前：条目 filename → 歌 id
try:
    for line in open(urls_path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[-1]:
            by_url[strip_query(parts[-1])] = parts[0]
except OSError:
    pass
if limit: entries = entries[:limit]
def entry_song(e):   # 身份：标题 [#id] → URL → 标题串「歌手 - 歌名」；都不行就不配时长（宁可缺，不可错）
    t = e.get("title") or ""
    m = re.match(r"^\[#(\d+)\]\s*", t)
    sid = m.group(1) if m else by_url.get(strip_query(e.get("filename") or ""))
    if sid and sid in by_id:
        return by_id[sid], re.sub(r"^\[#\d+\]\s*", "", t)
    for s in songs:
        if t.strip() == "%s - %s" % (s.get("artist") or "", s.get("name") or ""):
            return s, t
    return None, t
with open(kvout, "w") as kf, open(listout, "w") as lf:
    kf.write("HEAD\t" + ("队列 %d 首（当前第 %d 首）" % (count, pos + 1) if count else "队列是空的（先 play / daily / liked / artist / album）") + "\n")
    for e in entries:
        i = e["index"] - 1
        s, title = entry_song(e)
        ms = (s.get("ms") or 0) if s else (int(e["duration"]) * 1000 if e.get("duration") else 0)
        dur = ("  %d:%02d" % (ms // 60000, ms // 1000 % 60)) if ms else ""
        lf.write("%4d. %s%s%s\n" % (e["index"], title or "(未知)", dur, "  ← 正在放" if i == pos else ""))
    kf.write("count\t%d\n" % count)
    if pos >= 0: kf.write("pos\t%d\n" % (pos + 1))
    kf.write("source\tmpv\n")
INNER_PY_END
  local head; head="$(head -1 "${TMPDIR:-/tmp}/nm_queue.$$" | cut -f2-)"
  while IFS=$'\t' read -r k v; do [ "$k" = HEAD ] || kv "$k" "$v"; done < "${TMPDIR:-/tmp}/nm_queue.$$"
  kv as_of "$(now)"
  flush_result "$head"
  [ "$JSON" = 1 ] || cat "${TMPDIR:-/tmp}/nm_queue_list.$$"
  rm -f "${TMPDIR:-/tmp}/nm_queue.$$" "${TMPDIR:-/tmp}/nm_queue_list.$$"
}

cmd_play() { # cmd_play <关键词|id|链接>
  local arg="$1"
  case "$arg" in
    *music.163.com*artist*|artist:*) cmd_artist "${arg#artist:}"; return ;;
    *music.163.com*album*|album:*)   cmd_album "${arg#album:}"; return ;;
    *music.163.com*playlist*|*music.163.com*toplist*|playlist:*|*list=*)
      cmd_playlist "${arg#playlist:}"; return ;;
  esac
  if [ -z "$arg" ]; then die usage "play 需要关键词、歌曲 id 或歌单链接" 2; fi
  local one id rc=0
  one="$(api_or_die song "$arg" 2>/dev/null)" || rc=$?
  if [ $rc -ne 0 ]; then           # 纯数字又说「没这首歌」：多半给的是歌单 id
    case "$arg" in
      *[!0-9]*) api_or_die song "$arg" >/dev/null ;;  # 非数字：把原样报错交给用户
      *)        cmd_playlist "$arg" ;;
    esac
    return
  fi
  id="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<<"$one")"
  local songs; songs="$(api_out song "$id")" || exit $?
  python3 -c 'import json,sys;s=json.load(sys.stdin);print(json.dumps([s]))' <<<"$songs" | build_queue >/dev/null || exit $?
  play_queue
}
cmd_play_ids() {
  local j index start_id url_file url_pid="" started=0 rc=0
  [ "${#ARGS[@]}" -eq 1 ] || die usage "用法：play-ids <id,id,...> [--start N]" 2
  [ "$SHUFFLE" = 0 ] || die usage "play-ids 按输入顺序播放，不支持 --shuffle" 2
  start_id="$(python3 -c 'import sys
ids = [i for i in sys.argv[1].split(",") if i]
n = int(sys.argv[2])
print(ids[n - 1] if 0 < n <= len(ids) else "")' "${ARGS[0]}" "$START")"
  # 选中那首的地址和整列详情互不依赖：地址先在后台取、先探，详情一回来就能先出声；
  # 整条队列随后建好，再整队接到正在放的那首两侧（不重开、不打断）。
  url_file="$(mktemp "${TMPDIR:-/tmp}/nm_start.XXXXXX")" || exit 5
  if [ -n "$start_id" ]; then
    ( resolve_start_url "$start_id" > "$url_file" ) &
    url_pid=$!
  fi
  j="$(api_out play-ids "${ARGS[0]}" --start "$START")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -n "$url_pid" ] && kill "$url_pid" 2>/dev/null
    rm -f "$url_file"; exit "$rc"
  fi
  # 选中那首的地址先探好：探通才起播抢先；探不通就走整列开播的老路。
  [ -n "$url_pid" ] && { wait "$url_pid" 2>/dev/null || true; }
  local start_line; start_line="$(head -1 "$url_file" 2>/dev/null)"
  rm -f "$url_file"
  local skip_snap=0
  if [ -n "$start_line" ]; then
    # 旧队列先留档、旧保活先停：起播抢先会换掉 mpv 队列，保活不能对着临时队列改地址。
    snap_auto
    keepalive_stop
    local start_url start_title tmp_m3u
    start_url="$(cut -f3 <<<"$start_line")"
    start_title="$(python3 -c 'import json,sys
d = json.load(sys.stdin); sid = sys.argv[1]
s = next((x for x in (d.get("songs") or []) if str(x["id"]) == sid), {})
print("[#%s] %s - %s" % (sid, s.get("artist") or "", s.get("name") or ""))' "$start_id" <<<"$j")"
    tmp_m3u="${TMPDIR:-/tmp}/nm_start.$$.m3u"
    printf '#EXTM3U\n#EXTINF:-1,%s\n%s\n' "$start_title" "$start_url" > "$tmp_m3u"
    node "$MPVCTL" play "$tmp_m3u" --index 0 >/dev/null 2>&1 && started=1
    rm -f "$tmp_m3u"
    skip_snap=1
  fi
  SKIP_SNAPSHOT="$skip_snap" python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$j" | SKIP_SNAPSHOT="$skip_snap" build_queue "$START" >/dev/null || exit $?
  # 建队成功后才关随机：失败的 play-ids 不该动 mpv（选中项无地址时 build_queue 已带错退出）。
  mpvctl_or_die shuffle off >/dev/null
  index="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["start"] - 1)' "$QUEUE")"
  kv start "$START"
  if [ "$started" = 1 ]; then
    # 接不上（mpv 拒绝或最后一条数不对）就退回整列开播，宁愿重开一小下也要队列对齐。
    local attach_out attach_count total
    attach_out="$(node "$MPVCTL" attach "$M3U" --at "$index" 2>/dev/null)" || attach_out=""
    attach_count="$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("playlist") or 0)
except Exception: print(0)' <<<"$attach_out")"
    total="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["songs"]))' "$QUEUE")"
    [ "$attach_count" = "$total" ] || started=0
  fi
  if [ "$started" = 1 ]; then
    local n sf
    n="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["songs"]))' "$QUEUE")"
    sf="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["skipped"])' "$QUEUE")"
    kv queue "$n"
    [ "$sf" != "0" ] && kv skipped "${sf}（要 VIP 或没版权）"
    announce_queue_start "$n"
  else
    play_queue --index "$index"
  fi
}
cmd_remove() {
  local n="${ARGS[0]:-}" stage rc result
  [ "${#ARGS[@]}" -eq 1 ] && [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" =~ [1-9] ]] || die usage "remove 需要队列序号（从 1 开始）" 2
  mkdir -p "$LOCAL_DIR"
  stage="$(mktemp -d "$LOCAL_DIR/.queue-edit.XXXXXX")" || exit 5
  mpvctl playlist > "$stage/playlist.json"
  rc=$?; [ "$rc" -eq 0 ] || { rm -rf "$stage"; exit "$rc"; }
  python3 "$SKILL_DIR/scripts/lib/queue-edit.py" "$LOCAL_DIR" "$stage/playlist.json" "$n" "$stage"
  rc=$?; [ "$rc" -eq 0 ] || { rm -rf "$stage"; exit "$rc"; }
  result="$(mpvctl remove "$n")"
  rc=$?; [ "$rc" -eq 0 ] || { rm -rf "$stage"; exit "$rc"; }
  keepalive_stop
  local file
  for file in queue.json queue.m3u8 songs.json urls.txt; do
    mv "$stage/$file" "$LOCAL_DIR/$file" || { rm -rf "$stage"; exit 5; }
  done
  rm -rf "$stage"
  if [ "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$result")" -gt 0 ]; then keepalive_start; fi
  kv command remove; kv removed "$n"
  emit_status "已移除队列第 $n 首"
}
cmd_clear() {
  [ "${#ARGS[@]}" -eq 0 ] || die usage "用法：clear" 2
  mpvctl_or_die clear >/dev/null
  keepalive_stop
  rm -f "$QUEUE" "$M3U" "$LOCAL_DIR/songs.json" "$LOCAL_DIR/urls.txt" "$LOCAL_DIR/urls_at"
  kv command clear
  emit_status "已清空队列"
}
cmd_search() {
  local j; j="$(api_out search "$KEYWORD" --limit "$LIMIT")" || exit $?
  kv_api_total "$j"
  local list count
  list="$(python3 -c 'import json,sys
for i, s in enumerate(json.load(sys.stdin)["songs"], 1):
    print("%3d. %s — %s  [%s] %d:%02d%s  id=%s" % (i, s["name"], s["artist"], s["album"], s["ms"]//60000, s["ms"]//1000%60, "  VIP" if s["vip"] else "", s["id"]))' <<<"$j")"
  count="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  kv count "$count"; kv kw "$KEYWORD"; kv source api; kv as_of "$(now)"
  flush_result "搜到 $count 条：$KEYWORD"
  [ "$JSON" = 1 ] || printf '%s\n' "$list"
}
emit_status() { # emit_status [首行覆盖]：读 mpv 真值并打印状态块
  local st cur; st="$(mpvctl_or_die status)"
  cur="$(cur_song_json)"
  python3 - "$st" "$QUEUE" "$cur" <<'PY' > "${TMPDIR:-/tmp}/nm_status.$$"
import json, sys
st = json.loads(sys.argv[1]); q = {}
try: q = json.load(open(sys.argv[2]))
except Exception: pass
songs = q.get('songs', [])
try: s = json.loads(sys.argv[3]) if sys.argv[3].strip() else None
except Exception: s = None
if s is None:  # 映射不到（旧格式/异常）就退回按位置取
    s = songs[st['pos']] if 0 <= st['pos'] < len(songs) else None
print("HEAD\t" + ("正在播放：" + s['name'] + " - " + s['artist'] if s and st['playing'] else
      "已暂停：" + s['name'] + " - " + s['artist'] if s and st['paused'] else
      "没有在放" if st['idle'] else "播放中"))
if s:
    print(f"title\t{s['name']}"); print(f"artist\t{s['artist']}"); print(f"song_id\t{s['id']}")
print("state\t" + ("idle" if st['idle'] else "playing" if st['playing'] else "paused" if st['paused'] else "idle"))
if st['count']: print(f"queue_pos\t{st['pos']+1}/{st['count']}")
if st['elapsed'] is not None: print(f"elapsed\t{st['elapsed']}")
if st['duration'] is not None: print(f"duration\t{st['duration']}")
print(f"volume\t{st['volume']}"); print("repeat\t" + str(st['repeat']).lower()); print("shuffle\t" + str(st['shuffle']).lower())
print("repeat_mode\t" + st['repeat_mode'])
print("source\tmpv")
# The page's spectrum decodes the same stream, so it needs mpv's real path.
path = st.get('path') or ''
if path:
    print("path\t" + path)
PY
  local head; head="${1:-$(head -1 "${TMPDIR:-/tmp}/nm_status.$$" | cut -f2-)}"
  while IFS=$'\t' read -r k v; do [ "$k" = HEAD ] || kv "$k" "$v"; done < "${TMPDIR:-/tmp}/nm_status.$$"
  rm -f "${TMPDIR:-/tmp}/nm_status.$$"
  kv as_of "$(now)"
  flush_result "$head"
}
cmd_status() { emit_status; }
current_id() {
  local id; id="$(cur_id)"
  [ -n "$id" ] || die notfound "取不到当前歌曲（队列信息丢了），先 play/daily 一下" 4
  printf '%s' "$id"
}
cmd_myplaylists() { # 我创建 + 我收藏的歌单；[collected|own] 只列其中一类
  local mode="${1:-}" j list n
  j="$(api_out myplaylists --limit "${LIMIT:-100}")" || exit $?
  kv_api_total "$j"
  n="$(python3 -c 'import json,sys
p = json.load(sys.stdin)["playlists"]; m = sys.argv[1] if len(sys.argv) > 1 else ""
print(sum(1 for x in p if (m != "collected" or x.get("sub")) and (m != "own" or not x.get("sub"))))' "$mode" <<<"$j")"
  list="$(python3 -c 'import json,sys
m = sys.argv[1] if len(sys.argv) > 1 else ""
for p in json.load(sys.stdin)["playlists"]:
    if m == "collected" and not p.get("sub"): continue
    if m == "own" and p.get("sub"): continue
    print("  %s  %s（%d 首）%s" % (p["id"], p["name"], p["count"], "  [收藏的]" if p.get("sub") else ""))' "$mode" <<<"$j")"
  kv count "$n"; kv source api; kv as_of "$(now)"
  flush_result "我的歌单（$n 张${mode:+ · $mode}）"
  [ "$JSON" = 1 ] || printf '%s\n' "$list"
}

cmd_like() {
  local id name flag=true cur
  [ "${1:-}" = "--unlike" ] && flag=false
  cur="$(cur_song_json)"
  if [ -n "$cur" ]; then
    id="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<<"$cur")"
    name="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])' <<<"$cur")"
  else
    id=""; name=""
  fi
  [ -n "$id" ] || die notfound "取不到当前歌曲（队列信息丢了），先 play/daily 一下" 4
  if [ "$flag" = true ]; then api_or_die like "$id" >/dev/null; else api_or_die like "$id" --unlike >/dev/null; fi
  local now_liked lj; lj="$(api_out like-state "$id")" || exit $?
  now_liked="$(python3 -c 'import json,sys;print(str(json.load(sys.stdin)["liked"]).lower())' <<<"$lj")"
  kv song_id "$id"; kv title "$name"; kv liked "$now_liked"; kv as_of "$(now)"
  if [ "$now_liked" = true ]; then flush_result "已加入「我喜欢的音乐」：$name"; else flush_result "已移出「我喜欢的音乐」：$name"; fi
}
cmd_liked_ids() {
  local j ids count
  [ "${#ARGS[@]}" -eq 0 ] || die usage "用法：liked-ids" 2
  j="$(api_out liked-ids)" || exit $?
  if [ "$JSON" = 1 ]; then printf '%s\n' "$j"; return; fi
  count="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  ids="$(python3 -c 'import json,sys;print(",".join(map(str,json.load(sys.stdin)["ids"])))' <<<"$j")"
  kv count "$count"; kv ids "$ids"; kv_api_total "$j"; kv source api; kv as_of "$(now)"
  flush_result "我喜欢的歌曲 ID（$count 首）"
}
cmd_dislike() {
  local id="${ARGS[0]:-}" j
  [ "${#ARGS[@]}" -le 1 ] || die usage "用法：dislike [歌曲id]" 2
  if [ -z "$id" ]; then id="$(current_id)" || exit $?; fi
  j="$(api_out dislike "$id")" || exit $?
  kv song_id "$id"; kv disliked true; kv source api; kv as_of "$(now)"
  flush_result "已加入私人 FM 不喜欢：$id"
}
cmd_lyric() {
  local id; id="$(current_id)"
  local j; j="$(api_out lyric "$id" ${1:-})" || exit $?
  if [ "$JSON" = 1 ]; then
    kv lyric "$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("lyric",""))' <<<"$j")"
    kv song_id "$id"; kv as_of "$(now)"
    flush_result "歌词已取到（id=${id}）"
    return
  fi
  if [ "${1:-}" = "--all" ]; then
    local name; name="$(song_by_id "$id" | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')"
    kv song_id "$id"; kv title "$name"; kv source api; kv as_of "$(now)"
    flush_result "歌词：$name"
    python3 -c 'import json,sys;print(json.load(sys.stdin)["lyric"])' <<<"$j"
    return
  fi
  local pos
  pos="$(mpvctl_or_die status | python3 -c 'import json,sys;print(json.load(sys.stdin).get("elapsed") or 0)')"
  printf '%s' "$j" > "${TMPDIR:-/tmp}/nm_lyric.$$"
  python3 - "$pos" "${TMPDIR:-/tmp}/nm_lyric.$$" <<'PY'
import json, re, sys
cur = float(sys.argv[1])
lyric = json.load(open(sys.argv[2], encoding="utf-8"))["lyric"]
lines = []
for ln in lyric.splitlines():
    m = re.match(r"\[(\d+):(\d+(?:\.\d+)?)\](.*)", ln)
    if m and m.group(3).strip():
        lines.append((int(m.group(1)) * 60 + float(m.group(2)), m.group(3).strip()))
lines.sort()
if not lines:
    print("（纯音乐，没有歌词）")
else:
    i = max([k for k, (t, _) in enumerate(lines) if t <= cur] or [0])
    print("当前句：" + lines[i][1])
    if i + 1 < len(lines):
        print("下一句：" + lines[i + 1][1])
PY
  rm -f "${TMPDIR:-/tmp}/nm_lyric.$$"
}
cmd_setup() { # setup [--cookie 值] [--quality 级别]；不带参数就告诉你怎么登录
  local did=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cookie) conf_set cookie "$2"; did="$did cookie"; shift ;;
      --quality) conf_set quality "$2"; did="$did quality"; shift ;;
      --dir) conf_set download_dir "$2"; did="$did download_dir"; shift ;;
    esac
    shift
  done
  if [ -z "$did" ]; then
    kv config "$CFG"
    kv how "netease-music login --sms <手机号>（推荐：短信验证码）；或 login 扫码；或 setup --cookie 'MUSIC_U=…' 粘贴浏览器里的登录 cookie"
    kv as_of "$(now)"
    flush_result "netease-music 要登录才能用（每日推荐/我喜欢的/点播 VIP）：跑 netease-music login"
    return
  fi
  kv saved "$did"; kv config "$CFG"; kv as_of "$(now)"
  flush_result "配置已写入：$did"
}

mask_phone() { local p="$1"; [ ${#p} -ge 8 ] && printf '%s****%s' "${p:0:3}" "${p: -4}" || printf '%s' "$p"; }

cmd_login() { # 登录：默认扫码（过期自动换码）；--sms [手机号] / --sms-code 走短信验证码（推荐）
  need_deps
  local attempt=0 j key url png res state cookie sess nick uid
  if [ "$SMS_REQUEST" = 1 ]; then
    local phone="$SMS_PHONE"
    [ -n "$phone" ] || phone="$(conf_get phone)"
    [ -n "$phone" ] || die usage "短信登录要先给手机号：login --sms <手机号>" 2
    if [ -n "$SMS_CODE" ]; then
      res="$(api_out sms-login "$phone" "$SMS_CODE")" || exit $?
      cookie="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["cookie"])' <<<"$res")"
      conf_set cookie "$cookie"; COOKIE="$cookie"
      conf_set phone "$phone"
      sess="$(api_out session)" || exit $?
      nick="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["nick"])' <<<"$sess")"
      uid="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["uid"])' <<<"$sess")"
      kv nick "$nick"; kv uid "$uid"; kv config "$CFG"; kv as_of "$(now)"
      flush_result "登录成功：${nick}（cookie 已存 ${CFG}）"
    else
      api_or_die sms-send "$phone" >/dev/null
      conf_set phone "$phone"
      kv phone "$(mask_phone "$phone")"; kv as_of "$(now)"
      flush_result "验证码已发到 $(mask_phone "$phone")：拿到后跑 netease-music login --sms-code <验证码>（手机号已记在本机，换号再 --sms <新号>）"
    fi
    return
  fi
  while [ "$attempt" -lt "$REFRESH" ]; do
    attempt=$((attempt + 1))
    j="$(api_out qr-start)" || exit $?
    key="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["key"])' <<<"$j")"
    url="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])' <<<"$j")"
    png="/tmp/netease-login-qr-${key:0:8}.png"
    rm -f /tmp/netease-login-qr-*.png   # 旧的码一律删掉，避免扫到作废的那张
    osascript -e 'tell application "Preview" to close (every window whose name contains "netease-login-qr")' >/dev/null 2>&1 || true
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -o "$png" -s 8 -m 2 "$url"
      cp "$png" /tmp/netease-login-qr.png   # 稳定路径，方便找
      qrencode -t UTF8 -m 1 "$url"
      open -a Preview "$png" 2>/dev/null || open "$png" 2>/dev/null || true
    else
      kv qr_url "$url"
    fi
    echo "第 $attempt/$REFRESH 张码：${png}（刚弹到最前面）。用网易云 App 右上角「扫一扫」扫它，扫完在手机上点「确认登录」。过期自动换新。" >&2
    echo "扫了没反应/手机没出确认页？改用短信（更稳）：bash \"$SELF\" login --sms <手机号>" >&2
    res="$(api_out qr-poll "$key" --timeout "$TIMEOUT")" || exit $?
    state="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])' <<<"$res")"
    if [ "$state" = "ok" ]; then
      cookie="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["cookie"])' <<<"$res")"
      conf_set cookie "$cookie"
      COOKIE="$cookie"
      local sess nick uid
      sess="$(api_out session)" || exit $?
      nick="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["nick"])' <<<"$sess")"
      uid="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["uid"])' <<<"$sess")"
      kv nick "$nick"; kv uid "$uid"; kv config "$CFG"; kv as_of "$(now)"
      flush_result "登录成功：${nick}（cookie 已存 ${CFG}）"
      return
    fi
    [ "$state" = "expired" ] && echo "这张码过期了，自动换一张…（扫了没反应就换短信：login --sms <手机号>）" >&2 || die timeout "扫码没完成（state=${state}）" 5
  done
  die timeout "连着 $REFRESH 张码都没扫成（扫码不稳）：改用短信登录 netease-music login --sms <手机号>" 5
}
cmd_download() { # download <关键词|id> [--level 档] [-o 目录] [--force]
  local target="" level="" output="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --level) [ $# -gt 1 ] || die usage "--level 需要档位：standard/higher/exhigh/lossless/hires/best" 2; level="$2"; shift ;;
      -o|--output) [ $# -gt 1 ] || die usage "-o 需要目录（例：-o ~/Music/网易云音乐）" 2; output="$2"; shift ;;
      --force) force=1 ;;
      --level=*) level="${1#--level=}" ;;
      --output=*) output="${1#--output=}" ;;
      -*) die usage "download 不认识的参数：$1" 2 ;;
      *) [ -z "$target" ] || die usage "download 只接一首：歌名或歌曲 id" 2; target="$1" ;;
    esac
    shift
  done
  [ -n "$target" ] || die usage "download 需要歌名或歌曲 id（例：netease-music download 落叶归根 --level hires）" 2
  case "$level" in
    ""|best) level=best ;;
    standard|higher|exhigh|lossless|hires) ;;
    *) die usage "未知音质档位：${level}（可用 standard/higher/exhigh/lossless/hires/best）" 2 ;;
  esac
  command -v curl >/dev/null 2>&1 || die deps "缺 curl（下载音频文件要用）" 3

  local one id name artist
  one="$(api_out song "$target")" || exit $?
  id="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<<"$one")"
  name="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])' <<<"$one")"
  artist="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["artist"])' <<<"$one")"

  # 取地址：best 从 hires 往下逐档试，第一个有地址的就是这台账号能拿的最高档；
  # 指定档位只请求这一档（服务端仍可能按权限下调，实际档位看返回的 level）。
  local levels="$level" L j url="" got_level="" br=0
  [ "$level" = best ] && levels="hires lossless exhigh higher standard"
  for L in $levels; do
    j="$(api_out url "$id" --level "$L")" || exit $?
    url="$(python3 -c 'import json,sys
items=json.load(sys.stdin).get("items") or [{}]
print(items[0].get("url") or "")' <<<"$j")"
    [ -n "$url" ] || continue
    got_level="$(python3 -c 'import json,sys;print((json.load(sys.stdin).get("items") or [{}])[0].get("level") or "")' <<<"$j")"
    br="$(python3 -c 'import json,sys;print((json.load(sys.stdin).get("items") or [{}])[0].get("br") or 0)' <<<"$j")"
    break
  done
  [ -n "$url" ] || die notfound "《${name}》没有可下载地址（没版权或账号权限不够）：先用 search 看看有没有别的版本" 4

  local dir="$output"; [ -n "$dir" ] || dir="$(download_dir)"
  dir="${dir/#\~/$HOME}"
  mkdir -p "$dir" || die external "建不了目录：$dir" 5

  local fname stem e file bytes mb ext tmp at
  fname="$(python3 - "$artist" "$name" <<'PY'
import re, sys
s = "%s - %s" % (sys.argv[1], sys.argv[2])
s = re.sub(r'[/\\:*?"<>|\n\r\t]+', ',', s).strip()
print(s or "song")
PY
)"
  stem="$dir/$fname"
  if [ "$force" != 1 ]; then
    for e in flac mp3 m4a ogg; do
      [ -e "$stem.$e" ] && die conflict "已存在：$stem.${e}（要覆盖加 --force）" 5
    done
  fi
  tmp="$stem.part.$$"
  if ! curl -fsSL --retry 2 --max-time 900 -o "$tmp" "$url"; then
    rm -f "$tmp"; die external "下载失败（直链约 5 分钟过期，重跑一次会重新取地址）" 5
  fi
  ext="$(python3 - "$tmp" <<'PY'
import sys
b = open(sys.argv[1], "rb").read(16)
if b[:4] == b"fLaC": print("flac")
elif b[:3] == b"ID3" or (len(b) > 1 and b[0] == 0xFF and (b[1] & 0xE0) == 0xE0): print("mp3")
elif len(b) >= 12 and b[4:8] == b"ftyp": print("m4a")
elif b[:4] == b"OggS": print("ogg")
PY
)"
  if [ -z "$ext" ]; then rm -f "$tmp"; die external "下载到的不是音频（直链可能已过期）：重跑一次" 5; fi
  file="$stem.$ext"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; die external "写不进 $file" 5; }
  bytes="$(wc -c < "$file" | tr -d '[:space:]')"
  [ "${bytes:-0}" -gt 0 ] || { rm -f "$file"; die external "下载的文件是空的：$file" 5; }
  # 登记进本地库：队列构建靠它优先用本地文件，App 靠它显示「已下载」标记。
  at="$(python3 "$SKILL_DIR/scripts/lib/downloads.py" "$LOCAL_DIR" add "$id" "$name" "$artist" "$file" "$got_level" "$br" "$bytes" 2>/dev/null)" || at=""
  [ -n "$at" ] || at="$(now)"
  mb="$(python3 -c 'import sys;print("%.1f MB" % (int(sys.argv[1])/1048576))' "$bytes")"
  kv id "$id"; kv name "$name"; kv artist "$artist"; kv level "$got_level"; kv br "$br"
  kv file "$file"; kv bytes "$bytes"; kv at "$at"; kv source api; kv as_of "$(now)"
  flush_result "已下载：$artist - ${name}（${got_level}，${mb}）→ $file"
}

cmd_downloads() { # downloads：列出本地已下载的歌曲（只读）
  [ "${#ARGS[@]}" -eq 0 ] || die usage "用法：downloads" 2
  local j count
  j="$(python3 "$SKILL_DIR/scripts/lib/downloads.py" "$LOCAL_DIR" list)" || exit $?
  if [ "$JSON" = 1 ]; then printf '%s\n' "$j"; return; fi
  count="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  kv count "$count"; kv source local; kv as_of "$(now)"
  flush_result "已下载 $count 首（本地文件还在的）"
  python3 -c 'import json,sys
for e in json.load(sys.stdin)["downloads"]:
    print("  %-12s %s - %s（%s）" % (e.get("id"), e.get("artist") or "", e.get("name") or "", e.get("level") or ""))' <<<"$j"
}

cmd_check() {
  local ok=true b
  for b in node python3 mpv qrencode; do
    if command -v "$b" >/dev/null 2>&1; then kv "bin_$b" ok; else kv "bin_$b" missing; ok=false; fi
  done
  kv quality "$QUALITY"
  kv download_dir "$(download_dir)"
  kv cookie "$([ -n "$COOKIE" ] && echo "已配置（${#COOKIE} 字节）" || echo 未配置)"
  [ -n "$COOKIE" ] || ok=false
  if command -v node >/dev/null 2>&1; then
    local sess; sess="$(api session 2>/dev/null)"
    if [ -n "$sess" ]; then
      kv logged_in "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["loggedIn"])' <<<"$sess" 2>/dev/null || echo unknown)"
      kv nick "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["nick"])' <<<"$sess" 2>/dev/null || echo '')"
      kv uid "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["uid"])' <<<"$sess" 2>/dev/null || echo 0)"
    fi
    kv mpv "$(mpvctl status >/dev/null 2>&1 && echo ok || echo 起不来)"
  fi
  kv as_of "$(now)"
  [ "$ok" = true ] || { flush_result "自检未全绿（看下面字段）"; die deps "未登录跑 netease-music login；缺依赖用 brew install mpv qrencode" 3; }
  flush_result "netease-music 自检通过：接口与播放器都可用"
}

push_login_notice() { # push_login_notice <原因/修复提示>：只在巡检失败时调用；推送失败只报告，不改退出码
  local hint="$1" lib out rc
  # 手机推送是可选的外部能力：有 NETEASE_MUSIC_NOTIFY_LIB（一个 notify.mjs）就用，
  # 没有就安静跳过，不影响巡检退出码。
  lib="${NETEASE_MUSIC_NOTIFY_LIB:-$SKILL_DIR/../skill-interface/scripts/lib/notify.mjs}"
  if ! command -v node >/dev/null 2>&1 || [ ! -f "$lib" ]; then
    printf '通知：推送入口不可用，跳过手机提醒\n' >&2
    return 1
  fi
  out="$(node --input-type=module -e '
import { pathToFileURL } from "node:url";
const [lib, title, body] = process.argv.slice(1);
const { notify } = await import(pathToFileURL(lib).href);
const result = notify({ title, body, group: "netease-music" });
console.log(JSON.stringify(result));
process.exit(result.sent ? 0 : 1);
' "$lib" "网易云音乐：需要重新登录" "网易云音乐登录态巡检未通过：${hint}（巡检只读，不动队列与配置。）" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'notified=yes（已推手机）\n' >&2
  else
    printf 'notified=no（%s）\n' "$(printf '%s' "$out" | head -c 200)" >&2
  fi
}

cmd_watch() { # watch [--notify]：只读巡检登录态；坏掉才出声（挂定时任务用）
  need_deps
  local err sess rc code hint nick logged
  err="$(mktemp)"
  sess="$(api session 2>"$err")"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$sess" ]; then
    # 取不到登录态：按后端自己的错误码报（网络坏了就是 external，不能冒充掉登录）
    code="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("error") or "external")
except Exception: print("external")' "$err")"
    hint="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("hint") or "")
except Exception: print("")' "$err")"
    [ -n "$hint" ] || hint="巡检取不到登录态（退出码 ${rc}）：$(head -c 200 "$err")"
    rm -f "$err"
    if [ "$NOTIFY" = 1 ]; then push_login_notice "$hint"; fi
    case "$code" in auth) die "$code" "$hint" 3 ;; usage) die "$code" "$hint" 2 ;; *) die "$code" "$hint" 5 ;; esac
  fi
  rm -f "$err"
  logged="$(python3 -c 'import json,sys;print("true" if json.load(sys.stdin).get("loggedIn") else "false")' <<<"$sess" 2>/dev/null || echo false)"
  if [ "$logged" != true ]; then
    hint="登录已过期或未登录：跑 bash \"$SELF\" login（手机扫码，或 login --sms <手机号>）重新登录"
    if [ "$NOTIFY" = 1 ]; then push_login_notice "$hint"; fi
    die auth "$hint" 3
  fi
  if [ "$JSON" = 1 ] || [ "$QUIET" != 1 ]; then
    nick="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("nick") or "")' <<<"$sess" 2>/dev/null || echo '')"
    kv logged_in true
    [ -n "$nick" ] && kv nick "$nick"
    kv source api
    kv as_of "$(now)"
    flush_result "登录态正常${nick:+：$nick}（接口可用）"
  fi
}

apply_shuffle() { [ "${SHUFFLE:-0}" = 1 ] && mpvctl shuffle on >/dev/null; }

# ---------- 地址保活：直链约 5 分钟过期，长队列边走边换 ----------
# 建队时地址是新鲜的（起播零等待）；这里后台盯着，快过期就把「还没播到的部分」批量重取、
# 原地换掉 m3u 里对应的行。KEEPALIVE_PID 单独存，换队列时旧的就收掉。
KEEPALIVE_PID="$LOCAL_DIR/keepalive.pid"
KEEPALIVE_LOG="$LOCAL_DIR/keepalive.log"

keepalive_stop() {
  [ -s "$KEEPALIVE_PID" ] || return 0
  local pid; pid="$(cat "$KEEPALIVE_PID" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null ;; esac
  rm -f "$KEEPALIVE_PID"
}

keepalive_start() {
  keepalive_stop
  nohup "$SKILL_DIR/scripts/refresh-urls.sh" > "$KEEPALIVE_LOG" 2>&1 &
  echo $! > "$KEEPALIVE_PID"
}

# ---------- 队列现场：快照 / 切回 / 追加 ----------
# 一个 mpv 只有一条队列，任何「放 X」都会整列替换；所以建新队列之前，
# 自动把「当前这条」存成上一条快照（只存歌曲列表，地址回放时重取）。
QUEUES_DIR="$LOCAL_DIR/queues"
SKIP_SNAPSHOT=0

mpv_meta() { # 输出 "<pos> <shuffle>"；拿不到就给 "-1 false"
  local st; st="$(mpvctl status 2>/dev/null)" || { printf '%s' "-1 false"; return; }
  python3 -c 'import json,sys
try:
    d = json.loads(sys.argv[1]); print("%d %s" % (d.get("pos", -1), str(d.get("shuffle", False)).lower()))
except Exception: print("-1 false")' "$st"
}

snap_auto() { # 建新队列前留一份上一条（出错也不影响主流程）
  [ -s "$QUEUE" ] || return 0
  local m id; m="$(mpv_meta)"; id="$(cur_id)"
  python3 "$SKILL_DIR/scripts/lib/snapshot.py" save "$QUEUE" "$QUEUES_DIR/prev.json" \
    "${m%% *}" "${m##* }" "上一条" "${id:-}" >/dev/null 2>&1 || true
}

snap_save() { # snap_save <文件> <名字> [队列文件]：打一份快照
  local m id; m="$(mpv_meta)"; id="$(cur_id)"
  python3 "$SKILL_DIR/scripts/lib/snapshot.py" save "${3:-$QUEUE}" "$1" \
    "${m%% *}" "${m##* }" "$2" "${id:-}"
}

restore_snapshot() { # restore_snapshot <快照文件>：按快照重建队列，并回到当时的歌与随机状态
  local snap="$1" meta songs pos shuf sid
  meta="$(python3 "$SKILL_DIR/scripts/lib/snapshot.py" meta "$snap")" || die external "快照读不了：$snap" 5
  songs="$(python3 "$SKILL_DIR/scripts/lib/snapshot.py" songs "$snap")"
  pos="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("pos",-1))' <<<"$meta")"
  shuf="$(python3 -c 'import json,sys;print(str(json.load(sys.stdin).get("shuffle",False)).lower())' <<<"$meta")"
  sid="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("song_id") or "")' <<<"$meta")"
  SKIP_SNAPSHOT=1
  printf '%s' "$songs" | build_queue >/dev/null || exit $?
  SKIP_SNAPSHOT=0
  [ "$shuf" = true ] && mpvctl_or_die shuffle on >/dev/null || mpvctl_or_die shuffle off >/dev/null
  # 输出交给调用方（back / queue-load 会自己 emit_status），这里只负责把歌放起来
  # 开随机后「当时的位置」没有意义：优先回到当时在放的那首歌；旧快照没存 id 才退回位置
  if [ -n "$sid" ]; then
    play_queue >/dev/null
    local idx; idx="$(jump_index_of_id "$sid")"
    [ -n "$idx" ] && mpvctl_or_die jump "$idx" >/dev/null
  elif [ "${pos:-0}" -gt 0 ] 2>/dev/null; then play_queue --index "$pos" >/dev/null; else play_queue >/dev/null; fi
}

cmd_queues() { # 列出本地队列快照
  local rows n list
  rows="$(python3 "$SKILL_DIR/scripts/lib/snapshot.py" list "$QUEUES_DIR")"
  n="$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' <<<"$rows")"
  list="$(python3 -c 'import json,sys
for r in json.load(sys.stdin):
    tag = "上一条（back 切回）" if r["file"] == "prev.json" else r["name"]
    print("  %s  %d 首  %s  %s" % (r["file"], r["count"], (r["saved_at"] or "")[:16].replace("T", " "), tag))' <<<"$rows")"
  kv count "$n"; kv source local; kv as_of "$(now)"
  flush_result "本地队列快照（$n 条）"
  [ "$JSON" = 1 ] || [ "$n" = 0 ] && { [ "$JSON" = 1 ] || printf '  （还没有快照；每次放新的音乐会自己留一条「上一条」）\n'; } || printf '%s\n' "$list"
}

cmd_queue_save() { # 把当前队列存成命名快照
  [ -s "$QUEUE" ] || die notfound "现在没有队列可存" 4
  local name="$1" fname cnt out
  fname="$(python3 -c 'import re,sys
n = (sys.argv[1] or "").strip(); n = re.sub(r"[^\w.\-]+", "_", n, flags=re.UNICODE)[:40]
print(n)' "$name")"
  [ -n "$fname" ] || fname="save-$(date +%Y%m%d-%H%M%S)"
  out="$(snap_save "$QUEUES_DIR/$fname.json" "${name:-$fname}")" || die external "存快照失败" 5
  cnt="$(printf '%s' "$out" | cut -f2)"
  kv saved "$fname"; kv count "$cnt"; kv source local; kv as_of "$(now)"
  flush_result "已存队列快照：${fname}（$cnt 首）"
}

cmd_back() { # 切回上一条队列（含当时的位置；再 back 一次就切回来）
  [ -s "$QUEUES_DIR/prev.json" ] || die notfound "没有上一条可切回（用 queues 看有哪些快照）" 4
  local tmp="$QUEUES_DIR/.swap.json" meta name count
  [ -s "$QUEUE" ] && snap_save "$tmp" "下一条" >/dev/null 2>&1
  meta="$(python3 "$SKILL_DIR/scripts/lib/snapshot.py" meta "$QUEUES_DIR/prev.json")"
  name="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("name") or "")' <<<"$meta")"
  count="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("count") or 0)' <<<"$meta")"
  kv back_to "$name"; kv count "$count"
  restore_snapshot "$QUEUES_DIR/prev.json"
  [ -s "$tmp" ] && mv "$tmp" "$QUEUES_DIR/prev.json"
  emit_status "已切回上一条：${name}（$count 首）"
}

cmd_queue_load() { # 载入某个命名快照（当前这条会留成「上一条」，可 back 回来）
  local name="$1"; [ -n "$name" ] || die usage "queue-load 需要快照名（用 queues 看有哪些）" 2
  local f="$QUEUES_DIR/$(basename "$name")"
  [ -s "$f" ] || f="$QUEUES_DIR/$(basename "$name").json"
  [ -s "$f" ] || die notfound "没有这个快照：${name}（queues 看有哪些）" 4
  local meta count
  meta="$(python3 "$SKILL_DIR/scripts/lib/snapshot.py" meta "$f")" || die external "快照读不了：$f" 5
  count="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("count") or 0)' <<<"$meta")"
  [ -s "$QUEUE" ] && snap_save "$QUEUES_DIR/prev.json" "上一条" >/dev/null 2>&1
  kv loaded "$(basename "$f" .json)"; kv count "$count"
  restore_snapshot "$f"
  emit_status "已载入快照：$(basename "$f" .json)（$count 首）"
}

cmd_add() { # 往当前队列尾部加一首（不动正在放的那首）
  local q="$1"; [ -n "$q" ] || die usage "add 需要歌曲关键词或 id（例：netease-music add 幻听）" 2
  local song id name artist ms
  song="$(api_out song "$q")" || exit $?
  id="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<<"$song")"
  name="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])' <<<"$song")"
  artist="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["artist"])' <<<"$song")"
  ms="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("ms") or 0)' <<<"$song")"
  if [ ! -s "$QUEUE" ] || [ ! -s "$M3U" ]; then   # 还没队列：这一首就是队列
    python3 -c 'import json,sys;print(json.dumps([json.load(sys.stdin)]))' <<<"$song" | build_queue >/dev/null || exit $?
    play_queue; return
  fi
  local raw url
  raw="$(api_out url "$id" --level "$QUALITY")" || exit $?
  url="$(python3 -c 'import json,sys
d = json.load(sys.stdin); it = (d.get("items") or [{}])[0]; print(it.get("url") or "")' <<<"$raw")"
  [ -n "$url" ] || die notfound "这首拿不到播放地址（可能要 VIP 或已下架）：$name" 4
  local tmp="${TMPDIR:-/tmp}/nm_add.$$.m3u" res ok cnt
  res="$(python3 "$SKILL_DIR/scripts/lib/queue-append.py" "$QUEUE" "$M3U" "$tmp" "$id" "$name" "$artist" "$ms" "$url")"
  ok="$(python3 -c 'import json,sys;print(str(json.load(sys.stdin).get("ok",False)).lower())' <<<"$res")"
  if [ "$ok" != true ]; then
    rm -f "$tmp"
    cnt="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("count",0))' <<<"$res")"
    kv added no; kv count "$cnt"; kv source local; kv as_of "$(now)"
    flush_result "没加：$name - $artist 已经在队列里（队列 $cnt 首）"
    return
  fi
  mpvctl_or_die append "$tmp" >/dev/null; rm -f "$tmp"
  cnt="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("count",0))' <<<"$res")"
  kv added "$name - $artist"; kv count "$cnt"
  emit_status "已加到队尾：$name - ${artist}（队列 $cnt 首）"
}

# ---------- 歌单搜索 / 榜单 / 收藏 / 私人 FM / 最近 / 播客 ----------

cmd_playlists() { # 搜歌单（别人做的），只列不播
  local kw="${ARGS[0]:-}"; [ -n "$kw" ] || die usage "playlists 需要关键词（例：netease-music playlists 夜跑）" 2
  local j list n
  j="$(api_out playlists "$kw" --limit "${LIMIT:-20}")" || exit $?
  kv_api_total "$j"
  n="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  list="$(python3 -c 'import json,sys
for p in json.load(sys.stdin)["playlists"]:
    print("  %s  %s（%d 首 · %s）%s" % (p["id"], p["name"], p["count"], p["creator"], "  [已收藏]" if p["sub"] else ""))' <<<"$j")"
  kv count "$n"; kv source api; kv as_of "$(now)"
  flush_result "歌单搜索「${kw}」（$n 张）"
  [ "$JSON" = 1 ] || printf '%s\n' "$list"
}

cmd_charts() { # 列排行榜
  local j list n
  j="$(api_out charts --limit "${LIMIT:-100}")" || exit $?
  kv_api_total "$j"
  n="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  list="$(python3 -c 'import json,sys
for c in json.load(sys.stdin)["charts"]:
    print("  %s  %s（%s 首 · %s）" % (c["id"], c["name"], c["count"], c["freq"]))' <<<"$j")"
  kv count "$n"; kv source api; kv as_of "$(now)"
  flush_result "排行榜（$n 个）"
  [ "$JSON" = 1 ] || printf '%s\n' "$list"
}

cmd_chart() { # 放某个榜单（名字或 id）
  local q="$1"; [ -n "$q" ] || die usage "chart 需要榜单名（例：netease-music chart 飙升榜；全部榜单用 charts）" 2
  local j
  j="$(api_out chart "$q" --limit "${LIMIT:-500}")" || exit $?
  kv_api_total "$j"
  kv chart "$(python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("chart") or "")' <<<"$j")"
  python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$j" | build_queue >/dev/null || exit $?
  apply_shuffle
  play_queue
}

cmd_myalbums() { # 我收藏的专辑
  local j list n
  j="$(api_out myalbums --limit "${LIMIT:-60}")" || exit $?
  kv_api_total "$j"
  n="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  list="$(python3 -c 'import json,sys
for a in json.load(sys.stdin)["albums"]:
    print("  %s  %s（%s 首 · %s）" % (a["id"], a["name"], a["size"], a["artist"]))' <<<"$j")"
  kv count "$n"; kv source api; kv as_of "$(now)"
  flush_result "我收藏的专辑（$n 张）"
  [ "$JSON" = 1 ] || printf '%s\n' "$list"
}

cmd_myartists() { # 我收藏的歌手
  local j list n
  j="$(api_out myartists --limit "${LIMIT:-60}")" || exit $?
  kv_api_total "$j"
  n="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  list="$(python3 -c 'import json,sys
for a in json.load(sys.stdin)["artists"]:
    print("  %s  %s（专辑 %s 张）" % (a["id"], a["name"], a["albums"]))' <<<"$j")"
  kv count "$n"; kv source api; kv as_of "$(now)"
  flush_result "我收藏的歌手（$n 位）"
  [ "$JSON" = 1 ] || printf '%s\n' "$list"
}

cmd_fm() { # 私人 FM
  local j
  j="$(api_out fm --limit "${LIMIT:-12}")" || exit $?
  python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$j" | build_queue >/dev/null || exit $?
  apply_shuffle
  play_queue
}

cmd_recent() { # 最近播放（只列）
  local j list n
  j="$(api_out recent --limit "${LIMIT:-30}")" || exit $?
  kv_api_total "$j"
  n="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  list="$(python3 -c 'import json,sys
for i, s in enumerate(json.load(sys.stdin)["songs"], 1):
    print("  %2d  %s - %s（播放 %s 次）" % (i, s["name"], s["artist"], s.get("plays", "?")))' <<<"$j")"
  kv count "$n"; kv source api; kv as_of "$(now)"
  flush_result "最近播放（$n 首）"
  [ "$JSON" = 1 ] || printf '%s\n' "$list"
}

cmd_replay() { # 再放一次最近第 N 首（默认 1 = 最近那首）
  local n="${1:-1}" j id
  j="$(api_out recent --limit 30)" || exit $?
  id="$(python3 -c 'import json,sys
s = json.load(sys.stdin)["songs"]; i = int(sys.argv[1]) - 1
print(s[i]["id"] if 0 <= i < len(s) else "")' "$n" <<<"$j")"
  [ -n "$id" ] || die notfound "最近播放里没有第 $n 首" 4
  cmd_play "$id"
}

cmd_podcasts() { # 我的播客订阅（--recommend 看推荐的）
  local args=(podcasts --limit "${LIMIT:-50}") j list n
  [ "${RECOMMEND:-0}" = 1 ] && args+=(--recommend)
  j="$(api_out "${args[@]}")" || exit $?
  kv_api_total "$j"
  n="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' <<<"$j")"
  list="$(python3 -c 'import json,sys
for p in json.load(sys.stdin)["podcasts"]:
    print("  %s  %s（%s 期 · %s）" % (p["id"], p["name"], p["episodes"], p["dj"]))' <<<"$j")"
  kv count "$n"; kv source api; kv as_of "$(now)"
  flush_result "我的播客（$n 个）"
  [ "$JSON" = 1 ] || printf '%s\n' "$list"
}

cmd_podcast() { # 放某播客最新 N 期
  local q="$1"; [ -n "$q" ] || die usage "podcast 需要播客名或 id（例：netease-music podcast 黑水公园 --limit 3）" 2
  local j
  j="$(api_out podcast "$q" --limit "${LIMIT:-3}")" || exit $?
  kv_api_total "$j"
  kv podcast "$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("name") or "")' <<<"$j")"
  python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$j" | build_queue >/dev/null || exit $?
  play_queue
}

cmd_episode() { # 放某一期节目（要节目 id，从 podcast 列表里抄）
  local q="$1"; [ -n "$q" ] || die usage "episode 需要节目 id（从 netease-music podcast <播客> 的输出里抄）" 2
  local j
  j="$(api_out episode "$q")" || exit $?
  kv episode "$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("name") or "")' <<<"$j")"
  python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["songs"]))' <<<"$j" | build_queue >/dev/null || exit $?
  play_queue
}

# ---------- 入口 ----------
CMD="${1:-status}"
case "$CMD" in -h|--help) CMD=help ;; -V|--version) CMD=version ;; esac
if [ $# -gt 0 ]; then shift; fi
ARGS=(); LIMIT=""; OFFSET=0; START=1; KEYWORD=""; QUALITY=""; TIMEOUT=300; REFRESH=4; SHUFFLE=0; SMS_PHONE=""; SMS_CODE=""; SMS_REQUEST=0; RECOMMEND=0; NOTIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --quiet|-q) QUIET=1 ;;
    --limit) LIMIT="$2"; shift ;;
    --offset)
      [ $# -gt 1 ] && [[ "$2" =~ ^[0-9]+$ ]] || die usage "--offset 需要非负整数" 2
      OFFSET="$2"; shift ;;
    --start)
      [ "$CMD" = play-ids ] && [ $# -gt 1 ] && [[ "$2" =~ ^[0-9]+$ ]] || die usage "play-ids --start 需要从 1 开始的序号" 2
      START="$2"; shift ;;
    --shuffle) SHUFFLE=1 ;;
    --notify) NOTIFY=1 ;;
    --recommend) RECOMMEND=1 ;;
    --timeout) TIMEOUT="$2"; shift ;;
    --refresh) REFRESH="$2"; shift ;;
    --sms)
      SMS_REQUEST=1
      if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then SMS_PHONE="$2"; shift; fi ;;
    --sms-code)
      [ $# -gt 1 ] || die usage "--sms-code 需要验证码" 2
      SMS_REQUEST=1; SMS_CODE="$2"; shift ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

COOKIE="$(env_get NETEASE_MUSIC_COOKIE)"; [ -z "$COOKIE" ] && COOKIE="$(env_get NETEASE_COOKIE)"; [ -z "$COOKIE" ] && COOKIE="$(conf_get cookie)"
QUALITY="$(env_get NETEASE_MUSIC_QUALITY)"; [ -z "$QUALITY" ] && QUALITY="$(conf_get quality)"; [ -z "$QUALITY" ] && QUALITY=lossless
KEYWORD="${ARGS[0]:-}"

case "$CMD" in
  version)     printf '%s %s\n' "netease-music" "$(cat "$SKILL_DIR/VERSION" 2>/dev/null || printf unknown)" ;;
  help)        cmd_help "${ARGS[0]:-}" ;;
  setup)       cmd_setup ${ARGS[@]+"${ARGS[@]}"} ;;  # 命令自己的旗标（--cookie/--quality/--dir）在 ARGS 里
  login)       cmd_login ;;
  check)       cmd_check ;;
  watch)       cmd_watch ;;
  daily)       need_deps; LIMIT="${LIMIT:-40}"; cmd_daily ;;
  play)        need_deps; cmd_play "${ARGS[0]:-}" ;;
  play-ids)    need_deps; cmd_play_ids ;;
  search)      need_deps; LIMIT="${LIMIT:-20}"; cmd_search ;;
  cover)       need_deps; api cover ${ARGS[@]+"${ARGS[@]}"} ;;
  download)    need_deps; cmd_download ${ARGS[@]+"${ARGS[@]}"} ;;
  downloads)   need_deps; cmd_downloads ;;
  liked)       need_deps; cmd_liked ;;
  liked-ids)   need_deps; cmd_liked_ids ;;
  artist)      need_deps; cmd_artist "${ARGS[0]:-}" ;;
  album)       need_deps; cmd_album "${ARGS[0]:-}" ;;
  albums)      need_deps; cmd_albums "${ARGS[0]:-}" ;;
  queue)       need_deps; cmd_queue ;;
  remove)      need_deps; cmd_remove ;;
  clear)       need_deps; cmd_clear ;;
  jump)        need_deps
               jn="$(jump_target "${ARGS[0]:-}")" || exit $?
               mpvctl_or_die jump "$jn" >/dev/null; kv command jump; kv jumped "${ARGS[0]}"; emit_status ;;
  myplaylists) need_deps; cmd_myplaylists "${ARGS[0]:-}" ;;
  playlist)    need_deps; [ -n "${ARGS[0]:-}" ] || die usage "playlist 需要歌单名/id/链接（例：netease-music playlist 夜跑）" 2
               cmd_playlist "${ARGS[0]}" ;;
  playlists)   need_deps; cmd_playlists ;;
  charts)      need_deps; cmd_charts ;;
  chart)       need_deps; cmd_chart "${ARGS[0]:-}" ;;
  myalbums)    need_deps; cmd_myalbums ;;
  myartists)   need_deps; cmd_myartists ;;
  fm)          need_deps; cmd_fm ;;
  recent)      need_deps; cmd_recent ;;
  replay)      need_deps; cmd_replay "${ARGS[0]:-1}" ;;
  podcasts)    need_deps; cmd_podcasts ;;
  podcast)     need_deps; cmd_podcast "${ARGS[0]:-}" ;;
  episode)     need_deps; cmd_episode "${ARGS[0]:-}" ;;
  queues)      cmd_queues ;;
  queue-save)  cmd_queue_save "${ARGS[0]:-}" ;;
  queue-load)  need_deps; cmd_queue_load "${ARGS[0]:-}" ;;
  back)        need_deps; cmd_back ;;
  add)         need_deps; cmd_add "${ARGS[0]:-}" ;;
  pause|resume|toggle|next|prev|stop|seek|volume|shuffle|repeat)
               need_deps
               if [ "$CMD" = repeat ] && [ "${#ARGS[@]}" -gt 1 ]; then die usage "用法：repeat off|list|single（on = list）" 2; fi
               case "$CMD" in
                 seek|volume|shuffle|repeat) mpvctl_or_die "$CMD" "${ARGS[0]:-}" >/dev/null ;;
                 *)                          mpvctl_or_die "$CMD" >/dev/null ;;
               esac
               [ "$CMD" = stop ] && keepalive_stop
               kv command "$CMD"
               [ -n "${ARGS[0]:-}" ] && kv requested_arg "${ARGS[0]}"
               emit_status ;;   # 变更后回读真值：命令生效与否，看这里的状态
  status)      need_deps; cmd_status ;;
  like|unlike) need_deps; [ "$CMD" = unlike ] && set -- --unlike || set --; cmd_like "$@" ;;
  dislike)     need_deps; cmd_dislike ;;
  lyric)       need_deps; cmd_lyric "${ARGS[0]:-}" ;;
  *)           die usage "未知命令：${CMD}（跑 netease-music help）" 2 ;;
esac
