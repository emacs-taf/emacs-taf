.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L tests -L ../etaf -L ../etaf-ui -L ../ebox -L ../ecss
SOURCES = lisp/etaf-desktop-theme.el lisp/etaf-desktop-runtime.el lisp/etaf-desktop-layout.el lisp/etaf-desktop-apps.el etaf-desktop.el
SOURCES += $(wildcard examples/*.el)
TEST_FILES := $(wildcard tests/*-tests.el)

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test
compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-desktop))' --eval '(princ "etaf-desktop load OK\n")'
check: structure-check compile acceptance api-check
structure-check:
	python3 ../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	git config --local core.hooksPath .githooks
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"
api-check:
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
# check-api.el is supplied by the shared provider checker in standalone clones.
clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc

test: acceptance
