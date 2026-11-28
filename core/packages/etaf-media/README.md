# etaf-media

[中文](README.zh-CN.md)

Native video playback engine and `etaf-video` Component for [ETAF](https://github.com/emacs-taf/etaf). Supports local files, HTTP(S) streams, split video/audio streams, hardware GPU video overlay layers (macOS Metal/CAOpenGL, Windows Win32/WGL, Linux X11/Wayland EGL via `libmpv`), Kitty terminal graphics, pure-Emacs image rings, and ASCII/half-block render modes.

## Prerequisites

- Emacs 29.1 or newer
- `etaf`, `ebox`, `ecss`
- Optional: `libmpv` (for native GPU/libmpv playback via prebuilt `native/manifest.json`), `ffmpeg` / `ffprobe` / `ffplay` (for fallback decoding, probing and audio sidecar)

## Installation

Install from the ETAF package archive with `M-x etaf-install` (`etaf-media`), or load from a source checkout of [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf):

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-media"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(require 'etaf-media)
```

## Minimal Example

```elisp
(require 'etaf)
(require 'etaf-media)

(etaf-mount (get-buffer-create "*ETAF Video*")
            (etaf-view
             (etaf-video :src nil :mode 'ascii :columns 40 :rows 12
                         :handle 'demo :autoplay nil)))
```

## Documentation

- Public API inventory: [etaf-media.el](etaf-media.el) Commentary
- Native video chapter: [ETAF Reference Manual](https://etaf.top/native-video/)
- Architecture: [docs/architecture.md](docs/architecture.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)

## Checks

```sh
make -C core/packages/etaf-media check
```
