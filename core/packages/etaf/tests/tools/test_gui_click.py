"""Native click tool contract: explicit targets and complete input events."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeClickTests(unittest.TestCase):
    def run_lisp(self, body):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'click.el'
            script.write_text(''';;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'emacs-gui-verifier)
(setq print-circle t print-level 6 print-length 20)
(save-window-excursion
  (with-temp-buffer
    (insert "Target\\n")
    (set-window-buffer (selected-window) (current-buffer))
    (let ((window (selected-window)) (events nil) (lookups 0)
          (visible t) (graphic t) (frame-visible t) (wrong-point nil) (wrong-window nil))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _frame) graphic))
                ((symbol-function 'frame-visible-p) (lambda (&optional _frame) frame-visible))
                ((symbol-function 'redisplay) (lambda (&rest _args) nil))
                ((symbol-function 'posn-at-point)
                 (lambda (position target)
                   (cl-incf lookups)
                   (list (or wrong-window target)
                         (or wrong-point (if (markerp position) (marker-position position) position))
                         '(0 . 0) 0)))
                ((symbol-function 'pos-visible-in-window-p)
                 (lambda (&rest _args) visible))
                ((symbol-function 'execute-kbd-macro)
                 (lambda (input &rest _args) (push input events))))
''' + body + '''
))))
''', encoding='utf-8')
            result = subprocess.run(
                [os.environ.get('EMACS', 'emacs'), '-Q', '--batch',
                 '-L', str(ROOT / 'scripts'), '-l', str(script)],
                text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_integer_and_marker_send_one_complete_click(self):
        self.run_lisp('''
(dolist (position (list 1 (copy-marker 2)))
  (unless (eq t (etaf-gui-verifier-native-click position)) (error "Missing success")))
(unless (= (length events) 2) (error "Wrong click count"))
(dolist (input events)
  (unless (equal (mapcar #'car (append input nil)) '(down-mouse-1 mouse-1))
    (error "Incomplete native click"))
  (unless (equal (cadr (aref input 0)) (cadr (aref input 1)))
    (error "Down and up have different targets")))
''')

    def test_invalid_positions_never_resolve_or_dispatch(self):
        self.run_lisp('''
(let ((other (generate-new-buffer " *other-click*")) (dead (make-marker)))
  (unwind-protect
      (dolist (position (list nil 0 (1+ (point-max)) "1" dead
                             (with-current-buffer other (point-marker))))
        (let ((rejected (condition-case nil
                            (progn (etaf-gui-verifier-native-click position) nil)
                          (error t))))
          (unless rejected (error "Invalid position was accepted"))))
    (kill-buffer other)))
(unless (and (null events) (= 0 lookups)) (error "Invalid input reached native targeting"))
''')

    def test_wrong_window_or_buffer_and_terminal_are_rejected(self):
        self.run_lisp('''
(let ((other (split-window-below)))
  (unless (condition-case nil (progn (etaf-gui-verifier-native-click 1 other) nil)
            (error t))
    (error "Unselected window accepted")))
(with-temp-buffer
  (unless (condition-case nil (progn (etaf-gui-verifier-native-click 1 window) nil)
            (error t))
    (error "Wrong buffer accepted")))
(setq graphic nil)
(unless (condition-case nil (progn (etaf-gui-verifier-native-click 1) nil) (error t))
  (error "Terminal accepted"))
(setq graphic t frame-visible nil)
(unless (condition-case nil (progn (etaf-gui-verifier-native-click 1) nil) (error t))
  (error "Hidden frame accepted"))
(unless (and (null events) (= 0 lookups)) (error "Wrong target sent events"))
''')

    def test_invisible_offscreen_and_mismatched_hits_never_dispatch(self):
        self.run_lisp('''
(dolist (kind '(offscreen invisible wrong-point wrong-window))
  (setq visible (not (eq kind 'offscreen))
        wrong-point (and (eq kind 'wrong-point) 2)
        wrong-window (and (eq kind 'wrong-window) (split-window-below)))
  (put-text-property 1 2 'invisible (eq kind 'invisible))
  (unless (condition-case nil (progn (etaf-gui-verifier-native-click 1) nil) (error t))
    (error "Invisible or mismatched hit accepted")))
(unless (null events) (error "Rejected hit sent a partial click"))
''')


if __name__ == '__main__':
    unittest.main()
