.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
GAMEKIT_CACHE ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/emacs-taf/game-engines
GODOT ?= $(GAMEKIT_CACHE)/bin/godot
PROVIDER_ROOT ?= $(if $(wildcard ../etaf/etaf.el),..,../..)
LOAD_PATH = -L . -L lisp -L $(PROVIDER_ROOT)/etaf-gamekit -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf/scripts
SOURCES = lisp/etaf-tanks-theme.el lisp/etaf-tanks-maps.el lisp/etaf-tanks-model.el lisp/etaf-tanks-board.el lisp/etaf-tanks-editor.el lisp/etaf-tanks-views.el lisp/etaf-tanks-app.el etaf-tanks.el tests/etaf-tanks-tests.el benchmarks/performance-scenarios.el scripts/etaf-tanks-gui-scenarios.el

.PHONY: compile test check clean structure-check setup-hooks acceptance api-check native-check
native-check:
	$(GODOT) --headless --no-header --path native/godot --check-only --script game.gd
compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' --eval '(require (quote cl-lib))' --eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a published package checkout; run the shared checks from the etaf-mono workspace:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api
acceptance:
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"
api-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
test: acceptance
check: structure-check native-check compile acceptance api-check
clean:
	rm -f *.elc lisp/*.elc tests/*.elc benchmarks/*.elc scripts/*.elc
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."
