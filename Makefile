.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Single source: the checkout list and its dependency order come from the registry.
MODULE_DIRS := $(shell python3 -c 'import json; print(" ".join(json.load(open("workspace.json"))["repositories"]))')
.PHONY: compile test check clean structure-check setup-hooks sync-policy
structure-check:
	python3 scripts/workspace.py check
sync-policy:
	python3 scripts/workspace.py sync
setup-hooks:
	python3 scripts/workspace.py setup-hooks
	git config --local core.hooksPath .githooks
compile: installer-compile
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" compile EMACS="$(EMACS)"; done
test:
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" test EMACS="$(EMACS)"; done
check: structure-check installer-compile
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" check EMACS="$(EMACS)"; done
clean:
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" clean; done

RELEASE_DIR ?= /tmp/etaf-release
.PHONY: installer-compile release-build release-check release-publish release-tool-tests
installer-compile:
	python3 scripts/elisp.py run --emacs "$(EMACS)" -L . -e '(require (quote bytecomp)) (let ((byte-compile-error-on-warn t)) (dolist (file (quote ("etaf-install.el" "scripts/install-smoke.el"))) (unless (byte-compile-file file) (error "Compilation failed: %s" file))))'
release-build:
	python3 scripts/package-release.py build --directory "$(RELEASE_DIR)"
release-check:
	python3 scripts/package-release.py verify --directory "$(RELEASE_DIR)" --emacs "$(EMACS)"
release-publish:
	python3 scripts/package-release.py publish --directory "$(RELEASE_DIR)"
release-tool-tests:
	python3 -m unittest discover -s tests/tools -p 'test_package_*.py'
	python3 -m unittest discover -s tests/tools -p 'test_install.py'

.PHONY: api-check
api-check:
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" api-check EMACS="$(EMACS)"; done

.PHONY: verify verify-baseline verify-repeatability
verify:
	python3 scripts/verify.py --emacs "$(EMACS)" --baseline "$(BASELINE)"
verify-baseline:
	python3 scripts/verify.py --emacs "$(EMACS)" --record-baseline
verify-repeatability:
	python3 scripts/verify.py --emacs "$(EMACS)" --baseline "$(BASELINE)" --repeatability

.PHONY: perf-list perf-check perf-compare
perf-list:
	python3 scripts/performance.py list $(PERF_ARGS)
perf-check:
	python3 scripts/performance.py run --emacs "$(EMACS)" $(PERF_ARGS)
perf-compare:
	python3 scripts/performance.py compare "$(BASELINE)" "$(RESULT)"
