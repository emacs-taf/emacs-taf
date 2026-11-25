# Feedback and Status

The feedback components carry short, semantic messages: a label states a value, a badge or tag marks it, a keycap documents a shortcut, a progress bar measures it, an alert or empty state explains it, and a skeleton reserves its space. They are presentational and stateless — the application owns the value, the visibility and the reaction — and they share one color vocabulary: a semantic variant selects the foreground, background and border the component paints with. [UI Overview](ui-overview.md) defines the catalog's shared contract, [Containers](ui-containers.md) the surfaces these components usually sit on, and [Component Styles and Themes](component-styles-and-themes.md) how the variants resolve through Theme tokens.

## Semantic variants

<!-- index: variant; status colors; neutral; feedback triple -->

A variant names a semantic role rather than a color. The status variants `success`, `warning`, `danger` and `info` map to the `:ui-success-*`, `:ui-warning-*`, `:ui-danger-*` and `:ui-info-*` triples defined in [Component Styles and Themes](component-styles-and-themes.md); `neutral` (the default where a default exists) maps to the base `:ui-fg`, `:ui-bg` and `:ui-border`. A component that paints a variant takes its foreground from the first key, its background from the second and, where it draws a frame or a rule, its border from the third.

Because each key resolves through a deferred token, providing a Theme restyles every variant-carrying component in the subtree without re-rendering. Unknown variant symbols are not rejected by most of these components: they fall back to the neutral triple and become part of the component's class name, which keeps a caller's own variant vocabulary usable through static rules.

## The label component

<!-- index: etaf-label; label variant; text payload -->

#### Component: etaf-label (&key text variant)

Render TEXT in a semantic Label with ordinary Box layout.

**Arguments.** TEXT is a value, ref or computed: nil renders empty, a string keeps its text properties, and any other value uses its printed form. VARIANT is `default`, `muted`, `danger`, `success`, `strong` or `heading`; `strong` and `heading` emphasize the text with weight while keeping the inherited font size. When a color prop is passed to the call it overrides the variant's color, as any Host attribute on a single-root Component does.

**Semantics.** The label is an ordinary Box whose Text child inherits typography and color from it, so layout attributes such as `:width`, `:padding`, `:border` and `:wrap-mode` apply to the Box: `:width 'stretch` follows the containing width and `:wrap-mode 'word` wraps prose. A reactive TEXT or a viewport change reflows through Ebox like any other text. An unknown variant symbol keeps the default foreground and becomes the label's second class name.

**Returns.** A View.

**Example.**

```elisp
(etaf-label :text "Disk almost full" :variant 'danger)
```

**See also.** `etaf-badge`, `:ui-fg`.

## Status marks

<!-- index: badge; tag; keycap; removable tag -->

#### Component: etaf-badge (&key text variant)

Render compact semantic status text using neutral, success, warning, danger or info styling.

**Arguments.** TEXT is the value to display, as for `etaf-label`. VARIANT defaults to `neutral`.

**Semantics.** The badge is a `max-content` box with one column of horizontal padding and bold text, painted with the variant's foreground and background; its role is `status`, so assistive tooling reads it as a status mark rather than as a control. It never grows to fill its container.

**Returns.** A View.

**Example.** `(etaf-badge :text "stale" :variant 'warning)`

**See also.** `etaf-tag`, `etaf-label`.

#### Component: etaf-tag (&key text variant closable on-close)

Render a compact semantic tag; an optional close action remains caller-owned.

**Arguments.** TEXT and VARIANT are as for `etaf-badge`. CLOSABLE non-nil adds a close control. ON-CLOSE is required when CLOSABLE is non-nil and receives no arguments.

**Semantics.** A closable tag shows a ghost `×` button whose accessible name is `"Remove TEXT"`. Pressing it calls ON-CLOSE; the tag does not remove itself, so the caller decides whether the tag remains. The close control and the tag share the variant's colors, so a labelled tag reads as one mark.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when CLOSABLE is non-nil and ON-CLOSE is not a function.

**Example.** `(etaf-tag :text "filter: open" :variant 'info :closable t :on-close #'clear-filter)`

#### Component: etaf-kbd (&key keys)

Render a keyboard shortcut as accessible keycaps from a nonempty string list.

**Arguments.** KEYS is a nonempty list of nonempty strings; each entry is one keycap.

**Semantics.** Each key is a compact rounded, bordered box with horizontal padding and the normal line height. Its subtle fill and edge derive from the inherited panel foreground and background, so keycaps remain readable in light and dark Themes. The group is a `max-content` row with one column between keycaps; `("C-c" "C-k")` therefore reads as two physical keys.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when KEYS is nil, empty, or contains a value that is not a nonempty string.

**Example.** `(etaf-kbd :keys '("C-c" "C-k"))`

#### Component: etaf-keycap (&key text level label active disabled on-press aria-label help-echo variant)

Render one key as a keycap; action keys and region keys are two sizes.

**Arguments.** TEXT is the nonempty string drawn in the cap. LEVEL is `action` (default) or `region`. LABEL is optional caption text drawn one column to the right of the cap. ACTIVE matters for region keys only: non-nil fills the square with `:ui-accent` and draws the letter in `:ui-bg`. DISABLED keeps the slot and the outline and drops only the ink to `:ui-disabled-fg`. ON-PRESS is an optional zero-argument callback; supplying it makes the cap a focusable button. ARIA-LABEL and HELP-ECHO pass through to the Host.

**Semantics.** An action key is one row high with a one-pixel hairline border and no fill, its letter at 10px. A region key is a 20px right-angled square with a bold centred letter. The two sizes, not the colour, separate "do something" from "go somewhere". A cap is an inline control and never grows the line: it is shorter than the standard row and centres inside it, and it takes no part in flex shrinking, so a cap at the right end of a row is never squeezed by the spacer before it. Enabled and disabled change only ink; position and width stay put.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when TEXT is not a nonempty string, LEVEL is neither keyword, LABEL is not a string, or ON-PRESS is not a function.

**Example.** `(etaf-keycap :text "x" :label "Complete" :on-press #'agenda-toggle)`, `(etaf-keycap :text "B" :level 'region :active t)`

#### Component: etaf-check-mark (&key state color glyph aria-label)

Draw one task's check state as a box.

**Arguments.** STATE is `empty`, `done`, `dropped` or `skipped`, default `empty`. COLOR overrides the ink of the box and its stroke; otherwise it inherits the surrounding foreground. GLYPH optionally overrides the two-cell terminal spelling of that state. ARIA-LABEL defaults to the state's own word.

**Semantics.** On graphical frames the four states are one right-angled box with a path: empty, check, cross, dash. Box and stroke keep identical metrics across the states, so a column of marks never shifts when a state changes. The box is a path rather than a character, so it stays crisp at any scale and does not depend on the font carrying the glyph. Without SVG the mark falls back to two cells of text (待 / 完 / 弃 / 跳), which keeps the meaning readable.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when STATE is outside the four keywords or GLYPH is not a nonempty string.

**Example.** `(etaf-check-mark :state 'done)`, `(etaf-check-mark :state 'empty :glyph "todo" :color "#e06c75")`

## Progress

<!-- index: etaf-progress; determinate progress; track token; reactive value -->

#### Component: etaf-progress (&key value max label variant animated)

Render a determinate progress bar. VALUE and MAX are numeric (or reactive) with 0 <= VALUE <= MAX and MAX > 0. LABEL is optional.

**Arguments.** VALUE is the current quantity and MAX the full quantity; both accept plain numbers or reactive values and are read on every render. LABEL is an optional caption. VARIANT selects the fill's color from the semantic variants. ANIMATED, when non-nil (default nil), smoothly transitions the fill width and percentage label on the shared animation clock when mounted.

**Semantics.** The bar is two rows: a row showing the label and the rounded percentage, then one standard row whose track uses `:ui-progress-track` and whose fill uses the variant's foreground and occupies the percentage of the width. A reactive VALUE or MAX re-renders the bar and rewrites the percentage; because the checks run on every render, live bounds are enforced while the value changes.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when MAX is not positive, or when VALUE is not a number between zero and MAX, naming the property and the received value.

**Example.**

```elisp
(etaf-progress :value 25 :max 200 :label "Upload")
```

**See also.** `:ui-progress-track`, `etaf-skeleton`.

## Alerts and empty states

<!-- index: etaf-alert; dismissible alert; etaf-empty; empty state action -->

#### Component: etaf-alert (&key title message variant dismissible on-dismiss)

Render an alert with semantic styling. A dismissible alert invokes ON-DISMISS; the caller decides whether its state remains visible.

**Arguments.** TITLE is an optional string heading; MESSAGE is the body text, wrapped by word. VARIANT defaults to `info`. DISMISSIBLE non-nil adds a ghost `×` control; ON-DISMISS is required then and receives no arguments.

**Semantics.** The alert is a padded flex row with the variant's foreground and background and the `alert` role. The title is strong and the message wraps at word boundaries, so a long message grows the alert vertically instead of widening it. Dismissing calls ON-DISMISS and changes nothing by itself: the caller hides the alert by re-rendering without it.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when TITLE is neither a string nor nil, or when DISMISSIBLE is non-nil and ON-DISMISS is not a function.

**Example.**

```elisp
(etaf-alert :title "Heads up" :message "Three targets are stale"
            :variant 'warning :dismissible t :on-dismiss #'hide-alert)
```

#### Component: etaf-empty (&key title description action-label on-action)

Render an empty state with optional action callback.

**Arguments.** TITLE defaults to `"Nothing here"`; DESCRIPTION is an optional supporting line; ACTION-LABEL non-nil adds a button; ON-ACTION is required then and receives no arguments.

**Semantics.** The state is a stretched column, centered on the cross axis, with padding and a row of gap between its parts: a strong title, a muted description and an optional primary button. Empty states are deliberately static — the component does not decide when the state is empty or what the action does.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ACTION-LABEL is non-nil and ON-ACTION is not a function.

**Example.**

```elisp
(etaf-empty :title "No results" :description "Try another query"
            :action-label "Clear" :on-action #'clear-query)
```

```elisp :figure Badges, an alert and a progress bar
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 1)
   (row :item-gap '(ch 1)
     (etaf-badge :text "已完成" :variant 'success)
     (etaf-badge :text "注意" :variant 'warning))
   (etaf-alert :title "提示" :message "这是一条信息告警" :variant 'info)
   (etaf-progress :value 60 :max 100 :label "进度")))
```

## Metrics

<!-- index: etaf-statistic; metric card -->

#### Component: etaf-statistic (&key label value trend animated)

Render a compact metric card from caller-owned display values.

**Arguments.** LABEL is the muted caption, VALUE the emphasized figure and TREND an optional success-colored change line. Each accepts a value, ref or computed, like `etaf-label`. ANIMATED, when non-nil (default nil), rolls numeric values smoothly on the shared animation clock when mounted.

**Semantics.** The result is a three-row column — a muted label, a heading value and a success-trend line — with no surface of its own, because the component deliberately leaves its container spacing and surface to the caller. A nil TREND renders an empty line.

**Returns.** A View.

**Example.**

```elisp
(etaf-statistic :label "Requests" :value "1,204" :trend "+12%")
```

## Placeholders

<!-- index: etaf-skeleton; loading placeholder; placeholder size -->

#### Component: etaf-skeleton (&key width height animated)

Render a neutral loading placeholder without owning loading state.

**Arguments.** WIDTH defaults to `stretch` and HEIGHT to one standard row; both accept any length value. ANIMATED, when non-nil (default nil), gently pulses the placeholder fill on the shared animation clock when mounted.

**Semantics.** The skeleton is a plain box filled with `:ui-progress-track`, sized by its props. Without ANIMATED it contains no state and no timer; with ANIMATED it uses a Scope-owned frame sequence that stops on unmount and honors `etaf-animation-enabled`.

**Returns.** A View.

**Example.**

```elisp
(etaf-skeleton :width '(ch 24) :height '(lh 2))
```

**See also.** `etaf-progress`, `etaf-spinner`, `:ui-progress-track`.

#### Component: etaf-spinner (&key style label variant interval)

Render a fixed-width shared-clock loading indicator with an optional caption.

**Arguments.** STYLE selects the frame sequence: `braille` (default), `dots`, `line` or `meter`. LABEL is an optional muted caption beside the glyph. VARIANT selects the glyph color from the semantic variants (default `info`). INTERVAL is the positive number of seconds per frame (default 0.09).

**Semantics.** The spinner owns a Scope-bound `etaf-animation-frames` sequence on the shared clock and fixes its glyph box width so adjacent labels never shift as frames cycle. Unmounting stops the sequence, and `etaf-animation-enabled` nil freezes it on its first frame.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when STYLE is not one of the four symbols, LABEL is neither a string nor nil, or INTERVAL is not a positive number.

**Example.** `(etaf-spinner :style 'braille :label "Syncing")`

**See also.** `etaf-animation-frames`, `etaf-skeleton`.

## The track token

<!-- index: ui-progress-track; progress track; placeholder fill -->

#### Token: :ui-progress-track

The background of a progress track and of a placeholder block.

**Semantics.** `etaf-progress` paints its unfilled track with this color and `etaf-skeleton` fills its whole box with it, so a loading bar and its placeholder read as the same material. The fill of a progress bar uses the variant foreground instead. A component that reads the token supplies a built-in fallback, so both paint without a provided Theme.

## Errors and recovery

- `error→ etaf-component-call-error` reports a violated input contract through `etaf-check-prop`, naming the component, the property, the received value and the expectation: a tag or alert that asks for a close control without a dismiss callback, an empty state with an action label but no callback, a keycap list that is empty or not a list of nonempty strings, and progress bounds that are not positive and ordered.
- The variant-driven components do not validate the variant; an unknown symbol falls back to the neutral triple and joins the class names. The input contract of the value, the labels and the size props is what is checked.
- Nothing is rolled back, because these components own no state: a rejected call leaves the mounted surface as it was, and the caller's own state was never written by the component.
- A progress bar with a reactive VALUE updates in place; if a write makes the bound invalid, the rejected render leaves the bar showing its last valid paint.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery).

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-alert :title "Heads up" :message "Three targets are stale"
               :variant 'warning)
   (etaf-progress :value 2 :max 5 :label "Sync")
   (row :item-gap '(ch 1)
     (etaf-badge :text "stale" :variant 'warning)
     (etaf-tag :text "build"))))
```
