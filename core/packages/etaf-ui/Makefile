.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L ../etaf -L ../ebox -L ../ecss
SOURCES = lisp/etaf-ui-style.el lisp/etaf-ui-host-theme.el lisp/etaf-ui-basic.el lisp/etaf-ui-drop.el lisp/etaf-ui-edge.el lisp/etaf-ui-pane.el lisp/etaf-ui-icon.el lisp/etaf-ui-svg.el lisp/etaf-ui-input.el lisp/etaf-ui-field.el lisp/etaf-ui-editor.el lisp/etaf-ui-selection.el lisp/etaf-ui-feedback.el lisp/etaf-ui-navigation.el lisp/etaf-ui-surface.el lisp/etaf-ui-key-help.el lisp/etaf-ui-reactions.el lisp/etaf-ui-media.el lisp/etaf-ui-table.el lisp/etaf-ui-data.el lisp/etaf-ui-tile-grid.el lisp/etaf-ui-svg-stage.el lisp/etaf-ui-text-grid.el lisp/etaf-ui-cell-line.el lisp/etaf-ui-sheet.el lisp/etaf-ui-playing-card.el lisp/etaf-ui-advanced.el lisp/etaf-ui-window.el lisp/etaf-ui-desktop.el lisp/etaf-ui-markdown-parse.el lisp/etaf-ui-markdown-highlight.el lisp/etaf-ui-markdown.el etaf-ui.el

TEST_FILES := $(wildcard tests/*-tests.el)
SOURCES += $(wildcard examples/*.el) $(wildcard benchmarks/*.el) scripts/etaf-ui-gui.el scripts/etaf-ui-sheet-gui.el tests/etaf-ui-icon-gui.el

.PHONY: all compile check checkdoc load clean

all: check

compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc benchmarks/*.elc scripts/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-ui))' \
		--eval '(princ "etaf-ui load OK\n")'

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (file (append (directory-files "lisp" t "\\.el$$") (directory-files-recursively "tests" "\\.el$$") (directory-files-recursively "scripts" "\\.el$$"))) (checkdoc-file file)))'

check: structure-check compile acceptance api-check

clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc benchmarks/*.elc scripts/*.elc

.PHONY: structure-check setup-hooks gui-check icon-check
structure-check:
	@test -f ../../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

GUI_EXAMPLE ?= surfaces
gui-check: icon-check
	scripts/run-gui-check.sh $(GUI_EXAMPLE)

icon-check:
	scripts/run-icon-check.sh

PERF_ARGS ?=
PERF_TOOL ?= ../../../scripts/performance.py
.PHONY: perf-check
perf-check:
	python3 "$(PERF_TOOL)" run --root . --scenario-file benchmarks/performance-scenarios.el --mode gui --scenario 'gallery.*' $(PERF_ARGS)

.PHONY: acceptance
acceptance:
	@test -f ../../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	@test -f ../../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../ebox -L ../etaf -L ../etaf-db -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance
