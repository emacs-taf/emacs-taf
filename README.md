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
these names. The recorded revisions are the source baseline for the organization
migration, not a certified release lock. `python3 scripts/workspace.py status` reports
revision differences without changing checkouts. Package READMEs specify installation
requirements; native builds are explicit package targets.

Run `make setup-hooks` after cloning to enable the staged structure gate in every
checkout. Python 3.10+ and Git are required for policy checks; package checks also
require an appropriate Emacs executable (`make check EMACS=/path/to/emacs`).

## Development

- `make structure-check`: validate every package and detect shared-policy drift.
- `make check`: run policy regression tests and public package acceptance checks in dependency order.
- `make compile`, `make test`, `make clean`: delegate to package-owned entry points.
- `make sync-policy`: distribute the canonical policy, checker, hook and CI workflow.

Read [AGENTS.md](AGENTS.md) for the complete development contract. Update shared files
here and run `make sync-policy`; do not customize individual copies. Runtime source
stays at package roots. Tests, examples, benchmarks, tools and native sources live in
`tests/`, `examples/`, `benchmarks/`, `scripts/` and `native/` respectively.
`tests/` holds plugin ERT Lisp and fixture data; Python/Shell runners live in
`scripts/`, their tests in `scripts/tests/`, and acceptance selection in
`scripts/acceptance.json`. `benchmarks/` holds Lisp performance workloads only.

## Documentation

Keep a short README. Put complete usage and public integration contracts in
`docs/manual.md`, current internal ownership in `docs/architecture.md`, and notable
version changes in `CHANGELOG.md`. The latter three are created only when needed.
Translations consistently use `.zh-CN.md`. Do not duplicate the same contract in
several files; callers link to the provider's manual. Preserve legal notices.

This is a project convention informed by [Diátaxis](https://diataxis.fr/),
[README guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
and [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), not a universal filename standard.

## Enforcement

The pre-commit hook checks the exact Git index. The checked-in CI workflow runs the
same structure check on pushes and pull requests. Local hooks can be bypassed;
remote administrators must enable Actions and make the structure job a required
merge check. This workspace does not configure remote permissions or branch rules.
The checker catches mechanical drift; interface design and documentation accuracy
still require behavioral tests and review.
