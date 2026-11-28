;;; etaf-web-router.el --- Deterministic tiered routing and site fingerprinting -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Deterministic Stage 0 (URL + saved site preference) and Stage 1 (HTTP
;; response header + HTML DOM fingerprint) routing across rendering tiers:
;; T1 (static reader compilation), T2 (site-archetype adapters), and T3 (live
;; dynamic projection).

;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'subr-x)
(require 'etaf-web-compile)
(require 'etaf-web-cache)
(require 'etaf-web-adapter)

(defconst etaf-web--valid-modes '(auto reader adapter live)
  "Supported user-selectable rendering mode symbols.")

(defun etaf-web--header-value (headers name)
  "Return HTTP header value for NAME from lowercased HEADERS alist, or nil."
  (when (and (listp headers) (stringp name))
    (cdr (assoc (downcase name) headers))))

(defun etaf-web--meta-generator (dom)
  "Return the first `<meta name=\"generator\">' content string from DOM, or nil."
  (when dom
    (etaf-web--meta-content dom 'name '("generator"))))

(defun etaf-web--meta-generators (dom)
  "Return all non-empty `<meta name=\"generator\">' content strings from DOM."
  (when dom
    (cl-loop for meta in (etaf-web--find-all
                          dom (lambda (n) (eq (dom-tag n) 'meta)))
             for key = (etaf-web--attr meta 'name)
             for val = (etaf-web--attr meta 'content)
             when (and key val
                       (equal (downcase (string-trim key)) "generator")
                       (not (string-empty-p (string-trim val))))
             collect (string-trim (etaf-web--collapse-ws val)))))

(defun etaf-web--effective-mode (url &optional explicit-mode)
  "Resolve effective rendering mode for URL given optional EXPLICIT-MODE.
When EXPLICIT-MODE is nil or `auto', consults the persisted per-host preference."
  (cond
   ((and explicit-mode (memq explicit-mode '(reader adapter live)))
    explicit-mode)
   (t
    (let* ((host (car (etaf-web--url-parts url))))
      (etaf-web--site-pref-get host)))))

(defun etaf-web--route-url (url &optional explicit-mode)
  "Stage 0 routing decision for URL before issuing an HTTP request.
Returns a plist `(:mode MODE :tier TIER-OR-NIL :adapter ADAPTER-OR-NIL)'.
When MODE is `reader', Stage 0 forces T1 immediately without running adapters.
When MODE is `auto' or `adapter', checks registered URL-level adapters."
  (let ((mode (etaf-web--effective-mode url explicit-mode)))
    (pcase mode
      ('reader
       (list :mode 'reader :tier 't1 :adapter nil))
      ('live
       (list :mode 'live :tier 't3 :adapter nil))
      (_
       (if-let* ((adapter (etaf-web--adapter-find-url url)))
           (list :mode mode :tier 't2 :adapter adapter)
         (list :mode mode :tier nil :adapter nil))))))

(defun etaf-web--route-html (url headers html &optional explicit-mode)
  "Stage 1 routing decision after decoding HTML for URL with HEADERS.
Returns `(:mode MODE :tier TIER :adapter ADAPTER-OR-NIL :dom DOM-OR-NIL)'.
Avoids parsing HTML when no `:match-html' adapters are registered or when
EXPLICIT-MODE resolves to `reader'."
  (let ((mode (etaf-web--effective-mode url explicit-mode)))
    (cond
     ((eq mode 'reader)
      (list :mode 'reader :tier 't1 :adapter nil :dom nil))
     ((not (cl-some (lambda (a) (plist-get a :match-html))
                    etaf-web--adapter-registry))
      (list :mode mode :tier (if (eq mode 'live) 't3 't1) :adapter nil :dom nil))
     (t
      (let* ((dom (condition-case nil
                      (etaf-web--parse-html html)
                    (error nil)))
             (adapter (etaf-web--adapter-find-html url headers html dom)))
        (if adapter
            (list :mode mode :tier 't2 :adapter adapter :dom dom)
          (list :mode mode :tier (if (eq mode 'live) 't3 't1)
                :adapter nil :dom dom)))))))

(provide 'etaf-web-router)
;;; etaf-web-router.el ends here
