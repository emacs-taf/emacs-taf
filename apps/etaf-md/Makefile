.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= $(if $(wildcard ../../core/packages/etaf),../../core/packages,$(if $(wildcard ../etaf/etaf.el),..,../..))
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-media -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/etaf-doc -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss
SOURCES = $(wildcard lisp/*.el)
SOURCES += etaf-md.el
SOURCES += $(wildcard examples/*.el)
SOURCES += scripts/etaf-md-gui-probe.el
SOURCES += benchmarks/performance-scenarios.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test benchmark

compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-md))' --eval '(princ "etaf-md load OK\n")'

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
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C apps/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el

benchmark:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l benchmarks/render-large-document.el

test: acceptance

clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc
