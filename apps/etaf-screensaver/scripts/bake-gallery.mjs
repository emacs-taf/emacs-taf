#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Thin collection recipe runner. All rendering/cleanup belongs to the baker.
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir, mkdtemp, rm, lstat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
const HERE=dirname(fileURLToPath(import.meta.url));
const HELP=`usage: node scripts/bake-gallery.mjs --out DIR [--modules DIR] [--cdp-port N]
  --list             list curated works without starting a browser
  --only ID,ID       build a selected subset
  --catalog FILE    collection recipe (default scripts/gallery.json)
  --seconds S --warmup S --loop S --fps N --width W --height H
                     override baking defaults, e.g. smaller review copies
  help | --help      show usage
Requires a running local Chrome CDP endpoint. The bundled recipe uses
  vanta@0.5.24 three@0.134.0; custom preset works also need
  butterchurn@2.6.7 butterchurn-presets@2.4.7.
Existing work directories are never overwritten. Completed works survive a
later failure, but gallery.el is written only when every selected work passes.
Load OUT/gallery.el from Emacs to add the scenes/packs; it does not change your
program or presentation choice. Baked images and generated config stay out of Git.`;
const args=process.argv.slice(2);
let child, interrupted=false;
const interrupt=()=>{interrupted=true;child?.kill('SIGTERM');};
function string(value){return JSON.stringify(String(value));}
async function main() {
  if (!args.length || args[0]==='help' || args.includes('--help')) {console.log(HELP);return;}
  const options={catalog:join(HERE,'gallery.json')},overrides={};
  for(let i=0;i<args.length;i++) {
    const flag=args[i];if(flag==='--list'){options.list=true;continue;}
    if(!['--out','--modules','--cdp-port','--only','--catalog','--seconds','--warmup','--loop','--fps','--width','--height'].includes(flag) || i+1>=args.length)
      throw new Error('Unknown/incomplete option: '+flag);
    const key=flag.slice(2),value=args[++i];
    if(['seconds','warmup','loop','fps','width','height'].includes(key)) {
      const n=Number(value);if(!Number.isFinite(n))throw new Error('Not a finite number: '+flag);overrides[key]=n;
    } else options[key]=value;
  }
  const catalog=JSON.parse(await readFile(options.catalog,'utf8'));
  if(catalog.version!==1 || !Array.isArray(catalog.works) || !Array.isArray(catalog.packs))throw new Error('Invalid collection recipe');
  const ids=new Set(),packIds=new Set();
  for(const pack of catalog.packs) {
    if(!/^[a-z][a-z0-9-]*$/.test(pack.id) || packIds.has(pack.id)
       || !['full','card','band','mosaic'].includes(pack.presentation))throw new Error('Invalid/duplicate pack');
    packIds.add(pack.id);
  }
  for(const work of catalog.works) {
    if(!/^[a-z][a-z0-9-]*$/.test(work.id) || ids.has(work.id) || !packIds.has(work.pack)
       || [work.preset,work.effect,work.url].filter(Boolean).length!==1)throw new Error('Invalid/duplicate work');
    ids.add(work.id);
  }
  const selected=options.only?.split(',');
  if(selected?.some(id=>!ids.has(id)))throw new Error('Unknown selected work');
  const works=catalog.works.filter(w=>!selected || selected.includes(w.id));
  if(options.list){for(const w of works)console.log(`${w.id}\t${w.pack}\t${w.title}\t${w.effect || w.preset || w.url}`);return;}
  if(!options.out)throw new Error('--out is required');
  const out=resolve(options.out),defaults={...catalog.defaults,...overrides},failures=[];
  await mkdir(out,{recursive:true});
  // Generated image bundles must not accidentally enter an enclosing checkout.
  try { await writeFile(join(out,'.gitignore'),'*\n',{flag:'wx'}); }
  catch(error) { if(error.code!=='EEXIST')throw error; }
  // Refuse the entire selection before touching existing work.
  for(const work of works) {
    try {await lstat(join(out,work.id));throw new Error('Output already exists: '+work.id);}
    catch(error){if(error.code!=='ENOENT')throw error;}
  }
  const temporary=await mkdtemp(join(tmpdir(),'screensaver-gallery-'));
  process.once('SIGINT',interrupt);process.once('SIGTERM',interrupt);
  try {
    for(const [index,work] of works.entries()) {
      if(interrupted)throw new Error('Gallery interrupted');
      const settings={...defaults,...work.bake},argv=[join(HERE,'bake-canvas-frames.mjs'),'--out',join(out,work.id)];
      for(const [key,value] of Object.entries(settings))argv.push('--'+key,String(value));
      for(const key of ['modules','cdp-port'])if(options[key])argv.push('--'+key,options[key]);
      for(const key of ['preset','effect','url','license'])if(work[key])argv.push('--'+key,work[key]);
      if(work.options) {
        const path=join(temporary,work.id+'.json');await writeFile(path,JSON.stringify(work.options));argv.push('--effect-options',path);
      }
      console.log(`[${index+1}/${works.length}] ${work.title} (${work.id})`);
      const code=await new Promise((resolve,reject)=>{
        child=spawn(process.execPath,argv,{stdio:'inherit'});child.once('error',reject);child.once('exit',resolve);
      });child=null;
      if(code!==0){failures.push(work.id);continue;}
      const manifest=JSON.parse(await readFile(join(out,work.id,work.id+'.frames.json'),'utf8'));
      const background=work.options?.backgroundColor ?? catalog.packs.find(p=>p.id===work.pack).background;
      const paper=typeof background==='number' ? '#'+background.toString(16).padStart(6,'0') : background;
      const spec=`;;; -*- lisp-data -*-\n(:id frames-${work.id} :background ${string(paper)} :title ${string(work.title)} :summary ${string(manifest.source)} :tags (gallery ${work.pack}) :provider frames :recording ${string(work.id+'/'+work.id+'.frames.json')} :kind image :frame-rate ${manifest.frame_rate} :frame-count ${manifest.frames.length} :source ${string(manifest.source)} :license ${string(manifest.license)})\n`;
      await writeFile(join(out,'frames-'+work.id+'.esr'),spec,{flag:'wx'});
    }
    if(interrupted)throw new Error('Gallery interrupted');
    if(failures.length)throw new Error(`Failed works: ${failures.join(', ')}; completed bundles remain in ${out}; gallery.el was not written`);
    const packs=catalog.packs.map(p=>{
      const scenes=works.filter(w=>w.pack===p.id).map(w=>'frames-'+w.id);
      return scenes.length ? `(gallery-${p.id} :title ${string(p.title)} :presentation ${p.presentation} :order sequential :scenes (${scenes.join(' ')}))` : null;
    }).filter(Boolean);
    const config=`;;; -*- lexical-binding: t; -*-\n;;; Generated artwork collection; playback choices remain user-owned.\n(require 'etaf-screensaver)\n(add-to-list 'etaf-screensaver-scene-directories (file-name-directory (or load-file-name buffer-file-name)))\n(dolist (pack '(${packs.join('\n               ')}))\n  (setf (alist-get (car pack) etaf-screensaver-packs) (cdr pack)))\n(etaf-screensaver-load-scenes)\n`;
    await writeFile(join(out,'gallery.el'),config,{flag:'wx'});
    console.log(`Gallery ready: ${works.length} works; load ${join(out,'gallery.el')}`);
  } finally {
    process.removeListener('SIGINT',interrupt);process.removeListener('SIGTERM',interrupt);
    child?.kill('SIGTERM');await rm(temporary,{recursive:true,force:true});
  }
}
await main().catch(error=>{console.error('gallery failed: '+error.message);process.exitCode=1;});
