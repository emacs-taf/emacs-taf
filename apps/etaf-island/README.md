# ETAF Island

Pure-protocol Dynamic Island system shell for Emacs, consuming ETAF's cross-application live activity (`etaf-activity-*`) and notification (`etaf-notify*`) protocol without coupling to any application package.

## Capabilities

- **Headerless 1-row floating capsule**: auto-sizes in `etaf-posframe` from a quiet idle clock capsule to a multi-activity bar (timer, media with real audio spectrum via `:meter`, background tasks, unread counter) and expands cleanly on demand.
- **Live event pulses**: subscribes to `etaf-notify-functions` for semantic notification pulses with grouped deduplication (`×N`), publisher-declared quick actions and an auto-collapsing TTL progress strip.
- **Expanded multi-activity hub**: zero-jitter borderless tabs for live activities (`1`), notification feed (`2`) and installed ecosystem quick launchers + native Emacs sensor switches (`3`).
- **Optional native Emacs sensors**: `etaf-island-mode` optionally bridges `compilation-finish-functions` and `org-clock` into the same `etaf-activity` / `etaf-notify` protocol.
- **Zero idle repaints**: demand-driven ticking repaints only when an active activity supplies a live `:meter` or when the minute changes.

## Usage

```elisp
(add-to-list 'load-path "/path/to/emacs-taf/apps/etaf-island")
(require 'etaf-island)

;; Enable global protocol listening, native sensors and floating capsule
(etaf-island-mode 1)

;; Or toggle the floating top-center capsule / open standalone buffer
(etaf-island-toggle)
(etaf-island-open)
```

## Checks

```sh
make check
```
