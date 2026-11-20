;;; etaf-slides.el --- Slide decks in ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.4") (etaf-ui "0.3.3"))
;; Keywords: hypermedia, outlines
;; URL: https://github.com/emacs-taf/etaf-slides

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-slides) after adding this repository
;; and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  The application
;; presents a markdown deck as slides: one aspect-preserving 16:9 stage fills
;; the window, the slide body renders through ETAF UI's markdown renderer, and
;; the footer carries the deck title, the position and the presentation clock.
;; `SPC' or `RET' advances, `DEL' goes back, `o' lists every slide, `s' shows
;; the speaker notes, `+' and `-' change the type size and `?' lists every
;; key.  A presentation opens at four text scale steps, about twice the
;; frame's body size, because a slide is read from across a room.
;;
;; A deck is one markdown file.  Front matter (title, theme, author, date) is
;; optional, slides are separated by a line of three or more dashes, and the
;; first heading of a slide is its title.  A `::: notes' block holds the
;; speaker notes:
;;
;;   ---
;;   title: ETAF 幻灯片
;;   theme: light
;;   ---
;;
;;   # 一套内容，多种投影
;;
;;   正文用 markdown 写。
;;
;;   ---
;;
;;   ## 要点页
;;
;;   - 第一个要点
;;   - 第二个要点
;;
;;   ::: notes
;;   这一页讲什么。
;;   :::
;;
;; A session is the unit of state.  `etaf-slides-create' builds one from a file
;; or from text, `etaf-slides-open' displays it in its own buffer, the
;; navigation functions below drive it, and `etaf-slides-state' reports it as
;; plain data.  Every displayed value is an ETAF reactive source, so a slide
;; change, a theme change or a window resize repaints the mounted deck without
;; a refresh call or a remount.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions.
;;
;; Function: etaf-slides-open (deck &optional slide)
;;;###autoload (autoload 'etaf-slides-open "etaf-slides" nil t)
;; Open DECK in an ETAF slides buffer and return it.
;; DECK is a markdown deck file, a session from `etaf-slides-create', or nil to
;; ask for a file.  SLIDE is a one-based slide number.  An already open deck is
;; selected instead of mounted twice, so one session never has two hosts.
;; The buffer shows the stage plus a footer; the clock starts only in
;; presentation.
;;
;; Function: etaf-slides-present (deck &optional slide)
;;;###autoload (autoload 'etaf-slides-present "etaf-slides" nil t)
;; Present DECK in the whole frame and start its clock.
;; DECK and SLIDE are as in `etaf-slides-open'.  The presentation closes the
;; other windows, drops the window margins and fringes, and keeps the mode line
;; hidden; it does not change the frame's fullscreen state, which `f' toggles
;; explicitly.  Closing the buffer stops the clock.
;;
;; Function: etaf-slides-close ()
;;;###autoload (autoload 'etaf-slides-close "etaf-slides" nil t)
;; Close the current slides buffer and stop its clock.
;;
;; Function: etaf-slides-view (&optional session)
;;;###autoload (autoload 'etaf-slides-view "etaf-slides" nil t)
;; Return the View for SESSION, or for an empty deck when SESSION is nil.
;; Pass a session from `etaf-slides-create' to mount a deck yourself with
;; `etaf-mount', for example inside another layout or a batch test.
;;
;; Function: etaf-slides-create (&key file text title theme)
;; Return a new headless slide session.
;; FILE is a markdown deck read from disk, or TEXT is the deck itself; one of
;; them is required.  TITLE overrides the deck title and THEME starts at
;; `light', `dark' or `auto' (the default, which follows the frame).  A missing
;; or unreadable FILE, or a deck with no slides, signals `etaf-slides-error'.
;;
;; Function: etaf-slides-state (session)
;; Return SESSION as plain data.
;; The plist carries `:title', `:file', `:index' (zero based), `:count',
;; `:title-of', `:layout', `:notes', `:notes-visible', `:mode', `:theme',
;; `:appearance', `:clock', `:stage' (the geometry plist of
;; `etaf-slides-stage') and `:overflow' (zero-based indices whose estimated
;; content does not fit the stage).
;;
;; Function: etaf-slides-goto (session index)
;; Show slide INDEX of SESSION, clamped to the deck, and return it.
;; Indices count from zero, so `etaf-slides-goto' accepts the value a
;; zero-based caller reads back from `etaf-slides-state'.
;;
;; Function: etaf-slides-show (session index)
;; Show slide INDEX of SESSION on the stage and return the index.
;; Leaving the overview for a chosen slide is one action, so a caller does not
;; have to pair a jump with a mode change.
;;
;; Function: etaf-slides-next (session &optional count)
;; Move SESSION forward by COUNT slides (one by default) and return the index.
;; The last slide is a boundary: it stays selected instead of wrapping.
;;
;; Function: etaf-slides-previous (session &optional count)
;; Move SESSION back by COUNT slides (one by default) and return the index.
;;
;; Function: etaf-slides-set-mode (session mode)
;; Set SESSION's mode to `stage' or `overview' and return it.
;;
;; Function: etaf-slides-set-theme (session theme)
;; Set SESSION's THEME to `light', `dark' or `auto' and return it.
;; `auto' follows the frame's appearance through `etaf-appearance', so a theme
;; switch repaints a mounted deck.
;;
;; Function: etaf-slides-cycle-theme (session)
;; Advance SESSION's theme light, then dark, then auto; return the new theme.
;;
;; Function: etaf-slides-set-notes (session flag)
;; Show SESSION's speaker notes when FLAG is non-nil; return FLAG.
;; The notes band sits above the footer and never covers the slide.
;;
;; Function: etaf-slides-set-clock (session seconds)
;; Set SESSION's elapsed presentation clock to SECONDS, a display string.
;; The application's clock writes this cell once per second; a caller that
;; owns its own clock can write it directly.
;;
;; Function: etaf-slides-stage (width rows &optional char-width line-height)
;; Return the stage geometry for a WIDTH-pixel, ROWS-line viewport.
;; CHAR-WIDTH and LINE-HEIGHT are the frame's cell metrics in pixels.  The
;; stage keeps the 16:9 aspect ratio, takes the full width when the window is
;; wide enough and otherwise the full height, and never exceeds either budget.
;; Keys are `:columns', `:rows' (the stage itself), `:body-rows' (room for
;; slide content) and `:clipped' (the viewport is below the application's
;; minimum usable stage).
;;
;; Function: etaf-slides-next-slide ()
;;;###autoload (autoload 'etaf-slides-next-slide "etaf-slides" nil t)
;; Show the next slide in the current buffer.
;;
;; Function: etaf-slides-previous-slide ()
;;;###autoload (autoload 'etaf-slides-previous-slide "etaf-slides" nil t)
;; Show the previous slide in the current buffer.
;;
;; Function: etaf-slides-first-slide ()
;;;###autoload (autoload 'etaf-slides-first-slide "etaf-slides" nil t)
;; Show the first slide in the current buffer.
;;
;; Function: etaf-slides-last-slide ()
;;;###autoload (autoload 'etaf-slides-last-slide "etaf-slides" nil t)
;; Show the last slide in the current buffer.
;;
;; Function: etaf-slides-goto-slide (number)
;;;###autoload (autoload 'etaf-slides-goto-slide "etaf-slides" nil t)
;; Show slide NUMBER, counting from one, in the current buffer.
;; Interactively it reads NUMBER with `read-number' rather than a multi-key
;; sequence, so the deck's keys stay single-key and the framework's rules hold.
;;
;; Function: etaf-slides-toggle-overview ()
;;;###autoload (autoload 'etaf-slides-toggle-overview "etaf-slides" nil t)
;; Switch the current buffer between the stage and the slide overview.
;;
;; Function: etaf-slides-toggle-notes ()
;;;###autoload (autoload 'etaf-slides-toggle-notes "etaf-slides" nil t)
;; Show or hide the speaker notes band in the current buffer.
;;
;; Function: etaf-slides-next-theme ()
;;;###autoload (autoload 'etaf-slides-next-theme "etaf-slides" nil t)
;; Advance the current deck's theme: light, dark, then follow the frame.
;;
;; Function: etaf-slides-toggle-clock ()
;;;###autoload (autoload 'etaf-slides-toggle-clock "etaf-slides" nil t)
;; Start or stop the presentation clock in the current buffer.
;;
;; Function: etaf-slides-zoom-in ()
;;;###autoload (autoload 'etaf-slides-zoom-in "etaf-slides" nil t)
;; Enlarge the deck by one text scale step.
;; The stage re-fits around the larger cells, so the slide keeps its aspect
;; ratio and its content wraps instead of being clipped.
;;
;; Function: etaf-slides-zoom-out ()
;;;###autoload (autoload 'etaf-slides-zoom-out "etaf-slides" nil t)
;; Shrink the deck by one text scale step.
;;
;; Function: etaf-slides-zoom-reset ()
;;;###autoload (autoload 'etaf-slides-zoom-reset "etaf-slides" nil t)
;; Return the deck to the size it opened at: the presentation scale in a
;; presentation, the window scale in an ordinary window.
;;
;; Variable: etaf-slides-present-scale
;; Text scale steps of a presentation; default 4, about twice the body size.
;;
;; Variable: etaf-slides-window-scale
;; Text scale steps of a deck opened in an ordinary window; default 2.
;;
;; Function: etaf-slides-toggle-fullscreen ()
;;;###autoload (autoload 'etaf-slides-toggle-fullscreen "etaf-slides" nil t)
;; Toggle the frame's fullscreen state.
;; The application never changes it on its own: filling the screen is the
;; presenter's decision, not an opening side effect.
;;
;; Function: etaf-slides-edit-source ()
;;;###autoload (autoload 'etaf-slides-edit-source "etaf-slides" nil t)
;; Open the deck's markdown source in another window.
;; A session created from text has no source file; the command then signals
;; `user-error' instead of guessing a path.
;;
;; Error: etaf-slides-error
;; Invalid deck, session or navigation argument
;; Catch this condition with condition-case; failed calls do not return a
;; value.

;;; Code:

;; Consumers that only add this repository root to `load-path' reach the
;; submodules through this entry.
(add-to-list 'load-path
             (expand-file-name "lisp"
                               (file-name-directory (or load-file-name
                                                        buffer-file-name))))

(require 'etaf-slides-app)

(provide 'etaf-slides)
;;; etaf-slides.el ends here
