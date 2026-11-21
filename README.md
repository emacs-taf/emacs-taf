# Emacs TAF workspace

[中文](README.zh-CN.md)

This repository owns the shared development policy and orchestration for the
Emacs TAF ecosystem: its framework packages, applications and games. Every
package is a directory under `packages/` in one Jujutsu checkout, registered in
`workspace.json`; each still publishes as its own repository with its own
version, public interfaces, releases and behavior checks.

## Development

Every package lives in one Jujutsu checkout under `packages/`, so a change can
span a provider and the applications that use it. Publishing projects one
package out of that checkout: each repository keeps its ordinary single-package
history and installs through package.el as before.

```sh
make check                # the whole checkout in dependency order, before a release
make plan-affected        # preview which units the current change reaches
make check-affected       # compile/test only affected units (supports JOBS=4)
make order                # show parallelizable dependency layers
make -C packages/etaf-ui check
```

The published repositories each carry a `pre-mono` tag naming the history they
had before the checkout was unified; a clone older than that has to be replaced
rather than pulled.

## Install in an existing Emacs

Use Emacs 29.1 or newer. Evaluate this once, then choose a target (the component
gallery is the default):

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

Afterward, use `M-x etaf-install`; installed targets reopen offline. Use
`M-x etaf-install-manage` to see installed and available versions, update,
remove or open targets, and read the doctor; one window holds the table and the
mode line names the keys (`i` install, `u` update, `U` update all, `d` remove,
`RET` open, `?` doctor, `g` refresh, `l` list-packages, `q` quit). `M-x list-packages` remains the
advanced package menu. Package.el owns dependency installation, local byte
compilation, updates and removal. No Git, Python, system compiler, Pi or
replacement Emacs configuration is required.

The installer groups its targets: framework (`etaf-install`, the `etaf-ui`
gallery, `etaf`, `ebox`, `ecss`, `ekp`, `etaf-db`, `etaf-gamekit`,
`etaf-posframe`), applications (`etaf-manual`, `etaf-md`,
`etaf-org-preview`, `etaf-video-player`, `etaf-desktop`, `etaf-telega`,
`etaf-weread`, `etaf-ncm`, `etaf-pomodoro`, `maillist`) and games
(`etaf-xiangqi`, `etaf-tanks`). Each entry reports what is missing before
opening. SQLite needs an Emacs build with SQLite support;
`M-x etaf-install-doctor` reports required and optional capabilities without
installing anything. External service accounts and media programs are detected,
not installed; an application's own backend ships in its package.  For Telega
the installer installs the Emacs `telega` package but not the native
`telega-server`: install TDLib, run `M-x telega-server-build` (or follow the
Telega installation guide), and put `telega-server` on `exec-path`.  The
install message, `M-x etaf-install-doctor` and the `?` key in
`M-x etaf-install-manage` print this remedy.

Use `M-x etaf-install-manage` for the supported targets and `M-x list-packages`
for advanced or third-party packages; restart Emacs after updates. Removal keeps
application data, logins and caches; shared dependencies stay installed.
A failed installation removes only its newly added packages, reports cleanup
failures and preserves previous installations; restart before retrying because
partially loaded Lisp cannot be rolled back. Do not mix source checkouts and
package installations of the same dependency. See the
[installation reference](https://etaf.top/introduction/#installation).
The checkout instructions below are for development.

## Repositories

Framework packages and workspace tooling developed in this checkout:

| Repository | Responsibility | Dependencies in this workspace |
| --- | --- | --- |
| [ecss](https://github.com/emacs-taf/ecss) | Selector and cascade semantics | None |
| [ekp](https://github.com/emacs-taf/ekp) | Knuth–Plass paragraph layout | None |
| [ebox](https://github.com/emacs-taf/ebox) | Box layout, rendering and incremental publication | ecss; optional ekp |
| [etaf](https://github.com/emacs-taf/etaf) | Components, state and application runtime | ebox |
| [etaf-ui](https://github.com/emacs-taf/etaf-ui) | Reusable UI components | etaf |
| [etaf-gamekit](https://github.com/emacs-taf/etaf-gamekit) | Game definitions, independent instances, actions and backend adapters | etaf |
| [etaf-posframe](https://github.com/emacs-taf/etaf-posframe) | Floating child-frame panels for any ETAF View | etaf |
| [etaf-db](https://github.com/emacs-taf/etaf-db) | Database backends for ETAF; currently SQLite | etaf |
| [etaf-manual](https://github.com/emacs-taf/etaf-manual) | The ETAF Reference Manual for the core packages, in English and Chinese, checked against their public interfaces; published at <https://etaf.top> | etaf, etaf-ui; its gate reads ecss, ekp, ebox and etaf-db |

[etaf-gamekit](https://github.com/emacs-taf/etaf-gamekit) provides game
definitions and a common action/observation lifecycle over Godot, boardgame.io
and OpenSpiel. Game applications own their rules and presentation and live
beside the framework packages, outside the framework core; the core does not
depend on their components.
Install the backend needed by your game, or use
`make -C packages/etaf-gamekit engine-all GAMEKIT_PYTHON=python3.11` before running the
complete `make -C packages/etaf-gamekit check`. Its README and manual describe standalone
game projects and adapter integration.

## Applications

Applications and games are two kinds of programs built on the framework; each lives
under `packages/` in this checkout and publishes as its own independent repository.

### Applications

Every application is a package directory under `packages/` registered in `workspace.json`; the
table names the framework packages each one uses:

| Application | Responsibility | Framework dependencies |
| --- | --- | --- |
| [etaf-desktop](https://github.com/emacs-taf/etaf-desktop) | Desktop window-management application built from ETAF and ETAF UI | etaf, etaf-ui, ebox |
| [etaf-ncm](https://github.com/emacs-taf/etaf-ncm) | NetEase Cloud Music player: library browsing, playback control, lyrics and queue | etaf, etaf-ui, ebox |
| [etaf-weread](https://github.com/emacs-taf/etaf-weread) | WeChat Reading client: shelf, notebook, highlights, store search and statistics | etaf, etaf-ui, etaf-db, ebox |
| [etaf-md](https://github.com/emacs-taf/etaf-md) | Markdown reading view: centered measure, headings, tables, callouts, code and media cards | etaf, etaf-ui, ebox |
| [etaf-org-preview](https://github.com/emacs-taf/etaf-org-preview) | Org reading view: structural folding, headline keywords and planning, lists, tables, code, callouts, footnotes and a table of contents | etaf, etaf-ui, ebox |
| [etaf-rss](https://github.com/emacs-taf/etaf-rss) | RSS reader: subscriptions, folders, unread and starred scopes, reading pane, search and OPML, over a local JSON store or a Miniflux server | etaf, etaf-ui, ebox |
| [maillist](https://github.com/emacs-taf/maillist) | Mailing-list client: public-inbox thread list with unread and starred scopes, a fixed-header reader, local read/star state and replies through smtpmail | etaf, etaf-ui, etaf-db, ebox |
| [etaf-reader](https://github.com/emacs-taf/etaf-reader) | Local ebook reader: EPUB/TXT/Markdown/HTML/FB2/PDF import, paged reading, annotations and progress | etaf, etaf-ui, etaf-db, ebox |
| [etaf-pomodoro](https://github.com/emacs-taf/etaf-pomodoro) | Focus timer as an application and as a floating panel: reactive countdown, three styles and a host-following palette | etaf, etaf-ui, ebox |
| [etaf-telega](https://github.com/emacs-taf/etaf-telega) | Telegram client on Telega's TDLib backend: chats, live message stream, composer and message actions | etaf, etaf-ui, ebox |
| [etaf-video-player](https://github.com/emacs-taf/etaf-video-player) | Local video and streams as image frames, density characters or true-color half blocks, with sound | etaf, etaf-ui, ebox |
| [etaf-bili](https://github.com/emacs-taf/etaf-bili) | Bilibili client: popular feed, ranking and search with in-buffer playback | etaf, etaf-ui, ebox |
| [etaf-screensaver](https://github.com/emacs-taf/etaf-screensaver) | Idle screensavers: canvas-only animation, input dismissal, grouped playback and adapted recorded animations | etaf, ebox |

`etaf-bili`, `etaf-reader`, `etaf-rss` and `etaf-screensaver` live and pass
their checks in this checkout but are not in the package archive yet;
`M-x etaf-install` does not list them.

### Games

Game applications live under `packages/` too. Both build on
[etaf-gamekit](https://github.com/emacs-taf/etaf-gamekit) for game definitions,
independent instances, actions and backend adapters, and keep their rules,
presentation and resources in their own package directories.

| Game | Description | Backend |
| --- | --- | --- |
| [etaf-tanks](https://github.com/emacs-taf/etaf-tanks) | Iron Tide: real-time tank battle with a native arena | Godot |
| [etaf-xiangqi](https://github.com/emacs-taf/etaf-xiangqi) | Chu He: xiangqi (Chinese chess) against the computer or hot-seat | OpenSpiel |

## Outside this checkout

These repositories build on the framework but are not part of this checkout. They keep their own history and checks and consume the framework through its published packages. One can join later with `python3 scripts/add-package.py`.

| Repository | Responsibility |
| --- | --- |
| [ebox-playground](https://github.com/emacs-taf/ebox-playground) | Runnable Ebox layout examples |
| [etaf-playground](https://github.com/emacs-taf/etaf-playground) | ETAF/UI integration examples and acceptance surfaces |
| [etaf-pi](https://github.com/emacs-taf/etaf-pi) | Native Pi agent client: streamed conversations, tool output, session recovery and multiline input |
| [etaf-video-studio](https://github.com/emacs-taf/etaf-video-studio) | Record, edit and publish software tutorials through the video-project skill: recording, non-destructive edits, background previews/exports and a two-step publish flow |
| [etaf-youtube](https://github.com/emacs-taf/etaf-youtube) | YouTube client: account feeds, search, channels, playlists and in-canvas video playback |
| [etaf-browser](https://github.com/emacs-taf/etaf-browser) | Browser client with an address and status shell in the ETAF canvas |
| [etaf-algo-lab](https://github.com/emacs-taf/etaf-algo-lab) | Learn algorithms by watching, steering and comparing them inside Emacs |
| [etaf-slides](https://github.com/emacs-taf/etaf-slides) | Present a markdown deck as slides: an aspect-preserving 16:9 stage, speaker notes, a slide overview and a presentation clock |
| [etaf-solitaire](https://github.com/emacs-taf/etaf-solitaire) | Verdant: K+ Klondike solitaire with undo and redo |
| [etaf-salvage](https://github.com/emacs-taf/etaf-salvage) | Salvage Station: real-time exploration and extraction |
| [etaf-mario](https://github.com/emacs-taf/etaf-mario) | Super Mario: four-stage text platformer built from character sprites, with items and enemies |

## Setup

All packages listed in `workspace.json` live under `packages/` in this single
`jjosh` checkout; do not clone separate sibling repositories or nest `.git`/`.jj`
directories inside `packages/`. Package READMEs specify optional runtime
requirements; native builds are explicit package targets.

Python 3.10+ and `jjosh` are required for policy and change-graph tooling; package
checks also require an appropriate Emacs executable (`make check EMACS=/path/to/emacs`).
Run `make setup-hooks` to configure hooks in a Git checkout or print the equivalent
manual gates for a `jjosh` checkout.

Protect pushed history in this checkout:

```sh
jjosh config set --repo 'revset-aliases."immutable_heads()"' \
  'builtin_immutable_heads() | remote_bookmarks()'
```

## Workspace commands

Read the [accepted ecosystem architecture and development contract](docs/architecture.zh-CN.md)
before cross-package work. It records package ownership, shared style and interaction
semantics, ETAF Component/API usability, asynchronous resources and error recovery,
implementation gaps, migration order and observable acceptance criteria.
Its target behavior is explicitly distinguished from the current implementation.

- `make structure-check`: validate the root, every package under `packages/`, `workspace.json` registry alignment and cross-package public API boundaries.
- `make check`: run structure/API gates, compile in dependency order, run policy regression tests and run public package acceptance checks.
- `make plan-affected` / `make check-affected [JOBS=4]`: compute symbol-level impact for the current change (`@`) via `scripts/refscope.py` and re-check only affected units in dependency order (optionally parallel per layer).
- `make order`: print the parallelizable dependency layers of all packages.
- `make perf-list`: list registered performance scenarios.
- `make perf-check PERF_ARGS='--mode gui --scenario gallery.selection.mouse --diagnose'`:
  measure the existing native Emacs, then collect separate phase, CPU and memory
  diagnostics. `--baseline /path/result.json` compares a previous run. See the
  [performance workflow and scenario interface](docs/manual.md).
- `make verify-baseline`: save a batch correctness/performance baseline with logs and raw samples.
- `make verify BASELINE=/path/result.json`: run the same batch checks and compare p95/max
  with the baseline through `scripts/performance.py`; increases over 2 ms fail independently
  of each registered scenario's absolute budget. The wrapper compiles the workspace, measures
  the registered Playground workloads, and runs `make check` even after a performance failure.
  One set of 5 warmups and 30 samples is a screen, reported as `screened`.
  `make verify-repeatability BASELINE=/path/result.json` compares three independent sets
  against a three-set baseline recorded with `scripts/verify.py --record-baseline --repeatability`.
  Ordinary `make verify` adopts the baseline's sample grouping.
  Each run prints a compact summary and an evidence directory outside Git. Actual GUI
  rendering/input and installation checks remain separate acceptance requirements.
- `make compile`, `make test`, `make clean`: delegate to package-owned entry points in dependency order.
- `python3 scripts/add-package.py`: register a new package under `packages/` and `workspace.json`.
- `python3 scripts/publish-packages.py [--dry-run] [--package NAME]`: project and push packages from the shared tree to their independent remotes.

Packages expose one root entry with the supported API in its Commentary.
Checkout users add repository roots to `load-path`; multi-file implementations
live in `lisp/`. Small single-file packages may keep implementation in the entry. Tests, examples, benchmarks, tools and native sources live in
`tests/`, `examples/`, `benchmarks/`, `scripts/` and `native/` respectively.
Organize by responsibility: correctness tests and their helpers go in `tests/`,
including development-tool tests in `tests/tools/` and data in `tests/fixtures/`.
`tests/acceptance.json` inventories every maintained Lisp test. Tests exercise only
public package APIs. Dedicated measurement harnesses
and workloads belong in `benchmarks/`; general runners and release tools belong in
`scripts/`. Language and file extension do not determine these boundaries.
Create directories only when needed; native subprojects retain ecosystem conventions.

## Documentation

Keep a short README. The root entry Commentary owns the supported API inventory,
calling signatures and usage notes. Put integration workflows and examples in
`docs/manual.md`, current internal ownership in `docs/architecture.md`, and notable
version changes in `CHANGELOG.md`. The latter three are created only when needed.
The workspace architecture document also owns accepted cross-package target behavior
and migration boundaries. The dedicated [keyboard navigation contract](docs/keyboard-navigation.zh-CN.md)
owns regions, editing states and key binding rules; other documents link to it.
Maintain these contracts in place instead of adding separate plans.
Translations consistently use `.zh-CN.md`. Do not duplicate the same contract in
several files; callers link to the provider's manual. Preserve legal notices.

This is a project convention informed by [Diátaxis](https://diataxis.fr/),
[README guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
and [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), not a universal filename standard.

## Version control workflow

Commit each validated, complete modification promptly; keep related code, tests and
contract documentation together. Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
with a concrete title, explanatory body and `Validation:` results. Logical commit
boundaries follow the [Git workflow guidance](https://git-scm.com/docs/gitworkflows).
The 72-character title limit and validation field are project requirements.
Make local writes with `jjosh` (never mix plain `jj` on a `jjosh` checkout). `jjosh`
does not run Git hooks, so check each message with
`python3 scripts/check-commit-message.py <file>` and the sealed tree with
`make structure-check` before pushing.

Every package publishes by projection to its own remotes (`origin` at
`github.com/emacs-taf` plus any maintainer mirrors recorded in AGENTS.md) using
`python3 scripts/publish-packages.py`. Run `jjosh git export` before building
release archives. The checkout itself, including the installer and the shared
tooling that no package carries, is pushed to its private repository-wide
`aliyun` remote after each delivery. Do not force-push or implicitly publish other branches or tags.
Report each delivery result.
Hooks validate structure and message format; authors remain responsible for
scope, accurate descriptions and validation.

## Enforcement

The pre-commit hook checks the exact Git index; jj commits bypass it, so run the
same check before pushing. The checked-in CI workflow runs the
same structure check on pushes and pull requests. Local hooks can be bypassed;
remote administrators must enable Actions and make the structure job a required
merge check. Remote permissions and branch protection are managed on each hosting service.
The checker catches mechanical drift; interface design and documentation accuracy
still require behavioral tests and review.
