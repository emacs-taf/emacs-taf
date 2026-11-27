.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= ..
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui
LOAD_PATH += -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf-db
SOURCES = lisp/etaf-agenda-theme.el lisp/etaf-agenda-layout.el lisp/etaf-agenda-parse.el
SOURCES += lisp/etaf-agenda-store.el lisp/etaf-agenda-model.el lisp/etaf-agenda-keys.el
SOURCES += lisp/etaf-agenda-views-pages.el lisp/etaf-agenda-views.el lisp/etaf-agenda-app.el
SOURCES += etaf-agenda.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test

compile:
	rm -f *.elc lisp/*.elc tests/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-agenda))' --eval '(princ "etaf-agenda load OK\n")'

check: structure-check compile acceptance api-check

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a published package checkout; run the shared checks from the etaf-mono workspace:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

acceptance:
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el

clean:
	rm -f *.elc lisp/*.elc tests/*.elc

test: acceptance
