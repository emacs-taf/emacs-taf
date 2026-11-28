#!/usr/bin/env node
/**
 * 配置契约原语（库，不是 CLI）：随人/随机器变化的值统一走这里。
 *
 * 优先级：CLI 参数 > 环境变量 PI_SKILL_<SKILL>_<KEY> > local/skills/<技能>/config.json
 *         > 自动发现（技能自己查出来的值，传 discovered） > 声明里的 default
 *
 * 为什么：技能本体（共享仓库，可分发）只放确定性逻辑；凡是「每个人不一样」的值
 * （主机名、代码根目录、账号、路径）都声明在 interface.json 的 config[]，值存 local/（不进 Git）。
 *
 * 约定（写新技能/改造存量时照抄）：
 *   - `config` 声明每个键：key/desc/type/required/requiredFor/secret/discover/ask/default/ttl/when
 *   - 缺必需值时输出 `error=config missing=<key> need=human ask="…" hint="pi-skill X setup --<key> <值>"`
 *   - secret: true 的键默认打码，只有 --reveal 才显示明文
 *   - 读取一律经本模块（不要自己拼 local/skills 路径），这样 doctor 能一次性体检全库
 *
 * 文件格式：`{ "<key>": <值>, …, "_meta": { "<key>": { "updatedAt": ISO } } }`
 * （兼容存量技能的扁平 JSON：顶层非 `_meta` 的键就是值）
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const CONFIG_SOURCES = ['arg', 'env', 'file', 'discovered', 'default'];
/** 声明里的 type 词汇表（与 skill-registry 共用同一个真源）。 */
export const CONFIG_TYPES = ['string', 'int', 'bool', 'path', 'host', 'url', 'enum', 'list'];

export const agentDirOf = () => process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent');
export const configPathFor = (skillName, agentDir = agentDirOf()) => path.join(agentDir, 'local', 'skills', skillName, 'config.json');
export const envKeyOf = (skillName, key) => `PI_SKILL_${skillName.toUpperCase().replace(/-/g, '_')}_${key.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toUpperCase()}`;

/** 读本机配置：文件不存在/坏掉都返回空对象（读取失败不该让技能崩），但把错误带出来。 */
export function readConfig(skillName, { agentDir } = {}) {
  const file = configPathFor(skillName, agentDir);
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return { file, values: {}, meta: {}, error: '配置不是 JSON 对象' };
    const { _meta: meta = {}, ...values } = parsed;
    return { file, values, meta, error: null };
  } catch (error) {
    return { file, values: {}, meta: {}, error: error.code === 'ENOENT' ? null : error.message };
  }
}

function platformMatches(item) {
  const when = item?.when?.platform;
  return !Array.isArray(when) || !when.length || when.includes(process.platform);
}

function typeError(item, value) {
  const type = item.type ?? 'string';
  if (type === 'list') return Array.isArray(value) ? null : '应为数组';
  if (type === 'int') return Number.isInteger(Number(value)) && Number.isFinite(Number(value)) ? null : '应为整数';
  if (type === 'bool') return typeof value === 'boolean' || value === 'true' || value === 'false' ? null : '应为布尔值';
  if (type === 'enum') return Array.isArray(item.values) && item.values.includes(value) ? null : `只能是 ${(item.values ?? []).join(' / ')}`;
  if (typeof value !== 'string') return '应为字符串';
  if (type === 'host' && !/^[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$/.test(value)) return '应为 host 或 user@host';
  if (type === 'path' && !value.trim()) return '路径不能为空';
  if (type === 'url' && !/^https?:\/\//.test(value)) return '应为 http(s):// 开头的 URL';
  if (Array.isArray(item.values) && !item.values.includes(value)) return `只能是 ${item.values.join(' / ')}`;
  return null;
}

/**
 * 解析一个技能的配置。
 * @returns {{ ok: boolean, values: object, sources: object, missing: object[], invalid: object[], stale: object[], file: string, meta: object, fileError: string|null }}
 */
export function resolveConfig(skill, { argv = {}, env = process.env, discovered = {}, agentDir, now = Date.now() } = {}) {
  const items = (skill.declared?.config ?? []).filter(platformMatches);
  const { file, values: fileValues, meta, error: fileError } = readConfig(skill.name, { agentDir });
  const values = {};
  const sources = {};
  const invalid = [];
  const stale = [];

  for (const item of items) {
    const candidates = [
      ['arg', argv[item.key]],
      ['env', env[envKeyOf(skill.name, item.key)]],
      ['file', fileValues[item.key]],
      ['discovered', discovered[item.key]],
      ['default', item.default],
    ];
    const hit = candidates.find(([, value]) => value !== undefined && value !== null && value !== '');
    if (!hit) continue;
    const [source, value] = hit;
    const problem = typeError(item, value);
    if (problem) { invalid.push({ item, value, message: problem }); continue; }
    values[item.key] = value;
    sources[item.key] = source;
    const updatedAt = meta?.[item.key]?.updatedAt;
    if (item.ttl && updatedAt && now - Date.parse(updatedAt) > item.ttl * 1000) stale.push({ item, value, updatedAt });
  }

  const missing = items.filter(item => item.required === true && !(item.key in values));
  return { ok: !missing.length && !invalid.length, values, sources, missing, invalid, stale, file, meta, fileError };
}

/** 某条命令真正必需的配置（required 全量 ∪ requiredFor 命中该命令的）。 */
export function requiredForCommand(skill, command) {
  return (skill.declared?.config ?? []).filter(item => platformMatches(item) && (item.required === true || (command && (item.requiredFor ?? []).includes(command))));
}

/** 缺配置时的标准输出行（error=config + 可执行 hint）。 */
export function configErrorLines(skillName, missing) {
  const keys = missing.map(entry => entry.item ? entry.item.key : entry.key).join(' ');
  const lines = [`error=config missing=${keys} need=human`];
  for (const entry of missing) {
    const item = entry.item ?? entry;
    if (item.ask) lines.push(`ask="${item.ask}"`);
  }
  lines.push(`hint=${missing.map(entry => {
    const item = entry.item ?? entry;
    const flag = item.setupFlag || `--${item.key}`; // 技能的 setup 命令用了别的旗标时在 config[].setupFlag 里写明
    return `pi-skill ${skillName} setup ${flag} <${item.type === 'list' ? '值1,值2' : '值'}>`;
  }).join('；或 ')}`);
  return lines;
}

/** secret 打码：保留首尾各 2 字符便于核对，中间固定 4 个 *。 */
export function maskValue(value) {
  const text = String(value ?? '');
  if (text.length <= 4) return '*'.repeat(text.length || 0) || '(空)';
  return `${text.slice(0, 2)}****${text.slice(-2)}`;
}

/** 按声明决定要不要打码；`{ reveal: true }` 才显示明文。 */
export function displayValue(item, value, { reveal = false } = {}) {
  if (value === undefined || value === null || value === '') return '';
  if (!item?.secret || reveal) return Array.isArray(value) ? value.join(',') : String(value);
  return maskValue(value);
}

/** 写回本机配置：合并 → 写 0600 → 回读并校验（写完的值必须能读出来）。 */
export function writeConfig(skillName, patch, { agentDir, now = new Date().toISOString() } = {}) {
  const { file, values, meta } = readConfig(skillName, { agentDir });
  const nextValues = { ...values };
  const nextMeta = { ...meta };
  for (const [key, value] of Object.entries(patch)) {
    if (value === undefined || value === null || value === '') delete nextValues[key];
    else nextValues[key] = value;
    nextMeta[key] = { updatedAt: now };
  }
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, `${JSON.stringify({ ...nextValues, _meta: nextMeta }, null, 2)}\n`, { mode: 0o600 });
  const readBack = readConfig(skillName, { agentDir });
  const keys = Object.keys(patch);
  const ok = keys.every(key => (patch[key] === undefined || patch[key] === null || patch[key] === '' ? !(key in readBack.values) : JSON.stringify(readBack.values[key]) === JSON.stringify(patch[key])));
  return { file, ok, values: readBack.values, meta: readBack.meta };
}

/** 体检用：声明了但脚本里从没出现过的键（防止声明烂掉；反向检查比正向扫描代码可靠，见 ROADMAP D14）。 */
export function declaredButUnused(skill, text) {
  return (skill.declared?.config ?? []).filter(item => {
    const forms = [item.key, item.key.replace(/-/g, '_'), item.key.replace(/[-_](\w)/g, (_, c) => c.toUpperCase()), envKeyOf(skill.name, item.key)];
    return !forms.some(form => new RegExp(`\\b${form.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`).test(text));
  });
}

/** 体检用：脚本里出现的 PI_SKILL_<SKILL>_<KEY> 环境变量键名（可用来抓未声明的键）。 */
export function envKeysUsed(skill, text) {
  const prefix = `PI_SKILL_${skill.name.toUpperCase().replace(/-/g, '_')}_`;
  const found = new Set();
  for (const match of text.matchAll(new RegExp(`${prefix}[A-Z0-9_]+`, 'g'))) found.add(match[0].slice(prefix.length).toLowerCase());
  return [...found];
}

/** 到处都有、不用声明的命令（或由运行时保证的）：声明的价值为负。 */
const UBIQUITOUS_BINARIES = new Set([
  'node', 'python', 'python3', 'bash', 'sh', 'zsh', 'fish', 'env', 'echo', 'printf', 'cat', 'sed', 'grep', 'awk',
  'sleep', 'true', 'false', 'date', 'which', 'command', 'test', 'mkdir', 'rm', 'cp', 'mv', 'ln', 'ls', 'chmod',
  'head', 'tail', 'wc', 'sort', 'uniq', 'tr', 'cut', 'tee', 'touch', 'dirname', 'basename', 'readlink', 'xargs',
  'find', 'stat', 'uname', 'id', 'ps', 'kill', 'pkill', 'killall', 'open', 'defaults', 'plutil', 'launchctl',
  'osascript', 'sw_vers', 'sysctl', 'df', 'du', 'git', 'curl', 'jq', 'sqlite3', 'sips', 'tccutil', 'timeout',
]);

const BINARY_PATTERNS = [
  /spawnSync\(\s*['"]([A-Za-z0-9_.-]+)['"]/g,
  /execFileSync\(\s*['"]([A-Za-z0-9_.-]+)['"]/g,
  /shutil\.which\(\s*['"]([A-Za-z0-9_.-]+)['"]/g,
  /subprocess\.run\(\s*\[\s*['"]([A-Za-z0-9_.-]+)['"]/g,
  /command -v ([A-Za-z0-9_.-]+)/g,
];

/** 体检用：脚本里真会调用的外部二进制 → 用来抓「用了但没在 requires[] 里声明」。
 *  排除：无处不在的命令、技能自己的名字/别名、其它技能的名字/别名（那是 dependsOn 的活）。 */
export function binariesUsed(skill, text, others = []) {
  const declared = new Set((skill.declared?.requires ?? []).map(item => item.name));
  const self = new Set([skill.name, ...(skill.declared?.aliases ?? [])]);
  const foreign = new Set(others.flatMap(other => [other.name, ...(other.declared?.aliases ?? []), ...(other.declared?.admin ?? []).map(item => item.alias).filter(Boolean)]));
  const found = new Set();
  for (const pattern of BINARY_PATTERNS) {
    for (const match of text.matchAll(pattern)) {
      const name = match[1];
      if (UBIQUITOUS_BINARIES.has(name) || self.has(name) || foreign.has(name) || declared.has(name)) continue;
      found.add(name);
    }
  }
  return [...found];
}
