.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PYTHON ?= python3
ECSS_DIR ?= ../ecss
LOAD_EXTRA ?=
RELEASE_DIR ?= /tmp/ebox-release
RELEASE_DEPS_DIR ?= /tmp/ebox-release-deps
RELEASE_OPTIONS ?=

EMACS_BATCH = $(EMACS) -Q --batch -L . -L lisp -L benchmarks -L $(ECSS_DIR) $(LOAD_EXTRA) --eval '(setq load-prefer-newer t)'
EMACS_TEST = $(EMACS_BATCH) -L tests

.PHONY: all check ci load compile native checkdoc diff-check clean package-lint package-lint-install

.PHONY: release-deps release-build release-check release-tool-tests

all: check

release-deps:
	$(PYTHON) scripts/ebox-release.py deps --directory "$(RELEASE_DEPS_DIR)" $(RELEASE_OPTIONS)

release-build:
	$(PYTHON) scripts/ebox-release.py build --directory "$(RELEASE_DIR)" $(RELEASE_OPTIONS)

release-check: release-build
	$(PYTHON) scripts/ebox-release.py verify --directory "$(RELEASE_DIR)" --emacs "$(EMACS)"

release-tool-tests:
	$(PYTHON) -m unittest discover -s tests/tools -p 'test_ebox_release.py'

check: structure-check compile acceptance api-check release-tool-tests

ci: check checkdoc load diff-check

load:
	$(EMACS_BATCH) -l ebox.el --eval '(princ "ebox load OK\n")'

compile:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc benchmarks/*.elc
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t byte-compile-warnings (quote (not obsolete)))' -l ebox.el --eval '(ebox-byte-compile)'

native: compile
	$(EMACS_BATCH) -l ebox.el --eval '(dolist (file (cons "ebox.el" (directory-files "lisp" t "\\`ebox-.*\\.el$$"))) (native-compile (expand-file-name file)))'

package-lint:
	$(EMACS_BATCH) -l scripts/ebox-package-lint.el -f ebox-package-lint-batch

package-lint-install:
	EBOX_PACKAGE_LINT_INSTALL=1 $(MAKE) package-lint EMACS="$(EMACS)"

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (file (directory-files "lisp" t)) (when (string-suffix-p ".el" file) (checkdoc-file file))))'

diff-check:
	git diff --check

clean:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc benchmarks/*.elc

.PHONY: structure-check setup-hooks
structure-check:
	python3 ../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

.PHONY: acceptance
acceptance:
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../etaf -L ../etaf-ui -L ../etaf-db -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance

PERF_TOOL ?= ../../scripts/performance.py
.PHONY: perf-list perf-check
perf-list:
	$(PYTHON) "$(PERF_TOOL)" list --root . --scenario-file benchmarks/performance-scenarios.el --scenario 'ebox.*'
perf-check:
	$(PYTHON) "$(PERF_TOOL)" run --root . --scenario-file benchmarks/performance-scenarios.el --mode batch --scenario 'ebox.*' $(PERF_ARGS)

