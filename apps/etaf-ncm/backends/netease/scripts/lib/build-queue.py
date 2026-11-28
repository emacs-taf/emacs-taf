#!/usr/bin/env python3
"""build-queue — 把歌曲列表 + 播放地址合成 mpv 队列（内部原语，被 netease-music.sh 调用）

用法: build-queue.py <songs.json> <urls.txt> <queue.json> <queue.m3u8> [start，从 1 开始]
  songs.json: [{"id","name","artist","ms"}, ...]
  urls.txt:   每行 "<id>\t<档位>\t<播放地址>"（取不到地址的歌不写进来）
输出: "picked skipped" 一行；queue.json 按 m3u 顺序存曲目，供 status/like/lyric 反查。

**为什么 m3u 里写的是 URL 而不是 id**：网易云的直链是限时签名 URL，实测取出来约 **5 分钟**就 403。
所以长队列不能靠预取地址（放到后半段全部失效，听感是「歌还在放但没声音」）。
这里的做法是：m3u 里写的仍是取地址那一刻的 URL（保证刚建队就能立刻出声、零等待），
同时 queue.json 记下这批地址的取用时刻；播到过期地址时由入口的 keepalive 重取（见 netease-music.sh）。
"""
import json
import sys
import time


def main():
    songs_path, urls_path, queue_path, m3u_path = sys.argv[1:5]
    songs = json.load(open(songs_path, encoding="utf-8"))
    urls = {}
    levels = {}
    for line in open(urls_path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        sid, level, url = (parts[0], parts[1], parts[2]) if len(parts) == 3 else (parts[0], "", parts[-1])
        if url:
            urls[sid] = url
            levels[sid] = level
    picked = [s for s in songs if str(s["id"]) in urls]
    start = None
    if len(sys.argv) > 5:
        requested = int(sys.argv[5]) - 1
        if not 0 <= requested < len(songs):
            print('error=notfound\nhint=--start 指定的序号超出这批歌曲，队列未替换', file=sys.stderr)
            return 4
        if str(songs[requested]["id"]) not in urls:
            print('error=notfound\nhint=选中的这首不能播（可能要 VIP 或没有版权），队列未替换', file=sys.stderr)
            return 4
        start = 1 + sum(str(s["id"]) in urls for s in songs[:requested])
    for s in picked:
        s["level"] = levels.get(str(s["id"]), "")   # 服务端实际给的档位（VIP 歌可能被降档）
    with open(queue_path, "w", encoding="utf-8") as f:
        json.dump(
            {
                "songs": picked,
                "skipped": len(songs) - len(picked),
                "as_of": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                **({"start": start} if start is not None else {}),
            },
            f,
            ensure_ascii=False,
            indent=1,
        )
    with open(m3u_path, "w", encoding="utf-8") as f:
        f.write("#EXTM3U\n")
        for s in picked:
            # 标题前缀 [#id]：mpv 开了 shuffle 后顺序和 queue.json 不一致，
            # 靠它把「mpv 在放/队列第几项」映射回歌（见 scripts/lib/mpv-map.py）。
            f.write("#EXTINF:%d,[#%s] %s - %s\n%s\n" % ((s.get("ms") or 0) // 1000, s["id"], s["artist"], s["name"], urls[str(s["id"])]))
    print(len(picked), len(songs) - len(picked))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 5 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0 if len(sys.argv) > 1 else 2)
    sys.exit(main())
