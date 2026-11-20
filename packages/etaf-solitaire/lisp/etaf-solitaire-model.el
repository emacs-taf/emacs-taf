;;; -*- lexical-binding: t; -*-
;;; etaf-solitaire-model.el --- Decode public Klondike observations for presentation

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-gamekit)

(defun etaf-solitaire--table (observation)
  "Project OBSERVATION's public OpenSpiel 2.0.2 text, without inferring rules."
  (when-let* ((text (plist-get observation :observation)))
    (let (waste foundations targets sources rows reading)
      (dolist (line (split-string text "\n"))
        (cond
         ((string-match "\\`WASTE *: *\\(.*\\)" line)
          (setq waste (split-string (match-string 1 line) " +" t)))
         ((string-match "\\`FOUNDATIONS *: *\\(.*\\)" line)
          (setq foundations (split-string (match-string 1 line) " +" t)))
         ((string-prefix-p "TABLEAUS" line) (setq reading t))
         ((string-match "\\`TARGETS *: *\\(.*\\)" line)
          (setq targets (split-string (match-string 1 line) " +" t) reading nil))
         ((string-match "\\`SOURCES *: *\\(.*\\)" line)
          (setq sources (split-string (match-string 1 line) " +" t)))
         ((and reading (not (string-empty-p (string-trim line))))
          (push (split-string line " +" t) rows))))
      (setq rows (nreverse rows))
      (unless (and (= (length foundations) 4) (= (length targets) 11))
        (error "Unsupported OpenSpiel solitaire observation"))
      (list :waste (cl-remove-if-not (lambda (card) (member card sources)) waste)
            :stock-count (length waste) :foundations foundations
            :columns (mapcar (lambda (target) (unless (equal target "🂿") (pop rows)))
                             (cl-subseq targets 0 7))
            :moves (delq nil (mapcar
                             (lambda (action)
                               (let ((parts (split-string (plist-get action :label) " ← ")))
                                 (when (= (length parts) 2)
                                   (list :id (plist-get action :id) :target (car parts) :source (cadr parts)))))
                             (plist-get observation :legal_actions)))
            :home (apply #'+ (mapcar (lambda (card)
                                      (if (> (length card) 1)
                                          (1+ (cl-position (aref card 0) "A23456789TJQK")) 0)) foundations))))))

(defun etaf-solitaire--suit (card)
  "Return the display suit of public CARD text."
  (when (and card (> (length card) 0))
    (pcase (aref card (1- (length card))) (?♠ 'spades) (?♥ 'hearts) (?♣ 'clubs) (?♦ 'diamonds))))

(defun etaf-solitaire--rank (card)
  "Return the visible rank of CARD, or nil for a back/empty pile."
  (when (and (etaf-solitaire--suit card) (> (length card) 1))
    (let ((rank (substring card 0 -1))) (if (equal rank "T") "10" rank))))

(defun etaf-solitaire--send (session selected operation &optional arguments)
  "Send OPERATION and clear caller-owned SELECTED when the instance is ready."
  (when (eq (etaf-gamekit-status session) 'ready)
    (etaf-gamekit-action session operation arguments)
    (setf (etaf-value selected) nil)))

(defun etaf-solitaire--press (session selected table card)
  "Choose CARD or submit the native legal move matching the current selection."
  (let* ((moves (plist-get table :moves))
         (move (cl-find-if (lambda (item) (and (equal (plist-get item :source) (etaf-value selected))
                                              (equal (plist-get item :target) card))) moves)))
    (cond (move (etaf-solitaire--send session selected "act" (list :action (plist-get move :id))))
          ((equal card (etaf-value selected)) (setf (etaf-value selected) nil))
          ((cl-find card moves :key (lambda (item) (plist-get item :source)) :test #'equal)
           (setf (etaf-value selected) card)))))

(defun etaf-solitaire--snapshot (session selected operation)
  "Choose an explicit snapshot file for OPERATION."
  (let ((file (etaf-call-with-input
               (lambda () (read-file-name (if (equal operation "save") "Save deal: " "Load deal: ")
                                          nil nil (equal operation "load") "solitaire.json")))))
    (when file (etaf-solitaire--send session selected operation (list :path (expand-file-name file))))))

(provide 'etaf-solitaire-model)
;;; etaf-solitaire-model.el ends here
