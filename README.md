# Emacs TAF Monorepo

[中文](README.zh-CN.md)

[![Repository structure](https://github.com/emacs-taf/emacs-taf/actions/workflows/structure.yml/badge.svg)](https://github.com/emacs-taf/emacs-taf/actions/workflows/structure.yml)
[![Package installation](https://github.com/emacs-taf/emacs-taf/actions/workflows/package-installation.yml/badge.svg)](https://github.com/emacs-taf/emacs-taf/actions/workflows/package-installation.yml)

[Website & Manual](https://etaf.top) · [Package Archive](https://etaf.top/packages/) · [Native Modules](https://etaf.top/native/) · [Media Library](https://etaf.top/media/) · [License](LICENSE)

**Emacs TAF (ETAF)** is a declarative text application framework for Emacs with CSS-style selectors and cascade, box/flex/grid layout, reactive components and incremental buffer rendering.

This repository (`https://github.com/emacs-taf/emacs-taf`) is the **official Emacs TAF monorepo** and canonical home for development, pull requests and CI across the ecosystem. Packages are organized into three layers: `core/packages/` (15 framework, extension, installer and reference-manual packages, projected together to [emacs-taf/etaf](https://github.com/emacs-taf/etaf)), `apps/` (16 applications) and `games/` (2 games), where published products project individually to `https://github.com/emacs-taf/<package>`.

![ETAF applications in Emacs](https://etaf.top/media/site/shots/etaf-ncm.webp)

*ETAF applications running inside native Emacs buffers — see more captures on [etaf.top](https://etaf.top) and the [media library](https://etaf.top/media/).*

## Install in an existing Emacs

Requires **Emacs 29.1 or newer**. No Git, Python, C compiler or replacement Emacs configuration is needed. Evaluate once, then choose a target (the `etaf-ui` component gallery is the default):

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

Key entry points and guarantees:

- **`M-x etaf-install`**: Install any supported framework package, extension, application or game from `https://etaf.top/packages/`; already-installed targets reopen offline.
- **Declarative `use-package` & `etaf-install-ensure`**: Add `("etaf" . "https://etaf.top/packages/")` to `package-archives`, call `(etaf-install-ensure '(etaf-md etaf-org ...))` for offline-fast automatic installation plus prebuilt native modules, and configure packages lazily with `(use-package etaf-md :ensure t :pin etaf ...)`. See [etaf-install](core/packages/etaf-install).
- **`M-x etaf-install-manage`**: Native tabulated-list manager for installed/available versions, runtime readiness, manual `System CLI` prerequisites and Lisp dependencies (`i` install, `n` native modules, `u` update, `U` update all, `d` remove, `RET` open, `?` doctor, `g` refresh, `l` list-packages, `q` quit).
- **Automatic prebuilt native modules**: Installing or updating a target automatically downloads, SHA-256 verifies and activates declared prebuilt dynamic modules (such as `etaf-md`'s QuickJS Mermaid/MathJax renderer, `etaf`'s `libmpv` bridge and `ekp`'s C line-breaking engine) into `~/.cache/emacs-taf/native/`. Set `etaf-install-auto-native` to `nil` to opt out, or use `M-x etaf-install-native` (`n` in the manager).
- **Capability diagnostics (`M-x etaf-install-doctor`)**: Reports required and optional capabilities offline without writing config. Missing required external OS CLIs open `*ETAF Installation*` with one combined copyable command for your package manager (`c` copy, `r` re-check, `o` open). External service accounts and OS binaries are detected, never auto-installed (for `etaf-telega`, install TDLib and run `M-x telega-server-build` so `telega-server` is on `exec-path`).
- **Standard `package.el` lifecycle**: `package.el` owns dependency resolution, local byte compilation, upgrades and removal (`M-x list-packages` remains available). Removal preserves application data, logins and caches; failed installs roll back only newly added packages; restart Emacs after upgrading loaded Lisp, and do not mix source checkouts with installed packages of the same dependency.

See the full [installation reference](https://etaf.top/introduction/#installation) for details.

## Packages in this Monorepo

Every package below lives under `core/packages/`, `apps/` or `games/` and is registered in [workspace.json](workspace.json).

### Core Framework (`core/packages/` → [emacs-taf/etaf](https://github.com/emacs-taf/etaf))

| Package | Responsibility | Monorepo dependencies |
| --- | --- | --- |
| [ecss](core/packages/ecss) | Selector and cascade semantics | None |
| [ekp](core/packages/ekp) | Knuth–Plass paragraph layout | None |
| [ebox](core/packages/ebox) | Box layout, rendering and incremental publication | ecss; optional ekp |
| [etaf](core/packages/etaf) | Components, state and application runtime | ebox |
| [etaf-ui](core/packages/etaf-ui) | Reusable UI components and theme tokens | etaf |
| [etaf-gamekit](core/packages/etaf-gamekit) | Game definitions, independent instances, actions and backend adapters | etaf |
| [etaf-posframe](core/packages/etaf-posframe) | Floating child-frame panels for any ETAF View | etaf |
| [etaf-ext](core/packages/etaf-ext) | Universal extension engine, lifecycle manager and host hooks for ETAF apps | etaf, etaf-ui, etaf-posframe |
| [etaf-db](core/packages/etaf-db) | Database backends for ETAF; currently SQLite | etaf |
| [etaf-install](core/packages/etaf-install) | Official `package.el` installer, capability doctor, native module downloader and package manager | None |
| [etaf-manual](core/packages/etaf-manual) | Bilingual ETAF Reference Manual for the core packages, checked against public interfaces and published at <https://etaf.top> | etaf, etaf-ui; gate also reads ecss, ekp, ebox, etaf-db |

### Extensions (`core/packages/` → [emacs-taf/etaf](https://github.com/emacs-taf/etaf))

Built on [etaf-ext](core/packages/etaf-ext) to attach cross-cutting capabilities to any ETAF buffer or application:

| Extension | Responsibility | Framework dependencies |
| --- | --- | --- |
| [etaf-hints](core/packages/etaf-hints) | Quick keyboard jump hints for interactive targets | etaf-ext, etaf, etaf-ui, ebox |
| [etaf-highlight](core/packages/etaf-highlight) | Text highlighting and anchored notes across ETAF views | etaf-ext, etaf, etaf-ui, ebox |
| [etaf-translate](core/packages/etaf-translate) | Immersive inline and side-by-side translation for ETAF views | etaf-ext, etaf, etaf-ui, etaf-db, ebox |
| [etaf-export](core/packages/etaf-export) | Vector SVG and PDF export for ETAF rendered pages | etaf-ext, etaf, etaf-ui, ebox |

### Applications (`apps/`)

| Application | Responsibility | Framework dependencies |
| --- | --- | --- |
| [etaf-desktop](https://github.com/emacs-taf/etaf-desktop) | Desktop window-management application built from ETAF and ETAF UI | etaf, etaf-ui, ebox |
| [etaf-ncm](https://github.com/emacs-taf/etaf-ncm) | NetEase Cloud Music player: library browsing, playback control, lyrics and queue | etaf, etaf-ui, ebox |
| [etaf-weread](https://github.com/emacs-taf/etaf-weread) | WeChat Reading client: shelf, notebook, highlights, store search and statistics | etaf, etaf-ui, etaf-db, ebox |
| [etaf-md](https://github.com/emacs-taf/etaf-md) | Native Markdown renderer and live previewer: centered measure, full-grid tables, 35+ `:::` containers, zero-browser QuickJS Mermaid/MathJax SVGs and lockstep split preview | etaf, etaf-ui, ebox |
| [etaf-org](https://github.com/emacs-taf/etaf-org) | Org reading view and living documents: native Org syntax, extensible node engine, live widgets, Mermaid/KaTeX diagrams, outline side window and O(Δ) live split preview | etaf, etaf-ui, ebox |
| [etaf-rss](https://github.com/emacs-taf/etaf-rss) | RSS reader: subscriptions, folders, unread/starred scopes, reading pane, search and OPML (local JSON or Miniflux) | etaf, etaf-ui, ebox |
| [maillist](https://github.com/emacs-taf/maillist) | Mailing-list client: public-inbox thread list, unread/star marks, fixed-header reader and smtpmail replies | etaf, etaf-ui, etaf-db, ebox |
| [etaf-reader](https://github.com/emacs-taf/etaf-reader) | Local ebook reader: EPUB/TXT/Markdown/HTML/FB2/PDF import, paged reading, annotations and progress | etaf, etaf-ui, etaf-db, ebox |
| [etaf-pomodoro](https://github.com/emacs-taf/etaf-pomodoro) | Focus timer as an application or floating panel: reactive countdown, three styles and host-following palette | etaf, etaf-ui, ebox |
| [etaf-telega](https://github.com/emacs-taf/etaf-telega) | Telegram client on Telega's TDLib backend: chats, live message stream, composer and message actions | etaf, etaf-ui, ebox |
| [etaf-video-player](https://github.com/emacs-taf/etaf-video-player) | Local video and streams as image frames, density characters or true-color half blocks, with sound | etaf, etaf-ui, ebox |
| [etaf-bili](https://github.com/emacs-taf/etaf-bili) | Bilibili client: popular feed, ranking and search with in-buffer playback | etaf, etaf-ui, ebox |
| [etaf-youtube](https://github.com/emacs-taf/etaf-youtube) | YouTube client: account feeds, search, channels, playlists and in-canvas video playback | etaf, etaf-ui, etaf-db, ebox |
| [etaf-screensaver](https://github.com/emacs-taf/etaf-screensaver) | Idle screensavers: canvas-only animation, input dismissal, grouped playback and recorded animations | etaf, ebox |
| [etaf-web](apps/etaf-web) | Web article reader: compiles HTML to `etaf-md` intermediate language with local caching | etaf-md, etaf, etaf-ui, ebox |
| [etaf-agenda](https://github.com/emacs-taf/etaf-agenda) | Personal agenda: daily log, year/month/week calendar, tasks, projects, habits and monthly review on SQLite | etaf, etaf-ui, etaf-db, ebox |

> **Archive status:** `etaf-agenda`, `etaf-reader`, `etaf-rss`, `etaf-screensaver` and `etaf-web` pass their checks in this monorepo but are not published to the ELPA archive yet (`M-x etaf-install` does not list them).

### Games (`games/`)

Both games build on [etaf-gamekit](core/packages/etaf-gamekit) and keep their rules, presentation and assets in their own package directories:

| Game | Description | Backend |
| --- | --- | --- |
| [etaf-tanks](https://github.com/emacs-taf/etaf-tanks) | Iron Tide: real-time tank battle with a native arena | Godot |
| [etaf-xiangqi](https://github.com/emacs-taf/etaf-xiangqi) | Chu He: xiangqi (Chinese chess) against the computer or hot-seat | OpenSpiel |

For gamekit development tests, install the required engine backend or run `make -C core/packages/etaf-gamekit engine-all GAMEKIT_PYTHON=python3.11` before `make -C core/packages/etaf-gamekit check`.

## Outside this Monorepo

These companion repositories build on the ETAF framework through published packages and maintain their own independent histories.

| Repository | Responsibility |
| --- | --- |
| [etaf-pi](https://github.com/emacs-taf/etaf-pi) | Native Pi agent client: streamed conversations, tool output, session recovery and multiline input |
| [etaf-video-studio](https://github.com/emacs-taf/etaf-video-studio) | Record, edit and publish software tutorials with non-destructive timelines and background export |
| [etaf-browser](https://github.com/emacs-taf/etaf-browser) | Browser client with an address and status shell rendered on the ETAF canvas |
| [etaf-algo-lab](https://github.com/emacs-taf/etaf-algo-lab) | Learn algorithms by watching, steering and comparing them inside Emacs |
| [etaf-slides](https://github.com/emacs-taf/etaf-slides) | Present a Markdown deck as aspect-preserving 16:9 slides with speaker notes, overview and timer |
| [etaf-solitaire](https://github.com/emacs-taf/etaf-solitaire) | Verdant: K+ Klondike solitaire with undo and redo |
| [etaf-salvage](https://github.com/emacs-taf/etaf-salvage) | Salvage Station: real-time exploration and extraction |
| [etaf-mario](https://github.com/emacs-taf/etaf-mario) | Super Mario: four-stage text platformer built from character sprites, with items and enemies |

## Monorepo Layout & Read-Only Projections

```text
emacs-taf/
├── core/                     # Core projection (→ emacs-taf/etaf): README + packages/<15 core/ext/manual pkgs>
├── apps/                     # 16 end-user applications (published apps project individually → emacs-taf/<app>)
├── games/                    # 2 games (project individually → emacs-taf/<game>)
├── scripts/                  # Shared build, structure/API checks, refscope, release and media publishing tools
├── docs/                     # Monorepo tool manual, ecosystem architecture and keyboard navigation contracts
├── tests/tools/              # Unit and regression tests for shared monorepo tooling and installer flows
├── workspace.json            # Package registry, paths, roles and projection targets (schema 3)
├── release-dependencies.json # Official ELPA archive package selection and runtime resources
└── Makefile                  # Dependency-ordered monorepo orchestration targets
```

- **Single source of truth for PRs**: Changes spanning a framework provider and its consuming applications land together in one atomic commit and PR in `emacs-taf/emacs-taf`.
- **Layered read-only projections**:
  - `core/` projects automatically to **[emacs-taf/etaf](https://github.com/emacs-taf/etaf)** as a unified 15-package core framework repository (framework, extensions, installer and reference manual).
  - Each published application/game under `apps/` and `games/` projects automatically to its own standalone repository (`https://github.com/emacs-taf/<package>`) for independent discovery and browsing; PRs are disabled on projection mirrors.
- **Source-manager installs (`straight.el` / `elpaca`)**: Prefer the official ELPA archive (`https://etaf.top/packages/`), or install directly from this monorepo using `:files ("core/packages/<pkg>/*")` / `:files ("apps/<app>/*")`.

## Development & Contributing

External contributors need only standard **Git**, **Python 3.10+** and **Emacs 29.1+**:

```sh
git clone https://github.com/emacs-taf/emacs-taf.git
cd emacs-taf
make setup-hooks              # configure local Git pre-commit / commit-msg hooks
```

Common commands:

| Command | Purpose |
| --- | --- |
| `make structure-check` | Validate repository layout, `workspace.json` alignment, media policy and cross-package public API boundaries |
| `make -C core/packages/<pkg> check` | Run structure check, byte compilation, public acceptance tests and API check for a core package |
| `make -C apps/<app> check` | Run checks for an application (or `make -C games/<game> check` for a game) |
| `make plan-affected` | Preview which packages are affected by the current change (via `scripts/refscope.py`) |
| `make check-affected JOBS=4` | Compile and test only affected units in dependency order |
| `make order` | Print parallelizable dependency layers across all packages |
| `make check` | Full monorepo validation in dependency order (used before releases) |
| `make perf-list` / `make perf-check` | List or run registered performance scenarios (see [docs/manual.md](docs/manual.md)) |
| `python3 scripts/media-publish.py publish --item <pkg>:/path/shot.png` | Compress and upload showcase screenshots/videos to `https://etaf.top/media/` (never commit showcase media to Git) |

Contribution conventions:

- Keep each package's root entry (`<pkg>.el`) Commentary as the authoritative public API list; consumers never require another package's internal `lisp/` modules.
- Format commits using [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) (title ≤ 72 chars plus a `Validation:` line) and verify with `python3 scripts/check-commit-message.py <msg-file>`.
- Do not commit showcase images or videos to Git (only compact ≤ 100 KB offline test inputs belong in `tests/fixtures/`); host showcase assets on `https://etaf.top/media/`.
- Maintainer workflows (automated projections via `.github/workflows/project.yml`, archive releases and performance verification) are documented in [docs/manual.md](docs/manual.md).

## Documentation

- **ETAF Reference Manual**: <https://etaf.top> ([English](https://etaf.top/introduction/) · [简体中文](https://etaf.top/zh-cn/introduction/))
- **Monorepo Tooling & Release Manual**: [docs/manual.md](docs/manual.md) · [docs/manual.zh-CN.md](docs/manual.zh-CN.md)
- **Ecosystem Architecture & Development Contract**: [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md)
- **Keyboard Navigation Contract**: [docs/keyboard-navigation.zh-CN.md](docs/keyboard-navigation.zh-CN.md)
- **Changelog**: [CHANGELOG.md](CHANGELOG.md)

## License

Licensed under the GNU General Public License v3.0 or later. See [LICENSE](LICENSE) for details.
