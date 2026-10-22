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
- Before changing installation, packaging, release or dependency handling, read
  the distribution contract (section 13 of
  [the ecosystem contract](docs/architecture.zh-CN.md)) and the workflow in
  [the tool manual](docs/manual.md). Menu wording, component layout and the
  dependency classes are decided there; do not invent a second install path.
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
  Standalone example applications use `examples/<app>/<app>.el` as their entry
  and follow the same entry/lisp layout. Their entry Commentary owns their API;
  those exports do not become framework APIs. The boundary gate checks each
  such application as a separate consumer, including calls from tests.
  Native subprojects follow their language's own layout. Keep domain resources in
  descriptive directories such as `dictionaries/`; do not create generic dumping grounds.
- Use `site/` for a static website build: its source, content generator and
  publish scripts are maintained files; dependencies, generated content and
  the build output stay untracked. A repository that publishes a site provides
  one command that regenerates the content and deploys the current build.
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
| ETAF Reference Manual (`etaf-manual/book/`) | Users and developers of the core packages (ecss, ekp, ebox, etaf, etaf-ui, etaf-db) looking up exact behavior | Concept models; one definition entry per public interface whose signature matches Commentary; semantics, ordering, errors and recovery; how each subsystem works (data flow, invariants, cost) explained through concepts and public interfaces; runnable examples; one line per paragraph | Tutorials, task narration, unimplemented target behavior, entries for or references to private symbols, applications, games and a hand-maintained API list outside its definition entries |
| Workspace `docs/architecture.zh-CN.md` | Maintainers coordinating ecosystem development | Cross-package responsibilities, accepted target contracts, relevant implementation gaps, dependency order and observable acceptance criteria | Conversation history, agent operation, unaccepted ideas and claims that pending capabilities already work |
| Workspace `docs/keyboard-navigation.zh-CN.md` | Framework and application maintainers implementing keyboard interaction | The authoritative accepted contract for regions, navigation, editing states, key ownership, help, implementation gaps and observable acceptance | Duplicate package API inventories, task narration and claims that target behavior is already implemented |
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
  The workspace keyboard navigation contract is maintained in its dedicated
  document above; the ecosystem architecture and package documents link to it.
- The ETAF Reference Manual owns the user documentation of the core packages.
  A core package keeps its README, Commentary, CHANGELOG and maintainer
  `docs/architecture.md` and links to the manual; once the manual covers it,
  it keeps no `docs/manual.md`. Its chapters live in the etaf-manual repository
  (see its `docs/manual.md` for the authoring format).
- English uses the default name; Chinese translations use `.zh-CN.md` consistently.
  Reference-book chapters use language directories instead: `book/en/<slug>.md`
  and `book/zh-CN/<slug>.md` with the same slug and definition entries.
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
  ownership, lifecycle, failure semantics and a runnable example in its manual;
  core packages do so in the ETAF Reference Manual.
  Keep private implementation symbols out of consumer code.
- Keep the reference manual current. A change to a core package's public
  interface, documented behavior or a mechanism the manual explains updates the
  affected etaf-manual chapters in both languages in the same integrated
  delivery; `make -C etaf-manual check` verifies definition coverage, signatures,
  translations, links and examples against the sibling sources.

## Development and validation

- Before treating a dependency or framework as defective, restore its original implementation and run the same case; a passing counter-proof means it is not the framework, so do not patch its code.
- Apply design requirements to their responsible packages and affected integrations.
  A package's requirements do not automatically apply to its dependencies.
- Preserve each package's documented responsibility, independent use and dependency
  direction. Keep shared capabilities in their owning provider; do not duplicate
  authoritative state or algorithms in consumers. Migrate affected callers with
  interface changes and remove the superseded route once migration is complete.
- Evolve the shared component catalog while building frameworks and applications.
  Before reusing a component, assess whether its name, responsibility, visual
  defaults, interaction model, state ownership and public props fit the intended
  reusable concept. Existing code is not by itself a reason to reuse it; an
  earlier application's terminology or assumptions must not dictate a new
  application's interface.
  Reuse or configure a component when its semantics already fit. Improve or
  refactor it when the shared abstraction is wrong; extract a common primitive
  and compose specialized components when the use cases share mechanisms but
  have different semantics. Add a new component when it has a distinct reusable
  responsibility. Name each layer for that responsibility and keep application
  policy in the application. Do not accumulate application-specific flags,
  misleading aliases, copied controls or exceptions that make the catalog harder
  to understand. Avoid speculative abstraction or renaming a sound component
  merely to match the newest application.
  Put reusable ETAF components in etaf-ui and engine primitives in ebox, expose
  required engine capabilities through ETAF, then consume their public APIs.
  A changed abstraction includes migration of affected consumers, examples,
  API documentation and public behavior tests; validate both established and new
  workflows, including appearance, keyboard/mouse interaction and latency.
  Component defaults must be modern and visually coherent: unified icon metrics
  that never grow the standard line height, consistent spacing and state styling
  through theme tokens. The catalog accumulates across applications so later
  text apps reuse it instead of rebuilding the same control.
- Interactive states must not stack.  A control or row that is already
  active or selected keeps its selected presentation and takes no
  pointer-hover highlight; hover feedback belongs to unselected targets
  only.  Catalog components with a selected state suppress their hover
  fill, and application rows apply hover only when they are not the
  current or selected one.
  A state style declares the paint it changes, typically the fill; the engine
  restates the label's own ink, weight and decoration in the native hover face.
  Components must not carry per-theme text colours to survive a hover.
- State colours must come from the Theme.  A hover, selected or active fill
  reads a theme token or is derived from the theme's own surface and text
  colours; never use a fixed light-only literal, because a dark application
  would paint light text on it.  A derived state colour must keep the label
  at least as readable as the resting state, and hover feedback stays
  visible.  Check every interactive surface with the pointer in both
  palettes, and prefer deriving in the owning catalog component over
  repeating a colour in each application.
- User-visible copy follows mixed-script typography: a Chinese character
  next to a Latin letter or digit keeps one separating space, in literal
  strings and in values joined at display time alike (for example a
  chapter card reads `上一章 18 盒与常规流`); full-width punctuation keeps
  its own spacing.
- Before implementing a new ETAF interface or a visual redesign, create an SVG
  design and render it into a complete image for explicit user approval.
  Use the intended viewport, readable typography and representative content;
  include panel and control borders in the design, not just layout boxes.
  Only then reproduce the approved design with ETAF and reusable UI components,
  and compare real GUI captures against it before functional and performance
  acceptance. A mockup is not an implemented interface or acceptance evidence.
  Changes to an approved visual design require renewed approval; fixes that
  preserve it use the existing design as their reference.
- Implementation draws UI decoration with text properties, not with images:
  icons, borders, dividers, progress and badges use faces and etaf-ui
  components, and application code never builds SVG markup or calls
  `create-image` to replace a control. Reaching for an image is right only for
  shapes no font can draw (make it one etaf-ui component, not one per app) or
  for content that is itself an image, such as covers, avatars and inline
  figures. The detailed decision table, with the reasons it holds, lives in the
  `etaf-app-dev` skill under `guide layout`.
- Application layouts, including games, must have a coherent content grid,
  aligned region boundaries, intentional spacing and a clear visual hierarchy.
  Avoid large empty panels created merely by stretching containers.
  Preserve game-world geometry and intrinsic tile/sprite dimensions across
  viewport sizes. Reflow, reposition or collapse surrounding panels and use
  deliberate framing; never stretch game elements merely to fill a window.
  Adapt region proportions, arrangement and information density to both width
  and height across the supported viewport range; one well-sized screenshot is
  not sufficient acceptance. Keep controls readable and preserve standard line
  metrics rather than squeezing or overlapping them to fit.
  Define and document a meaningful minimum usable viewport. Below it, preserve
  the layout's structure and use deliberate viewport clipping or scrolling;
  do not promise full adaptation to impractically small dimensions. Validate
  wide, ordinary, compact and short windows in the real GUI, including resize
  during interaction, before completing an application change.
- Applications and catalog components use ETAF's public API only; Ebox stays an
  internal engine behind it. When an application needs a lower-level capability
  (measurement, retained updates, viewport control), extend the ETAF API first
  and consume that; never call ebox- prefixed functions from an app or a
  catalog component. ETAF must stay the simple, low-understanding-cost entry for
  building complete text applications.
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
- `scripts/run-acceptance.py` serializes one run per checkout and caps ERT failure
  output: concurrent runs are refused with exit 75 unless `--wait SECONDS` queues
  them, and `--print-level`, `--print-length` and `--max-condition-bytes` tune how
  much of a failing condition is printed.
- Assert on small values: bind the result of calls that take large live objects
  (runtimes, desktops, buffers) to a local before evaluating a `should` form; ERT
  captures evaluated arguments, so a large object inside the form makes every
  failure report huge.
- Debug and test scripts that print ETAF/EBox buffer content must take the text
  with `buffer-substring-no-properties`; when printing structures that may carry
  text properties or cycles, bind `print-circle` (plus `print-length`/`print-level`
  as needed). `%S` expands every text property, and cyclic property graphs
  (keymaps and closures referencing each other) print forever and exhaust memory.
  Error handlers and custom debuggers have the same restriction: with
  `debug-on-error`, never use `%S` for a live Runtime, session or
  `(backtrace-frames)`; cyclic objects can trap Emacs in a 99% CPU print loop.
  Bind `print-circle` to `t` and limit `print-length`/`print-level` in error
  reports, or print only the error message.
- Do not call functions that move match data (`string-match`, `string-trim`,
  `string-replace`, and similar) from a function-valued REP callback to
  `replace-regexp-in-string`: Emacs uses the callback's leftover match data as
  the replacement base, so only a prefix is replaced (`(a.md)` becomes `(a/`
  with a leftover `md)`). Wrap every callback body in `save-match-data`, or
  save `(match-string 0)` before other work.
- Every Lisp file written for Emacs to load, including temporary debug, probe and
  GUI scripts outside the repositories, starts with
  `;;; -*- lexical-binding: t; -*-`. Emacs 31 raises a `*Warnings*` buffer over
  the user's frame for each load of a file without it.
- Look up Lisp with `python3 scripts/elisp.py def SYMBOL...` (complete forms)
  and `refs SYMBOL` (callers by enclosing definition) instead of searching and
  reading guessed line ranges; batch independent lookups and reads into one call.
  Run batch Lisp through `python3 scripts/elisp.py run`, which loads the
  workspace via `scripts/ecosystem.el` and bounds time, memory, output and
  printing; do not hand-write `-L` chains or timeout wrappers. See
  [the tool manual](docs/manual.md).
- After editing a `.el` file, byte-compile it: unclosed delimiters surface as
  `End of file during parsing`. To independently check delimiter balance, run
  `check-parens` in an `emacs-lisp-mode` buffer; in `fundamental-mode`, `;` is
  not a comment and apostrophes inside comments are treated as quotes, producing
  false `Unmatched bracket or quote` reports.
- From this directory, use `make -C <package> structure-check` and affected tests
  while developing; run `make -C <package> check` before completing a package change.
  That target runs the checkout's own copy of `scripts/check-repository.py`, so
  a copy that lags `workspace.py sync` accepts what
  `python3 scripts/workspace.py check` rejects; read the workspace verdict,
  whose unprefixed error lines belong to the checkout named by the prefixed
  lines above them.
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
  contract; [validating an isolated checkout](docs/manual.md#validate-an-isolated-checkout-in-a-real-gui)
  in the full user init follows the manual's isolated GUI session recipe.
  Invalid, incomplete, stale-code or incomparable runs remain unverified.
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
  Run workspace validation (`make check` / `make verify`) only after editing and
  committing are complete on a quiet tree: any workspace source change during
  measurement marks the entire run `UNVERIFIED: Workspace sources changed during measurement`.
- Run `make setup-hooks` after cloning so Git commits run the structure and message
  gates on the exact index. jj does not run Git hooks; run the same commands before
  publishing (see `Checks before publishing`). CI runs the same structural and API
  checker plus `make api-check` in batch Emacs, fetching missing provider checkouts.
  Local checks use sibling sources; CI uses provider default branches.
  `workspace.json` records the tested combination of revisions.
  The boundary gate covers runtime, runnable examples and Lisp tests/helpers.
  Tests may not reference internal APIs of either their own package or a provider.
  Static checks cover direct references; code review must also reject dynamically
  constructed private calls. These checks do not constitute Lisp access control.
- A diagnostic the framework reports while a test runs (component validation,
  a renderer warning, a byte-compilation or loader error) is a defect, not
  noise: read it, find the owning layer and fix it there. Never silence it
  with `ignore-errors`, a wider `condition-case`, a suppressed warning or a
  test exclusion; suppressing is only right when the diagnostic itself is
  wrong, and then the fix belongs where the diagnostic is raised.
- Never weaken a check, add an exclusion or skip a test just to make a failure green.
  Update obsolete checks to the current contract and retain behavioral coverage.
- If a new document or directory does not fit this policy, first simplify the design.
  Maintain shared checkers, hooks and configuration in the workspace and distribute
  them with `python3 scripts/workspace.py sync`. Commit the root tooling, then run
  `python3 scripts/workspace.py seal-sync` in the same delivery: it commits only
  the shared copies in each child and names other unpublished work that
  publishing that child would include. Changes to mechanically enforced
  rules update the checker and its tool regressions together.

## Version control and delivery

This root and every repository in `workspace.json` are colocated Jujutsu
repositories. Use jj for every local write: changes, descriptions, bookmarks,
rebases and bisection. Use git read-only for inspection and CI. Git's HEAD stays
detached at `@-` while jj owns the working copy; that is expected.
`pi-skill jj-workflow status|commit|publish|undo|workspace-*` wraps these steps
where installed. Its `publish` fetches, checks fast-forward and re-reads the
remote, but does not run the checks below.

### Changes

- Commit promptly after a coherent change has been validated, before starting an
  unrelated change and before ending a completed task. A commit is one explainable,
  independently reviewable and revertible change, not one function or a fixed count
  of files/lines. Keep its code, regression coverage and documentation together.
  Split unrelated fixes, formatting, moves and features; keep necessary path/caller
  updates together so each commit remains usable for bisection.
- A working copy has one writer. jj snapshots every file into `@` on each command,
  so run `jj st` before editing: a non-empty `@` you did not create holds another
  person's unfinished work. Do not describe, squash, abandon or restore it; seal
  only your paths with `jj commit <paths> -m "…"`, and ask before continuing when
  both of you edit the same file. Parallel agents and experiments use their own
  `jj workspace add <dir>`, never `git worktree`. Never include generated files.
- Start a change with `jj new -m "type(scope): summary"`, or edit first and run
  `jj describe`. Inspect `jj st` and `jj diff`, then seal it with `jj commit -m "…"`
  (describe plus `jj new`): the finished change becomes `@-` and further work starts
  in an empty `@`. Run affected checks and `make check` before sealing a completed
  package change. Report failures honestly; do not create a passing-looking
  checkpoint by hiding them.
- Unpublished commits (`mutable()`) may be reworded, squashed into their own change
  or rebased. Never rewrite published commits, force-push or squash distinct changes
  without explicit authorization. Prefer a focused fix or `jj revert`.
- Use Conventional Commits: `type(scope): concrete imperative English summary`.
  Scope is optional; types are feat, fix, docs, refactor, perf, test, build, ci,
  chore and revert. The project limits titles to 72 characters. Avoid generic
  titles such as "update files". After a blank line, explain the problem and resulting
  behavior or reason; include `Validation:` with actual commands/results (or why a
  check was not run). Breaking changes require both `!` and a `BREAKING CHANGE:`
  footer explaining impact and migration. Edit generated merge/revert messages to
  follow this contract. The message checker verifies format, not factual accuracy.

### Checks before publishing

jj runs no Git hooks, so run their commands from the repository root. Check the
message of every commit in the publish range (`<range>` is `main@origin..@-` in a
child and `main..@-` in the root), then the sealed tree, which the colocated Git
index mirrors as `@-`. A secondary `jj workspace add` checkout has no Git index;
there `--staged` accepts only an empty `@` and checks that sealed working copy.
The final query must print nothing. Do not skip these checks to finish a task.

```sh
jj log -r <commit> --no-graph -T description > /tmp/msg
python3 scripts/check-commit-message.py /tmp/msg
python3 scripts/check-repository.py --staged
jj log -r '(<range>) & (conflicts() | divergent() | description(exact:""))'
```

Run each command from the repository being published. The workspace root's
`scripts/check-repository.py` defaults `--root` to the workspace root, so
invoking it by absolute path from a child checks the root (and fails on
unrelated root files) instead of the child's sealed tree.

### Publishing

- Every module has three remotes: `origin` at github.com/emacs-taf (the public
  home), aliyun at forgejo.vhkd.top and laycat at gitea.gklazycat.heiyu.space
  (mirrors). Published files name the GitHub origin: repository links, package
  URL headers and the `url` of every `workspace.json` record. Each mirror serves
  the same commit under its own host; do not rewrite links per host. Preserve
  unrelated third-party source and licensing links.
- The public home presents release history only: it carries release tags
  (`v<major>.<minor>.<patch>`, with a GitHub Release when the notes are ready)
  and keeps each repository's topics to the role topic, `emacs` and at most two
  specific topics. Milestone, candidate, performance and rollback tags belong to
  the bisect and recovery workflow, stay on the mirrors and are never pushed to
  origin.
- The published bookmark is the `branch` recorded in `workspace.json` (`main`).
  jj does not derive the push remote from tracking, and no `git.fetch` or
  `git.push` default is configured, so always name the remote and the bookmark.
- The user authorizes automatic delivery to aliyun and origin: after completing a
  coherent group of validated commits, publish `@-` to the same-named branch on
  both. No repeated approval is needed. Leave laycat configured; the user handles
  its availability and delivery manually. Do not retry it or block delivery on it.
  Keep local commits timely and push at validated checkpoints.

  ```sh
  jj git fetch --remote aliyun
  jj git fetch --remote origin
  jj log -r '@-..main@aliyun | @-..main@origin'  # must be empty: fast-forwards
  jj log -r '(main@aliyun | main@origin)..@-'    # the commits being published
  jj bookmark set main -r @-
  jj git push --remote aliyun -b main
  jj git push --remote origin -b main
  ```

- When `@-..main@aliyun` or `@-..main@origin` is not empty, rebase the unpublished
  commits with `jj rebase -b @- -o main@aliyun` or `-o main@origin` and repeat the
  checks; if they are already immutable (for example on laycat), merge with
  `jj new @- main@aliyun -m "…"`. Never force-push.
- Do not infer a destination when a remote is missing, or publish other bookmarks
  or tags implicitly. If authentication, connectivity or configuration prevents a
  push, retain local commits and report that delivery failure. Never claim
  an unpushed commit is backed up remotely.
- The root workspace uses the same `origin`, `aliyun` and `laycat` remotes as the
  modules; move its `main` bookmark with `jj bookmark set main -r @-` before pushing.
- A change users install from the ETAF package archive (`https://etaf.top/packages/`)
  is not delivered until that archive serves it: bump the package `Version`, publish
  the provider, record it in `workspace.json`, then build, gate and publish the
  archive and read the published `manifest.json` back. `pi-skill etaf-archive-release
  release <package> --yes` runs that sequence and refuses to publish unless every
  install target passes the archive gate. Do not leave a package fix reachable only
  from the repositories.

### Cross-repository revisions

- Commit provider changes before consumers. jj rewrites give a commit a new ID
  while its change ID stays, so publish provider commits before quoting their IDs
  in consumer messages when an interface dependency changes.
- At an integrated checkpoint, record each child's published `main` commit
  (`jj log -r main --no-graph -T commit_id`) in workspace.json together with the
  checks. `python3 scripts/workspace.py status` compares that bookmark, not `@`.
  Never describe uncommitted trees or an unsealed `@` as a reproducible checkpoint.

### History and recovery

- Published history is immutable because the `immutable_heads()` alias includes
  `remote_bookmarks()` (see the README setup); jj refuses to rewrite it by design.
  Confirm it with `jj config get 'revset-aliases."immutable_heads()"'`.
- Locate regressions with `jj log -p <path>` (file history), `jj file annotate
  <path>` (blame), `jj diff` and `jj bisect run --range <good>..<bad> -- <command>`.
  Bisection edits the working copy, so run it in a separate `jj workspace add`;
  exit status 125 skips a pre-existing untestable revision instead of marking it bad.
- Undo the last operation with `jj undo`, or restore an earlier state from
  `jj op log` with `jj op restore <operation>`. `jj evolog -p -r <rev>` shows how a
  single change was rewritten, not a file's history.

## Applications and games

Framework packages, applications and games are sibling checkouts registered in
`workspace.json`, with `role` set to `framework`, `application` or `game`. The
root is the only workspace: do not create a nested workspace root, and do not
clone a second checkout of a registered repository. Everything that needs an
isolated tree (a release, a benchmark, an acceptance run) creates a disposable
workspace and removes it.

Application and game Makefiles resolve providers as siblings (`../etaf`); they
keep the `../..` fallback only so a standalone clone still builds. A new
application is added to `workspace.json`, the README tables, and (only if the
archive ships it) `release-dependencies.json` in the same change.

### Emacs 29 compatibility

The providers keep Emacs 29.1 as their baseline and CI runs Ubuntu's
`emacs-nox`; breakage from newer Emacs versions or a graphics-less build only
surfaces there. Three patterns cover everything seen so far:

- **Emacs 30+ APIs**: a direct `(string-pixel-width string buffer)` call fails
  every mount on 29 with `wrong-number-of-arguments`. Probe the arity and fall
  back (see `ebox--string-pixel-width-in`).
- **C-implemented graphics functions**: `image-size` and `image-flush` are C
  functions on 29, so `require`ing `image` gives the byte compiler no definition
  and `byte-compile-error-on-warn` fails the compile. Declare them near the
  requires: `(declare-function image-size "image.c" (spec &optional pixels frame))`
  and `(declare-function image-flush "image.c" (image &optional frame))`.
- **Graphics-only scenarios** cannot run without a display; guard them with
  `(skip-unless (and (display-graphic-p) (image-type-available-p 'png)))`.

Reproduce all three in batch without a second Emacs: `fmakunbound` the C
functions before a `byte-compile-error-on-warn` compile, and run the suite in
batch where `display-graphic-p` is nil.

### Measuring interaction stalls

- Measure, never guess: schedule a repeating 50 ms timer that records
  `(- (float-time) (+ start (* n 0.05)))` and report the maximum plus the counts
  over 20 ms and 100 ms. A healthy idle application stays at 1-6 ms; a
  whole-view publication per second reaches 200-500 ms.
- Attribute without editing code: point the retained Host the application uses
  at a missing symbol, run the same probe, then restore it.
- Compare interleaved rounds with medians; a single pass on a loaded GUI varies
  by more than 50%.
- Timers only run while Emacs waits: drive them in batch with `sleep-for`, never
  `accept-process-output` or `sit-for`.
- Measure rendered height with `window-text-pixel-size`, not buffer lines;
  `posn-at-point` on a line boundary reports the wrong row.

### UI acceptance

Every interaction a person can perform is verified in a real graphical session
before a change is complete. Provider unit scenarios, batch rendering and README
screenshots are not application acceptance.

- Drive the controls, not the model API: send documented keys through the
  command loop (`execute-kbd-macro`) or activate through ETAF focus
  (`etaf-focus` + RET). OS-level synthetic clicks do not reach Emacs text areas,
  so the native activation path stands in for a click; record which path each
  step used.
- Mount through the application's offline harness for capture passes; a session
  against the real backend keeps the canvas blank until its service answers.
  Close the verification instance when the pass ends, including a failed one.
- Verify against the signed-in account before claiming completion: scripted
  scenarios are the regression gate, not the acceptance result.
- Walk every affordance the buffer exposes. An affordance without a scenario is
  an untested affordance.
- Verify the layout matrix (wide, medium, narrow, short), asserting the resolved
  layout state and each column's content, then review the captures.
- Keep every row within the frame line height; a font fallback or a variation
  selector (U+FE0E) clips the bottom rows.
- Assertions and visual review are separate steps: a green run certifies
  behavior, not appearance.
- Record every problem a pass finds in one list, fix them one by one with
  regression coverage, then re-run the affected scenarios. Run evidence stays
  outside version control.

Maintain scenarios as `scripts/<application>-gui-scenarios.el` on the shared
`emacs-gui-verifier` engine; its action, checkpoint, evidence and timing
contract lives in `etaf`'s manual under GUI verification tools.

### View width discipline

- In ETAF/Ebox views, `width: stretch` fills its containing block, not remaining
  space. For remaining space use `flex-basis (ch 0)` with `flex-grow 1`; never
  add `flex-shrink 0`, which overflows the container.
- An over-wide canvas pushes centered blocks aside; clicking its right edge can
  horizontally scroll the overflow. Compare each line's `window-text-pixel-size`
  with `(window-body-width win t)`.
- Indent Chinese paragraphs with ordinary spaces, never U+3000; a missing glyph
  renders it as an underlined escape glyph.

### Provider integration pitfalls

- `call-process` takes a *file name* for stderr, never a buffer. Pass
  `(list OUTPUT-BUFFER STDERR-FILE)` with `make-temp-file`, read the file back on
  failure, and delete it in `unwind-protect`.
- `json-parse-string` signals `json-trailing-content` on a trailing newline;
  trim the CLI's stdout first, or use `json-parse-buffer`.
- `json-encode` guesses alist versus plist from the first element, so a *list of
  plists* encodes as an alist. Store nested values through a small recursive
  encoder that keeps keyword-keyed plists as JSON objects, and parse them back
  with `:object-type 'plist`.
- In an `etaf-view` body a helper call in a child position must be wrapped:
  `(expr (my-view ...))`. A bare call is rejected with "must be inside (expr FORM)".
- When a view wraps text itself, count every prefix (indent, quote bar) in the
  wrap width; leave one cell of slack in the column width.

### Runtime-only defects

These are green in batch while broken in a real session:

- A View or mount path must not touch storage, create Data Controllers or call
  the network; ETAF rejects it as `etaf-render-side-effect-error`. Views read
  refs and cached values; data access belongs before mounting or inside commands
  and events.
- The renderer's minor-mode map owns `SPC`, `S-SPC`, `DEL`, `C-v`, `M-v`, `RET`,
  wheel and `n`/`q`. An application does not install its own mode map: its keys
  are the root Host's `:keys` (`(KEY COMMAND LABEL)`), which outrank the buffer
  keymap and stay inert during a native input session. A sequence cannot start
  with a printable key, `RET` in an application's own list must keep focused
  controls activating, and help reads the same labels. Verify by driving the
  documented keys through `execute-kbd-macro`, never by calling the command.
- `(setf (plist-get plist :key) value)` only writes in place when the key exists;
  create every hot field with the session, or use `plist-put`.
- A hand-written `'(.body . nil)` reads as the symbol `.body`, not
  `(body . nil)`; every `eq` comparison against it silently fails.
- Retained Host updates take a **symbol** ref (a string signals "Unknown
  committed Host"), the node needs both `:ref` and `:id`, and one missing target
  rejects the whole batch.

### Retained Host updates

- A scoped update through ETAF's retained Host boundary stays scoped: the update
  report reads `strategy owner-rerender` or `span-patch`, `dirty 1`, `patch 1`,
  with a `projection-kind` of `span-patch` or `owner-scoped`.
- Its cost follows the changed subset, not the view. A per-second scoped update
  is affordable; re-measure after a provider change.
- Publishing out of band is only safe while the controlled state stays
  authoritative: publish the local effect eagerly so an interaction never waits
  for a later publication.
- A mount can precede the window manager's resize, leaving the canvas at the old
  viewport; repaint once at a neighbouring width and once at the real width when
  a settled window grew across a layout boundary.
