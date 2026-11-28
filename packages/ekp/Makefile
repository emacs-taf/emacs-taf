.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
SOURCES := lisp/ekp-utils.el lisp/ekp-hyphen.el ekp.el lisp/ekp-buffer.el lisp/ekp-layout.el
.PHONY: compile check clean native-build
compile:
	$(EMACS) -Q --batch -L . -L lisp --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' -f batch-byte-compile $(SOURCES)
check: structure-check compile acceptance api-check
native-build:
	$(MAKE) -C native PROFILE=portable
clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc benchmarks/*.elc

.PHONY: structure-check setup-hooks
structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

.PHONY: acceptance
acceptance:
	@test -f ../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ebox -L ../etaf -L ../etaf-ui -L ../etaf-db -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance
