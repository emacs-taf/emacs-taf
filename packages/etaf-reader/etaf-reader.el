;;; etaf-reader.el --- Local ebook reader for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0") (etaf-db "0.1.0"))
;; Keywords: hypermedia, ui
;; URL: https://github.com/emacs-taf/etaf-reader

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-reader) after adding this repository
;; and the ETAF, ETAF UI, ETAF DB and Ebox roots to `load-path'.  The reader is
;; a local ebook application for Emacs: it scans a library directory for
;; EPUB/TXT/Markdown/HTML/FB2/PDF files, imports them into one SQLite library
;; through ETAF DB, and reads them with adaptive paged or scrolling layout,
;; text selection, highlight/underline/wavy annotations, thoughts, bookmarks
;; and reading progress.  Parsing is provided by the `ebook-parse' backend;
;; every annotation anchors on (chapter index, code point offset) of the
;; chapter's plain-text projection, so it survives re-wrapping, font changes
;; and window resizes.
;;
;; A session is the unit of state.  `etaf-reader-create' builds one, the
;; functions below drive it, `etaf-reader-state' reports it as plain data, and
;; `etaf-reader-app' or `etaf-reader-open' display it.  Every displayed value
;; is an ETAF reactive source, so a page turn or an annotation repaints the
;; mounted reader without a refresh call.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Function: etaf-reader-open (&optional file)
;;;###autoload (autoload 'etaf-reader-open "etaf-reader" nil t)
;; Mount the reader in the current window and return its buffer.
;; Without FILE it opens the shelf; a FILE path is imported and opened right
;; away; a session from `etaf-reader-create' is mounted as it is.  An empty
;; library directory is scanned once on first open; later rescans use the `i'
;; command.
;;
;; Function: etaf-reader-open-file (file)
;;;###autoload (autoload 'etaf-reader-open-file "etaf-reader" nil t)
;; Open FILE (an ebook) in a new reader and return its buffer.
;;
;; Function: etaf-reader-close ()
;;;###autoload (autoload 'etaf-reader-close "etaf-reader" nil t)
;; Save the reading position and close the open reader.
;; Unmounting releases the session's pending save timer and kills the buffer.
;; Killing the reader buffer directly saves the position the same way.
;; Signal `user-error' when no reader is open.
;; The library connection is cached for reuse by later sessions.
;;
;; Function: etaf-reader-create (&key parser theme)
;; Create a headless reader session and return it.
;; PARSER defaults to the `ebook-parse' backend; a caller may pass the plist
;; described by `etaf-reader-library' to drive the same reader from another
;; parser. Saved reading preferences are restored from the configured database;
;; an explicit THEME overrides the saved palette. The session owns no buffer and
;; no timer before it is mounted, so it is a complete headless reader for
;; scripts and tests.
;;
;; Function: etaf-reader-state (session)
;; Return SESSION's state as a detached plist snapshot.
;; Keys are `:view', `:book' (title), `:chapter' (index), `:lines', `:line',
;; `:mode', `:theme', `:density', `:pane', `:percent', `:annotations',
;; `:selection' and `:message'. The
;; snapshot copies every value, so mutating it never changes the reader.
;;
;; Function: etaf-reader-open-book (session book &optional parser)
;; Open BOOK in SESSION, importing it first when needed.
;; BOOK is a row from the library store; opening stores the reading position of
;; the previously open book first.  A missing or changed file is re-imported
;; through PARSER, which defaults to the session's parser.
;;
;; Function: etaf-reader-goto-percent (session percent)
;; Move SESSION to PERCENT (0-100) of the current book.
;;
;; Function: etaf-reader-search-book (session query)
;; Search the whole book for QUERY and jump to the first match.
;; Return the search state plist `(:query :matches :index)'; later
;; `etaf-reader-search-next' walks the matches.  The scan starts at the
;; current chapter and wraps around.
;;
;; Function: etaf-reader-annotate (session kind color)
;; Apply annotation KIND in COLOR to SESSION's current selection.
;; KIND is a string: `highlight' fills the range, `underline' and `wavy' draw
;; that decoration, `note' marks a range that carries a thought.  Return the
;; annotation identity, or nil when nothing is selected.
;;
;; Function: etaf-reader-annotation-note (session id note)
;; Attach NOTE (a string) to the annotation ID.
;;
;; Function: etaf-reader-annotation-delete (session id)
;; Delete the annotation ID.
;;
;; Function: etaf-reader-export-notes (session file)
;; Write SESSION's annotations of the current book to FILE as Markdown.
;;
;; Function: etaf-reader-view (session)
;; Return the mountable View of SESSION.
;; Use it to embed the reader in your own `etaf-mount' call; prefer
;; `etaf-reader-open' to also get a buffer, a keymap and window metrics.
;;
;; Function: etaf-reader-view-for-session (session)
;; Return the application View of SESSION, including its palette provider.
;;
;; Component: etaf-reader-app (&key session)
;; Render the mounted reader for SESSION and own its lifecycle.
;; SESSION must come from `etaf-reader-create'.  Mounting provides the palette
;; for its subtree; every displayed value is read from the session, so any
;; command or annotation repaints the reader without a remount.
;;
;; Function: etaf-reader-refresh-library (session)
;; Rescan the library directories and refresh SESSION's shelf rows.
;; Return a report plist `(:total :new :changed :failed)'.  Unchanged files
;; keep their annotations and reading state.
;;
;; Function: etaf-reader-books (session)
;; Return SESSION's loaded shelf rows, filtered by `etaf-reader-set-filter'.
;; Each row is a book plist (`:id', `:title', `:author', `:format', `:path',
;; `:chapters', `:chars', `:pages').  Refresh the shelf first (or open the
;; reader, which loads it) before reading this list.
;;
;; Function: etaf-reader-configure (session &rest options)
;; Validate, apply and persist reading options: :theme dark/light/sepia,
;; :mode page/scroll, :density compact/comfortable, :columns auto or 24..72.
;; Return the saved preference plist. Invalid options signal etaf-reader-error
;; before any change. Settings are restored when opening a new reader.
;;
;; Function: etaf-reader-filter-library (session query &optional filter sort)
;; Search cached titles/authors and reset the library page. FILTER is all,
;; reading, unread or finished; SORT is recent, title or author. Return books.
;;
;; Function: etaf-reader-library-page (session)
;; Return a bounded library page: :items, zero-based :index, :pages, :total.
;;
;; Function: etaf-reader-page-library (session delta)
;; Move the library by DELTA pages, clamp at the ends and return its page.
;;
;; Function: etaf-reader-show-pane (session pane)
;; Toggle toc, notes, bookmarks, search or settings. Help opens the shared
;; read-only modal in SESSION's mounted buffer, returning that buffer without
;; changing :pane; repeated help requests reuse it. A headless help request
;; signals etaf-reader-error. Nil closes both help and the navigation pane.
;; Reading navigation requires an open book. Storage is read before rendering.
;;
;; Function: etaf-reader-jump (session chapter offset)
;; Navigate to CHAPTER/OFFSET, retaining the previous position for jump-back.
;; History is session-owned, bounded to 100 entries and cleared on book change.
;;
;; Function: etaf-reader-jump-back (session)
;; Return to the previous navigation position; empty history shows a message.
;;
;; Function: etaf-reader-lines (session)
;; Return the wrapped lines of SESSION's current chapter.
;; Each line is a plist with `:key', `:start', `:end' (chapter offsets),
;; `:text', `:kind' and `:styles'.
;;
;; Function: etaf-reader-annotations (session &optional chapter)
;; Return SESSION's annotations of CHAPTER, or of the current chapter.
;;
;; Function: etaf-reader-set-filter (session filter)
;; Filter SESSION's shelf rows by FILTER (`all', `reading' or `unread').
;;
;; Function: etaf-reader-open-chapter (session index &optional offset)
;; Open chapter INDEX of SESSION's book, positioned at character OFFSET.
;;
;; Function: etaf-reader-goto-line (session line)
;; Move SESSION's first visible line to LINE.
;;
;; Function: etaf-reader-next-page (session)
;; Turn to the next page, moving into the next chapter at the end.
;;
;; Function: etaf-reader-previous-page (session)
;; Turn to the previous page, moving into the previous chapter at the start.
;;
;; Function: etaf-reader-next-chapter (session)
;; Open the next chapter.
;;
;; Function: etaf-reader-previous-chapter (session)
;; Open the previous chapter.
;;
;; Function: etaf-reader-scroll-lines (session delta)
;; Scroll SESSION by DELTA lines (negative scrolls back).
;;
;; Function: etaf-reader-percent (session)
;; Return SESSION's reading progress in percent of the whole book.
;;
;; Function: etaf-reader-set-metrics (session columns rows spread layout mode)
;; Set SESSION's layout explicitly and re-wrap the current chapter.
;; LAYOUT is `wide', `medium' or `narrow'; MODE is `page' or `scroll'.
;;
;; Function: etaf-reader-selection (session)
;; Return SESSION's selection as (START . END) chapter offsets, or nil.
;;
;; Function: etaf-reader-selection-text (session)
;; Return the selected text of SESSION, or an empty string.
;;
;; Function: etaf-reader-begin-selection (session line char)
;; Start a selection at LINE and CHAR; return its chapter offset.
;;
;; Function: etaf-reader-extend-selection (session line char)
;; Extend the active selection to LINE and CHAR; return its chapter offset.
;;
;; Function: etaf-reader-clear-selection (session)
;; Clear SESSION's selection, cursor and annotation toolbar.
;;
;; Function: etaf-reader-mark-annotation (session id kind color)
;; Change the annotation ID to KIND and COLOR, keeping its thought.
;;
;; Function: etaf-reader-save-now (session)
;; Write SESSION's reading position and reading time to the store.
;;
;; Function: etaf-reader-search-next (session &optional backward)
;; Jump to the next search match, or the previous one when BACKWARD is non-nil.
;;
;; Variable: etaf-reader-theme
;; Appearance of a new reader session: `dark', `light' or `sepia'.  The
;; running choice is the session's mode cell, which the reader's own switch
;; and a panel's title-bar switch both write; the option only seeds it.
;;
;; Variable: etaf-reader-library-directories
;; Directories scanned for local ebooks by the shelf scan.
;;
;; Variable: etaf-reader-parser-command
;; Command prefix that runs the ebook parser, or nil to discover one.
;; A value ending in `.py' runs under `python3'; a bare command runs directly.
;;
;; Variable: etaf-reader-store-file
;; SQLite file holding the reader's library, annotations and progress.
;;
;; Variable: etaf-reader-cache-directory
;; Directory holding extracted book assets (covers and images).
;;
;; Error: etaf-reader-error
;; Invalid ETAF reader operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-reader-theme)
(require 'etaf-reader-store)
(require 'etaf-reader-library)
(require 'etaf-reader-model)
(require 'etaf-reader-navigation)
(require 'etaf-reader-views)
(require 'etaf-reader-app)

(provide 'etaf-reader)
;;; etaf-reader.el ends here
