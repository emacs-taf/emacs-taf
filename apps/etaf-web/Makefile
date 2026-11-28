.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= $(if $(wildcard ../../core/packages/etaf),../../core/packages,$(if $(wildcard ../etaf/etaf.el),..,../..))
LOAD_PATH = -L . -L lisp -L tests -L ../etaf-md -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-media -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/etaf-doc -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss
SOURCES = $(wildcard lisp/*.el)
SOURCES += etaf-web.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test corpus-check corpus-diff corpus-audit corpus-benchmark

compile:
	rm -f *.elc lisp/*.elc tests/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-web))' --eval '(princ "etaf-web load OK\n")'

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

test: acceptance

corpus-check:
	python3 scripts/corpus.py --emacs "$(EMACS)" check-fixtures

corpus-diff:
	python3 scripts/corpus.py --emacs "$(EMACS)" diff --show-diff

corpus-audit:
	python3 scripts/corpus.py --emacs "$(EMACS)" audit-cache

corpus-benchmark:
	python3 scripts/corpus.py --emacs "$(EMACS)" benchmark

clean:
	rm -f *.elc lisp/*.elc tests/*.elc
