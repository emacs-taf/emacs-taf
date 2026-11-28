.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
POSFRAME_DIR ?= $(lastword $(sort $(wildcard $(HOME)/.emacs.d/elpa/posframe-*)))
PROVIDERS = -L ../etaf -L ../etaf-ui -L ../etaf-posframe -L ../ebox -L ../ecss -L ../ekp
LOAD_PATH = -L . -L lisp -L tests $(PROVIDERS) $(if $(POSFRAME_DIR),-L $(POSFRAME_DIR))
SOURCES = \
	lisp/etaf-devtools-core.el \
	lisp/etaf-devtools-overlay.el \
	lisp/etaf-devtools-target.el \
	lisp/etaf-devtools-model.el \
	lisp/etaf-devtools-picker.el \
	lisp/etaf-devtools-view.el \
	lisp/etaf-devtools-ui.el \
	etaf-devtools.el

.PHONY: all compile load test check clean structure-check setup-hooks acceptance api-check

all: check

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-warnings '(not obsolete))" \
		--eval "(load-file \"etaf-devtools.el\")" \
		--eval "(dolist (file '($(foreach file,$(SOURCES),\"$(file)\"))) (unless (byte-compile-file file) (error \"Compilation failed: %s\" file)))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' \
		--eval '(require (quote etaf-devtools))' \
		--eval '(princ "etaf-devtools load OK\n")'

acceptance:
	@test -f ../../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	EMACSLOADPATH="$(POSFRAME_DIR):$(EMACSLOADPATH)" \
		python3 ../../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

test: acceptance

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
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) $(if $(POSFRAME_DIR),-L $(POSFRAME_DIR)) --eval '(setq load-prefer-newer t)' -l ../../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../ebox -L ../etaf -L ../etaf-ui -L ../etaf-posframe -L ../etaf-db

check: structure-check compile acceptance api-check

clean:
	rm -f *.elc lisp/*.elc tests/*.elc
