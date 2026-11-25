# ETAF UI Architecture

This document is the maintainer contract for the implemented component catalog. It explains ownership, dependency direction, composition and invariants.  User recipes live in the [ETAF Reference Manual](https://etaf.top/ui-overview/); the authoritative public API list is the Commentary of [`../etaf-ui.el`](../etaf-ui.el).

## 1. Responsibility and boundary

`etaf-ui` is the official catalog of reusable ETAF Components.  It owns:

- registered component names, their props, slots and public callbacks;
- visual defaults through Theme tokens, including derived hover, selection and status colors;
- the keyboard model of composite controls: one Tab stop, arrows inside it and modal scopes closed by Escape;
- shared primitives that several components build on, such as cell grids, tables, sheets, selection, fields and surfaces;
- the Gallery that presents live specimens and copies runnable examples.

It does not own application state, application policy or a second widget model. A Button, Checkbox, DataGrid or Window is an ordinary ETAF Component with the same View, props, slots, events and Data contracts as application code.  There is no parallel control tree, no separate event system and no hidden buffer text state.

```text
ecss → ebox → etaf → etaf-ui → applications
```

`etaf-ui` consumes ETAF public APIs.  Ebox is the engine behind ETAF and stays internal; a gap in a lower layer is exposed through ETAF first, never by calling Ebox from a catalog component.

## 2. Composition model

Components are declared with `etaf-define-component` and registered under their exact public names (`etaf-button`, `etaf-panel`, `etaf-data-grid`, ...).  They compose each other:

| Layer | Examples | Owns |
| --- | --- | --- |
| Primitives | `etaf-ui-cell-line`, `etaf-ui-text-grid`, `etaf-ui-table` | cell geometry, rows, columns, identity keys |
| Controls | button, checkbox, field, editor, number input, selection | one interactive surface and its keyboard behavior |
| Composites | data grid, sheet, calendar, tree, tabs, steps | state presentation over primitives |
| Surfaces | popover, dropdown menu, dialog, drawer, window | modal scope, placement request, dismissal |
| Desktop chrome | taskbar, launcher, switcher, window shell | presentation of a desktop model owned by the application |
| Content | media, markdown, icons, SVG | rendering of content that is not a control |

State is controlled by the caller through refs and props, or kept in component local refs when it is presentation state.  A composite does not copy a row, selection or controller into a second authoritative store; it reads the ETAF Data Controller, refs or props it was given.

## 3. Style and theme

Every component reads its colors from Theme tokens.  Hover, selected and active fills are derived from the surface and text colors of the current palette; a component never carries a fixed light-only literal.  Text placed on a derived surface is mixed toward the readable extreme, and every derived state is at least as readable as its resting state.

A selected or active control keeps its selected paint and does not add a hover fill.  Hover belongs to unselected targets only.  This is one rule shared by the catalog, not a per-component exception.

Type size comes from the user's Emacs.  Catalog components never set `:font-size`; hierarchy uses color, weight, spacing and position.  Icons come from faces and text properties, not from application-built images; a shape no font can draw becomes one catalog component.

## 4. Keyboard, focus and help

Each composite is one Tab stop, entered at its selected item.  Arrows and `C-n`/`C-p`/`C-b`/`C-f` move inside it; `RET` activates the focused target. Dialogs, drawers, popovers and the media viewer are modal key scopes: Tab and arrows stay inside, Escape dismisses the innermost layer.  `?` opens read-only help listing the keys in scope.

Focus, hit testing and the keymap are owned by ETAF and Ebox.  A component requests focus and declares keys; it does not install a competing global map or scan the buffer for its own targets.

## 5. Data and asynchronous state

`etaf-data-grid` and the pagination components adapt an ETAF Data Controller onto Table and Button.  They show idle, loading, refreshing, cancelled, error and empty states, and keep accepted rows interactive while a refresh or a failure is shown above them.  The Controller owns query, page, items, status, errors and reconciliation; the component only presents that state.

A component that starts asynchronous work owns its cancellation and cleanup through ETAF's lifecycle.  Unmounting or removing the component releases what it started; a late reply must not publish into a removed target.

## 6. Gallery

`M-x etaf-ui-gallery-open` renders the catalog from the installed entry.  Usage panels are built at runtime from the Commentary records: signature, parameter defaults, constraints, callback arguments and a runnable example shared with the live specimen.  There is no separate API catalog to drift from the code.

The Gallery uses local data only.  It must remain usable offline and must not make a network or storage request while a View is mounting.

## 7. Invariants

- Every public component is an ordinary ETAF Component; no second control model.
- Catalog code calls ETAF public APIs only.
- State is read from refs, props, Data Controllers or local presentation refs; no authoritative copy is kept in buffer text.
- Colors come from Theme tokens; state fills are derived and keep labels readable; selected controls suppress hover.
- Type size is inherited from the user's Emacs.
- A composite is one Tab stop; modal scopes close on Escape in order.
- Icons, borders and dividers are drawn with faces and text properties, not application-built images.
- The Gallery metadata comes from the entry Commentary, so a public interface and its usage panel cannot diverge.
