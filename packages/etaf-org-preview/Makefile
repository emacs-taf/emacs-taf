.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Providers are siblings in the workspace and in a standalone clone;
# override PROVIDER_ROOT to pin another checkout.
PROVIDER_ROOT ?= ..
LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss
SOURCES = lisp/etaf-org-preview-entities.el lisp/etaf-org-preview-parse.el
SOURCES += lisp/etaf-org-preview-theme.el lisp/etaf-org-preview-model.el
SOURCES += lisp/etaf-org-preview-views.el lisp/etaf-org-preview-typeset.el
SOURCES += lisp/etaf-org-preview-app.el
SOURCES += etaf-org-preview.el
SOURCES += examples/etaf-org-preview-demo.el
SOURCES += benchmarks/performance-scenarios.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test benchmark

compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-org-preview))' --eval '(princ "etaf-org-preview load OK\n")'

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

benchmark:
	$(EMACS) -Q --batch $(LOAD_PATH) -l benchmarks/render-large-document.el

clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc scripts/*.elc
