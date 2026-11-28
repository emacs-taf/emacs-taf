.DEFAULT_GOAL := check
.NOTPARALLEL:
# Makefile for the etaf-install package.

EMACS ?= emacs
LOADPATH = -L . -L lisp -L tests
SRC = lisp/etaf-install-catalog.el lisp/etaf-install-native.el lisp/etaf-install-doctor.el lisp/etaf-install-manage.el etaf-install.el
TESTS = $(wildcard tests/*-tests.el)

.PHONY: compile compile-all check clean diff-check structure-check setup-hooks acceptance api-check test

compile: clean
	$(EMACS) -Q --batch $(LOADPATH) \
	  --eval '(setq byte-compile-error-on-warn t byte-compile-warnings (quote (not obsolete)))' \
	  -f batch-byte-compile $(SRC)

compile-all: clean
	$(EMACS) -Q --batch $(LOADPATH) \
	  --eval '(setq byte-compile-error-on-warn t byte-compile-warnings (quote (not obsolete)))' \
	  -f batch-byte-compile $(SRC) $(TESTS)

diff-check:
	git diff --check

check: structure-check compile acceptance api-check

clean:
	rm -f *.elc lisp/*.elc tests/*.elc

structure-check:
	@test -f ../../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

acceptance:
	@test -f ../../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	@test -f ../../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l ../../../scripts/check-api.el

test: acceptance
