# Emacs TAF workspace

[中文](README.zh-CN.md)

This repository owns the shared development policy and local orchestration for
the Emacs TAF ecosystem: its framework packages, applications and games. Every
repository is an independent checkout beside this one, registered in
`workspace.json`; each retains its own Git history, public interfaces, releases
and behavior checks.

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
remove or open targets, and read the doctor; `M-x list-packages` remains the
advanced package menu. Package.el owns dependency installation, local byte
compilation, updates and removal. No Git, Python, system compiler, Pi or
replacement Emacs configuration is required.

The installer groups its targets: framework (`etaf-ui` gallery, `etaf`,
`etaf-db`, `ekp`), applications (`etaf-md-preview`, `etaf-video-player`,
`etaf-desktop`, `etaf-manual`, `etaf-telega`, `etaf-weread`, `etaf-ncm`) and
games (`etaf-xiangqi`, `etaf-tanks`). Each entry reports what is missing before
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
| [etaf-db](https://github.com/emacs-taf/etaf-db) | Database backends for ETAF; currently SQLite | etaf |
| [ebox-playground](https://github.com/emacs-taf/ebox-playground) | Runnable Ebox layout examples | ebox |
| [etaf-playground](https://github.com/emacs-taf/etaf-playground) | ETAF/UI integration examples and acceptance surfaces | etaf, etaf-ui, etaf-db, etaf-desktop |
| [etaf-manual](https://github.com/emacs-taf/etaf-manual) | The ETAF Reference Manual for the core packages, in English and Chinese, checked against their public interfaces; published at <https://etaf.top> | etaf, etaf-ui; its gate reads ecss, ekp, ebox and etaf-db |

[etaf-gamekit](https://github.com/emacs-taf/etaf-gamekit) provides game
definitions and a common action/observation lifecycle over Godot, boardgame.io
and OpenSpiel. Game applications own their rules and presentation and live
beside the framework packages, outside the framework core; the core does not
depend on their components.
Install the backend needed by your game, or use
`make -C etaf-gamekit engine-all GAMEKIT_PYTHON=python3.11` before running the
complete `make -C etaf-gamekit check`. Its README and manual describe standalone
game projects and adapter integration.

## Applications

Applications and games are two kinds of programs built on the framework; each is
an independent repository with its own history and checks.

### Applications

Every application is a sibling checkout registered in `workspace.json`; the
table names the framework repositories each one uses:

| Application | Responsibility | Framework dependencies |
| --- | --- | --- |
| [etaf-desktop](https://github.com/emacs-taf/etaf-desktop) | Desktop window-management application built from ETAF and ETAF UI | etaf, etaf-ui, ebox |
| [etaf-ncm](https://github.com/emacs-taf/etaf-ncm) | NetEase Cloud Music player: library browsing, playback control, lyrics and queue | etaf, etaf-ui, ebox |
| [etaf-weread](https://github.com/emacs-taf/etaf-weread) | WeChat Reading client: shelf, notebook, highlights, store search and statistics | etaf, etaf-ui, etaf-db, ebox |
| [etaf-md-preview](https://github.com/emacs-taf/etaf-md-preview) | Markdown reading view: centered measure, headings, tables, callouts, code and media cards | etaf, etaf-ui, ebox |
| [etaf-rss](https://github.com/emacs-taf/etaf-rss) | RSS reader: subscriptions, folders, unread and starred scopes, reading pane, search and OPML | etaf, etaf-ui, ebox |
| [etaf-reader](https://github.com/emacs-taf/etaf-reader) | Local ebook reader: EPUB/TXT/Markdown/HTML/FB2/PDF import, paged reading, annotations and progress | etaf, etaf-ui, etaf-db, ebox |
| [etaf-pi](https://github.com/emacs-taf/etaf-pi) | Native Pi agent client: streamed conversations, tool output, session recovery and multiline input | etaf, etaf-ui, ebox |
| [etaf-telega](https://github.com/emacs-taf/etaf-telega) | Telegram client on Telega's TDLib backend: chats, live message stream, composer and message actions | etaf, etaf-ui, ebox |
| [etaf-ascii-video](https://github.com/emacs-taf/etaf-ascii-video) | Video and HTTP(S) streams inside an Emacs buffer as pure characters | etaf, etaf-ui, ebox |
| [etaf-video-player](https://github.com/emacs-taf/etaf-video-player) | Local video and streams as sharp image frames with sound | etaf, etaf-ui, ebox |
| [etaf-video-studio](https://github.com/emacs-taf/etaf-video-studio) | Record, edit and publish software tutorials through the video-project skill: recording, non-destructive edits, background previews/exports and a two-step publish flow | etaf, etaf-ui, ebox |
| [etaf-bili](https://github.com/emacs-taf/etaf-bili) | Bilibili client: popular feed, ranking and search with in-buffer playback | etaf, etaf-ui, ebox |
| [etaf-youtube](https://github.com/emacs-taf/etaf-youtube) | YouTube client: account feeds, search, channels, playlists and in-canvas video playback | etaf, etaf-ui, etaf-db, ebox |
| [etaf-miniflux](https://github.com/emacs-taf/etaf-miniflux) | Miniflux client for a self-hosted feed server | etaf, etaf-ui, ebox |
| [etaf-browser](https://github.com/emacs-taf/etaf-browser) | Browser client with an address and status shell in the ETAF canvas | etaf, etaf-ui |
| [etaf-algo-lab](https://github.com/emacs-taf/etaf-algo-lab) | Learn algorithms by watching, steering and comparing them inside Emacs | etaf, etaf-ui, ebox |
| [etaf-screensaver](https://github.com/emacs-taf/etaf-screensaver) | Idle screensavers: canvas-only animation, input dismissal, grouped playback and adapted recorded animations | etaf, ebox |

### Games

Game applications are sibling checkouts too. They build on
[etaf-gamekit](https://github.com/emacs-taf/etaf-gamekit) for game definitions,
independent instances, actions and backend adapters, and keep their rules,
presentation and resources in their own repositories:

| Game | Description | Backend |
| --- | --- | --- |
| [etaf-solitaire](https://github.com/emacs-taf/etaf-solitaire) | Verdant: K+ Klondike solitaire with undo and redo | OpenSpiel |
| [etaf-salvage](https://github.com/emacs-taf/etaf-salvage) | Salvage Station: real-time exploration and extraction | Godot |
| [etaf-tanks](https://github.com/emacs-taf/etaf-tanks) | Iron Tide: real-time tank battle with a native arena | Godot |
| [etaf-xiangqi](https://github.com/emacs-taf/etaf-xiangqi) | Chu He: xiangqi (Chinese chess) against the computer or hot-seat | OpenSpiel |

## Setup

Clone the repositories listed in `workspace.json` into sibling directories with
exactly these names. Each record's `url` is its GitHub origin: clone with
`git clone -o origin <url> <name>`.
The recorded revisions identify the child commits verified together by
`make check`; they are an integration checkpoint, not a release certification.
Commits must be pushed before this checkpoint is available from the remote URLs. `python3 scripts/workspace.py status` reports
revision differences without changing checkouts. Package READMEs specify installation
requirements; native builds are explicit package targets.

Run `make setup-hooks` after cloning to enable the staged structure and commit-message gates in every
checkout. Python 3.10+ and Git are required for policy checks; package checks also
require an appropriate Emacs executable (`make check EMACS=/path/to/emacs`).

Local history is managed with [Jujutsu](https://docs.jj-vcs.dev/latest/) on top of Git.
In this root and every clone, run `jj git init --colocate`, then protect pushed
history:

```sh
jj config set --repo 'revset-aliases."immutable_heads()"' \
  'builtin_immutable_heads() | remote_bookmarks()'
```

## Development

Read the [accepted ecosystem architecture and development contract](docs/architecture.zh-CN.md)
before cross-package work. It records package ownership, shared style and interaction
semantics, ETAF Component/API usability, asynchronous resources and error recovery,
implementation gaps, migration order and observable acceptance criteria.
Its target behavior is explicitly distinguished from the current implementation.

- `make structure-check`: validate every package and detect shared-tooling drift.
- `make check`: run policy regression tests and public package acceptance checks in dependency order.
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
- `make compile`, `make test`, `make clean`: delegate to package-owned entry points.
- `make sync-policy`: distribute shared checkers, hooks, formatting and CI configuration maintained here.
  After committing them in the root, `python3 scripts/workspace.py seal-sync [--dry-run]` commits only those
  copies in each repository and lists other unpublished commits that publishing it would include.

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
Make local writes with jj and use Git read-only. jj does not run Git hooks, so
check each message with `python3 scripts/check-commit-message.py <file>` and the
sealed change with `python3 scripts/check-repository.py --staged` before pushing.

Every module publishes to `origin` at `github.com/emacs-taf`. After a coherent
group of validated commits, fetch and inspect `origin`, then push the branch
recorded in `workspace.json` to its same-named branch with
`jj git push --remote origin -b <branch>`. The delivery rules, including the
maintainers' additional remotes, live in AGENTS.md. Do not force-push or
implicitly publish other branches or tags. Report each delivery result. The root
workspace uses the same remote as the modules.
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
