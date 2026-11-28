# Components

A *Component* turns part of a View into a named, reusable unit with inputs. Defining a Component registers a recipe; calling it in a View places an instance; and each instance keeps its own inputs, scope and state across updates. This chapter defines the definition macro and its clauses, props with their defaults and validation, slots, the `:view` and `:render` frontends, setup and bindings, the lifecycle hooks, attribute fallthrough, and the two error conditions.

A Component is not a Host: it owns no Ebox node of its own. Its render result is a View, and that View may be nil, a single Host, or several nodes grouped by a fragment. Host kinds, properties and references belong to [Hosts](hosts.md); the View grammar, node identity and the compiler belong to [Views](views.md); the Scope ownership that an instance uses for its reactive state belongs to [Reactivity](reactivity.md#scopes).

<!-- index: Component; Component instance; prop; slot; fallthrough; lifecycle hook -->

## Model

### Calls, instances and identity

A Component call is a View node exactly like a Host node: `(demo-notice :severity "warning" title "Disk almost full" ...children...)`. The name is resolved against the registry when the View is built, keyword properties are partitioned into the Component's declared props and Host fallthrough attributes, and the children become slot input.

Rendering a call creates or updates an *instance*. Reconciliation matches instances by the Component and the `:key`, as [Views](views.md#identity) describes, so an instance survives re-renders: its input cells, its Scope with the refs and watchers created in setup, its binding values and its retained children all belong to it and are released when it stops being rendered.

An instance is the ownership boundary for everything its setup creates. `etaf-ref`, `etaf-computed`, `etaf-watch` and `etaf-local-ref` are all owned by the instance's Scope, so disposing the instance also stops them; [Reactivity](reactivity.md#scopes) defines that lifecycle.

### The definition contract

A Component definition is static data, validated when it is defined and stored in the registry under its name. At the call site only values are evaluated. The definition declares:

- the props it accepts, as `(&key NAME ...)`;
- exactly one rendering frontend, `:view` or `:render`;
- optionally `:bindings`, `:validate`, `:setup` and `:styles`.

A Component without `:setup` is stateless and can be rendered by `etaf-render`; a Component with `:setup` needs a mounted Runtime, because its Scope must have a lifecycle owner, as [Views](views.md) explains for `etaf-render`.

```elisp :figure One component definition, three instances
(etaf-define-component demo-chip (&key label)
  :render
  (etaf-view
   (box :padding '((lh 0) (ch 2))
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
     (text :color (etaf-theme-token :ui-accent "#0969da") (expr label)))))

(etaf-view
 (row :item-gap '(ch 1)
   (demo-chip :label "调用 A")
   (demo-chip :label "调用 B")
   (demo-chip :label "调用 C")))
```

## Defining a Component

#### Macro: etaf-define-component (name arguments &rest clauses)

Define a Component named NAME from an argument declaration and clauses, and register it.

**Arguments.**

- NAME is an ordinary non-nil symbol. It must not be a Host name and must not be registered by another definition; a deliberate replacement uses `etaf-component-redefine-run`.
- ARGUMENTS declares the props: `(&key NAME ...)`, where each entry is NAME or `(NAME DEFAULT)`. A prop name is an ordinary symbol; the keyword `:key`, the branch and list directives `:if`, `:else-if`, `:else`, `:for`, and names beginning with `&` are reserved and rejected.
- CLAUSES are keyword/value pairs in any order: `:bindings`, `:validate`, `:setup`, `:view`, `:render` and `:styles`. At most one of each is allowed, and exactly one of `:view` and `:render` is required.

**Semantics.**

- `:bindings ((NAME INITIALIZER) ...)` declares named values initialized once per instance, in order before `:setup`. A binding name must be an ordinary symbol and must not duplicate another binding or a prop. Binding values are stable across re-renders and are read directly by `:setup`, both frontends and callbacks; reassigning the lexical name with `setq` does not replace the stored value.
- `:validate ORDINARY-ELISP` runs after defaults are resolved, on mount and on every input update, before any binding, setup or rendering sees the new inputs. Its return value is ignored; use `etaf-check-prop` or signal an error to reject input. It must be pure and may run again, and it cannot use instance bindings, state, slots or lifecycle.
- `:setup SETUP` is an ordinary Elisp body, not a lambda. Its return value is the instance's state when the Component has no `:bindings`; with `:bindings` the return value is ignored. It must not return a function, and it must not construct View structure: the frontends own rendering.
- `:view VIEW` is unquoted View syntax and is compiled with the definition; `:render ORDINARY-ELISP` is ordinary Elisp returning a View, usually through `etaf-view`. Both frontends receive the declared props and the current slots. `:view` reads a prop by its name; `:render` reads the live value through `etaf-current-prop` or a source from `etaf-prop`.
- `:styles ((SELECTOR ATTRIBUTE ...) ...)` declares the Component's static style rules. The clause itself belongs to [Component Styles and Themes](component-styles-and-themes.md); the syntax is validated at definition time.

**Returns.** The Component name, as a quoted symbol, so a definition form evaluates to NAME.

**Errors.** All of these are raised while the definition is expanded or evaluated, as `etaf-component-definition-error` with one message string: props not declared as `(&key ...)` or an entry that is not `NAME` or `(NAME DEFAULT)`; a prop name that is a keyword, nil, t or starts with `&`; a duplicate or reserved prop; a malformed or duplicate binding; a binding that duplicates a prop; a duplicate or unknown clause; both `:view` and `:render`, or neither; a `:setup` that is a lambda or builds View structure; and a malformed `:styles` form. A duplicate of an already registered name raises `etaf-component-call-error` instead, naming the Component.

**Example.** A dismissible notice: it takes `severity` and `title`, keeps its own closed state, and renders a status box with a Dismiss button.

```elisp :run
(etaf-define-component demo-notice (&key (severity "info") title)
  :bindings ((closed (etaf-ref nil)))
  :view
  (box :if (not (etaf-value closed))
       :role "status"
       (row
        (text :font-weight 'bold (expr title))
        (text (expr (format " (%s)" severity))))
       (text :role 'button :tab-index 0
             :aria-label (concat "Dismiss " title)
             :on-press (lambda () (etaf-set-value closed t))
             "Dismiss")))

(etaf-view (demo-notice :severity "warning" :title "Disk almost full"))
```

**See also.** `etaf-view`, `etaf-node`, [Component Styles and Themes](component-styles-and-themes.md), and the other entries in this chapter.

### The clauses

One paragraph per clause; each links to the section that defines its behavior.

- **Props** are declared in the argument list and passed by keyword at the call site. [Props](#props) defines defaults, validation and reactivity.
- **`:bindings`** creates named values once per instance, before setup. [Setup, bindings and state](#setup-bindings-and-state) defines their lifetime.
- **`:setup`** performs per-instance initialization in the instance's own Scope; it may register lifecycle hooks and create reactive state. [Setup, bindings and state](#setup-bindings-and-state) and [Lifecycle hooks](#lifecycle-hooks).
- **`:validate`** checks input values before they are published. [Validation](#validation).
- **`:view`** and **`:render`** are the two frontends. [The `:view` and `:render` frontends](#the-view-and-render-frontends).
- **`:styles`** declares static style rules. [Component Styles and Themes](component-styles-and-themes.md).

### Registration and redefinition

A definition is registered under its exact name. Reloading an identical declaration from the same library, including loading bytecode after source during package.el installation, retains the original definition, its captured values and mounted instances. This is idempotent loading, not hot replacement: it does not reinitialize state or refresh values captured from the library's lexical environment. A changed declaration, a declaration in another library, or an ordinary evaluated duplicate still raises an error, because a silently replaced Component would leave mounted instances and compiled Views inconsistent. An authoring tool that replaces a Component or refreshes its captured values disposes the old Runtime first and then evaluates the definition inside `etaf-component-redefine-run`.

#### Function: etaf-component-redefine-run (function)

Run FUNCTION while allowing intentional Component redefinition.

**Arguments.** FUNCTION is a function of no arguments. Any other value signals `wrong-type-argument` with data `(functionp FUNCTION)`.

**Semantics.** Inside the call, a `etaf-define-component` of an already defined name replaces its registry entry instead of signaling. The Component's compiled material is invalidated, as [Views](views.md) describes for the registry generation, so the next mount or render uses the new definition. Outside the call, duplicate definitions remain errors except for the unchanged library reload described above. Mounted instances of the old definition keep it until they are disposed with their Runtime; the function should therefore dispose the old Runtime before or shortly after the replacement.

**Returns.** FUNCTION's return value.

**Errors.** `error→ wrong-type-argument` when FUNCTION is not a function. Errors inside FUNCTION, including a duplicate Host name or a malformed new definition, propagate and leave the registry as it was.

**Example.** A preview tool reloads a Component after disposing the Runtime.

```elisp
(etaf-component-redefine-run
 (lambda () (load "notice-component" nil t)))
```

**See also.** [Registration and redefinition](#registration-and-redefinition) and [Views](views.md).

## Props

### Declaring, passing and defaulting

A prop is declared in the argument list as NAME or `(NAME DEFAULT)` and passed at the call site as a keyword: `(demo-notice :severity "warning" :title "Disk almost full")`. A call may pass any declared prop; it may not pass an undeclared one as a business prop of the Component — such a property is a fallthrough attribute instead, described under [Attribute fallthrough](#attribute-fallthrough).

A prop value in a View is an ordinary expression and is deferred like any other property value, so a prop read from a reactive source makes the Component's input dynamic ([Views](views.md#property-values)).

Defaults resolve on first use per instance:

- A default is evaluated only when the call does not supply the prop. An explicitly supplied nil is a value, not an absence, so the default is not evaluated for it.
- Defaults evaluate in declaration order, and a later default can read the earlier props.
- The resolved default is retained by the mounted instance: an update that still omits the prop reuses the value instead of evaluating the default again. A new instance evaluates it again.
- A default expression must be safe to evaluate again after a rejected publication and must not depend on instance bindings, state or lifecycle.

When the call supplies a different value later, the instance's prop cell changes and everything that read that prop updates; when the value compares equal under the shallow equality rule of [Reactivity](reactivity.md#equality), nothing updates.

### Validation

`:validate` is the definition's input contract. It runs after defaults are resolved, on mount and on every input update, before bindings, setup, rendering and the publication of new inputs. Its return value is ignored, so validation rejects input by signaling; `etaf-check-prop` is the standard way to do that.

The form receives the declared props as lexical variables and may also read them with `etaf-current-prop`; it runs with the Component's name for diagnostics and must be pure, because it may run again. A rejected input leaves the instance's published props and callbacks unchanged; the caller's own state change is not rolled back, as [Reactivity](reactivity.md#recovery) explains.

#### Function: etaf-check-prop (property value valid-p expected &optional component)

Report VALUE as invalid input unless VALID-P is non-nil.

**Arguments.** PROPERTY is a keyword naming the input. VALUE is the received value. VALID-P is an ordinary Elisp predicate result, usually `(natnump count)` or `(stringp name)`. EXPECTED is a description string such as `"a nonnegative integer"`. COMPONENT names the input owner; inside a `:validate` form it defaults to the Component being validated, and helpers called outside validation must supply it.

**Semantics.** When VALID-P is non-nil the value is returned unchanged. Otherwise the function signals `etaf-component-call-error` with a message naming the Component, the property, the received value and the expectation; large values are abbreviated in the message. The function copies nothing and owns nothing, and it must not mutate the value or perform effects.

**Returns.** VALUE.

**Errors.** `error→ etaf-component-call-error` when VALID-P is nil. `error→ etaf-component-definition-error` when the call metadata itself is malformed — no Component name, a non-keyword PROPERTY or a non-string EXPECTED.

**Example.** `(etaf-check-prop :count count (natnump count) "a nonnegative integer")`

**See also.** [Validation](#validation).

### Reading props over time

The lexical prop names a definition uses are snapshots of the inputs at the time they are bound: in `:setup` and `:bindings` they hold the values that setup ran with. Two accessors expose the inputs over time.

#### Function: etaf-prop (name)

Return the current instance's stable read-only reactive input NAME.

**Arguments.** NAME is a declared prop name or its keyword.

**Semantics.** Call it during setup to obtain a reactive source for the prop, and read the source with `etaf-value` inside computed getters, watchers or View expressions. Equal names return the same source object within the instance, so two watchers of one prop share one read; the source follows every later input, unlike the lexical snapshot. A name that is not a declared prop, or a call outside setup, is an error.

**Returns.** A read-only reactive source; `etaf-value` of it is the current input.

**Errors.** `error→ etaf-component-definition-error` when called outside Component setup or when NAME is not a declared prop.

**Example.** A watcher that reacts only to one input.

```elisp
(etaf-define-component demo-search (&key (query ""))
  :bindings ((q (etaf-prop 'query)))
  :view (text (expr (format "Searching for %S" (etaf-value q)))))
```

**See also.** `etaf-current-prop` and [Reactivity](reactivity.md).

#### Function: etaf-current-prop (name)

Return the current value of Component input NAME during rendering.

**Arguments.** NAME is a prop name or keyword.

**Semantics.** Call it during setup or rendering, from a `:render` body or from ordinary Elisp that runs during rendering, such as a helper called by `:view`. During rendering the read is tracked: the binding that reads the prop updates when the caller supplies a different value. During rendering a plain lexical prop name also reads the live value, because the frontends bind it to the input cell; `etaf-current-prop` is how ordinary Elisp reads it.

**Returns.** The current input value, or nil when the name is not declared.

**Example.** `(etaf-define-component demo-label (&key text) :render (etaf-view (text (etaf-current-prop 'text))))`

**See also.** `etaf-prop`.

## Slots

A Component call passes content as ordinary children — the *default slot* — or as named slot inputs written `(slot :name NAME CHILD ...)`. Inside the Component, `(slot)` or `(slot :name NAME FALLBACK ...)` projects a slot; the fallback children render when the caller supplied nothing.

Slot content stays with its caller: it is evaluated in the caller's Context, keeps the caller's style ownership, and its expressions read the caller's reactive state. The Component decides where the content appears, not what it means. The value read out of a slot is opaque; pass it to View children or wrap it as a View child, and do not keep it beyond the instance's Runtime.

#### Function: etaf-current-slot (name &optional fallback)

Return the composable children the caller supplied for slot NAME, or FALLBACK when nothing was supplied.

**Arguments.** NAME is the slot name, normally `default`. FALLBACK is the value to return when the slot is empty; pass a list of View children to render the fallback.

**Semantics.** Call it while the Component's View or render functions run. The returned children are caller-owned typed Views: pass them, append them or wrap them as View children, and treat each value as opaque. In a `:view` form the result is usually wrapped as `(expr (etaf-current-slot 'default))`, because an expression is the place where a computed list of children belongs.

**Returns.** A list of typed View children; FALLBACK when the slot has no input.

**Errors.** `error→ etaf-component-definition-error` when called outside Component rendering.

**Example.** A panel with a header and a body.

```elisp
(etaf-define-component demo-panel ()
  :view (column
         (row (expr (etaf-current-slot 'header)))
         (box (expr (etaf-current-slot 'default)))))
```

**See also.** `etaf-current-slots`.

#### Function: etaf-current-slots ()

Return the current Component's whole slot alist of opaque composable children.

**Semantics.** The result is an alist from slot names to the same caller-owned children `etaf-current-slot` returns; the default slot is keyed `default`. It is the forwarding tool: a wrapper Component can hand its own slots to the Component it wraps without naming them. Ownership and lifetime are those of `etaf-current-slot`, and the call is allowed only during Component rendering.

**Returns.** A fresh alist of slot names to lists of typed View children.

**Errors.** `error→ etaf-component-definition-error` when called outside Component rendering.

**Example.** `(etaf-define-component demo-shell () :view (expr (etaf-node 'box (list :class "shell") (append (etaf-current-slot 'default) nil))))` forwards the default slot into a styled box.

**See also.** `etaf-current-slot`.

## The `:view` and `:render` frontends

The two clauses differ in when the View is computed and how prop reads are tracked; both produce the same typed View output.

- `:view` is written in the structural language and compiled once with the definition. It is evaluated once when the instance first renders and again as part of an update, but each prop name it uses is a tracked read of that prop's cell: a binding that shows one prop updates without re-running the whole Component. The View is written with unquoted Host and Component forms, and prop names may be used directly, including inside `expr`.
- `:render` is ordinary Elisp. It runs in a retained effect, so it is evaluated once and then again when any source it read changed. A `:render` body reads props with `etaf-current-prop` (tracked) or a source from `etaf-prop`, and must return a View built with `etaf-view` or `etaf-node`.

A Component that only assembles Hosts needs no runtime state; `:view` is the common choice. A Component whose whole output depends on a computed value read in ordinary Lisp, or that must build nodes programmatically, uses `:render`.

### Several roots and nil

A Component's render result must be nil, a string, or one typed View. Rendering nil is valid and shows nothing while the instance stays alive. Several roots are expressed with a fragment: the fragment's children join the enclosing layout, so a Component can return a header and a body without adding a container. Host attributes passed to a call whose result is a fragment are an error, because there is no single root to style; add a wrapping Host when callers must be able to pass attributes.

## Setup, bindings and state

Setup is per-instance initialization. It runs once, in a Scope detached from the surrounding render, after inputs are validated and before the first render; the Scope owns every reactive object and reference created there and is disposed with the instance. With `:bindings`, the binding values are created in order inside setup; with or without them, a defined `:setup` may return a state value when the Component has no bindings.

A stateless Component — no `:setup`, no `:validate`, no state — may be rendered by `etaf-render`. A Component with setup needs a mounted Runtime, and `etaf-render` signals `etaf-renderer-error` for it, as [Views](views.md) describes.

#### Function: etaf-state ()

Return the current Component instance's exact setup result.

**Semantics.** Call it while the Component renders. The value is whatever the `:setup` form returned, including nil; a defined setup is tracked independently of its return value, so nil is a valid state. A Component that uses `:bindings` must refer to its named values directly instead of calling `etaf-state`, and a Component without `:setup` has no state to return.

**Returns.** The setup result.

**Errors.** `error→ etaf-component-definition-error` when called outside Component rendering, when the current Component declares no `:setup`, or when the current Component uses `:bindings`.

**Example.** A canvas Component keeps its process in setup state.

```elisp
(etaf-define-component demo-canvas (&key (text ""))
  :setup (start-editor-process text)
  :view (text :ref 'surface (expr text)))
;; while rendering:
(process-status (etaf-state))
```

**See also.** [Setup, bindings and state](#setup-bindings-and-state) and `etaf-prop`.

## Lifecycle hooks

The three hooks let a Component act at the boundaries of its instance life. Each is registered during setup and receives zero-argument callbacks; registering outside setup, or with a non-function, is an error.

- **Mounted** runs after the instance is first published: its buffer output exists and its geometry is committed. It is the place to open external resources, subscribe to processes or read an initial size.
- **Updated** runs after a commit in which the instance participated — its inputs, slots or rendered output changed. It is not run for a newly mounted instance, and not for an instance whose output did not change.
- **Unmounted** runs when the instance is disposed: when it stops appearing in its parent, or when its Runtime unmounts. It is the place to release what mounted opened, although the instance's Scope releases its reactive objects automatically.

Hooks run outside rendering and may write state; their errors are collected by the Runtime's drain like other publication work. Registration order is preserved, and hooks run in the registration order within their moment. Unmounting a Runtime runs the unmounted hooks of the instances still alive at that moment.

#### Function: etaf-on-mounted (callback)

Run CALLBACK after the current Component is first published.

**Arguments.** CALLBACK is a zero-argument function.

**Semantics.** Registered during the current Component's setup; the callback runs after the commit that published the instance, in the Runtime's context and outside rendering. The host buffer already shows the rendered output.

**Errors.** `error→ wrong-type-argument` with data `(functionp CALLBACK)`; an error when called outside Component setup.

**Example.** `(etaf-on-mounted (lambda () (message "notice shown")))`

**See also.** `etaf-on-updated`, `etaf-on-unmounted`.

#### Function: etaf-on-updated (callback)

Run CALLBACK after the current Component participates in an update.

**Arguments.** CALLBACK is a zero-argument function, registered during setup.

**Semantics.** The callback runs after a commit changed the instance's inputs, slots or output; a newly mounted instance runs only its mounted hooks, and an unchanged instance runs nothing.

**Errors.** `error→ wrong-type-argument` with data `(functionp CALLBACK)`; an error when called outside Component setup.

**Example.** `(etaf-on-updated (lambda () (etaf-scroll-into-view (etaf-current-runtime) 'selected)))` keeps a selected row visible after the selection changed.

**See also.** `etaf-on-mounted`, `etaf-on-unmounted`.

#### Function: etaf-on-unmounted (callback)

Run CALLBACK when the current Component is disposed.

**Arguments.** CALLBACK is a zero-argument function, registered during setup. It also runs when the whole Runtime unmounts.

**Semantics.** The callback runs after the instance stopped being rendered, in the Runtime's context, once. The instance's Scope is disposed independently, so cleanup that the Scope owns — refs, watchers, local references — does not need a hook.

**Errors.** `error→ wrong-type-argument` with data `(functionp CALLBACK)`; an error when called outside Component setup.

**Example.** `(etaf-on-unmounted (lambda () (delete-process watch-process)))`

**See also.** `etaf-on-mounted`, `etaf-on-updated`.

## Attribute fallthrough

A caller may pass Host attributes to a Component call even though the Component itself declares no such prop. These *fallthrough attributes* are applied to the root of the Component's rendered result, so a reusable Button can accept `:disabled`, `:on-press` or `:class` from its user:

- A Host root receives the attributes merged into its own properties, under the rules of [Hosts](hosts.md#values-and-conflicts).
- A string root becomes a text Host carrying the attributes.
- A Component-call root forwards them: declared props of the inner Component become its props, and the rest become its fallthrough attributes.
- A fragment root, an empty result and any other value cannot receive attributes and signals `etaf-component-call-error`.

The merge rules are the Host rules: non-nil style values from the caller win; `:class` unions with the root's classes; event callbacks compose with the root's callback first; `:disabled` combines with `or`; `:role` and the identifying `:aria-*` attributes are owned by the root and a conflicting caller value is an error; `:use` lists concatenate and `:keys` merge. Attribute expressions evaluate in the caller's context, so they may read the caller's state. A style attribute the root Host kind does not accept is rejected with a message naming the Component, the Host kind and the attribute.

## Semantic details

### The instance record

An instance holds: its identity (the definition and the call's `:key`), one reactive cell per declared prop plus the table of prop names, the current call and its resolved slots, the Scope created for setup, the state or binding values, the retained rendered View, the input effect when props are dynamic, the registered lifecycle hooks, and the bookkeeping flags the Runtime uses to publish and retire it. The Runtime also keeps every live instance in a table for introspection, as [Runtime](runtime.md) describes.

### Initialization and updates

Mounting or first rendering a call initializes the instance in order: create the instance with its prop cells; resolve defaults, validate inputs and write the changed cells; create the setup Scope and run setup; render the frontend; and register the instance as new so the commit publishes it and runs its mounted hooks. A Component with setup and no Runtime stops after the first two steps with `etaf-renderer-error`.

Updating an instance starts when its parent re-renders and produces a new call matched by identity. The new call replaces the old one. If the prop values differ, the input cells update and the readers of those cells re-run; if the call's slots changed, the retained slot content updates; if the fallthrough attributes changed, the rendered result is re-projected with them. The frontend then re-renders as its kind requires: a `:view` instance re-evaluates its compiled View, and a `:render` instance re-runs only when the effect's tracked reads changed. Removing the call disposes the instance and runs its unmounted hooks.

### Cost

A Component costs nothing while its inputs, slots and output are unchanged: reconciliation stops at one identity comparison per call. When an input changes, the cost is the readers of that input — a Host property bound to one prop updates that Host alone, not the whole Component — plus the frontend work the change requires. A `:render` frontend that reads several sources re-runs once per drain, not once per source. Retaining an instance across updates is what keeps this cost proportional to the change instead of to the Component's size; the keyed identity rules of [Views](views.md#identity) are what make retention possible.

## Errors and recovery

Component problems separate into definition problems, which are programming errors in the definition, and input problems, which are data errors at a call.

#### Error: etaf-component-definition-error

An invalid Component definition or a Component API used outside its phase, with the message "Invalid ETAF Component definition". It is a subtype of `etaf-view-error`; its data is a list holding one formatted message string.

| Message | Cause |
| --- | --- |
| `"Component props must use (&key NAME ...), got %S"` | An argument declaration that does not start with `&key` |
| `"Component props must be NAME or (NAME DEFAULT): %S"` | A malformed prop entry |
| `"Component prop name must be an ordinary symbol: %S"` | A keyword, nil, t or `&`-prefixed prop name |
| `"Duplicate Component prop: %S"` | The same prop declared twice |
| `"Component prop %S is reserved by the View grammar"` | A prop named like a directive |
| `"Component %S binding must be (NAME INITIALIZER): %S"` | A malformed binding |
| `"Component %S binding %S duplicates a binding or prop"` | A colliding binding name |
| `"Component %S has duplicate :render"` and the same for the other clauses | A clause given twice |
| `"Unknown Component definition keyword %S"` | A clause outside the list |
| `"Component %S must choose :view or :render, not both"` and `"Component %S requires exactly one of :view or :render"` | The frontend clauses are inconsistent |
| `"Component %S :setup cannot construct View structure"` | A `:setup` form containing `etaf-view` or `etaf-node` |
| `"Component %S :setup cannot return a render function"` | A `:setup` written as a lambda |
| `"Input checks require a Component name, keyword property and expectation string"` | Malformed `etaf-check-prop` metadata |
| `"Component %S has no declared prop %S"` | `etaf-prop` for an undeclared name |
| `"etaf-prop requires Component setup"` | `etaf-prop` outside setup |
| `"Slots are available only during Component view/render"` | `etaf-current-slot` or `etaf-current-slots` outside rendering |
| `"ETAF state is available only during Component view/render"`, `"Current Component does not declare :setup"`, `"Current Component uses :bindings; refer to its named values directly"` | Misuse of `etaf-state` |

#### Error: etaf-component-call-error

An invalid Component call or input, with the message "Invalid ETAF Component call". It is a subtype of `etaf-view-error`; its data is a list holding one formatted message string.

| Message | Cause |
| --- | --- |
| `"Unknown ETAF Host or Component: %S"` | A call name that is neither |
| `"Component %S is already registered"` | A duplicate definition outside `etaf-component-redefine-run` |
| `"Component %S conflicts with a core Host"` | A Component named after a Host kind |
| `"Component %S property %S received %S; expected %s"` | An input rejected by `:validate` or `etaf-check-prop` |
| `"Component %S must render nil, a string, or one typed View; got %S"` | A render result that is not a View |
| `"Component %S has multiple roots; Host attrs have no target"` | Fallthrough attributes on a fragment result |
| `"Component %S cannot apply Host attrs to %S"` | Fallthrough attributes on an unsupported result |
| `"Component %S root Host %S rejects attribute %S"` | A fallthrough style the root Host kind does not accept |
| `"Component %S root Host %S owns %S; conflicting fallthrough value %S"` | A caller value for an owned semantic property |
| `"Duplicate Component slot %S"` and `"Component default slot has both children and an explicit input"` | Slot input conflicts |
| ``"Stateful Component requires `etaf-mount'"`` (`etaf-renderer-error`) | Rendering a Component with `:setup` without a Runtime |

### Recovery

| Failure | What remains |
| --- | --- |
| A malformed definition | The registry is unchanged; the failed definition is not registered |
| A duplicate definition | The registered definition stays; use `etaf-component-redefine-run` to replace it deliberately |
| Rejected input | The instance keeps its previously published props, callbacks and output; the caller's own state change stays, and the next valid input updates normally |
| A failing render or update | The committed buffer output stays; the work is retried at the next drain or flush, as [Reactivity](reactivity.md#recovery) describes |
| A disposed instance | Its children, Scope, reactive objects and references are released; later reads of its inputs signal an error |

A definition error is a programming error and must be fixed in the source. An input error is data and belongs to the call site: the instance rejects the value in a controlled way, keeps the last good publication, and recovers as soon as the input is valid again.
