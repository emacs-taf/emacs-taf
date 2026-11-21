.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= ..
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/etaf-db -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss
SOURCES = lisp/etaf-weread-theme.el lisp/etaf-weread-service.el lisp/etaf-weread-index.el
SOURCES += lisp/etaf-weread-model.el lisp/etaf-weread-views.el lisp/etaf-weread-app.el etaf-weread.el
SOURCES += $(wildcard examples/*.el)
SOURCES += scripts/weread-gui-probe.el
SOURCES += scripts/weread-gui-acceptance.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test
compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-weread))' --eval '(princ "etaf-weread load OK\n")'
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
clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc

test: acceptance
