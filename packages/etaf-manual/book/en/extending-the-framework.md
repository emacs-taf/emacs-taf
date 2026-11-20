# Extending the Framework

The earlier parts describe the framework as it is; this chapter describes how it grows. Some extensions are open to any consumer through a public macro or protocol, and some are work on the packages themselves, because this version deliberately exports no registration point for them. Each section below takes one of the seven documented extension routes, says when the route applies, names the public interfaces it uses, and gives the checks that keep the result in the ecosystem's shape. All of the routes end in the same three obligations: a public inventory entry, a manual entry in both languages, and an acceptance test.

## Which routes are open

<!-- index: extension point; package work -->

| Route | Open to consumers | Public interface |
| --- | --- | --- |
| New Behavior | Yes | `etaf-define-behavior`, `etaf-behavior-create` |
| New UI component | Yes | `etaf-define-component` |
| New Data backend | Yes | `etaf-data-source`, `etaf-data-source-load-page` |
| New image converter | Yes | `ebox-image-converters`, `ebox-image-prepare` |
| Expose an Ebox capability through ETAF | Yes, by extending ETAF | The new ETAF adapter, plus the Ebox interface it wraps |
| New Host kind | No: package work in Ebox and ETAF | Ebox author tags; ETAF Host kinds |
| New style property | No: package work in Ebox | `ebox-style-schema-id`, `ebox-style-property-accepted-p` |

The two closed routes are not an accident of incomplete work. A Host kind and a style property sit in the middle of the layout engine and the cascade, where an outside definition could break invariants the whole framework relies on, so they are added by changing the package that owns them. The five open routes cover what a consumer can build without touching those layers.

## Adding a Host kind

<!-- index: host kind; author tag -->

A new Host kind is warranted when an interface needs a primitive whose layout or interaction cannot be expressed with the existing kinds — `text`, `box`, `fragment`, `row`, `column`, `flex`, `grid` and `image`. Because the kind must participate in style acceptance, layout, hit testing and incremental damage, adding one is work in Ebox and then in ETAF; this version has no `define-host` style registration.

The steps follow the layering. In Ebox, choose the author tag and define what it means: which author properties it accepts, how it treats children, how it lays out and paints, and which part of it is interactive. Teach the builder and the node layer to accept the tag and reject the wrong shapes with a named error. In ETAF, add the Host kind to the View language and map it to the Ebox tag, including the semantic and event properties that apply and the validation of each. Expose any new query or mutation as a public ETAF interface rather than letting callers reach the node. Then update the Hosts chapter, the style-property applicability tables and the property-acceptance matrix, and add the acceptance scenarios.

The check is the same as for any Host: mount it in a real window, verify its layout at several viewport sizes, and exercise its focus, pointer, drag and input behavior if it has any. `etaf-runtime-host-props-for` must report the committed semantic properties, and the boundary gate must pass.

## Adding a style property

<!-- index: style property; schema; hot field -->

A new style property is warranted when a visual concept has no existing property and its value should participate in the cascade like the rest. Adding one is Ebox package work; the public interfaces report the result rather than accept a definition.

In Ebox, add the property to the style schema: its canonical name, aliases, initial value, whether it inherits, the contexts where it applies, its value validator and its membership in shorthands. If the property affects geometry, fill the corresponding hot field in the computed style record and mark the dirty bit that makes the flush recompute layout; a paint-only property needs the paint bit instead. The schema is registered with ECSS, so the computed style record and its provenance include the property automatically: writers then use it through rules and inline declarations, and readers through `ecss-computed-style-value`, `ecss-computed-style-present-p` and `ecss-computed-style-property-fact`. `ebox-style-property-accepted-p` is what a Host kind uses to accept or reject it.

Finally, update the style property reference with the value syntax, initial value, applicability, inheritance and paint-or-geometry effect, in both languages, and add scenarios for the validators, the shorthand expansion and the visible effect. A property that never changes a pixel or a geometry fact should not exist.

## Adding a Behavior

<!-- index: behavior extension; installer -->

A Behavior bundles semantic attributes and optional setup into one reusable unit, installed on a Host with `:use`. Use this route when the same interaction attribute set appears on several Hosts and you want one definition instead of copies. A Behavior is data, not a View node: it never renders and never introduces a container.

Define the constructor with `etaf-define-behavior`; its body must return an `etaf-behavior-create` spec. The spec's attributes merge into the Host's properties, and the reserved `:install` attribute runs setup and returns a cleanup function:

```elisp
(etaf-define-behavior demo-hint (label)
  (etaf-behavior-create
   'demo-hint
   :help-echo label
   :install (lambda ()
              (push 'installed log)
              (lambda () (push 'cleaned log)))))
```

Install it with `(text :use (demo-hint "press me") "hello")`. The installer runs when the Behavior is installed on a committed Host and the cleanup runs when it is removed or the Host is unmounted, which is what makes the route safe for resources. An invalid spec signals `etaf-behavior-error`. Keep the Behavior free of application policy: which Behavior to use and when belongs to the application, the attributes and cleanup belong to the Behavior.

## Adding a UI component

<!-- index: ui component; catalog entry; theme token -->

A new UI component is the most common extension: an application-specific control, or a new entry in the component catalog. Use `etaf-define-component` and choose exactly one frontend: `:view` when the output is a compiled structure, `:render` when ordinary Elisp is the clearer way to compute it. Instance state belongs in `:bindings` or in refs created by `:setup`; props are the inputs, and `:validate` rejects invalid ones before anything is published.

When the component belongs in etaf-ui, it also follows the catalog contract: one entry shape with a props table (name, type, default, controlled or `:bind` participation, meaning), then slots, reported events, keyboard and focus behavior, accessible metadata, the theme tokens it reads, and its size rules. New theme tokens are added to the catalog's default theme and read through `etaf-theme-token`. A catalog component uses ETAF public APIs only: it never calls an Ebox-prefixed function, which the workspace boundary gate checks.

An extension in flight can redefine a Component with `etaf-component-redefine-run` around the definition, which replaces the registry entry and invalidates compiled material; mounted instances of the old definition keep it until they are disposed. Validate a new component the way the catalog chapters do: a runnable example that mounts, a real GUI pass at wide, ordinary, compact and short viewports, and the manual entry in both languages.

## Adding a Data backend

<!-- index: data backend; source capability -->

A Data backend adapts a storage or service to the Data Source protocol. Create the source with `etaf-data-source` and the capabilities that describe it. `:load` is required: it receives the query, page and page size and returns a plist containing at least `:items`, optionally `:total`, `:page` and `:page-size`. Writes use optional `:mutate`, or `:mutate-v2` when the backend can report commit certainty, or `:mutate-batch` when it can apply a list of operations atomically. `:dispose` releases the backend when its controller stops, `:item-key` supplies stable selection identity, and `:provider` names the source in observation reports. Any callback may return `etaf-async` instead of a value.

Check the loading path without a Controller first: `etaf-data-source-load-page` loads and normalizes one page and is also what a prepared `:initial-result` comes from. Then hand the source to `etaf-data-controller`, which owns its lifecycle; keep one owning controller per source. A backend that cannot prove an external write result reports `external-unknown` rather than guessing, and it never implies local rollback. The shipped SQLite backend in etaf-db is the reference implementation, and [Data Sources](data-sources.md) defines the protocol in full.

## Adding an image converter

<!-- index: image converter; preparation -->

An image converter turns a source into an Ebox image character surface. It is a function of the source, the columns and the rows that returns a string of exactly ROWS lines of COLUMNS `▀` characters, each carrying a `face` plist with 24-bit foreground and background colors. Returning nil, signaling, or returning a malformed string declines the source, so the next converter in the list gets it.

Converters are consulted only during preparation. Install one at the front of `ebox-image-converters`, or pass a list with `:converters` to `ebox-image-prepare` for one call. Preparation resolves the source, runs the converters and caches the result; layout and buffer writes only reuse prepared content, which is why an image conversion can never stall a flush. Inspect the result with `ebox-image-info` and `ebox-image-content`, and call `ebox-image-cache-clear` when a converter's behavior changes so cached preparations are not reused. A converter must not mutate its source.

## Exposing an Ebox capability through ETAF

<!-- index: etaf adapter; boundary rule -->

When an application or a catalog component needs a capability that only Ebox has — a measurement, a retained update, viewport control — the capability is exposed as an ETAF interface, and the application uses that interface. This is the ecosystem's boundary rule, and it applies to framework extensions too: an Ebox-prefixed call stays inside ETAF or inside an Ebox-owned package such as etaf-ui's viewport helpers.

The extension goes in five steps. First confirm that no existing ETAF interface already provides the fact. Second, implement the capability in Ebox as a public interface with its own acceptance scenario, including the invariant it must keep — for example, that preparation work does not happen during layout. Third, add the ETAF adapter: it validates its Runtime and Host references before changing anything, routes retained edits through the normal commit so one call produces one publication and one revision, and keeps no parallel copy of Ebox facts. Fourth, add the definition entry and update the affected chapters in both languages, plus the test that the boundary gate runs. Fifth, migrate the callers to the new interface and remove the direct Ebox route.

The retained content and geometry updates are the model: `etaf-runtime-update-host-contents` and `etaf-runtime-update-host-geometries` validate every target first, publish once per call, and advance the revision once, which is exactly the contract an application needs from a high-frequency display surface.

## How a change is verified

<!-- index: public test; acceptance inventory; bounded failure output -->

A maintained test exercises observable inputs, outputs, errors, rollback and lifecycle through the interfaces the package entry declares. It does not test a private helper, an internal data structure, source text, call counts or a retired behavior; fixtures and helpers obey the same rule, and indirection, reflection or fault injection do not grant private access. When a scenario seems to need a private symbol, the fact behind it is moved into a public interface or the test asserts the observable behavior instead — the symbol is never promoted to public API just to keep the test. Every package inventories its maintained Lisp correctness scenarios in `tests/acceptance.json`, one entry per scenario with an observable purpose: `make test` runs exactly that public suite and `make check` adds the structural gate, byte compilation, a fresh entry binding and source signature validation. There is no separate internal suite, because an internal test would assert the implementation rather than the behavior a consumer sees.

The scenarios are ERT tests and run headless. The workspace runner `scripts/run-acceptance.py` serializes runs of one checkout behind an advisory lock: a concurrent run is refused with exit status 75, or waits for up to `--wait SECONDS`. A failing condition can be large or cyclic, so the runner prints it with `--print-length` (default 6), `--print-level` (default 3) and a hard `--max-condition-bytes` cap (default 8192). Two habits keep individual assertions readable: bind the result of a call that returns a large live object — a Runtime, a buffer, a tree — to a local and assert on the local, because ERT captures evaluated arguments; and print framework content with `buffer-substring-no-properties` while binding `print-circle` with print limits, because a live Runtime or backtrace can carry cyclic closures and text properties that `%S` would expand forever. Any Lisp file written for Emacs to load, including a temporary probe, starts with `;;; -*- lexical-binding: t; -*-`.

Headless assertions prove behavior, not appearance or latency, so a visible or interactive change is validated in a real graphical Emacs session: the affected example is opened the way its users open it, the four viewport classes — wide, ordinary, compact and short — are inspected, and a resize during interaction is exercised. Batch runs certify neither rendering nor input latency. The performance scenarios are part of this validation rather than a substitute: `scripts/performance.py` runs a registered scenario in batch mode for operation and CPU cost or in GUI mode for real rendering and input timing, and the rules around it — a baseline before the change, three independent sample sets for a final claim, measurement only on a quiet tree — are described in [Performance Engineering](performance-engineering.md). A failed, missing or incomparable gate stays unverified, including a pre-existing failure, and a run whose checkout changed during the measurement is marked unverified regardless of its numbers. Measurement produces raw evidence, raw evidence stays out of version control, and the compact result is inspected before a specific failure log is opened.

When the framework reports a diagnostic while a test or an example runs — a component validation, a renderer warning, a byte-compilation or loader error — that report is the finding, not noise: it is traced to its owning layer and fixed there, never silenced with `ignore-errors`, a wider `condition-case`, a suppressed warning or an excluded test. In the same spirit, a check is never weakened and a test never skipped to make a failure green; when a check has become obsolete, it is updated to the current contract with its behavioral coverage kept.

The manual is gated the same way. `make -C etaf-manual book-check` verifies the chapter structure, definition-entry signatures against the providers' Commentaries, coverage of the documented packages and vocabularies, links, the public-symbol rule in prose, line discipline and the alignment of the two languages, and its runnable-example acceptance mounts every `:run` example in every language, so an example that fails to evaluate or mount fails the gate. A change to a public interface therefore updates the affected chapters in both languages in the same delivery, which is what keeps the manual a description of the current code rather than a snapshot of an earlier one.

## How a change is delivered

<!-- index: colocated repository; conventional commit; fast-forward -->

Each repository is a Jujutsu repository colocated with Git, with one published branch. Jujutsu owns the working copy: the current commit `@` is the working copy, every command snapshots files into it, and Git's detached `HEAD` is expected. A commit is sealed with `jj commit <paths> -m "…"`, which puts the named paths into a finished change and starts an empty `@`; naming paths seals only your work, so a commit never sweeps up someone else's unfinished changes. A working copy has one writer: run `jj st` before editing, and when `@` already holds changes you did not make, seal only your own paths and coordinate before touching a file you both edit. Parallel work uses an independent `jj workspace add <dir>` checkout, never a Git worktree, and published history is the exception that must be respected: `immutable_heads()` includes remote bookmarks, so a published commit is not rewritten by accident.

A commit is one explainable, independently reviewable and revertible change — one coherent feature, fix, move or documentation update together with its regression coverage and documentation — not a fixed count of files or lines. Unrelated changes are split so each commit stays usable for bisection. Messages follow Conventional Commits: `type(scope): concrete imperative English summary`, with a title of at most 72 characters; after a blank line, the body explains the problem and the resulting behavior or the reason for the change. A `Validation:` line names the commands that were actually run and their results, or says why a check was not run. A breaking change carries both `!` in the title and a `BREAKING CHANGE:` footer that explains the impact and the migration.

Before anything is published, every commit in the publish range is checked and so is the tree it produces: each commit's description is rendered to a file and run through `python3 scripts/check-commit-message.py`; `python3 scripts/check-repository.py --staged` validates the sealed tree that the colocated Git index mirrors; `jj log -r '(<range>) & (conflicts() | divergent() | description(exact:""))'` must print nothing; and `@-..main@<remote>` must be empty, so publishing is a fast-forward. Each repository publishes to its `origin` at `github.com/emacs-taf` and delivers to the `aliyun` mirror at the same checkpoints, with `laycat` kept as a second mirror; the published bookmark is the `branch` recorded in `workspace.json`. Jujutsu does not derive a push remote from tracking, so the remote and the bookmark are always named explicitly: `jj bookmark set main -r @-` followed by `jj git push --remote aliyun -b main` and `jj git push --remote origin -b main`. A provider is published before a consumer that depends on its interface, and an unpublished commit is never force-pushed: when the remote has commits the local branch does not, the unpublished commits are rebased onto the remote and the checks are repeated. When authentication or connectivity prevents a push, the commits stay local and the delivery failure is reported.

At an integrated checkpoint, every repository's published `main` commit is recorded in `workspace.json` together with the checks that were run, which is what makes a combination of revisions reproducible; `python3 scripts/workspace.py status` compares the bookmarks against those recorded revisions — never the working copies — and the integrated checks run on a quiet tree after editing and committing are complete. For history and recovery, `jj log -p <path>` shows one file's history, `jj file annotate <path>` blames a line, and `jj bisect run --range <good>..<bad> -- <command>` bisects a commit range in a separate workspace, because bisection edits the working copy; exit status 125 skips a revision that cannot be tested rather than marking it bad. `jj undo` reverses the last operation, `jj op log` with `jj op restore <operation>` returns the repository to an earlier state, and `jj evolog -p -r <rev>` shows how one change itself was rewritten, which is different from a file's history.

A user-visible change is recorded in the changelog following Keep a Changelog, under a release heading or `Unreleased`, and the manual and the changelog ride with the code: the affected chapters are updated in both languages in the same delivery, the book gate runs as part of the package checks, and a version header change updates every manual passage that names the package and version, because the book gate checks that span against the entry file.

## What every extension shares

<!-- index: extension checklist -->

Whatever the route, an extension is not finished until the same four things are true. The entry Commentary of the owning package lists the new public interfaces, because that Commentary is the authoritative inventory. The manual has a definition entry for each new public interface and the affected chapters updated in both languages, because the book gate checks coverage, signatures and translation structure. The change has an acceptance scenario in the package's `tests/acceptance.json` that exercises the new behavior through public interfaces, no diagnostic the framework reports during it is ignored, and a visible or interactive change has been exercised in a real window at the supported viewport sizes.
