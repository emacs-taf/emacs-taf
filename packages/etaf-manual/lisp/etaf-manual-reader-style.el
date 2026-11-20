;;; etaf-manual-reader-style.el --- Layout and surface design of the manual reader -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The design system of the manual reader: one place that names every
;; surface, spacing and text rank the document application uses.  Views
;; compose these builders instead of styling themselves, so the header, the
;; navigation column, the article cards and the example viewers share one
;; look and a palette or spacing change lands in a single place.
;;
;; A rendering environment (`env') is a plist with `:palette' (semantic color
;; alist), `:theme' (palette name), `:viewport' (READER, WIDTH-IN-CHARACTERS
;; or nil when unknown) and `:reader' (the session).  The markdown renderer
;; receives the same environment, so document text and application chrome
;; read the same colors.
;;
;; Line grid: every row the reader publishes has the frame's standard line
;; height.  The header, the navigation column and the article share buffer
;; lines, so one taller row (a scaled heading, a smaller label, a fallback
;; glyph from another font) would push the navigation column out of rhythm
;; and change the article's pixel height as it scrolls, which shifts the
;; footer.  Hierarchy therefore uses weight, color, surfaces and spacing,
;; never font size, and icons come from `etaf-ui-icon', whose metrics never
;; exceed the standard row.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)

(declare-function etaf-manual-reader--nodes
                  "etaf-manual-reader-model" (session &optional id))
(declare-function etaf-manual-reader--sidebar-columns
                  "etaf-manual-reader-model" (session))
(declare-function etaf-manual-reader--outline-columns
                  "etaf-manual-reader-model" (session))

(defconst etaf-manual-reader--measure-max 96
  "Widest reading measure of the article column, in character cells.")

(defconst etaf-manual-reader--measure-min 44
  "Narrowest reading measure that still keeps prose readable.")

(defconst etaf-manual-reader--sidebar-fallback-width 38
  "Navigation column width used when ENV carries no reader session.")

(defconst etaf-manual-reader--wide-threshold 104
  "Frame width, in character cells, that keeps the navigation column beside
the article; narrower frames collapse it into the overview screen.")

(defun etaf-manual-reader--sidebar-width (env)
  "Return ENV's navigation column width in character cells."
  (if-let* ((reader (plist-get env :reader)))
      (etaf-manual-reader--sidebar-columns reader)
    etaf-manual-reader--sidebar-fallback-width))

(defun etaf-manual-reader--outline-width (env)
  "Return ENV's on-this-page column width in character cells."
  (if-let* ((reader (plist-get env :reader)))
      (etaf-manual-reader--outline-columns reader)
    30))

(defconst etaf-manual-reader--compact-threshold 88
  "Frame width, in character cells, below which the chrome drops details.
The brand, the breadcrumb, the language switch and the key hints all shorten
so nothing is truncated on a narrow frame.")

(defconst etaf-manual-reader--gutter '(lh 1)
  "Vertical padding inside panels and chrome bars, in line heights.")

(defconst etaf-manual-reader--inline-pad '((lh 0) (ch 2))
  "Horizontal padding inside panels and chrome bars.")

(defconst etaf-manual-reader--card-pad '((lh 1) (ch 2))
  "Padding inside document cards and callouts.")

;;;; Colors

(defun etaf-manual-reader--color (env key)
  "Return ENV's semantic color for KEY."
  (or (cdr (assq key (plist-get env :palette)))
      (signal 'etaf-manual-error
              (list (format "Unknown manual reader color: %S" key)))))

;;;; Surfaces

(defun etaf-manual-reader--border (env)
  "Return ENV's one-pixel rule."
  (list '(px 1) 'solid (etaf-manual-reader--color env :border)))

(defun etaf-manual-reader--page (env children &optional height keys)
  "Wrap CHILDREN in the reader page surface: full size, page colors.
The page is a flex column so the body owns the space left between the header
and the footer; a plain column would not distribute that remainder.  HEIGHT
overrides the page height; the reader passes one row less than the reported
viewport, because a graphical frame can reserve its last text row for the
window chrome while the runtime still counts it.  KEYS is the page Host's
`:keys' table, which makes the reader keys visible to the ETAF key help."
  (etaf-node 'flex
             (list :flex-direction 'column
                   :align-items 'stretch
                   :gap '((lh 0) (ch 0))
                   :width '(vw 100)
                   :height (or height '(vh 100))
                   :background-color (etaf-manual-reader--color env :bg)
                   :color (etaf-manual-reader--color env :ink)
                   :aria-label "手册阅读器"
                   :keys keys
                   :overflow 'hidden)
             children))

(defun etaf-manual-reader--surface (env children &optional props)
  "Return a bordered panel containing CHILDREN.
PROPS override the panel's own style."
  (etaf-node 'box
             (append (list :width 'stretch
                           :background-color (etaf-manual-reader--color env :panel)
                           :border (etaf-manual-reader--border env)
                           :padding etaf-manual-reader--card-pad
                           :box-sizing 'border-box)
                     props)
             children))

(defun etaf-manual-reader--chrome (env children &optional props)
  "Return a chrome bar (header or footer) containing CHILDREN."
  (etaf-node 'flex
             (append (list :width 'stretch
                           :flex-direction 'row
                           :padding etaf-manual-reader--inline-pad
                           :column-gap '(ch 2)
                           :align-items 'center
                           :background-color (etaf-manual-reader--color env :panel))
                     props)
             children))

(defun etaf-manual-reader--spacer (&optional lines)
  "Return an empty spacer LINES lines tall."
  (etaf-node 'box (list :height (list 'lh (or lines 1))) nil))

(defun etaf-manual-reader--hover (env &optional key)
  "Return ENV's pointer-hover paint for interactive surfaces.
KEY names the palette color (default `:hover'), so one rail, row or card
highlight matches every other interactive surface in the reader."
  (list :background-color (etaf-manual-reader--color env (or key :hover))))

;;;; Text ranks

(defun etaf-manual-reader--icon (env name &optional color)
  "Return the line-safe icon NAME in ENV's COLOR key (default `:muted')."
  (etaf-node 'etaf-ui-icon
             (list :name name :set 'svg
                   :color (etaf-manual-reader--color env (or color :muted)))
             nil))

(defun etaf-manual-reader--brand (env text)
  "Return the application brand: the book icon and TEXT."
  (etaf-node 'row
             (list :item-gap '(ch 1) :cross-align 'center)
             (list (etaf-manual-reader--icon env 'file :accent)
                   (etaf-node 'text
                              (list :font-weight 'bold
                                    :color (etaf-manual-reader--color env :ink))
                              (list text)))))

(defun etaf-manual-reader--chapter-heading (env number title)
  "Return the chapter title: NUMBER in the accent color, then TITLE.
The title keeps the body font size; weight, color and the rule beneath it
carry its rank, so it stays on the line grid."
  (etaf-node 'row
             (list :width 'stretch :item-gap '(ch 2)
                   :box-sizing 'border-box
                   :border-bottom (list '(px 1) 'solid
                                        (etaf-manual-reader--color env :heading-rule)))
             (append
              (when number
                (list (etaf-node 'text
                                 (list :font-weight 'bold
                                       :color (etaf-manual-reader--color env :accent))
                                 (list (format "%s" number)))))
              (list (etaf-node 'text
                               (list :font-weight 'bold
                                     :color (etaf-manual-reader--color env :heading))
                               (list title))))))

(defun etaf-manual-reader--label (env text)
  "Return secondary label TEXT in the muted color."
  (etaf-node 'text
             (list :color (etaf-manual-reader--color env :muted))
             (list text)))

(defun etaf-manual-reader--mono (env text &optional props)
  "Return TEXT in the frame's fixed-pitch family with PROPS."
  (etaf-node 'text
             (append (list :font-family (etaf-manual-reader--mono-family)
                           :color (etaf-manual-reader--color env :ink))
                     props)
             (list text)))

(defun etaf-manual-reader--mono-family ()
  "Return the family of the frame's fixed-pitch font, or nil."
  (let ((family (face-attribute 'fixed-pitch :family nil t)))
    (and (stringp family) (not (string-empty-p family)) family)))

;;;; Measurement

(defun etaf-manual-reader--viewport-columns (env)
  "Return ENV's frame width in character cells, or nil when unknown."
  (plist-get env :viewport))

(defun etaf-manual-reader--wide-p (env)
  "Return non-nil when ENV frames the two-column layout."
  (let ((columns (etaf-manual-reader--viewport-columns env)))
    (or (null columns)
        (>= columns etaf-manual-reader--wide-threshold))))

(defun etaf-manual-reader--compact-p (env)
  "Return non-nil when ENV asks for the compact chrome."
  (let ((columns (etaf-manual-reader--viewport-columns env)))
    (and columns (< columns etaf-manual-reader--compact-threshold))))

(defun etaf-manual-reader--outline-p (env)
  "Return non-nil when ENV frames the on-this-page column."
  (let ((columns (etaf-manual-reader--viewport-columns env)))
    (or (null columns)
        (>= columns (+ (etaf-manual-reader--sidebar-width env)
                       (etaf-manual-reader--outline-width env)
                       etaf-manual-reader--measure-min 6)))))

(defun etaf-manual-reader--measure (env)
  "Return the article measure in character cells for ENV."
  (let* ((columns (etaf-manual-reader--viewport-columns env))
         (sidebar (if (etaf-manual-reader--wide-p env)
                      (etaf-manual-reader--sidebar-width env)
                    0))
         (outline (if (etaf-manual-reader--outline-p env)
                      (etaf-manual-reader--outline-width env)
                    0))
         ;; Each draggable divider costs one extra column of slack.
         (resizers (cond ((zerop sidebar) 0)
                         ((zerop outline) 1)
                         (t 2)))
         (available (if columns
                        (- columns sidebar outline resizers 6)
                      etaf-manual-reader--measure-max)))
    (max etaf-manual-reader--measure-min
         (min etaf-manual-reader--measure-max available))))

;;;; Shared small pieces

(defun etaf-manual-reader--key-hints (env hints)
  "Return one line of key HINTS: each key in ink, its label muted.
HINTS is a list of (KEYS . LABEL) where KEYS is the text of the key."
  (etaf-node 'row
             (list :item-gap '(ch 2) :cross-align 'center)
             (mapcar (lambda (hint)
                       (etaf-node 'row
                                  (list :item-gap '(ch 1))
                                  (list (etaf-node 'text
                                                   (list :font-weight 'bold
                                                         :color (etaf-manual-reader--color env :ink))
                                                   (list (car hint)))
                                        (etaf-manual-reader--label env (cdr hint)))))
                     hints)))

(defun etaf-manual-reader--state-line (env text &optional tone)
  "Return a one-line state TEXT tinted with semantic TONE."
  (etaf-node 'text
             (list :color (etaf-manual-reader--color env (or tone :muted)))
             (list text)))

(provide 'etaf-manual-reader-style)
;;; etaf-manual-reader-style.el ends here
