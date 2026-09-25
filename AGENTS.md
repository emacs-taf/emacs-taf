# Workspace development instructions

Start development from this directory. These instructions govern work across the
independent repositories listed in `workspace.json`.

## Locate the task

- Use [README.md](README.md) for the repository map and workspace commands. Each
  child has its own Git history; inspect and commit changes in the owning repository.
  The root repository tracks orchestration, documentation and integration revisions.
- Before editing a package, discover and read any AGENTS.md on the path from its
  root to the target files, then its README and the relevant contract sections.
- Maintain common instructions here. Add a local AGENTS.md only when its scope
  needs special development commands, critical reminders or document navigation.
- For architecture or cross-package changes, read the applicable parts of
  [the ecosystem contract](docs/architecture.zh-CN.md) and the affected providers'
  public contracts. Select documents by the task and the responsible packages;
  distinguish required targets from implemented behavior.

## Structure

- Each package has one root entry named after its provided package feature.
  Keep package metadata, public API Commentary and implementation loading there.
  Multi-file implementations live in lisp/;
  do not duplicate the entry, add forwarding wrappers or preserve obsolete paths.
  Small single-file packages may implement their behavior in the root entry.
- Checkout users add repository roots to load-path and require the package entry.
  Consumers must not require a provider's internal module. Keep entry loading,
  byte compilation, autoloads, resource paths and installation recipes aligned.
- Organize by responsibility, not file extension. Use `tests/` for correctness
  scenarios and their helpers, `tests/fixtures/` for data, and `tests/tools/`
  for development-tool tests. Keep the acceptance inventory at `tests/acceptance.json`.
- Use `benchmarks/` for performance workloads, dedicated measurement harnesses and
  input data; use `scripts/` for build, release, environment and general runners.
  Tests and benchmarks may use Lisp, Python, Shell or appropriate data formats.
- Use `examples/` for runnable usage examples and `native/` for native implementations.
  Native subprojects follow their language's own layout. Keep domain resources in
  descriptive directories such as `dictionaries/`; do not create generic dumping grounds.
- Share directory meanings and command interfaces across repositories. Create only
  the directories a repository needs; do not impose identical empty skeletons.
- Create directories only when they contain maintained files. Use lowercase kebab-case
  directory names. Preserve upstream resource names and license notices.
- Follow `.editorconfig` for whitespace and encoding; preserve upstream resources.
- Keep generated files, caches, local reports and recordings out of version control.
- Do not add compatibility paths, obsolete implementation plans, audit reports,
  milestone inventories, historical placeholder documents or per-task notes.
  Git history holds removed material. Delete obsolete code and its callers together.

## Documentation

Maintain this documentation policy only in the workspace root AGENTS.md. Apply it
to every repository changed from this workspace.

| Location | Reader and purpose | Include | Exclude |
| --- | --- | --- | --- |
| Root `AGENTS.md` | Development agents working across the workspace | Task navigation, common engineering rules, document selection, validation and Git delivery instructions | Product tutorials, full API contracts, detailed architecture, task transcripts and progress reports |
| Local `AGENTS.md`, when needed | Agents changing that specific scope | Special commands, critical local reminders and links to the relevant contracts | Copies of root rules, unrelated package requirements and full design documents |
| `README.md` | People evaluating, installing or starting to use the project | Purpose, capabilities, prerequisites, installation, a minimal working example, documentation links and brief contribution/check commands; the workspace README describes orchestration | Agent setup, AGENTS.md discovery or maintenance, agent workflow instructions, task reports, detailed design and exhaustive API references |
| Root entry `.el` Commentary | Package consumers looking up supported APIs | The authoritative API inventory, signatures, purpose, inputs/results, usage and lifecycle/error constraints | Duplicate implementations, private APIs and refactoring plans |
| `docs/manual.md` | Users integrating the package or completing a task | Supported workflows, configuration, composition, runnable examples, lifecycle, failures and recovery | Agent operation, implementation walkthroughs, speculative APIs and a second full API inventory |
| Package `docs/architecture.md` | Maintainers understanding the implemented system | Responsibilities, dependency direction, data flow, invariants and the rationale for current design | Agent operation, task chronology, abandoned designs and unimplemented proposals |
| Workspace `docs/architecture.zh-CN.md` | Maintainers coordinating ecosystem development | Cross-package responsibilities, accepted target contracts, relevant implementation gaps, dependency order and observable acceptance criteria | Conversation history, agent operation, unaccepted ideas and claims that pending capabilities already work |
| `CHANGELOG.md` | Users deciding how to upgrade | Notable user-visible changes and necessary migration instructions, organized by release or Unreleased following Keep a Changelog | Copied commit logs, internal work reports, fabricated releases and routine edits without user impact |

- Before writing, identify the reader's task and the owning document above. Update
  its relevant section; if the content does not serve that purpose, relocate or
  omit it rather than appending a new explanation. Check the final diff against
  these boundaries before committing.
- Write standalone descriptions of the maintained behavior or accepted requirement.
  Readers must not need the conversation, previous edits or abandoned approaches to
  understand the text. Keep durable design rationale where it explains a current
  decision; record user-relevant version transitions in CHANGELOG. Task narration
  belongs in the conversation and change history.
- Maintain each detailed contract in one authoritative location and link to it
  from other documents. Create optional documents only for maintained content;
  reuse existing sections and remove stale or redundant material.
- English uses the default name; Chinese translations use `.zh-CN.md` consistently.
  Keep existing translations aligned when their contract changes. Do not create empty
  translations or documents merely to fill a template. Legal notices are exempt.
- The root entry's Commentary is the authoritative supported API inventory. Use
  `;; Function: name (arguments)`, `Macro`, `Variable`, `Hook`, `Error` or `Component`,
  followed by purpose, inputs/results and usage guidance. Document meaningful error
  and lifecycle constraints; keep signatures and behavior aligned with docstrings.
  A symbol with separate function and error-condition bindings has one record for
  each; duplicate records within the same binding namespace are invalid.
  Group related interfaces for reading. Do not maintain a second API variable/list
  or repeat implementations in the entry. README and manuals link to this inventory.
  Attach autoload declarations to Function/Macro records so package.el exposes the
  same root entry without requiring users to configure internal directories.
- Consumers require the provider's root feature and use only declared interfaces.
  An unlisted symbol is internal even without `--`. Do not bypass this boundary
  through dynamic symbol lookup, loading a private library or redefining its symbols.
- Every package with integration APIs documents supported callers, inputs/outputs,
  ownership, lifecycle, failure semantics and a runnable example in its manual.
  Keep private implementation symbols out of consumer code.

## Development and validation

- Apply design requirements to their responsible packages and affected integrations.
  A package's requirements do not automatically apply to its dependencies.
- Preserve each package's documented responsibility, independent use and dependency
  direction. Keep shared capabilities in their owning provider; do not duplicate
  authoritative state or algorithms in consumers. Migrate affected callers with
  interface changes and remove the superseded route once migration is complete.
- A move or deletion must update all code, Makefiles, tests and documentation references
  in the same change. Use stable behavior-based names, not development-phase labels.
- Put behavioral regressions in tests. Do not require documents to enumerate every
  source file or retired command. Test public examples and integration contracts.
- Keep only public API behavior tests: observable inputs, outputs, errors,
  rollback and lifecycle through interfaces declared by the package entry.
  Delete tests of private helpers, internal structures, source text, implementation
  call counts and retired versions. Do not repair or preserve those tests.
  Test fixtures and helper functions must also use public package interfaces;
  indirection, reflection and fault injection do not grant private access.
  Do not promote an internal symbol to public API merely to retain its tests.
- `tests/acceptance.json` inventories every maintained Lisp correctness scenario,
  with an observable purpose. `make test` runs this public suite; `make check`
  adds structure/API boundary validation, compilation and fresh entry binding
  and source signature validation. Do not retain a separate internal-test suite.
  Delete native internal unit-test modules too; validate native behavior through
  supported package APIs. Preserve upstream vendor sources.
  Development tools may test their supported command/input/output contracts.
  GUI appearance and performance use their separate acceptance targets.
- From this directory, use `make -C <package> structure-check` and affected tests
  while developing; run `make -C <package> check` before completing a package change.
  Workspace changes run `python3 scripts/workspace.py check`; integrated changes
  run workspace `make check`, including affected consumers in dependency order.
- Validate each complete feature change through the affected examples' data flow,
  visible rendering, behavior and interaction latency before continuing to another
  feature. Provider unit scenarios alone do not establish application acceptance.
  Interface or recommended-authoring changes migrate UI components, all maintained
  consuming examples, manuals and tests in the same coherent delivery.
- Establish a performance baseline before editing and compare after each coherent
  change. Use `make verify-baseline` once, then `make verify BASELINE=/path/result.json`
  for repeatable batch correctness, latency samples and regression comparison.
  Keep raw evidence outside Git; inspect the compact result before opening specific
  failure logs. A failed, missing or incomparable gate remains unverified, including
  pre-existing failures. Do not postpone performance work until ecosystem completion.
  These batch commands do not certify actual GUI rendering or input latency; run
  and inspect the affected examples through their maintained GUI workflow too.
  Use three independent sample sets for the final performance claim.
- The user authorizes launching Emacs from the command line for GUI validation
  without repeated approval. The user's init starts the server automatically.
  Prefer a usable existing server; when a fresh process is needed, start it
  yourself and verify its PID, graphical frame and loaded code. Do not ask the
  user to launch Emacs or start its server. Preserve unrelated Emacs instances
  and application focus; this authorization does not permit closing their work.
- Use `scripts/performance.py` for repeatable interaction latency and diagnosis;
  select maintained scenarios with `perf-list` and add new adapters to the owning
  package's `benchmarks/performance-scenarios.el`. Reuse its separate latency,
  trace, CPU and allocation passes, baseline comparison and saved evidence rather
  than writing temporary measurement scripts. See `docs/manual.md` for the tool
  contract. Invalid, incomplete, stale-code or incomparable runs remain unverified.
- Use existing performance evidence until a concrete uncertainty requires another
  measurement. Stop diagnosis once the dominant cost is actionable and fix it.
  After a change, screen only affected representative scenarios; reserve full
  three-set matrices for final acceptance. Do not repeat unchanged button suites
  or collect more samples merely to show activity. Background diagnosis and
  window-scoped capture do not require foreground focus; request it only for an
  explicitly selected foreground input-latency gate.
- Each package exposes `compile`, `test`, `check`, `clean`, `structure-check`, and
  `setup-hooks`. `check` includes the structural gate. Serialize commands that clean
  and rebuild shared dependencies; parallel builds must not race over sibling outputs.
- Run `make setup-hooks` after cloning. The pre-commit gate checks staged contents,
  not merely the working tree. jj does not run git hooks, so run the affected checks
  yourself before publishing a jj change (see `Local version control (jj)`). CI runs the same structural and API checker plus
  `make api-check` in batch Emacs, fetching
  missing provider checkouts. Local checks use sibling sources; CI uses provider
  default branches. `workspace.json` records the tested combination of revisions.
  The boundary gate covers runtime, runnable examples and Lisp tests/helpers.
  Tests may not reference internal APIs of either their own package or a provider.
  Static checks cover direct references; code review must also reject dynamically
  constructed private calls. These checks do not constitute Lisp access control.
- Never weaken a check, add an exclusion or skip a test just to make a failure green.
  Update obsolete checks to the current contract and retain behavioral coverage.
- If a new document or directory does not fit this policy, first simplify the design.
  Maintain shared checkers, hooks and configuration in the workspace and distribute
  them with `python3 scripts/workspace.py sync`. Changes to mechanically enforced
  rules update the checker and its tool regressions together.

## Git history and delivery

- Commit promptly after a coherent change has been validated, before starting an
  unrelated change and before ending a completed task. A commit is one explainable,
  independently reviewable and revertible change, not one function or a fixed count
  of files/lines. Keep its code, regression coverage and documentation together.
  Split unrelated fixes, formatting, moves and features; keep necessary path/caller
  updates together so each commit remains usable for `git bisect`.
- Inspect `git status`, the diff and staged diff before committing. Stage only the
  current change; never include another person's unfinished work or generated files.
  Run affected checks and `make check` before committing a completed package change.
  Report failures honestly; do not create a passing-looking checkpoint by hiding them.
- Use Conventional Commits: `type(scope): concrete imperative English summary`.
  Scope is optional; types are feat, fix, docs, refactor, perf, test, build, ci,
  chore and revert. The project limits titles to 72 characters. Avoid generic
  titles such as "update files". After a blank line, explain the problem and resulting
  behavior or reason; include `Validation:` with actual commands/results (or why a
  check was not run). Breaking changes require both `!` and a `BREAKING CHANGE:`
  footer explaining impact and migration. Edit generated merge/revert messages to
  follow this contract. The commit-msg hook checks format, not factual accuracy.
- Commit provider changes before consumers in cross-repository work. Mention relevant
  provider commit hashes in consumer messages when an interface dependency changes.
  At an integrated checkpoint, update workspace.json to the verified child revisions
  and record the checks; never describe uncommitted trees as a reproducible checkpoint.
- Preserve useful checkpoints. Do not amend published commits, force-push, rewrite
  shared history or squash distinct changes without explicit authorization. Prefer a
  focused fix or revert. Use log, blame, diff and bisect when locating regressions;
  mark pre-existing untestable revisions as skipped rather than bad in a bisect.
- Each module keeps two remotes: laycat at gitea.gklazycat.heiyu.space
  and aliyun at gitea.vhkd.top. The current branch tracks laycat. Reserve origin
  for a future GitHub remote; leave it unconfigured until requested. Preserve unrelated third-party source and licensing links.
- The user authorizes automatic delivery to aliyun: after completing a coherent
  group of validated commits, fetch and inspect aliyun, then push the current
  branch to its same-named branch there. No repeated approval is needed.
  Leave laycat configured; the user handles its availability and delivery
  manually. Do not retry it or block delivery on it. Keep local commits timely
  and push to aliyun at validated checkpoints.
- Do not infer a destination when a remote is missing, or publish other branches
  or tags implicitly. Resolve divergence without force or rewriting history.
  If authentication, connectivity or configuration prevents the aliyun push,
  retain local commits and report that delivery failure.
  The root workspace currently has no remote; keep its commits local until a
  destination is provided. Never claim an unpushed commit is backed up remotely.
  Do not bypass shared hooks to finish a task.

## Local version control (jj)

Every repository here is a colocated Jujutsu workspace (`jj git init --colocate`).
Use jj for every write operation; use git read-only (inspection, remotes, CI).
The same steps are available as `pi-skill jj-workflow status|commit|publish|undo|workspace-*`
(prefer the command when publishing: it fetches, checks fast-forward and verifies the push).

- Work on one change: `jj new -m "type(scope): summary"` (or edit first, then
  `jj describe`). jj snapshots the working copy on every command, so there is
  nothing to stage. Close the change with `jj new` before starting unrelated work.
- Publish before pushing: `jj bookmark set <branch> -r @-`, then push with the
  existing remote rules (`jj git push --remote <remote>`, or
  `git push <remote> <branch>:<branch>`). Git's HEAD is detached while jj owns the
  working copy; that is expected, not a repository problem.
- jj does not run git hooks. Keep the Conventional Commit contract by hand, and run
  the affected checks plus the workspace check before publishing a change.
- Recover with `jj undo`, inspect history with `jj log`, and use `jj evolog -p` to
  see a file's revisions. Use `jj workspace add <dir>` for parallel experiments,
  never `git worktree`.
- History that exists on a remote is immutable (`immutable_heads()` includes
  `remote_bookmarks()`), so rewriting published commits is refused by design.
