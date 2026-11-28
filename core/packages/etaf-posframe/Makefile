.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
POSFRAME_DIR ?= $(lastword $(sort $(wildcard $(HOME)/.emacs.d/elpa/posframe-*)))
PROVIDERS = -L ../etaf -L ../etaf-ui -L ../ebox -L ../ecss -L ../ekp
LOAD_PATH = -L . -L lisp -L tests $(PROVIDERS) $(if $(POSFRAME_DIR),-L $(POSFRAME_DIR))
SOURCES = lisp/etaf-posframe-pool.el lisp/etaf-posframe-panel.el lisp/etaf-posframe-layout.el lisp/etaf-posframe-app.el lisp/etaf-posframe-modal.el etaf-posframe.el examples/etaf-symbol-card.el tests/etaf-posframe-tests.el

.PHONY: all compile load test tty-test check clean structure-check setup-hooks acceptance api-check

all: check

compile:
	rm -f *.elc lisp/*.elc examples/*.elc tests/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-posframe))' \
		--eval '(princ "etaf-posframe load OK\n")'

acceptance:
	@test -f ../../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	EMACSLOADPATH="$(POSFRAME_DIR):$(EMACSLOADPATH)" \
		python3 ../../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

test: acceptance

tty-test:
	python3 scripts/run-tty-acceptance.py --emacs "$(EMACS)"

structure-check:
	@test -f ../../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

api-check:
	@test -f ../../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../../scripts/check-api.el

check: structure-check compile acceptance api-check

clean:
	rm -f *.elc lisp/*.elc examples/*.elc tests/*.elc
