;;; etaf-translate-render.el --- Theme-aware bilingual and replace Views -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Converts translated units, loading placeholders and retryable error states
;; into ETAF presentation specs (`override', `companion-inside' and
;; `companion-after').  Colors derive dynamically from the active palette and
;; appearance; type size is never shrunk with `:font-size'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)
(require 'etaf-translate-core)
(require 'etaf-translate-extract)

;;;; Theme-derived palette

(defun etaf-translate--frame-for-runtime (runtime)
  "Return the frame currently displaying RUNTIME, or the selected frame."
  (let* ((buf (and runtime (etaf-runtime-buffer runtime)))
         (win (and (buffer-live-p buf) (get-buffer-window buf t))))
    (or (and (window-live-p win) (window-frame win))
        (selected-frame))))

(defun etaf-translate--palette (runtime)
  "Return restrained editorial translation colors derived from `etaf-ext-theme'."
  (let* ((frame (etaf-translate--frame-for-runtime runtime))
         (th (with-current-buffer (etaf-runtime-buffer runtime)
               (etaf-ext-theme frame)))
         (dark (eq (plist-get th :ext-mode) 'dark))
         (bg (plist-get th :ext-bg))
         (fg (plist-get th :ext-fg))
         (accent (or (plist-get th :ext-accent-fill)
                     (plist-get th :ext-accent)))
         ;; Secondary editorial ink: distinct from 100% original text yet crisp.
         (ink (etaf-ui-color-legible
               (etaf-ui-color-mix fg bg (if dark 0.30 0.28)) bg 4.5))
         ;; Calm muted ink for `muted' style, headings and quote translations.
         (muted (etaf-ui-color-legible
                 (etaf-ui-color-mix fg bg (if dark 0.44 0.42)) bg 3.6))
         ;; Whisper-thin low-saturation left hairline (never loud neon).
         (bar (etaf-ui-color-mix accent bg (if dark 0.62 0.58)))
         (quote-bar (etaf-ui-color-mix fg bg (if dark 0.66 0.68)))
         (tint (etaf-ui-color-mix bg fg (if dark 0.038 0.028)))
         (quote-bg (etaf-ui-color-mix bg fg (if dark 0.035 0.025)))
         (danger (plist-get th :ext-danger)))
    (list :bg bg :fg fg :ink ink :muted muted :bar bar :quote-bar quote-bar
          :tint tint :quote-bg quote-bg :danger danger)))

;;;; Inline run View construction

(defun etaf-translate--segment-node (runtime segment default-ink preserve-color-p)
  "Build one ETAF `text' View node for decoded SEGMENT in RUNTIME.
DEFAULT-INK is applied when PRESERVE-COLOR-P is nil and SEGMENT has no explicit
link color.  Interactive link segments forward presses back to their original
Host via `etaf-runtime-trigger-host-press'."
  (let* ((text (or (plist-get segment :text) ""))
         (orig (plist-get segment :props))
         (host-id (plist-get segment :host-id))
         (atomic-p (plist-get segment :atomic))
         (role (plist-get orig :role))
         (is-link (or (eq role 'link)
                      (and (stringp role) (string= (downcase role) "link"))))
         (props nil))
    (dolist (key '(:font-weight :font-style :text-decoration-line
                   :background-color :font-family :help-echo :pointer :tab-index))
      (when-let* ((val (plist-get orig key)))
        (setq props (plist-put props key val))))
    (when (and preserve-color-p (plist-get orig :font-size))
      (setq props (plist-put props :font-size (plist-get orig :font-size))))
    (cond
     ((and (or preserve-color-p is-link atomic-p) (plist-get orig :color))
      (setq props (plist-put props :color (plist-get orig :color))))
     (default-ink
      (setq props (plist-put props :color default-ink))))
    (when is-link
      (setq props (plist-put props :role 'link)))
    (when (and host-id (plist-get orig :has-on-press))
      (setq props (plist-put props :on-press
                             (lambda ()
                               (if-let* ((ctx (etaf-ext-context 'etaf-translate runtime)))
                                   (etaf-ext-press ctx host-id)
                                 (etaf-runtime-trigger-host-press runtime host-id)))))
      (unless (plist-get props :pointer)
        (setq props (plist-put props :pointer 'hand))))
    (etaf-node 'text props (list text))))

(defun etaf-translate--build-run-nodes (runtime unit translated default-ink preserve-color-p)
  "Return list of ETAF `text' View nodes for UNIT's TRANSLATED markup."
  (mapcar (lambda (seg)
            (etaf-translate--segment-node runtime seg default-ink preserve-color-p))
          (etaf-translate-decode-runs translated unit)))

;;;; Companion and override spec builders

(defun etaf-translate--effective-mode (_runtime unit mode)
  "Resolve effective presentation MODE for UNIT.
Constrained single-line Hosts degrade to `replace' so text never clips."
  (if (etaf-translate-unit-constrained-p unit) 'replace mode))

(defun etaf-translate--styled-companion-view (runtime unit translated style palette)
  "Build the editorial companion ETAF View for UNIT's TRANSLATED text in STYLE."
  (let* ((kind (etaf-translate-unit-kind unit))
         (ink (plist-get palette :ink))
         (muted (plist-get palette :muted))
         (bar (plist-get palette :bar))
         (quote-bar (plist-get palette :quote-bar))
         (tint (plist-get palette :tint))
         (quote-bg (or (plist-get palette :quote-bg) tint))
         (text-ink (if (or (eq style 'muted)
                           (memq kind '(heading quote-paragraph)))
                       muted
                     ink))
         (nodes (etaf-translate--build-run-nodes runtime unit translated text-ink nil))
         (box-props
          (cond
           ;; Headings always render as clean calm subtitles without noisy bars/slabs.
           ((eq kind 'heading)
            (list :width 'stretch :wrap-mode 'word :color muted))
           ;; Quote paragraphs stay inside the single quote rail without doubled bars.
           ((eq kind 'quote-paragraph)
            (list :width 'stretch :wrap-mode 'word
                  :background-color quote-bg
                  :border-left (list '(px 2) 'solid quote-bar)
                  :padding-left '(ch 1)
                  :color muted))
           ((eq style 'left-bar)
            (list :width 'stretch :wrap-mode 'word
                  :border-left (list '(px 2) 'solid bar)
                  :padding-left '(ch 1)
                  :color ink))
           ((eq style 'tinted)
            (list :width 'stretch :wrap-mode 'word
                  :background-color tint
                  :padding '((lh 0) (ch 1))
                  :color ink))
           (t
            (list :width 'stretch :wrap-mode 'word
                  :color muted)))))
    (etaf-node 'box box-props nodes)))

(defun etaf-translate-build-presentation (runtime unit translated mode style)
  "Build a `(HOST-ID . SPEC)' presentation entry for UNIT's TRANSLATED text.
MODE is `bilingual-stacked' or `replace'; STYLE is `left-bar', `muted' or
`tinted'."
  (let* ((host-id (etaf-translate-unit-host-id unit))
         (host-tag (etaf-translate-unit-host-tag unit))
         (eff-mode (etaf-translate--effective-mode runtime unit mode))
         (palette (etaf-translate--palette runtime)))
    (cons
     host-id
     (pcase eff-mode
       ('replace
        (let ((orig-tip (etaf-translate-unit-source-text unit)))
          (if (eq host-tag 'text)
              (let ((plain (mapconcat (lambda (seg) (or (plist-get seg :text) ""))
                                      (etaf-translate-decode-runs translated unit)
                                      "")))
                (list :mode 'override
                      :text (if (and (stringp orig-tip) (not (string-empty-p orig-tip)))
                                (propertize plain 'help-echo orig-tip)
                              plain)))
            (let ((nodes
                   (mapcar
                    (lambda (seg)
                      (let* ((orig (plist-get seg :props))
                             (seg2 (if (and orig-tip (not (plist-get orig :help-echo)))
                                       (plist-put (copy-sequence seg)
                                                  :props
                                                  (plist-put (copy-sequence orig)
                                                             :help-echo orig-tip))
                                     seg)))
                        (etaf-translate--segment-node runtime seg2 nil t)))
                    (etaf-translate-decode-runs translated unit))))
              (list :mode 'override
                    :view (etaf-node 'fragment nil nodes))))))
       (_
        (let ((view (etaf-translate--styled-companion-view
                     runtime unit translated style palette)))
          (if (eq host-tag 'box)
              (list :mode 'companion-inside :view view)
            (list :mode 'companion-after :view view))))))))

(defun etaf-translate-build-loading-presentation (runtime unit mode)
  "Build a subtle loading presentation entry for UNIT, or nil in replace mode.
Replace mode keeps original text readable while waiting for the backend."
  (let ((eff-mode (etaf-translate--effective-mode runtime unit mode)))
    (unless (eq eff-mode 'replace)
      (let* ((palette (etaf-translate--palette runtime))
             (host-id (etaf-translate-unit-host-id unit))
             (host-tag (etaf-translate-unit-host-tag unit))
             (view (etaf-node 'box
                              (list :width 'stretch :color (plist-get palette :muted))
                              (list (etaf-node 'text nil (list "译文中…"))))))
        (cons host-id
              (list :mode (if (eq host-tag 'box) 'companion-inside 'companion-after)
                    :view view))))))

(defun etaf-translate-build-error-presentation (runtime unit mode message on-retry)
  "Build a subtle retryable error presentation entry for UNIT, or nil."
  (let ((eff-mode (etaf-translate--effective-mode runtime unit mode)))
    (unless (eq eff-mode 'replace)
      (let* ((palette (etaf-translate--palette runtime))
             (host-id (etaf-translate-unit-host-id unit))
             (host-tag (etaf-translate-unit-host-tag unit))
             (view (etaf-node
                    'box
                    (list :width 'stretch :color (plist-get palette :danger))
                    (list (etaf-node
                           'text
                           (list :role 'button :tab-index 0 :pointer 'hand
                                 :help-echo (or message "翻译失败，点击重试")
                                 :on-press on-retry)
                           (list "翻译失败（点击重试）"))))))
        (cons host-id
              (list :mode (if (eq host-tag 'box) 'companion-inside 'companion-after)
                    :view view))))))

(provide 'etaf-translate-render)
;;; etaf-translate-render.el ends here
