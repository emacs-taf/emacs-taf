.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PROVIDER_ROOT ?= $(if $(wildcard ../etaf/etaf.el),..,../..)
LOAD_PATH = -L . -L lisp -L $(PROVIDER_ROOT)/etaf-gamekit -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf/scripts
SOURCES = lisp/etaf-solitaire-theme.el lisp/etaf-solitaire-model.el lisp/etaf-solitaire-views.el lisp/etaf-solitaire-app.el etaf-solitaire.el tests/etaf-solitaire-tests.el scripts/etaf-solitaire-gui-scenarios.el benchmarks/performance-scenarios.el

.PHONY: compile test check clean structure-check setup-hooks acceptance api-check
compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' --eval '(require (quote cl-lib))' --eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
structure-check:
	python3 ../../scripts/check-repository.py --root . --skip-api
acceptance:
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"
api-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
test: acceptance
check: structure-check compile acceptance api-check
clean:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc benchmarks/*.elc
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."
