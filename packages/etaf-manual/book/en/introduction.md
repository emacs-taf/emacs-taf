# Introduction

This is the reference manual of ETAF, a framework for building text applications in Emacs. It describes every public interface of the framework packages: what each function, macro, variable, property and component does, in what order things happen, what can fail and what state a failure leaves. It also explains how the framework works, including data flow, ordering, invariants and cost, so that developers can extend it and diagnose it. All of this is explained through concepts and public interfaces: internal functions and data structures may change in any release, and the manual does not name them.

The manual is organized by subsystem, not by package. A subsystem that spans several packages, such as styles or focus, is described in one place, and each definition entry belongs to exactly one package; the Layers and stability section explains how that owner is determined. It is not a tutorial: it assumes that you know Emacs Lisp and want precise answers.

## Installation

All packages except ECSS require Emacs 29.1 or newer; ECSS alone supports 28.1. The official package.el archive is [https://etaf.top/packages/](https://etaf.top/packages/). Source-only packages are compiled locally by Emacs; using the framework and catalog does not require Git, Python, a system compiler or Pi, and installation does not replace the user's configuration. Native compilation is optional. SQLite additionally requires an Emacs build for which `sqlite-available-p` returns non-nil; the sqlite3 executable alone is not sufficient. Graphical media require a graphical frame and the relevant Emacs image support.

Evaluate the following once, then select the component gallery or another supported target:

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

Thereafter, `M-x etaf-install` reopens installed targets without downloading again. `M-x etaf-install-doctor` checks required and optional capabilities without accessing the network or writing configuration. The [workspace README](https://github.com/emacs-taf/emacs-taf#install-in-an-existing-emacs) lists the available targets and the boundary around external backends. Package.el remains the package manager; use `M-x list-packages` for updates and removal, and restart Emacs after updating loaded code.

The installer rejects conflicting source load paths and already loaded source dependencies rather than silently replacing them. On an installation or entry-loading failure, it removes only packages added by that attempt, keeps older installations and unrelated packages, reports any cleanup failure, and requires a restart before retrying: deleting package files cannot undo Lisp already loaded into the process. Keep source checkouts for development in a separate profile instead of mixing both installations of the same dependency.

## Scope

The manual covers six packages:

| Package | Provides | Depends on |
| --- | --- | --- |
| `ecss` | A CSS cascade engine: selectors, specificity, cascade, inheritance, variables and computed styles | — |
| `ekp` | Knuth–Plass paragraph line breaking, with CJK support | — |
| `ebox` | A retained box tree rendered into buffer text: measurement, box, flex and grid layout, style projection, scrolling, incremental buffer updates and input primitives | `ecss` |
| `etaf` | The application framework: Views, Hosts, Components, reactive state, Context, Runtimes, events, Behaviors, Actions, Resources and Data | `ebox`, `ecss` |
| `etaf-ui` | The official component catalog and its theme tokens | `etaf`, `ebox` |
| `etaf-db` | Database backends for ETAF Data; currently SQLite | `etaf` |
| `etaf-posframe` | Floating panels: any ETAF View in a child frame, with placement, a title bar, a theme toggle and an application registry | `etaf`, `etaf-ui` |

Applications reach Ebox and ECSS only through ETAF, and no other package uses EKP. The manual still describes the public interfaces of these three packages completely, because each can be used on its own: Ebox without ETAF, ECSS with another host, and EKP for ordinary Emacs text each have a part of their own.

The manual does not cover applications built with ETAF, games, the etaf-desktop desktop application or the game kit. The two playgrounds appear only in the chapters on tooling.

The manual documents behavior that is implemented. Where the workspace architecture or the keyboard navigation contract sets a target that the code does not meet yet, the manual says so in one sentence and describes only the current behavior.

## Readers and reading paths

The manual has three kinds of readers. Each can start at the beginning of the listed parts and consult the rest through the [concept index](concept-index.md), the [symbol index](symbol-index.md) and cross-references.

| Reader | Read first | Then, as needed |
| --- | --- | --- |
| Application author: builds an application from Views, components and state | Overview; The ETAF Programming Model | Style; Layout and Rendering; Interaction; Data and Asynchrony; [the UI Component Library](ui-overview.md) |
| Component author: adds reusable components to an application or to the catalog | The same, with the [component styles and themes](component-styles-and-themes.md) chapter of Style | [the overview of the UI Component Library](ui-overview.md); the chapter on incremental updates and publication; the chapter on extending the framework |
| Framework developer: extends ETAF or diagnoses its behavior and performance | The ETAF Programming Model; Layout and Rendering | Framework Internals and Extension; the chapters on the [implementation of styles](style-implementation.md) and of EKP |
| Library user: uses Ebox, ECSS or EKP without ETAF | the part on that package: Using Ebox Directly, ECSS as a General Library or EKP Paragraph Layout | Style; Layout and Rendering |

The chapters of each part are ordered so that a chapter needs only the chapters before it. [Reactivity](reactivity.md) is a good example of the depth of the manual: read it before the chapters on [Components](components.md) and [Runtime](runtime.md).

## Notation

### Terminology

<!-- index: terminology; public interface; internal symbol -->

These terms are used throughout the manual. Each is defined fully in the chapter that owns it.

**Entry file and Commentary record.** Each package has one entry file named after its feature, such as `etaf.el`. The Commentary of that file lists the package's supported interface, one record per symbol, such as `;; Function: etaf-mount (buffer-or-name view &optional options)`.

**Public and internal.** A symbol is public when its package's Commentary lists it. Every other symbol is internal, even when its name has no double hyphen: it may change in any release, and this manual does not describe it.

**View.** An immutable description of user interface: a tree of Host nodes and Component nodes. Write it with the `etaf-view` macro or build it with `etaf-node`.

**Host.** A node kind that ETAF renders directly through Ebox: `text`, `box`, `fragment`, `row`, `column`, `flex`, `grid` and `image`. A Host node's properties are style properties, semantic properties such as `:role`, and event properties such as `:on-press`.

**Component.** A named, reusable unit of View with props, defined with `etaf-define-component`. Each use of a component in a mounted View is an *instance* with its own state and Scope.

**Runtime.** The object that `etaf-mount` creates for a buffer. It renders the View, owns the instance tree and publishes changes to the buffer through Ebox.

**Ref, computed value, effect and Scope.** The objects of the reactive system. A ref holds state, a computed value derives state, an effect reacts to state and a Scope owns effects and releases them together. See [Reactivity](reactivity.md).

**Drain and commit.** After state changes, ETAF *drains*: it runs the queued effects until the state settles. During a drain, each Runtime whose output changed *commits* once, writing the change into its buffer.

**Context.** A value that an ancestor provides with `etaf-provide` and that its descendants read with `etaf-inject`. See [Context](context.md).

**Action.** A named command defined with `etaf-action-define` and invoked with `etaf-dispatch`. An Action receives the Runtime as its first argument. See [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md).

**Behavior.** A reusable set of non-visual Host properties and an optional installer that returns a cleanup function, defined with `etaf-define-behavior` and attached through a Host's `:use` property. See [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md).

**Theme and token.** A Theme maps named values, called *tokens*, to colors and other style values. The component catalog's tokens have names such as `:ui-fg` and `:ui-panel-bg`.

**Style property.** A property that Ebox uses for layout and painting, such as `:padding` or `:font-weight`. ECSS computes the final value of every style property from inline styles, stylesheets and inheritance.

**Ebox node and mount.** Ebox keeps a retained tree of nodes, lays it out and writes it into a buffer. A *mount* connects a tree to a buffer and keeps the two consistent as the tree changes.

### Evaluation, rendering, errors and output

<!-- index: notation; ⇒; ▷; error→; -| -->

Examples use four marks:

| Mark | Meaning |
| --- | --- |
| `⇒` | The form evaluates to the value that follows. |
| `▷` | The View renders as the buffer text that follows. |
| `error→` | Evaluating the form signals the condition that follows, with its data. |
| `-\|` | Evaluating the form writes the text that follows to `*Messages*`. |

Every `;; ⇒` line states the value of the form above it, and the book gate evaluates that form and compares the value. A bare `⇒` line illustrates the outcome of the form above it, usually a buffer or window state, so the gate checks that it follows a complete form and reads as a value, or ends with `; display`, without evaluating anything. When the outcome is an object without a stable printed form, the line describes it and ends with a `; display` comment instead.

```elisp
(etaf-value (etaf-ref 3))
;; ⇒ 3

(etaf-value 5)
;; error→ wrong-type-argument (etaf-reactive-source-p 5)

(etaf-next-tick (lambda () (message "published")))
;; -| published
;; ⇒ nil
```

An example marked as runnable evaluates to a View. The Emacs reader mounts it and lets you interact with it; printed forms of the manual show the rendered text instead:

```elisp :run
(etaf-view (text "Hello"))
```

▷ `Hello`

Each top-level form of an example is evaluated separately with lexical binding, so the forms of one example do not share local variables. Runnable examples name the components they define with a `demo-` prefix.

In signatures, argument names are written in lower case, as Lisp writes them: `(etaf-ref initial-value &key test name)`. In the text, argument names are written in upper case: INITIAL-VALUE, TEST. Signatures use the lambda-list syntax of `cl-defun`:

| Signature element | Meaning |
| --- | --- |
| `&optional` | The arguments that follow may be omitted; they default to nil. |
| `&rest` | The remaining arguments are collected into a list. |
| `&key` | The arguments that follow are keyword arguments, such as `:test`. |
| `(name default)` | The argument defaults to DEFAULT, evaluated when it is omitted. |
| `(name default supplied-p)` | SUPPLIED-P is non-nil when the caller passed the argument. |

### Definition entries

<!-- index: definition entry; entry kinds -->

Every public symbol, Host, property, style property and token has exactly one *definition entry*. An entry starts with a heading that gives its kind, its name and, for callables, its signature:

```markdown
#### Function: etaf-ref (initial-value &key test name)
```

The signature is copied from the entry's Commentary record, and a build check compares it with the code, so the two cannot drift.

Several consecutive headings share the description that follows them. The first paragraph of a description is one sentence that says what the entry is or does. Further paragraphs begin with a label, always in this order:

| Label | Content |
| --- | --- |
| **Arguments.** | What each argument accepts and means. |
| **Semantics.** | What happens, in order, including boundary cases. |
| **Returns.** | The value. |
| **Errors.** | Each condition that can be signaled, written `error→` followed by the condition, its data and when it is signaled. |
| **Example.** | Examples in the notation above. |
| **See also.** | Related entries and sections. |

A short entry may omit labels and say everything in prose.

The kinds of entries are:

| Kind | Names | The name and signature are checked against |
| --- | --- | --- |
| Function | a function | its Commentary record |
| Macro | a macro | its Commentary record |
| Variable | a variable or user option | its Commentary record |
| Hook | a hook variable | its Commentary record |
| Error | an error condition | its Commentary record |
| Component | a component and its props | its Commentary record |
| Host | a Host kind, such as `text` | the Hosts ETAF defines |
| Property | a semantic or event property of Hosts, such as `:role` | the properties ETAF reads |
| Style | a style property, such as `:padding` | the style properties Ebox defines |
| Token | a theme token, such as `:ui-fg` | the tokens of the component catalog |
| Syntax | a form of View syntax, such as `expr` | not checked |

Entries for style properties start with a table of the property's values, its initial value, the nodes it applies to, whether it is inherited, and whether it affects geometry or only painting.

Key bindings are listed in a table of Key, Command and Context in the entry or section that owns the keymap.

### Layers and stability

<!-- index: layer; stability; compatibility -->

Each entry belongs to exactly one package, its *layer*. The layer is not written in the heading. It follows from the code:

| Kind | Layer |
| --- | --- |
| Function, Macro, Variable, Hook, Error, Component | the package whose Commentary lists the record |
| Host, Property, Syntax | `etaf` |
| Style | `ebox` |
| Token | `etaf-ui` |

Every entry is public: it is part of its package's supported interface, and an incompatible change to it is listed with migration instructions in that package's change log.

## Versions

This edition describes `ecss 0.1.0`, `ekp 1.0.1`, `ebox 3.1.3`, `etaf 0.3.5`, `etaf-ui 0.3.4`, `etaf-db 0.1.0` and `etaf-posframe 0.3.0`. The manual is maintained together with the code: a build check fails when a public interface of a package the manual covers has no entry, when a signature differs from the code, when the text names a symbol that is not public, or when a version above differs from the package.

## Reading this manual in Emacs

<!-- index: etaf-manual package -->

The `etaf-manual` package provides the manual as data. `etaf-manual-book` returns the parsed manual in a language selected by `etaf-manual-language`, `etaf-manual-definition` finds the entry of a symbol, and `etaf-manual-example-view` evaluates a runnable example to a View that `etaf-mount` can display:

```elisp
(plist-get (etaf-manual-definition 'etaf-ref) :chapter)
;; ⇒ reactivity
```

This edition ships a generated [concept index](concept-index.md) and [symbol index](symbol-index.md). `M-x etaf-manual-open` opens the reader in Emacs, with Info-style section navigation, definition cards, runnable examples and symbol lookup; `M-x etaf-manual-lookup` opens a symbol's entry from any buffer. The same sources are published as a website at [https://etaf.top](https://etaf.top), English at the root and Simplified Chinese under `/zh-cn/`.
