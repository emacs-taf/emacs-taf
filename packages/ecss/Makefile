.DEFAULT_GOAL := check
.NOTPARALLEL:
# Makefile for the ecss library.

EMACS ?= emacs
LOADPATH = -L . -L lisp -L tests
PACKAGE_LINT_LOAD_EXTRA ?=
SRC = lisp/ecss-selector.el lisp/ecss-cascade.el lisp/ecss-file.el ecss.el
TESTS = $(wildcard tests/*-tests.el)

.PHONY: compile compile-all checkdoc package-lint check clean diff-check

compile: clean
	$(EMACS) -Q --batch $(LOADPATH) \
	  --eval '(setq byte-compile-error-on-warn t byte-compile-warnings (quote (not obsolete)))' \
	  -f batch-byte-compile $(SRC)

compile-all: clean
	$(EMACS) -Q --batch $(LOADPATH) \
	  --eval '(setq byte-compile-error-on-warn t byte-compile-warnings (quote (not obsolete)))' \
	  -f batch-byte-compile $(SRC) $(TESTS)

checkdoc:
	$(EMACS) -Q --batch $(LOADPATH) \
	  --eval '(progn (require (quote cl-lib)) (require (quote checkdoc)) \
	    (cl-letf (((symbol-function (quote display-warning)) \
	               (lambda (_type message &rest _args) (error "%s" message)))) \
	      (dolist (file (quote ("lisp/ecss-selector.el" "lisp/ecss-cascade.el" "lisp/ecss-file.el" "ecss.el"))) \
	        (checkdoc-file file))))'

package-lint:
	$(EMACS) -Q --batch $(LOADPATH) $(PACKAGE_LINT_LOAD_EXTRA) \
	  --eval '(progn (require (quote package-lint)) \
	    (setq package-lint-main-file "ecss.el") \
	    (dolist (file (quote ("lisp/ecss-selector.el" "lisp/ecss-cascade.el" "lisp/ecss-file.el" "ecss.el"))) \
	      (with-current-buffer (find-file-noselect file) \
	        (let ((issues (package-lint-buffer))) \
	          (when issues (error "package-lint failed for %s: %S" file issues))))))'

diff-check:
	git diff --check

check: structure-check compile acceptance api-check

clean:
	rm -f *.elc lisp/*.elc tests/*.elc

.PHONY: structure-check setup-hooks
structure-check:
	python3 ../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	git config --local core.hooksPath .githooks

.PHONY: acceptance
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
API_PROVIDER_PATH = -L ../ekp -L ../ebox -L ../etaf -L ../etaf-ui -L ../etaf-db -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance
