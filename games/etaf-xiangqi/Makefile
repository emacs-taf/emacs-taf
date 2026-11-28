.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PROVIDER_ROOT ?= $(if $(wildcard ../../core/packages/etaf),../../core/packages,$(if $(wildcard ../etaf/etaf.el),..,../..))
LOAD_PATH = -L . -L lisp -L $(PROVIDER_ROOT)/etaf-gamekit -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf/scripts
SOURCES = lisp/etaf-xiangqi-theme.el lisp/etaf-xiangqi-model.el lisp/etaf-xiangqi-presentation.el lisp/etaf-xiangqi-board.el lisp/etaf-xiangqi-views.el lisp/etaf-xiangqi-app.el etaf-xiangqi.el tests/etaf-xiangqi-tests.el benchmarks/performance-scenarios.el scripts/etaf-xiangqi-gui-scenarios.el

.PHONY: compile test check clean structure-check setup-hooks acceptance api-check
compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' --eval '(require (quote cl-lib))' --eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C games/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api
acceptance:
	@test -f ../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C games/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"
api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C games/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
test: acceptance
check: structure-check compile acceptance api-check
clean:
	rm -f *.elc lisp/*.elc tests/*.elc benchmarks/*.elc scripts/*.elc
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."
