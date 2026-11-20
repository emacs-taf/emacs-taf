;;; generate-entities.el --- Regenerate the entity table -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The preview translates org entity names (`\alpha') to their Unicode
;; spelling without loading Org.  The table is generated from Org's own
;; `org-entities' so the two stay identical, and checked in as data.
;;
;;   emacs -Q --batch -l scripts/generate-entities.el \
;;     --eval '(etaf-org-preview-generate-entities "lisp/etaf-org-preview-entities.el")'
;;
;; Regenerate after an Org upgrade and run the parser tests.

;;; Code:

(require 'org-entities)

(defun etaf-org-preview--entity-pairs ()
  "Return (NAME . UNICODE) for every entity with a Unicode spelling."
  (let (pairs)
    (dolist (entry org-entities)
      (when (and (listp entry) (stringp (nth 6 entry)) (not (string-empty-p (nth 6 entry))))
        (push (cons (nth 0 entry) (nth 6 entry)) pairs)))
    (sort (nreverse pairs)
          (lambda (a b) (string< (car a) (car b))))))

(defun etaf-org-preview-generate-entities (file)
  "Write the entity table to FILE."
  (let ((pairs (etaf-org-preview--entity-pairs)))
    (with-temp-file file
      (insert ";;; etaf-org-preview-entities.el --- Entity table -*- lexical-binding: t; -*-\n\n")
      (insert ";; SPDX-License-Identifier: GPL-3.0-or-later\n\n")
      (insert ";;; Commentary:\n;;\n")
      (insert ";; Generated from `org-entities' by scripts/generate-entities.el.\n")
      (insert ";; Do not edit by hand.  Each entry maps an Org entity name to its\n")
      (insert ";; Unicode spelling, so the preview can render entities without loading\n")
      (insert ";; Org.  A name Org dropped keeps rendering literally.\n\n")
      (insert ";;; Code:\n\n")
      (insert "(defconst etaf-org-preview-entities\n  '(")
      (let ((first t))
        (dolist (pair pairs)
          (insert (format "%s(%S . %S)"
                          (if first "" "\n    ")
                          (car pair) (cdr pair)))
          (setq first nil)))
      (insert ")\n  \"Entity names and their Unicode spelling.\")\n\n")
      (insert "(defconst etaf-org-preview-subscripts\n  '((?0 . \"₀\") (?1 . \"₁\") (?2 . \"₂\") (?3 . \"₃\") (?4 . \"₄\")\n")
      (insert "    (?5 . \"₅\") (?6 . \"₆\") (?7 . \"₇\") (?8 . \"₈\") (?9 . \"₉\")\n")
      (insert "    (?+ . \"₊\") (?- . \"₋\") (?= . \"₌\") (?\\( . \"₍\") (?\\) . \"₎\")\n")
      (insert "    (?a . \"ₐ\") (?e . \"ₑ\") (?o . \"ₒ\") (?x . \"ₓ\") (?h . \"ₕ\")\n")
      (insert "    (?k . \"ₖ\") (?l . \"ₗ\") (?m . \"ₘ\") (?n . \"ₙ\") (?p . \"ₚ\")\n")
      (insert "    (?s . \"ₛ\") (?t . \"ₜ\") (?i . \"ᵢ\") (?j . \"ⱼ\") (?r . \"ᵣ\")\n")
      (insert "    (?u . \"ᵤ\") (?v . \"ᵥ\"))\n  \"Characters with a Unicode subscript spelling.\")\n\n")
      (insert "(defconst etaf-org-preview-superscripts\n  '((?0 . \"⁰\") (?1 . \"¹\") (?2 . \"²\") (?3 . \"³\") (?4 . \"⁴\")\n")
      (insert "    (?5 . \"⁵\") (?6 . \"⁶\") (?7 . \"⁷\") (?8 . \"⁸\") (?9 . \"⁹\")\n")
      (insert "    (?+ . \"⁺\") (?- . \"⁻\") (?= . \"⁼\") (?\\( . \"⁽\") (?\\) . \"⁾\")\n")
      (insert "    (?n . \"ⁿ\") (?i . \"ⁱ\") (?a . \"ᵃ\") (?b . \"ᵇ\") (?c . \"ᶜ\")\n")
      (insert "    (?d . \"ᵈ\") (?e . \"ᵉ\") (?f . \"ᶠ\") (?g . \"ᵍ\") (?h . \"ʰ\")\n")
      (insert "    (?j . \"ʲ\") (?k . \"ᵏ\") (?l . \"ˡ\") (?m . \"ᵐ\") (?o . \"ᵒ\")\n")
      (insert "    (?p . \"ᵖ\") (?r . \"ʳ\") (?s . \"ˢ\") (?t . \"ᵗ\") (?u . \"ᵘ\")\n")
      (insert "    (?v . \"ᵛ\") (?w . \"ʷ\") (?x . \"ˣ\") (?y . \"ʸ\") (?z . \"ᶻ\"))\n  \"Characters with a Unicode superscript spelling.\")\n\n")
      (insert "(provide 'etaf-org-preview-entities)\n;;; etaf-org-preview-entities.el ends here\n"))))

(provide 'generate-entities)
;;; generate-entities.el ends here
