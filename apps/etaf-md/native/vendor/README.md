# Vendored dependencies

Runtime builds and execution of `etaf-md-typeset-native` do not fetch dependencies from the network. The embedded QuickJS + Pele + native CoreText/Pango background-thread SVG architecture is directly inspired by [LuciusChen/pele.el](https://github.com/LuciusChen/pele.el).

| Dependency | Version | Source | License | SHA-256 |
| --- | --- | --- | --- | --- |
| [Pele](https://github.com/obsidianmd/pele) | 1.13.0 | https://registry.npmjs.org/pele/-/pele-1.13.0.tgz | MIT | `00f879d86c5a6ece897ef70e18fd228a9952bba338a0cb1293b373900d7414bd` |
| [QuickJS](https://github.com/bellard/quickjs) | 2026-06-04 | https://github.com/bellard/quickjs/archive/3d5e064e9dd67c70f7962836505a7fa067bf0a4e.tar.gz | MIT | `afccd11533e21a4e49af43e6909fc7236ed0b92f25e01e1061ceb0b47e15e05d` |
| [MathJax](https://github.com/mathjax/MathJax-src) (`mathjax-full`) | 3.2.2 | https://registry.npmjs.org/mathjax-full/-/mathjax-full-3.2.2.tgz | Apache-2.0 | `9da8715555528acbdc6977c20364e19f3494af4595794d83e4d13b4681f6cff0` (bundle) |

`pele/pele.global.js`, `pele/package.json` and `pele/LICENSE` are copied without modification from the npm archive. [Pele](https://github.com/obsidianmd/pele) is by kepano / Obsidian.

`quickjs/` contains the unmodified runtime C sources, supporting headers, `VERSION` and `LICENSE` from the official `2026-06-04` release commit (`3d5e064e9dd67c70f7962836505a7fa067bf0a4e`). It omits the command-line programs, libc bindings, examples and tests; no OS or filesystem JavaScript bindings are exposed by the host. [QuickJS](https://github.com/bellard/quickjs) is by Fabrice Bellard and Charlie Gordon.

`mathjax/mathjax-tex-svg.global.js` is a standalone IIFE bundle built with `esbuild` from unmodified `mathjax-full@3.2.2` (`TeX` with `AllPackages` excluding `bussproofs`, `SVG` with `fontCache: 'none'`, and `liteAdaptor`), exposing `globalThis.__etafMdMathJaxSvg(source, display)` with zero browser or Node.js dependencies. `mathjax/LICENSE` and `mathjax/package.json` are copied without modification from `mathjax-full@3.2.2`.

Retain each upstream license and copyright notice when distributing these sources or a built native module: `pele/LICENSE`, `quickjs/LICENSE` and `mathjax/LICENSE`.
