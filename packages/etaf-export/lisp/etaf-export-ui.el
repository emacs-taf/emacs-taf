;;; etaf-export-ui.el --- Interactive export popup panel for etaf-export -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Renders a compact floating `etaf-ext' settings popup allowing the user to
;; configure pagination (`a4', `letter', `single'), theme (`current', `light')
;; and page numbers before exporting the active ETAF page to PDF or SVG.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)
(require 'etaf-export-snapshot)
(require 'etaf-export-pdf)

(defvar etaf-export-default-page-mode)
(defvar etaf-export-default-theme)
(defvar etaf-export-page-numbers)

(declare-function etaf-export-pdf "etaf-export")
(declare-function etaf-export-svg "etaf-export")

(defun etaf-export--ctx-options (ctx)
  "Return current export options plist stored on CTX."
  (or (etaf-ext-ctx-state ctx)
      (let ((init (list :page-mode etaf-export-default-page-mode
                        :theme etaf-export-default-theme
                        :page-numbers etaf-export-page-numbers)))
        (etaf-ext-ctx-set-state ctx init)
        init)))

(defun etaf-export--set-opt (ctx key value)
  "Update option KEY to VALUE on CTX and refresh the export popup."
  (let ((opts (copy-sequence (etaf-export--ctx-options ctx))))
    (setq opts (plist-put opts key value))
    (etaf-ext-ctx-set-state ctx opts)
    (etaf-ext-show-popup ctx (etaf-export--popup-view ctx)
                         :title "导出页面为 PDF / SVG" :width 56 :height 17)))

(defun etaf-export--option-pill (ctx key value label current-val theme)
  "Render a single selectable option pill for KEY = VALUE."
  (let* ((selected (equal current-val value))
         (accent (plist-get theme :ext-accent))
         (panel (plist-get theme :ext-panel))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (border (plist-get theme :ext-border))
         (sel-bg (etaf-ui-color-mix panel accent 0.22))
         (sel-fg (etaf-ui-color-legible accent sel-bg 4.5)))
    (if selected
        ;; Active/selected pill keeps calm resting presentation (no hover/hand)
        (etaf-node
         'box (list :background-color sel-bg
                    :border (list '(px 1) 'solid accent)
                    :padding '((lh 0) (ch 1)))
         (list (etaf-node 'text (list :color sel-fg :font-weight 'bold)
                          (list label))))
      (etaf-view
       (etaf-button
        :label label :variant 'ghost :pointer 'hand
        :color muted
        :border (list '(px 1) 'solid border)
        :padding '((lh 0) (ch 1))
        :hover-style (list :color fg :background-color (etaf-ui-color-mix panel fg 0.08))
        :on-press (lambda () (etaf-export--set-opt ctx key value)))))))

(defun etaf-export--run-from-popup (ctx format)
  "Hide popup, prompt for output path and run FORMAT (`pdf' or `svg') export."
  (let* ((rt (etaf-ext-ctx-runtime ctx))
         (opts (etaf-export--ctx-options ctx))
         (ext (if (eq format 'svg) "svg" "pdf"))
         (snap (etaf-export--snapshot-runtime rt :theme (plist-get opts :theme)))
         (default-path (etaf-export--default-filename snap ext)))
    (etaf-ext-hide-popup ctx)
    (let* ((dest (read-file-name (format "导出 %s 到: " (upcase ext))
                                 (file-name-directory default-path)
                                 default-path nil
                                 (file-name-nondirectory default-path)))
           (res (if (eq format 'svg)
                    (etaf-export-svg dest
                                     :runtime rt
                                     :page-mode (plist-get opts :page-mode)
                                     :theme (plist-get opts :theme)
                                     :page-numbers (plist-get opts :page-numbers))
                  (etaf-export-pdf dest
                                   :runtime rt
                                   :page-mode (plist-get opts :page-mode)
                                   :theme (plist-get opts :theme)
                                   :page-numbers (plist-get opts :page-numbers)))))
      (etaf-ext-notify ctx (format "已导出 %s（%d 页）" (upcase ext) (plist-get res :pages))
                       :detail (plist-get res :file))
      res)))

(defun etaf-export--popup-view (ctx)
  "Build floating popup View for configuring and running page export on CTX."
  (let* ((rt (etaf-ext-ctx-runtime ctx))
         (meta (etaf-ext-ctx-meta ctx))
         (buf (etaf-runtime-buffer rt))
         (title (truncate-string-to-width (or (plist-get meta :title) (buffer-name buf)) 42 nil nil "…"))
         (opts (etaf-export--ctx-options ctx))
         (page-mode (plist-get opts :page-mode))
         (theme-opt (plist-get opts :theme))
         (page-nums (plist-get opts :page-numbers))
         (doctor (etaf-export--doctor-report))
         (rsvg-ok (plist-get doctor :ready))
         (theme (etaf-ext-theme))
         (bg (plist-get theme :ext-bg))
         (fg (plist-get theme :ext-fg))
         (muted (plist-get theme :ext-muted))
         (accent (plist-get theme :ext-accent))
         (border (plist-get theme :ext-border))
         (danger (or (plist-get theme :ui-danger) "#f85149")))
    (etaf-node
     'column
     (list :width 'stretch :background-color bg
           :padding '((lh 1) (ch 2)) :item-gap '(lh 1))
     (delq
      nil
      (list
       (etaf-node 'column '(:item-gap (lh 0))
                  (list
                   (etaf-node 'text (list :color fg :font-weight 'bold)
                              (list (format "目标页面: %s" title)))
                   (etaf-node 'text (list :color muted)
                              (list "零浏览器真矢量导出（文字可选、Mermaid/MathJax 矢量保留）"))))
       (etaf-node
        'flex '(:align-items center :gap ((lh 0) (ch 1)))
        (list
         (etaf-node 'text (list :color fg :font-weight 'bold) '("分页模式:"))
         (etaf-export--option-pill ctx :page-mode 'a4 "A4 分页" page-mode theme)
         (etaf-export--option-pill ctx :page-mode 'letter "Letter" page-mode theme)
         (etaf-export--option-pill ctx :page-mode 'single "单页长图" page-mode theme)))
       (etaf-node
        'flex '(:align-items center :gap ((lh 0) (ch 1)))
        (list
         (etaf-node 'text (list :color fg :font-weight 'bold) '("导出配色:"))
         (etaf-export--option-pill ctx :theme 'current "跟随当前主题" theme-opt theme)
         (etaf-export--option-pill ctx :theme 'light "强制亮色打印" theme-opt theme)))
       (etaf-node
        'flex '(:align-items center :gap ((lh 0) (ch 1)))
        (list
         (etaf-node 'text (list :color fg :font-weight 'bold) '("页脚页码:"))
         (etaf-export--option-pill ctx :page-numbers t "显示页码" page-nums theme)
         (etaf-export--option-pill ctx :page-numbers nil "隐藏页码" page-nums theme)))
       (unless rsvg-ok
         (etaf-node 'text (list :color danger)
                    '("未检测到 rsvg-convert：请先安装 librsvg 以启用 PDF 导出（SVG 仍可用）")))
       (etaf-node
        'flex (list :justify-content 'flex-end :align-items 'center
                    :gap '((lh 0) (ch 1))
                    :border-top (list '(px 1) 'solid border)
                    :padding '((lh 1) (ch 0)))
        (list
         (etaf-view
          (etaf-button
           :label "导出 SVG" :variant 'outline :pointer 'hand
           :on-press (lambda () (etaf-export--run-from-popup ctx 'svg))))
         (etaf-view
          (etaf-button
           :label "导出 PDF" :variant 'primary :pointer 'hand
           :disabled (not rsvg-ok)
           :color (etaf-ui-color-legible "#ffffff" accent 4.5)
           :on-press (lambda () (etaf-export--run-from-popup ctx 'pdf)))))))))))

(provide 'etaf-export-ui)
;;; etaf-export-ui.el ends here
