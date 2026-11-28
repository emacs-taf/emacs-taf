;;; etaf-web-adapter.el --- Site-archetype adapter registry and page controllers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Registry for Tier 2 site-archetype adapters and the uniform Page Controller
;; abstraction shared across Tier 1 (reader), Tier 2 (archetype adapters) and
;; Tier 3 (live dynamic projection).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-web-compile)

(defvar etaf-web--adapter-registry nil
  "List of registered Tier 2 site-archetype adapter plists.")

(defun etaf-web--adapter-sort (adapters)
  "Return a copy of ADAPTERS sorted by ascending `:priority', then `:name'."
  (sort (copy-sequence adapters)
        (lambda (a b)
          (let ((pa (or (plist-get a :priority) 100))
                (pb (or (plist-get b :priority) 100)))
            (if (= pa pb)
                (string< (symbol-name (plist-get a :name))
                         (symbol-name (plist-get b :name)))
              (< pa pb))))))

(cl-defun etaf-web-register-adapter (&key name label priority match-url match-html open)
  "Register or replace a Tier 2 site-archetype adapter.
NAME is a non-nil symbol uniquely identifying the adapter.
LABEL is a short display string (default NAME) shown in the status slot.
PRIORITY is an integer controlling matching order (default 100, smaller first).
MATCH-URL is an optional function `(URL)' for Stage 0 URL matching.
MATCH-HTML is an optional function `(URL HEADERS HTML DOM)' for Stage 1
response/DOM fingerprint matching.  Supply at least MATCH-URL or MATCH-HTML.
OPEN is a required function `(CONTEXT)' called when the adapter claims a page;
CONTEXT carries `:url', `:headers', `:html', `:dom', `:navigate', `:on-stage',
`:on-ready' and `:on-error', and OPEN may return a canceller or `fallback'.
Signals `etaf-web-error' on invalid arguments."
  (unless (and (symbolp name) name (not (keywordp name)))
    (signal 'etaf-web-error '("Adapter :name must be a non-nil symbol")))
  (unless (or (functionp match-url) (functionp match-html))
    (signal 'etaf-web-error '("Adapter requires :match-url or :match-html function")))
  (unless (functionp open)
    (signal 'etaf-web-error '("Adapter requires an :open function")))
  (when (and priority (not (integerp priority)))
    (signal 'etaf-web-error '("Adapter :priority must be an integer")))
  (let* ((disp-label (if (and (stringp label) (not (string-blank-p label)))
                         (string-trim label)
                       (symbol-name name)))
         (entry (list :name name
                      :label disp-label
                      :priority (or priority 100)
                      :match-url match-url
                      :match-html match-html
                      :open open))
         (filtered (cl-remove-if (lambda (it) (eq (plist-get it :name) name))
                                 etaf-web--adapter-registry)))
    (setq etaf-web--adapter-registry
          (etaf-web--adapter-sort (cons entry filtered)))
    name))

(defun etaf-web-unregister-adapter (name)
  "Remove the registered Tier 2 adapter named NAME.
Returns non-nil when an adapter was removed, or nil if NAME was not registered."
  (let ((before (length etaf-web--adapter-registry)))
    (setq etaf-web--adapter-registry
          (cl-remove-if (lambda (it) (eq (plist-get it :name) name))
                        etaf-web--adapter-registry))
    (< (length etaf-web--adapter-registry) before)))

(defun etaf-web-adapters ()
  "Return a detached list of registered Tier 2 adapter descriptors.
Each descriptor is a plist `(:name SYMBOL :label STRING :priority INTEGER)'
ordered by ascending priority."
  (mapcar (lambda (it)
            (list :name (plist-get it :name)
                  :label (plist-get it :label)
                  :priority (plist-get it :priority)))
          etaf-web--adapter-registry))

(defun etaf-web--adapter-find-url (url)
  "Return the highest-priority registered adapter whose `:match-url' matches URL."
  (cl-find-if
   (lambda (adapter)
     (when-let* ((pred (plist-get adapter :match-url)))
       (condition-case nil
           (funcall pred url)
         (error nil))))
   etaf-web--adapter-registry))

(defun etaf-web--adapter-find-html (url headers html dom)
  "Return the highest-priority adapter whose `:match-html' matches the response."
  (cl-find-if
   (lambda (adapter)
     (when-let* ((pred (plist-get adapter :match-html)))
       (condition-case nil
           (funcall pred url headers html dom)
         (error nil))))
   etaf-web--adapter-registry))

;;; ---------------------------------------------------------------------------
;;; Uniform Page Controller contract (T1 / T2 / T3)
;;; ---------------------------------------------------------------------------

(defun etaf-web--make-page-controller (&rest spec)
  "Construct a uniform Page Controller plist from SPEC for the browser shell.
Required keys: `:tier' (`t1', `t2' or `t3') and `:render' `(lambda (ctx) ...)'.
Optional keys: `:adapter', `:mode-label', `:url', `:title', `:keys',
`:own-scroll', `:outline', `:on-reload', `:on-theme', `:on-width',
`:on-headings', `:dispose' and `:md-session'."
  (let ((tier (plist-get spec :tier))
        (render (plist-get spec :render)))
    (unless (memq tier '(t1 t2 t3))
      (signal 'etaf-web-error (list (format "Invalid page tier: %S" tier))))
    (unless (functionp render)
      (signal 'etaf-web-error '("Page controller requires a :render function")))
    (list :tier tier
          :adapter (plist-get spec :adapter)
          :mode-label (plist-get spec :mode-label)
          :url (plist-get spec :url)
          :title (plist-get spec :title)
          :render render
          :keys (plist-get spec :keys)
          :own-scroll (and (plist-get spec :own-scroll) t)
          :outline (plist-get spec :outline)
          :on-reload (plist-get spec :on-reload)
          :on-theme (plist-get spec :on-theme)
          :on-width (plist-get spec :on-width)
          :on-headings (plist-get spec :on-headings)
          :dispose (plist-get spec :dispose)
          :md-session (plist-get spec :md-session))))

(defun etaf-web--dispose-page-controller (page)
  "Safely invoke PAGE controller's `:dispose' hook if present."
  (when-let* ((fn (and (listp page) (plist-get page :dispose))))
    (when (functionp fn)
      (funcall fn))))

(provide 'etaf-web-adapter)
;;; etaf-web-adapter.el ends here
