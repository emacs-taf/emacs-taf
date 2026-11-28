.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PROVIDERS = -L ../etaf -L ../etaf-ui -L ../etaf-ext -L ../ebox -L ../ecss -L ../ekp
LOAD_PATH = -L . -L lisp -L tests $(PROVIDERS)
SOURCES = \
	lisp/etaf-translate-core.el \
	lisp/etaf-translate-store.el \
	lisp/etaf-translate-cache.el \
	lisp/etaf-translate-rules.el \
	lisp/etaf-translate-extract.el \
	lisp/etaf-translate-engine.el \
	lisp/etaf-translate-render.el \
	lisp/etaf-translate-scheduler.el \
	lisp/etaf-translate-session.el \
	lisp/etaf-translate-ui.el \
	lisp/etaf-translate-integrations.el \
	etaf-translate.el

.PHONY: all compile load test check clean structure-check setup-hooks acceptance api-check

all: check

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-warnings '(not obsolete))" \
		--eval "(load-file \"etaf-translate.el\")" \
		--eval "(dolist (file '($(foreach file,$(SOURCES),\"$(file)\"))) (unless (byte-compile-file file) (error \"Compilation failed: %s\" file)))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' \
		--eval '(require (quote etaf-translate))' \
		--eval '(princ "etaf-translate load OK\n")'

acceptance:
	@test -f ../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

test: acceptance

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../ebox -L ../etaf -L ../etaf-ui -L ../etaf-ext -L ../etaf-db

check: structure-check compile acceptance api-check

clean:
	rm -f *.elc lisp/*.elc tests/*.elc
