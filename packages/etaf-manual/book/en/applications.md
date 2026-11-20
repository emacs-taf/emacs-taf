# Applications

An *application* is one named buffer showing one mounted View, with the lifecycle a user expects from a program: it opens in the selected window, fits its content to that window as the window changes, follows its theme in every cell, answers its own keys, and saves its state once when it goes away. This chapter defines the application lifecycle that `etaf-app-open` and `etaf-app-close` provide, how fitting, theming and keys work for an application, and the recovery rules when opening or closing fails. Running command-line backends belongs to [Asynchronous Model](async.md#subprocesses).

An application builds on the [Runtime](runtime.md): `etaf-app-open` prepares and displays a buffer, then calls `etaf-mount`. A Runtime alone is enough for a View embedded in another buffer or a test; an application adds what a top-level program needs around it.

<!-- index: application; application buffer; application lifecycle -->

## Model

An application has a name, which is also its buffer name, a View, and three optional pieces of behavior supplied as functions: a fit function that adapts the application's state to the display window, a close function that saves or releases what the application holds, and the theme colors of its canvas. The application also carries one opaque state value, usually the record or session object its commands work on.

Opening is one transaction: the buffer is prepared as a canvas, displayed, fitted and mounted, and a failure at any step closes the application again. Closing has three triggers, killing the buffer, `etaf-app-close` and reopening the same name, and each runs the close function exactly once while the View is still mounted.

## Opening and closing

#### Function: etaf-app-open (name view &key state on-fit on-close background foreground (cursor 'inherit) mode-line (display t) mount-options)

Open VIEW as the application buffer NAME and return the buffer.

**Arguments.**

- NAME is the buffer name. An existing buffer of that name that is not an open application is reused.
- VIEW is passed to `etaf-mount`: a normalized View or a zero-argument function returning one.
- STATE is any value; `etaf-app-state` returns it.
- ON-FIT is nil or a function of one argument, the display window. It runs with the application buffer current.
- ON-CLOSE is nil or a function of no arguments. It runs with the application buffer current.
- BACKGROUND and FOREGROUND are nil or a color: a color string, a ref, a computed or a zero-argument function returning a color string or nil.
- CURSOR is a `cursor-type` value, or `inherit` (the default) to keep the buffer's cursor.
- MODE-LINE is nil (the default) to hide the mode line, t to keep it, or a `mode-line-format` value.
- DISPLAY is t (the default) to show the buffer in the selected window, a function that receives the buffer and displays it, or nil to leave it undisplayed.
- MOUNT-OPTIONS is the OPTIONS plist of `etaf-mount`, or a function of the display window (nil when the buffer is not displayed) that returns it. A function runs in the buffer after ON-FIT, so options such as a fixed `:viewport-height` can come from the fitted state.

**Semantics.** The steps run in this order.

1. An open application named NAME is closed first, with its close function.
2. The buffer is prepared as a canvas: lines are truncated, horizontal scrolling and scroll margins are off, line numbers are off and a truncated line shows no continuation glyph, so content wider than the window is clipped cleanly. CURSOR and MODE-LINE apply as described above.
3. BACKGROUND and FOREGROUND remap the buffer's default face, so the cells the View does not paint, such as the area below the last line, match the application's surface. A reactive color repaints when it changes, until the application closes.
4. DISPLAY shows the buffer. With t, the user's `display-buffer` rules cannot redirect it to another window or split the frame.
5. When the buffer has a window, ON-FIT runs once with that window, so the first render already uses fitted sizes.
6. VIEW mounts with MOUNT-OPTIONS, calling it first when it is a function.

After the mount, ON-FIT runs again after each settled change of the display window, as [Fitting to the window](#fitting-to-the-window) describes.

**Returns.** The application buffer.

**Errors.** Any error from a step, including `etaf-runtime-error` for invalid MOUNT-OPTIONS, View errors and a `quit` while opening, closes the application: the close function runs, the buffer is killed and the condition propagates.

**Example.** A notes application keeps a session object as its state, sizes its list in the fit function and saves on close.

```elisp
(defun notes-open ()
  (interactive)
  (let ((session (notes-session-create)))
    (etaf-app-open "*notes*" (lambda () (notes-view session))
                   :state session
                   :on-fit (lambda (window)
                             (notes-set-page-size
                              session (- (window-body-height window) 2)))
                   :on-close (lambda () (notes-save session))
                   :background (notes-theme-color session :bg))))
```

**See also.** `etaf-app-close`, `etaf-mount` and [Native application windows](runtime.md#native-application-windows).

#### Function: etaf-app-close (&optional buffer-or-name)

Close the application in BUFFER-OR-NAME, by default the current buffer, and return t.

**Semantics.** The close function runs while the View is still mounted, then the View unmounts and the buffer is killed. Interactively the command closes the application in the current buffer, so an application can bind it to `q` in its root `:keys`.

**Returns.** t.

**Errors.** `error→ user-error` when the buffer holds no open application. An error of the close function propagates after the buffer is gone; when the buffer is killed directly the same error is reported as a message instead, so `kill-buffer` itself never fails.

## Finding an application

#### Function: etaf-app-state (&optional buffer-or-name)

Return the STATE of the open application in BUFFER-OR-NAME, by default the current buffer, or nil.

**Semantics.** A key command runs in the application buffer, so it finds its session with `(etaf-app-state)` instead of a buffer-local variable of its own. The close function still sees the state, so it can save the session it belongs to; once the close function returns, the call returns nil.

#### Function: etaf-app-buffer (name)

Return the buffer of the open application NAME, or nil.

**Semantics.** An entry command that should return to an open application rather than reopen it checks this first and selects the buffer it returns.

## Fitting to the window

<!-- index: fit; resize; display window; fixed viewport -->

An application fits its content in ON-FIT: page sizes, row budgets, column widths, or a fixed viewport for an application whose canvas has a natural size. The function receives the display window and reads its body size; it writes refs, and the View renders from them.

After the mount, ON-FIT runs once per settled change: Emacs reports window size changes many times during a drag, and the engine waits until they stop before refitting the Runtime. ON-FIT then runs inside one reactive batch, after the Runtime's own viewport has been updated, so the refit and the application's changes publish together. It runs when the display window's body width or height changes, when the buffer moves to another window, and when the text scale changes. It does not run when the minibuffer or an echo-area message temporarily takes lines from the window, because the space returns as soon as they close; refitting would make the content jump twice.

An application that mounts with a fixed `:viewport-width` or `:viewport-height` still receives ON-FIT, so it can call `etaf-refit` with new dimensions there.

## Theme and canvas

<!-- index: canvas; default face; application background -->

The View paints only the cells it draws. The rest of the window, such as the lines below a short View or the right edge of a narrow one, shows the buffer's default face. BACKGROUND and FOREGROUND make those cells match the application: pass the same theme colors the root Host uses, as refs or functions when the theme can change while the application is open. The remapping belongs to the application buffer only and ends when the application closes.

## Keys

<!-- index: application keys; root :keys -->

An application declares its commands in the `:keys` of its root Host, as [Keyboard](keyboard.md#host-keys) describes; it does not install a keymap of its own. Root keys appear in help, yield to nearer Hosts and modal scopes, and leave the framework keys intact. Two resolution rules make root keys sufficient for an application.

- RET on the root acts on the application's selection, yet a focused button nearer than the root still receives RET.
- A pointer event, such as `<wheel-down>`, resolves from the Host under the pointer, so a pane can scroll itself with its own wheel binding.

## Errors and recovery

Opening never leaves a half-open application: when a step fails, the close function runs, the buffer is killed and the condition propagates, so the caller can fix the cause and open again. A close function should not signal; when it does, `etaf-app-close` reports the error after the buffer is gone and killing the buffer reports it as a message. Either way the application is closed and its name can be opened again.

The close function does not run when Emacs exits. An application whose state must survive the session saves it from `kill-emacs-hook` as well.
