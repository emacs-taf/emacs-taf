.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PYTHON ?= python3
LOAD_PATH = -L . -L lisp -L ../etaf -L ../etaf-ui -L ../ebox -L ../ecss -L ../ekp
# etaf-posframe is checked against the window manager it wraps; that is an
# installed ELPA package, not a workspace checkout.
POSFRAME_DIR ?= $(lastword $(sort $(wildcard $(HOME)/.emacs.d/elpa/posframe-*)))
SOURCES = lisp/etaf-manual-book.el lisp/etaf-manual-generate.el
SOURCES += lisp/etaf-manual-reader-theme.el lisp/etaf-manual-reader-style.el
SOURCES += lisp/etaf-manual-reader-model.el lisp/etaf-manual-reader-article.el
SOURCES += lisp/etaf-manual-reader-views.el lisp/etaf-manual-reader.el
SOURCES += etaf-manual.el scripts/check-book.el site/scripts/export-site.el

.PHONY: all compile book-check coverage tool-check check clean

all: check

compile:
	rm -f *.elc lisp/*.elc scripts/*.elc tests/*.elc site/scripts/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(progn (require 'cl-lib) (setq load-prefer-newer t byte-compile-error-on-warn t))" \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

# Validate book/ against the sibling provider checkouts; see docs/manual.md.
# The panels part documents etaf-posframe, which needs Posframe: an ELPA
# package, not a workspace checkout, so the book cannot be checked without it.
book-check:
	@test -n "$(POSFRAME_DIR)" || { echo "book-check needs Posframe: install it, or set POSFRAME_DIR=/path/to/posframe"; exit 2; }
	$(EMACS) -Q --batch -L . -L lisp -L $(POSFRAME_DIR) --eval '(setq load-prefer-newer t)' -l scripts/check-book.el

# Print how many interfaces of each package already have a definition entry.
coverage:
	@test -n "$(POSFRAME_DIR)" || { echo "coverage needs Posframe: install it, or set POSFRAME_DIR=/path/to/posframe"; exit 2; }
	$(EMACS) -Q --batch -L . -L lisp -L $(POSFRAME_DIR) --eval '(setq load-prefer-newer t)' -l scripts/check-book.el --coverage

tool-check:
	EMACS="$(EMACS)" $(PYTHON) -m unittest discover -s tests/tools -p 'test_*.py'

check: structure-check compile book-check acceptance api-check tool-check

clean:
	rm -f *.elc lisp/*.elc scripts/*.elc tests/*.elc site/scripts/*.elc

.PHONY: structure-check setup-hooks
structure-check:
	python3 ../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	git config --local core.hooksPath .githooks

# Build the manual site from book/ into site/dist/.
.PHONY: site
site:
	cd site && npm run build

# Build and publish the manual site to https://etaf.top.
.PHONY: site-publish
site-publish:
	$(PYTHON) site/scripts/publish.py $(PUBLISH_ARGS)

.PHONY: acceptance
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	$(EMACS) -Q --batch -L . -L lisp $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../ebox -L ../etaf -L ../etaf-ui -L ../etaf-db -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance
