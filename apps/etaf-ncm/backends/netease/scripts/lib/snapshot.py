#!/usr/bin/env python3
"""队列快照：把「当前队列」存成可回放的文件。

只存歌曲列表（id/歌名/歌手/时长），不存播放地址 —— 那种 URL 二十分钟就过期。
回放时按列表重新取地址，所以快照可以长期留着。

用法：
  snapshot.py save  <queue.json> <快照文件> <位置> <shuffle:true|false> [名字]
  snapshot.py list  <快照目录>            列出全部快照（JSON 数组）
  snapshot.py songs <快照文件>            只打印歌曲列表（喂给 build_queue）
  snapshot.py meta  <快照文件>            打印元信息（名字/首数/位置/shuffle/来源/时间）
"""
import datetime
import json
import os
import sys

KEEP_NAMED = 20  # 命名快照最多留 20 条，多的按时间删最旧（prev.json 不受影响）


def _now():
    return datetime.datetime.now().astimezone().isoformat(timespec='seconds')


def cmd_save(queue_path, out_path, pos, shuffle, name='', song_id=''):
    try:
        q = json.load(open(queue_path, encoding='utf-8'))
    except Exception:
        return 2
    songs = q.get('songs') or []
    if not songs:
        return 2
    out = {
        'name': name or q.get('source') or 'unnamed',
        'saved_at': _now(),
        'source': q.get('source') or '',
        'pos': int(pos or -1),
        'shuffle': str(shuffle).lower() == 'true',
        # 开随机后 pos 是打乱顺序里的位置，回放靠 song_id 认「当时在放的那首」
        'song_id': int(song_id) if str(song_id).strip().isdigit() else None,
        'count': len(songs),
        'songs': songs,
    }
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False)
    _prune(os.path.dirname(out_path))
    print('%s\t%d\t%s' % (out['name'], out['count'], out['saved_at']))
    return 0


def _prune(d):
    named = []
    for fn in os.listdir(d):
        if not fn.endswith('.json') or fn.startswith('.') or fn == 'prev.json':
            continue
        try:
            meta = json.load(open(os.path.join(d, fn), encoding='utf-8'))
        except Exception:
            continue
        named.append((meta.get('saved_at') or '', fn))
    named.sort()
    for _, fn in named[:-KEEP_NAMED] if len(named) > KEEP_NAMED else []:
        try:
            os.remove(os.path.join(d, fn))
        except OSError:
            pass


def cmd_list(d):
    rows = []
    for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not fn.endswith('.json') or fn.startswith('.'):
            continue
        try:
            meta = json.load(open(os.path.join(d, fn), encoding='utf-8'))
        except Exception:
            continue
        rows.append({
            'file': fn,
            'name': meta.get('name') or fn[:-5],
            'count': meta.get('count') or len(meta.get('songs') or []),
            'saved_at': meta.get('saved_at') or '',
            'source': meta.get('source') or '',
            'pos': meta.get('pos', -1),
        })
    rows.sort(key=lambda r: (r['file'] != 'prev.json', r['saved_at']), reverse=False)
    json.dump(rows, sys.stdout, ensure_ascii=False)
    return 0


def cmd_songs(p):
    try:
        d = json.load(open(p, encoding='utf-8'))
    except Exception:
        return 4
    json.dump(d.get('songs') or [], sys.stdout, ensure_ascii=False)
    return 0


def cmd_meta(p):
    try:
        d = json.load(open(p, encoding='utf-8'))
    except Exception:
        return 4
    json.dump({k: d.get(k) for k in ('name', 'count', 'pos', 'shuffle', 'song_id', 'source', 'saved_at')},
              sys.stdout, ensure_ascii=False)
    return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'save':
        return cmd_save(*(args + ['', '', '', '', ''])[:6])
    if cmd == 'list':
        return cmd_list(args[0])
    if cmd == 'songs':
        return cmd_songs(args[0])
    if cmd == 'meta':
        return cmd_meta(args[0])
    print('未知子命令：%s' % cmd, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
