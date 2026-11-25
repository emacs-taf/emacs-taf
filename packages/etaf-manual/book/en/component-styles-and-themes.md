# Component Styles and Themes

<!-- index: component styles; Theme; theme token; palette; hover style -->

A Component owns its default appearance through a static rule list and paints through the inherited Theme. The rule list is written with the same declaration grammar as any other style input, and `&` scopes it to the Component's roots. A Theme is a Context value that supplies Host defaults and named tokens; tokens let a static rule read the current Theme without becoming an inline dynamic property. This chapter defines the rule format, the runtime style replacement hook, state and hover styling, Theme provision and palette resolution, the token vocabulary and the moment a token resolves. [The Style System](style-system.md) defines the cascade and [Values](values.md) the value grammar; [Host](hosts.md) defines the properties the rules declare.

## Rules and roots

<!-- index: :styles; static rule list; component scope; rule specificity -->

The `:styles` clause of `etaf-define-component` is a static, ordered rule list without a wrapper: `((SELECTOR PROPERTY VALUE ...) ...)`. Its values are style data — a literal `(1 2)` or `bold` needs no quote — and the rules are compiled against the Ebox schema when the Component is defined, so an invalid property or value fails the definition.

The rules of one Component form one scope around its View. `&` and `:scope` match each Component root, including every root when a Component renders a fragment or a forest; an ordinary selector is rewritten to a strict descendant of the root, so `&.selected` styles a root itself while `.selected` styles owned descendants only. Rules of a parent Component do not reach into a nested Component's internals, and content supplied through a caller slot keeps the caller's scope. Inside one rule list, later rules win ties.

The rules enter Ebox at author origin, under the same cascade as inline Host properties: normal inline declarations outrank normal Component rules and important rules can override normal inline values. A nil Host property is omitted rather than declared. [Selectors](selectors.md) defines the selector language and the state model.

## Replacing styles at runtime

<!-- index: runtime style replacement; stylesheet reload -->

A preview or authoring tool can replace a Component's rule list without redefining the Component.

#### Function: etaf-component-set-styles (name styles)

Replace the static style form for Component NAME with STYLES.

**Arguments.** NAME is a registered Component name. STYLES uses the same `((SELECTOR PROPERTY VALUE ...) ...)` contract as `etaf-define-component`.

**Semantics.** STYLES is validated immediately against the Ebox schema, exactly like the `:styles` clause of a definition. On success it becomes the Component's rule list; the next mount or render lowers the new rules, while already mounted runtimes are not flushed implicitly, so their current paint stays until they commit again. The replacement is visible to every instance that renders afterwards.

**Returns.** STYLES.

**Errors.** `error→ etaf-component-definition-error` when NAME is not a registered Component, or when STYLES is not a valid rule list; the message names the Component and the rejected part.

**Example.**

```elisp
(etaf-component-set-styles
 'styled-card '(("&" :background-color "#1F2937")))
```

**See also.** the `:styles` clause in [Component](components.md).

## State styles and hover

<!-- index: state selector; selected class; hover style -->

State styling is selector styling: a rule such as `&.selected` or `&:disabled` matches the derived or authored state of a root, as [Selectors](selectors.md) describes. Components commonly carry an authored state class (`selected`, `disabled`, `active`) and switch it from a prop, which keeps the style static and the state on the retained Host.

Hover is transient paint, not a retained visual state: a Host declares `:hover-style` with a plist of paint properties and Ebox merges them over the node's computed paint while the pointer is over it, so the fill keeps the Host's radius and padding and the label keeps its contrast; rendered output carries the same declarations as a native mouse face. `:hover-content` can replace one line of text the same way. Both are semantic properties of Hosts, defined in [Host](hosts.md). A `:hover-style` value may contain deferred Theme tokens: ETAF resolves them together with the rest of the instance's styles, because an unresolved token would be an invalid face attribute.

The catalog derives a hover fill when the Theme names none. Buttons and menu rows read `:ui-button-primary-hover-bg`, `:ui-button-secondary-hover-bg`, `:ui-button-ghost-hover-bg` or `:ui-accent-soft-bg` when the application provides them; a Button given its own `:bgcolor` derives its hover fill from that surface instead, so a custom chip never hovers in its resting color. Otherwise the catalog lightens a dark surface and darkens a light one, so a dark palette keeps its light text readable instead of inheriting a light tint from the fallback palette. Application hover styles follow the same rule: read the fill from the Theme or derive it from the Theme's own colors, and check the pointer in both palettes.

```elisp :figure Component rules read the Theme: a provided token paints the chips and a state class switches one to the disabled colors
(etaf-define-component demo-theme-states ()
  :setup (etaf-theme-provide '(:chip-bg "#0F766E" :chip-fg "#ECFDF5"))
  :styles (("& .chip" :background-color (etaf-theme-token :chip-bg "#334155")
                     :color (etaf-theme-token :chip-fg "#F8FAFC"))
           ("& .chip.muted" :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
                            :color (etaf-theme-token :ui-disabled-fg "#687386")))
  :view
  (row :item-gap '(ch 1)
       (box :class "chip" :padding '((lh 0) (ch 1)) (text "在线"))
       (box :class "chip muted" :padding '((lh 0) (ch 1)) (text "离线"))))
(etaf-view (demo-theme-states))
```

## Providing a Theme

<!-- index: Theme provision; Host defaults; UA origin -->

A Theme is an ordinary Context value under the key `theme`. It is a property plist that mixes two kinds of entries: a key that names a style property supplies a default for every Host in the subtree that accepts that property, and any other key is a named token for `etaf-theme-token` to read.

Host defaults from a Theme enter Ebox at UA origin, so normal author declarations — inline properties and Component rules — override them, while an important Theme default still beats an important author declaration. A Theme may be a ref or a computed source; like every provided Context value it stays reactive, and changing it republishes the defaults without converting them into inline properties.

#### Function: etaf-theme-provide (theme)

Provide THEME property defaults to the current Component subtree.

**Arguments.** THEME is a property plist such as `(:color "#F4F6FB" :bgcolor "#202634")`; every key is a keyword. It may also be a ref or a computed whose value is such a plist.

**Semantics.** The value is provided as the Context key `theme` to the current Component and its descendants, following the visibility and lifetime rules of [Context](context.md). Accepted style-property keys become Host defaults at UA origin, resolved against the same Theme before they reach Ebox; other keys remain ordinary token values. A reactive source is tracked, so a later write republishes the subtree. An invalid Theme shape or an invalid resolved default is rejected instead of publishing.

**Returns.** The provided value, as `etaf-provide` returns it.

**Errors.** `error→ etaf-context-error` with `("Theme defaults must be keyword/value pairs: %S")` when THEME is not an even-length plist, or `("Theme default must use a keyword: %S")` when a key is not a keyword.

**See also.** `etaf-theme-resolve-palette`, `etaf-theme-token`, and the Host defaults section of [Host](hosts.md).

## Resolving a palette

<!-- index: palette; light mode; dark mode; color pair -->

An application that ships both a light and a dark look keeps one palette of semantic roles and resolves it for an explicit mode. A palette value may be a plain color string (used in both modes), a `(LIGHT . DARK)` pair, a `(:light LIGHT :dark DARK)` plist, or nil; the result is an ordinary Theme plist that can be passed to `etaf-theme-provide`.

#### Function: etaf-theme-resolve-palette (palette mode)

Resolve semantic PALETTE token specs for explicit MODE.

**Arguments.** PALETTE is a keyword plist whose keys are Theme keys. Each value is a color string, a `(LIGHT . DARK)` pair, a `(:light LIGHT :dark DARK)` plist, or nil. MODE is `light` or `dark`.

**Semantics.** Each entry is resolved for MODE: a string is kept, a pair or plist contributes the corresponding light or dark value, and nil stays nil. The outcome contains the same keys and is a plain Theme value, so the caller can provide it and later re-resolve it for the other mode.

**Returns.** The resolved Theme plist.

**Errors.** `error→ etaf-context-error` with `("Theme palette mode must be light or dark: %S")` for a bad MODE, `("Theme palette must be a keyword plist: %S")` for a malformed palette, `("Theme palette key must be a keyword: %S")` for a non-keyword key, and `("Invalid ETAF palette color: %S")` for a value that is none of the four accepted shapes.

**Example.**

```elisp
(etaf-theme-resolve-palette
 '(:color "black" :bgcolor ("#FFF" . "#111") :accent (:light "#2563EB" :dark "#60A5FA"))
 'dark)
     ⇒ (:color "black" :bgcolor "#111" :accent "#60A5FA")
```

#### Function: etaf-theme-current-mode ()

Return the current frame color mode as `light` or `dark`.

**Semantics.** The mode is read from the frame's `background-mode` parameter: `dark` maps to `dark` and anything else to `light`. This is only the default argument for palette resolution — an application-owned light/dark toggle passes its own mode to `etaf-theme-resolve-palette` instead of changing the Emacs frame. It also ties the caller to the theme-switch signal: after a switch, a Theme computed that reads it re-derives instead of keeping the mode it first read.

**Returns.** The symbol `light` or `dark`.

## Theme tokens

<!-- index: deferred token; token fallback; token transform; token resolution -->

A Theme token is deferred data. `etaf-theme-token` returns a small list that names a Theme key and carries a fallback; the list survives in a quoted static rule list, and ETAF replaces it with the Theme's value while lowering the declaration into Ebox. Because the substitution happens at the lowering boundary, many retained Hosts can share one static style instead of each carrying an inline dynamic property.

A token resolves when the declaration that contains it is lowered: an inline Host property resolves from the inherited Theme as the Host commits, a Component rule resolves when that instance's rule snapshot is built for the current Theme, a Host default from a Theme resolves as the default is computed, and a token nested in `:hover-style` resolves with the instance's styles. If the Theme has no value for the key, the token's default is used; a default that is itself a token is resolved first; a transform function, when given, is applied to the final value.

#### Function: etaf-theme-token (key &optional default transform)

Return a deferred Theme token for a static Component style.

**Arguments.** KEY is a keyword naming a Theme entry. DEFAULT is returned when the Theme has no value for KEY; it may be a nested token. TRANSFORM, when non-nil, is a pure function applied to the resolved value.

**Semantics.** The result is a list of the shape `(etaf-theme-token KEY DEFAULT [TRANSFORM])`. It is intentionally data: it can be placed directly in a quoted `((SELECTOR PROPERTY VALUE ...) ...)` rule list or returned from an inline property expression, and `etaf-theme-token-p` recognizes it. The token is replaced by its resolved value when the containing declaration is lowered, so a theme change re-lowers the static rules rather than rewriting each Host.

**Returns.** The deferred token list.

**Errors.** `error→ etaf-context-error` with `("Theme token keys must be keywords: %S")` when KEY is not a keyword, and `("Theme token transform must be callable: %S")` when TRANSFORM is neither nil nor callable.

**See also.** `etaf-theme-provide`, `etaf-theme-token-p`.

#### Function: etaf-theme-token-p (value)

Return non-nil when VALUE is a deferred ETAF Theme token.

**Semantics.** A value is a token when it is a proper list of two to four elements whose first element is the symbol `etaf-theme-token`, whose second element is a keyword, and whose optional fourth element is a function. Ordinary Theme plists and colors are not tokens.

**Returns.** Non-nil for a token, nil otherwise.

```elisp :run
(etaf-define-component demo-theme-chip ()
  :setup (etaf-theme-provide '(:chip-bg "#0F766E" :chip-fg "#ECFDF5"))
  :view (text "Online")
  :styles (("&" :background-color (etaf-theme-token :chip-bg "#334155")
               :color (etaf-theme-token :chip-fg "#F8FAFC"))))
(etaf-view (demo-theme-chip))
```

### The base token vocabulary

<!-- index: ui-fg; ui-bg; ui-border; ui-muted-fg; status color -->

The tokens in this section are the semantic color surface the official Component catalog reads. A component that uses a token supplies a built-in fallback, so a catalog that runs without a provided Theme still paints; providing that key in a Theme overrides the fallback for the whole subtree. The remaining, component-family tokens are the subject of [the UI overview](ui-overview.md); the [Theme token table](theme-token-table.md) lists the full vocabulary.

Each entry names one role. A Theme may give the key any value the consuming declaration accepts; the base vocabulary uses colors.

#### Token: :ui-fg

The default foreground for catalog content.

**Semantics.** Official Components use it for ordinary text and glyphs, such as Label's default and strong variants, Selection rows, Table cells and the Data presentations. A Theme value under this key replaces the fallback.

#### Token: :ui-bg

The default background of application surfaces.

**Semantics.** Used by feedback surfaces, Data presentations and other application-level panels. It is a color for `:background-color`.

#### Token: :ui-border

The default border and divider color.

**Semantics.** Feedback Components use it for dividers and panel outlines; a consumer may transform the color into a full border declaration through its own style helper.

#### Token: :ui-muted-fg

The subdued foreground for secondary text.

**Semantics.** Used for hints, captions and inactive labels whose text should recede behind `:ui-fg`.

#### Token: :ui-accent

The accent color for emphasis and selection.

**Semantics.** Used by selection controls, media surfaces and the desktop shell for the selected state. It is the fill or text color that marks the active item.

#### Token: :ui-accent-fg

The foreground paired with `:ui-accent`.

**Semantics.** Names the text color for accent-filled surfaces, so a Theme can keep the accent fill and its foreground legible together.

#### Token: :ui-accent-soft-bg

The soft accent tint.

**Semantics.** Used for selected or secondary fills that carry less weight than a full `:ui-accent` surface, such as a selected desktop item background.

#### Token: :ui-disabled-fg

The foreground of a disabled control.

**Semantics.** Replaces `:ui-fg` while a control cannot be operated; used by Button, Checkbox and Selection.

#### Token: :ui-disabled-bg

The background of a disabled control.

**Semantics.** Keeps a disabled control's footprint visible while dimming its fill.

#### Token: :ui-disabled-border

The border color of a disabled control.

**Semantics.** Pairs with `:ui-disabled-bg` for outlined controls.

#### Token: :ui-danger-fg

The foreground of the danger status.

**Semantics.** Used for destructive or erroneous states, including Label's danger variant and feedback surfaces.

#### Token: :ui-danger-bg

The background of the danger status.

**Semantics.** The tint behind danger text in feedback surfaces.

#### Token: :ui-danger-border

The border of the danger status.

**Semantics.** Completes the danger triple with `:ui-danger-fg` and `:ui-danger-bg`.

#### Token: :ui-warning-fg

The foreground of the warning status.

**Semantics.** Used for cautionary states in feedback surfaces.

#### Token: :ui-warning-bg

The background of the warning status.

**Semantics.** The tint behind warning text.

#### Token: :ui-warning-border

The border of the warning status.

**Semantics.** Completes the warning triple.

#### Token: :ui-info-fg

The foreground of the informational status.

**Semantics.** Used for neutral notices and hints in feedback surfaces.

#### Token: :ui-info-bg

The background of the informational status.

**Semantics.** The tint behind informational text.

#### Token: :ui-info-border

The border of the informational status.

**Semantics.** Completes the informational triple.

#### Token: :ui-success-fg

The foreground of the success status.

**Semantics.** Used for confirming states, including Label's success variant and feedback surfaces.

#### Token: :ui-success-bg

The background of the success status.

**Semantics.** The tint behind success text.

#### Token: :ui-success-border

The border of the success status.

**Semantics.** Completes the success triple.

#### Token: :ui-important-fg

The foreground of the important status.

**Semantics.** Used for high-priority highlights and important semantic accents across cards and feedback surfaces.

#### Token: :ui-important-bg

The background of the important status.

**Semantics.** The tint behind important text.

#### Token: :ui-important-border

The border of the important status.

**Semantics.** Completes the important triple with `:ui-important-fg` and `:ui-important-bg`.

## Following the Emacs frame

<!-- index: frame background mode; theme toggle -->

A Theme computed from the frame re-derives after an Emacs theme switch: `etaf-theme-current-mode` ties its caller to the switch, and a Theme or a render that reads it re-runs once per switch, after the enable and disable steps settle. A Theme that pins its own mode stays application data, and the application decides when to rebuild it. A host that owns several surfaces provides their appearance explicitly ([Appearance inheritance](#appearance-inheritance)) and updates it when it re-resolves a Theme, so the Components below follow without knowing the host. The provided building blocks are `etaf-theme-current-mode`, which reports whether the current frame is light or dark, and `etaf-theme-resolve-palette`, which turns one palette into a Theme for an explicit mode. A common arrangement is to keep the palette in application data, resolve it for the mode when the application starts or when its own toggle changes, and provide the result; because a provided Theme may be a ref, re-providing the new mode republishes the subtree without re-rendering it.

## Appearance inheritance

<!-- index: appearance; light and dark surface; panel appearance -->

A host may render a surface whose appearance differs from the frame, as a light panel inside a dark Emacs frame does. `etaf-appearance-provide` provides that appearance to the Component subtree, and `etaf-appearance` reads the nearest provided one; without a provider the frame's mode is returned. A host may provide a ref or a computed, so switching the appearance republishes the subtree without re-rendering it.

#### Function: etaf-appearance-mode (&optional override)

Return a computed appearance mode that follows the host.

**Semantics.** OVERRIDE, when non-nil, is a ref holding `light` or `dark` and wins over the host; that is what an application's own light/dark switch writes. The computed tracks the host appearance, so a Component that reads it re-renders when the host switches.

**Returns.** A computed ref whose value is `light` or `dark`.

#### Function: etaf-appearance-provide (appearance)

Provide APPEARANCE (`light` or `dark`) to the current Component subtree.

**Semantics.** APPEARANCE is `light`, `dark`, a ref or a computed. An invalid value signals `etaf-context-error` before anything is provided. The value applies to the current Component and its descendants until a nested provider replaces it.

#### Function: etaf-appearance ()

Return the appearance inherited from the nearest host, or the frame mode.

**Semantics.** A provided ref or computed is read through `etaf-value`, so the calling Component re-renders when the host switches appearance. Without a provider the value comes from `etaf-theme-current-mode`.

**Returns.** The symbol `light` or `dark`.

## Surface declaration

<!-- index: surface declaration; application palette; panel paint -->

An application that owns its palette and its light/dark switch can declare both to the host that frames it instead of letting the host guess a second one. `etaf-surface-create` makes the declaration slot, and the host provides it with `etaf-surface-provide` before rendering the content; the content reads the slot with `etaf-surface-host` in its Component `:setup` and writes its Theme, mode cell and mode table with `etaf-surface-declare`. The host reads `etaf-surface-theme`, `etaf-surface-mode` and `etaf-surface-modes` to paint its own frame, title bar and border, and uses the mode table as its switch. The mode cell is the only state: the content's own switch writes it and the host's switch writes it too, so the content and the surface framing it have one appearance state instead of one each. Without a host `etaf-surface-host` returns nil, and the content paints itself as before.

#### Function: etaf-surface-create ()

Return an empty surface declaration for a host to provide.

**Semantics.** The host creates it once before providing it and keeps that same object afterwards: the content fills it in and the host reads the same one after the content mounts. The slot is ordinary data and does not travel in Context; the object itself does.

**Returns.** A surface declaration, opaque to callers; pass it to `etaf-surface-provide` and the three readers.

#### Function: etaf-surface-provide (surface)

Provide SURFACE to the current Component subtree.

**Semantics.** SURFACE comes from `etaf-surface-create`; any other value signals `etaf-context-error`. The slot is inherited down the Context, and the content reads it with `etaf-surface-host`. The object is mutable, so what the host reads after mounting is what the content wrote, not a copy taken when it was provided.

**Returns.** SURFACE.

#### Function: etaf-surface-host ()

Return the surface declaration of the nearest host, or nil.

**Semantics.** Call it from a content Component's `:setup`. An ordinary buffer, or a host that provides no slot, returns nil, so an application declares its surface only while it is framed and keeps painting its own palette when it stands alone.

**Returns.** A surface declaration, or nil.

#### Function: etaf-surface-declare (surface &key theme mode modes)

Declare the content's own surface on host SURFACE.

**Semantics.** THEME is a ref or computed holding the Theme plist, MODE a ref holding the current mode symbol, and MODES the ordered alist of `(MODE . LABEL)`, where LABEL is a string. Each keyword may be omitted, and an omitted field keeps its value, so the palette and the mode table can be declared in separate calls. The host paints its frame, title bar and border from THEME, uses MODES as the title-bar switch and writes MODE; the content reads the same cell, so a switch on either side repaints both. Calling it while rendering, an invalid value, or a SURFACE that is not a declaration slot signals `etaf-context-error` before anything is stored.

**Returns.** SURFACE.

#### Function: etaf-surface-theme (surface)

Return SURFACE's Theme source (a ref or a computed), or nil when it declared none.

**Semantics.** The host reads it through `etaf-value` after the content mounts and repaints its own surface; a content that replaces the source is followed by the host.

#### Function: etaf-surface-mode (surface)

Return SURFACE's mode ref, or nil when it declared none.

**Semantics.** This is the one cell content and host share: the content's own switch writes it and the host's switch writes it too, and the Components that read it and the host repaint with it.

#### Function: etaf-surface-modes (surface)

Return SURFACE's ordered alist of `(MODE . LABEL)`, or nil when it declared none.

**Semantics.** The host renders its switch in that order; nil means the content has no switch, and the host draws none.

#### Function: etaf-ui-color-contrast (from to)

Return the WCAG contrast ratio between FROM and TO, from 1 to 21.

**Parameters.** Either colour may be written the way Emacs resolves colours, `#RRGGBB` or a name such as `moccasin`.

**Returns.** A ratio between 1 and 21.

**Semantics.** A colour Emacs cannot resolve has no measurable contrast and answers 0, which reads as a colour nobody checked rather than as no contrast at all. Use it to check a theme or palette instead of judging lightness by eye.

**See also.** `etaf-ui-color-legible`, `etaf-theme-token`.

#### Function: etaf-ui-color-legible (color background &optional ratio)

Return COLOR made readable on BACKGROUND, keeping its hue.

**Parameters.** COLOR is the colour to use, BACKGROUND the surface it lands on, and RATIO the target contrast, defaulting to 4.5, the WCAG AA ratio for body text.

**Returns.** A `#RRGGBB` colour.

**Semantics.** A syntax colour written for one page disappears on another: the pale pink a dark theme gives strings vanishes on a white page. COLOR is mixed toward black on a light surface and toward white on a dark one, in steps, until it reaches RATIO; a colour that already passes comes back unchanged. A colour in any spelling other than `#RRGGBB` also comes back unchanged, because it cannot be mixed here. The answer is cached per (COLOR BACKGROUND RATIO), because a page re-renders its code blocks on every repaint.

**See also.** `etaf-ui-color-contrast`, `etaf-theme-resolve-palette`.

## Rule files

<!-- index: rule file; .ecss; stylesheet reload -->

Rules written outside a Component definition can still become Component styles. An ECSS rule file is read as an ordered rule list ([Rule Files](ecss-rule-files.md) defines the reader), and `etaf-component-set-styles` accepts that list, so a stylesheet file, a preview tool or a hot-reload loop can replace a Component's rules without touching its definition. The `.ebox` file format and its companion rules belong to the Ebox part; a Component's own `:styles` clause remains static data and cannot itself read a file.
