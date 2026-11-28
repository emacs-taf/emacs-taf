.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PROVIDER_ROOT ?= $(if $(wildcard ../../core/packages/etaf),../../core/packages,$(if $(wildcard ../etaf/etaf.el),..,../..))
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss
SOURCES = lisp/etaf-desktop-theme.el lisp/etaf-desktop-shell.el lisp/etaf-desktop-runtime.el lisp/etaf-desktop-layout.el lisp/etaf-desktop-apps.el etaf-desktop.el
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
# check-api.el is supplied by the shared provider checker in standalone clones.
clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc

test: acceptance
