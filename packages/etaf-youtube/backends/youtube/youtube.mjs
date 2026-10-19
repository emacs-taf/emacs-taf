#!/usr/bin/env node
// Versioned YouTube command interface; no Emacs or presentation policy here.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseFlags, scanGlobals } from './vendor/args.mjs';
import { emit, fail, reportError, nowIso } from './vendor/render.mjs';

const iface = JSON.parse(fs.readFileSync(path.join(import.meta.dirname, 'interface.json'), 'utf8'));
const usage = command => {
  const commands = command ? iface.commands.filter(x => x.name === command) : iface.commands;
  return `youtube — ${iface.summary}\n\n用法：node backends/youtube/youtube.mjs <命令> [参数] [--json] [--timeout 秒]\n\n${commands.map(x => `  ${x.usage || x.name}\n    ${x.summary}`).join('\n')}\n  help [命令]  查看用法\n\n首次使用：node backends/youtube/youtube.mjs login；检查：node backends/youtube/youtube.mjs check\n写入默认预览，--yes 提交，--dry-run 强制预览。verified=false 不可自动重发。\n`;
};
const specs = { check: {}, login: {}, feed: {}, search: { filter: 'string' }, browse: { params: 'string' },
  video: {}, comments: {}, more: {}, source: { quality: 'string' }, captions: { language: 'string' },
  action: { playlist: 'string', text: 'string' }, watch: { notify: 'bool' } };

async function main(argv) {
  const command = argv[0] || 'help';
  if (['help', '-h', '--help'].includes(command)) { console.log(usage(argv[1])); return; }
  if (!Object.hasOwn(specs, command)) fail('usage', `未知命令 ${command}`, 'node backends/youtube/youtube.mjs help');
  const { flags, positional } = parseFlags(argv.slice(1), specs[command], { skill: 'youtube', command });
  if (flags.help) { console.log(usage(command)); return; }
  const needed = !['check', 'login', 'watch'].includes(command);
  if (needed && !positional.length) fail('usage', '缺少参数', `node backends/youtube/youtube.mjs help ${command}`);
  if (command === 'action' && positional.length !== 2) fail('usage', '动作需要名称和目标', 'node backends/youtube/youtube.mjs help action');
  if (!['search', 'action'].includes(command) && positional.length > (needed ? 1 : 0)) fail('usage', '位置参数过多', `node backends/youtube/youtube.mjs help ${command}`);
  const timeout = flags.timeout ?? 45;
  if (timeout < 1 || timeout > 90) fail('usage', '--timeout 范围是 1–90 秒', 'node backends/youtube/youtube.mjs help');
  const service = await import('./lib/service.mjs');
  const deadline = setTimeout(() => {
    try { fail('timeout', 'YouTube 命令超过总时限；写入结果未知时不要自动重发', 'node backends/youtube/youtube.mjs check'); }
    catch (error) { reportError(error, { json: flags.json }); }
    process.exit(3);
  }, timeout * 1000);
  let result, session;
  try {
    if (command === 'source' || command === 'captions') {
      const id = service.videoId(positional[0]);
      if (flags.quality && !['360', '480', '720', '1080', '1440', '2160', 'best'].includes(flags.quality)) fail('usage', '清晰度不支持', 'node backends/youtube/youtube.mjs help source');
      if (command === 'captions' && !flags.language) fail('usage', '缺少 --language', 'node backends/youtube/youtube.mjs help captions');
      const source = await import('./lib/source.mjs');
      result = command === 'source' ? await source.media(id, flags.quality || '720', timeout * 1000)
        : await source.caption(id, flags.language, '360', timeout * 1000);
    } else if (command === 'action' && (!flags.yes || flags['dry-run'])) {
      result = await service.action(null, positional[0], positional[1], flags);
    } else {
      const browser = await import('./lib/browser.mjs');
      session = await browser.session({ login: command === 'login', timeout: timeout * 1000 });
      switch (command) {
        case 'login': case 'check': case 'watch': result = await service.check(session); break;
        case 'feed': result = await service.feed(session, positional[0]); break;
        case 'search': result = await service.search(session, positional.join(' '), flags.filter); break;
        case 'browse': result = await service.browse(session, positional[0], flags.params); break;
        case 'video': result = await service.details(session, positional[0]); break;
        case 'comments': result = await service.discussion(session, positional[0]); break;
        case 'more': result = await service.more(session, positional[0]); break;
        case 'action': result = await service.action(session, positional[0], positional[1], flags); break;
      }
    }
    if (command === 'watch' && !flags.json) return;
    const rows = result.items || [];
    emit({ conclusion: result.signed_in ? `已登录 YouTube：${result.name}` : result.title || `${command}：${rows.length ? `${rows.length} 项` : result.status || '完成'}`,
      fields: { count: result.items ? rows.length : undefined, next: result.next || undefined, status: result.status },
      text: rows.map(x => `${x.id}  ${x.title || x.author || ''}${x.text ? `  ${x.text}` : ''}`).join('\n'),
      json: { protocol: 1, ...result }, source: command === 'source' || command === 'captions' ? 'yt-dlp+youtube' : 'youtube-web-session', asOf: nowIso(),
    }, { json: flags.json, quiet: flags.quiet });
  } catch (error) {
    if (command === 'watch' && flags.notify) {
      const { notify } = await import('./vendor/notify.mjs');
      await notify({ title: 'YouTube 登录检查异常', body: `${error.message}\nnode backends/youtube/youtube.mjs login`, group: 'youtube-watch' });
    }
    throw error;
  } finally { clearTimeout(deadline); session?.close(); }
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url))) {
  const argv = process.argv.slice(2);
  main(argv).catch(error => { reportError(error, { json: scanGlobals(argv).json }); });
}
