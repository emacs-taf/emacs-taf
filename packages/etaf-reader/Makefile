.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PROVIDER_ROOT ?= $(if $(wildcard ../etaf/etaf.el),..,../..)
LOAD_PATH = -L . -L lisp -L tests $(foreach package,etaf etaf-ui etaf-db ebox ecss,-L $(PROVIDER_ROOT)/$(package))
SOURCES = lisp/etaf-reader-theme.el lisp/etaf-reader-store.el
SOURCES += lisp/etaf-reader-library.el lisp/etaf-reader-model.el
SOURCES += lisp/etaf-reader-navigation.el lisp/etaf-reader-views.el
SOURCES += lisp/etaf-reader-app.el etaf-reader.el
SOURCES += $(wildcard examples/*.el)


.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test

compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-reader))' --eval '(princ "etaf-reader load OK\n")'

check: structure-check compile acceptance api-check

structure-check:
	python3 ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	git config --local core.hooksPath .githooks

acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"

api-check:
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el

test: acceptance

clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc
