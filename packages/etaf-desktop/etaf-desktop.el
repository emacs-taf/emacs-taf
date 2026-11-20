;;; etaf-desktop.el --- Desktop application for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.7
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0"))
;; Keywords: ui, desktop, tools
;; URL: https://github.com/emacs-taf/etaf-desktop

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-desktop) after adding this repository
;; and the ETAF and ETAF UI roots to `load-path'.  The package owns application
;; policy for windows and workspaces.  Ebox remains the geometry and retained
;; publication provider; ETAF owns state and lifecycle; ETAF UI supplies the
;; controls used by the desktop surface.
;;
;; Function: etaf-desktop-create (&key (name "*ETAF Desktop*") canvas-width canvas-height fit (workspaces '(main)))
;;;###autoload (autoload 'etaf-desktop-create "etaf-desktop" nil nil)
;; Create an unmounted desktop controller.  WORKSPACES is a nonempty list of
;; unique keys.  When CANVAS-WIDTH or CANVAS-HEIGHT is nil, the mounted desktop
;; derives its canvas from the displaying Emacs window and fills its visible
;; body.  FIT is nil for that behaviour, or `region' when an application embeds
;; `etaf-desktop-view' in a window: the desktop then follows that window body
;; through `etaf-viewport', so resizing or maximizing the hosting window
;; reflows this desktop.  The controller owns a reactive state source and can
;; be mounted with `etaf-desktop-mount'.
;;
;; Error: etaf-desktop-error
;; Invalid desktop operation, unknown window/workspace, or rejected geometry.
;;
;; Function: etaf-desktop-state (desktop)
;;;###autoload (autoload 'etaf-desktop-state "etaf-desktop" nil nil)
;; Return a detached plist describing canvas, workspaces, active window and all
;; windows.  `:token' is the desktop's ETAF Host reference namespace: its own
;; controls are `<token>-<name>', and application windows are
;; `<token>/<instance-id>/<window-id>'.  The plist and window entries are safe
;; for callers to retain.
;;
;; Function: etaf-desktop-windows (desktop)
;;;###autoload (autoload 'etaf-desktop-windows "etaf-desktop" nil nil)
;; Return detached public window state plists for DESKTOP.
;;
;; Function: etaf-desktop-window-state (desktop id)
;;;###autoload (autoload 'etaf-desktop-window-state "etaf-desktop" nil nil)
;; Return the detached public state for window ID, or signal
;; `etaf-desktop-error' when it is unknown.
;;
;; Function: etaf-desktop-active-window (desktop)
;;;###autoload (autoload 'etaf-desktop-active-window "etaf-desktop" nil nil)
;; Return the active window ID, or nil when the active workspace has no window.
;;
;; Function: etaf-desktop-active-workspace (desktop)
;;;###autoload (autoload 'etaf-desktop-active-workspace "etaf-desktop" nil nil)
;; Return the active workspace key.
;;
;; Function: etaf-desktop-open-window (desktop id &key title view (x 0) (y 0) (width 400) (height 12) (min-width 160) (min-height 3) max-width max-height workspace (visible t) (movable t) (resizable t))
;;;###autoload (autoload 'etaf-desktop-open-window "etaf-desktop" nil nil)
;; Add a window to DESKTOP.  VIEW is caller-owned ETAF View content built for
;; this window; each window renders its own instance once, so callers never
;; share one application instance between windows.  The
;; window is seamless: VIEW owns every body cell, because the frame's resize
;; strips are transparent pointer targets on the outermost body row and
;; columns rather than painted chrome.  Geometry is in logical desktop units;
;; movable and resizable default to non-nil.  Raise and focus policy is applied
;; when the window opens.
;;
;; Function: etaf-desktop-close-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-close-window "etaf-desktop" nil nil)
;; Remove ID and return non-nil when it existed.
;;
;; Function: etaf-desktop-focus-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-focus-window "etaf-desktop" nil nil)
;; Raise and focus ID, switching to its workspace and restoring it from the
;; minimized taskbar when needed.
;;
;; Function: etaf-desktop-move-window (desktop id x y)
;;;###autoload (autoload 'etaf-desktop-move-window "etaf-desktop" nil nil)
;; Set ID's top-left position.  Moving a maximized window restores its saved
;; rectangle first.  X and Y are integers; a floating window may overflow the
;; canvas' left, right and bottom edges and the canvas clips it, but the
;; position is adjusted so at least 48 pixels of its width and its title row
;; stay inside the canvas.  Non-integer X or Y signals `etaf-desktop-error'.
;;
;; Function: etaf-desktop-resize-window (desktop id width height)
;;;###autoload (autoload 'etaf-desktop-resize-window "etaf-desktop" nil nil)
;; Set ID's size, clamped to its minimum and optional maximum.  Resizing a
;; maximized window restores its saved rectangle first.  A left or top edge
;; drag may cross the canvas' left edge; the top edge stops at the canvas top.
;;
;; Function: etaf-desktop-maximize-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-maximize-window "etaf-desktop" nil nil)
;; Maximize ID to the desktop canvas and retain its prior rectangle for restore.
;;
;; Function: etaf-desktop-minimize-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-minimize-window "etaf-desktop" nil nil)
;; Hide ID and expose it through the current workspace's taskbar.
;;
;; Function: etaf-desktop-restore-window (desktop id)
;;;###autoload (autoload 'etaf-desktop-restore-window "etaf-desktop" nil nil)
;; Restore ID from minimized or maximized state, then raise and focus it.
;;
;; Function: etaf-desktop-window-maximized-p (desktop id)
;;;###autoload (autoload 'etaf-desktop-window-maximized-p "etaf-desktop" nil nil)
;; Return non-nil when ID is maximized.
;;
;; Function: etaf-desktop-switch-workspace (desktop workspace)
;;;###autoload (autoload 'etaf-desktop-switch-workspace "etaf-desktop" nil nil)
;; Select WORKSPACE and choose its highest visible, non-minimized window.
;;
;; Function: etaf-desktop-add-workspace (desktop workspace)
;;;###autoload (autoload 'etaf-desktop-add-workspace "etaf-desktop" nil nil)
;; Add a unique workspace key and return it.
;;
;; Function: etaf-desktop-remove-workspace (desktop workspace)
;;;###autoload (autoload 'etaf-desktop-remove-workspace "etaf-desktop" nil nil)
;; Remove WORKSPACE, moving its windows to another workspace.  The final
;; workspace cannot be removed.
;;
;; Function: etaf-desktop-view (desktop)
;;;###autoload (autoload 'etaf-desktop-view "etaf-desktop" nil nil)
;; Return the root View for DESKTOP without mounting it.  A caller that mounts
;; this View owns the enclosing ETAF Runtime and buffer and must unmount them.
;;
;; Function: etaf-desktop-mount (desktop &optional buffer-or-name)
;;;###autoload (autoload 'etaf-desktop-mount "etaf-desktop" nil nil)
;; Mount DESKTOP and return its buffer.  A desktop may have one mounted Runtime.
;; This call owns the Runtime it creates; an existing target buffer remains
;; caller-owned.  The mounted buffer hides its header/mode lines.  Its native
;; cursor follows the input modality, like every mounted ETAF view: a pointer
;; press hides it and the next keyboard command restores it, so keyboard
;; navigation keeps its marker.  Cursor shape and global blink preferences are
;; unchanged.
;; Mutations publish through ETAF's reactive path and retain Ebox's committed
;; target and incremental display semantics.
;;
;; Function: etaf-desktop-fit-canvas (desktop &optional window)
;;;###autoload (autoload 'etaf-desktop-fit-canvas "etaf-desktop" nil nil)
;; Fit DESKTOP's default canvas to the live Emacs WINDOW displaying it; WINDOW
;; defaults to the window showing the mounted buffer.  A desktop created with
;; both `:canvas-width' and `:canvas-height' keeps them.  When the fitted
;; `(WIDTH . HEIGHT)' changes, the shell frame follows through retained
;; bindings, every tiled and monocle workspace reflows, maximized windows
;; refill the canvas and floating windows on every workspace shrink to it and
;; keep their title row and part of their width reachable, in one batch.
;; Return the new size, or nil when nothing changed.  A mounted desktop calls this itself
;; from Emacs' window size hooks; call it after resizing a window outside the
;; redisplay cycle, such as in batch Emacs.
;;
;; Function: etaf-desktop-close (desktop)
;;;###autoload (autoload 'etaf-desktop-close "etaf-desktop" nil nil)
;; Unmount the Runtime created by `etaf-desktop-mount' and kill its newly
;; created buffer.  A caller-mounted View and an existing target buffer remain
;; caller-owned.  Repeated calls are harmless.
;;
;; Function: etaf-desktop-open (&optional desktop buffer-or-name)
;;;###autoload (autoload 'etaf-desktop-open "etaf-desktop" nil t)
;; Create a default desktop when DESKTOP is nil, mount it, and return the
;; controller.  Interactive calls display the mounted buffer in the selected
;; Emacs window, without splitting or deleting existing windows.  Calls from
;; Lisp mount without changing the displayed buffer.

;; Function: etaf-desktop-demo-open (&optional buffer-or-name)
;;;###autoload (autoload 'etaf-desktop-demo-open "etaf-desktop" nil t)
;; Mount the runnable example desktop in *ETAF Desktop Demo* (or
;; BUFFER-OR-NAME) and return its controller.  It registers the Notes,
;; Tasks, Clock, Calculator, Chat and Monitor sample applications, launches
;; them across the `main' and `work' workspaces and leaves the launcher,
;; taskbar and settings dialog fully usable.  Reopening closes the previous
;; demo first; `etaf-desktop-close' disposes it and stops its timers.

;; Function: etaf-desktop-launcher-open-p (desktop)
;;;###autoload (autoload 'etaf-desktop-launcher-open-p "etaf-desktop" nil nil)
;; Return whether DESKTOP's controlled application launcher is visible.

;; Function: etaf-desktop-toggle-launcher (desktop &optional open)
;;;###autoload (autoload 'etaf-desktop-toggle-launcher "etaf-desktop" nil nil)
;; Set or toggle the application launcher visibility and return the new value.

;; Function: etaf-desktop-close-launcher (desktop)
;;;###autoload (autoload 'etaf-desktop-close-launcher "etaf-desktop" nil nil)
;; Close the application launcher.

;; Function: etaf-desktop-switcher-open-p (desktop)
;;;###autoload (autoload 'etaf-desktop-switcher-open-p "etaf-desktop" nil nil)
;; Return whether DESKTOP's controlled window switcher is visible.

;; Function: etaf-desktop-toggle-switcher (desktop &optional open)
;;;###autoload (autoload 'etaf-desktop-toggle-switcher "etaf-desktop" nil nil)
;; Set or toggle the window switcher visibility and return the new value.

;; Function: etaf-desktop-close-switcher (desktop)
;;;###autoload (autoload 'etaf-desktop-close-switcher "etaf-desktop" nil nil)
;; Close the window switcher.

;; Function: etaf-desktop-settings (desktop)
;;;###autoload (autoload 'etaf-desktop-settings "etaf-desktop" nil nil)
;; Return detached user settings for DESKTOP, including theme, layout mode,
;; tile spacing, title/content font sizes, optional font family and keybindings.
;; Both font sizes default to nil, following the inherited Emacs typography.

;; Function: etaf-desktop-set-setting (desktop key value)
;;;###autoload (autoload 'etaf-desktop-set-setting "etaf-desktop" nil nil)
;; Validate and set one user setting, returning the detached settings plist.
;; `:theme' accepts `system', `light', `dark' or a registered theme name
;; (default `system': the first built-in theme matching the Emacs frame mode;
;; `light'/`dark' select the first built-in theme of that mode).
;; `:accent-color' accepts nil (the theme's accent) or a "#RRGGBB" string
;; replacing the accent and its derived tints.  Theme changes repaint the
;; mounted shell through Theme paint slots without re-rendering windows.  A
;; panel that frames the desktop writes the same `:theme' choice through the
;; surface it declares, and applications in desktop windows receive the
;; resolved light/dark polarity through `etaf-appearance'.
;; `:tile-outer-gap' accepts integers 0..4 and `:tile-inner-gap' accepts integers
;; 1..4; both default to 1.  Gap units and allocation are described under
;; `etaf-desktop-layout-apply'.  Layout mode and tile spacing changes apply
;; immediately to the active workspace; the other values are projected by the
;; retained shell.  Invalid settings signal `etaf-desktop-error' without
;; changing settings or window geometry.  Settings persist in session state.
;; `:title-font-size' and `:content-font-size' accept nil (inherit, the default)
;; or numbers 8..32 in CSS reference pixels, independently for each region.
;; These are not point sizes: 16 CSS pixels is 12 points. `:font-family' is
;; nil to inherit or a font family string. Reset restores font inheritance.
;; `:keybindings' is a plist from action keyword (`:focus-next',
;; `:focus-previous', `:launcher', `:switcher', `:settings', `:toggle-layout',
;; `:split-window', `:swap-window', `:maximize-window', `:restore-window',
;; `:minimize-window', `:close-window') to a `kbd' string such as "n" or
;; "C-c n".  A sequence may not start with a printing key, and no binding may
;; be a prefix of another.  The bindings are the mounted shell's ETAF Host
;; keys: they are local to the Desktop buffer, listed by read-only `etaf-help'
;; and the explicit execution palette `etaf-palette', yield
;; to keys of focused application content and native input, and are inactive
;; while a modal dialog is open.  Focusing the next or previous window raises
;; it and moves keyboard focus into it.

;; Function: etaf-desktop-reset-settings (desktop)
;;;###autoload (autoload 'etaf-desktop-reset-settings "etaf-desktop" nil nil)
;; Restore the default Desktop settings, including one-cell tile gaps, and
;; return the detached plist.  The active workspace returns to floating mode.

;; Function: etaf-desktop-settings-open-p (desktop)
;;;###autoload (autoload 'etaf-desktop-settings-open-p "etaf-desktop" nil nil)
;; Return whether the in-buffer settings modal is visible.

;; Function: etaf-desktop-define-theme (name &key label (mode 'light) tokens)
;;;###autoload (autoload 'etaf-desktop-define-theme "etaf-desktop" nil nil)
;; Register or replace desktop theme NAME, a symbol other than `system',
;; `light' or `dark'.  LABEL is shown in Desktop Settings; MODE is `light' or
;; `dark'.  TOKENS is a plist of "#RRGGBB" colors for the shell tokens
;; (`:ui-shell-*', `:ui-canvas-*', `:ui-window-*', `:ui-divider-bg',
;; `:ui-accent*') and the dialog tokens (`:ui-panel-*', `:ui-picker-item-*',
;; `:ui-button-{primary,secondary}-{fg,bg}', `:ui-button-ghost-fg',
;; `:ui-checkbox-enabled-fg', `:ui-fg', `:ui-bg', `:ui-muted-fg',
;; `:ui-border'); omitted tokens fall back to the first
;; built-in theme of MODE.  Invalid names, modes or tokens signal
;; `etaf-desktop-error'.  Built-in themes: `daylight' and `paper' (light),
;; `midnight', `forest' and `graphite' (dark).  Return the registered plist.

;; Function: etaf-desktop-themes ()
;;;###autoload (autoload 'etaf-desktop-themes "etaf-desktop" nil nil)
;; Return registered themes in definition order as detached plists with
;; `:name', `:label' and `:mode'.

;; Function: etaf-desktop-theme-tokens (name)
;;;###autoload (autoload 'etaf-desktop-theme-tokens "etaf-desktop" nil nil)
;; Return the complete token plist of theme NAME, with `system', `light' and
;; `dark' resolved to their built-in theme.  Use it to match desktop colors
;; in tests or companion applications.

;; Function: etaf-desktop-toggle-settings (desktop &optional open)
;;;###autoload (autoload 'etaf-desktop-toggle-settings "etaf-desktop" nil nil)
;; Open or toggle the reusable ETAF UI settings modal.

;; Function: etaf-desktop-close-settings (desktop)
;;;###autoload (autoload 'etaf-desktop-close-settings "etaf-desktop" nil nil)
;; Close the settings modal without changing its values.
;;
;; Function: etaf-desktop-layout-sync (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-sync "etaf-desktop" nil nil)
;; Synchronize the layout registry with open windows.  New windows are
;; floating until tiled explicitly; closed windows are removed from trees.
;; Call this after application-level window mutations when using a custom
;; mutation path.
;;
;; Function: etaf-desktop-layout-refresh (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-refresh "etaf-desktop" nil nil)
;; Synchronize membership and apply `tiling', `master-stack' or `monocle' policy
;; in one guarded publication.  This is the desktop mutation integration hook.
;;
;; Function: etaf-desktop-layout-mode (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-mode "etaf-desktop" nil nil)
;; Return WORKSPACE's `floating', `tiling', `master-stack' or `monocle' policy mode.
;; WORKSPACE defaults to the active workspace.
;;
;; Function: etaf-desktop-toggle-layout-mode (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-toggle-layout-mode "etaf-desktop" nil t)
;; Switch WORKSPACE between `floating' and `tiling' and return DESKTOP.
;;
;; This is the interactive counterpart of `etaf-desktop-set-layout-mode': the
;; workspace bar's trailing control calls it, and other modes return to tiling.
;;
;; Function: etaf-desktop-set-layout-mode (desktop mode &optional workspace)
;;;###autoload (autoload 'etaf-desktop-set-layout-mode "etaf-desktop" nil nil)
;; Set and apply a workspace layout mode.  Tiling fills the inset canvas using
;; its layout tree; master-stack gives the first window a wide master region and
;; stacks the rest; monocle fills it with every tree leaf and raises the active
;; window; floating preserves each window's own rectangle.  A mode change exits
;; a temporary maximized view so it cannot cover the new layout.
;;
;; Function: etaf-desktop-layout-tree (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-tree "etaf-desktop" nil nil)
;; Return a detached layout tree using `(:leaf ID)' and
;; `(:split ORIENTATION RATIO FIRST SECOND)' nodes.
;;
;; Function: etaf-desktop-layout-set-tree (desktop tree &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-set-tree "etaf-desktop" nil nil)
;; Validate and apply a detached layout TREE for WORKSPACE.  Windows omitted
;; from TREE remain floating; this is also the public restore boundary for
;; persisted split topology and ratios.

;; Function: etaf-desktop-layout-floating-windows (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-floating-windows "etaf-desktop" nil nil)
;; Return floating window IDs for WORKSPACE as a detached list.
;;
;; Function: etaf-desktop-layout-apply (desktop &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-apply "etaf-desktop" nil nil)
;; Apply the current workspace layout and return the calculated rectangle list.
;; Horizontal splits divide width (left/right); vertical splits divide height
;; (top/bottom).  Tile spacing uses one frame character width per horizontal
;; cell and one text row per vertical cell.  Outer gaps inset the canvas and
;; shrink as needed to preserve pane minimum sizes.  Inner gaps separate panes;
;; their horizontal width is normally at least three pixels.  When pane
;; minimums cannot fit, inner gaps and pane sizes shrink to fit the canvas
;; where possible.  Divider handles are centered and confined to their gaps;
;; a zero-width gap has no handle.  Monocle uses the inset canvas for every leaf
;; and ignores inner gaps when deciding how much outer margin fits.
;; A maximized window keeps its full canvas view until restored or the mode
;; changes; floating windows keep their own rectangles.
;;
;; Function: etaf-desktop-layout-tile-window (desktop id &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-tile-window "etaf-desktop" nil nil)
;; Add ID to the workspace tiling tree and apply it.  Existing rectangles are
;; recomputed from the tree.
;;
;; Function: etaf-desktop-layout-untile-window (desktop id &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-untile-window "etaf-desktop" nil nil)
;; Remove ID from the tiling tree and leave it as a floating window.
;;
;; Function: etaf-desktop-layout-split (desktop target new-id orientation ratio &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-split "etaf-desktop" nil nil)
;; Insert NEW-ID beside TARGET using a horizontal or vertical split.  RATIO
;; controls the existing TARGET side and must be strictly between zero and one.
;; Both windows must already belong to WORKSPACE.
;;
;; Function: etaf-desktop-layout-resize-split (desktop path ratio &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-resize-split "etaf-desktop" nil nil)
;; Change the split at PATH, where each path element is 0 (first child) or 1
;; (second child), then apply the layout.
;;
;; Function: etaf-desktop-layout-remove-window (desktop id &optional workspace)
;;;###autoload (autoload 'etaf-desktop-layout-remove-window "etaf-desktop" nil nil)
;; Remove ID from layout policy after its owning window is closed.  This does
;; not close the window itself.

;; Function: etaf-desktop-register-app (id &key title icon open close serialize restore capabilities default-window replace)
;;;###autoload (autoload 'etaf-desktop-register-app "etaf-desktop" nil nil)
;; Register an ETAF application manifest.  Its callbacks receive a context
;; plist and may create one or more desktop windows.  Return a detached
;; manifest plist.

;; Function: etaf-desktop-unregister-app (id &optional force)
;;;###autoload (autoload 'etaf-desktop-unregister-app "etaf-desktop" nil nil)
;; Remove an application manifest, rejecting live instances unless FORCE is
;; non-nil.

;; Function: etaf-desktop-app (id)
;;;###autoload (autoload 'etaf-desktop-app "etaf-desktop" nil nil)
;; Return a detached manifest plist for ID.

;; Function: etaf-desktop-apps ()
;;;###autoload (autoload 'etaf-desktop-apps "etaf-desktop" nil nil)
;; Return all registered application manifests.

;; Function: etaf-desktop-app-registered-p (id)
;;;###autoload (autoload 'etaf-desktop-app-registered-p "etaf-desktop" nil nil)
;; Return non-nil when ID is registered.

;; Function: etaf-desktop-launch (desktop app-id &key instance-id options restore-data restore workspace)
;;;###autoload (autoload 'etaf-desktop-launch "etaf-desktop" nil nil)
;; Start an application instance.  Callback failures are isolated in an error
;; instance and placeholder window while the desktop remains usable.

;; Function: etaf-desktop-instances (desktop)
;;;###autoload (autoload 'etaf-desktop-instances "etaf-desktop" nil nil)
;; Return detached application instance states for DESKTOP.

;; Function: etaf-desktop-instance (desktop id)
;;;###autoload (autoload 'etaf-desktop-instance "etaf-desktop" nil nil)
;; Return detached state for application instance ID.

;; Function: etaf-desktop-set-instance-state (desktop id state)
;;;###autoload (autoload 'etaf-desktop-set-instance-state "etaf-desktop" nil nil)
;; Set application-owned serializable state for an instance.

;; Function: etaf-desktop-focus-instance (desktop id)
;;;###autoload (autoload 'etaf-desktop-focus-instance "etaf-desktop" nil nil)
;; Focus the first visible window belonging to application instance ID.

;; Function: etaf-desktop-suspend-instance (desktop id)
;;;###autoload (autoload 'etaf-desktop-suspend-instance "etaf-desktop" nil nil)
;; Minimize an application's windows and mark its lifecycle suspended.

;; Function: etaf-desktop-restore-instance (desktop id)
;;;###autoload (autoload 'etaf-desktop-restore-instance "etaf-desktop" nil nil)
;; Restore an application's windows and focus its instance.

;; Function: etaf-desktop-close-instance (desktop id &optional reason)
;;;###autoload (autoload 'etaf-desktop-close-instance "etaf-desktop" nil nil)
;; Close an application instance, invoke its callback and release its windows.

;; Function: etaf-desktop-session-state (desktop)
;;;###autoload (autoload 'etaf-desktop-session-state "etaf-desktop" nil nil)
;; Return a serializable desktop and application session plist, including
;; settings, tile spacing and per-workspace layout policies.

;; Function: etaf-desktop-save-session (desktop file)
;;;###autoload (autoload 'etaf-desktop-save-session "etaf-desktop" nil nil)
;; Save a session plist to FILE.

;; Function: etaf-desktop-restore-session (desktop session-or-file)
;;;###autoload (autoload 'etaf-desktop-restore-session "etaf-desktop" nil nil)
;; Restore a session plist or saved FILE; unknown applications become isolated
;; error placeholders.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-desktop-theme)
(require 'etaf-desktop-runtime)
(require 'etaf-desktop-layout)
(require 'etaf-desktop-apps)

(autoload 'etaf-desktop-demo-open "examples/etaf-desktop-demo" nil t)

(provide 'etaf-desktop)
;;; etaf-desktop.el ends here
