.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
export PYTHONUTF8 := 1
PYTHON ?= python3
EMACSCLIENT ?= emacsclient

# Providers live beside the application in the workspace or standalone clones;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= $(if $(wildcard ../../core/packages/etaf),../../core/packages,$(if $(wildcard ../etaf/etaf.el),..,../..))

LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf \
            -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf/scripts

SOURCES = $(wildcard lisp/*.el) etaf-screensaver.el
SOURCES += scripts/etaf-screensaver-gui-scenarios.el
SOURCES += $(wildcard benchmarks/*.el) $(wildcard tests/*.el)

.PHONY: all compile load test check structure-check setup-hooks acceptance api-check gui clean

all: check

compile:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc benchmarks/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(require (quote etaf-screensaver))' \
		--eval '(princ "etaf-screensaver load OK\n")'

test: acceptance

check: structure-check compile acceptance api-check

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C apps/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(PYTHON) ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

acceptance:
	@test -f ../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C apps/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(PYTHON) ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C apps/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el

# Run the maintained GUI scenario in an existing owned server and print a fresh
# evidence directory; pass SERVER=<name> for a dedicated verification instance.
gui:
	$(EMACSCLIENT) $(if $(SERVER),--socket-name "$(SERVER)",) --eval '(progn (require (quote etaf-screensaver)) (add-to-list (quote load-path) (expand-file-name "scripts" (file-name-directory (locate-library "etaf")))) (add-to-list (quote load-path) "$(CURDIR)/scripts") (load "$(CURDIR)/scripts/etaf-screensaver-gui-scenarios.el" nil t) (let ((directory (make-temp-file "etaf-screensaver-gui-" t))) (run-at-time 0.05 nil (function etaf-screensaver-gui-run) directory) directory))'

clean:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc benchmarks/*.elc
