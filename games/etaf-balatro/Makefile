.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PROVIDER_ROOT ?= $(if $(wildcard ../../core/packages/etaf),../../core/packages,$(if $(wildcard ../etaf/etaf.el),..,../..))
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf/scripts
SOURCES = lisp/etaf-balatro-theme.el lisp/etaf-balatro-engine.el lisp/etaf-balatro-model.el lisp/etaf-balatro-views.el lisp/etaf-balatro-app.el etaf-balatro.el scripts/etaf-balatro-gui-scenarios.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-balatro))' --eval '(princ "etaf-balatro load OK\n")'

check: structure-check compile acceptance api-check

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C games/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

acceptance:
	@test -f ../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C games/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C games/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el

test: acceptance

clean:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc
