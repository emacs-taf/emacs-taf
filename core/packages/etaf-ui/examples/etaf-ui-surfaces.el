;;; etaf-ui-surfaces.el --- Compose menus, popovers and dialogs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run M-x etaf-ui-surfaces-open after loading etaf-ui. The application owns
;; the preferences and status; UI owns the floating presentation.

;;; Code:
(require 'etaf-ui)

(etaf-define-component etaf-ui-surfaces-example ()
  :bindings ((dialog (etaf-ref nil))
             (help (etaf-ref nil))
             (notifications (etaf-ref t))
             (name (etaf-ref "工作空间"))
             (status (etaf-ref "准备就绪")))
  :view
  (column :width 'stretch :height '(vh 90) :padding '((lh 2) (ch 4))
          :item-gap '(lh 1) :background-color "#F1F5F9" :color "#0F172A"
    (etaf-label :text "工作空间" :variant 'heading)
    (text "菜单、浮层和模态框使用相同的组件、状态与宿主布局。")
    (row :item-gap '(ch 2)
      (etaf-dropdown-menu
       :label "操作"
       :items '((:key rename :label "编辑偏好")
                (:key duplicate :label "复制工作空间")
                (:key delete :label "删除（不可用）" :disabled t))
       :on-select (lambda (key)
                    (pcase key
                      ('rename (setf (etaf-value dialog) t))
                      ('duplicate (setf (etaf-value status) "已复制工作空间")))))
      (etaf-button :label "偏好设置" :on-press (lambda () (setf (etaf-value dialog) t)))
      (etaf-button :id "surfaces-help" :label "帮助" :variant 'ghost
                   :on-press (lambda () (setf (etaf-value help) (not (etaf-value help))))))
    (etaf-panel :title "概览" :width '(ch 68)
      (etaf-label :text name :variant 'strong)
      (text (expr (if (etaf-value notifications) "通知已开启" "通知已关闭")))
      (etaf-label :text status :variant 'muted))
    (etaf-popover :open help :anchor "surfaces-help" :title "快捷操作" :width '(ch 40)
                  :on-close (lambda () (setf (etaf-value help) nil))
      (text "Tab / 方向键选择，Enter 确认。")
      (text "Escape 关闭浮层并返回入口。")
      (etaf-button :label "知道了" :on-press (lambda () (setf (etaf-value help) nil))))
    (etaf-dialog :open dialog :title "偏好设置" :width '(ch 48) :close-label "关闭"
                 :on-close (lambda () (setf (etaf-value dialog) nil))
      (etaf-text-input :bind name :label "名称")
      (etaf-checkbox :bind notifications :label "接收通知")
      (slot :name 'footer
        (etaf-button :label "完成"
                     :on-press (lambda ()
                                 (setf (etaf-value dialog) nil
                                       (etaf-value status) "偏好已更新")))))))

;;;###autoload
(defun etaf-ui-surfaces-open ()
  "Mount the floating component example and return its buffer.
Interactive calls display it. Reopening resets example state."
  (interactive)
  (let ((buffer (etaf-mount "*ETAF UI Surfaces*" (etaf-view (etaf-ui-surfaces-example)))))
    (when (called-interactively-p 'interactive) (switch-to-buffer buffer))
    buffer))

(provide 'etaf-ui-surfaces)
;;; etaf-ui-surfaces.el ends here
