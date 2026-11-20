// SPDX-License-Identifier: GPL-3.0-or-later
// CLI contract tests against a local CDP peer; no Chrome, GPU or network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, readdir, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const CLI=resolve('scripts/bake-canvas-frames.mjs');
const PNG='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1cAAAAASUVORK5CYII=';
function invoke(args,onSpawn,cli=CLI) {
  return new Promise((resolve,reject)=>{
    const child=spawn(process.execPath,[cli,...args]); let stdout='',stderr='';
    child.stdout.on('data',s=>stdout+=s); child.stderr.on('data',s=>stderr+=s);
    child.on('error',reject); child.on('exit',code=>resolve({code,stdout,stderr}));
    onSpawn?.(child);
  });
}
async function peer(mode='ok') {
  const calls=[],closed=[],connections=new Set(); let child;
  const server=createServer((req,res)=>{
    if (req.url.startsWith('/json/new')) res.end(JSON.stringify({id:'owned-tab',webSocketDebuggerUrl:`ws://127.0.0.1:${server.address().port}/devtools/page/owned-tab`}));
    else if (req.url.startsWith('/json/close/')) { closed.push(req.url); res.end('Target is closing'); }
    else { res.writeHead(404);res.end(); }
  });
  server.on('connection',s=>{ connections.add(s);s.on('close',()=>connections.delete(s)); });
  server.on('upgrade',(request,socket)=>{
    if (mode==='handshake-timeout') return;
    const accept=createHash('sha1').update(request.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const send=value=>{
      const bytes=Buffer.from(JSON.stringify(value));
      const header=bytes.length<126?Buffer.from([0x81,bytes.length]):Buffer.from([0x81,126,bytes.length>>8,bytes.length&255]);
      socket.write(Buffer.concat([header,bytes]));
    };
    let pending=Buffer.alloc(0);
    socket.on('data',chunk=>{
      pending=Buffer.concat([pending,chunk]);
      while (pending.length>=6) {
        let length=pending[1]&127, offset=2;
        if (length===126) { if (pending.length<8)return; length=pending.readUInt16BE(2);offset=4; }
        if (length===127) { if(pending.length<14)return;length=Number(pending.readBigUInt64BE(2));offset=10; }
        if (pending.length<offset+4+length)return;
        const opcode=pending[0]&15,mask=pending.subarray(offset,offset+4),bytes=Buffer.from(pending.subarray(offset+4,offset+4+length));
        pending=pending.subarray(offset+4+length);
        if (opcode===8) { socket.end(Buffer.from([0x88,0]));return; }
        for(let i=0;i<bytes.length;i++)bytes[i]^=mask[i%4];
        const message=JSON.parse(bytes.toString());calls.push(message);
        let result={};
        if (message.method==='Runtime.evaluate') {
          const expression=message.params.expression;
          if (expression.startsWith('__capture(') || expression.startsWith('(__bake.advance(')) {
            if (mode==='socket-close') {socket.destroy();return;}
            if (mode==='timeout') return;
            if (mode==='signal') {child.kill('SIGTERM');return;}
            if (mode==='dimensions') result={exceptionDetails:{text:'Canvas dimensions differ: 2x2'}};
            else result={result:{value:mode==='mime'?PNG.replace('image/png','image/jpeg'):PNG}};
          } else result={result:{value:expression.startsWith('__bake.error')?'ready':true}};
        }
        send({id:message.id,result});
      }
    });
  });
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  return {calls,closed,port:server.address().port,setChild:c=>child=c,
    close:async()=>{for(const s of connections)s.destroy();await new Promise(r=>server.close(r));}};
}
async function fixture(mode,run) {
  const root=await mkdtemp(join(tmpdir(),'bake-contract-')),remote=await peer(mode);
  const args=['--url','http://fixture.test/canvas','--width','1','--height','1','--fps','10','--seconds','.2',
    '--warmup','0','--format','png','--cdp-port',String(remote.port),'--request-timeout','.3','--timeout','2','--out',join(root,'work')];
  try { await run({root,remote,args}); } finally {await remote.close();await rm(root,{recursive:true,force:true});}
}

test('help succeeds and invalid/bounded inputs fail before CDP',async()=>{
  assert.equal((await invoke(['help'])).code,0);
  for(const [flag,value] of [['--seconds','Infinity'],['--fps','0'],['--fps','2.5'],['--width','2049'],
    ['--height','NaN'],['--warmup','-1'],['--seed','0'],['--max-bytes','Infinity'],['--manifest','../escape.frames.json']]) {
    const result=await invoke(['--url','http://fixture.test','--out','/tmp/not-written',flag,value]);
    assert.equal(result.code,2,result.stderr);
  }
});
test('atomic success writes validated manifest, frames and closes only its tab',async()=>fixture('ok',async({root,remote,args})=>{
  const result=await invoke(args);assert.equal(result.code,0,result.stderr);
  const manifest=JSON.parse(await readFile(join(root,'work','work.frames.json'),'utf8'));
  assert.deepEqual(manifest.frames,['f00000.png','f00001.png']);
  assert.equal(manifest.width,1);assert.equal(manifest.frame_rate,10);
  assert.deepEqual(await readdir(root),['work']);
  assert.deepEqual(remote.closed,['/json/close/owned-tab']);
  assert(remote.calls.some(c=>c.method==='Emulation.setDeviceMetricsOverride' && c.params.width===1));
  assert.equal((await readFile(join(root,'work','f00000.png'))).toString('base64'),PNG.split(',')[1]);
}));
for(const mode of ['socket-close','timeout','signal','dimensions','mime','handshake-timeout']) {
  test(`${mode} fails promptly, removes staging and closes owned tab`,async()=>fixture(mode,async({root,remote,args})=>{
    const result=await invoke(args,remote.setChild);assert.equal(result.code,1,result.stderr);
    assert.deepEqual(await readdir(root),[]);
    assert.deepEqual(remote.closed,['/json/close/owned-tab']);
  }));
}
test('output byte limit includes data and leaves no half bundle',async()=>fixture('ok',async({root,args})=>{
  const result=await invoke([...args,'--max-bytes','10']);assert.equal(result.code,1);assert.match(result.stderr,/max-bytes/);
  assert.deepEqual(await readdir(root),[]);
}));
test('total deadline cancels warmup and cleans up',async()=>fixture('ok',async({root,remote,args})=>{
  const result=await invoke([...args,'--warmup','1','--timeout','.2','--request-timeout','1']);
  assert.equal(result.code,1);assert.deepEqual(await readdir(root),[]);
  assert.deepEqual(remote.closed,['/json/close/owned-tab']);
}));
test('virtual warmup advances each frame and loop omits its leading window',async()=>fixture('ok',async({root,remote,args})=>{
  const modules=join(root,'modules');
  for(const file of ['butterchurn/LICENSE','butterchurn-presets/LICENSE','butterchurn/lib/butterchurn.min.js',
    'butterchurn-presets/lib/butterchurnPresets.min.js']) {
    const path=join(modules,file);await mkdir(join(path,'..'),{recursive:true});await writeFile(path,'fixture upstream notice');
  }
  const custom=args.slice(2); // replace --url URL with a local preset renderer
  const result=await invoke(['--preset','fixture','--packs','base','--modules',modules,...custom,
    '--fps','10','--seconds','1','--warmup','.3','--loop','.2']);
  assert.equal(result.code,0,result.stderr);
  const expressions=remote.calls.filter(c=>c.method==='Runtime.evaluate').map(c=>c.params.expression);
  assert.equal(expressions.filter(e=>e==='__bake.advance(100)').length,3);
  assert.equal(expressions.filter(e=>e.startsWith('(__bake.advance(')).length,10);
  assert(expressions.some(e=>e==='(__bake.advance(100), __capture(false,1,1))'));
  const manifest=JSON.parse(await readFile(join(root,'work','work.frames.json'),'utf8'));
  assert.equal(manifest.frames.length,8);assert.match(manifest.license,/fixture upstream notice/);
}));
test('collection delegates baking and emits independently loadable scene/pack data',async()=>fixture('ok',async({root,remote})=>{
  const catalog=join(root,'catalog.json'),out=join(root,'gallery');
  await writeFile(catalog,JSON.stringify({version:1,defaults:{width:1,height:1,fps:10,seconds:.2,warmup:0,format:'png'},
    packs:[{id:'test',title:'Test',presentation:'card',background:'#ffffff'}],
    works:[{id:'one',title:'One',pack:'test',url:'http://fixture.test/canvas',license:'fixture notice'}]}));
  const argv=['--catalog',catalog,'--out',out,'--cdp-port',String(remote.port)];
  const cli=resolve('scripts/bake-gallery.mjs');
  assert.equal((await invoke(['help'],null,cli)).code,0);
  const listing=await invoke(['--catalog',catalog,'--list'],null,cli);assert.match(listing.stdout,/one\ttest\tOne/);
  const result=await invoke(argv,null,cli);assert.equal(result.code,0,result.stderr);
  const spec=await readFile(join(out,'frames-one.esr'),'utf8');
  assert.match(spec,/:recording "one\/one.frames.json"/);
  assert.match(spec,/:background "#ffffff"/);
  const config=await readFile(join(out,'gallery.el'),'utf8');
  assert.match(config,/lexical-binding: t/);assert.match(config,/gallery-test/);assert.doesNotMatch(config,/:theme/);
  assert.doesNotMatch(config,/setq etaf-screensaver-program/);
  assert.doesNotMatch(config,/:background/);
  assert.equal((await invoke(argv,null,cli)).code,1);
}));
test('existing output is preserved without opening a tab',async()=>fixture('ok',async({root,remote,args})=>{
  await mkdir(join(root,'work'));await writeFile(join(root,'work','keep'),'original');
  const result=await invoke(args);assert.equal(result.code,1);assert.match(result.stderr,/already exists/);
  assert.equal(await readFile(join(root,'work','keep'),'utf8'),'original');assert.equal(remote.calls.length,0);
}));
