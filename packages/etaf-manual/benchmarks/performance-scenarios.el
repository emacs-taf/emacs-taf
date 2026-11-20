;;; performance-scenarios.el --- Manual reader interaction workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; Adapters for the workspace performance driver (scripts/performance.py).
;; The reader scenarios measure the documented interactions of the mounted
;; manual reader through the page Host's `:keys' and the example run
;; control: moving between sections, between chapters, and running the first
;; runnable example in place.  The driver times the key dispatch or event
;; through the buffer write and the forced redisplay.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-manual)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-manual-benchmark--viewport (mode)
  "Return the (WIDTH-COLUMNS . HEIGHT-LINES) fixture viewport for MODE.
GUI takes the selected window's own metrics; batch fixes the same 150x44
window so both modes measure a comparable amount of visible text."
  (if (eq mode 'gui)
      (cons (max 20 (/ (window-body-width (selected-window) t)
                       (frame-char-width)))
            (window-body-height (selected-window)))
    (cons 150 44)))

(defun etaf-manual-benchmark--position (buffer)
  "Return the footer reading-position label of BUFFER, or nil."
  (with-current-buffer buffer
    (let ((text (substring-no-properties (buffer-string)))
          (start 0) label)
      (while (string-match "\\(第 [0-9]+/[0-9]+ 章\\(?: · 第 [0-9]+/[0-9]+ 节\\)?\\)"
                           text start)
        (setq label (match-string 1 text)
              start (match-end 0)))
      label)))

(defun etaf-manual-benchmark--reader (chapter keys mode)
  "Prepare the mounted reader at CHAPTER and press KEYS.
MODE selects the batch or GUI viewport; the driver shows the buffer before
`:ready' resolves the actual window metrics."
  (let ((buffer (etaf-manual-open chapter))
        (ready nil) before)
    (unless (etaf-runtime-for-buffer buffer)
      (error "The manual reader fixture did not mount"))
    (list
     :buffer buffer
     :ready
     (lambda ()
       (unless ready
         (let ((viewport (etaf-manual-benchmark--viewport mode)))
           (etaf-runtime-refit (etaf-runtime-for-buffer buffer)
                               (* (car viewport) (frame-char-width))
                               (cdr viewport)))
         (setq ready t))
       t)
     :prepare
     (lambda () (setq before (etaf-manual-benchmark--position buffer)))
     :invoke
     (lambda (_sample)
       (with-current-buffer buffer
         (execute-kbd-macro (kbd keys))))
     :verify
     (lambda ()
       (let ((after (etaf-manual-benchmark--position buffer)))
         (cond ((not (and (buffer-live-p buffer)
                          (etaf-runtime-for-buffer buffer)))
                "The reader runtime disappeared")
               ((equal before after)
                (format "The reading position did not move from %s" before))
               (t t))))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (etaf-manual-close)))))))

(defun etaf-manual-benchmark--example (mode)
  "Prepare the mounted reader at MODE and run its first runnable example.
The example identifier is fixed by the introduction chapter."
  (let ((buffer (etaf-manual-open 'introduction))
        (id "introduction-1") (ready nil))
    (unless (etaf-runtime-for-buffer buffer)
      (error "The manual reader fixture did not mount"))
    (list
     :buffer buffer
     :ready
     (lambda ()
       (unless ready
         (let ((viewport (etaf-manual-benchmark--viewport mode)))
           (etaf-runtime-refit (etaf-runtime-for-buffer buffer)
                               (* (car viewport) (frame-char-width))
                               (cdr viewport))
           ;; The article publishes only its visible lines; bring the
           ;; example card into view so its preview reaches the buffer.
           (etaf-scroll-into-view (etaf-runtime-for-buffer buffer)
                                  (intern (format "etaf-manual-example-run-%s" id))
                                  'start)
           (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))
         (setq ready t))
       t)
     :invoke
     (lambda (_sample)
       (let ((runtime (etaf-runtime-for-buffer buffer)))
         (etaf-dispatch-event runtime
                              (intern (format "etaf-manual-example-run-%s" id))
                              'press)
         (etaf-runtime-flush runtime)))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let ((text (substring-no-properties (buffer-string))))
           (cond ((not (etaf-runtime-for-buffer buffer))
                  "The reader runtime disappeared")
                 ((string-match-p "尚未运行" text)
                  "The example still shows its unstarted placeholder")
                 ((not (string-match-p "Hello" text))
                  "The example preview did not render its View")
                 (t t)))))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (etaf-manual-close)))))))

(taf-benchmark-register
 "manual.reader.section"
 :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree
 :budget-ms 100
 :description "Next section in the mounted manual reader via the page Host `:keys'"
 :setup (lambda (mode) (etaf-manual-benchmark--reader 'introduction "n" mode)))

(taf-benchmark-register
 "manual.reader.chapter"
 :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree
 :budget-ms 100
 :description "Next chapter in the mounted manual reader via the page Host `:keys'"
 :setup (lambda (mode) (etaf-manual-benchmark--reader 'introduction "]" mode)))

(taf-benchmark-register
 "manual.reader.chapter-large"
 :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree
 :budget-ms 100
 :description "Next chapter into the largest chapter, the style property reference"
 :setup (lambda (mode) (etaf-manual-benchmark--reader 'values "]" mode)))

(taf-benchmark-register
 "manual.reader.example"
 :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree
 :budget-ms 100
 :description "Run the first introduction example in place in the manual reader"
 :setup (lambda (mode) (etaf-manual-benchmark--example mode)))

;;; performance-scenarios.el ends here
