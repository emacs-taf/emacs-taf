# Standard Errors

The error conditions are part of the public API: a program that calls the framework catches them to tell a bad input from a missing mount or an unavailable backend, and to recover without leaving a partial state behind. This appendix lists every condition with its parent and the situation that raises it; the linked entries give the data each condition carries, the messages and what remains after a failure. Every condition derives from `error` except `ebox-input-cancelled`, which derives from `quit` so that ordinary error handlers do not intercept an abandoned input session.

<!-- index: error condition; condition hierarchy; recovery -->

## ETAF

| Condition | Parent | Signaled when |
| --- | --- | --- |
| [`etaf-view-error`](views.md#error-etaf-view-error) | `error` | The base condition for an invalid View; the View and Component conditions below are its subtypes. |
| [`etaf-view-syntax-error`](views.md#error-etaf-view-syntax-error) | `etaf-view-error` | A structural form is malformed; raised while `etaf-view` expands, before any evaluation happens. |
| [`etaf-component-definition-error`](components.md#error-etaf-component-definition-error) | `etaf-view-error` | A Component definition is invalid, or a Component API is used outside its phase. |
| [`etaf-component-call-error`](components.md#error-etaf-component-call-error) | `etaf-view-error` | A Component call or one of its inputs is invalid. |
| [`etaf-renderer-error`](views.md#error-etaf-renderer-error) | `error` | A normalized View cannot be shown, or a mounted Runtime is required but absent. |
| [`etaf-reactive-error`](reactivity.md#error-etaf-reactive-error) | `error` | The reactive graph rejected an operation, such as a write during a computation or an invalid reactive value. |
| [`etaf-render-side-effect-error`](reactivity.md#error-etaf-render-side-effect-error) | `etaf-reactive-error` | An operation that would change the reactive graph was attempted during rendering; the data names the operation. |
| [`etaf-runtime-error`](runtime.md#error-etaf-runtime-error) | `error` | A Runtime operation cannot complete: use without a mount, malformed mount options or a failed retained update. |
| [`etaf-observer-error`](incremental-updates-and-publication.md#error-etaf-observer-error) | `error` | Observer context state is built or used with an invalid value, such as a non-function sink. |
| [`etaf-context-error`](context.md#error-etaf-context-error) | `error` | A Context operation is malformed or a required dependency is missing. |
| [`etaf-action-error`](actions-behaviors-and-error-boundaries.md#error-etaf-action-error) | `error` | An Action cannot be defined, registered or dispatched. |
| [`etaf-behavior-error`](actions-behaviors-and-error-boundaries.md#error-etaf-behavior-error) | `error` | A Behavior spec, source, installer or controlled geometry input is invalid. |
| [`etaf-event-error`](events.md#error-etaf-event-error) | `error` | An event operation has an invalid event context or target. |
| [`etaf-async-error`](async.md#error-etaf-async-error) | `etaf-reactive-error` | An asynchronous adapter or timeout is invalid. |
| [`etaf-async-timeout`](async.md#error-etaf-async-timeout) | `etaf-async-error` | An asynchronous wait exceeded its timeout. |
| [`etaf-async-cancelled`](async.md#error-etaf-async-cancelled) | `etaf-async-error` | Pending asynchronous work was cancelled. |
| [`etaf-resource-error`](resources.md#error-etaf-resource-error) | `etaf-reactive-error` | A Resource operation is invalid. |
| [`etaf-data-error`](data-controllers.md#error-etaf-data-error) | `error` | A Data contract is violated: a mutation is already pending, a batch is malformed, a capability is missing or an outcome is not committed. |
| [`etaf-data-stopped-error`](data-controllers.md#error-etaf-data-stopped-error) | `etaf-data-error` | An operation was attempted on a stopped Data Controller. |
| [`etaf-animation-error`](animation.md#error-etaf-animation-error) | `error` | An animation operation is invalid. |

## Ebox

| Condition | Parent | Signaled when |
| --- | --- | --- |
| [`ebox-error`](ebox-errors.md#error-ebox-error) | `error` | A public entry point received input it cannot use: an unknown tag, a malformed author form, an invalid property list or a bad node topology. |
| [`ebox-size-error`](ebox-errors.md#error-ebox-size-error) | `error` | A size value is outside its domain. |
| [`ebox-style-schema-error`](style-implementation.md#error-ebox-style-schema-error) | `error` | A style schema is malformed. |
| [`ebox-input-error`](text-input.md#error-ebox-input-error) | `ebox-error` | An input session operation is invalid. |
| [`ebox-input-cancelled`](text-input.md#error-ebox-input-cancelled) | `quit` | The input target is no longer available; its parent is `quit`, so an ordinary `error` handler does not catch it. |

## ECSS

| Condition | Parent | Signaled when |
| --- | --- | --- |
| [`ecss-error`](ecss-errors.md#error-ecss-error) | `error` | The base condition for a rejected ECSS operation; the five conditions below are its subtypes. |
| [`ecss-invalid-selector`](ecss-errors.md#error-ecss-invalid-selector) | `ecss-error` | The selector grammar or a selector AST is invalid. |
| [`ecss-invalid-subject-adapter`](ecss-errors.md#error-ecss-invalid-subject-adapter) | `ecss-error` | A subject adapter cannot be built. |
| [`ecss-invalid-property-schema`](ecss-errors.md#error-ecss-invalid-property-schema) | `ecss-error` | A package or property definition is malformed, or a composition cannot be formed. |
| [`ecss-invalid-declaration`](ecss-errors.md#error-ecss-invalid-declaration) | `ecss-error` | A declaration cannot be used as written. |
| [`ecss-invalid-rule`](ecss-errors.md#error-ecss-invalid-rule) | `ecss-error` | A rule, an origin, a layer or a source combination is invalid. |

## EKP

| Condition | Parent | Signaled when |
| --- | --- | --- |
| [`ekp-hyphen-error`](ekp-hyphenation.md#error-ekp-hyphen-error) | `error` | The base condition for hyphenation failures; the two conditions below are its subtypes. |
| [`ekp-hyphen-dictionary-not-found`](ekp-hyphenation.md#error-ekp-hyphen-dictionary-not-found) | `ekp-hyphen-error` | No dictionary matches the requested language. |
| [`ekp-hyphen-unsupported-pattern`](ekp-hyphenation.md#error-ekp-hyphen-unsupported-pattern) | `ekp-hyphen-error` | A dictionary uses replacement patterns this implementation does not support. |
| [`ekp-backend-contract-error`](ekp-native-module.md#error-ekp-backend-contract-error) | `error` | The native backend returned a malformed result. |

## ETAF UI

| Condition | Parent | Signaled when |
| --- | --- | --- |
| [`etaf-ui-svg-error`](ui-icons.md#error-etaf-ui-svg-error) | `error` | The SVG scene helpers received invalid input. |
| [`etaf-ui-markdown-error`](ui-composite-components.md#error-etaf-ui-markdown-error) | `error` | A markdown operation was rejected: an unknown dialect name during parsing, or a missing palette or unknown palette key during rendering. |

## ETAF DB

| Condition | Parent | Signaled when |
| --- | --- | --- |
| [`etaf-sqlite-error`](sqlite-backend.md#error-etaf-sqlite-error) | `error` | The base condition for a rejected SQLite operation; the three conditions below are its subtypes. |
| [`etaf-sqlite-schema-error`](sqlite-backend.md#error-etaf-sqlite-schema-error) | `etaf-sqlite-error` | A descriptor or an initialized database does not match the declared schema. |
| [`etaf-sqlite-unavailable`](sqlite-backend.md#error-etaf-sqlite-unavailable) | `etaf-sqlite-error` | The Emacs build has no SQLite support. |
| [`etaf-sqlite-commit-unknown`](sqlite-backend.md#error-etaf-sqlite-commit-unknown) | `etaf-sqlite-error` | A mutation's commit outcome cannot be determined. |

## ETAF Posframe

| Condition | Parent | Signaled when |
| --- | --- | --- |
| [`etaf-posframe-error`](posframe-panels.md#error-etaf-posframe-error) | `error` | A panel option, anchor, size or `:border` plist is invalid, or the frame is not graphical. |

