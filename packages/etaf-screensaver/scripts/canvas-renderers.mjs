// SPDX-License-Identifier: GPL-3.0-or-later
// Browser-side adapters for upstream renderers. Nothing here runs in Emacs.
export const EFFECTS = ['birds', 'cells', 'clouds', 'dots', 'fog', 'halo', 'net', 'rings', 'waves'];
export const PACKS = ['base', 'extra', 'extra2', 'md1', 'minimal', 'nonminimal'];
const PACK_FILES = ['', 'Extra', 'Extra2', 'MD1', 'Minimal', 'NonMinimal'];

export function rendererFiles(options) {
  if (options.effect) return [
    'three/build/three.min.js', `vanta/dist/vanta.${options.effect}.min.js`,
  ];
  return ['butterchurn/lib/butterchurn.min.js',
    ...options.packs.map(pack => `butterchurn-presets/lib/butterchurnPresets${PACK_FILES[PACKS.indexOf(pack)]}.min.js`)];
}

export function rendererHarness(options) {
  // Configure the clock and RNG before upstream modules initialize. Keep RAF
  // callbacks queued until an explicit frame step, including warmup frames.
  return `<!doctype html><meta charset="utf-8"><style>
html,body,#art{margin:0;width:100%;height:100%;overflow:hidden;background:#000}canvas{display:block}
</style><script>
let seed = ${options.seed};
Math.random = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return (seed >>> 0) / 4294967296; };
window.__vt = 1;
performance.now = () => __vt;
Date.now = () => 1700000000000 + __vt;
const callbacks = new Map(); let callbackId = 0;
window.requestAnimationFrame = fn => { callbacks.set(++callbackId, fn); return callbackId; };
window.cancelAnimationFrame = id => callbacks.delete(id);
window.__bake = {ready:false, error:null};
window.addEventListener('error', e => { __bake.error = e.message || 'Script resource failed'; });
</script>
${rendererFiles(options).map((_, i) => `<script src="/module-${i}.js"></script>`).join('\n')}
<div id="art"></div><script>
const presets = {};
for (const key of Object.keys(window)) {
  if (/^butterchurnPresets/.test(key) && typeof window[key].getPresets === 'function')
    Object.assign(presets, window[key].getPresets());
}
__bake.names = () => Object.keys(presets).sort();
__bake.start = opts => {
  try {
    let canvas, visualizer;
    if (opts.effect) {
      const effect = VANTA[opts.effect.toUpperCase()]({
        ...opts.effectOptions, el: '#art', THREE,
        mouseControls:false, touchControls:false, gyroControls:false,
        forceAnimate:true, minWidth:1, minHeight:1, scale:1, scaleMobile:1
      });
      canvas = effect.renderer.domElement;
      __bake.advance = ms => {
        __vt += ms;
        const pending = [...callbacks.values()]; callbacks.clear();
        for (const callback of pending) callback(__vt);
      };
    } else {
      canvas = document.createElement('canvas');
      canvas.width = opts.width; canvas.height = opts.height;
      document.querySelector('#art').appendChild(canvas);
      visualizer = (butterchurn.default || butterchurn).createVisualizer(new AudioContext(), canvas,
        {width:opts.width, height:opts.height, pixelRatio:1});
      const preset = presets[opts.preset];
      if (!preset) throw new Error('Unknown preset: ' + opts.preset);
      visualizer.loadPreset(preset, 0);
      const audioSize = visualizer.audio.fftSize;
      let audioSeed = 987654321;
      const random = () => {
        audioSeed ^= audioSeed << 13; audioSeed ^= audioSeed >>> 17; audioSeed ^= audioSeed << 5;
        return (audioSeed >>> 0) / 4294967296;
      };
      const audioLevels = seconds => {
        const bass = 0.55 + 0.45 * Math.sin(seconds * Math.PI * 2 * 0.45);
        const mid = 0.5 + 0.5 * Math.sin(seconds * Math.PI * 2 * 1.1 + 1.7);
        const treble = 0.5 + 0.5 * Math.sin(seconds * Math.PI * 2 * 2.3 + 0.4);
        const bytes = new Uint8Array(audioSize);
        for (let i = 0; i < audioSize; i++) {
          const phase = i / audioSize * Math.PI * 2;
          const sample = 0.5 * Math.sin(phase * 3) * bass + 0.25 * (random() * 2 - 1) * mid
                       + 0.15 * Math.sin(phase * 40) * treble;
          bytes[i] = Math.max(0, Math.min(255, Math.round(128 + 120 * sample)));
        }
        return {timeByteArray:bytes, timeByteArrayL:bytes, timeByteArrayR:bytes};
      };
      __bake.advance = ms => {
        __vt += ms;
        visualizer.render(opts.audio === 'synthetic'
          ? {audioLevels:audioLevels(__vt / 1000), elapsedTime:ms / 1000}
          : {elapsedTime:ms / 1000});
      };
    }
    __bake.ready = true;
  } catch (error) { __bake.error = String(error.stack || error); }
};
</script>`;
}

// Install after navigation; URL mode is deliberately real-time and unseeded.
// The first loop window is retained as decoded images. Crossfade the tail
// into it, then omit those leading frames: the seam is adjacent motion.
export function captureHarness(options) {
  return `(() => {
    const first = [], width = ${options.width}, height = ${options.height};
    const output = document.createElement('canvas'); output.width=width; output.height=height;
    const context = output.getContext('2d');
    window.__capture = async (remember, blendIndex, alpha) => {
      const canvas = document.querySelector(${JSON.stringify(options.canvas)});
      if (!canvas) throw new Error('Canvas disappeared');
      if (canvas.width !== width || canvas.height !== height)
        throw new Error('Canvas dimensions differ: ' + canvas.width + 'x' + canvas.height);
      let source = canvas;
      if (blendIndex >= 0) {
        context.globalAlpha=1; context.drawImage(canvas,0,0);
        context.globalAlpha=alpha; context.drawImage(first[blendIndex],0,0);
        context.globalAlpha=1; source=output;
      }
      const data = source.toDataURL(${JSON.stringify(options.mime)}, ${options.quality});
      if (remember) {
        const image = new Image(); image.src=data; await image.decode(); first.push(image);
      }
      return data;
    };
    return true;
  })()`;
}
