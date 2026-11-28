#!/usr/bin/env python3
"""准备 remove 的本地队列文件；按 mpv 的实际顺序映射，IPC 成功后才由入口安装。

用法：queue-edit.py <local-dir> <playlist.json> <1-based index> <stage-dir>
"""
import importlib.util
import json
from pathlib import Path
import sys
import time

spec = importlib.util.spec_from_file_location('mpv_map', Path(__file__).with_name('mpv-map.py'))
mpv_map = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mpv_map)


def main():
    local, playlist, index, stage = sys.argv[1:]
    local, stage = Path(local), Path(stage)
    entries = json.loads(Path(playlist).read_text())['entries']
    index = int(index) - 1
    if not 0 <= index < len(entries):
        print('error=notfound\nhint=队列里没有这个序号', file=sys.stderr)
        return 4
    queue = json.loads((local / 'queue.json').read_text())
    urls = mpv_map.load_urls(local / 'urls.txt')
    songs, lines, url_lines = [], ['#EXTM3U'], []
    for i, entry in enumerate(entries):
        if i == index:
            continue
        song = mpv_map.resolve(queue['songs'], urls, entry['title'], entry['filename'])
        if not song or not entry['filename']:
            print('error=notfound\nhint=mpv 条目无法映射到本地歌曲，队列未修改', file=sys.stderr)
            return 4
        songs.append(song)
        lines.extend([
            '#EXTINF:%d,[#%s] %s - %s' % ((song.get('ms') or 0) // 1000, song['id'], song['artist'], song['name']),
            entry['filename'],
        ])
        url_lines.append('%s\t%s\t%s' % (song['id'], song.get('level', ''), entry['filename']))
    queue.update(songs=songs, count=len(songs), as_of=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    queue.pop('start', None)
    (stage / 'queue.json').write_text(json.dumps(queue, ensure_ascii=False), encoding='utf-8')
    (stage / 'songs.json').write_text(json.dumps(songs, ensure_ascii=False), encoding='utf-8')
    (stage / 'queue.m3u8').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    (stage / 'urls.txt').write_text('\n'.join(url_lines) + ('\n' if url_lines else ''), encoding='utf-8')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print('error=external\nhint=无法编辑本地队列：%s' % error, file=sys.stderr)
        sys.exit(5)
