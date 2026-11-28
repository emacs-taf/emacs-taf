.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L tests -L ../etaf -L ../etaf-ui -L ../ebox -L ../ecss
SOURCES = lisp/etaf-ui-markdown-parse.el lisp/etaf-ui-markdown-highlight.el lisp/etaf-ui-markdown.el
SOURCES += lisp/etaf-doc-cache.el lisp/etaf-doc-qrcode.el lisp/etaf-doc-typeset.el
SOURCES += lisp/etaf-doc-assets.el lisp/etaf-doc-protocol.el lisp/etaf-doc-widgets.el
SOURCES += etaf-doc.el

.PHONY: all compile load check clean native-build native-clean structure-check setup-hooks acceptance api-check test

all: check

native-build:
	$(MAKE) -C native EMACS="$(EMACS)"

native-clean:
	$(MAKE) -C native clean

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-warnings '(not obsolete))" \
		--eval "(load-file \"etaf-doc.el\")" \
		--eval "(dolist (file '($(foreach file,$(SOURCES),\"$(file)\"))) (unless (byte-compile-file file) (error \"Compilation failed: %s\" file)))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" --eval "(require 'etaf-doc)" --eval "(princ \"ETAF Doc load OK\\n\")"

structure-check:
	@test -f ../../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

acceptance:
	@test -f ../../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	@test -f ../../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ebox -L ../etaf -L ../etaf-ui

check: structure-check compile acceptance api-check

test: acceptance

clean:
	rm -f *.elc lisp/*.elc tests/*.elc
