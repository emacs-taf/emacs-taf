# Emacs TAF workspace

[中文](README.zh-CN.md)

This repository owns the shared development policy and local orchestration for
nine independent Emacs Lisp repositories. Each package retains its own Git history,
public interfaces, releases and behavior checks.

| Repository | Responsibility | Dependencies in this workspace |
| --- | --- | --- |
| ecss | Selector and cascade semantics | None |
| tp | Text properties, retained surfaces and transactions | None |
| ekp | Knuth–Plass paragraph layout | None |
| ebox | Box layout, rendering and incremental publication | ecss, tp; optional ekp |
| etaf | Components, state and application runtime | ebox, tp |
| etaf-ui | Reusable UI components | etaf |
| etaf-db | SQLite adapter; the Lisp package is `etaf-sqlite` | etaf |
| ebox-playground | Runnable Ebox layout examples | ebox |
| etaf-playground | Application integration examples | etaf, etaf-ui, etaf-db |

## Setup

Clone the repositories from `workspace.json` into sibling directories with exactly
these names. The recorded revisions identify the child commits verified together by
`make check`; they are an integration checkpoint, not a release certification.
Commits must be pushed before this checkpoint is available from the remote URLs. `python3 scripts/workspace.py status` reports
revision differences without changing checkouts. Package READMEs specify installation
requirements; native builds are explicit package targets.

Run `make setup-hooks` after cloning to enable the staged structure and commit-message gates in every
checkout. Python 3.10+ and Git are required for policy checks; package checks also
require an appropriate Emacs executable (`make check EMACS=/path/to/emacs`).

## Development

- `make structure-check`: validate every package and detect shared-policy drift.
- `make check`: run policy regression tests and public package acceptance checks in dependency order.
- `make compile`, `make test`, `make clean`: delegate to package-owned entry points.
- `make sync-policy`: distribute the canonical policy, checker, hook and CI workflow.

Read [AGENTS.md](AGENTS.md) for the complete development contract. Update shared files
here and run `make sync-policy`; do not customize individual copies. Packages expose one root entry with the supported API in its Commentary.
Checkout users add repository roots to `load-path`; multi-file implementations
live in `lisp/`. Small single-file packages may keep implementation in the entry. Tests, examples, benchmarks, tools and native sources live in
`tests/`, `examples/`, `benchmarks/`, `scripts/` and `native/` respectively.
Organize by responsibility: correctness tests and their helpers go in `tests/`,
including development-tool tests in `tests/tools/` and data in `tests/fixtures/`.
`tests/acceptance.json` inventories every maintained Lisp test. Tests use only
public package APIs; private implementation tests are deleted. Dedicated measurement harnesses
and workloads belong in `benchmarks/`; general runners and release tools belong in
`scripts/`. Language and file extension do not determine these boundaries.
Create directories only when needed; native subprojects retain ecosystem conventions.

## Documentation

Keep a short README. The root entry Commentary owns the supported API inventory,
calling signatures and usage notes. Put integration workflows and examples in
`docs/manual.md`, current internal ownership in `docs/architecture.md`, and notable
version changes in `CHANGELOG.md`. The latter three are created only when needed.
Translations consistently use `.zh-CN.md`. Do not duplicate the same contract in
several files; callers link to the provider's manual. Preserve legal notices.

This is a project convention informed by [Diátaxis](https://diataxis.fr/),
[README guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
and [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), not a universal filename standard.

## Git workflow

Commit each validated, complete modification promptly; keep related code, tests and
contract documentation together. Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
with a concrete title, explanatory body and `Validation:` results. Logical commit
boundaries follow the [Git workflow guidance](https://git-scm.com/docs/gitworkflows).
The 72-character title limit and validation field are project requirements.
See [AGENTS.md](AGENTS.md) for granularity, breaking changes and history rules.

Automatically push each coherent group of validated commits to the current branch's
configured upstream after fetching and checking divergence. This is the user-approved
default; no repeated confirmation is needed. If no upstream exists or delivery fails,
keep the local commits and report the blocker.
Never force-push or publish to all remotes implicitly. Hooks validate structure and
message format; authors remain responsible for meaning, scope and actual verification.

## Enforcement

The pre-commit hook checks the exact Git index. The checked-in CI workflow runs the
same structure check on pushes and pull requests. Local hooks can be bypassed;
remote administrators must enable Actions and make the structure job a required
merge check. This workspace does not configure remote permissions or branch rules.
The checker catches mechanical drift; interface design and documentation accuracy
still require behavioral tests and review.
