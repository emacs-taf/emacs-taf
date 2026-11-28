# Navigation and Collections

The catalog's navigation components keep the user oriented inside an application: tabs switch between views, a breadcrumb shows the path back, steps show progress through a flow, and an accordion or tree discloses nested content. A list presents a selectable collection, and a pagination bar drives a Data Controller's pages. All of them compose ordinary buttons and flow layout, keep their state in caller-owned values or refs, and create no second focus or event system: the keyboard behavior is the catalog's baseline, and a selected item is shown by its paint, never by changing its padding, typeface or a prefix that would shift the row. [UI Overview](ui-overview.md) defines the controlled contract, [Buttons and Choice Controls](ui-buttons-and-choice-controls.md) the buttons and selection tint they compose, [Data Controllers](data-controllers.md) the controller the pagination follows, and [Keyboard](keyboard.md) focus groups.

## Items and state

<!-- index: navigation items; item key; selected state; caller-owned state -->

The navigation components share one item shape: a plist with a unique non-nil `:key`, a nonempty string `:label`, and optional extras — a scalar `:count` shown next to the label, a symbol `:ref` that lets a caller address that control directly, or, for the tree, nested `:children`. The list component uses the same idea with `:title` and an optional `:description`, and the tree's items may carry children of the same shape. Validation is strict about uniqueness: duplicate keys or labels are rejected, because a callback that receives only the key must be unambiguous.

State stays caller-owned. Tabs take an active key, the accordion an open key list, the tree an expanded key list, the pagination a controller, and each reports the next state through a callback rather than storing it. Selection and expansion are painted with the selection tint — the active tab, the open section, the current step — so the text itself never changes width when the state moves, and a row of tabs does not jump under the pointer. Each collector is one horizontal or vertical focus group, so the arrows move within it and Tab leaves it.

## Tabs, breadcrumb and steps

<!-- index: etaf-tabs; etaf-breadcrumb; etaf-steps -->

#### Component: etaf-tabs (&key items active on-change variant framed)

Render controlled tabs from unique scalar keys and labels.

**Arguments.** ITEMS is the item list described above; an item may carry a scalar `:count` and a symbol `:ref`. ACTIVE is the selected key and must be present in ITEMS; it may be a value or a ref. ON-CHANGE receives the selected key and is required. VARIANT is the tab strip's class variant and defaults to `underline`.

**Semantics.** Each tab is a ghost button whose selected state uses the secondary Theme colors without changing its geometry or typeface; a count renders after the label in the muted color, so a tab can show how many items it holds. The strip is a horizontal focus group with the `tablist` role, and the selected tab carries `:aria-selected`. An item's `:ref`, when supplied, names its button so a caller can focus it directly.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ITEMS is not an item list with unique keys and labels, ACTIVE is not a key in ITEMS, or ON-CHANGE is not a function.

**Example.**

```elisp
(etaf-tabs :active tab :on-change #'select-tab
           :items '((:key all :label "All" :count 12) (:key open :label "Open")))
```

**See also.** `etaf-steps`, `etaf-accordion`.

#### Component: etaf-breadcrumb (&key items on-select)

Render a navigation trail of strings; ON-SELECT receives a zero-based index.

**Arguments.** ITEMS is a nonempty list of strings. ON-SELECT is optional; when it is nil the trail is plain text.

**Semantics.** With a callback, each item is a ghost button and the last one carries `:aria-current`; the items are separated by a muted `/` label. The trail is a horizontal focus group, so the arrows move along the path instead of stepping through every crumb with Tab.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ITEMS is empty or not a proper list of strings, or ON-SELECT is neither a function nor nil.

**Example.** `(etaf-breadcrumb :items '("Home" "Docs" "API") :on-select #'go-to)` 

#### Component: etaf-steps (&key items current on-change)

Render ordered step buttons. ITEMS contain `:key` and `:label`; CURRENT and the callback are controlled by the caller.

**Arguments.** CURRENT is a key in ITEMS, as a value or a ref. ON-CHANGE is optional and receives a selected key.

**Semantics.** Each step is a button reading `"N  LABEL"` with a muted `→` between steps; the current one uses the ghost Button's selected tint with unchanged padding and typeface. The row wraps when the window is narrow, so a long flow reflows instead of overflowing, and it is one horizontal focus group with a row of gap between wrapped lines.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ITEMS is malformed, CURRENT is not a key in ITEMS, or ON-CHANGE is neither a function nor nil.

**Example.**

```elisp
(etaf-steps :current 'account :on-change #'goto-step
            :items '((:key account :label "Account") (:key billing :label "Billing")))
```

```elisp :figure A breadcrumb trail and a tabs strip
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 1)
   (etaf-breadcrumb :items '("手册" "样式" "选择器"))
   (etaf-tabs :items '((:key overview :label "概览")
                       (:key details :label "细节"))
              :active 'overview
              :on-change #'ignore)))
```

## Disclosure and collections

<!-- index: etaf-accordion; etaf-tree; etaf-list -->

#### Component: etaf-accordion (&key items open on-toggle multiple)

Render controlled disclosure sections. Items contain `:key`, `:label` and string or zero-argument function `:content`. OPEN is a list of expanded keys.

**Arguments.** OPEN is a list of keys present in ITEMS. ON-TOGGLE receives the next list of open keys and is required. MULTIPLE (default t) permits more than one open section.

**Semantics.** Each section is a ghost button with a downward disclosure icon when open and a rightward icon when closed, followed by its content. Its accessible name stays equal to the item label; `:aria-expanded` carries the expansion state. With MULTIPLE nil the next list contains at most one key; OPEN is validated against the item keys and the single-open rule, so a caller cannot leave the component in an inconsistent state.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ITEMS is malformed, OPEN is not a list of item keys (or contains more than one key with MULTIPLE nil), a `:content` is neither a string nor a function, MULTIPLE is not a boolean, or ON-TOGGLE is not a function.

**Example.**

```elisp
(etaf-accordion :open open :on-toggle (lambda (next) (setq open next)) :multiple nil
                :items '((:key a :label "Details" :content "Body")))
```

#### Component: etaf-tree (&key items expanded on-toggle on-select)

Render nested items with caller-owned expanded keys and selection callbacks.

**Arguments.** ITEMS is a nonempty list of tree items; each may carry `:children` of the same shape. EXPANDED is a list of open keys, as a value or a ref. ON-TOGGLE receives a key or the next expanded list; ON-SELECT receives a key. Either callback may be nil.

**Semantics.** The tree flattens the visible items into rows with two spaces of indentation per depth and a downward or rightward disclosure icon on branches. A branch row carries `:aria-expanded` and toggles on press; a leaf row selects on press. Right opens and Left closes the focused branch in place through the direction channel, so the keyboard can walk the hierarchy without activating a row. Expanded branches use the selection tint, and the tree is one vertical focus group.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ITEMS is empty or malformed, EXPANDED is not a proper list, or a callback is neither a function nor nil.

**Example.**

```elisp
(etaf-tree :expanded expanded :on-toggle #'toggle-node :on-select #'open-file
           :items '((:key src :label "src"
                          :children ((:key main :label "main.el")))))
```

**See also.** `etaf-list`.

#### Component: etaf-list (&key items on-select checkbox selected)

Render a selectable list. ITEMS contain `:key`, `:title` and optional `:description`; selection is reported to ON-SELECT.

**Arguments.** Keys are unique and titles are nonempty strings; an empty list is allowed. ON-SELECT is optional; no selection state is created by the List.

**Semantics.** Each row is one stretched ghost button whose label is the title, with the description on the following line. The list is a vertical focus group, so arrows move between rows and every row keeps the full catalog button behavior — pointer, help text, activation and disabled support through the composed button.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ITEMS is not a proper list of items with unique keys, nonempty string titles and optional string descriptions, or ON-SELECT is neither a function nor nil.

**Example.**

```elisp
(etaf-list :on-select #'open-item
           :items '((:key a :title "Alpha" :description "first")
                    (:key b :title "Beta")))
```

## Pagination

<!-- index: etaf-pagination; controller pager; page summary -->

#### Component: etaf-pagination (&key controller previous-ref next-ref previous-label next-label class color bgcolor border padding aria-label)

Render a controlled pager whose callbacks follow its committed CONTROLLER.

**Arguments.** CONTROLLER is a [Data Controller](data-controllers.md); when it is nil the pager shows its safe empty state (page 1 of 1 with no items). PREVIOUS-REF and NEXT-REF name the two buttons. PREVIOUS-LABEL and NEXT-LABEL override the complete Button captions. CLASS, COLOR, BGCOLOR, BORDER and PADDING override the surface, and ARIA-LABEL defaults to `"Pagination"`.

**Semantics.** The pager reads the controller's page, page size, total and status. It disables a button at the boundary and while a load is loading or refreshing; pressing one advances or retreats the controller through `etaf-data-previous-page` and `etaf-data-next-page`. The centre shows `"Page X / Y"` above `"A–B of T"`, the range of the items currently shown, painted with `:ui-pagination-muted-fg`. The bar is a wrapping row inside the `navigation` role, so it reflows in a narrow window instead of clipping.

**Returns.** A View.

**Errors.** The pager composes ordinary buttons; no prop is validated beyond the labels and references it forwards.

**Example.**

```elisp
(etaf-pagination :controller controller :previous-ref 'prev :next-ref 'next)
```

**See also.** `etaf-data-next-page`, `:ui-pagination-muted-fg`.

## The pagination token

<!-- index: ui-pagination-muted-fg; page summary color -->

#### Token: :ui-pagination-muted-fg

The color of the pagination summary line.

**Semantics.** The `"A–B of T"` range uses this color while the page counter stays in the default foreground, so the exact range reads as supporting detail. The pager supplies a built-in fallback, so it paints without a provided Theme.

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected input through `etaf-check-prop`, naming the component, property, received value and expectation: duplicate keys or labels, an active or current key that is not in the items, an open list whose keys are not items, a bad section content, and non-function callbacks where one is required.
- Selection never mutates the caller's value: the callbacks receive the next key or key list and the application stores it, so a rejected or ignored change leaves the component showing its previous state.
- A tree's Right/Left return `release` when the focused row is not a branch or when the requested action would not change anything, so the direction key falls through to the surrounding layout instead of being consumed.
- A pager without a controller is not an error: it renders its empty state and keeps the buttons disabled.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Data Controllers](data-controllers.md).

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-tabs :active 'all :on-change #'ignore
              :items '((:key all :label "All" :count 12) (:key open :label "Open")))
   (etaf-list :on-select #'ignore
              :items '((:key a :title "Alpha" :description "first")
                       (:key b :title "Beta")))))
```
