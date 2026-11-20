# Installation, Loading and Building

This chapter lists what the packages need from Emacs and from the system, how to load them from source checkouts and through package.el, how to compile them, how to build their native parts, and what happens when an optional program or library is missing.

## Requirements

<!-- index: requirements; Emacs version; SQLite support -->

| Package | Emacs | Optional programs and libraries |
| --- | --- | --- |
| `ecss` | 28.1 | — |
| `ekp` | 29.1 | For the C module: dynamic module support in Emacs, `make`, and a C11 compiler with POSIX threads |
| `ebox` | 29.1 | For images in terminal frames: `chafa` or `ffmpeg`. For color emoji on macOS: `swiftc` |
| `etaf` | 29.1 | For video: `ffmpeg`, `ffprobe` and `ffplay` |
| `etaf-ui` | 29.1 | For the font icon sets: their icon fonts |
| `etaf-db` | 29.1, built with SQLite support | — |

A package also needs the Emacs version of every package it requires, so every package above ECSS needs Emacs 29.1. EKP uses `string-pixel-width` and `object-intervals`, which Emacs 29.1 introduced. etaf-db needs an Emacs in which `sqlite-available-p` returns non-nil.

Batch Emacs loads every package, mounts Views and computes layout; the packages' own tests run that way.

### Graphical and terminal frames

<!-- index: graphical frame; terminal frame -->

The packages run in graphical and in terminal frames. A terminal frame paints some parts differently:

| Part | Graphical frame | Terminal frame |
| --- | --- | --- |
| Box backgrounds | `:border-radius` rounds the corners | Square corners; a background fills whole lines |
| Borders | 1 px hairlines and rounded corners | One-cell box rules; a blank border row becomes `┌──┐` / `└──┘` |
| Type sizes | `:font-size` scales the glyphs | One face size; a raised size renders bold |
| Images | Displayed by Emacs | Converted to character cells by `chafa`, else by `ffmpeg`, else replaced by a placeholder |
| Video in `image` mode | Each frame is displayed as an image | Falls back to `ascii` mode |
| Icons | SVG sets are displayed as images, and font sets are drawn as SVG text, so tall glyphs are not clipped | The registered `tty` set supplies one-cell Unicode marks; other sets use their text variants |

In both kinds of frame, every line of the buffer keeps its standard height, and the text of the buffer is never replaced. On a graphical frame, a character cluster that would make its line taller, such as a color emoji, is painted over with a line-high image when Ebox can render one (see [The Ebox emoji renderer](#the-ebox-emoji-renderer)), and is otherwise scaled down with a `height` display property until it fits. Batch Emacs and terminal frames leave clusters as they are.

### Fonts

<!-- index: fonts; icon fonts -->

Ebox measures text in the fonts that the frame uses, so ordinary text needs no particular font, and proportional and CJK fonts align. The icons of the component catalog need fonts only for the font icon sets:

| Icon set | Font families |
| --- | --- |
| `nerd` | DroidSansMono Nerd Font or DejaVuSansMono Nerd Font |
| `fa` | FontAwesome |
| `material` | Material Icons |
| `octicons` | github-octicons |
| `sys`, `svg` | None |

`nerd` is the initial value of `etaf-ui-icon-default-set`. When the font or the glyph of an icon is missing, `etaf-ui-icon` looks the icon up in the default set, then in `sys`, then in `svg`, and shows its name as plain text when no set has it. `etaf-ui-icon-metrics` reports nil for the pixel height and the fit of a set whose font is missing.

## Loading from source checkouts

<!-- index: source checkout; load-path; require -->

Add the root of each repository to `load-path` and require the entry feature of the package you use. Requiring a package loads the packages it requires, so their roots must be in `load-path` as well:

| To require | Add the roots of |
| --- | --- |
| `ecss` | `ecss` |
| `ekp` | `ekp` |
| `ebox` | `ecss`, `ebox` |
| `etaf` | `ecss`, `ebox`, `etaf` |
| `etaf-ui` | `ecss`, `ebox`, `etaf`, `etaf-ui` |
| `etaf-db` | `ecss`, `ebox`, `etaf`, `etaf-db` |

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ui")
(require 'etaf-ui)
```

Add only the roots. Each entry file adds its own `lisp/` directory when it loads, and the features in that directory are internal (see [Public interfaces](ecosystem-and-layers.md#public-interfaces)). Keep the layout of each repository intact: EKP reads its hyphenation dictionaries from `dictionaries/` and its C module from `native/`, and Ebox reads the source of its emoji renderer from `native/`.

Unless `load-prefer-newer` is non-nil, Emacs loads a byte-compiled file even when its source is newer, and only prints a message about it. After updating a checkout that contains compiled files, compile it again, or set `load-prefer-newer` before loading the packages.

## Installing with package.el

<!-- index: package.el; autoload; package archive -->

Each entry file has the `Version` and `Package-Requires` headers that package.el reads. A package archive of a package contains its entry file and its `lisp/` directory; an archive of EKP also needs `dictionaries/` and `native/`.

Function and Macro records may carry an autoload cookie:

```elisp
;; Function: ekp-c-module-load ()
;;;###autoload (autoload 'ekp-c-module-load "ekp" nil t)
```

When package.el installs a package, it collects these cookies into the package's autoload file. Public commands such as `ekp-c-module-build` are then available through `M-x` at once. A public function or macro that carries no cookie becomes available only after the package is loaded; `require` the package before calling it. Records of the other kinds have no autoloads, so require the package before using them. A source checkout has no autoload file; require its entry instead.

## Compiling

<!-- index: byte compilation; native compilation; load-prefer-newer -->

Compile the packages before using them for real work: interpreted code is much slower. EKP, for example, runs about ten times faster byte-compiled than interpreted. package.el byte-compiles a package when it installs it. In a source checkout:

- `make compile` byte-compiles the package.
- `make native`, in the Ebox and ETAF repositories, byte-compiles the package and then compiles it to native code in the `eln-cache`. Emacs loads that code in place of the bytecode without further configuration, even when just-in-time native compilation is disabled. A source file edited later runs as bytecode until the next `make native`.
- `make clean` removes the compiled files.

#### Function: ebox-byte-compile ()

Recompile every Ebox Lisp source into a neighboring `.elc` file.

**Semantics.** The function byte-compiles the Ebox entry and its `lisp/ebox-*.el` modules beside their sources, in the checkout it was loaded from, and writes the compiler's output to `*Ebox Byte Compile*`. It is what `make compile` in the Ebox repository runs. Every source is attempted even when one fails; the failures are collected and reported together with the failing file names. Restart Emacs after a successful build so the running session loads the new bytecode; a source edited later runs as bytecode only after the next compile.

**Returns.** Unspecified; the compilation is the effect.

**Errors.** `error→ error` "Ebox byte compilation failed: FILE, …" naming every file that failed to compile.

## Native components

### The EKP C module

<!-- index: EKP C module; dynamic module -->

EKP can compute line breaks in a C dynamic module, which runs the optimization in C and lays out several paragraphs in parallel on a pool of threads. The module is optional: without it, EKP computes line breaks in Emacs Lisp.

Building the module needs an Emacs with dynamic module support, in which `module-file-suffix` is non-nil, together with `make` and a C11 compiler with POSIX threads. There are two ways to build it:

- `M-x ekp-c-module-build` runs `make` in the `native/` directory asynchronously and loads the module when the build succeeds. It reads a build profile; the default is `portable`.
- `make native-build` in the EKP repository builds the `portable` profile. Load the result with `ekp-c-module-load`.

| Profile | Compiler options |
| --- | --- |
| `portable` | `-O3`, without instructions specific to the building machine |
| `native` | `-O3 -march=native -flto`, tuned to the building machine |
| `debug` | `-O0 -g3`, for use in a debugger |
| `sanitize` | `-O1 -g3` with the address and undefined behavior sanitizers |

The module is a file in the `native/` directory, named `ekp` with the suffix `.dylib` on macOS, `.dll` on Windows and `.so` elsewhere. Requiring EKP does not load it. `ekp-c-module-load` loads it and reports the result in the echo area:

- When the file does not exist, it reports that the module was not found, and EKP keeps using Emacs Lisp.
- When the module is older than the version that this EKP requires, it reports that the module is too old, and EKP keeps using Emacs Lisp. Build the module again.
- Otherwise it enables the module and reports its version and its number of threads.

`ekp-c-module-load` loads a copy of the file, so a module that was rebuilt during the session can be loaded with the same command.

Two variables decide when a loaded module is used. `ekp-use-c-module`, non-nil by default, lets EKP use the module; nil forces Emacs Lisp. `ekp-auto-justify-native-append` applies only to text appended while automatic justification is active; when the module is unavailable, that path falls back to Emacs Lisp.

`ekp-c-module-build` signals `user-error` for an unknown profile, when the `native/` directory has no Makefile, and when no `make` program is found. When the build fails, it reports the exit status and displays the buffer with the output of the build.

### The Ebox emoji renderer

<!-- index: emoji; color emoji -->

Color emoji often have glyphs taller than a line of text. On macOS, Ebox renders such emoji itself, as square images exactly one line high, so that lines keep their height. It does so when the frame is graphical with the `ns` window system, Emacs supports PNG images, the `swiftc` compiler is found, and the source of the renderer is present in the Ebox repository. The first time it needs an image, Ebox compiles a small helper program into the `ebox-emoji/` directory of `user-emacs-directory`, and it keeps the images that the helper renders in the same directory as PNG files. When the source of the helper has changed, Ebox removes the old helper and images and builds a new helper. When the helper is unavailable the first time Ebox needs it, Ebox does not try again in the same session. The helper is a program, not a dynamic module, and needs no build step of its own.

When the renderer is unavailable, Ebox scales a tall cluster down instead, as described in [Graphical and terminal frames](#graphical-and-terminal-frames).

## Missing optional dependencies

<!-- index: optional dependency; chafa; ffmpeg; ffprobe; ffplay -->

| Missing | Effect | To restore |
| --- | --- | --- |
| The EKP C module, or dynamic module support | EKP computes line breaks in Emacs Lisp | Build and load the module |
| `chafa` and `ffmpeg`, for a terminal frame | Ebox shows a placeholder in place of each image | Install either program |
| `swiftc`, or a system other than macOS | Ebox scales tall emoji down instead of rendering them as images | — |
| `ffmpeg` | Starting playback of a video signals `user-error` with the message `ffmpeg is not available: PROGRAM`, before any process starts | Install ffmpeg, or set `etaf-video-ffmpeg-program` to its name or absolute file name |
| `ffprobe` | `etaf-video-source-info` returns its documented default metadata | Install ffprobe, or set `etaf-video-ffprobe-program` |
| `ffplay` | Videos play without sound; no error is signaled | Install ffplay, or set `etaf-video-ffplay-program` |
| SQLite support in Emacs | Each etaf-db operation that connects to a database signals `etaf-sqlite-unavailable`; declaring tables and databases still works | Use an Emacs built with SQLite support |
| An icon font | `etaf-ui-icon` takes icons of that set from the fallback sets | Install the font |

EKP is optional as a whole: no other package uses it, so only programs that require EKP themselves need it.
