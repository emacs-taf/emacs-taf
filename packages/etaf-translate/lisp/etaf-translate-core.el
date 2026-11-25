;;; etaf-translate-core.el --- Shared configuration and text utilities -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Shared error conditions, user options, script/language heuristics, spacing
;; hygiene and content hashing for `etaf-translate'.  Pure functions with no
;; Runtime or network dependency.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(define-error 'etaf-translate-error "ETAF translation error")
(define-error 'etaf-translate-engine-error "ETAF translation engine error"
  'etaf-translate-error)

;;;; Customization

(defgroup etaf-translate nil
  "Universal immersive page translation for ETAF Views."
  :group 'applications
  :prefix "etaf-translate-")

(defcustom etaf-translate-target-lang "zh-CN"
  "Default target language code (for example \"zh-CN\", \"en\", \"ja\")."
  :type 'string
  :group 'etaf-translate)

(defcustom etaf-translate-source-lang 'auto
  "Default source language code, or `auto' for automatic detection."
  :type '(choice (const :tag "Auto" auto) string)
  :group 'etaf-translate)

(defcustom etaf-translate-default-mode 'bilingual-stacked
  "Default presentation mode when enabling page translation.
One of `bilingual-stacked' or `replace'."
  :type '(choice (const :tag "Bilingual stacked" bilingual-stacked)
                 (const :tag "Replace in place" replace))
  :group 'etaf-translate)

(defcustom etaf-translate-default-style 'left-bar
  "Default visual style for bilingual translations.
One of `left-bar', `muted' or `tinted'."
  :type '(choice (const :tag "Left hairline" left-bar)
                 (const :tag "Muted ink" muted)
                 (const :tag "Subtle surface tint" tinted))
  :group 'etaf-translate)

(defcustom etaf-translate-default-scope 'content
  "Default extraction scope for page translation.
`content' translates prose, headings, quotes, list items and table cells while
skipping UI chrome and code; `full' also translates short UI labels."
  :type '(choice (const :tag "Main content" content)
                 (const :tag "Full page" full))
  :group 'etaf-translate)

(defcustom etaf-translate-default-engine 'openai
  "Symbol naming the default registered translation engine."
  :type 'symbol
  :group 'etaf-translate)

(defcustom etaf-translate-max-concurrency 5
  "Maximum number of concurrent in-flight translation requests per Runtime."
  :type 'integer
  :group 'etaf-translate)

(defcustom etaf-translate-batch-max-chars 1000
  "Soft character ceiling for combining adjacent units into one batch request."
  :type 'integer
  :group 'etaf-translate)

(defcustom etaf-translate-batch-max-units 4
  "Maximum number of translation units combined into one batch request."
  :type 'integer
  :group 'etaf-translate)

(defcustom etaf-translate-commit-debounce 0.25
  "Seconds to wait after an application commit before rescanning dirty text."
  :type 'number
  :group 'etaf-translate)

(defcustom etaf-translate-scroll-debounce 0.08
  "Seconds after scrolling before enqueueing newly visible units."
  :type 'number
  :group 'etaf-translate)

(defcustom etaf-translate-prefetch-lines 50
  "Lines ahead of the visible viewport band to prefetch eagerly."
  :type 'integer
  :group 'etaf-translate)

(defcustom etaf-translate-auto-retry-count 1
  "Automatic retries per unit after transient async engine failures."
  :type 'integer
  :group 'etaf-translate)

(defcustom etaf-translate-fallback-engine nil
  "Optional fallback engine or profile symbol used if the primary engine fails."
  :type '(choice (const :tag "None" nil) symbol)
  :group 'etaf-translate)

(defcustom etaf-translate-prompt-style 'technical
  "Prompt style for LLM translation engines.
One of `technical', `academic', `literary', `concise', or a custom prompt
instruction string."
  :type '(choice (const :tag "Technical documentation" technical)
                 (const :tag "Academic paper" academic)
                 (const :tag "Literary / book" literary)
                 (const :tag "Concise literal" concise)
                 (string :tag "Custom instruction"))
  :group 'etaf-translate)

(defcustom etaf-translate-enable-disk-cache t
  "When non-nil, back the shared cache with a local SQLite L2 store."
  :type 'boolean
  :group 'etaf-translate)

(defcustom etaf-translate-cache-file
  (locate-user-emacs-file "etaf-translate-cache.sqlite")
  "File path for the persistent L2 SQLite translation cache, or nil to disable."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'etaf-translate)

(defcustom etaf-translate-cache-ttl-days 90
  "Number of days to keep entries in the L2 SQLite cache (0 disables expiry)."
  :type 'integer
  :group 'etaf-translate)

(defcustom etaf-translate-cache-max-disk-entries 20000
  "Maximum number of entries retained in the L2 SQLite translation cache."
  :type 'integer
  :group 'etaf-translate)

(defcustom etaf-translate-state-file
  (locate-user-emacs-file "etaf-translate-state.eld")
  "File path storing persisted panel preferences, site rules and glossary, or nil."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'etaf-translate)

(defcustom etaf-translate-spacing-normalize t
  "When non-nil, keep a single ASCII space between CJK and Latin/digit runs."
  :type 'boolean
  :group 'etaf-translate)

;;;; Validation helpers

(defconst etaf-translate--valid-modes
  '(bilingual-stacked replace)
  "Supported presentation modes.")

(defconst etaf-translate--valid-styles
  '(left-bar muted tinted)
  "Supported bilingual visual styles.")

(defconst etaf-translate--valid-scopes
  '(content full)
  "Supported extraction scopes.")

(defun etaf-translate--check-mode (mode)
  "Return MODE when valid, otherwise signal `etaf-translate-error'."
  (unless (memq mode etaf-translate--valid-modes)
    (signal 'etaf-translate-error (list "Unsupported translation mode" mode)))
  mode)

(defun etaf-translate--check-style (style)
  "Return STYLE when valid, otherwise signal `etaf-translate-error'."
  (unless (memq style etaf-translate--valid-styles)
    (signal 'etaf-translate-error (list "Unsupported bilingual style" style)))
  style)

(defun etaf-translate--check-scope (scope)
  "Return SCOPE when valid, otherwise signal `etaf-translate-error'."
  (unless (memq scope etaf-translate--valid-scopes)
    (signal 'etaf-translate-error (list "Unsupported translation scope" scope)))
  scope)

;;;; Language and script detection

(defun etaf-translate--normalize-lang (lang)
  "Return the coarse language family symbol or string for LANG."
  (let ((s (downcase (string-trim (if (symbolp lang) (symbol-name lang) (or lang ""))))))
    (cond
     ((string-prefix-p "zh" s) 'zh)
     ((string-prefix-p "en" s) 'en)
     ((string-prefix-p "ja" s) 'ja)
     ((string-prefix-p "ko" s) 'ko)
     ((string-prefix-p "ru" s) 'ru)
     (t s))))

(defun etaf-translate--script-stats (text)
  "Return character-class counts for TEXT as a plist."
  (let ((cjk 0) (latin 0) (kana 0) (hangul 0) (cyrillic 0)
        (digits 0) (letters 0) (nonspace 0))
    (dotimes (i (length text))
      (let ((ch (aref text i)))
        (unless (memq ch '(?\s ?\t ?\n ?\r))
          (cl-incf nonspace)
          (cond
           ((or (<= #x4E00 ch #x9FFF)
                (<= #x3400 ch #x4DBF)
                (<= #xF900 ch #xFAFF))
            (cl-incf cjk)
            (cl-incf letters))
           ((or (<= #x3040 ch #x309F)
                (<= #x30A0 ch #x30FF))
            (cl-incf kana)
            (cl-incf letters))
           ((or (<= #xAC00 ch #xD7AF)
                (<= #x1100 ch #x11FF))
            (cl-incf hangul)
            (cl-incf letters))
           ((<= #x0400 ch #x04FF)
            (cl-incf cyrillic)
            (cl-incf letters))
           ((or (<= ?a ch ?z) (<= ?A ch ?Z)
                (<= #x00C0 ch #x024F))
            (cl-incf latin)
            (cl-incf letters))
           ((<= ?0 ch ?9)
            (cl-incf digits))))))
    (list :cjk cjk :latin latin :kana kana :hangul hangul :cyrillic cyrillic
          :digits digits :letters letters :nonspace nonspace)))

(defun etaf-translate-text-matches-target-p (text target-lang)
  "Return non-nil when TEXT already appears to be written in TARGET-LANG."
  (let* ((stats (etaf-translate--script-stats (or text "")))
         (letters (plist-get stats :letters))
         (cjk (plist-get stats :cjk))
         (latin (plist-get stats :latin))
         (kana (plist-get stats :kana))
         (hangul (plist-get stats :hangul))
         (cyrillic (plist-get stats :cyrillic))
         (family (etaf-translate--normalize-lang target-lang)))
    (when (> letters 0)
      (pcase family
        ('zh
         (and (zerop kana)
              (zerop hangul)
              (or (>= (/ (float cjk) letters) 0.45)
                  (and (>= cjk 4) (>= (/ (float cjk) letters) 0.30)))))
        ('ja
         (and (> kana 0)
              (>= (/ (float (+ kana cjk)) letters) 0.45)))
        ('ko
         (>= (/ (float hangul) letters) 0.35))
        ('ru
         (>= (/ (float cyrillic) letters) 0.50))
        ('en
         (and (zerop cjk) (zerop kana) (zerop hangul) (zerop cyrillic)
              (>= (/ (float latin) letters) 0.85)))
        (_ nil)))))

(defconst etaf-translate--url-or-path-re
  "\\`\\(?:https?://\\|file://\\|mailto:\\|~/\\|/[[:alnum:]_.-]+/\\|[A-Za-z]:\\\\\\)"
  "Regexp matching URLs and file paths that should not be translated.")

(defconst etaf-translate--identifier-re
  "\\`[A-Za-z_][A-Za-z0-9_]*\\(?:[-./:_][A-Za-z0-9_]+\\)+\\'"
  "Regexp matching technical identifiers such as `etaf-mount' or `foo.bar'.")

(defconst etaf-translate--token-re
  "\\`[A-Za-z_][A-Za-z0-9_./:-]*\\'"
  "Regexp matching a single technical token with no whitespace.")

(defun etaf-translate--technical-list-p (trimmed)
  "Return non-nil when TRIMMED is a list of technical/package identifiers.
Matches strings like \"etaf, etaf-ui\" or \"etaf-md, etaf, ebox\" while keeping
natural-language phrases with commas such as \"Hello, world\" translatable."
  (when (string-match-p "[,;]" trimmed)
    (let ((items (mapcar #'string-trim (split-string trimmed "[,;]+" t))))
      (and (>= (length items) 2)
           (cl-every (lambda (item)
                       (string-match-p etaf-translate--token-re item))
                     items)
           (cl-some (lambda (item)
                      (string-match-p etaf-translate--identifier-re item))
                    items)))))

(defun etaf-translate-text-meaningful-p (text)
  "Return non-nil when TEXT holds natural-language text worth translating."
  (let ((trimmed (string-trim (or text ""))))
    (and (> (length trimmed) 1)
         (not (string-match-p etaf-translate--url-or-path-re trimmed))
         (not (string-match-p etaf-translate--identifier-re trimmed))
         (not (etaf-translate--technical-list-p trimmed))
         (let* ((stats (etaf-translate--script-stats trimmed))
                (letters (plist-get stats :letters))
                (nonspace (plist-get stats :nonspace)))
           (and (>= letters 2)
                (> nonspace 0)
                (>= (/ (float letters) nonspace) 0.25))))))

;;;; Text normalization and hashing

(defun etaf-translate-normalize-spacing (text)
  "Return TEXT with clean single-space separation between CJK and Latin/digits.
Inline placeholders such as `<1>' and `⟦c0⟧' are preserved untouched."
  (if (or (not etaf-translate-spacing-normalize)
          (not (stringp text))
          (string-empty-p text))
      (or text "")
    (let ((s (subst-char-in-string ?\u3000 ?\s text)))
      (setq s (replace-regexp-in-string
               "\\([\u4e00-\u9fff]\\)\\([A-Za-z0-9]\\)" "\\1 \\2" s))
      (setq s (replace-regexp-in-string
               "\\([A-Za-z0-9]\\)\\([\u4e00-\u9fff]\\)" "\\1 \\2" s))
      s)))

(defun etaf-translate--join-wrapped-lines (text)
  "Normalize hard line wraps inside TEXT while preserving paragraph breaks."
  (let* ((paras (split-string (string-trim (or text "")) "\n[ \t]*\n+" t))
         (joined
          (mapcar
           (lambda (para)
             (let ((out ""))
               (dolist (raw (split-string para "\n" t))
                 (let ((s (string-trim raw)))
                   (unless (string-empty-p s)
                     (cond
                      ((string-empty-p out) (setq out s))
                      ((and (string-suffix-p "-" out)
                            (> (length out) 1)
                            (string-match-p "\\`[a-z]" s))
                       (setq out (concat (substring out 0 -1) s)))
                      (t
                       (let* ((last-ch (aref out (1- (length out))))
                              (first-ch (aref s 0))
                              (cjk-join (and (> last-ch 127) (> first-ch 127))))
                         (setq out (concat out (if cjk-join "" " ") s))))))))
               out))
           paras)))
    (mapconcat #'identity (cl-remove-if #'string-empty-p joined) "\n\n")))

(defun etaf-translate-text-hash (text)
  "Return a stable SHA-256 hex digest for TEXT."
  (secure-hash 'sha256 (encode-coding-string (or text "") 'utf-8)))

(provide 'etaf-translate-core)
;;; etaf-translate-core.el ends here
