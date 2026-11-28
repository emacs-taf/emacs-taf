;;; etaf-symbol-card.el --- Show the symbol at point in a floating card -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This example uses `etaf-posframe' to show a card for the symbol at point.
;; The card is a passive panel: it never takes focus and hides before the next
;; command, so it reads as a preview, not as a mode.
;;
;; Load it from this repository and bind one key:
;;
;;   (add-to-list 'load-path "/path/to/etaf-posframe/examples")
;;   (require 'etaf-symbol-card)
;;   (global-set-key (kbd "C-c h") #'etaf-symbol-card-show)
;;
;; `etaf-symbol-card-show' on a visible card hides it instead of stacking a
;; second one.  It reports a message when point is not on a symbol.

;;; Code:

(require 'project)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-posframe)

(defgroup etaf-symbol-card nil
  "Floating card for the symbol at point."
  :group 'etaf
  :prefix "etaf-symbol-card-")

(defconst etaf-symbol-card--width 64
  "Card width in columns.")

(defun etaf-symbol-card--kind (symbol)
  "Return the display kind of SYMBOL as (LABEL . BADGE-VARIANT)."
  (cond ((macrop symbol) (cons "宏" 'warning))
        ((fboundp symbol) (cons "函数" 'info))
        ((boundp symbol) (cons "变量" 'success))
        ((facep symbol) (cons "面" 'neutral))
        ((keymapp (ignore-errors (symbol-value symbol))) (cons "键图" 'neutral))
        (t (cons "符号" 'neutral))))

(defun etaf-symbol-card--documentation (symbol)
  "Return SYMBOL's full documentation string, or nil."
  (or (and (fboundp symbol) (documentation symbol t))
      (and (boundp symbol)
           (documentation-property symbol 'variable-documentation t))))

(defun etaf-symbol-card--summary (symbol)
  "Return the first documentation paragraph of SYMBOL, or nil."
  (let ((doc (etaf-symbol-card--documentation symbol)))
    (when (stringp doc)
      (let* ((end (or (string-match "\n\n" doc) (length doc)))
             (text (substring doc 0 end)))
        (setq text (replace-regexp-in-string "[ \t\n]+" " " text))
        (when (> (length text) 240)
          (setq text (concat (substring text 0 239) "…")))
        (string-trim text)))))

(defun etaf-symbol-card--definition-file (symbol)
  "Return the file that defines SYMBOL now.
`symbol-file' can report an `use-package' autoload in the user's init
instead of the library, so the newest `load-history' defun wins."
  (let ((hits
         (seq-filter
          (lambda (entry)
            (and (consp entry) (stringp (car entry))
                 (seq-some (lambda (item)
                             (and (consp item)
                                  (memq (car item)
                                        '(defun defmacro cl-defun cl-defmacro
                                          defsubst))
                                  (eq symbol (cdr item))))
                           (cdr entry))))
          load-history)))
    (let ((file (or (car (car (last hits)))
                    (symbol-file symbol 'defun)
                    (symbol-file symbol))))
      (if (and (stringp file) (string-match-p "\\.elc\\'" file)
               (file-exists-p (concat (file-name-sans-extension file) ".el")))
          (concat (file-name-sans-extension file) ".el")
        file))))

(defun etaf-symbol-card--display-file (file)
  "Return FILE relative to the project root when it is inside one."
  (let ((root (ignore-errors (project-root (project-current)))))
    (if (and root (string-prefix-p root file))
        (file-relative-name file root)
      (file-name-nondirectory file))))

(defun etaf-symbol-card--location (symbol)
  "Return SYMBOL's definition as FILE:LINE, or nil."
  (let ((file (etaf-symbol-card--definition-file symbol)))
    (when (and (stringp file) (file-exists-p file))
      (condition-case nil
          (let* ((hit (find-function-search-for-symbol symbol nil file))
                 (line (with-current-buffer (car hit)
                         (line-number-at-pos (cdr hit)))))
            (format "%s:%d" (etaf-symbol-card--display-file file) line))
        (error (etaf-symbol-card--display-file file))))))

(defun etaf-symbol-card--usages (symbol)
  "Return (COUNT . ROWS) for calls of SYMBOL in the current buffer.
ROWS hold up to three call sites as (:line N :text CALL)."
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (let ((pattern (rx (or "(" "#'") (literal (symbol-name symbol)) symbol-end))
            (count 0)
            rows)
        (while (and (< count 999) (re-search-forward pattern nil t))
          (setq count (1+ count))
          (when (< (length rows) 3)
            (let* ((beg (match-beginning 0))
                   (text (string-trim
                          (buffer-substring-no-properties beg (line-end-position)))))
              (when (> (length text) 46)
                (setq text (concat (substring text 0 45) "…")))
              (when (> (cl-count ?\( text) (cl-count ?\) text))
                (setq text (concat text " …")))
              (push (list :line (line-number-at-pos beg) :text text) rows))))
        (cons count (nreverse rows))))))

(defun etaf-symbol-card--keys (symbol)
  "Return up to two key bindings of SYMBOL, or nil."
  (when (commandp symbol)
    (ignore-errors
      (let ((keys (where-is-internal symbol nil t)))
        (when keys
          (seq-take (mapcar #'key-description keys) 2))))))

(defun etaf-symbol-card--data (symbol)
  "Return everything the card shows for SYMBOL."
  (let* ((kind (etaf-symbol-card--kind symbol))
         (usages (etaf-symbol-card--usages symbol)))
    (list :name (symbol-name symbol)
          :kind (car kind)
          :variant (cdr kind)
          :summary (etaf-symbol-card--summary symbol)
          :usages (cdr usages)
          :count (car usages)
          :location (etaf-symbol-card--location symbol)
          :keys (etaf-symbol-card--keys symbol))))

(defun etaf-symbol-card--usages-view (count rows)
  "Return the usage section for COUNT calls at ROWS."
  (etaf-view
   (column :item-gap '(lh 0) :width 'stretch
           (etaf-divider)
           (flex :column-gap '(ch 2) :align-items 'center
                 (etaf-label :text "本文件用法" :variant 'strong)
                 (etaf-label :text (format "%d 处" count) :variant 'muted))
           (expr (mapcar #'etaf-symbol-card--usage-row rows)))))

(defun etaf-symbol-card--usage-row (row)
  "Return one call-site row for ROW."
  (etaf-view
   (flex :column-gap '(ch 2) :align-items 'flex-start
         (box :width '(ch 5) :flex-shrink 0
              (etaf-label :text (number-to-string (plist-get row :line))
                          :variant 'muted))
         (etaf-label :text (plist-get row :text) :wrap-mode 'word))))

(defun etaf-symbol-card--view (data)
  "Return the card View for DATA."
  (let ((name (plist-get data :name))
        (kind (plist-get data :kind))
        (variant (plist-get data :variant))
        (summary (plist-get data :summary))
        (usages (plist-get data :usages))
        (count (plist-get data :count))
        (location (plist-get data :location))
        (keys (plist-get data :keys)))
    (etaf-view
     (etaf-card
      (column :item-gap '(lh 0) :width 'stretch
              (flex :justify-content 'space-between :align-items 'center
                    (flex :column-gap '(ch 1) :align-items 'center
                          (etaf-badge :text kind :variant variant)
                          (etaf-label :text name :variant 'strong))
                    (expr (when keys
                            (etaf-view (etaf-kbd :keys keys)))))
              (expr (when summary
                      (etaf-view
                       (etaf-label :text summary :wrap-mode 'word))))
              (expr (when (> count 0)
                      (etaf-symbol-card--usages-view count usages)))
              (etaf-divider)
              (flex :justify-content 'space-between :align-items 'center
                    (etaf-label :text (or location "—") :variant 'muted)
                    (flex :column-gap '(ch 1) :align-items 'center
                          (etaf-kbd :keys '("M-."))
                          (etaf-label :text "跳转" :variant 'muted)
                          (etaf-kbd :keys '("M-?"))
                          (etaf-label :text "引用" :variant 'muted))))))))

;;;###autoload
(defun etaf-symbol-card-show ()
  "Show the card for the symbol at point, or hide a visible card.
The card is passive: it does not take focus and the next command hides it."
  (interactive)
  (etaf-posframe-toggle
   (lambda ()
     (let ((symbol (symbol-at-point)))
       (unless symbol
         (user-error "Point is not on a symbol"))
       (etaf-symbol-card--view (etaf-symbol-card--data symbol))))
   :key 'symbol-card
   :width etaf-symbol-card--width
   :at 'point
   :auto-hide t))

;;;###autoload
(define-minor-mode etaf-symbol-card-mode
  "Bind \\[etaf-symbol-card-show] to show the symbol card."
  :global t
  :lighter nil
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c h") #'etaf-symbol-card-show)
            (define-key map (kbd "C-c H") #'etaf-symbol-card-show)
            map))

(provide 'etaf-symbol-card)
;;; etaf-symbol-card.el ends here
