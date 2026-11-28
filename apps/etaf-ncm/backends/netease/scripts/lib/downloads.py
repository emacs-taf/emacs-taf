#!/usr/bin/env python3
"""downloads — 已下载歌曲登记表（内部原语，被 netease-music.sh 调用）

用法: downloads.py <state-dir> <命令> [参数]
  add <id> <name> <artist> <file> <level> <br> <bytes>
                         登记/更新一条，打印登记时刻（ISO）
  pick <id...>           对每个「登记过且文件还在」的 id，打印 "<id>\t<档位>\t<文件路径>"
  list                   打印 {"count":N,"total":N,"downloads":[...]}（不存在的文件不列出）
  get <id>               打印该 id 的文件路径；没有或文件不存在时退出 3

登记表落在 <state-dir>/downloads.json：键是歌曲 id 字符串，值是
{id,name,artist,file,level,br,bytes,at}。它是「本地优先播放」和 App 里
「已下载」标记的唯一真源，所以下载成功必须先登记、再报成功。
"""
import json
import os
import sys
import time


def state_file(state):
    return os.path.join(state, "downloads.json")


def load(state):
    try:
        data = json.load(open(state_file(state), encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def save(state, data):
    os.makedirs(state, exist_ok=True)
    target = state_file(state)
    temp = target + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1)
    os.replace(temp, target)


def live_entries(state):
    """Return registered entries whose file still exists, newest first."""
    found = [entry for entry in load(state).values()
             if isinstance(entry, dict) and entry.get("file")
             and os.path.isfile(entry["file"])]
    found.sort(key=lambda entry: entry.get("at") or "", reverse=True)
    return found


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    state = sys.argv[1]
    command = sys.argv[2]
    arguments = sys.argv[3:]
    if command == "add":
        if len(arguments) < 7:
            print("add 需要 <id> <name> <artist> <file> <level> <br> <bytes>", file=sys.stderr)
            return 2
        sid, name, artist, path, level, br, size = arguments[:7]
        at = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        data = load(state)
        data[str(sid)] = {"id": int(sid), "name": name, "artist": artist,
                          "file": os.path.abspath(path), "level": level,
                          "br": int(br or 0), "bytes": int(size or 0), "at": at}
        save(state, data)
        print(at)
        return 0
    if command == "pick":
        data = load(state)
        for sid in arguments:
            entry = data.get(str(sid))
            if entry and entry.get("file") and os.path.isfile(entry["file"]):
                print("%s\t%s\t%s" % (sid, entry.get("level") or "local", entry["file"]))
        return 0
    if command == "list":
        entries = live_entries(state)
        print(json.dumps({"count": len(entries), "total": len(entries),
                          "downloads": entries}, ensure_ascii=False))
        return 0
    if command == "get":
        entry = load(state).get(str(arguments[0])) if arguments else None
        if entry and entry.get("file") and os.path.isfile(entry["file"]):
            print(entry["file"])
            return 0
        return 3
    print("未知命令：%s" % command, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
