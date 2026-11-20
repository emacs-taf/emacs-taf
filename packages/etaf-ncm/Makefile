.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= ..
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf-db
SOURCES = lisp/etaf-ncm-theme.el lisp/etaf-ncm-layout.el lisp/etaf-ncm-service.el lisp/etaf-ncm-cache.el lisp/etaf-ncm-hero.el lisp/etaf-ncm-model.el lisp/etaf-ncm-views.el lisp/etaf-ncm-app.el etaf-ncm.el
SOURCES += $(wildcard examples/*.el)

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test
compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-ncm))' --eval '(princ "etaf-ncm load OK\n")'
check: structure-check compile acceptance api-check
structure-check:
	python3 ../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	git config --local core.hooksPath .githooks
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"
api-check:
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc

test: acceptance
