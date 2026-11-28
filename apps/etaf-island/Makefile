.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
POSFRAME_DIR ?= $(lastword $(sort $(wildcard $(HOME)/.emacs.d/elpa/posframe-*)))
PROVIDER_ROOT ?= $(if $(wildcard ../../core/packages/etaf),../../core/packages,$(if $(wildcard ../etaf/etaf.el),..,../..))
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf-posframe -L $(PROVIDER_ROOT)/etaf/scripts $(if $(POSFRAME_DIR),-L $(POSFRAME_DIR))
SOURCES = lisp/etaf-island-theme.el lisp/etaf-island-sensors.el lisp/etaf-island-model.el lisp/etaf-island-views.el lisp/etaf-island-app.el etaf-island.el scripts/etaf-island-gui-scenarios.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-island))' --eval '(princ "etaf-island load OK\n")'

check: structure-check compile acceptance api-check

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C apps/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

acceptance:
	@test -f ../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C apps/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	EMACSLOADPATH="$(POSFRAME_DIR):$(EMACSLOADPATH)" \
		python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C apps/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el

test: acceptance

clean:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc
