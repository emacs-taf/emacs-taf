# Errors

Ebox's error conditions are part of its public API. A program that drives the library directly — building trees, mounting them, compiling styles or opening files — catches these conditions to tell a bad input from a missing mount, and to recover without leaving a half-built tree or a stale buffer behind. This chapter collects the conditions into one hierarchy, says which part of the API signals what, and describes the data each condition carries. [Node Construction](ebox-node-construction.md), [Mount and Lifecycle](ebox-mount-lifecycle.md), [Tree Queries](ebox-tree-queries.md) and [.ebox Files and Preview](ebox-files-and-preview.md) document the errors of their own entries; this chapter explains the model behind them.

## The error hierarchy

<!-- index: error condition; condition hierarchy; quit; recovery -->

Ebox's conditions hang off two Emacs roots. `ebox-error` descends from `error` and is the condition for a rejected Ebox operation: the caller asked the library to do something it cannot do with the input it was given. Two conditions descend from `error` directly rather than from `ebox-error` — `ebox-size-error` for a value that fails size validation, and `ebox-style-schema-error`, the schema vocabulary's condition. `ebox-input-cancelled` descends from `quit` instead: cancellation is not an error but a user or target decision, and it travels on the same path as a keyboard quit so that ordinary error handling does not swallow it.

| Condition | Parent | Called for |
| --- | --- | --- |
| `ebox-error` | `error` | A public Ebox operation rejected its input |
| `ebox-input-error` | `ebox-error` | An input session operation has no valid session or target |
| `ebox-input-cancelled` | `quit` | The target of a synchronous read disappeared |
| `ebox-size-error` | `error` | A size value is outside its grammar or unit domain |
| `ebox-style-schema-error` | `error` | The style schema vocabulary's condition |

The parentage decides which handlers see which condition. A handler for `ebox-error` catches construction, mount and update errors and also `ebox-input-error`, but not a size error: size validation belongs to the style layer and is only wrapped into `ebox-error` when it crosses an author-form boundary. A handler for `error` catches every Ebox error except cancellation, and a handler for `quit` is what catches both a user quit and `ebox-input-cancelled`.

## Conditions

#### Error: ebox-error

The base condition for a rejected Ebox operation.

**Semantics.** The condition is signaled when a public entry point is given input it cannot use — an unknown tag or malformed author form, a property list that is not an even-length list, a style or interaction value outside its domain, a node that already has a parent, a non-root node passed to render or mount. It is the condition applications catch around construction, mounting and node updates. The error data is a list whose first element is a human-readable description; `error-message-string` turns it into a message of the form `Ebox error: DESCRIPTION`.

**Recovery.** The failed call applied nothing: construction drops the nodes it built, a rejected mount leaves the previous mount and its text as they were, and a property list that fails validation is not installed. Fix the input and retry.

**Example.**

```elisp
(condition-case err
    (ebox-build '(widget "x"))
  (ebox-error (error-message-string err)))
     ⇒ "Ebox error: \"Unknown Ebox author tag\", widget"
```

**See also.** `ebox-input-error`, `ebox-size-error`, `ebox-build`, `ebox-node-create`.

#### Error: ebox-size-error

The condition for an invalid size value.

**Semantics.** The condition is signaled when a size fails validation, such as a length with a unit its axis does not allow. The style compiler raises it directly: `ebox-style-compile-declarations`, `ebox-style-compile-form` and `ebox-style-compile-rules` all let it through with the property and the allowed units in the data. Higher-level entry points wrap it: author-form construction and property replacement compile declarations through the same pipeline and re-signal an `ebox-error` whose description names the tag and the rejected property, so an application that only talks to nodes sees `ebox-error`. The error data is `(REASON VALUE)`: REASON is a description naming the property and the units it accepts, VALUE the offending value.

**Recovery.** The declaration was not installed and no layout ran with it. Correct the value — often the unit or the axis — and compile or construct again.

**Example.**

```elisp
(condition-case err
    (ebox-style-compile-declarations '(:width (bogus 1)) t)
  (ebox-size-error (cdr err)))
     ⇒ ("Invalid value for :width; allowed units: (px ch vw %)" (bogus 1))
```

**See also.** `ebox-style-compile-declarations`, `ebox-node-create`, `ebox-node-set-props`.

The other three conditions are defined where their subsystem lives. [ebox-input-error](text-input.md#error-ebox-input-error) and [ebox-input-cancelled](text-input.md#error-ebox-input-cancelled) belong to [Text Input](text-input.md); [ebox-style-schema-error](style-implementation.md#error-ebox-style-schema-error) belongs to [Styles Implementation](style-implementation.md) and has no public path that raises it today.

## What the API signals

<!-- index: error site; user-error; read error -->

| API area | Conditions |
| --- | --- |
| Building trees (`ebox-build`, `ebox-node-create`, `ebox-text-create`, `ebox-node-copy`) | `ebox-error`; a non-node child is a type error |
| Rendering and mounting (`ebox-render`, `ebox-mount`) | `ebox-error` for a non-root or a malformed form |
| Updating nodes (`ebox-node-put`, `ebox-node-set-props`, `ebox-node-insert`, `ebox-node-remove`, `ebox-node-move`, `ebox-node-replace-children`) | `ebox-error` |
| Compiling styles directly (`ebox-style-compile-declarations`, `ebox-style-compile-form`, `ebox-style-compile-rules`) | `ebox-size-error` for sizes; `user-error` for malformed lists and unknown properties; other errors for duplicate declarations and grammar violations |
| The same pipeline through a node or author form | `ebox-error` wrapping the original condition, with the tag and property named |
| Input sessions (`ebox-input-begin`, `ebox-input-end`, `ebox-call-with-input`) | `ebox-input-error`; `ebox-input-cancelled` on target loss |
| `.ebox` files (`ebox-file-read-form`, `ebox-file-read-file`, `ebox-file-evaluate-form`, `ebox-file-evaluate-buffer`, `ebox-file-preview`) | `user-error` for file and format problems; ordinary read and Lisp errors for contents |

## Semantic details

<!-- index: error data; wrapping; atomic failure -->

Error data is meant to be read. An `ebox-error` carries a description list whose first element is a string; `error-message-string` prints it as `Ebox error: DESCRIPTION`, and the description itself names what was rejected, so a diagnostic need not decode a structure. A size error's data separates the reason from the offending value, which lets a caller quote the value back without parsing the message. Cancellation's data carries the stale node, as [Text Input](text-input.md) describes.

The construction boundary wraps. The style pipeline works with conditions that name properties and values, but a node caller asked for a tree, not a declaration list, so construction catches the style condition and re-signals `ebox-error` with the tag and property in the description. The distinction matters when choosing a handler: use `ebox-size-error` when driving the style compiler directly, `ebox-error` when building or updating nodes, and `user-error` for the argument-shape checks that run before either. Cancellation is deliberately outside `error`: a program that catches `error` will not intercept a cancelled read, and a program that handles `quit` already handles it.

Failure is atomic where it matters. The operations that could leave a tree half-changed validate before they mutate: declarations compile before properties are installed, a child's parent is checked before it is attached, a mount's input is built before the previous mount is released. A failed call therefore leaves either the previous state or a tree that was never published.

## Errors and recovery

Catch the narrowest condition that describes what you can handle. A handler around construction or updates usually wants `ebox-error`; a handler around the style compiler wants `ebox-size-error` and `user-error`; input code should handle `ebox-input-error` and decide separately whether `ebox-input-cancelled` means "user went away" or "target changed". A generic `error` handler catches everything except cancellation; a `quit` handler catches cancellation along with real quits.

Recovery depends on the class. An `ebox-error` means an input is wrong and the failing call changed nothing, so the fix is local: correct the form, property or node and retry. A size error means one declaration is wrong; correct the value — the data names the property and its units. An input error means there is no session to act on; check the mount and the node before retrying, and after a cancellation start a fresh read if the target still exists. A file error means the file does not contain exactly one usable form or a companion path is wrong; the preview and the tree are untouched. And because layout and paint are outputs of the tree, an error never corrupts what is on screen: the next successful flush decides the text.
