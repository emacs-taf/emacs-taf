# Context

*Context* is the one deliberately inherited dependency environment of ETAF. It is attached to Component instances, not to View nodes or global variables: one Component provides a value, and the Components below it read that value without it being passed through every prop. This chapter defines the two functions, the ancestor rule that decides what a Component sees, reactive context values, and the error condition.

Context is the mechanism behind subtree-wide configuration: a panel gives its descendants a locale, a tone, a controller or a data source; the Theme defaults that [Components](components.md) read are a Context value under the key `theme`, which [Component Styles and Themes](component-styles-and-themes.md) documents. Unlike a prop, a Context value is not part of a Component call; unlike a global variable, it is scoped to the subtree that provided it.

<!-- index: Context; provide; inject; inherited dependency; ancestor scope -->

## Model

### The ancestor chain

Every Component with `:setup` owns one *context frame*: a small table of keys to values whose parent frame is the frame of the Component that rendered it. A Component without `:setup` has no frame of its own and is evaluated in the frame of the Component that rendered it. A mounted View therefore forms a chain of frames from the root of the tree down to the Component currently being evaluated; `etaf-render` has the same root.

`etaf-provide` writes into the frame of the Component being evaluated. `etaf-inject` starts at that frame and walks up the chain until it finds the key, so the nearest provider wins. Nothing is copied when a value is provided or injected: the frame holds the exact object the provider gave.

### What a provider is for

A provider exists for values that a whole subtree must share and that no single Component call should carry as a prop:

- configuration of an embedded area, such as the tone or the locale of a panel;
- a controller or data source that several descendants read;
- a source of truth that descendants subscribe to, provided as a reactive value.

Visibility follows Component ancestry, not the position where a node appears on screen. That distinction matters for slots: content a caller passes into a Component is rendered with the caller's Context, and a Component's own `View` is rendered with the Component's Context, as [Visibility](#visibility) explains.

## Providing and injecting

#### Function: etaf-provide (key value)

Provide VALUE under stable Context KEY to the current subtree.

**Arguments.** KEY is a stable symbol: an ordinary non-nil, non-`t`, non-keyword symbol; a keyword, nil, t, a string or any other object signals `etaf-context-error`. VALUE is any object, stored as given, including nil.

**Semantics.** The call writes VALUE into the context frame of the Component being evaluated. The value is visible to that Component's own evaluation and to every descendant Component rendered below it; Components outside the subtree, including siblings and caller-provided slot content, are unaffected. Providing the same KEY again in the same frame replaces the value. The call does not notify readers: it changes what a later `etaf-inject` finds, not what already rendered, so a value that must follow application state is provided as a reactive source, as [Reactive context values](#reactive-context-values) describes. A provided nil is a value like any other and stops a lookup from reaching an outer provider.

**Returns.** VALUE.

**Errors.** `error→ etaf-context-error` with the message `"Context keys must be stable symbols: %S"` when KEY is not a stable symbol. Outside a Component evaluation — at top level, in a lifecycle hook or in an event callback — the call signals the ordinary `error` with the message `"ETAF provide requires Component setup or render context"`. During the pure render phase the call signals `error→ etaf-render-side-effect-error` with data `(provide-context)`, as [Reactivity](reactivity.md#rendering-is-free-of-side-effects) defines for side effects during rendering.

**Example.** A panel provides the tone its badges read.

```elisp
(etaf-provide 'tone "danger")
```

**See also.** `etaf-inject`, [Visibility](#visibility) and [Component Styles and Themes](component-styles-and-themes.md) for the `theme` key.

#### Function: etaf-inject (key &optional default (required-p nil required-p-supplied-p))

Return the nearest provided value for KEY.

**Arguments.** KEY is a stable symbol, validated like `etaf-provide`. DEFAULT is returned when KEY is absent anywhere in the chain. REQUIRED-P is explicit: when it is non-nil and was passed, absence signals an error instead. The optional third argument is explicit so a provided nil can be distinguished from a missing dependency: a provided nil is found and returned, while an absent key with REQUIRED-P signals.

**Semantics.** The lookup starts at the current frame and walks up the Component ancestry, so the nearest provider wins. A found nil is returned as nil, not replaced by DEFAULT. The read is available wherever a Component is evaluated — setup, `:bindings`, the render frontends and the effects or watchers created during setup, which keep their evaluation environment on later runs. A lifecycle hook or an event callback runs outside that evaluation, so a lookup there walks nothing and returns DEFAULT; capture the value or the source during setup instead.

**Returns.** The nearest provided value, or DEFAULT when the key is absent.

**Errors.** `error→ etaf-context-error` with the message `"Context keys must be stable symbols: %S"` when KEY is not a stable symbol, and with the message `"Missing ETAF Context dependency: %S"` when REQUIRED-P is non-nil and the key is absent from the whole chain. A failing lookup changes nothing.

**Example.** A field label falls back to a default currency.

```elisp
(etaf-inject 'currency "USD")
```

**See also.** `etaf-provide` and [Visibility](#visibility).

## Visibility

<!-- index: nearest provider; slot context; subtree scope -->

Context follows the Component tree. Three rules cover every case:

- A descendant Component sees the value; a sibling of the provider or a Component outside its subtree does not.
- The nearest provider of a key wins; an inner provider shadows an outer one below it.
- Caller-provided slot content keeps the caller's Context, and a `slot` fallback is rendered in the Component's own Context.

A panel that sets the tone of its own badges uses the first two rules.

```elisp :run
(etaf-define-component demo-tone-badge (&key label)
  :bindings ((tone (etaf-inject 'tone "neutral")))
  :view (box :role "status"
             (expr (format "%s — %s" label tone))))

(etaf-define-component demo-tone-panel ()
  :setup (etaf-provide 'tone "danger")
  :view (column (demo-tone-badge :label "Disk almost full")
                (demo-tone-badge :label "Backup stale")))

(etaf-view (demo-tone-panel))
```

The badge reads the tone from its ancestry; a badge rendered next to the panel, or passed into it as slot content, reads the default instead. That is the point of the slot rule: what a caller passes remains under the caller's configuration, no matter where the Component places it. A Component that wants its provided value to reach caller content cannot have it both ways; render that content itself, or let the caller provide the value.

Watchers and effects created during setup keep the frame they were created in, so they may keep injecting on later reactive runs. Lifecycle hooks and event callbacks are different: they are registered during setup but run outside the Component evaluation, so they should capture the value or the source they need while setup runs.

## Reactive context values

<!-- index: reactive context value; provided source -->

Context itself is not a reactive source. Calling `etaf-provide` or `etaf-inject` records no dependency, and re-providing a plain value does not re-render its readers. To let a subtree follow application state, provide a *source* — a ref or a computed value — and read it with `etaf-value` where the value is used:

```elisp
(etaf-define-component demo-locale (&key locale)
  :setup (etaf-provide 'locale locale)
  :view (column (slot)))

(etaf-define-component demo-label (&key text)
  :bindings ((locale (etaf-inject 'locale (etaf-ref "en"))))
  :view (text (expr (format "%s (%s)" text (etaf-value locale)))))
```

Changing the provided ref re-renders every reader that reads it, exactly like any other source. The alternative — re-providing a new plain value from a watcher or effect — is visible to later lookups but notifies nobody, so it cannot update what has already rendered.

## Semantic details

### Frames and lifetime

A frame belongs to one Component instance and lives as long as it does: a value provided during setup survives every update of the subtree, and a Component created later sees it too. When the providing instance is disposed, its frame goes with it and descendants created afterwards no longer find the value. Values are stored by reference; Context neither copies nor freezes them.

### Cost

An injection is one hash-table lookup per frame visited, so its cost is proportional to the depth of the Component chain, not to the number of provided values. A provide is one hash-table write. Frames are ordinary objects released with their instance; there is no global registry to grow.

## Errors and recovery

#### Error: etaf-context-error

Invalid ETAF Context operation. It is signaled when a Context operation is malformed or a required dependency is missing. Catch this condition with `condition-case`; failed calls do not return a value. Its parent condition is `error`, and its data is a list holding one formatted message string.

| Message | Cause |
| --- | --- |
| `"Context keys must be stable symbols: %S"` | A KEY that is a keyword, nil, t, a string or another non-symbol object, in `etaf-provide` or `etaf-inject` |
| `"Missing ETAF Context dependency: %S"` | `etaf-inject` with a non-nil REQUIRED-P for a key absent from the whole chain |

The Theme functions in [Component Styles and Themes](component-styles-and-themes.md) use the same condition for their input validation; that chapter lists their messages.

**See also.** [Reactivity](reactivity.md#errors-and-recovery) for `etaf-render-side-effect-error`, and [Components](components.md) for setup, bindings and lifecycle.

### Recovery

| Failure | What remains |
| --- | --- |
| An invalid KEY | Nothing was provided or looked up; existing Context is unchanged |
| A missing key with REQUIRED-P | The call signals and returns no value; existing Context is unchanged |
| A lookup outside a Component evaluation | DEFAULT is returned, or the call signals when REQUIRED-P is set; nothing changes |
| A provide during the pure render phase | The Runtime discards the work as it does for any render-phase failure, as [Reactivity](reactivity.md#recovery) describes |
| A plain value that no longer matches application state | Readers keep the rendered output until the View renders again; provide a source instead of a plain value to follow state |

A Context failure is a programming error in the providing or reading Component; it never corrupts another subtree, because a frame only holds its own entries.

**See also.** `etaf-provide`, `etaf-inject` and [Reactivity](reactivity.md#mounted-runtimes).
