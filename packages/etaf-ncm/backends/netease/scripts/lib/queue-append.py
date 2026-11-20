#!/usr/bin/env python3
"""把一首歌追加进队列文件，并写出给 mpv 用的「只有这一首」的临时 m3u。

参数：queue.json queue.m3u8 tmp.m3u id 歌名 歌手 毫秒 url
输出（JSON）：{"ok": true, "count": N, "name", "artist", "id"} 或 {"ok": false, "reason": "duplicate", "count": N}
"""
import json
import sys


def main():
    if len(sys.argv) < 9:
        print('用法：queue-append.py <queue.json> <queue.m3u8> <tmp.m3u> <id> <歌名> <歌手> <毫秒> <url>', file=sys.stderr)
        return 2
    qpath, mpath, tpath, sid, name, artist, ms, url = sys.argv[1:9]
    q = json.load(open(qpath, encoding='utf-8'))
    songs = q.get('songs') or []
    new = {'id': int(sid), 'name': name, 'artist': artist, 'ms': int(ms or 0)}
    if any(s.get('id') == new['id'] for s in songs):
        print(json.dumps({'ok': False, 'reason': 'duplicate', 'count': len(songs)}, ensure_ascii=False))
        return 0
    songs.append(new)
    q['songs'] = songs
    q['count'] = len(songs)
    with open(qpath, 'w', encoding='utf-8') as f:
        json.dump(q, f, ensure_ascii=False)
    # 标题前缀 [#id] 与 build-queue.py 一致，供 mpv-map.py 映射回歌曲
    entry = "#EXTINF:%d,[#%s] %s - %s\n%s\n" % ((new['ms'] or 0) // 1000, new['id'], artist, name, url)
    with open(mpath, 'a', encoding='utf-8') as f:
        f.write(entry)
    with open(tpath, 'w', encoding='utf-8') as f:
        f.write('#EXTM3U\n' + entry)
    print(json.dumps({'ok': True, 'count': len(songs), 'name': name, 'artist': artist, 'id': new['id']},
                     ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
