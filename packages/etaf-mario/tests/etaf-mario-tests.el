;;; -*- lexical-binding: t; -*-
;;; etaf-mario-tests.el --- Public Super Mario behavior

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; These scenarios exercise the declared API only: the deterministic world,
;; its snapshot, the parsed levels, the text renderer and the doctor.  They
;; assert observable characters and state instead of comparing screenshots, so
;; a regression in the sprite art, the camera or the collision rules is
;; reported with the exact row and column that changed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf-mario)

(defun etaf-mario-test--step (world steps &optional input)
  "Advance WORLD STEPS fixed simulation steps under INPUT."
  (dotimes (_ steps)
    (etaf-mario-world-step world input)))

(defun etaf-mario-test--snapshot (world)
  "Return WORLD's snapshot plist."
  (etaf-mario-world-snapshot world))

(defun etaf-mario-test--player (world)
  "Return WORLD's player plist."
  (plist-get (etaf-mario-test--snapshot world) :player))

(defun etaf-mario-test--frame (world &optional columns rows)
  "Return WORLD's plain text frame rows at COLUMNS by ROWS."
  (let ((result (etaf-mario-render-frame world (or columns 132) (or rows 20))))
    (cons (car result) (mapcar #'substring-no-properties (cdr result)))))

(defun etaf-mario-test--row (world index &optional columns rows)
  "Return WORLD's frame row INDEX at COLUMNS by ROWS."
  (nth index (cdr (etaf-mario-test--frame world columns rows))))

(defun etaf-mario-test--level-tile (level column row)
  "Return LEVEL's tile at COLUMN and ROW from its parsed tile vector."
  (let ((width (plist-get level :width)))
    (aref (plist-get level :tiles) (+ (* row width) column))))

(defun etaf-mario-test--walk-to (world target)
  "Advance WORLD with right input until the player reaches TARGET pixels."
  (let ((limit 2000))
    (while (and (< (plist-get (etaf-mario-test--player world) :x) target)
                (> limit 0))
      (etaf-mario-world-step world '(:right t))
      (setq limit (1- limit))))
  (etaf-mario-test--player world))

(ert-deftest etaf-mario-campaign-is-healthy ()
  "Every bundled level parses and every sprite character is painted."
  (should-not (etaf-mario-doctor))
  (should (= 4 (length etaf-mario-levels)))
  (dotimes (index 4)
    (let ((level (etaf-mario-level-by-index index)))
      (should (plist-get level :name))
      (should (plist-get level :start))
      (should (plist-get level :flag))
      (should (>= (plist-get level :width) 100))
      (should (= 8 (plist-get level :height))))))

(ert-deftest etaf-mario-levels-keep-two-empty-rows-under-floating-blocks ()
  "No bundled block leaves a one-row shelf above the surface below it.
A shelf one block tall is too small for big Mario to pass under and too
small to jump through, so the parser rejects it; this scenario states the
invariant for the shipped campaign."
  (dotimes (index 4)
    (let* ((level (etaf-mario-level-by-index index))
           (width (plist-get level :width))
           (height (plist-get level :height)))
      (dotimes (column width)
        (dotimes (row height)
          (when (memq (etaf-mario-test--level-tile level column row)
                      '(brick question used))
            (let ((below (cl-loop for probe from (1+ row) below height
                                  when (memq (etaf-mario-test--level-tile
                                              level column probe)
                                             '(ground dirt brick question used
                                               pipe-tl pipe-tr pipe-l pipe-r
                                               castle bridge))
                                  return probe)))
              (when below
                ;; Zero empty rows is a step resting on a surface; two or
                ;; more is a floating shelf tall Mario can pass under.
                (should-not (= 1 (- below row 1)))))))))))

(ert-deftest etaf-mario-jump-bumps-the-block-above ()
  "Jumping under a question block turns it into a used block and pays a coin."
  (let ((world (etaf-mario-world-create 0)))
    (etaf-mario-world-step world '(:right t))
    (while (< (plist-get (etaf-mario-test--player world) :x) 124)
      (etaf-mario-world-step world '(:right t)))
    (dotimes (_ 20) (etaf-mario-world-step world nil))
    (etaf-mario-world-step world '(:jump t :jump-held t))
    (etaf-mario-test--step world 20 '(:jump-held t))
    (should (eq (etaf-mario-world-tile world 16 3) 'used))
    (should (= 1 (plist-get (etaf-mario-test--snapshot world) :coins)))))

(ert-deftest etaf-mario-bumped-coin-pop-leaves-the-world ()
  "A coin popped from a bumped block is gone after its animation."
  (let ((world (etaf-mario-world-create 0)))
    (etaf-mario-world-step world '(:right t))
    (while (< (plist-get (etaf-mario-test--player world) :x) 124)
      (etaf-mario-world-step world '(:right t)))
    (dotimes (_ 20) (etaf-mario-world-step world nil))
    (etaf-mario-world-step world '(:jump t :jump-held t))
    (etaf-mario-test--step world 20 '(:jump-held t))
    (should (cl-some (lambda (entity) (eq 'coin-pop (plist-get entity :kind)))
                     (plist-get (etaf-mario-test--snapshot world) :entities)))
    (etaf-mario-test--step world 60)
    (should-not (cl-some (lambda (entity) (eq 'coin-pop (plist-get entity :kind)))
                         (plist-get (etaf-mario-test--snapshot world) :entities)))))

(ert-deftest etaf-mario-jump-collects-a-coin-tile ()
  "A jump under a floating coin collects it and pays a coin."
  (let ((world (etaf-mario-world-create 0)))
    (etaf-mario-world-step world '(:right t))
    (while (< (plist-get (etaf-mario-test--player world) :x) 114)
      (etaf-mario-world-step world '(:right t)))
    (dotimes (_ 25) (etaf-mario-world-step world nil))
    (etaf-mario-world-step world '(:jump t :jump-held t))
    (etaf-mario-test--step world 40 '(:jump-held t))
    (should (= 1 (plist-get (etaf-mario-test--snapshot world) :coins)))
    (should (eq (etaf-mario-world-tile world 15 1) 'empty))))

(ert-deftest etaf-mario-big-mario-passes-under-a-floating-shelf ()
  "Big Mario walks beneath a row-three block run without getting stuck."
  (let* ((world (etaf-mario-world-create 0 '(:big t)))
         (player (progn (etaf-mario-test--step world 260 '(:right t))
                        (etaf-mario-test--player world))))
    (should (plist-get player :big))
    (should (> (plist-get player :x) 220))
    (should (equal 'playing (plist-get (etaf-mario-test--snapshot world) :status)))))

(ert-deftest etaf-mario-pit-ends-the-run ()
  "Walking off the first sky platform falls into the pit and starts dying."
  (let ((world (etaf-mario-world-create 2))
        (steps 0))
    (while (and (< steps 400)
                (eq 'playing (plist-get (etaf-mario-test--snapshot world) :status)))
      (etaf-mario-world-step world '(:right t))
      (setq steps (1+ steps)))
    (should (< steps 400))
    (should (eq 'dying (plist-get (etaf-mario-test--snapshot world) :status)))))

(ert-deftest etaf-mario-render-joins-adjacent-blocks ()
  "A block run draws one outer border instead of a frame around every block."
  (let* ((world (etaf-mario-world-create 0))
         (row (etaf-mario-test--row world 10 132 20)))
    ;; The lone question block keeps both of its corners.
    (should (equal "▛▀▀▜" (substring row 64 68)))
    ;; The five-block run joins into one strip: one left corner, one right.
    (should (equal (concat "▛" (make-string 18 ?▀) "▜")
                   (substring row 80 100)))
    (should-not (string-match-p "▜▛" row))))

(ert-deftest etaf-mario-render-joins-both-pipe-halves ()
  "A two-block pipe draws one rim and one pair of body edges."
  (let* ((world (etaf-mario-world-create 0))
         (top (etaf-mario-test--row world 12 132 20))
         (body (etaf-mario-test--row world 13 132 20)))
    (should (equal "╔══════╗" (substring top 120 128)))
    (should (equal "║██████║" (substring body 120 128)))
    (should-not (string-match-p "╗╔" top))))

(ert-deftest etaf-mario-render-keeps-feet-on-the-ground ()
  "The player's last sprite row sits directly on the grass row."
  (let* ((world (etaf-mario-world-create 0)))
    (etaf-mario-test--step world 3)
    (let ((feet (etaf-mario-test--row world 15 132 20))
          (ground (etaf-mario-test--row world 16 132 20)))
      (should (equal "██████" (substring feet 11 17)))
      (should (equal "▁▁▁▁" (substring ground 0 4)))
      (should-not (string-match-p "[^ ]" (substring feet 0 10))))))

(ert-deftest etaf-mario-render-aligns-enemies-on-their-platform ()
  "Enemies spawned on a sky platform stand exactly on its top edge."
  (let* ((world (etaf-mario-world-create 2))
         (feet (mapcar (lambda (entity)
                         (+ (plist-get entity :y) (plist-get entity :height)))
                       (plist-get (etaf-mario-test--snapshot world) :entities))))
    ;; Ground platform at y 48, row-two platforms at 16, row-three at 24.
    (should (member 48 feet))
    (should (member 24 feet))
    (should (member 16 feet))))

(ert-deftest etaf-mario-render-keeps-pits-as-gaps ()
  "Both ground rows are empty in a pit and the surrounding surface stays."
  (let* ((world (etaf-mario-world-create 0))
         (ground (etaf-mario-test--row world 16 600 20)))
    (should (eq 'ground (etaf-mario-world-tile world 69 6)))
    (should (eq 'empty (etaf-mario-world-tile world 70 6)))
    (should (eq 'empty (etaf-mario-world-tile world 72 7)))
    (should (eq 'ground (etaf-mario-world-tile world 73 6)))
    (should (equal "▁▁▁▁" (substring ground 276 280)))
    (should (equal (make-string 12 ?\s) (substring ground 280 292)))
    (should (equal "▁▁▁▁" (substring ground 292 296)))))

(ert-deftest etaf-mario-camera-scrolls-one-cell-at-a-time ()
  "The camera and the player's screen column change by at most one cell per step."
  (let ((world (etaf-mario-world-create 0))
        (previous-camera nil)
        (previous-screen nil)
        (steps 0))
    (dotimes (index 150)
      (etaf-mario-world-step world '(:right t))
      (when (>= index 40)
        (let* ((frame (etaf-mario-render-frame world 96 20))
               (camera (car frame))
               (player (etaf-mario-test--player world))
               (screen (floor (/ (- (plist-get player :x) (* camera 2)) 2))))
          (when previous-camera
            (should (<= (abs (- camera previous-camera)) 1))
            (should (<= (abs (- screen previous-screen)) 1))
            (setq steps (1+ steps)))
          (setq previous-camera camera
                previous-screen screen))))
    (should (> steps 50))))

(provide 'etaf-mario-tests)
;;; etaf-mario-tests.el ends here
