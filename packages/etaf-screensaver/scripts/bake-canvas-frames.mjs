#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded, atomic offline canvas baking. Playback never invokes this tool.
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm, lstat } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { EFFECTS, PACKS, rendererFiles, rendererHarness, captureHarness } from './canvas-renderers.mjs';

const MIME = { webp: 'image/webp', jpeg: 'image/jpeg', png: 'image/png' };
const HELP = `usage: node scripts/bake-canvas-frames.mjs (--preset NAME | --effect NAME | --url URL) --out DIR
  --modules DIR        npm modules (default ./node_modules)
  --packs LIST         comma-separated Butterchurn packs; default base,extra,extra2
  --list-presets        list available presets without baking
  --effect-options FILE  JSON object of Vanta numeric/color options
  --canvas SELECTOR    URL mode canvas selector (default canvas)
  --seconds S --fps N  recording duration and rate (default 20 seconds, 15 fps)
  --width W --height H canvas pixels (default 960x540; at most 2073600 pixels)
  --warmup S          advance every frame before recording (default 6 seconds)
  --loop S            crossfade tail to head; omit leading S seconds (default 0)
  --seed N            nonzero 32-bit seed for preset/effect mode (default 4242)
  --audio MODE        synthetic or silence (default synthetic)
  --format FORMAT --quality Q  jpeg|webp|png, quality in (0,1] (default jpeg,0.82)
  --manifest NAME     basename ending in .frames.json (default OUT.frames.json)
  --source TEXT --license TEXT  attribution; upstream notices included automatically
  --cdp-port N        local Chrome debug port (default 9222)
  --timeout S        total deadline, including navigation (default 300, max 1800)
  --request-timeout S per CDP/HTTP request deadline (default 15, max 60)
  --max-bytes N      encoded bundle byte budget (default 268435456, max 1073741824)
  help | --help      show this usage
Effects: ${EFFECTS.join(', ')}
Packs: ${PACKS.join(', ')}
An existing output is never overwritten. Failure removes only this run's staging
files and tab. URL mode uses real time; preset/effect mode uses a virtual clock.
Requires Node 22+, Chrome CDP, and local upstream npm modules for those modes.`;

function fail(message) { throw new Error(message); }
function bounded(value, min, max, name, integer = false) {
  if (!Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value)))
    fail(`${name} must be ${integer ? 'an integer ' : ''}in [${min}, ${max}]`);
}
function parse(argv) {
  const o = { modules: resolve('node_modules'), cdpPort:9222, fps:15, seconds:20,
    width:960, height:540, warmup:6, loop:0, seed:4242, audio:'synthetic', format:'jpeg', quality:0.82,
    canvas:'canvas', packs:['base','extra','extra2'], timeout:300, requestTimeout:15, maxBytes:268435456 };
  const flags = { '--preset':'preset', '--effect':'effect', '--url':'url', '--out':'out', '--modules':'modules',
    '--packs':'packs', '--effect-options':'effectOptionsFile', '--canvas':'canvas', '--seconds':'seconds',
    '--fps':'fps', '--width':'width', '--height':'height', '--warmup':'warmup', '--loop':'loop', '--seed':'seed',
    '--audio':'audio', '--format':'format', '--quality':'quality', '--manifest':'manifest', '--source':'source',
    '--license':'license', '--cdp-port':'cdpPort', '--timeout':'timeout', '--request-timeout':'requestTimeout',
    '--max-bytes':'maxBytes' };
  for (let i=0; i<argv.length; i++) {
    if (argv[i] === '--list-presets') { o.listPresets=true; continue; }
    const key=flags[argv[i]];
    if (!key || i+1>=argv.length) fail(`Unknown or incomplete option: ${argv[i]}`);
    const value=argv[++i];
    o[key]=typeof o[key] === 'number' ? Number(value) : value;
  }
  if (typeof o.packs === 'string') o.packs=o.packs.split(',');
  if (!o.packs.length || o.packs.some(p=>!PACKS.includes(p))) fail('Unknown preset pack');
  bounded(o.cdpPort,1,65535,'--cdp-port',true);
  bounded(o.timeout,0.1,1800,'--timeout'); bounded(o.requestTimeout,0.1,60,'--request-timeout');
  bounded(o.width,1,2048,'--width',true); bounded(o.height,1,2048,'--height',true);
  bounded(o.width*o.height,1,2073600,'canvas pixels');
  bounded(o.fps,1,60,'--fps',true); bounded(o.seconds,0.01,300,'--seconds');
  bounded(o.warmup,0,120,'--warmup'); bounded(o.loop,0,5,'--loop');
  bounded(o.seed,1,4294967295,'--seed',true); bounded(o.quality,0.001,1,'--quality');
  bounded(o.maxBytes,1,1073741824,'--max-bytes',true);
  o.frameCount=Math.round(o.fps*o.seconds); o.loopFrames=Math.round(o.fps*o.loop);
  bounded(o.frameCount,1,7200,'frame count',true);
  if (o.loopFrames*2 >= o.frameCount) fail('--loop must be shorter than half the recording');
  bounded(o.loopFrames*o.width*o.height,0,67108864,'retained loop pixels');
  if (!MIME[o.format]) fail('--format must be jpeg, webp or png');
  if (!['synthetic','silence'].includes(o.audio)) fail('--audio must be synthetic or silence');
  if (o.effect && !EFFECTS.includes(o.effect)) fail('Unknown Vanta effect');
  if (o.url && !['http:','https:','file:'].includes(new URL(o.url).protocol)) fail('Unsupported URL protocol');
  if (!o.listPresets && ([o.preset,o.effect,o.url].filter(Boolean).length !== 1 || !o.out))
    fail('Pass exactly one of --preset, --effect or --url, and --out');
  if (o.listPresets && (o.effect || o.url)) fail('--list-presets is only for Butterchurn');
  if (o.effectOptionsFile && !o.effect) fail('--effect-options requires --effect');
  o.modules=resolve(o.modules);
  if (o.out) {
    o.out=resolve(o.out);
    o.manifest ??= `${basename(o.out)}.frames.json`;
    if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*\.frames\.json$/.test(o.manifest))
      fail('--manifest must be a basename ending in .frames.json');
  }
  o.mime=MIME[o.format];
  return o;
}

class Cdp {
  constructor(socket, signal, timeout) {
    this.socket=socket; this.signal=signal; this.timeout=timeout; this.nextId=0; this.pending=new Map();
    this.abort=()=>this.rejectAll(signal.reason || new Error('Baking cancelled'));
    signal.addEventListener('abort',this.abort,{once:true});
    socket.addEventListener('close',()=>this.rejectAll(new Error('CDP socket closed')));
    socket.addEventListener('error',()=>this.rejectAll(new Error('CDP socket failed')));
    socket.addEventListener('message',event=>{
      try {
        const message=JSON.parse(event.data), waiter=this.pending.get(message.id);
        if (waiter) {
          clearTimeout(waiter.timer); this.pending.delete(message.id);
          if (message.error) waiter.reject(new Error(message.error.message)); else waiter.resolve(message.result);
        } else if (message.method === 'Runtime.exceptionThrown') {
          this.browserError=message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text;
        } else if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') {
          this.browserError=message.params.args.map(a=>a.value || a.description || '').join(' ');
        }
      } catch (error) { this.rejectAll(error); }
    });
  }
  rejectAll(error) {
    this.closedError=error;
    for (const waiter of this.pending.values()) { clearTimeout(waiter.timer); waiter.reject(error); }
    this.pending.clear();
  }
  send(method,params={}) {
    this.signal.throwIfAborted();
    if (this.closedError) return Promise.reject(this.closedError);
    return new Promise((resolve,reject)=>{
      const id=++this.nextId;
      const timer=setTimeout(()=>{ this.pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); },this.timeout);
      this.pending.set(id,{resolve,reject,timer});
      try { this.socket.send(JSON.stringify({id,method,params})); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  async evaluate(expression) {
    if (this.browserError) fail(`Browser error: ${this.browserError}`);
    const result=await this.send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});
    if (result.exceptionDetails) fail(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    if (this.browserError) fail(`Browser error: ${this.browserError}`);
    return result.result.value;
  }
  close() { this.signal.removeEventListener('abort',this.abort); this.socket.close(); }
}

async function exists(path) {
  try { await lstat(path); return true; } catch (error) { if (error.code==='ENOENT') return false; throw error; }
}
async function serve(options) {
  const files=rendererFiles(options), bodies=await Promise.all(files.map(f=>readFile(join(options.modules,f))));
  const page=rendererHarness(options);
  const server=createServer((request,response)=>{
    const index=files.findIndex((_,i)=>request.url===`/module-${i}.js`);
    if (request.url === '/harness.html') { response.setHeader('content-type','text/html'); response.end(page); }
    else if (index>=0) { response.setHeader('content-type','text/javascript'); response.end(bodies[index]); }
    else { response.writeHead(404); response.end('Not found'); }
  });
  await new Promise((resolve,reject)=>{ server.once('error',reject); server.listen(0,'127.0.0.1',resolve); });
  return server;
}
async function upstreamNotices(o) {
  const paths=o.effect ? ['vanta/LICENSE.md','three/LICENSE']
    : ['butterchurn/LICENSE','butterchurn-presets/LICENSE'];
  return (await Promise.all(paths.map(async p=>`${p}\n${await readFile(join(o.modules,p),'utf8')}`))).join('\n\n');
}
function encodedImage(data,mime) {
  const prefix=`data:${mime};base64,`;
  if (typeof data !== 'string' || !data.startsWith(prefix)) fail(`Canvas did not encode ${mime}`);
  const body=data.slice(prefix.length);
  if (!body.length || body.length%4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(body)) fail('Malformed canvas image');
  const bytes=Buffer.from(body,'base64');
  const valid=mime==='image/png' ? bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))
    : mime==='image/jpeg' ? bytes[0]===255 && bytes[1]===216 && bytes[2]===255
      : bytes.toString('ascii',0,4)==='RIFF' && bytes.toString('ascii',8,12)==='WEBP';
  if (!valid) fail('Canvas image signature disagrees with MIME');
  return bytes;
}

async function bake(o) {
  const controller=new AbortController(), signal=controller.signal;
  const timer=setTimeout(()=>controller.abort(new Error('Total baking deadline exceeded')),o.timeout*1000);
  const onSignal=()=>controller.abort(new Error('Baking interrupted'));
  process.once('SIGINT',onSignal); process.once('SIGTERM',onSignal);
  let server, target, socket, cdp, stage, lock;
  const endpoint=`http://127.0.0.1:${o.cdpPort}`;
  const request=async (path,init={})=>{
    const response=await fetch(endpoint+path,{...init,signal:AbortSignal.any([signal,AbortSignal.timeout(o.requestTimeout*1000)])});
    if (!response.ok) fail(`CDP HTTP ${response.status}`);
    return response;
  };
  try {
    if (!o.listPresets) {
      if (await exists(o.out)) fail(`Output already exists: ${o.out}`);
      await mkdir(dirname(o.out),{recursive:true});
      const reservation=o.out+'.bake-lock'; await mkdir(reservation); lock=reservation;
      if (await exists(o.out)) fail(`Output already exists: ${o.out}`);
      stage=await mkdtemp(join(dirname(o.out),`.${basename(o.out)}-baking-`));
    }
    if (o.effectOptionsFile) {
      o.effectOptions=JSON.parse(await readFile(o.effectOptionsFile,'utf8'));
      if (!o.effectOptions || Array.isArray(o.effectOptions) || typeof o.effectOptions!=='object') fail('Effect options must be an object');
      for (const [key,value] of Object.entries(o.effectOptions)) {
        if (!/^[a-zA-Z][a-zA-Z0-9]*$/.test(key) || ['el','THREE','texturePath'].includes(key)
            || !(typeof value==='boolean' || (typeof value==='number' && Number.isFinite(value))
                 || (typeof value==='string' && /^#[0-9a-fA-F]{6}$/.test(value))))
          fail(`Unsupported effect option: ${key}`);
      }
    }
    if (!o.url) {
      o.license=[o.license,await upstreamNotices(o)].filter(Boolean).join('\n\n');
      o.source ??= o.effect ? `Vanta ${o.effect} — Teng Bao (vanta 0.5.24)` : `${o.preset} — butterchurn-presets`;
      server=await serve(o);
    }
    target=await (await request('/json/new?about:blank',{method:'PUT'})).json();
    socket=new WebSocket(target.webSocketDebuggerUrl);
    const opened=new Promise((resolve,reject)=>{
      socket.addEventListener('open',resolve,{once:true});
      socket.addEventListener('error',()=>reject(new Error('CDP connection failed')),{once:true});
      socket.addEventListener('close',()=>reject(new Error('CDP connection closed')),{once:true});
    });
    await Promise.race([opened,delay(o.requestTimeout*1000,null,{signal}).then(()=>fail('CDP connection timeout'))]);
    cdp=new Cdp(socket,signal,o.requestTimeout*1000);
    await cdp.send('Runtime.enable'); await cdp.send('Page.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride',{width:o.width,height:o.height,deviceScaleFactor:1,mobile:false});
    const navigation=await cdp.send('Page.navigate',{url:o.url || `http://127.0.0.1:${server.address().port}/harness.html`});
    if (navigation.errorText) fail(navigation.errorText);
    const until=Date.now()+o.requestTimeout*1000;
    const ready=o.url ? `!!document.querySelector(${JSON.stringify(o.canvas)})` : 'typeof __bake === "object" && typeof __bake.start === "function"';
    while (!await cdp.evaluate(ready)) {
      if (Date.now()>until) fail('Canvas page did not become ready');
      await delay(50,null,{signal});
    }
    if (o.listPresets) { console.log((await cdp.evaluate('__bake.names()')).join('\n')); return; }
    if (!o.url) {
      await cdp.evaluate(`__bake.start(${JSON.stringify(o)})`);
      const status=await cdp.evaluate('__bake.error || (__bake.ready ? "ready" : "not ready")');
      if (status !== 'ready') fail(status);
      for (let i=0,n=Math.round(o.warmup*o.fps);i<n;i++) {
        await cdp.evaluate(`__bake.advance(${1000/o.fps})`);
        if (i%o.fps===0) console.error(`warmup ${i}/${n}`);
      }
    } else if (o.warmup) await delay(o.warmup*1000,null,{signal});
    await cdp.evaluate(captureHarness(o));
    const names=[], extension=o.format==='jpeg'?'jpg':o.format, started=Date.now();
    let bytesWritten=0;
    for (let frame=0;frame<o.frameCount;frame++) {
      const blendIndex=frame-(o.frameCount-o.loopFrames);
      // WebGL drawing buffers may be cleared as soon as a task yields.
      // Advance and capture in one browser task, not two CDP round trips.
      const capture=`__capture(${frame<o.loopFrames},${blendIndex},${blendIndex>=0?(blendIndex+1)/o.loopFrames:0})`;
      const data=await cdp.evaluate(o.url ? capture : `(__bake.advance(${1000/o.fps}), ${capture})`);
      const bytes=encodedImage(data,o.mime);
      if (frame>=o.loopFrames) {
        bytesWritten+=bytes.length;
        if (bytesWritten>o.maxBytes) fail('Bundle exceeds --max-bytes');
        const name=`f${String(names.length).padStart(5,'0')}.${extension}`;
        await writeFile(join(stage,name),bytes,{flag:'wx'}); names.push(name);
      }
      if (o.url) {
        const wait=started+(frame+1)*1000/o.fps-Date.now();
        if (wait>0) await delay(wait,null,{signal});
      }
      if ((frame+1)%o.fps===0) console.error(`frames ${frame+1}/${o.frameCount}`);
    }
    const manifest={version:1,width:o.width,height:o.height,frame_rate:o.fps,frames:names,
      source:o.source || o.url,license:o.license || 'Unspecified; verify source rights before sharing',
      bake:{renderer:o.effect?'vanta':o.preset?'butterchurn':'url',work:o.effect || o.preset || o.url,
        seed:o.url?null:o.seed,warmup:o.warmup,loop_crossfade:o.loop,source_seconds:o.seconds}};
    const text=JSON.stringify(manifest,null,1)+'\n';
    if (bytesWritten+Buffer.byteLength(text)>o.maxBytes) fail('Bundle exceeds --max-bytes');
    await writeFile(join(stage,o.manifest),text,{flag:'wx'});
    signal.throwIfAborted();
    if (await exists(o.out)) fail(`Output already exists: ${o.out}`);
    await rename(stage,o.out); stage=null;
    console.log(`baked ${names.length} frames to ${o.out} (${o.width}x${o.height} at ${o.fps} fps; ${bytesWritten} image bytes)`);
  } finally {
    clearTimeout(timer); controller.abort(new Error('Baking finished'));
    process.removeListener('SIGINT',onSignal); process.removeListener('SIGTERM',onSignal);
    cdp?.close(); if (!cdp) socket?.close();
    if (target?.id) {
      try {
        const response=await fetch(`${endpoint}/json/close/${encodeURIComponent(target.id)}`,{signal:AbortSignal.timeout(2000)});
        if (!response.ok) console.error(`cleanup: could not close owned tab ${target.id}`);
      } catch { console.error(`cleanup: could not reach owned tab ${target.id}`); }
    }
    if (server) { server.closeAllConnections(); server.close(); }
    if (stage) await rm(stage,{recursive:true,force:true});
    if (lock) await rm(lock,{recursive:true,force:true});
  }
}

const args=process.argv.slice(2);
if (!args.length || args.includes('--help') || args[0]==='help') console.log(HELP);
else {
  let options;
  try { options=parse(args); }
  catch (error) { console.error(`bake usage: ${error.message}\nUse help for options.`); process.exitCode=2; }
  if (options) await bake(options).catch(error=>{ console.error('bake failed: '+error.message); process.exitCode=1; });
}
