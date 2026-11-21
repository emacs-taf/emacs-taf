.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs

# Providers live beside the application (standalone) or two levels up (workspace).
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= ..

LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui \
            -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss

SOURCES = $(wildcard lisp/*.el) etaf-telega.el

.PHONY: compile load test check structure-check clean acceptance api-check setup-hooks

compile:
	rm -f *.elc lisp/*.elc tests/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(unless (file-exists-p "$(PROVIDER_ROOT)/etaf/etaf.el") (error "找不到 ETAF 检出（应为 ../etaf 或 --PROVIDER_ROOT 指定）"))' \
		--eval '(dolist (file (list $(foreach file,$(SOURCES),"$(file)"))) (unless (byte-compile-file file) (kill-emacs 1)))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(require (quote etaf-telega))' \
		--eval '(princ "etaf-telega load OK\n")'

test: acceptance

acceptance:
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el

check: structure-check compile acceptance api-check

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a published package checkout; run the shared checks from the etaf-mono workspace:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

clean:
	rm -f *.elc lisp/*.elc tests/*.elc
