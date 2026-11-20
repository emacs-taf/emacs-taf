;;; etaf-slides-tests.el --- Acceptance tests for etaf-slides -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour tests.  Every scenario drives the application through the
;; interfaces declared in `etaf-slides.el'.  Rendering scenarios mount a real
;; Runtime in a batch Emacs and read the visible buffer back, so they assert
;; what an audience sees instead of internal parse structures.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-slides)

(defconst etaf-slides-tests--deck "\
---
title: 测试放映
theme: light
---

# 封面标题

副标题一行

---

## 要点页

- 第一个要点
- 第二个要点

::: notes
这一页的讲稿
:::

---

## 结束

谢谢。
"
  "A three slide deck with front matter and one notes block.")

(defun etaf-slides-tests--mount (session)
  "Mount SESSION in a fresh buffer and return that buffer."
  (let ((buffer (generate-new-buffer " *etaf-slides-test*")))
    (etaf-mount buffer (etaf-slides-view session)
                '(:viewport-width 1200 :viewport-height 34))
    buffer))

(defmacro etaf-slides-tests--with-mount (session &rest body)
  "Mount SESSION, run BODY in its buffer, and always kill the buffer."
  (declare (indent 1) (debug t))
  `(let ((buffer (etaf-slides-tests--mount ,session)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun etaf-slides-tests--text (buffer)
  "Return BUFFER's visible text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

;;; Deck model

(ert-deftest etaf-slides-tests-deck-splits-front-matter-and-notes ()
  "A deck's front matter, slides and notes blocks each land where they belong."
  (let* ((session (etaf-slides-create :text etaf-slides-tests--deck))
         (state (etaf-slides-state session)))
    (should (equal "测试放映" (plist-get state :title)))
    (should (= 3 (plist-get state :count)))
    (should (equal "封面标题" (plist-get state :title-of)))
    (etaf-slides-goto session 1)
    (should (equal "这一页的讲稿"
                   (plist-get (etaf-slides-state session) :notes)))
    (should (equal "要点页" (plist-get (etaf-slides-state session) :title-of)))))

(ert-deftest etaf-slides-tests-layout-marks-cover-and-content ()
  "A heading with a subtitle is a cover and a heading with a list is content."
  (let ((session (etaf-slides-create :text etaf-slides-tests--deck)))
    (should (eq 'cover (plist-get (etaf-slides-state session) :layout)))
    (etaf-slides-goto session 1)
    (should (eq 'content (plist-get (etaf-slides-state session) :layout)))
    (etaf-slides-goto session 2)
    (should (eq 'cover (plist-get (etaf-slides-state session) :layout)))))

(ert-deftest etaf-slides-tests-invalid-decks-signal-an-error ()
  "A missing file and a deck without slides are reported as slide errors."
  (should-error (etaf-slides-create :file "/nonexistent/deck.markdown")
                :type 'etaf-slides-error)
  (should-error (etaf-slides-create :text "   \n\n") :type 'etaf-slides-error))

;;; Navigation

(ert-deftest etaf-slides-tests-navigation-clamps-at-the-deck-edges ()
  "Moving past either end keeps the first or last slide selected."
  (let ((session (etaf-slides-create :text etaf-slides-tests--deck)))
    (should (= 0 (etaf-slides-previous session)))
    (should (= 0 (plist-get (etaf-slides-state session) :index)))
    (should (= 2 (etaf-slides-next session 9)))
    (should (= 2 (plist-get (etaf-slides-state session) :index)))
    (should (= 1 (etaf-slides-goto session 1)))
    (should (= 0 (etaf-slides-goto session -4)))
    (should (= 2 (etaf-slides-goto session 42)))))

(ert-deftest etaf-slides-tests-theme-cycle-visits-light-dark-and-auto ()
  "Cycling the theme walks light, dark, then the frame's own appearance."
  (let ((session (etaf-slides-create :text etaf-slides-tests--deck
                                     :theme 'auto)))
    (should (eq 'light (etaf-slides-cycle-theme session)))
    (should (eq 'dark (etaf-slides-cycle-theme session)))
    (should (eq 'auto (etaf-slides-cycle-theme session)))
    (should (memq (plist-get (etaf-slides-state session) :appearance)
                  '(light dark)))))

;;; Stage geometry

(ert-deftest etaf-slides-tests-stage-keeps-the-aspect-ratio-inside-the-viewport ()
  "The stage fills the width without exceeding either budget, and clips when small."
  (let* ((stage (etaf-slides-stage 1200 40 8 17))
         (columns (plist-get stage :columns))
         (rows (plist-get stage :rows)))
    (should (<= columns 150))
    (should (<= rows 38))
    (should (> columns 100))
    (should (not (plist-get stage :clipped)))
    (let ((tiny (etaf-slides-stage 300 10 8 17)))
      (should (plist-get tiny :clipped))
      (should (= 32 (plist-get tiny :columns)))
      (should (= 10 (plist-get tiny :rows))))))

(ert-deftest etaf-slides-tests-overflow-reports-slides-over-budget ()
  "A slide whose text cannot fit the stage is reported, a short one is not."
  (let* ((bullets (mapconcat (lambda (n) (format "- 第 %d 条很长的要点" n))
                             (number-sequence 1 80) "\n"))
         (session (etaf-slides-create
                   :text (format "# 短页\n\n一行\n\n---\n\n# 长页\n\n%s\n" bullets)))
         (overflow (plist-get (etaf-slides-state session) :overflow)))
    (should (equal '(1) overflow))))

;;; Rendering

(ert-deftest etaf-slides-tests-mount-renders-the-current-slide ()
  "A mounted deck shows the current slide and repaints when the session moves."
  (let ((session (etaf-slides-create :text etaf-slides-tests--deck)))
    (etaf-slides-tests--with-mount session
      (should (string-match-p "封面标题" (etaf-slides-tests--text (current-buffer))))
      (etaf-slides-next session)
      (should (string-match-p "要点页" (etaf-slides-tests--text (current-buffer))))
      (should (string-match-p "第一个要点" (etaf-slides-tests--text (current-buffer))))
      (should-not (string-match-p "封面标题" (etaf-slides-tests--text (current-buffer)))))))

(ert-deftest etaf-slides-tests-notes-band-follows-the-toggle ()
  "Showing the notes adds their text above the footer without leaving the clock."
  (let ((session (etaf-slides-create :text etaf-slides-tests--deck)))
    (etaf-slides-goto session 1)
    (etaf-slides-tests--with-mount session
      (should-not (string-match-p "这一页的讲稿"
                                  (etaf-slides-tests--text (current-buffer))))
      (etaf-slides-set-notes session t)
      (should (string-match-p "这一页的讲稿"
                              (etaf-slides-tests--text (current-buffer))))
      (should (string-match-p "3 / 3\\|2 / 3"
                              (etaf-slides-tests--text (current-buffer)))))))

(ert-deftest etaf-slides-tests-application-keys-advance-the-slides ()
  "The declared root keys page through the deck in a mounted application."
  (let ((session (etaf-slides-create :text etaf-slides-tests--deck)))
    (unwind-protect
        (let ((buffer (etaf-slides-open session)))
          (with-current-buffer buffer
            ;; A deck opens at presentation size so a slide reads from a room.
            (should (= etaf-slides-window-scale
                       (bound-and-true-p text-scale-mode-amount)))
            (should (string-match-p "封面标题" (etaf-slides-tests--text buffer)))
            (execute-kbd-macro (kbd "SPC"))
            (should (string-match-p "要点页" (etaf-slides-tests--text buffer)))
            (execute-kbd-macro (kbd "DEL"))
            (should (string-match-p "封面标题" (etaf-slides-tests--text buffer)))
            (execute-kbd-macro (kbd "o"))
            (should (string-match-p "全部幻灯片 · 3"
                                    (etaf-slides-tests--text buffer)))
            (execute-kbd-macro (kbd "o"))
            (should (string-match-p "封面标题" (etaf-slides-tests--text buffer)))))
      (when-let* ((buffer (get-buffer (format "*ETAF Slides: %s*"
                                              (plist-get (etaf-slides-state session)
                                                         :title)))))
        (with-current-buffer buffer (etaf-app-close))))))

(provide 'etaf-slides-tests)
;;; etaf-slides-tests.el ends here
