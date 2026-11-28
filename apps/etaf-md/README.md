# ETAF Markdown Preview

[中文](README.zh-CN.md)

ETAF Markdown Preview renders a local Markdown document as a modern reading view inside Emacs. Built on [ETAF](https://github.com/emacs-taf/etaf) components and the [Ebox](https://github.com/emacs-taf/ebox) renderer, it combines a centered reading measure, typographic heading scale, syntax-highlighted code blocks with line markers and copy actions, full-grid pipe tables, GitHub alerts, footnotes, local image/video playback, native zero-browser Mermaid diagrams and MathJax display formulas, documentation containers, and Emacs living-document widgets — all inside one ordinary Emacs buffer so native scrolling, isearch and window splitting keep working.

Wide single-window reading view (`M-x etaf-md-open`) with headings, callouts, full-grid tables, highlighted code blocks, and crisp native Mermaid & MathJax SVGs:

![Wide reading view](https://etaf.top/media/etaf-md/etaf-md-preview-wide.webp)

Side-by-side live editing (`M-x etaf-md-preview` or `v`) with O(Δ) block-level repainting, proportional scroll-follow and jump-to-source:

![Side-by-side live preview](https://etaf.top/media/etaf-md/etaf-md-live-split.webp)

Documentation containers (`:::name {attrs}`) and Emacs-native living-document widgets (`stats`, `timeline`, `tabs`, `diff`, `code-ref`, `symbol`, `git-log`):

![Containers and living-document widgets](https://etaf.top/media/etaf-md/etaf-md-widgets.webp)

Light, dark, sepia and face-derived `auto` palettes (`t` to cycle), keeping every table, container, Mermaid diagram and formula crisp across themes:

![Light theme reading view](https://etaf.top/media/etaf-md/etaf-md-light.webp)

## Capabilities

- **Full Markdown + GFM + ETAF extensions**: CommonMark blocks and inlines, pipe tables with full grid borders and alignment, interactive task checkboxes (`- [x]` writing back to source), numbered footnotes with jump & `↩` back-link, YAML front matter, GitHub / Obsidian collapsible alerts (`> [!NOTE]`), `==highlights==`, `!!spoilers!!`, `[+annotations]`, `*[ABBR]:` cards, `[[wiki-links]]`, `:kbd[...]`, `:badge[...]`, `:color[...]`, `:sym[...]` and selectable dialects (`etaf`, `gfm`, `commonmark`, or feature plists).
- **Rich fenced code blocks**: `title=`, `:line-numbers[=N]`, `:collapsed-lines[=N]`, `{1,4-7}`, `/word/` and `[!code highlight|focus|++|--|warning|error|word:...]` markers, `:whitespace`, `:indent-guides` and one-click copy.
- **Native zero-browser Mermaid & MathJax**: with the optional prebuilt QuickJS dynamic module (`M-x etaf-install-native`, architecture inspired by [LuciusChen/pele.el](https://github.com/LuciusChen/pele.el)), `mermaid` fences render via vendored [Obsidian Pele](https://github.com/obsidianmd/pele) with native CoreText / Pango label measurement and `$$` display formulas render via vendored [MathJax](https://github.com/mathjax/MathJax-src) TeX-to-SVG inside a sandboxed background thread — zero Chromium, zero Node.js, zero local compiler required, crisp standalone SVGs cached on disk, and stale-while-revalidate during live edits.
- **Extensible `:::` documentation containers & living docs**: over 35 built-in containers (`card`, `columns`, `box`, `steps`, `timeline`, `stats`, `field`, `file-tree`, `chat`, `tabs`, `code-tabs`, `accordion`, `details`, `table`, `window`, `panel`, `tab-panel`, `form`, `chart`, `progress`, `keymap`, `breadcrumb`, `diff`, `pros-cons`, `demo`, `qrcode`, `code-tree`, `npm-to`, `image-card`, `link-card`) plus sandboxed workspace living-document widgets (`include`, `code-ref`, `symbol`, `project-tree`, `git-log`, `git-diff`) and trust-gated Runbook `run` blocks. Add custom node types with `etaf-md-define-node`; see [the extension syntax](docs/extensions.md).
- **Incremental live editing & minimal command surface**: global `M-x` exposes strictly two commands — `M-x etaf-md-open` (full-width single-window reader, `q` restores the source buffer) and `M-x etaf-md-preview` (non-destructive right-split live preview with proportional scroll-follow). Edits coalesce onto a 16 ms frame tick and splice-repaint only the changed block slice while preserving every other block's interactive state.
- **Media, lightbox & navigation**: local images and async-cached remote HTTP(S) images (`etaf-md-remote-images`), in-buffer media lightbox (`RET` on images and Mermaid diagrams), inline video playback via ETAF's video Component (`ffmpeg`), independent configurable TOC side window (`T`, `*ETAF Outline*`, configurable via `etaf-md-toc-side` defaulting to `left` and `etaf-md-toc-width`), outline jumps (`n`/`p`, `j`), reverse jump to source (`e`/`o`), floating link/symbol peek dialog (`K`), spoiler toggle (`S`), theme cycle (`t`), measure bounds (`[`/`]`) and in-buffer searchable help (`?`). Every preview action is also a preview-scoped `M-x` command; see [Usage](#usage) for customizing keys.

## Prerequisites

| Requirement | Why | Check |
| --- | --- | --- |
| Emacs 29.1 or newer | the ETAF runtime and Ebox | `emacs --version` |
| ETAF (`>= 0.3.11`), ETAF UI (`>= 0.3.13`), Ebox and ECSS | rendering and the component catalog | installed automatically via `etaf-install` |
| Prebuilt native module (optional, recommended) | fast zero-browser Mermaid and math SVGs without a local compiler (downloaded & SHA-256 verified into `~/.cache/emacs-taf/native/` via `M-x etaf-install-native`) | `M-x etaf-install-doctor` |
| ffmpeg (optional) | inline video playback and terminal image conversion | `ffmpeg -version` |
| qrencode (optional) | renders `qrcode` blocks | `qrencode -V` |
| git (optional) | powers `git-log` and `git-diff` living-doc blocks | `git --version` |

## Installation

### From the ETAF package archive (recommended)

```elisp
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
```

Then run `M-x etaf-install` and select `etaf-md` — in one step the installer fetches `etaf`, `etaf-ui`, `ebox` and `ecss`, downloads the checksum-verified prebuilt QuickJS Mermaid & MathJax native module for your platform into `~/.cache/emacs-taf/native/` (preserved across package upgrades, with no C compiler, Node.js or `make` required), and activates it immediately before opening `etaf-md`.

If you installed offline or directly via `package-install`, run `M-x etaf-install-native` and select `etaf-md` (or press `n` on `etaf-md` in `M-x etaf-install-manage`) anytime to fetch or refresh the prebuilt binary. Run `M-x etaf-install-doctor` (or evaluate `(etaf-md-doctor)`) to inspect whether `typeset-native`, `ffmpeg`, `qrencode` and `git` are active.

### From a source checkout

Clone this repository next to the framework checkouts so the directories are siblings, optionally run `make native-build`, then add each repository root to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/emacs-taf/ecss")
(add-to-list 'load-path "/path/to/emacs-taf/ebox")
(add-to-list 'load-path "/path/to/emacs-taf/etaf-ui")
(add-to-list 'load-path "/path/to/emacs-taf/etaf")
(add-to-list 'load-path "/path/to/emacs-taf/etaf-md")
(require 'etaf-md)
```

## Usage

Inside any Markdown buffer, run `M-x etaf-md-open` to read it full-width in the current window without prompting or splitting (`C-u M-x etaf-md-open` or running from another buffer prompts for a file; `q` restores the originating buffer in place). While authoring, run `M-x etaf-md-preview` in the source buffer to toggle a side-by-side right split with scroll-follow, or press `v` inside a preview to toggle the split on the fly.

```
M-x etaf-md-open         # read current .md file (or pick a file) in current window
M-x etaf-md-preview      # toggle side-by-side live preview beside source buffer
```

Open any local `.md` file and run `M-x etaf-md-open` or `M-x etaf-md-preview` right away (in a source checkout, `examples/all-syntax.markdown`, `examples/widgets-showcase.markdown` and `examples/sample.markdown` provide full feature and benchmark pages; ELPA packages intentionally omit `Makefile` and `examples/` to stay compact).

| Key | Command | Action |
| --- | --- | --- |
| `n` / `p` | `etaf-md-next-heading` / `etaf-md-previous-heading` | next / previous heading (pushes mark) |
| `j` | `etaf-md-goto-heading` | jump to heading with completion |
| `T` | `etaf-md-toggle-toc` | toggle the independent TOC side window (`etaf-md-toc-side`, default `left`) |
| `e` / `o` | `etaf-md-goto-source` | jump back to the matching line in the source buffer |
| `v` | `etaf-md-toggle-split` | toggle side-by-side source + live preview split |
| `f` | `etaf-md-follow-scroll` | toggle proportional scroll-follow with the source window |
| `RET` or mouse-1 | *(in-buffer host action)* | activate link, toggle checkbox, open image/diagram lightbox, or play/pause video |
| `g` / `r` | `etaf-md-reload` | re-read and repaint the document |
| `t` | `etaf-md-cycle-theme` | cycle theme (`dark` / `light` / `sepia` / `auto`) |
| `[` / `]` | `etaf-md-narrower` / `etaf-md-wider` | narrow / widen the reading measure |
| `K` / `S` | `etaf-md-preview-link` / `etaf-md-toggle-spoilers` | preview link or symbol at point / reveal or hide all spoilers |
| `?` | *(ETAF help)* | searchable in-buffer help modal |
| `q` | `etaf-md-close` | close the preview (restore previous buffer, or close live split) |
| `C-s`, `C-v`, `M-v`, wheel | *(native Emacs)* | native isearch and scrolling |

### Customizing keys

Preview bindings are defined in the customizable variable `etaf-md-keys` rather than a traditional major-mode keymap (defaults use single keys only so user prefix maps such as `C-c` / `C-t` / `C-x` are never shadowed, and every command above is also callable via `M-x` / `M-X` inside a preview buffer). Each entry has the form `(KEY COMMAND LABEL)`.

Run `M-x customize-variable RET etaf-md-keys`, or edit `etaf-md-keys` in your init file (changes apply to newly opened previews):

```elisp
(with-eval-after-load 'etaf-md
  ;; Rebind `e' to `C-c e' and unbind `o':
  (setq etaf-md-keys
        (cons '("C-c e" etaf-md-goto-source "Jump to source")
              (assoc-delete-all "o"
                                (assoc-delete-all "e" (copy-sequence etaf-md-keys))))))

;; Or disable all single-key bindings (useful for Evil / Meow users):
;; (setq etaf-md-keys nil)
```

## Development

```sh
make native-build     # build the embedded QuickJS + Pele + MathJax native module
make check            # structure, compilation, API bindings, acceptance tests
make benchmark        # batch render baseline for a generated large document
```

## Acknowledgements

The embedded QuickJS + Pele + CoreText/Pango background-thread SVG renderer in `native/` is directly inspired by [LuciusChen/pele.el](https://github.com/LuciusChen/pele.el), building on unmodified vendored [Obsidian Pele](https://github.com/obsidianmd/pele), Fabrice Bellard's [QuickJS](https://github.com/bellard/quickjs) and [MathJax](https://github.com/mathjax/MathJax-src). See [native/vendor/README.md](native/vendor/README.md) for exact upstream versions, SHA-256 digests and retained licenses.

## Documentation

- User manual: [docs/manual.md](docs/manual.md) · [中文手册](docs/manual.zh-CN.md)
- Extension syntax & container catalogue: [docs/extensions.md](docs/extensions.md) · [扩展语法（中文）](docs/extensions.zh-CN.md)
- Architecture & performance envelope: [docs/architecture.md](docs/architecture.md)
- Public API inventory: Commentary of [etaf-md.el](etaf-md.el)
- Version history: [CHANGELOG.md](CHANGELOG.md)
