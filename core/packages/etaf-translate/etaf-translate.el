;;; etaf-translate.el --- Universal immersive page translation for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.3.3
;; Package-Requires: ((emacs "29.1") (etaf "0.3.19") (etaf-ui "0.3.14") (etaf-posframe "0.3.5") (etaf-ext "0.1.4"))
;; Keywords: convenience, i18n, ui
;; URL: https://github.com/emacs-taf/etaf

;;; Commentary:

;; Universal immersive page translation for any mounted ETAF View, plus a
;; lightweight pure-translation quick popup usable in any Emacs buffer.
;;
;; Daily interactive commands (5):
;; - `etaf-translate-toggle': toggle page translation on or off.
;; - `etaf-translate-panel': toggle the slim top-right control panel.
;; - `etaf-translate-at-point': translate active region or word at point.
;; - `etaf-translate-paragraph': toggle inline paragraph translation in ETAF or popup-translate the paragraph at point in ordinary buffers.
;; - `etaf-translate-mode-cycle': cycle bilingual -> replace -> off.
;;
;; Supports 3 bilingual editorial styles (`left-bar', `muted', `tinted'),
;; in-place replace mode, persistent L2 SQLite caching, remembered site rules
;; without needing a global minor mode, SSE streaming engines (`openai', `anthropic', `deepl', `google', `command', `function')
;; with named profiles and automatic fallback, LaTeX math protection, and
;; built-in logical-paragraph providers for `maillist' and `etaf-reader'.
;;
;; Public API
;;
;; Load this package with (require 'etaf-translate) after adding this
;; repository, ETAF, ETAF UI, ETAF Posframe, ETAF Ext, Ebox and ECSS roots to `load-path'.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; docs/manual.md contains workflows.
;;
;; Error: etaf-translate-error
;; Invalid `etaf-translate' operation or configuration.
;; Catch this condition with `condition-case'; failed calls do not return a value.
;;
;; Error: etaf-translate-engine-error
;; Translation engine lookup or execution failure; parent is `etaf-translate-error'.
;;
;; Hook: etaf-translate-status-change-functions
;; Abnormal hook run with `(RUNTIME STATUS)' whenever translation status changes.
;;
;; Variable: etaf-translate-target-lang
;; Default target language code, for example "zh-CN" or "en".
;;
;; Variable: etaf-translate-source-lang
;; Default source language code, or `auto' for automatic detection.
;;
;; Variable: etaf-translate-default-mode
;; Default presentation mode: `bilingual-stacked' or `replace'.
;;
;; Variable: etaf-translate-default-style
;; Default bilingual visual style: `left-bar', `muted' or `tinted'.
;;
;; Variable: etaf-translate-default-scope
;; Default extraction scope: `content' (prose and headings) or `full' (includes UI chrome).
;;
;; Variable: etaf-translate-default-engine
;; Symbol naming the default registered engine or named profile.
;;
;; Variable: etaf-translate-fallback-engine
;; Optional fallback engine or profile symbol used after primary engine failure.
;;
;; Variable: etaf-translate-prompt-style
;; LLM prompt style: `technical', `academic', `literary', `concise', or custom string.
;;
;; Variable: etaf-translate-max-concurrency
;; Maximum concurrent in-flight translation batches per Runtime.
;;
;; Variable: etaf-translate-batch-max-chars
;; Soft character limit when combining adjacent translation units into one batch.
;;
;; Variable: etaf-translate-batch-max-units
;; Maximum number of translation units combined into one batch request.
;;
;; Variable: etaf-translate-commit-debounce
;; Seconds to wait after an application commit before scanning changed text.
;;
;; Variable: etaf-translate-scroll-debounce
;; Seconds to wait after scrolling before enqueueing newly visible units.
;;
;; Variable: etaf-translate-prefetch-lines
;; Lines ahead of the visible viewport band prefetched eagerly.
;;
;; Variable: etaf-translate-auto-retry-count
;; Automatic retries per unit after transient asynchronous engine failures.
;;
;; Variable: etaf-translate-enable-disk-cache
;; When non-nil, back the shared cache with a local SQLite L2 store.
;;
;; Variable: etaf-translate-cache-file
;; File path for the persistent L2 SQLite translation cache, or nil to disable.
;;
;; Variable: etaf-translate-cache-ttl-days
;; Number of days to retain L2 SQLite entries (0 disables expiry).
;;
;; Variable: etaf-translate-cache-max-disk-entries
;; Maximum number of entries retained in the L2 SQLite cache.
;;
;; Variable: etaf-translate-state-file
;; File path storing persisted panel preferences, site rules and glossary, or nil.
;;
;; Variable: etaf-translate-buffer-domain
;; Optional buffer-local domain or site identifier override for rule matching.
;;
;; Variable: etaf-translate-use-posframe
;; When non-nil, show control panel and popups via `etaf-posframe' if available.
;;
;; Variable: etaf-translate-spacing-normalize
;; When non-nil, keep a single ASCII space between CJK and Latin/digit runs.
;;
;; Variable: etaf-translate-glossary
;; Global terminology alist of `(SOURCE . TARGET)' pairs preserved in translation.
;;
;; Variable: etaf-translate-openai-endpoint
;; Chat completions HTTP URL for the built-in `openai' engine.
;;
;; Variable: etaf-translate-openai-model
;; Model identifier sent by the built-in `openai' engine.
;;
;; Variable: etaf-translate-openai-api-key
;; API key string, zero-argument function, or nil to read `OPENAI_API_KEY'.
;;
;; Variable: etaf-translate-openai-timeout
;; Timeout in seconds for one request (or SSE idle stall) of `openai'.
;;
;; Variable: etaf-translate-openai-temperature
;; Sampling temperature sent by the built-in `openai' engine.
;;
;; Variable: etaf-translate-openai-stream
;; When non-nil, stream `openai' replies over SSE and render units incrementally.
;;
;; Variable: etaf-translate-anthropic-endpoint
;; Messages API HTTP URL for the built-in `anthropic' (Claude) engine.
;;
;; Variable: etaf-translate-anthropic-model
;; Model identifier sent by the built-in `anthropic' engine.
;;
;; Variable: etaf-translate-anthropic-api-key
;; API key string, zero-argument function, or nil to read `ANTHROPIC_API_KEY'.
;;
;; Variable: etaf-translate-anthropic-max-tokens
;; Maximum output tokens per request for the built-in `anthropic' engine.
;;
;; Variable: etaf-translate-anthropic-timeout
;; Timeout in seconds for one request or SSE idle stall of `anthropic'.
;;
;; Variable: etaf-translate-anthropic-stream
;; When non-nil, stream `anthropic' replies over SSE incrementally.
;;
;; Variable: etaf-translate-deepl-api-key
;; API key string, zero-argument function, or nil to read `DEEPL_API_KEY'.
;;
;; Variable: etaf-translate-deepl-endpoint
;; Optional DeepL endpoint override; nil auto-selects Free (`:fx') vs Pro.
;;
;; Variable: etaf-translate-deepl-timeout
;; Timeout in seconds for one request of the built-in `deepl' engine.
;;
;; Variable: etaf-translate-google-endpoint
;; Endpoint URL for the zero-key `google' translation engine.
;;
;; Variable: etaf-translate-google-timeout
;; Timeout in seconds for one request of the built-in `google' engine.
;;
;; Variable: etaf-translate-curl-program
;; Executable name or path of `curl' used by HTTP translation engines.
;;
;; Variable: etaf-translate-command
;; Command list for the built-in `command' CLI translation engine.
;;
;; Variable: etaf-translate-command-timeout
;; Timeout in seconds for one request of the built-in `command' engine.
;;
;; Variable: etaf-translate-function-backend
;; Custom synchronous function `(TEXT SOURCE TARGET GLOSSARY)' for the `function' engine.
;;
;; Function: etaf-translate-toggle (&optional runtime)
;;;###autoload (autoload 'etaf-translate-toggle "etaf-translate" nil t)
;; Interactive command toggling immersive translation on or off for mounted RUNTIME.
;;
;; Function: etaf-translate-panel (&optional runtime)
;;;###autoload (autoload 'etaf-translate-panel "etaf-translate" nil t)
;; Interactive command toggling the floating control panel for mounted RUNTIME.
;;
;; Function: etaf-translate-at-point (&optional text engine)
;;;###autoload (autoload 'etaf-translate-at-point "etaf-translate" nil t)
;; Interactive command translating TEXT (or active region / word at point) in a
;; pure-translation floating popup with automatic height and vertical scrolling.
;;
;; Function: etaf-translate-paragraph (&optional runtime)
;;;###autoload (autoload 'etaf-translate-paragraph "etaf-translate" nil t)
;; Interactive command toggling inline translation for the paragraph at point in
;; a mounted ETAF RUNTIME, or opening the quick-translate popup for the paragraph
;; at point in any ordinary non-ETAF buffer.
;;
;; Function: etaf-translate-mode-cycle (&optional runtime)
;;;###autoload (autoload 'etaf-translate-mode-cycle "etaf-translate" nil t)
;; Interactive command cycling RUNTIME through bilingual-stacked, replace and off.
;;
;; Function: etaf-translate-enable (&optional runtime &rest options)
;;;###autoload (autoload 'etaf-translate-enable "etaf-translate" nil nil)
;; Enable immersive translation on mounted RUNTIME (default active/current buffer)
;; with optional plist OPTIONS (`:mode', `:style', `:scope', `:source-lang',
;; `:target-lang', `:engine', `:fallback-engine', `:prompt-style', `:glossary',
;; `:cache') and return its status plist.
;;
;; Function: etaf-translate-disable (&optional runtime)
;;;###autoload (autoload 'etaf-translate-disable "etaf-translate" nil nil)
;; Disable translation on mounted RUNTIME, cancelling in-flight requests and
;; restoring every Host to its authoritative content in one flush.
;;
;; Function: etaf-translate-set-mode (mode &optional runtime)
;;;###autoload (autoload 'etaf-translate-set-mode "etaf-translate" nil nil)
;; Switch active presentation MODE (`bilingual-stacked' or `replace') on RUNTIME
;; using cached translations without re-querying the engine.
;;
;; Function: etaf-translate-set-style (style &optional runtime)
;;;###autoload (autoload 'etaf-translate-set-style "etaf-translate" nil nil)
;; Switch active bilingual STYLE (`left-bar', `muted' or `tinted') on RUNTIME.
;;
;; Function: etaf-translate-set-scope (scope &optional runtime)
;;;###autoload (autoload 'etaf-translate-set-scope "etaf-translate" nil nil)
;; Switch active extraction SCOPE (`content' or `full') on RUNTIME.
;;
;; Function: etaf-translate-set-engine (engine &optional runtime)
;;;###autoload (autoload 'etaf-translate-set-engine "etaf-translate" nil nil)
;; Switch active translation ENGINE or named profile on RUNTIME.
;;
;; Function: etaf-translate-set-languages (source-lang target-lang &optional runtime)
;;;###autoload (autoload 'etaf-translate-set-languages "etaf-translate" nil nil)
;; Switch SOURCE-LANG and TARGET-LANG for RUNTIME's active translation.
;;
;; Function: etaf-translate-set-prompt-style (prompt-style &optional runtime)
;;;###autoload (autoload 'etaf-translate-set-prompt-style "etaf-translate" nil nil)
;; Switch LLM PROMPT-STYLE (`technical', `academic', `literary', `concise').
;;
;; Function: etaf-translate-retry-failed (&optional runtime)
;;;###autoload (autoload 'etaf-translate-retry-failed "etaf-translate" nil nil)
;; Retry all failed translation units on RUNTIME and return the count retried.
;;
;; Function: etaf-translate-refresh (&optional runtime)
;;;###autoload (autoload 'etaf-translate-refresh "etaf-translate" nil nil)
;; Evict cached translations for RUNTIME's current units and re-translate them.
;;
;; Function: etaf-translate-status (&optional runtime)
;;;###autoload (autoload 'etaf-translate-status "etaf-translate" nil nil)
;; Return a detached status plist for RUNTIME (`:active', `:site', `:mode',
;; `:style', `:scope', `:engine', `:fallback-engine', `:prompt-style',
;; `:source-lang', `:target-lang', `:total', `:translated', `:cache-hits',
;; `:pending', `:deferred', `:failed').
;;
;; Function: etaf-translate-panel-close ()
;;;###autoload (autoload 'etaf-translate-panel-close "etaf-translate" nil nil)
;; Close the open `etaf-translate' control panel if visible.
;;
;; Function: etaf-translate-popup-close ()
;;;###autoload (autoload 'etaf-translate-popup-close "etaf-translate" nil nil)
;; Close the active quick-translate popup if visible.
;;
;; Function: etaf-translate-register-engine (name &rest spec)
;;;###autoload (autoload 'etaf-translate-register-engine "etaf-translate" nil nil)
;; Register or replace async translation engine NAME with plist SPEC (`:translate',
;; optional `:label', `:supports-batch', `:max-chars').
;;
;; Function: etaf-translate-unregister-engine (name)
;;;###autoload (autoload 'etaf-translate-unregister-engine "etaf-translate" nil nil)
;; Remove engine NAME from the registry; return non-nil if it was present.
;;
;; Function: etaf-translate-engines ()
;;;###autoload (autoload 'etaf-translate-engines "etaf-translate" nil nil)
;; Return a detached list of registered engine descriptors.
;;
;; Function: etaf-translate-register-profile (name &rest spec)
;;;###autoload (autoload 'etaf-translate-register-profile "etaf-translate" nil nil)
;; Register or replace named engine profile NAME over `:engine' with optional
;; `:label', `:endpoint', `:model', `:api-key', `:stream', `:prompt-style', `:fallback'.
;;
;; Function: etaf-translate-unregister-profile (name)
;;;###autoload (autoload 'etaf-translate-unregister-profile "etaf-translate" nil nil)
;; Remove named profile NAME from the registry; return non-nil if it was present.
;;
;; Function: etaf-translate-profiles ()
;;;###autoload (autoload 'etaf-translate-profiles "etaf-translate" nil nil)
;; Return a detached list of registered named profile descriptors.
;;
;; Function: etaf-translate-register-rule (name &rest spec)
;;;###autoload (autoload 'etaf-translate-register-rule "etaf-translate" nil nil)
;; Register or replace declarative rule NAME with plist SPEC (`:priority', `:domain',
;; `:buffer-regexp', `:major-mode', `:predicate', `:mode', `:style', `:scope',
;; `:source-lang', `:target-lang', `:engine', `:fallback-engine', `:prompt-style',
;; `:auto-translate', `:never-translate', `:exclude-roles', `:exclude-classes',
;; `:glossary').
;;
;; Function: etaf-translate-unregister-rule (name)
;;;###autoload (autoload 'etaf-translate-unregister-rule "etaf-translate" nil nil)
;; Remove rule NAME from the registry; return non-nil if it was present.
;;
;; Function: etaf-translate-rules ()
;;;###autoload (autoload 'etaf-translate-rules "etaf-translate" nil nil)
;; Return a detached list of registered rules sorted by `:priority'.
;;
;; Function: etaf-translate-current-site (&optional runtime)
;;;###autoload (autoload 'etaf-translate-current-site "etaf-translate" nil nil)
;; Return the site/domain or application identifier for RUNTIME's buffer, or nil.
;;
;; Function: etaf-translate-remember-site (site action &optional overrides)
;;;###autoload (autoload 'etaf-translate-remember-site "etaf-translate" nil nil)
;; Persist preference ACTION (`auto', `never' or `custom') for SITE.
;;
;; Function: etaf-translate-forget-site (site)
;;;###autoload (autoload 'etaf-translate-forget-site "etaf-translate" nil nil)
;; Remove persisted rule for SITE and update `etaf-translate-state-file'.
;;
;; Function: etaf-translate-add-glossary-term (source target &optional persist)
;;;###autoload (autoload 'etaf-translate-add-glossary-term "etaf-translate" nil nil)
;; Add or update `(SOURCE . TARGET)' in `etaf-translate-glossary' and optionally PERSIST.
;;
;; Function: etaf-translate-remove-glossary-term (source &optional persist)
;;;###autoload (autoload 'etaf-translate-remove-glossary-term "etaf-translate" nil nil)
;; Remove SOURCE from `etaf-translate-glossary' and optionally PERSIST.
;;
;; Function: etaf-translate-register-provider (name &rest spec)
;;;###autoload (autoload 'etaf-translate-register-provider "etaf-translate" nil nil)
;; Register a virtualized content provider adapter NAME with `:match',
;; `:extract', `:apply' and `:clear' callbacks.
;;
;; Function: etaf-translate-unregister-provider (name)
;;;###autoload (autoload 'etaf-translate-unregister-provider "etaf-translate" nil nil)
;; Remove virtualized content provider NAME; return non-nil if it was present.
;;
;; Function: etaf-translate-providers ()
;;;###autoload (autoload 'etaf-translate-providers "etaf-translate" nil nil)
;; Return a list of registered virtualized provider names.
;;
;; Function: etaf-translate-make-unit (&rest args)
;;;###autoload (autoload 'etaf-translate-make-unit "etaf-translate" nil nil)
;; Create a translation unit for custom virtualized providers from keyword ARGS
;; (`:id', `:text', optional `:markup', `:kind', `:geometry', `:constrained').
;;
;; Function: etaf-translate-sqlite-persistence (&optional file ttl-days max-entries)
;;;###autoload (autoload 'etaf-translate-sqlite-persistence "etaf-translate" nil nil)
;; Create a native SQLite L2 persistence plist for `etaf-translate-cache-create',
;; or nil when SQLite support is unavailable.
;;
;; Function: etaf-translate-cache-create (&rest options)
;;;###autoload (autoload 'etaf-translate-cache-create "etaf-translate" nil nil)
;; Create a two-tier translation cache with optional `:max-entries' and L2
;; `:persistence' plist (`:get', `:put', optional `:remove', `:clear', `:stats', `:prune').
;;
;; Function: etaf-translate-cache-clear (&optional cache)
;;;###autoload (autoload 'etaf-translate-cache-clear "etaf-translate" nil nil)
;; Clear CACHE (defaulting to the shared cache) and its persistence backend.
;;
;; Function: etaf-translate-cache-stats (&optional cache)
;;;###autoload (autoload 'etaf-translate-cache-stats "etaf-translate" nil nil)
;; Return statistics plist for CACHE (`:l1-entries', `:l2-entries', `:hits', `:misses', ...).
;;
;; Function: etaf-translate-cache-prune (&optional cache)
;;;###autoload (autoload 'etaf-translate-cache-prune "etaf-translate" nil nil)
;; Prune expired and excess LRU entries from CACHE's L2 backend and return deleted count.
;;
;; Function: etaf-translate-text-matches-target-p (text target-lang)
;;;###autoload (autoload 'etaf-translate-text-matches-target-p "etaf-translate" nil nil)
;; Return non-nil when TEXT already appears to be written in TARGET-LANG.
;;
;; Function: etaf-translate-text-meaningful-p (text)
;;;###autoload (autoload 'etaf-translate-text-meaningful-p "etaf-translate" nil nil)
;; Return non-nil when TEXT contains natural-language content worth translating.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-translate")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-translate.el" dir))
                                (file-exists-p (expand-file-name "etaf-translate.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-translate-core)
(require 'etaf-translate-store)
(require 'etaf-translate-cache)
(require 'etaf-translate-rules)
(require 'etaf-translate-extract)
(require 'etaf-translate-engine)
(require 'etaf-translate-render)
(require 'etaf-translate-scheduler)
(require 'etaf-translate-session)
(require 'etaf-translate-ui)
(require 'etaf-translate-integrations)

(provide 'etaf-translate)
;;; etaf-translate.el ends here
