# etaf-posframe

Show any ETAF View in a floating child frame.  A panel does not take a window,
does not replace the current buffer and does not disturb the user's layout, so
ETAF content can appear next to ordinary editing work: a preview, a status
board, a detail card or a small form.

Requires Emacs 29.1 or newer, ETAF 0.3 and [Posframe](https://github.com/tumashu/posframe).
A graphical frame shows a panel with its full border and colours.  A text
terminal shows one too when Emacs provides the `tty-child-frames` feature
(Emacs 31 and later): the border takes one terminal cell in the terminal's own
colours, and `:border` width and colours apply to graphical frames.

```elisp
(require 'etaf-posframe)

(etaf-posframe-show
 (etaf-view
  (column :item-gap '(lh 0)
          (text :font-weight 'bold "Build finished")
          (text "3 tests failed in parser-tests")))
 :at 'window-top-right
 :width 36
 :auto-hide 6)
```

A panel is passive by default: it takes no keyboard focus and hides as soon as
the user works elsewhere.  `:focusable t` gives it the keyboard and
`:focus-on-open` decides whether it is selected on open; `:auto-hide nil` keeps
it until it is closed, `:draggable t` moves it by its title bar, and several
panels can be open at once.  The user documentation — the options, the
lifecycle, the failures and the Theme contract — is the
[Floating Panels](https://github.com/emacs-taf/etaf-manual/blob/main/book/en/posframe-panels.md)
and [Panel Applications](https://github.com/emacs-taf/etaf-manual/blob/main/book/en/posframe-applications.md)
chapters of the ETAF Reference Manual.

The [symbol card](examples/etaf-symbol-card.el) example uses the catalog from
`etaf-ui` and answers "what is this symbol, how is it called here, where do I go
next" in one keypress.  A pinned, draggable timer with three styles lives in its
own package, [etaf-pomodoro](https://github.com/emacs-taf/etaf-pomodoro).

## Applications as panels

`etaf-posframe-register-app` turns a whole ETAF application into a floating
panel, so each one opens with a single key instead of a command of its own.
This registry is a working setup: a player that keeps playing after its panel
closes, readers stacked at the top right, and games centred on a fixed board.

```elisp
(require 'etaf-posframe)

;; :create runs on every open and returns a fresh session (account, list,
;; timer); :view renders that session.  Both are plain functions, so an
;; application that ships xxx-create needs no glue, and one that first wants a
;; file prompt gets a small factory.
(defun my/etaf-md-preview-session ()
  (etaf-md-preview-create :file (read-file-name "Markdown: ")))

(defun my/etaf-manual-session ()
  "Open the manual where the reader stopped last time."
  (let ((session (etaf-manual-reader-create)))
    (etaf-manual-reader-restore session)
    session))

(defun my/etaf-rss-session ()
  (etaf-rss-create :client 'miniflux))

(defconst my/etaf-panel-apps
  '((ncm        :title "Music"        :create etaf-ncm-create     :view etaf-ncm-view
                :width 40 :height 17 :shortcut "m" :at frame-top-right :stack t
                :draggable t :keep-alive t
                :on-stop (lambda (session)
                           (ignore-errors (etaf-ncm-stop session))))
    (pomodoro   :title "Pomodoro"     :create etaf-pomodoro-create :view etaf-pomodoro-view
                :width 40 :shortcut "p" :at frame-top-right :stack t
                :focusable t :draggable t)
    (weread     :title "WeRead"       :create etaf-weread-create :view etaf-weread-view
                :width 100 :height 24 :shortcut "w" :at frame-top-right :stack t)
    (md-preview :title "Markdown"     :create my/etaf-md-preview-session :view etaf-md-preview-view
                :width 110 :height 26 :shortcut "d" :at frame-top-right :stack t)
    (manual     :title "ETAF Manual"  :create my/etaf-manual-session :view etaf-manual-reader-view
                :keep-alive t :width 180 :height 40 :shortcut "h" :at frame-center :stack t)
    (desktop    :title "Desktop"      :create etaf-desktop-create :view etaf-desktop-view
                :width (fraction 0.9) :height (fraction 0.9)
                :shortcut "D" :at frame-center :stack t)
    (rss        :title "RSS"          :create my/etaf-rss-session :view etaf-rss-view
                :width 100 :height 24 :shortcut "r" :at frame-top-right :stack t)
    (youtube    :title "YouTube"      :create etaf-youtube-create :view etaf-youtube-view
                :width 100 :height 24 :shortcut "y" :at frame-top-right :stack t)
    ;; Media and chat: their own palette, so a panel is a window, not a card.
    (bili       :title "Bilibili"     :create etaf-bili-create    :view etaf-bili-view
                :width (fraction 0.75) :height (fraction 0.8) :shortcut "B"
                :at frame-center :stack nil :draggable t)
    (telega     :title "Telegram"     :create etaf-telega-create  :view etaf-telega-view
                :width 110 :height 34 :shortcut "g" :at frame-center :stack nil)
    ;; Games: centred, large, not stacked against a reader.
    (solitaire  :title "Solitaire"    :create etaf-solitaire-create :view etaf-solitaire-view
                :width 50 :height 35 :shortcut "s" :at frame-center :stack nil :fill-height t)
    (xiangqi    :title "Xiangqi"       :create etaf-xiangqi-create :view etaf-xiangqi-view
                :resizable nil :width 75 :height 40 :shortcut "x" :at frame-center
                :stack nil :fill-height t)
    (tanks      :title "Tanks"        :create etaf-tanks-create   :view etaf-tanks-view
                :width 126 :height 32 :shortcut "t" :at (frame-center -3 0)
                :stack nil :fill-height t :draggable t))
  "One floating panel per ETAF application: (ID REGISTRATION-OPTIONS ...).
Small always-on panels sit at the top right and queue downward; games take the
centre, keep their board size and stay out of that column.")

(setq etaf-posframe-border-width 1
      etaf-posframe-border-hover-strength 0.4
      etaf-posframe-border-focus-strength 0.7)

(dolist (app my/etaf-panel-apps)
  (apply #'etaf-posframe-register-app (car app)
         (append (cdr app)
                 (list :require (intern (format "etaf-%s" (car app)))))))

;; One prefix for every shortcut above, plus walking between open panels.
(global-set-key (kbd "C-c e") #'etaf-posframe-app-prefix)
(define-key etaf-posframe-app-map (kbd "n") #'etaf-posframe-cycle)
(define-key etaf-posframe-app-map (kbd "q") #'etaf-posframe-app)
```

The shape of a registration:

- The key of each entry is the application id, so `:require` derives the
  `etaf-<id>` feature and the application loads on its first open, not at
  startup.
- `:create` takes no argument and runs once per open; `:view` receives that
  session.  Everything the application owns (account, queue, game state) lives
  in the session, so nothing outlives the panel unless `:keep-alive` is set.
- `:keep-alive t` hides the panel on close and keeps the session, so music
  keeps playing and a game pauses instead of restarting.  `:on-stop` runs with
  the session when `etaf-posframe-app-quit` really stops it.
- `:at frame-top-right` with `:stack t` makes the small panels queue downward
  without covering each other.  Games use `frame-center` with `:stack nil` and
  `:fill-height t`, and an `(ANCHOR ROWS COLS)` offset such as
  `(frame-center -3 0)` lifts a tall board off the minibuffer.
- `(fraction 0.9)` sizes the desktop panel against the parent frame, so it
  still opens nearly full-screen on another monitor.
- `:theme light` (or `dark`) pins a panel whose content declares no palette of
  its own; leave it out to follow the Emacs theme.
- `:focusable t` gives the panel the keyboard.  Panels opened by a shortcut are
  focused on open by default, which is what an application's own keys need.
- Registering an application rebuilds `etaf-posframe-app-map`, so bind extra
  keys such as `n` and `q` after the registrations, as above.

The [entry Commentary](etaf-posframe.el) is the supported API inventory.
Requires Emacs 29.1+, ETAF and Posframe on `load-path`; install from the ETAF
package archive once released, or add this checkout to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/etaf-posframe")
```

## Panels on a text terminal

Emacs 31 draws child frames on a text terminal, so the same panels work in
`emacs -nw`.  A terminal child frame takes neither the keyboard nor the mouse,
so a terminal reaches a panel through the app prefix map (the map you bind the
applications with, `C-c e` in the example setup):

| Key after the prefix | What it does |
| --- | --- |
| `left`, `right`, `up`, `down` | move the panel `etaf-posframe-move-step` cells (3 by default) |
| `=`, `+` | widen the panel |
| `-` | narrow it |
| `>`, `<` | heighten or shorten it |
| `k`, then a key | run that key in the panel, for the keys the View declares |

`etaf-posframe-move-step` (3) and `etaf-posframe-resize-step` (1) are the
defaults; `M-x etaf-posframe-move` and `M-x etaf-posframe-resize` take a count
with a prefix argument.  Control plus an arrow is deliberately not used: on
macOS the window manager switches desktop spaces before Emacs sees the key.

The arrow keys keep working after the first press: `C-c e`, then `right`, then
`right` again moves the same panel twice, and a held key repeats it.  Any other
key ends that run.  A panel stays inside its parent frame, so a run stops at the
edge.  Every one of them takes the panel of the selected frame, else the most
recent panel, so a prefix command works while the keyboard sits in an ordinary
buffer.
`etaf-posframe-move`, `etaf-posframe-resize` and `etaf-posframe-send-key` are
the same three operations as commands, and the first two prompt instead of
reading an arrow key.

A terminal cannot focus a child frame, so a control that needs the keyboard on
one row (a button reached through Tab) stays a graphical-frame feature.  A
terminal panel therefore suits a View whose keys are declared on the Host: the
player's `SPC`, `p` and `n` work through `k`, while clicking its buttons does
not.

## Checks

```sh
make check          # structure, compile, acceptance, API
make acceptance     # public behaviour scenarios
make compile        # byte-compile with warnings as errors
```

`make` needs Posframe discoverable.  It defaults to the newest
`~/.emacs.d/elpa/posframe-*`; set `POSFRAME_DIR=/path/to/posframe` for another
location.  GUI cases in the acceptance suite skip in batch Emacs and run in a
graphical verification instance.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE).
