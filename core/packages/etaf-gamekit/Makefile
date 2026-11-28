.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
GAMEKIT_CACHE ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/emacs-taf/game-engines
LOAD_PATH = -L . -L lisp -L ../etaf-ui -L ../etaf -L ../ebox -L ../ecss
SOURCES = lisp/etaf-gamekit-session.el lisp/etaf-gamekit-backends.el lisp/etaf-gamekit-engines.el lisp/etaf-gamekit-game.el lisp/etaf-gamekit-frame.el lisp/etaf-gamekit-view.el lisp/etaf-playing-card.el etaf-gamekit.el benchmarks/performance-scenarios.el tests/etaf-gamekit-tests.el tests/etaf-gamekit-playing-card-tests.el

.PHONY: compile test check clean structure-check setup-hooks acceptance api-check engine engine-check tool-test engine-all engine-boardgame-io engine-openspiel
compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' --eval '(require (quote cl-lib))' --eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
structure-check:
	@test -f ../../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/check-repository.py --root . --skip-api
engine:
	python3 native/godot/install-godot.py
engine-boardgame-io:
	npm ci --prefix native/boardgame-io --ignore-scripts --no-audit --no-fund
engine-openspiel:
	python3 native/openspiel/install-openspiel.py --cache "$(GAMEKIT_CACHE)" $(if $(GAMEKIT_PYTHON),--python "$(GAMEKIT_PYTHON)")
engine-all: engine engine-boardgame-io engine-openspiel
engine-check:
	python3 native/godot/install-godot.py --check
	node native/boardgame-io/bridge.cjs --version
	"$(GAMEKIT_CACHE)/openspiel/bin/python" native/openspiel/bridge.py --version
acceptance: engine-check
	@test -f ../../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"
tool-test: engine-check
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
api-check:
	@test -f ../../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C core/packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../../scripts/check-api.el
test: acceptance tool-test
check: structure-check compile acceptance tool-test api-check
clean:
	rm -f *.elc lisp/*.elc tests/*.elc benchmarks/*.elc scripts/*.elc
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."
