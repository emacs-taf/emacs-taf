.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PROVIDER_ROOT ?= $(if $(wildcard ../etaf/etaf.el),..,../..)
LOAD_PATH = -L . -L lisp -L tests $(foreach package,etaf etaf-ui ebox ecss etaf-db,-L $(PROVIDER_ROOT)/$(package))
SOURCES = lisp/etaf-video-player-theme.el lisp/etaf-video-player-subtitle.el lisp/etaf-video-player-history.el lisp/etaf-video-player-views.el lisp/etaf-video-player-app.el
SOURCES += etaf-video-player.el
SOURCES += $(wildcard examples/*.el)


.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test

compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-video-player))' --eval '(princ "etaf-video-player load OK\n")'

check: structure-check compile acceptance api-check

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a published package checkout; run the shared checks from the etaf-mono workspace:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

acceptance:
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

api-check:
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el

test: acceptance

clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc
