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
- Debug and test scripts that print ETAF/EBox buffer content must take the text
  with `buffer-substring-no-properties`; when printing structures that may carry
  text properties or cycles, bind `print-circle` (plus `print-length`/`print-level`
  as needed). `%S` expands every text property, and cyclic property graphs
  (keymaps and closures referencing each other) print forever and exhaust memory.
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
- Never weaken a check, add an exclusion or skip a test just to make a failure green.
  Update obsolete checks to the current contract and retain behavioral coverage.
- If a new document or directory does not fit this policy, first simplify the design.
  Maintain shared checkers, hooks and configuration in the workspace and distribute
  them with `python3 scripts/workspace.py sync`. Changes to mechanically enforced
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
message of every commit in the publish range (`<range>` is `main@aliyun..@-` in a
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

### Publishing

- Each module keeps two remotes: laycat at gitea.gklazycat.heiyu.space and aliyun
  at gitea.vhkd.top. Reserve origin for a future GitHub remote; leave it
  unconfigured until requested. Preserve unrelated third-party source and licensing
  links.
- The published bookmark is the `branch` recorded in `workspace.json` (`main`).
  jj does not derive the push remote from tracking, and no `git.fetch` or
  `git.push` default is configured, so always name the remote and the bookmark.
- The user authorizes automatic delivery to aliyun: after completing a coherent
  group of validated commits, publish `@-` to the same-named branch there. No
  repeated approval is needed. Leave laycat configured; the user handles its
  availability and delivery manually. Do not retry it or block delivery on it.
  Keep local commits timely and push to aliyun at validated checkpoints.

  ```sh
  jj git fetch --remote aliyun
  jj log -r '@-..main@aliyun'      # must be empty: publishing fast-forwards
  jj log -r 'main@aliyun..@-'      # the commits being published
  jj bookmark set main -r @-
  jj git push --remote aliyun -b main
  ```

- When `@-..main@aliyun` is not empty, rebase the unpublished commits with
  `jj rebase -b @- -o main@aliyun` and repeat the checks; if they are already
  immutable (for example on laycat), merge with `jj new @- main@aliyun -m "…"`.
  Never force-push.
- Do not infer a destination when a remote is missing, or publish other bookmarks
  or tags implicitly. If authentication, connectivity or configuration prevents the
  aliyun push, retain local commits and report that delivery failure. Never claim
  an unpushed commit is backed up remotely.
- The root workspace has no remote; keep its commits local until a destination is
  provided, but still move its `main` bookmark with `jj bookmark set main -r @-`
  after each completed commit.

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
