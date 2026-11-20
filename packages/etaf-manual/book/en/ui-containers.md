# Containers

The catalog's container components give content a surface: a padded, optionally bordered area that groups what belongs together, and a divider that separates groups without becoming an element of its own. Panel and card share one surface anatomy — the same padding, the same internal gap and the same three theme tokens — and differ in what they structure: a panel names a region and offers a header slot, a card presents a titled summary with a description. All three are presentational and stateless: they own no application data, and their content is the caller's slots. [UI Overview](ui-overview.md) defines the catalog's contract, [Values](values.md) the length syntax used by the padding and gap declarations, and [Component Styles and Themes](component-styles-and-themes.md) the token mechanism the surfaces read.

## Panel and card surfaces

<!-- index: panel surface; card anatomy; flat variant; content order -->

A surface is a column with one row of vertical and two columns of horizontal padding, one row of gap between its children, and — unless it is flat — a foreground, a background and a hairline border from the panel tokens. The padding belongs to the surface itself, not to the content, so a caller's text starts inside the frame and the frame reaches the surrounding layout's edges. An empty surface still shows its padding rows; the frame is part of the component, not an effect of having content.

A panel orders its children as a title, then the `header` slot, then the `default` slot. The title is a strong label named for the panel, so a region reads as a heading with a body; supplying a `header` slot lets the caller compose its own header content, and the two may coexist. A panel with no title and no header is a plain framed box. Its `variant` selects presentation: `flat` drops the background and the border while keeping the padding, and any other symbol becomes the surface's second class name — the hook a caller's static rules use to restyle one panel without registering a component.

A card orders its children as a title, a description and the `default` slot. The title is a strong label and the description a muted one, so the pair reads as a heading and a supporting line; the body follows. The card's `variant` is only a class name: the component ships one look and lets a caller's rules or a theme distinguish variants, rather than switching paint internally. A card spans the available width by default and a panel follows the column default, so a panel placed directly in a narrow row shrinks to its content.

Both surfaces read the same three tokens — `:ui-panel-fg`, `:ui-panel-bg` and `:ui-panel-border` — which are deferred values read when the declaration is lowered. Providing a Theme, including a reactive one, therefore restyles mounted surfaces through their paint slots without re-rendering the tree, and each token falls back to the catalog's built-in value when the Theme does not define it.

## The panel component

<!-- index: etaf-panel; header slot; titled region -->

#### Component: etaf-panel (&key title variant)

Render a titled Panel with named header and default slots.

**Arguments.** TITLE is an optional string rendered as a strong label; nil renders no title. VARIANT is a symbol selecting the presentation: `default` (the default) keeps the background and border, `flat` drops both while keeping the padding, and any other symbol is added to the surface's class names. The default slot holds the panel's body and the `header` slot holds caller-composed header content.

**Semantics.** The surface is a column with one row of vertical and two columns of horizontal padding and one row of gap between children. Its content order is the title, the `header` slot and the `default` slot. Unrecognized props that name ordinary Host properties fall through to the surface's root Host — a `:color` overrides the panel's body foreground, for example — while a name that is neither a declared prop nor a supported Host attribute is rejected.

**Returns.** A View.

**Errors.** `error→ wrong-type-argument (symbolp)` when VARIANT is not a symbol, because the variant becomes a class name. `error→ etaf-component-call-error` when an unknown name is neither a declared prop nor a Host attribute.

**Example.**

```elisp
(etaf-panel :title "Environment"
            :variant 'flat
            "All targets succeeded")
```

**See also.** `etaf-card`, `:ui-panel-fg`.

## The card component

<!-- index: etaf-card; description line; variant class -->

#### Component: etaf-card (&key title description icon variant width text-align on-press)

Render a reusable titled surface with default content slots.

**Arguments.** TITLE is an optional strong heading; DESCRIPTION is an optional muted supporting line; VARIANT is a symbol appended to the surface's class names. The default slot holds the card's content.

**Semantics.** The content order is TITLE, DESCRIPTION and the default slot. The surface uses the same padding, gap and panel tokens as `etaf-panel` and spans the available width. VARIANT carries no built-in behavior: every value produces the same default look with a different class, so callers distinguish card styles through their own rules or a Theme.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when an unknown name is neither a declared prop nor a Host attribute.

**Example.**

```elisp
(etaf-card :title "Build" :description "last run 2m ago"
           "All targets succeeded")
```

**See also.** `etaf-panel`, `:ui-panel-bg`.

```elisp :figure A panel and a card surface
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 1)
   (etaf-panel :title "面板"
     (text "面板正文"))
   (etaf-card :title "卡片" :description "卡片描述")))
```

## The divider component

<!-- index: etaf-divider; horizontal rule; vertical rule; separator label -->

#### Component: etaf-divider (&key orientation label)

Render a horizontal or vertical separator, optionally with a centered label.

**Arguments.** ORIENTATION is `horizontal` (the default) or `vertical`. LABEL is an optional string; it is rendered only on a horizontal divider.

**Semantics.** A horizontal divider is a one-row flex line: two equal growing boxes paint a hairline with `:ui-border` at the vertical centre, and when LABEL is present the label sits between them with one column of gap on each side. The label is a muted caption, so it reads as an alternative to the line rather than as content. A vertical divider is a one-column box with the divider color as its background and a stretched height; it has no label. The divider's own height is the standard row, and a vertical divider fills the height its container gives it, so place it inside a sized container when a visible rule is required.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ORIENTATION is neither `horizontal` nor `vertical`.

**Example.**

```elisp
(etaf-divider :label "or")
```

**See also.** `:ui-border`, [Boxes and Normal Flow](boxes-and-normal-flow.md).

## The surface tokens

<!-- index: ui-panel-fg; ui-panel-bg; ui-panel-border; surface triple -->

#### Token: :ui-panel-fg

The foreground of a catalog surface.

**Semantics.** Panel and card paint their content with this color, and the floating surfaces of the catalog read the same key for their own foreground. A component that reads it supplies a built-in fallback, so a surface paints without a provided Theme.

#### Token: :ui-panel-bg

The background of a catalog surface.

**Semantics.** The fill behind panel and card content, and behind the floating surfaces' panels. The `flat` panel variant omits it deliberately.

#### Token: :ui-panel-border

The border of a catalog surface.

**Semantics.** Completes the surface triple with `:ui-panel-fg` and `:ui-panel-bg`; a divider uses the shared `:ui-border` instead because a rule is not a surface.

## Errors and recovery

- `error→ etaf-component-call-error` reports a rejected `:orientation` for the divider and any unknown name that is neither a declared prop nor a Host attribute for a surface component, naming the component, property and received value.
- `error→ wrong-type-argument (symbolp)` reports a non-symbol panel variant, because the variant is used as a class name; a card variant is formatted into a class name and therefore accepts any value.
- The surfaces are stateless: there is nothing to roll back. Content supplied through slots belongs to the caller and keeps the caller's Context and state, and a rejected call leaves already mounted surfaces untouched.
- Theme rejection happens before painting: [Component Styles and Themes](component-styles-and-themes.md) describes how an invalid provided Theme is refused instead of publishing.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery).

```elisp :run
(etaf-view
 (etaf-panel :title "Environment"
   (etaf-card :title "Build" :description "last run 2m ago"
              "All targets succeeded")
   (etaf-divider :label "or")
   (etaf-card :variant 'compact "Run a manual check")))
```
