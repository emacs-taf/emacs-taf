.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Windows Python defaults to the ANSI code page; the policy tools read and
# write UTF-8 sources and spawn each other, so export UTF-8 mode to every
# child process on every platform.
export PYTHONUTF8 := 1
PYTHON ?= python3
NODE ?= node
EMACSCLIENT ?= emacsclient
GALLERY ?= $(HOME)/.emacs.d/etaf-screensaver/scenes/gallery/gallery.el
PRESENTATION ?= full

# Providers live beside the application (standalone) or two levels up (workspace).
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= ..

LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf \
            -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf/scripts

SOURCES = $(wildcard lisp/*.el) etaf-screensaver.el
SOURCES += scripts/etaf-screensaver-gui-scenarios.el
SOURCES += $(wildcard benchmarks/*.el) $(wildcard tests/*.el)

.PHONY: all compile load test check structure-check setup-hooks acceptance api-check tools-test gui gui-gallery gui-transition clean

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

check: structure-check compile acceptance api-check tools-test

tools-test:
	$(NODE) --test tests/tools/*.test.mjs

structure-check:
	$(PYTHON) ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	git config --local core.hooksPath .githooks

acceptance:
	$(PYTHON) scripts/run-acceptance.py --emacs "$(EMACS)"

api-check:
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el

# Run the maintained GUI scenario in an existing owned server and print a fresh
# evidence directory; pass SERVER=<name> for a dedicated verification instance.
gui:
	$(EMACSCLIENT) $(if $(SERVER),--socket-name "$(SERVER)",) --eval '(progn (require (quote etaf-screensaver)) (add-to-list (quote load-path) (expand-file-name "scripts" (file-name-directory (locate-library "etaf")))) (add-to-list (quote load-path) "$(CURDIR)/scripts") (load "$(CURDIR)/scripts/etaf-screensaver-gui-scenarios.el" nil t) (let ((directory (make-temp-file "etaf-screensaver-gui-" t))) (run-at-time 0.05 nil (function etaf-screensaver-gui-run) directory) directory))'

gui-gallery:
	$(EMACSCLIENT) $(if $(SERVER),--socket-name "$(SERVER)",) --eval '(progn (require (quote etaf-screensaver)) (add-to-list (quote load-path) (expand-file-name "scripts" (file-name-directory (locate-library "etaf")))) (load "$(CURDIR)/scripts/etaf-screensaver-gui-scenarios.el" nil t) (let ((directory (make-temp-file "etaf-screensaver-gallery-gui-" t))) (run-at-time 0.05 nil (function etaf-screensaver-gui-run-gallery) directory "$(GALLERY)") directory))'

gui-transition:
	$(EMACSCLIENT) $(if $(SERVER),--socket-name "$(SERVER)",) --eval '(progn (require (quote etaf-screensaver)) (add-to-list (quote load-path) (expand-file-name "scripts" (file-name-directory (locate-library "etaf")))) (load "$(CURDIR)/scripts/etaf-screensaver-gui-scenarios.el" nil t) (let ((directory (make-temp-file "etaf-screensaver-transition-gui-" t))) (run-at-time 0.05 nil (function etaf-screensaver-gui-run-transition) directory "$(GALLERY)" (quote $(PRESENTATION))) directory))'

clean:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc benchmarks/*.elc
