# Module Map

This part explains how the documented packages are implemented and how to extend them, using concepts and public interfaces. This chapter is its map: which source modules each package has, what each one is responsible for, and which direction its dependencies point. It defines no interfaces of its own — it names the files that implement the interfaces defined in the earlier parts.

## How a package is organized

<!-- index: entry file; module; load path; internal feature -->

Every package has one entry file in its repository root, named after the package: `etaf.el`, `ebox.el`, `ecss.el`, `ekp.el`, `etaf-ui.el` and `etaf-db.el`. The entry adds the package's `lisp/` directory to `load-path`, loads the implementation modules in a fixed order, and owns the authoritative Commentary. A program adds the repository root to `load-path` and requires the entry; it never requires a file under `lisp/`. [Ecosystem and Layers](ecosystem-and-layers.md#public-interfaces) states the rule and its consequence: a feature and a symbol that the entry Commentary does not list are internal, even without a double hyphen.

The modules below `lisp/` are private implementation files. This chapter describes what they are responsible for, not what they contain: their symbols, data structures and internal functions are outside the manual, and the tables give no way to call them. A module name can change in any release, so nothing outside the package should depend on the division.

The tables read as follows. *Module* is the file path in the repository. *Responsibility* is the kind of work the module owns. *Depends on* lists the modules the file loads directly, limited to the documented packages; Emacs's own libraries and modules that are loaded indirectly are not repeated. Dependencies point downward: a module may load a lower layer or a module in its own layer that is closer to the bottom, never a higher one. Each package's `docs/architecture.md` explains the rationale of its division in more detail.

## The ECSS modules

<!-- index: ecss-selector.el; ecss-cascade.el; ecss-file.el -->

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `lisp/ecss-selector.el` | Selector parsing, matching and specificity | — |
| `lisp/ecss-cascade.el` | Style schemas, cascade and computed values | `lisp/ecss-selector.el` |
| `lisp/ecss-file.el` | Reading `.ecss` rule files into the structures the cascade consumes | `lisp/ecss-cascade.el` |

The selector module is the bottom of the package: it knows nothing about styles or rules. The cascade module uses it to match rules and owns the schema, the origins and the computation of values. The file module is a reader on top: it turns source text into rules and hands them to the cascade. This is the smallest module set of all packages and the one every other package builds on.

## The Ebox modules

<!-- index: ebox-size.el; ebox-measure.el; ebox-style.el; ebox-node.el; ebox-image.el; ebox-layout.el; ebox-flex.el; ebox-buffer.el; ebox-interaction.el; ebox-viewport.el; ebox-file.el -->

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `lisp/ebox-size.el` | Validation and resolution of `(unit number)` lengths and size functions | — |
| `lisp/ebox-measure.el` | Pixel measurement, text-unit segmentation, display spaces and display twins | — |
| `lisp/ebox-style.el` | Style schema, aliases, validators, shorthand expansion and ECSS scopes | `lisp/ebox-size.el`, ECSS |
| `lisp/ebox-node.el` | Retained node records, author properties, the selector adapter and computed styles | `lisp/ebox-measure.el`, `lisp/ebox-size.el`, `lisp/ebox-style.el`, ECSS |
| `lisp/ebox-image.el` | Image preparation, the converter protocol and the raster cache | `lisp/ebox-measure.el` |
| `lisp/ebox-layout.el` | Text, box, row, column and positioned layout, line composition and edit planning | `lisp/ebox-node.el`, `lisp/ebox-image.el` |
| `lisp/ebox-flex.el` | The flex and grid algorithms | `lisp/ebox-node.el`, `lisp/ebox-size.el`, `lisp/ebox-layout.el` |
| `lisp/ebox-buffer.el` | Mounts, the dirty queue, flush orchestration, buffer writes and geometry queries | `lisp/ebox-node.el`, `lisp/ebox-layout.el`, `lisp/ebox-flex.el` |
| `lisp/ebox-interaction.el` | Keymaps, focus, activation, drag, input sessions and scrolling | `lisp/ebox-node.el`, `lisp/ebox-layout.el`, `lisp/ebox-buffer.el` |
| `lisp/ebox-viewport.el` | The window-size bridge and settled refit scheduling | `lisp/ebox-buffer.el` |
| `lisp/ebox-file.el` | `.ebox` source reading, companion loading and preview | `lisp/ebox-node.el` |

The two pure modules at the top of the table — sizes and measurement — do not know about nodes, mounts or buffers. Nodes depend on them and on styles; layout depends on nodes and images; the mount layer depends on nodes and layout. Interaction is layered above mounted buffers, and the viewport bridge above the mount layer only requests a refit. One deliberate soft cycle deserves a note: the layout module calls the flex and grid algorithms through forward declarations and the entry loads the layout module before the flex module, so the large layout core does not have to load the flex and grid details it dispatches to.

## The ETAF modules

<!-- index: etaf-view.el; etaf-runtime.el; etaf-reactive.el; etaf-component.el -->

ETAF has the largest module set. Its core is the authoring model; the Runtime is the hub that ties the model to Ebox; the remaining modules are capabilities layered on the Runtime.

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `lisp/etaf-view.el` | The structural View language shared by Hosts and Components | Ebox |
| `lisp/etaf-compiler.el` | Compiling supported topology into embedded blueprints | `lisp/etaf-view.el` |
| `lisp/etaf-reactive.el` | The reactive graph: refs, computeds, effects and Scopes | — |
| `lisp/etaf-component.el` | Component definitions, instances, bindings and setup | `lisp/etaf-view.el`, `lisp/etaf-compiler.el`, `lisp/etaf-reactive.el`, ECSS |
| `lisp/etaf-context.el` | The inherited provide/inject environment | `lisp/etaf-reactive.el` |
| `lisp/etaf-behavior.el` | Reusable Behavior bundles of semantic attributes and setup | `lisp/etaf-reactive.el` |
| `lisp/etaf-controlled-behavior.el` | Controlled Behavior variants for application-owned geometry | `lisp/etaf-behavior.el` |
| `lisp/etaf-observer.el` | The observation port scoped to one dynamic operation | — |
| `lisp/etaf-runtime.el` | Mounting, the retained segment tree, commits and Host maps | `lisp/etaf-view.el`, `lisp/etaf-component.el`, `lisp/etaf-reactive.el`, `lisp/etaf-behavior.el`, `lisp/etaf-context.el`, `lisp/etaf-observer.el`, Ebox |
| `lisp/etaf-app.el` | Application buffers: canvas, theme face, fitting and single close | `lisp/etaf-runtime.el`, `lisp/etaf-reactive.el`, Ebox |
| `lisp/etaf-events.el` | Runtime event entry points into Host callbacks | `lisp/etaf-runtime.el`, `lisp/etaf-reactive.el`, Ebox |
| `lisp/etaf-actions.el` | Named Actions and their dispatch | `lisp/etaf-runtime.el`, `lisp/etaf-reactive.el` |
| `lisp/etaf-keys.el` | Host key tables, help and hint keys | `lisp/etaf-runtime.el`, `lisp/etaf-events.el`, `lisp/etaf-regions.el`, `lisp/etaf-reactive.el`, Ebox |
| `lisp/etaf-regions.el` | Region declarations and region navigation | `lisp/etaf-runtime.el`, `lisp/etaf-events.el`, Ebox |
| `lisp/etaf-viewport.el` | Nested viewport regions and settled refit | `lisp/etaf-runtime.el`, `lisp/etaf-component.el`, `lisp/etaf-events.el` |
| `lisp/etaf-async.el` | The asynchronous operation shared by Resource and Data | `lisp/etaf-reactive.el` |
| `lisp/etaf-process.el` | Run-to-completion subprocesses for command-line backends | — |
| `lisp/etaf-resource.el` | Loaded resource values and their cleanup | `lisp/etaf-async.el`, `lisp/etaf-observer.el`, `lisp/etaf-reactive.el` |
| `lisp/etaf-data.el` | The reactive data controller over explicit source capabilities | `lisp/etaf-async.el`, `lisp/etaf-observer.el`, `lisp/etaf-reactive.el` |
| `lisp/etaf-list-cache.el` | The stale-while-revalidate list cache | — |
| `lisp/etaf-animation.el` | Time-driven refs for transitions and animations | `lisp/etaf-reactive.el` |
| `lisp/etaf-performance.el` | The optional performance recorder | `lisp/etaf-runtime.el` |
| `lisp/etaf-video-source.el` | Video source normalization, probing and frame filtering | — |
| `lisp/etaf-video-audio.el` | The audio sidecar of a playback session | `lisp/etaf-video-source.el` |
| `lisp/etaf-video-session.el` | The playback session: frame producer, sidecar and timer | `lisp/etaf-video-source.el`, `lisp/etaf-video-audio.el` |
| `lisp/etaf-video-component.el` | The `etaf-video` Component | `lisp/etaf-video-source.el`, `lisp/etaf-video-session.el`, `lisp/etaf-video-audio.el`, `lisp/etaf-component.el`, `lisp/etaf-reactive.el`, `lisp/etaf-runtime.el` |

The Runtime is required by every capability module and requires none of them, which is what makes Actions, keys, regions, viewport regions and the performance recorder optional layers rather than parts of the core. The video modules form their own small stack: source, audio sidecar, session and finally the Component. The entry loads all of them, so requiring `etaf` loads the whole framework.

## The EKP modules

<!-- index: ekp-layout.el; ekp-buffer.el; ekp-hyphen.el; ekp-utils.el -->

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `lisp/ekp-utils.el` | Font handling, measurement helpers and the native module build and load | — |
| `lisp/ekp-hyphen.el` | Liang hyphenation patterns and dictionaries | — |
| `lisp/ekp-layout.el` | The box, glue and penalty model, the break search, layout and rendering | `lisp/ekp-utils.el`, `lisp/ekp-hyphen.el` |
| `lisp/ekp-buffer.el` | Interactive region and buffer justification and the auto mode | `lisp/ekp-layout.el` |

EKP is independent of the other packages: its two bottom modules are pure and its layout module is the only user of them. The buffer module is the interactive handle: region and buffer commands, the minor mode, protected regions and diagnostics all live there. [Implementation](ekp-implementation.md) describes the pipeline these modules implement.

## The catalog and storage packages

<!-- index: etaf-ui; etaf-db; component family -->

The component catalog is divided by component family. Most families load the basic module, which owns the simple controls and the shared style conventions; the icon, input, selection, surface, table and navigation families build on it, and the advanced, media and reactions modules compose those. The storage package is one module that registers a Data backend.

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `lisp/etaf-ui-style.el` | Shared style helpers and the theme token defaults | ETAF |
| `lisp/etaf-ui-svg.el` | SVG parsing helpers used by the icon family | — |
| `lisp/etaf-ui-basic.el` | `etaf-label`, `etaf-button`, `etaf-checkbox` and `etaf-panel` | `lisp/etaf-ui-style.el` |
| `lisp/etaf-ui-icon.el` | `etaf-ui-icon` and the icon set | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-feedback.el` | Badge, divider, progress, alert, statistic, empty, skeleton, card, avatar, timeline, tag and kbd | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-selection.el` | Radio, switch, segmented, slider and range | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-input.el` | Menu, select and number input | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-field.el` | Text input and search field | `lisp/etaf-ui-basic.el`, `lisp/etaf-ui-icon.el`, `lisp/etaf-ui-input.el` |
| `lisp/etaf-ui-editor.el` | Embedded native editor helpers | — |
| `lisp/etaf-ui-surface.el` | Popover, dialog, tooltip, toast, dropdown menu, context menu and drawer | `lisp/etaf-ui-feedback.el`, `lisp/etaf-ui-icon.el`, `lisp/etaf-ui-input.el`, Ebox |
| `lisp/etaf-ui-navigation.el` | Tabs, accordion, breadcrumb and steps | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-table.el` | Table and list | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-data.el` | Data grid and pagination | `lisp/etaf-ui-table.el` |
| `lisp/etaf-ui-advanced.el` | Date picker, tree, calendar and command palette | `lisp/etaf-ui-input.el`, `lisp/etaf-ui-navigation.el`, `lisp/etaf-ui-surface.el`, `lisp/etaf-ui-table.el` |
| `lisp/etaf-ui-media.el` | Media viewer | `lisp/etaf-ui-icon.el`, `lisp/etaf-ui-selection.el`, `lisp/etaf-ui-surface.el` |
| `lisp/etaf-ui-reactions.el` | Reactions | `lisp/etaf-ui-icon.el`, `lisp/etaf-ui-surface.el` |
| `lisp/etaf-ui-desktop.el` | Taskbar, workspace bar, launcher, switcher, splitter and pane resizer | `lisp/etaf-ui-basic.el`, `lisp/etaf-ui-style.el`, `lisp/etaf-ui-surface.el` |
| `lisp/etaf-ui-window.el` | Window chrome, window controls and resizable panel | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-tile-grid.el` | Tile grid | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-text-grid.el` | Text grid | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-playing-card.el` | Playing card | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-sqlite-store.el` | The SQLite Data source | ETAF, Emacs's `sqlite` support |

The catalog's three helpers that need a fact the engine measures — the viewport size used to size a surface or a field, the input commands a field must forward, and the pixel width a selection helper compares — read that fact from Ebox's public viewport and measurement interfaces rather than copying the measurement. Every other catalog dependency goes to ETAF.

## Keeping the map accurate

<!-- index: module map; architecture document -->

This map is descriptive. The supported interfaces remain those in each entry file's Commentary, and [Public interfaces](ecosystem-and-layers.md#public-interfaces) defines what that means for consumers. When a package adds, splits, merges or moves a module, the change updates this chapter and the package's `docs/architecture.md` in the same delivery, because both describe the same division from different readers' points of view: this chapter the whole ecosystem at a glance, the package document the rationale of one package.
