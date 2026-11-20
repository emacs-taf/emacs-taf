# Standard Hooks

Hooks are the observation points the framework runs at defined moments. All are abnormal hooks: the value is a list of functions, and a buffer-local value, when set, replaces the global list for that buffer. Each row links to the entry that documents the arguments, timing and recovery.

<!-- index: hook; abnormal hook; observation point -->

| Hook | Runs when | Called with | Errors |
| --- | --- | --- | --- |
| [`ebox-unmount-functions`](ebox-mount-lifecycle.md#hook-ebox-unmount-functions) | A mount is being released by `ebox-unmount-buffer`, before the mount is detached and before the display settings are restored, so the buffer still answers `ebox-buffer-mount`. | the buffer | An error signals out of `ebox-unmount-buffer`, aborts the rest of the release and leaves the mount live. |
| [`ebox-focus-change-functions`](focus.md#hook-ebox-focus-change-functions) | `ebox-focus` moved the mount's focus; it does not run when the focused node is unchanged, and it runs inside the focus operation, so the mount already reports the new focus. | the previously focused node, or nil, and the newly focused node, or nil | An error propagates from the focus operation that ran the hook. |
| [`ebox-after-flush-functions`](incremental-updates-and-publication.md#hook-ebox-after-flush-functions) | A flush actually published, after the observer and the background sync; the buffer shows the new output and geometry is settled. | the buffer | An error in one function does not prevent the others from running. |
| [`ebox-viewport-change-functions`](viewport.md#hook-ebox-viewport-change-functions) | The viewport size changed, whether by a window resize or `ebox-mount-set-viewport`, once the relayout for the new size has settled. | the buffer | An error in one function does not stop the others. |
| [`ebox-display-change-functions`](viewport.md#hook-ebox-display-change-functions) | Buffer text scaling has settled and the retained tree has been remeasured, including fixed-size viewports. | the buffer | A callback error is reported by the viewport task; unstarted work remains queued after a quit. |
| [`ebox-display-window-change-functions`](viewport.md#hook-ebox-display-window-change-functions) | A window change settled and the mount was refit, when the window became the buffer's display window or its body pixel size changed; fixed viewports are notified too, borrowed lines are not. | the buffer and its display window | An error stops the rest of that frame's batch and is reported by the viewport task. |

## Notes

- `ebox-unmount-functions` is the explicit-release hook. Killing a buffer releases its mount through the buffer's kill hook and does not run it.
- The hooks run in the mount's buffer. Register a function that belongs to one application buffer with a buffer-local entry, `(add-hook 'HOOK FUNCTION nil t)`, and one that belongs to the process with the global list.
- `:on-focus-enter` is built on `ebox-focus-change-functions`: ETAF computes the Hosts between the previous and the new node and dispatches the callback on each, nearest first.
