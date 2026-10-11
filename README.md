# Emacs TAF workspace

[中文](README.zh-CN.md)

This repository owns the shared development policy and local orchestration for
the Emacs TAF ecosystem: its framework packages, the etaf-apps application
workspace and the applications built on them. Each repository retains its own Git
history, public interfaces, releases and behavior checks.

## Repositories

Framework packages and workspace tooling developed in this checkout:

| Repository | Responsibility | Dependencies in this workspace |
| --- | --- | --- |
| [ecss](https://forgejo.vhkd.top/emacs-taf/ecss) | Selector and cascade semantics | None |
| [ekp](https://forgejo.vhkd.top/emacs-taf/ekp) | Knuth–Plass paragraph layout | None |
| [ebox](https://forgejo.vhkd.top/emacs-taf/ebox) | Box layout, rendering and incremental publication | ecss; optional ekp |
| [etaf](https://forgejo.vhkd.top/emacs-taf/etaf) | Components, state and application runtime | ebox |
| [etaf-ui](https://forgejo.vhkd.top/emacs-taf/etaf-ui) | Reusable UI components | etaf |
| `etaf-gamekit` (local checkout) | Game definitions, independent instances, actions and backend adapters | etaf; examples optionally use etaf-ui |
| [etaf-db](https://forgejo.vhkd.top/emacs-taf/etaf-db) | Database backends for ETAF; currently SQLite | etaf |
| [etaf-apps](https://forgejo.vhkd.top/emacs-taf/etaf-apps) | Application workspace: their integration checkpoints and shared tooling | etaf, etaf-ui, etaf-db |
| [ebox-playground](https://forgejo.vhkd.top/emacs-taf/ebox-playground) | Runnable Ebox layout examples | ebox |
| [etaf-playground](https://forgejo.vhkd.top/emacs-taf/etaf-playground) | ETAF/UI integration examples and acceptance surfaces | etaf, etaf-ui, etaf-db, etaf-desktop |
| [etaf-manual](https://forgejo.vhkd.top/emacs-taf/etaf-manual) | The ETAF Reference Manual for the core packages, in English and Chinese, checked against their public interfaces | etaf, etaf-ui; its gate reads ecss, ekp, ebox and etaf-db |

`etaf-gamekit` has no configured remote and is not yet part of the published
revision inventory. Its independent local checkout provides game definitions
and a common action/observation lifecycle over Godot, boardgame.io and OpenSpiel.
Game applications own their rules and presentation; Salvage Station lives under
`etaf-gamekit/examples/salvage/`, outside the framework core.
Install the backend needed by your game, or use
`make -C etaf-gamekit engine-all GAMEKIT_PYTHON=python3.11` before running the
complete `make -C etaf-gamekit check`. Its README and manual describe standalone
game projects and adapter integration.

## Applications

Every application is an independent repository with its own history and checks.
[etaf-desktop](https://forgejo.vhkd.top/emacs-taf/etaf-desktop) is developed in this
workspace; the others live in the [etaf-apps](https://forgejo.vhkd.top/emacs-taf/etaf-apps)
workspace, whose README owns their dependency lists:

| Application | Responsibility |
| --- | --- |
| [etaf-desktop](https://forgejo.vhkd.top/emacs-taf/etaf-desktop) | Desktop window-management application built from ETAF and ETAF UI |
| [etaf-ncm](https://forgejo.vhkd.top/emacs-taf/etaf-ncm) | NetEase Cloud Music player: library browsing, playback control, lyrics and queue |
| [etaf-weread](https://forgejo.vhkd.top/emacs-taf/etaf-weread) | WeChat Reading client: shelf, notebook, highlights, store search and statistics |
| [etaf-md-preview](https://forgejo.vhkd.top/emacs-taf/etaf-md-preview) | Markdown reading view: centered measure, headings, tables, callouts, code and media cards |
| [etaf-rss](https://forgejo.vhkd.top/emacs-taf/etaf-rss) | RSS reader: subscriptions, folders, unread and starred scopes, reading pane, search and OPML |
| [etaf-reader](https://forgejo.vhkd.top/emacs-taf/etaf-reader) | Local ebook reader: EPUB/TXT/Markdown/HTML/FB2/PDF import, paged reading, annotations and progress |
| [etaf-pi](https://forgejo.vhkd.top/emacs-taf/etaf-pi) | Native Pi agent client: streamed conversations, tool output, session recovery and multiline input |
| [etaf-telega](https://forgejo.vhkd.top/emacs-taf/etaf-telega) | Telegram client on Telega's TDLib backend: chats, live message stream, composer and message actions |
| [etaf-ascii-video](https://forgejo.vhkd.top/emacs-taf/etaf-ascii-video) | Video and HTTP(S) streams inside an Emacs buffer as pure characters |
| [etaf-video-player](https://forgejo.vhkd.top/emacs-taf/etaf-video-player) | Local video and streams as sharp image frames with sound |
| [etaf-algo-lab](https://forgejo.vhkd.top/emacs-taf/etaf-algo-lab) | Learn algorithms by watching, steering and comparing them inside Emacs |

## Setup

Clone the repositories from `workspace.json` into sibling directories with exactly
these names. Clone with `git clone -o laycat <url> <name>` and add the matching
`aliyun` URL at `https://forgejo.vhkd.top/emacs-taf/<name>.git`.
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
- `make perf-check PERF_ARGS='--mode gui --scenario gallery.review.mouse --diagnose'`:
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

Every module uses `laycat` at `gitea.gklazycat.heiyu.space` and `aliyun` at
`forgejo.vhkd.top`. After a coherent group of validated commits, fetch and inspect
`aliyun`, then push the branch recorded in `workspace.json` to its same-named
branch there with `jj git push --remote aliyun -b <branch>`.
Automatic delivery requires aliyun; laycat remains configured for manual
maintenance and delivery. Do not force-push or implicitly publish other branches
or tags. Report aliyun's delivery result. Reserve `origin` for future GitHub use;
it is currently unconfigured. The root workspace uses the same `aliyun` and
`laycat` remotes as the modules.
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
