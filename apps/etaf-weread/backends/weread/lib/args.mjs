// 参数解析：全局旗标同名同义；未知旗标一律 usage 错误（不许静默忽略）。
import { fail } from './render.mjs';
import { cliCommand } from './cli.mjs';

export const GLOBAL_FLAGS = { json: 'bool', 'dry-run': 'bool', yes: 'bool', quiet: 'bool', timeout: 'int', help: 'bool' };

const helpHint = (command) => `${cliCommand()} help${command ? `（看 ${command} 用法）` : ''}`;

/**
 * @param {string[]} argv
 * @param {Record<string, 'bool'|'string'|'int'|'float'|'list'>} spec 命令自己的旗标
 * @param {{command?: string}} where 只用于报错提示
 */
export function parseFlags(argv, spec = {}, { command = '' } = {}) {
  const defs = { ...GLOBAL_FLAGS, ...spec };
  const hint = helpHint(command);
  const flags = {};
  const positional = [];
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--') { positional.push(...argv.slice(index + 1)); break; }
    if (!token.startsWith('-') || token === '-') { positional.push(token); continue; }
    if (token === '-h') { flags.help = true; continue; }
    const eq = token.indexOf('=');
    const name = (eq >= 0 ? token.slice(0, eq) : token).replace(/^--?/, '');
    if (!Object.hasOwn(defs, name)) fail('usage', `未知参数 ${token}`, hint);
    const type = defs[name];
    if (type === 'bool') {
      if (eq >= 0) fail('usage', `${token} 不接受取值`, hint);
      flags[name] = true;
      continue;
    }
    const raw = eq >= 0 ? token.slice(eq + 1) : argv[++index];
    if (raw === undefined) fail('usage', `${token} 缺少取值`, hint);
    if (type === 'int' || type === 'float') {
      const pattern = type === 'int' ? /^-?\d+$/ : /^-?\d+(\.\d+)?$/;
      if (!pattern.test(raw)) fail('usage', `${token} 需要${type === 'int' ? '整数' : '数字'}，收到 ${raw}`, hint);
      flags[name] = Number(raw);
    } else if (type === 'list') {
      flags[name] = [...(flags[name] ?? []), raw];
    } else {
      flags[name] = raw;
    }
  }
  return { flags, positional };
}

export function requireFlag(flags, name, command) {
  if (flags[name] === undefined || flags[name] === '') {
    fail('usage', `缺少必填参数 --${name}`, helpHint(command));
  }
  return flags[name];
}

export function timeoutMsOf(flags, fallbackSeconds = 30, envVar = '') {
  const fromEnv = envVar && process.env[envVar] ? Number(process.env[envVar]) : undefined;
  const seconds = flags.timeout ?? fromEnv ?? fallbackSeconds;
  return Math.max(1, seconds) * 1000;
}

/** 位置参数拼成一段文本：`post 你好 世界` → "你好 世界"。 */
export function positionalText(positional) {
  return positional.join(' ').trim();
}

/** 入口只扫它认识的全局旗标（--timeout 是唯一带值的），用来在错误时也能给出 --json 形式的输出。 */
export function scanGlobals(argv) {
  const flags = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--json') flags.json = true;
    else if (token === '--quiet') flags.quiet = true;
    else if (token === '--dry-run') flags['dry-run'] = true;
    else if (token === '--yes') flags.yes = true;
    else if (token === '--timeout') { const value = argv[++index]; if (value !== undefined && /^\d+$/.test(value)) flags.timeout = Number(value); }
    else if (token.startsWith('--timeout=')) { const value = token.slice('--timeout='.length); if (/^\d+$/.test(value)) flags.timeout = Number(value); }
  }
  return flags;
}
