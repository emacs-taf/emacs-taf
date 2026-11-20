# UI Overview

`etaf-ui` is the official catalog of reusable components for ETAF text applications. It adds no new framework concepts: every component is an ordinary Component whose render result is a View built from Hosts, styled through the same cascade, provided the same Theme and driven by the same interaction layer. What the catalog contributes is a set of named, keyboard-operable controls with a uniform contract, so an application composes a complete interface instead of rebuilding buttons, lists, dialogs and grids every time. This chapter defines that shared contract — how inputs are owned, how an entry is written, which keyboard behavior every component promises, how components stay inside the standard line height, how they read theme tokens, and when a definition should use `:view` or `:render`. The following chapters then define each family: [Icons](ui-icons.md), [Containers](ui-containers.md), [Feedback and Status](ui-feedback-and-status.md), [Buttons and Choice Controls](ui-buttons-and-choice-controls.md), [Text Input Controls](ui-text-input-controls.md), [Embedded Native Editors](ui-embedded-editors.md), [Pickers and Menus](ui-pickers-and-menus.md), [Overlays](ui-overlays.md), [Navigation and Collections](ui-navigation-and-collections.md), [Data Display](ui-data-display.md), [Composite Components](ui-composite-components.md), [Panels and Windows](ui-panels-and-windows.md), [Desktop Navigation and Tiling](ui-desktop-navigation-and-tiling.md), [Media and Reactions](ui-media-and-reactions.md), [Grids and Character Surfaces](ui-grids-and-character-surfaces.md), and finally [Gallery and Acceptance](ui-gallery-and-acceptance.md). [Component](components.md) defines the Component model itself, [Component Styles and Themes](component-styles-and-themes.md) the rule list and token mechanism, and [Keyboard](keyboard.md) the key layer that every component relies on.

## Controlled components

<!-- index: controlled input; bind; caller-owned state; reported callback -->

Every interactive component in the catalog is a *controlled* control: the application owns the value, and the component only renders it and reports what the user did. The default interface is a pair of props — a value prop such as `:value` or `:checked` plus a callback prop such as `:on-change`, `:on-press`, `:on-select` or `:on-toggle`. The callback receives the candidate next value or the chosen key, and the application decides whether and how to store it. A component never writes application data and never keeps a second copy of it.

On components that declare `:bind`, it is an alternative to the value/callback pair: the caller passes one existing writable ref. A bound control reads its current value from that ref and writes candidate updates back to it; a later write to the same ref updates every mounted control and every other reader. Because the ref is the caller's, `:bind` and the explicit pair are mutually exclusive: supplying a value or a callback together with a non-nil bind is a rejected call, including an explicit nil. Unmounting releases the control's own handlers and subscriptions without disposing or clearing the caller's ref, and a rejected publication leaves the previous binding target in place. [Reactivity](reactivity.md) defines the write rules in general.

Only genuinely local presentation state belongs to a component. A dropdown menu owns its open flag and its anchor because they exist only for that retained instance, while `etaf-popover` keeps `:open` controlled so the application decides when a surface is visible. Values, selections, expansion sets, window geometry and media playback are always caller-owned; the catalog's callbacks *request* a change, and its names follow that meaning — `:on-close` asks to close, it does not close by itself.

Each prop states whether it accepts a plain value, ref or computed source. Do not infer reactive-source support merely from a similar name: for example, Calendar's `:value` is an integer day, while Range's `:value` accepts a reactive source. Passing `(etaf-value ref)` in a reactive View instead supplies the current plain value and subscribes that View. A supported ref/computed prop retains its source identity; the component may consume it at a render boundary or a retained Host binding as documented in its entry and [Component](components.md).

## Components, Hosts and instances

A catalog component is not a Host: it owns no Ebox node of its own. Its render result is a View — nil, one Host, or several Hosts grouped by a fragment — and the component instance is the unit that survives re-renders, matched by Component and `:key`. An instance keeps its inputs, its Scope with the refs and bindings created during initialization, and its retained children until it stops being rendered or its Runtime is unmounted.

That division decides what a component needs to run. A component that only assembles Hosts and semantic content is stateless and can be rendered by `etaf-render` as well as mounted. A component that declares initialization, bindings or retained state needs a mounted Runtime, because its Scope must have a lifecycle owner; rendering one without a mount signals `etaf-renderer-error`. The catalog follows this rule like any other Component, and its documentation marks the components that need a live Runtime — for example a text input's editing session, or a window whose mode lives in retained properties.

Host identity, slots and attribute fallthrough are ordinary Component rules: a catalog component reads its props, projects the caller's default and named slots, and renders whatever the caller supplied, so a `:class`, `:ref` or `:id` passed to a component call reaches the Host that represents it. The catalog does not wrap its roots in extra containers, so a component that produces a fragment joins the enclosing layout directly.

## Reading a Component entry

A catalog entry starts with its signature and purpose. Arguments explain inputs, defaults and callback payloads; Semantics explains state ownership, slots, focus, events and sizing, with Errors and examples where applicable. The root package Commentary is the supported API inventory and includes a concise Parameters block in each Component record. The [Gallery](ui-gallery-and-acceptance.md) displays that same record beside the live specimen, rather than maintaining another API list. This manual owns the detailed semantics and cross-component explanations.

Component parameters are distinct from public Host attribute fallthrough. Layout, paint, identity and accessibility attributes follow [Component](components.md) and [Hosts](hosts.md); forwarding an attribute to a component's root does not forward it to every nested control. Units are part of the contract: `(px N)` is a pixel length, `(ch N)` a character-width length and `(lh N)` standard text rows; a gesture delta is a pixel pair, not a new ratio or geometry.

Props are regular Component props, so the calling rules of [Component](components.md) apply unchanged: keyword arguments on the call, defaults resolved when a prop is missing, explicit nil distinct from an omitted prop, and a documented error when a prop falls outside its contract. An invalid input is reported at the point where the contract is checked — during validation or during rendering — naming the component and the property, so a failure can be traced to the call that caused it.

## Keyboard and focus

Every catalog component is keyboard operable through ETAF's key layer; a component that cannot be activated by keyboard is not accepted into the catalog. The baseline promise is one tab stop per control: Tab reaches an interactive control, and the arrows plus `C-n`, `C-p`, `C-b` and `C-f` move between the parts of a compound control. Collectors — tabs, segmented and radio selectors, desktop bars, window controls, tables, lists, trees, calendars, breadcrumbs, steps and tile grids — behave as one tab stop entered at their selected or focused item, so a long list does not flood the Tab order. Modal surfaces — dialogs, drawers, popovers, menus and the media viewer — establish a key scope: the keys in scope are the surface's own, Escape requests a close, and closing returns focus to the control that opened it. `?` opens read-only key help listing the keys currently in scope. [Focus](focus.md) defines tab order, group entry and modal scopes, and [Keyboard](keyboard.md) defines `:keys`, direction handling and help.

A component's own key behavior is part of its entry: which keys it adds, what they do, and which keys it reserves. A component that cannot bind a key reports it during validation rather than silently dropping the binding.

## Line height and sizing

The catalog's default is one standard line. A label, button, checkbox, badge, tag, keycap or icon occupies exactly one text row; trailing padding is expressed in row units that do not grow the line, so stacking components in a column keeps a predictable grid and never adds unexpected blank rows. Components with a larger fixed shape say so: a search field is a three-row pill with half a row of surface above and below its text, a text input's visible height follows its `:rows` minimum, and an icon is exactly one row by default and exactly two rows with `:lines 2`, with its size clamped inside those rows so an oversized glyph can never push the layout. Intrinsic dimensions stay intrinsic: tile grid cells and playing cards keep their authored cell size when the containing viewport changes, and reflow happens in the surrounding layout instead of by stretching the control.

The rule matters for positioned content. A window, resizable panel or any other component that positions text inside a canvas shares that canvas's line height, and Ebox rejects a font whose resolved line height exceeds it before publication; a larger CSS font size does not enlarge the canvas. [Boxes and Normal Flow](boxes-and-normal-flow.md) defines how rows and the standard line arise, and the Panels and Windows chapter covers the canvas contract.

## Theme tokens

Catalog components paint through Theme tokens rather than literal colors. A token names a semantic role — a surface, a muted foreground, an accent fill, a status color, a table selection — and the component reads it at the point where the declaration is lowered, so one provided Theme restyles every component in the subtree by re-lowering static rules and retained properties, without re-rendering the tree. [Component Styles and Themes](component-styles-and-themes.md) defines token resolution, provision and the base vocabulary; each catalog chapter defines the tokens of its own family, and the [Theme token table](theme-token-table.md) lists the full vocabulary.

A component always supplies a built-in fallback for every token it reads, so a catalog runs and looks coherent without any Theme; providing a key overrides the fallback for the whole subtree. The fallbacks are the catalog's default light look. A desktop shell additionally reads its own shell tokens, so a window manager can dim or recolor the shell and its pickers independently of the dialogs it keeps crisp. Because tokens resolve per declaration, a token read in a retained Host property or a static rule pins the *theme value*, not the color: switching the provided Theme repaints the same mounted components.

### Application palettes

An application usually owns a handful of colors (a surface, its text, a raised panel, a border, a muted text color and an accent) and wants every catalog component to follow them. `etaf-ui-theme-tokens` maps such a palette onto the catalog's color tokens, so the application provides one Theme instead of listing each `:ui-*` key.

#### Function: etaf-ui-theme-tokens (palette)

Return the catalog Theme tokens for application PALETTE.

**Arguments.** PALETTE is a plist of `#RRGGBB` color roles. `:bg` (the application surface) and `:fg` (its text) are required. The optional roles are `:panel` (raised surfaces, default `:bg`), `:track` (progress and range tracks, default `:panel`), `:border` (lines), `:muted` (secondary text), `:dim` (disabled text, default `:muted`), `:accent` (default `:fg`), `:accent-fg` (text on the accent, default white), `:accent-soft` (selection and tonal fills), and the status roles `:success`, `:warning`, `:danger` and `:info` (default `:accent`), each with a `-bg` and a `-border` variant.

**Semantics.** Omitted roles are derived: `:border` mixes the text 18% into the surface, `:muted` mixes the surface 35% into the text, `:accent-soft` mixes the accent 16% into the surface, a status `-bg` mixes its color 12% and a `-border` 35% into the surface, and the default status colors follow whether `:bg` is light or dark. Each role then fills every token that names it: `:panel` becomes the panel, shell, picker, window title and disabled backgrounds, `:border` every border and divider, `:accent` the primary button, the range fill and the table selection text, and so on. The result contains only colors; spacing and radius tokens keep their catalog defaults.

**Returns.** A fresh Theme plist of `:ui-*` keys, ready to append to the application's own Theme keys and pass to `etaf-theme-provide`. Because the first value of a key wins, a token placed before the result overrides it.

**Errors.** `wrong-type-argument` when PALETTE is not a plist, when it names a role outside the list above, when a value is not a string, or when `:bg` or `:fg` is missing.

```elisp
(etaf-theme-provide
 (append '(:ui-shell-bg "#0B1220")
         (etaf-ui-theme-tokens '(:bg "#101925" :fg "#E5EDF7" :panel "#182332"
                                 :border "#2B3A4E" :accent "#356BB2"))))
```

### Deriving state colors

An application that derives a hover fill, a selection tint or a surface step from its own palette needs one arithmetic on `#RRGGBB` values, not a second palette.

#### Function: etaf-ui-color-mix (from to amount)

Return FROM mixed AMOUNT of the way toward TO.

**Arguments.** FROM and TO are `#RRGGBB` colors, and AMOUNT is a fraction between 0 and 1: 0 returns FROM, 1 returns TO.

**Semantics.** The three channels are interpolated independently and rounded, so the result keeps the perceptual weight of a straight blend. A color written in any other spelling — a named color, a `#RGB` shortcut, `unspecified-bg` — is returned unchanged, which keeps a Theme that names a color usable instead of signaling.

**Returns.** A `#RRGGBB` string, or FROM unchanged when either color is not in that form.

**Errors.** None. A non-number AMOUNT signals `wrong-type-argument` from the arithmetic.

```elisp
;; A hover fill: the surface with 10% of the text color mixed in.
(etaf-ui-color-mix "#FAFAFA" "#383A42" 0.10)  ; => "#E9E9E9"
```

A catalog component derives its own state steps this way rather than asking the caller for a hover color, so a dark Theme and a light Theme both get a fill that keeps the label readable. The catalog's own fallbacks are the reference: 8% for a hover fill, 12% for a resting selected chip, and 4% for a disabled one.

## Choosing between :view and :render

Both authoring frontends of `etaf-define-component` are ordinary choices for a catalog component, and the component's entry describes behavior, not which one it uses. As [Component](components.md) defines, `:view` is the structural language compiled with the definition: each prop name it uses is a tracked read, so a component that only assembles Hosts and semantic content should use it, and a local update can repaint one binding without re-running the whole render. `:render` is ordinary Elisp evaluated in a retained effect; use it when the output depends on a computed value read in Lisp, when nodes must be built programmatically, or when the component must branch on ordinary data before choosing structure. Both receive the same props, slots and scope, and both can mix static rules with Host properties.

The practical rule for authors of new catalog components: start with `:view`; move a component to `:render` only for the reasons above, not because its view is large or its props numerous.

## Errors and recovery

- A prop outside its contract signals `error→ etaf-component-call-error` with the component name, the property, the received value and the expectation, raised through `etaf-check-prop`. Validation and rendering both use this condition, so callers do not need to distinguish the moment a component checked its input.
- A rejected input does not publish: a mounted instance keeps its previously published props and callbacks, and a bound control keeps its previous binding target. It does not undo a business ref the caller already wrote, because that write belongs to the application.
- A malformed definition is a different failure: `error→ etaf-component-definition-error` is raised while a component's definition is expanded or evaluated, and registering a duplicate name outside the intentional redefinition path signals `error→ etaf-component-call-error`.
- A stateful component rendered without a mounted Runtime signals `error→ etaf-renderer-error`, as every Component does. The catalog's entries say when that applies.
- A component that depends on an external facility reports its absence as a `user-error` naming the missing program, not as a component input error, because the call itself was well formed.

**See also.** [Component](components.md), [Component Styles and Themes](component-styles-and-themes.md), [Hosts](hosts.md), [Keyboard](keyboard.md), and [Text Input](text-input.md).
