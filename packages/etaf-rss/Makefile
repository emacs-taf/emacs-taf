.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= ..
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui
LOAD_PATH += -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss
SOURCES = lisp/etaf-rss-theme.el lisp/etaf-rss-parse.el lisp/etaf-rss-store.el
SOURCES += lisp/etaf-rss-service.el lisp/etaf-rss-miniflux.el
SOURCES += lisp/etaf-rss-model.el lisp/etaf-rss-views.el lisp/etaf-rss-app.el
SOURCES += etaf-rss.el
SOURCES += $(wildcard examples/*.el)
SOURCES += $(wildcard scripts/*.el)
SOURCES += $(wildcard benchmarks/*.el)

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test benchmark

compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-rss))' --eval '(princ "etaf-rss load OK\n")'

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
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc

test: acceptance
