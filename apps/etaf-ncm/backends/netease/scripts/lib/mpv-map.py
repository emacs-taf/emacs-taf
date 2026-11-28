#!/usr/bin/env python3
"""mpv-map — 把 mpv 的「当前在放哪首 / 队列第几项」映射回 queue.json 里的歌。

为什么需要它：mpv 开着 shuffle 时播放顺序是它自己排的，`playlist-pos`
指的是那条打乱过的顺序，直接拿去索引 queue.json 会报错歌（实测：
status 说在放《野心家》，实际在放《All Of Me/Say Something》）。

每首歌在队列里有两种稳定身份，建队时都会写进去：
  1. m3u8 的 #EXTINF 标题写成 "[#<id>] <歌手> - <歌名>"，mpv 的 media-title / 条目 title 原样带回；
  2. 条目 filename 是取地址那一刻的 URL，可对照 urls.txt（<id>\\t<档位>\\t<url>，按去 query 的路径比）。
旧格式标题（没有 [#id]）依次用 URL、标题串「歌手 - 歌名」回退；都对不上退出 3。

用法：
  mpv-map.py now   <queue.json> <urls.txt> <status.json>               # → 当前歌曲 JSON（mpv status 的输出）
  mpv-map.py index <queue.json> <urls.txt> <title> <path>              # → 当前歌在 queue.json 里的 0 基序号
  mpv-map.py find  <queue.json> <urls.txt> <song_id> <playlist.json>   # → 该歌在 mpv 队列里的 1 基序号
"""
import json
import re
import sys

ID_RE = re.compile(r'^\[#(\d+)\]\s*')


def load_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def load_urls(path):
    m = {}
    try:
        f = open(path, encoding='utf-8')
    except OSError:
        return m
    with f:
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) >= 2 and parts[-1]:
                m[parts[0]] = parts[-1]
    return m


def strip_query(url):
    return (url or '').split('?')[0]


def id_of_title(title):
    m = ID_RE.match(title or '')
    return m.group(1) if m else ''


def id_of_url(url, urls):
    if not url:
        return ''
    u = strip_query(url)
    for sid, u2 in urls.items():
        if strip_query(u2) == u:
            return sid
    return ''


def display_title(title):
    return ID_RE.sub('', title or '')


def resolve(songs, urls, title, path):
    """按标题里的 [#id] → URL → 「歌手 - 歌名」的顺序找回 queue.json 里的歌。"""
    sid = id_of_title(title)
    if not sid:
        sid = id_of_url(path, urls)
    if sid:
        for s in songs:
            if str(s.get('id')) == str(sid):
                return s
    t = (title or '').strip()
    if t:
        for s in songs:
            if t == '%s - %s' % (s.get('artist') or '', s.get('name') or ''):
                return s
    return None


def cmd_now(queue_path, urls_path, status_path):
    st = load_json(status_path)
    songs = (load_json(queue_path).get('songs') or [])
    s = resolve(songs, load_urls(urls_path), st.get('title'), st.get('path'))
    if not s:
        return 3
    print(json.dumps(s, ensure_ascii=False))
    return 0


def cmd_index(queue_path, urls_path, title, path):
    songs = (load_json(queue_path).get('songs') or [])
    s = resolve(songs, load_urls(urls_path), title, path)
    if not s:
        return 3
    print(songs.index(s))
    return 0


def cmd_find(queue_path, urls_path, song_id, playlist_path):
    songs = (load_json(queue_path).get('songs') or [])
    urls = load_urls(urls_path)
    entries = load_json(playlist_path).get('entries') or []
    target = str(song_id)
    for e in entries:
        sid = id_of_title(e.get('title')) or id_of_url(e.get('filename'), urls)
        if sid and str(sid) == target:
            print(e.get('index'))
            return 0
    # 标题是旧格式时，再用「歌手 - 歌名」对一次
    for s in songs:
        if str(s.get('id')) != target:
            continue
        want = '%s - %s' % (s.get('artist') or '', s.get('name') or '')
        for e in entries:
            if (e.get('title') or '').strip() == want:
                print(e.get('index'))
                return 0
    return 3


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    args = sys.argv[2:]
    try:
        if cmd == 'now' and len(args) == 3:
            return cmd_now(*args)
        if cmd == 'index' and len(args) == 4:
            return cmd_index(*args)
        if cmd == 'find' and len(args) == 4:
            return cmd_find(*args)
    except (OSError, ValueError, KeyError):
        return 3
    print('用法见脚本 docstring', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
