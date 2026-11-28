# Hosts

A *Host* is the View node that owns an Ebox node: the unit that Ebox lays out, styles, paints and hit-tests. Every visual part of a user interface is a Host, and everything else in a View exists to compose, repeat or replace Hosts. This chapter defines the eight Host kinds, the properties they accept, how properties from several sources are combined, how Host metadata becomes selector subjects, and the functions that resolve Host references and read committed geometry.

The View grammar, the evaluation of property expressions and the identity of Host nodes are defined in [Views](views.md). Components, `:use` Behaviors and caller attributes belong to the [Component](components.md) and [Behavior](actions-behaviors-and-error-boundaries.md) chapters; how style properties are declared and cascaded belongs to the style chapters. This chapter is the reference for the Host layer itself.

<!-- index: Host; Host kind; semantic property; Host reference; selector subject; geometry query -->

## Model

### The only View node with an Ebox node

A View is a tree of nodes. When a View is mounted or rendered, ETAF lowers it to a retained tree of segments; a Host segment is the only one that owns an Ebox node.

- A Host node is written with a Host name — `text`, `box`, `fragment`, `row`, `column`, `flex`, `grid` or `image` — its properties and its children.
- A Host segment owns exactly one Ebox node, or none for `fragment`, whose children join the enclosing layout directly.
- When a View produces several roots, the renderer adds one column wrapper of its own; that wrapper is not a Host and carries no application properties.
- Only Hosts carry style properties, host references and accessibility metadata, and only Hosts can be measured by the geometry queries.

A Host is also the unit of identity in a View: reconciliation matches Host children by their name and `:key`, as [Views](views.md#identity) describes, and a matched Host keeps its Ebox node and its retained state.

### The eight Host kinds

| Host | Content | Default role in layout |
| --- | --- | --- |
| `text` | exactly one text payload | text laid out by its parent |
| `box` | children | block-level flow container |
| `fragment` | children | no node; children join the parent |
| `row` | children | one horizontal line, no wrapping |
| `column` | children | vertical stack |
| `flex` | children | flex container |
| `grid` | children | grid with automatic tracks |
| `image` | none | fixed `:columns` × `:rows` character cell |

Every Host accepts semantic properties, event properties and pointer affordances; a `fragment` has no node to carry them. Style properties are accepted by kind:

| Host kinds | Accepted style properties |
| --- | --- |
| `text` | the typography and paint set: `:color`, `:background-color`, `:font-family`, `:font-size`, `:font-weight`, `:font-style`, `:text-decoration-line`, `:text-decoration-color`, `:text-decoration-style` |
| `box` | that set, plus `:text-align`, `:wrap-mode`, and the box model and geometry set |
| `row`, `column` | the Box set, plus `:cross-align` and `:item-gap` |
| `flex` | the Box set, plus `:flex-direction`, `:flex-wrap`, `:flex-flow`, `:justify-content`, `:align-items`, `:align-content`, `:row-gap`, `:column-gap` and `:gap` |
| `grid` | the Box set, plus `:grid-template-columns`, `:grid-template-rows`, `:grid-auto-columns`, `:grid-auto-rows`, `:grid-auto-flow`, `:justify-items`, `:justify-content`, `:align-items`, `:align-content`, `:row-gap`, `:column-gap` and `:gap` |
| `image` | none; its source and size come from `:src`, `:columns`, `:rows`, `:adapter` and `:inset` |
| `fragment` | none; it has no node |

A child of a `flex` or `grid` Host may also declare the item properties (`:order`, `:flex-grow`, `:flex-shrink`, `:flex-basis`, `:flex`, `:align-self`, `:justify-self`, `:grid-column`, `:grid-row`, `:grid-column-span`, `:grid-row-span`), which affect how its parent places it. Style properties start at the schema defaults — no padding, margin or border, inherited color, normal font weight and style, and the layout defaults named with each kind — so a Host with no style properties is already laid out. [Style Properties](style-properties.md) lists every property with its value grammar, initial value and inheritance.

```elisp :figure The eight Host kinds; fragment is the one without an Ebox node
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 0)
   (grid :width '(ch 44)
         :grid-template-columns '((fr 1) (fr 1) (fr 1) (fr 1))
         :gap '((lh 0) (ch 1))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "text"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "box"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "row"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "column"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "flex"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "grid"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "image"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
          (text :color (etaf-theme-token :ui-disabled-fg "#687386") "fragment")))
   (text :color (etaf-theme-token :ui-muted-fg "#526174") "fragment 不产生节点；其余七种各绑定一个 Ebox 节点。")))
```

## Host kinds

### text

#### Host: text

A Host showing one run of text; the leaf of most interfaces.

**Semantics.**

- The content is exactly one payload: a string, or an `expr` whose result resolves to text. A second child is a render error, and an empty string is valid.
- The renderer builds it as one Ebox text node. Ebox lays it out inside its parent: a `text` Host inside a `box` participates in a flow paragraph, and one inside a `row` becomes a one-line item.
- It accepts the typography and paint properties. Layout properties such as `:padding`, `:width`, `:wrap-mode` and `:text-align` belong to the container that lays the text out; the text Host inherits typography, color and `:text-align` from its ancestors.
- Its content is not interactive by itself: a click on it is handled by the nearest activating ancestor unless the `text` Host declares an interaction property.

**Errors.** `error→ etaf-renderer-error` when the payload is not text, for example a number in a structural position or a payload that resolves to a non-string.

**Example.** `(text :font-weight 'bold "Unread (3)")`

**See also.** the `box`, `row` and `image` Hosts.

### box

#### Host: box

A block-level flow container; the general-purpose layout Host.

**Semantics.**

- Children are laid out in normal flow. Consecutive inline children (typically `text` Hosts) become one anonymous paragraph, so a sentence written as several text nodes wraps as a whole; block children start a new line.
- It accepts the full box model and geometry set: padding, margin, border, width and height with their min/max forms, `:box-sizing`, `:position`, `:left`/`:top`, `:z-index`, `:layer`, `:anchor`, `:placement`, `:visibility`, `:outer`, `:overflow`, `:scroll-anchor`, `:border-radius`, `:wrap-mode`, `:text-align`, and the item properties when the box is a flex or grid item.
- `:overflow scroll` or `:auto` with a bounded height makes the box a scroller that [Scrolling](scrolling.md) describes.

**Example.** `(box :background-color "gray15" (text "Ready"))` is already a usable panel; `(box :padding '(px 4) :border-radius '(px 1) ...)` adds breathing room and a rounded corner.

**See also.** the `column` and `row` Hosts for the common stacking cases, and [Boxes and Normal Flow](boxes-and-normal-flow.md) for the layout rules.

### fragment

#### Host: fragment

A grouping Host with no Ebox node.

**Semantics.**

- The renderer inserts its children into the enclosing layout in order, so a fragment adds no visual box, no spacing and no style target. It is how a Component returns several roots, as [Views](views.md#fragments) describes.
- A fragment accepts `:key` and the compiler directives (`:if`, `:else-if`, `:else`, `:for`). Other Host properties have no node to act on and are disregarded.

**Example.** `(fragment (text "left") (text "right"))` places two text nodes next to each other in the parent.

**See also.** [Fragments](views.md#fragments).

### row

#### Host: row

A container that lays its children out in one horizontal line.

**Semantics.**

- Children are placed left to right and do not wrap; a child wider than the remaining space is shrunk to it, and the row's height is the tallest child.
- `:cross-align` (initial `stretch`) aligns children on the vertical axis; `:item-gap` (initial zero) sets the horizontal spacing between them.
- It accepts the Box set plus `:cross-align` and `:item-gap`. Use a `flex` Host when the content must wrap or reverse; use `row` for toolbars, button strips, breadcrumbs and single-line status bars.

**Example.** `(row :item-gap '(ch 1) (text "Name:") (text (expr name)))`

**See also.** `column`, which stacks children vertically with the same cross-axis and gap properties.

### column

#### Host: column

A container that stacks its children vertically.

**Semantics.**

- Children are laid out top to bottom in order; `:cross-align` aligns them on the horizontal axis and `:item-gap` sets the vertical spacing.
- It accepts the Box set plus `:cross-align` and `:item-gap`. It is the usual root of a page, a form or a list of rows.

**Example.** `(column :item-gap '(lh 1) ...heading... ...rows...)`

**See also.** `row`.

### flex

#### Host: flex

A full flex container.

**Semantics.**

- Direction, wrapping, main-axis distribution and cross-axis alignment come from the flex container set: `:flex-direction` (initial `row`), `:flex-wrap` (initial `nowrap`), `:flex-flow`, `:justify-content` (initial `flex-start`), `:align-items` and `:align-content` (initial `stretch`), plus `:row-gap`, `:column-gap` and the `:gap` shorthand.
- Unlike `row`, a flex container wraps, reverses, and honors the item properties of its children, so a toolbar that overflows can wrap to the next line.
- It accepts the Box set plus the flex container set.

**Example.** `(flex :flex-wrap 'wrap :gap '((lh 0) (px 2)) ...cards...)` lays cards out in a wrapping strip.

**See also.** [Flex Layout](flex-layout.md).

### grid

#### Host: grid

A grid container with explicit or automatic tracks.

**Semantics.**

- `:grid-template-columns` and `:grid-template-rows` define tracks; left at their initial nil the grid creates automatic tracks. `:grid-auto-columns`, `:grid-auto-rows` and `:grid-auto-flow` control tracks and placement outside the explicit template; `:justify-items` (initial `stretch`), `:justify-content`, `:align-items` and `:align-content` align items and the track group; `:row-gap`, `:column-gap` and `:gap` set spacing.
- Children place themselves with the item properties `:grid-column`, `:grid-row`, `:grid-column-span`, `:grid-row-span`, `:justify-self` and `:align-self`.
- It accepts the Box set plus the grid container set.

**Example.** `(grid :grid-template-columns '((fr 1) (fr 2)) ...cells...)` gives a two-column form whose second column is twice as wide.

**See also.** [Grid Layout](grid-layout.md).

### image

#### Host: image

A fixed-size local picture.

**Semantics.**

- `:src` is a local file path or an Emacs image descriptor `(image ... :type TYPE :file FILE)` or `:data DATA`. `:columns` and `:rows` are the positive integer character-cell size of the picture.
- `:adapter` selects how the source becomes cells: `auto` (initial) tries a graphics image on a graphical frame, then Kitty terminal graphics on compliant 24-bit text frames, then the registered converters, then a monochrome ASCII placeholder; `kitty` tries only Kitty terminal graphics before falling back to the placeholder; `text` skips both graphics paths; `placeholder` always makes the ASCII form. A missing or undecodable source becomes a placeholder rather than an error.
- `:inset` is nil or `(TOP . BOTTOM)`, the pixels of vertical room a graphics image leaves empty inside its rows.
- An image Host takes no children; it is a leaf, and style properties such as `:padding` or `:color` are disregarded because the picture fills its cell.

**Errors.** `error→ etaf-renderer-error` when `:src` is not a path or a descriptor with `:type` and `:file`/`:data`, when `:columns` or `:rows` is not a positive integer, when `:adapter` is not `auto`, `kitty`, `text` or `placeholder`, when `:inset` is not nil or a non-negative pair, or when the Host is given children.

**Example.** `(image :src "/tmp/chart.png" :columns 40 :rows 10 :adapter 'placeholder)`

**See also.** [Images](images.md).

#### Function: etaf-image-kitty-available-p (&optional frame)

Return a capability plist when FRAME supports Kitty terminal graphics, or nil.

**Arguments.** FRAME defaults to the selected frame.

**Semantics.** Delegates to `ebox-image-kitty-available-p` so ETAF applications can query `:cell-width`, `:cell-height` and `:local` on Kitty-capable text terminals (for aspect-ratio grid sizing of `image` Hosts) without calling Ebox directly.

**Returns.** A fresh capability plist `(:cell-width W :cell-height H :local BOOL)`, or nil.

**See also.** `ebox-image-kitty-available-p` in [Images](images.md).

## Semantic properties

Semantic properties are ETAF's own Host metadata: identity, accessibility, references, behaviors, pointer feedback, keyboard operation and layout persistence. They do not change a node's visual style; they reach the runtime, the Ebox node, or both, and this chapter defines them all.

A semantic property is validated when its Host commits. A successful commit keeps the previous state; a failing one publishes nothing for that Host, so a Host never carries a half-applied property set. Event properties (`:on-*`) are the third domain; [Events](events.md) defines them, and [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md) defines how they compose. `:on-direction` is a keyboard property and is defined in the [Keyboard](keyboard.md) chapter.

### Values and conflicts

A Host can receive properties from three places. Inline properties are written on the Host itself. *Fallthrough attributes* are the attributes a caller passes to a Component call whose root is a Host; they are merged into that root Host. `:use` attaches Behaviors, whose attributes are merged into the Host as well. The theme and component styles add Ebox-level inputs, not Host properties: a theme's Host defaults and a Component's style rules are applied by the Ebox cascade underneath the Host's own declarations.

The merge keeps each domain coherent:

| Property | When several sources provide it |
| --- | --- |
| style property | a non-nil value from the outer source replaces the inner one; nil leaves the inner value in place; a Behavior's style value fills only when the Host has none |
| `:class` | the values merge into one stable union, inner tokens first, duplicates removed |
| `:id` | the outer value replaces the inner one |
| event property | the callbacks compose, inner first, and the inner callback's return value is preserved |
| `:disabled` | the values combine with `or` |
| `:use` | the Behavior source lists concatenate |
| `:keys` | the binding lists merge; the Host's own entries take precedence |
| other semantic properties | the outer value replaces the inner one; a Behavior fills only when the Host has none |
| `:role` and most `:aria-*` | owned semantics: two different values are a conflict, not an override |

A conflict between owned semantics is an error rather than a silent override, because changing a control's role or accessible state behind the caller's back would break both the accessibility contract and the selectors that matched it. `:aria-label` and `:aria-description` are the exceptions: they describe rather than identify, so a caller may replace them.

**Errors.** `error→ etaf-component-call-error` when a fallthrough or Behavior value conflicts with an owned semantic property of the root Host; the message names the Component or Behavior, the Host kind and the property.

**See also.** the [Component chapter](components.md) for fallthrough attributes, and [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md) for `:use`.

### Roles and ARIA

A Host's accessible metadata is its `role` attribute and its `aria-*` attributes on the Ebox node. They are ordinary selector subjects, so stylesheets and tests can select a Host by role or accessible state, and they are the facts the keyboard and focus layers read.

- `:role` writes the node's `role` attribute. Roles such as `button`, `option`, `checkbox` and `slider` carry conventional behavior in the [Focus](focus.md) and [Keyboard](keyboard.md) chapters.
- Every `:aria-*` property writes one attribute with the name after the colon. Explicitly passing nil still writes the attribute with a nil value, which is different from omitting it: a nil attribute is present, so a selector that tests the attribute matches, and Ebox's inherited-value blocking sees the difference.
- The values are strings, numbers or symbols; numbers and symbols are converted to their printed form. A list or other value is rejected with `error→ etaf-renderer-error`.
- `:role` and the identifying `aria-*` attributes are owned semantic properties as described above; `:aria-label` and `:aria-description` are descriptive and may be replaced by a caller.

**Example.** `(box :role "progressbar" :aria-valuenow 62 :aria-valuemin 0 :aria-valuemax 100 ...)`

**See also.** the [Focus](focus.md) and [Keyboard](keyboard.md) chapters for role-specific behavior.

### Identity and metadata

#### Property: :class

One or more class names that selectors and component styles match.

**Arguments.** A string, a symbol, or a proper list of strings and symbols. A string is split on whitespace and a list is flattened, so `"task done"` and `'(task done)` both give the classes `task` and `done`. The default is nil, no classes. Any other value is rejected.

**Semantics.** Classes are written to the Ebox node and become selector subjects: a rule such as `.task` matches the Host, and [Component Styles and Themes](component-styles-and-themes.md) explains how a Component's own rules use them. When a caller attribute or a Behavior contributes `:class`, the two token sets merge into a stable union with the inner Host's tokens first and duplicates removed, so a caller can add a class without dropping the Host's own.

**Example.** `(text :class "status error" "Deployment failed")`

**Errors.** `error→ ebox-error` when the value is not a string, symbol or list of them and the node is built; `error→ etaf-component-call-error` when a merged value is invalid.

**See also.** [Selector subjects](#selector-subjects) and [Component Styles and Themes](component-styles-and-themes.md).

#### Property: :id

The identifier of a Host, matched by `#name` selectors.

**Arguments.** A string, symbol or number used as a token value; nil means no id.

**Semantics.** The value is written to the Ebox node as its id and becomes a selector subject. A caller attribute replaces the root Host's id; it does not merge.

**Example.** `(box :id "results" ...)` with a rule `#results { ... }`.

**See also.** [Selector subjects](#selector-subjects).

### Accessibility and focus

#### Property: :role

The accessible role of a Host.

**Arguments.** A symbol or a string, or nil. Values are not restricted to the ARIA vocabulary; ETAF only refuses values that are neither a symbol nor a string.

**Semantics.** A non-nil role is written to the node as its `role` attribute and becomes a selector subject. The [Focus](focus.md) and [Keyboard](keyboard.md) chapters define how roles such as `button`, `slider`, `separator` and `option` participate in focus order, arrows and activation. `:role` is owned semantics: once the Host declares it, a caller or Behavior cannot replace it with a different value.

**Example.** `(text :role 'button :tab-index 0 :on-press #'retry "Retry")`

**Errors.** `error→ etaf-renderer-error` when the value is neither a symbol, a string nor nil.

**See also.** `:aria-*`, [Roles and ARIA](#roles-and-aria).

#### Property: :aria-*

An attribute in the ARIA namespace; `:aria-*` stands for every property whose name begins with `:aria-`.

**Arguments.** nil, a string, a number or a symbol. nil is a supplied value: it writes a present nil attribute rather than omitting the attribute.

**Semantics.** The property writes one attribute whose name is the property name after the colon, so `:aria-label` writes `aria-label` and `:aria-selected` writes `aria-selected`. The attribute is a selector subject, and Ebox reads some attributes as state (`aria-selected`, `aria-checked`, `aria-current`) when a focus group chooses its entry. Explicit nil being present matters twice: a selector written for the attribute matches, and an inner nil blocks an ancestor's value in the Ebox inheritance rules.

**Example.** `(box :role "listbox" :aria-label "Open tabs" ...)`

**Errors.** `error→ etaf-renderer-error` when the value is not nil, a string, a number or a symbol.

**See also.** `:role`, [Roles and ARIA](#roles-and-aria).

#### Property: :tab-index

The position of a Host in the Tab order.

**Arguments.** nil or an integer. The default is nil, which makes the Host no focus stop.

**Semantics.** A non-negative integer makes the Host a focus stop: focus navigation can enter it with Tab and leave it with Tab. Stops are ordered by the integer, lower first, and stops with equal indices keep tree order, so a region's controls are visited together. A Host without a tab index can still be activated by pointer and can still contain focus stops of its own. The [Focus](focus.md) chapter defines the rest of the navigation model.

**Example.** `(row :tab-index 0 :on-press (lambda () (open item)) (text (expr item)))`

**Errors.** `error→ etaf-renderer-error` when the value is not an integer or nil.

**See also.** the [Focus](focus.md) chapter.

#### Property: :disabled

Mark a Host as unavailable without removing it.

**Arguments.** nil or t. Any other value is rejected. The default is nil.

**Semantics.** A disabled Host does not run its event callbacks or `:keys`; its Behaviors are not installed; Ebox gives it an empty keymap, so a disabled control blocks an inherited keymap instead of falling through to it; and its node derives the `disabled` selector state, which stylesheets can match with `:disabled`. The Host stays visible and keeps its place in the layout.

**Example.** `(text :role 'button :tab-index 0 :disabled (not (etaf-value valid)) :on-press #'save "Save")`

**Errors.** `error→ etaf-renderer-error` when the value is not nil or t.

**See also.** [Events](events.md) for activation and [Focus](focus.md) for focus.

#### Property: :focus-group

Make a container's focus stops one stop of the enclosing navigation.

**Arguments.** nil, `vertical`, `horizontal` or `grid`. The default is nil.

**Semantics.** A container with a focus group contributes only its entry to Tab order: Tab enters the group at the remembered member, or at the member whose `aria-selected`, `aria-current` or `aria-checked` is true, or at the first member. Inside the group, arrows move between members in the declared direction, and leaving an edge moves to the nearest stop outside. Nested groups belong to their nearest ancestor group.

**Example.** `(column :focus-group 'vertical ...rows...)`

**Errors.** `error→ etaf-renderer-error` when the value is not nil, `vertical`, `horizontal` or `grid`.

**See also.** the [Focus](focus.md) chapter.

#### Property: :key-scope

A non-modal keyboard boundary for a nested application or pane.

**Arguments.** `local` enables the boundary; nil leaves the Host transparent to keyboard scope resolution.

**Semantics.** While focus, or the point fallback when no focus exists, is inside the Host, the nearest local or modal boundary contains keys, dismissal, direction and edge navigation, regions, help preparation and palette controls. Unbound printing keys and unhandled Escape do not invoke enclosing Host or buffer actions. Native editing retains its keys. Moving point outside a still-focused local subtree does not change ownership; a real focus change does. Pointer actions and explicit focus or region jumps can leave a local boundary. A dismissal callback can explicitly focus the enclosing application without disposing the nested application; a region on the same Host remembers its eligible entry control.

**Returns.** This property configures resolution; it has no separate result or focus state.

**Errors.** Unsupported values signal `error→ etaf-renderer-error`.

**Example.** `(column :key-scope 'local :on-dismiss (lambda () (etaf-focus nil 'toolbar)) ...)`

**See also.** `:focus-scope`, `:region`, `:on-dismiss`, [Keyboard interaction](keyboard.md).

#### Property: :focus-scope

Confine keyboard operation to a subtree.

**Arguments.** nil or `modal`. The default is nil.

**Semantics.** While a `modal` Host is visible, Tab, arrows and `:keys` resolve inside it first; the innermost visible modal scope wins. Outer `:keys` are unreachable, and printing keys that nothing inside the scope binds are ignored instead of reaching the buffer's keymaps. This is how a dialog keeps focus while it is open.

**Example.** `(box :focus-scope 'modal :role "dialog" ...)`

**Errors.** `error→ etaf-renderer-error` when the value is not nil or `modal`.

**See also.** the [Focus](focus.md) and [Keyboard](keyboard.md) chapters.

#### Property: :region

Declare a user-addressable functional region on a Host.

**Arguments.** A property plist whose keys are `:id` (required, a non-nil symbol that identifies the region), `:label` (a display name), `:key` (one hint character other than `?`), `:enter` (the default entry Host reference) and `:neighbors` (a plist mapping `:left`, `:right`, `:up` and `:down` to region ids). Unknown keys are rejected.

**Semantics.** Regions nest by Host ancestry, so a pane inside a window is found inside its parent region. The [Region Navigation](region-navigation.md) chapter defines the selector that jumps between regions, the entry memory and how adjacency orders the movement.

**Example.** `(box :region (list :id 'editor :label "Editor" :key ?e :neighbors (list :right 'files)) ...)`

**Errors.** `error→ etaf-renderer-error` for a malformed plist, an unknown key, a missing or non-symbol `:id`, an invalid `:key`, or a neighbour direction outside the four directions.

**See also.** [Region Navigation](region-navigation.md).

### References and Behaviors

#### Property: :ref

The application's handle to a Host.

**Arguments.** nil, a symbol or a function. Other values are rejected.

**Semantics.** An explicit reference registers the committed Host under that value, and the geometry queries, focus functions and event functions accept it. A symbol is the common form; an instance-scoped opaque handle comes from `etaf-local-ref`. A function is accepted as an opaque handle and is never called by ETAF. A Host that carries no non-nil semantic property is not registered and cannot be found by a reference; `:ref` itself is such a property, so an explicit ref always registers. ETAF also gives every Host an internal generated reference that applications cannot reach.

When two committed Hosts carry the same explicit reference, the later commit wins; if that Host leaves, the reference resolves to nothing even though the other Host still carries it. An explicit reference is therefore a name for one Host at a time, not a shared alias.

**Example.** `(box :ref 'search-results ...)`, then `(etaf-host-ref-bounds runtime 'search-results)`.

**Errors.** `error→ etaf-renderer-error` when the value is not nil, a symbol or a function.

**See also.** [Host references](#host-references) and `etaf-local-ref`.

#### Property: :use

Attach one or more Behaviors to a Host.

**Arguments.** A Behavior source: a symbol naming a zero-argument constructor, a Behavior spec created with `etaf-behavior-create`, or a proper list of such sources. nil is accepted and attaches nothing.

**Semantics.** Each source resolves to a Behavior whose attributes are merged into the Host as [Values and conflicts](#values-and-conflicts) describes: event callbacks and `:disabled` compose, style values fill only where the Host is silent, and owned semantic properties conflict rather than override. A disabled Host installs no Behaviors. [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md) defines constructors, the optional installer and cleanup.

**Example.** `(text :use 'etaf-focusable "Open")`

**Errors.** `error→ etaf-renderer-error` when the value is not a Behavior source or a proper list of them; `error→ etaf-behavior-error` for an unknown constructor, a constructor that returns something else, or two Behaviors with the same name on one Host.

**See also.** [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md).

### Presentation and pointer feedback

#### Property: :help-echo

The help text shown for a Host.

**Arguments.** A string, a native three-argument `help-echo` function, or nil.

**Semantics.** Ebox paints it as the node's `help-echo` text property, so Emacs shows the text (or calls the function) when the pointer rests on the Host. It does not create an activation boundary, a keymap or an ETAF hover event. A present nil blocks an ancestor's value.

**Example.** `(text :help-echo "Reload from disk" :on-press #'reload "Reload")`

**See also.** `:hover-style` and `:hover-content` for visual feedback.

#### Property: :pointer

The mouse pointer shape for a Host.

**Arguments.** An Ebox pointer symbol such as `hand`, or nil.

**Semantics.** The pointer is painted as the node's `pointer` text property. A Host with a press or drag callback receives the `hand` pointer automatically unless it supplies `:pointer`; an explicit nil keeps the default pointer and blocks an ancestor's value.

**Example.** `(text :pointer 'hand :on-press #'open "Read more")`

**See also.** the pointer affordances described with `:help-echo` and `:hover-style`.

#### Property: :hover-style

The paint a Host shows while the pointer is over it.

**Arguments.** An even plist of paint properties: `:color`, `:background-color`, `:font-weight`, `:font-style`, `:text-decoration-line`, `:text-decoration-style` and `:text-decoration-color`. Theme tokens are resolved like any other style value.

**Semantics.** While the pointer rests over the Host, Ebox repaints it with these declarations merged over its computed paint, so the fill follows the Host's own `:border-radius` and covers every padding row; rendered output carries the same declarations as a native mouse face instead. Leaving restores the resting paint. An unsupported key or an odd plist is an error when the node paints. A present nil blocks the hover for that subtree.

**Example.** `(row :hover-style (list :background-color "gray25") ...menu item...)`

**Errors.** `error→ ebox-error` for a property outside the paint list or an odd plist.

**See also.** `:hover-content`.

#### Property: :hover-content

Text shown in place of a Host's content while it is hovered.

**Arguments.** A string, or a zero-argument function returning a string; other values are accepted but show nothing. nil means no replacement.

**Semantics.** While the pointer is over the Host — or keyboard focus enters it, since focus shows the same affordance as hovering — ETAF replaces the text of the Host's first text descendant with the value, and restores the original text when the pointer or focus leaves. This is how a compact cell reveals a full label, a short path reveals a longer one, or a status shows its details on demand. Properties of the Host remain in effect; only the text changes.

**Example.** `(text :hover-content "src/etaf-runtime.el (1420 lines)" "runtime.el")`

**See also.** `:hover-group`, which switches several Hosts together.

#### Property: :drag-lock-modifier

Keep a drag gesture alive across a button release.

**Arguments.** One of `shift`, `control`, `meta`, `super` or `hyper`, or nil. The default is nil, where releasing the button ends the gesture.

**Semantics.** A drag that starts with the lock modifier set stays active after the button is released, until the next press; the application can therefore implement click-then-drag sequences without holding the button. The property requires a drag callback: a lock modifier on a Host with no drag gesture is an error when the Host mounts, because there is no gesture to keep alive.

**Example.** `(box :on-drag (lambda (gesture) (move-panel gesture)) :drag-lock-modifier 'shift ...)`

**Errors.** `error→ error` when the modifier is unsupported, or when `:drag-lock-modifier` is given without a drag callback on the same Host.

**See also.** [Dragging and Gestures](dragging-and-gestures.md).

#### Property: :drag-edge

Report edge intent while a drag rests in or past a window edge band.

**Arguments.** Any non-nil value enables the phases; nil, the default, leaves the gesture silent.

**Semantics.** While a drag that started on this Host is in progress, has moved away from its press and rests within `ebox-drag-edge-band` lines or columns of a window edge or beyond it, Ebox delivers an `edge` phase after `ebox-drag-edge-interval` seconds and repeats it at that cadence until the pointer moves back into the interior or the gesture ends. `:edges` names the touched or passed edges in the fixed order `left`, `right`, `top`, `bottom`; a corner names both. The phase reports intent only: Ebox does not scroll and does not change `:delta`, and a press resting at the edge without moving reports nothing. Past the edge, outside the window, the phases continue: `:overshoot` gives the pointer's distance past the text area in pixels and `:elapsed` the seconds since the previous phase, so a handler can scroll faster the further out the pointer is. The application owns the viewport, the scroll step and how a content-anchored target follows the scroll; see [Dragging and Gestures](dragging-and-gestures.md#edge-intent-and-scrolling).

**Example.** `(box :on-drag (lambda (gesture) (when (eq (plist-get gesture :phase) 'edge) (scroll-view (plist-get gesture :edges)))) :drag-edge t ...)`

**See also.** [Dragging and Gestures](dragging-and-gestures.md#edge-intent-and-scrolling), `:on-drag`, `:drag-lock-modifier`.

#### Property: :hover-group

Make several Hosts share one hover state.

**Arguments.** Any value usable as a group key; nil gives the Host its own private group.

**Semantics.** Every Host that has both `:hover-content` and the same group key switches its hover content together: hovering or focusing any member shows the content of all members. The members need not be siblings, and a group with one member behaves like a plain `:hover-content`.

**Example.** `(row (text :hover-group 'toolbar :hover-content "Bold (C-b)" "B") (text :hover-group 'toolbar :hover-content "Italic (C-i)" "I"))` shows both full labels when either button is hovered.

**See also.** `:hover-content`.

### Layout persistence

#### Property: :sticky

Keep a Host visible while its buffer scrolls.

**Arguments.** nil or `top`. Any other value is rejected. The default is nil.

**Semantics.** A `top` Host mirrors its first row into a displaying window's header line once that window scrolls completely past the Host's rows (`window-start` reaches the line after the Host), without moving `window-start`, so the original row and the mirror never appear simultaneously. A primary click on a mirrored cell runs that cell's press binding at its buffer position. The mirror refreshes on commits, retained Host updates and refits, and is cleared when the Host stops being sticky or the Runtime unmounts. The Runtime owns the buffer's `header-line-format` while a sticky Host is mounted, and one Host per Runtime is sticky: the last committed `top` Host wins.

Sticky is a lightweight single-row header mirror for natively scrolling buffers, subject to Emacs header-line limits: it mirrors only the first row at the buffer's layout width (narrower second windows clip it) and cannot receive point, keyboard focus or native text input. Lay out fixed interactive toolbars as a non-scrolling sibling above an `:overflow` `scroll` viewport instead.

**Example.** A build log whose header stays visible while the log scrolls.

```elisp :run
(etaf-view
 (column
  (row :sticky 'top :background-color "gray20"
       (text :font-weight 'bold "Build log"))
  (text :for (line '("12:01  configure"
                     "12:02  compile"
                     "12:03  link"
                     "12:04  test"
                     "12:05  package"
                     "12:06  publish"))
        :key line
        (expr line))))
```

**Errors.** `error→ etaf-renderer-error` when the value is not nil or `top`.

**See also.** [Viewport](viewport.md) and [Scrolling](scrolling.md).

#### Property: :translate

Declare a translation hint on a Host for page-translation extensions.

**Arguments.** nil, `t`, `yes`, `no` or `content`. Any other value is rejected. The default is nil.

**Semantics.** Stored as Runtime-owned semantic Host metadata and exposed through `etaf-runtime-host-tree` without affecting Ebox layout or styling. nil inherits from enclosing Hosts; `t` or `yes` marks the Host translatable; `no` excludes the Host and its subtree (useful for code blocks, identifiers and key caps); `content` marks a primary content region.

**Example.** `(box :translate 'no (text "M-x etaf-translate-toggle"))`

**Errors.** `error→ etaf-renderer-error` when the value is outside nil, `t`, `yes`, `no` and `content`.

**See also.** `etaf-runtime-host-tree` and `etaf-runtime-set-host-presentations`.

### Keyboard operation

#### Property: :keys

Declare Host key bindings that run while the Host has focus or contains point.

**Arguments.** A list of `(KEY COMMAND [LABEL])` entries: KEY is a key or key sequence as a `kbd` string or a vector, COMMAND is a zero-argument function, and the optional LABEL is a string that names the command in the ETAF help palette. nil declares no bindings.

**Semantics.** A binding works while focus, or point when nothing is focused, is inside the Host. The nearest Host that binds a key wins; a disabled Host contributes nothing; Host bindings take precedence over the buffer's own keymaps, including application emulation maps. A command runs like a keymap binding, so it may move focus or begin input on a Host it just revealed; wrap several writes in `etaf-batch` to publish them once. Keys and regions coexist: the framework reserves arrows, Tab, `?`, Escape, `M-g` and `C-g` for focus, help and region navigation, and a binding may not collide with a reserved key or with another sequence elsewhere in the same Runtime. [Keyboard](keyboard.md) defines the full model, including prefixes, reserved keys and diagnostics.

**Example.** `(row :tab-index 0 :keys (list (list "RET" (lambda () (open item)) "Open")) ...)`

**Errors.** `error→ etaf-renderer-error` from the keyboard layer at Host commit: a malformed entry, an empty key, a sequence that starts with a printing key, a framework-reserved key, or a collision with another binding in the same Runtime.

**See also.** [Keyboard](keyboard.md), and `:region` for region-level navigation.

#### Property: :help

Contribute non-binding guidance to the current scope's read-only keyboard help.

**Arguments.** Nil, a string, or a proper list of strings.

**Semantics.** `etaf-help-data` collects these notes from the opening Host scope, nearest first, stopping at the modal boundary. Use notes for workflow advice and limitations; keys and their labels come from the effective bindings and must not be repeated as a hand-written key table. These notes are not native hover text; use `:help-echo` for that.

**Errors.** `error→ etaf-renderer-error` when the value is neither nil, a string nor a proper list of strings.

**Example.** `(column :help "Changes are kept when you leave the editor." ...)`

## Selector subjects

A Host's identity and accessible metadata are the facts Ebox selector queries match:

- `:class` tokens become the node's classes; `:id` becomes its id.
- A non-nil `:role` becomes the `role` attribute.
- Every `:aria-*` property, including one explicitly set to nil, becomes an attribute with the name after the colon.
- The `disabled` state comes from the same `:disabled` input that protects activation, so a Host disabled at commit is matched by `:disabled`.

Selector matching follows the rendered Host tree, not the View tree, and comparison uses ECSS value formatting. The adapter facts `:selector-attributes` and `:selector-state` are how Ebox's library users attach extra subjects; they cannot be authored as View properties, and ETAF rejects them with `error→ etaf-renderer-error`. This is the boundary that lets component styles and application stylesheets select Hosts by meaning rather than by position; [Component Styles and Themes](component-styles-and-themes.md) builds on it.

## Host references

#### Function: etaf-local-ref (name)

Obtain a stable Host reference scoped to one Component instance.

**Arguments.** NAME is a non-nil symbol or string naming the reference within the instance.

**Semantics.**

- Call it while the Component is being set up, from `:bindings` or `:setup`. Equal names in one instance return the same opaque reference; different instances never share one, and a new instance gets a new reference. Pass it to a Host's `:ref`, or to the focus, event and geometry functions that take a Host reference.
- The reference is a name, not state and not a key: it identifies the Host it is attached to, not the current value of anything.
- Only a committed Host resolves a reference. If publication fails, the previous target stays; if the Host with the reference is removed, the geometry queries return nil; a subsequent instance never inherits the old handle.

**Returns.** An opaque non-nil reference value.

**Errors.** `error→ etaf-component-definition-error` when called outside Component setup, or when NAME is not a non-nil symbol or string.

**Example.** A panel keeps a handle to its body so callers can measure or scroll it.

```elisp
(etaf-define-component demo-panel ()
  :bindings ((body (etaf-local-ref 'body)))
  :view (box :ref body ...))
```

**See also.** `:ref`, [Host references](#host-references) and the [Component chapter](components.md).

### Uniqueness and lifetime

A reference resolves to at most one committed Host. That is why the old name for a removed Host returns nil instead of falling back to another Host that still carries it, and why an application should give each Host a distinct reference. `etaf-local-ref` maintains that property per instance; a hand-written symbol is the application's own responsibility. The generated references ETAF assigns to every Host are internal: they are not returned by the geometry queries and cannot be passed to them by an application.

## Geometry queries

The geometry queries read the *committed* geometry of a mounted Runtime: what Ebox last laid out and painted. They are read-only, they do not publish or re-layout, and they signal when the Runtime is not mounted. Query after a change has drained — after a write's publication, or after `etaf-runtime-flush` — to see the new geometry, as [Reactivity](reactivity.md#recovery) describes.

#### Function: etaf-host-ref-bounds (runtime host-ref)

Return the live buffer span of a Host.

**Arguments.** RUNTIME is a mounted Runtime. HOST-REF is an explicit reference registered in it.

**Semantics.** The result is a `(START . END)` cons from the Host's first visible painted cell to the end of its last painted row. A `:visibility hidden` Host in flow reports its blank slot; a Host that owns no cells, or whose reference is not registered, returns nil.

**Returns.** A cons of buffer positions, or nil.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**Example.** After layout, scroll a row into view from its bounds, or align a capture region to a panel.

**See also.** `etaf-host-ref-position`, `etaf-host-ref-size` and [Scrolling](scrolling.md).

#### Function: etaf-host-ref-at (runtime &optional position predicate)

Find the explicit reference of the Host painted at a buffer position.

**Arguments.** RUNTIME is a mounted Runtime. POSITION defaults to point. PREDICATE, when non-nil, is a function of one reference that decides which Host is acceptable.

**Semantics.** The lookup starts at the innermost Host painted at POSITION and walks outwards through its committed ancestors, returning the first explicit reference — or, with PREDICATE, the first reference PREDICATE accepts. Generated references are never returned, so a Host the application did not reference is invisible to this query. This is what lets a key handler map point to the row it is on; `etaf-host-ref-position` is its inverse.

**Returns.** A reference value, or nil when no matching Host encloses POSITION.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**Example.** `(etaf-host-ref-at runtime (point) (lambda (ref) (string-prefix-p "row-" (symbol-name ref))))` stops at the innermost ancestor whose reference names a row.

**See also.** `etaf-host-ref-position` and [Keyboard](keyboard.md).

#### Function: etaf-host-ref-size (runtime host-ref)

Return the painted size of a Host.

**Arguments.** RUNTIME is a mounted Runtime. HOST-REF is an explicit reference registered in it.

**Semantics.** The result is the committed border-box size of the Host's last layout: `(WIDTH-PIXELS . HEIGHT-ROWS)`. Margins and neighbouring columns are excluded, clipping reduces the reported size, and an absent or wholly hidden Host returns nil. Read it after layout to prepare resources — for example to decide whether a preview fits — not per frame.

**Returns.** `(WIDTH . HEIGHT)`, both positive, or nil.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**Example.** `(etaf-host-ref-size runtime 'preview)` decides whether the preview pane can show a picture.

**See also.** `etaf-host-ref-bounds`.

#### Function: etaf-host-ref-position (runtime host-ref)

Return the first live buffer position of a Host.

**Arguments.** RUNTIME is a mounted Runtime. HOST-REF is an explicit reference registered in it.

**Semantics.** The result is the position where the Host starts in the buffer. A Host that is not painted, or whose reference is not registered, returns nil.

**Returns.** A buffer position, or nil.

**Errors.** `error→ etaf-runtime-error` when RUNTIME is not mounted.

**Example.** `(goto-char (etaf-host-ref-position runtime 'message-log))` moves point to a log's first line.

**See also.** `etaf-host-ref-at`, which maps a position back to a reference.

### Reading geometry

The queries share one contract:

- They resolve references against committed state, so they never see a Host that has been removed or a property update that has not drained.
- They do not publish: calling them inside a watch or an effect does not cause another render, and they must not be used to poll per frame. Prepare resources after a layout change instead.
- They are safe to call from ordinary application code, including keyboard handlers, after checking that the Runtime is mounted.
- All four refuse an unmounted Runtime with `error→ etaf-runtime-error`.

## Semantic details

### Hosts and their Ebox nodes

Each Host kind lowers to one Ebox node:

| Host kind | Ebox node |
| --- | --- |
| `text` | a text node with the resolved payload |
| `box`, `row`, `column`, `flex`, `grid` | a container node holding the children's nodes |
| `image` | a leaf node holding the prepared image |
| `fragment` | nothing; its children's nodes are inserted into the parent's child list |

The mapping is one Host to one node, and the node moves with its Host: reconciliation matches segments by the Host's identity, and a matched Host keeps its node and updates its properties and children in place. A removed Host releases its node.

### Property resolution and cost

Property resolution is per Host: when a Host's segment initializes or its properties change, ETAF evaluates the Host's deferred property expressions once, resolves theme tokens, merges Behaviors, and computes the Ebox property list. The node is only updated when that list differs from the committed one.

- A Host whose properties and Theme are unchanged costs one identity comparison at update time.
- A Host whose plain style values changed follows a lighter path: the changed values are applied to the retained node without recomputing its metadata, Behaviors or children.
- Changing keys, semantics or the Theme takes the full path: the Host re-resolves its properties, re-registers its reference, and reconciles its Behaviors.
- The resolved property values reach the node for style properties; identity, accessibility and interaction facts are split off according to the table in [Selector subjects](#selector-subjects) and the interaction boundary [Events](events.md) describes. ETAF keeps its own copy of the semantic properties for its queries and for event dispatch.

The cost of a Host update is therefore proportional to that Host's own properties, not to the size of the View or the number of siblings; a Host that only reads static values costs nothing after it is first bound.

### Sticky Hosts

The sticky mechanism is owned by the Runtime, not by the layout. When a Host with `:sticky` `top` commits, the Runtime records it and prepares a single-row mirror string with primary mouse clicks forwarded to each cell's buffer position. The buffer's `header-line-format` uses a zero-allocation integer check against the window's start so the mirror appears only after the Host's rows have scrolled completely off screen and hides automatically once any part of the Host returns into view, without calling `set-window-start`. Because the header line belongs to the window, each window showing the buffer decides independently whether to show the mirror, though all windows share the buffer's rendered width. The mirror and its line span refresh on commits, retained Host updates and refits, and are removed completely when the Host clears `:sticky` or the Runtime unmounts.

#### Function: etaf-projection (runtime entries &optional source)

Return the projection of RUNTIME described by ENTRIES.

**Parameters.** ENTRIES is an alist of (REF . (SOURCE-START . SOURCE-END)), one per Host whose painted cells stand for a source range. SOURCE is the source buffer, defaulting to the runtime's own.

**Returns.** A vector of runs (DISPLAY-BEG DISPLAY-END SOURCE-BEG SOURCE-END) ordered by display position.

**Semantics.** It connects "where it is painted" with "which part of the source it comes from": an entry that paints nothing, and a source range of zero length, are skipped. The projection is plain data, so click mapping and caret placement both read it instead of walking the Host tree again.

**See also.** `etaf-projection-position`, `etaf-projection-source-offset`, [Text input](text-input.md).

#### Function: etaf-projection-source-offset (projection position)

Return the source offset that painted POSITION stands for.

**Parameters.** PROJECTION is what `etaf-projection` returned; POSITION is a buffer position.

**Returns.** A source offset.

**Semantics.** A position just after a run is the end of that run's source, which is where a caret sits when it is on the line's break. Any other position outside a run reports the nearest run's edge, and a position before the first run names the start of the source, so every position has an answer.

**See also.** `etaf-projection`, `etaf-projection-position`.

#### Function: etaf-projection-position (projection offset)

Return the painted position where source OFFSET lives, or nil.

**Parameters.** PROJECTION is what `etaf-projection` returned; OFFSET is a source offset.

**Returns.** A buffer position, or nil.

**Semantics.** An offset inside a run maps to its cell; an offset the paint skipped — such as a marker the render folded away — maps to the start of the next run, so placing a caret on folded content does not lose its place.

**See also.** `etaf-projection`, `etaf-projection-source-offset`.

## Errors and recovery

Host problems fall into distinct groups, by the layer that detects them.

| Failure | Condition | What remains |
| --- | --- | --- |
| A style property the Host kind does not accept, or an invalid `:class` value | `error→ ebox-error` when the node is built | Nothing is published for that Host; a mounted previous state stays |
| An invalid semantic value, or an Ebox-only property such as `:content` or `:selector-attributes` | `error→ etaf-renderer-error` before the Host commits | The previous committed properties and reference stay in effect |
| A conflicting owned semantic property from a caller or Behavior | `error→ etaf-component-call-error` during the merge | The previous committed properties stay; the caller must resolve the conflict |
| An invalid Behavior source or a duplicate Behavior | `error→ etaf-behavior-error` during resolution | The Host keeps its previous properties and Behaviors |
| `etaf-local-ref` outside setup or with an invalid name | `error→ etaf-component-definition-error` at the call | No reference is created; the component instance is unaffected |
| A geometry query on an unmounted Runtime | `error→ etaf-runtime-error` at the call | The query returns no value and no state changes |

The recovery principle is the same throughout: a Host commits as one unit. A failure leaves the previous committed Host in place — its properties, its node, its reference and its Behaviors — and the failing work is retried by the next drain if it was caused by data, or must be fixed in the source if it was caused by a malformed property. A Host that is removed simply stops existing for queries: its reference resolves to nothing and the geometry queries return nil.
