.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L tests -L ../etaf -L ../ebox -L ../ecss
SOURCES = lisp/etaf-video-source.el lisp/etaf-video-audio.el lisp/etaf-video-mpv.el lisp/etaf-video-session.el lisp/etaf-video-component.el etaf-media.el

.PHONY: all compile load check clean structure-check setup-hooks acceptance api-check test

all: check

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-warnings '(not obsolete))" \
		--eval "(load-file \"etaf-media.el\")" \
		--eval "(dolist (file '($(foreach file,$(SOURCES),\"$(file)\"))) (unless (byte-compile-file file) (error \"Compilation failed: %s\" file)))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" --eval "(require 'etaf-media)" --eval "(princ \"ETAF Media load OK\\n\")"

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
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ebox -L ../etaf

check: structure-check compile acceptance api-check

test: acceptance

clean:
	rm -f *.elc lisp/*.elc tests/*.elc
