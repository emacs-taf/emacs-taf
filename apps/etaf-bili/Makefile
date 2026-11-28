.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs

# Providers live beside the application (standalone) or two levels up (workspace).
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= $(if $(wildcard ../../core/packages/etaf),../../core/packages,$(if $(wildcard ../etaf/etaf.el),..,../..))

LOAD_PATH = -L . -L lisp -L tests \
            -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-media -L $(PROVIDER_ROOT)/etaf-ui \
            -L $(PROVIDER_ROOT)/etaf-db -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss

SOURCES = lisp/etaf-bili-theme.el lisp/etaf-bili-service.el lisp/etaf-bili-store.el \
          lisp/etaf-bili-model.el lisp/etaf-bili-account.el \
          lisp/etaf-bili-views.el lisp/etaf-bili-watch.el lisp/etaf-bili-app.el
SOURCES += etaf-bili.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test

compile:
	rm -f *.elc lisp/*.elc tests/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(unless (file-exists-p "$(PROVIDER_ROOT)/etaf/etaf.el") (error "找不到 ETAF 检出（应为 ../etaf 或 --PROVIDER_ROOT 指定）"))' \
		--eval '(dolist (file (list $(foreach file,$(SOURCES),"$(file)"))) (unless (byte-compile-file file) (kill-emacs 1)))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(require (quote etaf-bili))' \
		--eval '(princ "etaf-bili load OK\n")'

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

clean:
	rm -f *.elc lisp/*.elc tests/*.elc

test: acceptance
