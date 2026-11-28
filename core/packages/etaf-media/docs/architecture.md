# etaf-media Architecture

`etaf-media` isolates native video playback, multimedia subprocesses, and platform C/Objective-C dynamic modules (`libmpv` GPU overlays and canvas readers) out of the core `etaf` runtime package so non-media applications stay pure Emacs Lisp.

## Module Layers

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `lisp/etaf-video-source.el` | Source normalization, `ffprobe` metadata probing, and frame scaling filters | — |
| `lisp/etaf-video-audio.el` | Optional `ffplay` audio sidecar lifecycle and volume/seek sync | `etaf-video-source` |
| `lisp/etaf-video-mpv.el` | Dynamic module loader (`native/etaf-video-mpv.*`) and cross-platform `libmpv` session controller | `etaf-video-source` |
| `lisp/etaf-video-session.el` | Unified playback state machine coordinating `libmpv` or `ffmpeg` producers, audio sidecar and display timers | `etaf-video-source`, `etaf-video-audio`, `etaf-video-mpv` |
| `lisp/etaf-video-component.el` | `etaf-video` Component, handle registry, Kitty/GPU/canvas/image/ASCII presentation, and ETAF hook registration | `etaf`, `ebox`, `etaf-video-session`, `etaf-video-mpv`, `etaf-video-audio`, `etaf-video-source` |

## Integration Boundaries

- **Upward hooks into `etaf`**: `etaf-video-component.el` registers `etaf-video--sync-all-gpu-instances` on `etaf-overlay-sync-functions` so fullscreen and PiP viewport transitions resynchronize hardware GPU layers without `etaf` knowing about video internals.
- **Decoupled UI driver**: `etaf-video-component.el` publishes its control functions and component symbol in `etaf-video-driver`, allowing `etaf-ui` (`etaf-media-viewer`) to play video whenever `etaf-media` is loaded while keeping `etaf-ui` free of any hard dependency on `etaf-media`.
- **Native artifacts**: `native/manifest.json` declares checksummed prebuilt `etaf-video-mpv` dynamic modules (and Windows `libmpv-2.dll`) consumed by `etaf-install`.
