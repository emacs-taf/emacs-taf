# Ecosystem and Layers

ETAF consists of six packages, layered so that each kind of fact has exactly one owner. This chapter describes what a text application is, what each package provides, how the packages depend on each other, where the public interface of each package ends, which package owns which facts, and the path that a change of state takes to the buffer. Later chapters describe each of these subjects in detail.

## Text applications

<!-- index: text application; buffer as canvas -->

A text application draws its whole user interface into an ordinary Emacs buffer. The buffer holds text with text properties: faces for colors and fonts, and display properties for images and for horizontal alignment. Keymaps installed in the buffer deliver keys and mouse events to the interface. Emacs commands that read text, such as motion and search, work on it as on any other buffer.

The buffer is a canvas with two kinds of units. Horizontal geometry is measured in pixels: Ebox measures the text it lays out and fills the remaining width with spaces of an exact pixel width, so proportional fonts and wide CJK characters line up. Vertical geometry is measured in lines: the height of every box is a whole number of lines.

The application does not edit the buffer. It describes its interface as a View, keeps its state in reactive sources and changes that state; the framework then rewrites the lines whose content changed and leaves the other lines untouched.

The same buffer works in graphical and in terminal frames. A terminal frame draws a simpler picture, for example square corners and text in place of images; [Graphical and terminal frames](installation-and-loading.md#graphical-and-terminal-frames) lists what changes.

## The packages

<!-- index: package responsibilities; ecss; ekp; ebox; etaf; etaf-ui; etaf-db -->

| Package | Owns | Leaves to other packages |
| --- | --- | --- |
| `ecss` | Selectors and specificity, stylesheets, origins and importance, cascade layers, CSS-wide values, custom properties and `var()`, inheritance, computed styles and the provenance of each computed value | Text properties, layout, reactive updates and buffers |
| `ebox` | The retained tree of text, box, row, column, flex, grid and image nodes; computed styles through ECSS; text measurement; box, flex and grid layout; scrolling and the viewport; line composition and direct buffer updates; focus, pointer targets, keymaps, dragging and text input sessions | Components, application state and reactivity |
| `etaf` | View and Component syntax, reactive state and bindings, the lifetime of Runtimes, Context, Themes, Behaviors, Actions, Data and Resources, the scoped keyboard layer, and queries about committed Hosts | Layout, hit testing, focus order and buffer writes, which it delegates to Ebox |
| `etaf-ui` | The official component catalog: reusable components with their keyboard behavior, and the theme tokens they read | Layout, focus and hit testing: its components are ordinary ETAF components |
| `etaf-db` | Database backends for the Data Source contract of ETAF; currently SQLite | Data Controllers, which belong to ETAF |
| `etaf-posframe` | Floating panels: a child frame per panel, its placement, title bar, theme toggle, border and its application registry | Panel content, which is an ordinary ETAF View; frame creation, which Posframe owns |
| `ekp` | Knuth–Plass optimal line breaking for paragraphs of mixed CJK and Latin text, with kinsoku rules, hyphenation and pixel-accurate justification, in Emacs Lisp and optionally in a C module | — |

ECSS and Ebox can be used without the packages above them. Ebox suits a package that needs layout and buffer rendering but no components or reactive state. ECSS computes styles for any program that registers its own property vocabulary, whether the result drives text, a widget or a diagnostic. EKP lays out ordinary Emacs text; none of the other packages uses it.

### Dependencies

<!-- index: dependency direction; Package-Requires -->

Each package declares its requirements in the `Package-Requires` header of its entry file; [Versions and Migration](versions-and-migration.md#versions) lists the version combination this edition documents and the minimum each package requires.

The dependencies point in one direction. In the following figure, an arrow points from a package to the packages that require it:

```text
ecss ──▶ ebox ──▶ etaf ──┬──▶ etaf-ui ──▶ etaf-posframe
                         └──▶ etaf-db
ekp
```

No package requires a package above it, and applications sit above `etaf-ui`, `etaf-db` and `etaf-posframe`. ETAF also requires ECSS directly, so that resolving Theme tokens can keep values whose computation ECSS defers to the cascade.

Applications use ETAF and the component catalog and do not call Ebox. When an application needs a capability that only Ebox has, such as a measurement or control of the viewport, ETAF publishes an interface for it, and the application uses that interface.

## Public interfaces

<!-- index: public interface; entry file; Commentary record; internal symbol; lisp directory -->

Each package has one entry file in its repository root, named after the feature it provides, such as `etaf.el`. The implementation lives in files under the `lisp/` directory. Loading the entry file adds that directory to `load-path` and loads the implementation, so a program requires only the entry feature:

```elisp
(require 'etaf)
```

A program never requires a file under `lisp/`. Those features are internal: their names and the way the implementation is divided among them may change in any release.

The Commentary of the entry file is the authoritative list of the package's supported interface. It contains one record for each public function, macro, variable, hook, error condition and component, followed by the description of that interface:

```elisp
;; Function: etaf-mount (buffer-or-name view &optional options)
```

A symbol that the Commentary does not list is internal, even when its name has no double hyphen, and so is every feature and file under `lisp/`. [Module Map](module-map.md) describes what those modules are responsible for, but not their symbols. Calling an internal function, reading an internal variable, loading an internal file and redefining an internal symbol are all unsupported, including through a symbol computed at run time.

Besides the records, the packages publish vocabularies that Views and stylesheets use by name: ETAF publishes the Host kinds and their properties, Ebox the style properties, and the component catalog its theme tokens. They are public in the same way as the records, and each has a definition entry in this manual. [Layers and stability](introduction.md#layers-and-stability) describes how changes to public interfaces are recorded.

## Authoritative owners

<!-- index: authoritative owner; single source of truth -->

Each kind of fact has one owner. Other packages ask the owner through its public interface instead of keeping a copy, so two packages never disagree about the same fact:

| Fact | Owner |
| --- | --- |
| The winning declaration and the computed value of a style property, including inherited values and variables | `ecss` |
| The node tree, geometry, line composition, which buffer text belongs to which node, focus order, the target of a pointer event, dragging, scrolling and text input sessions | `ebox` |
| Application state, component instances and their Scopes, Context, Themes, Actions, Data and Resources | `etaf` |
| The meaning of each control, such as what activating a button or a checkbox does | `etaf-ui` |
| Database storage | `etaf-db` |
| Business state | the application |

These consequences follow, and they explain much of the behavior described in later chapters:

- ETAF keeps a map from Hosts to Ebox nodes, so that it can route events and answer queries, but it keeps no layout, hit testing or focus state of its own. Ebox answers a geometry query from its current layout.
- Visible changes reach the buffer only through Ebox. Neither ETAF nor an application writes text into a mounted buffer.
- A Host property bound to reactive state is not a second copy of that state: when the state changes, the property follows it.
- When output is wrong, the owner of the wrong fact is the place to look: a wrong color is a question for the cascade, a wrong position for layout, and a stale value for the dependencies of the binding that shows it.

## The path of an update

<!-- index: update path; mount; flush -->

Every change to a mounted interface takes the same path, from a write to the buffer:

```text
write             drain                  node updates           flush                buffer
ref, Action,  ─▶  dirty effects     ─▶   properties, text  ─▶   style, layout,  ─▶   changed lines
Data              run                    and child lists        line composition     rewritten
```

1. **Mounting.** `etaf-mount` instantiates the View once. It creates a retained tree that keeps the identity of each part of the View and an Ebox node for each Host, and the first flush writes the whole buffer. The static parts of the View are built once and never computed again. Each dynamic part, such as a property value computed by Lisp, a text written as `(expr FORM)`, a conditional or a list, becomes a binding: an effect tied to the part of the tree it updates.
2. **Writing.** Application code changes state: it writes a ref, dispatches an Action that writes one, or receives new Data. The bindings that read the changed state become dirty, and no others.
3. **Draining.** ETAF runs the dirty effects in phase order, as [the path of a write](reactivity.md#the-path-of-a-write) describes. A property binding sets the properties of its Ebox node, a text binding sets its text, and a conditional or a list patches only its own children; keyed children keep their nodes and move. When a component's props change, only the bindings that read them run again. A component written with a render function computes its whole output again, and that output is patched into the same retained tree.
4. **Flushing.** Each Runtime whose nodes changed commits once. Ebox computes the styles of the changed nodes through ECSS and lays out the tree for the current viewport, recomputing only the boxes whose content or constraints changed; a box of fixed size stops a change from propagating to its ancestors. It then composes the lines, turns the changed regions into line edits and rewrites only those lines.
5. **Settling.** Post effects run, and then the functions scheduled with `etaf-next-tick`.

Input enters the same loop. Ebox resolves an Emacs key or mouse event to the focused or targeted node, and ETAF maps that node to its committed Host and calls the Host's handler inside a batch. The handler writes state, and steps 2 to 5 follow once, when the batch ends.

The cost of an update therefore grows with the number of changed bindings and changed lines, not with the size of the View. The chapter that traces one update, in the part Framework Internals and Extension, follows a single write through each of these steps.
