.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
# Single source: every directory under packages/ with one root entry is a module.
MODULE_DIRS := $(patsubst packages/%,%,$(wildcard packages/*))
.PHONY: compile test check clean structure-check setup-hooks
structure-check:
	python3 scripts/check-repository.py --exclude packages/
	@set -e; for pkg in packages/*; do python3 scripts/check-repository.py --root "$$pkg" --skip-api; done
	python3 scripts/check-api.py --workspace packages
setup-hooks:
	@echo "jj does not run Git hooks; check the message and the sealed tree with"
	@echo "  python3 scripts/check-commit-message.py /tmp/msg"
	@echo "  python3 scripts/check-repository.py --exclude packages/"
	@echo "and validate every package with 'make structure-check' before publishing.
	git config --local core.hooksPath .githooks
compile: installer-compile
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "packages/$$repo" compile EMACS="$(EMACS)"; done
test:
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "packages/$$repo" test EMACS="$(EMACS)"; done
check: structure-check installer-compile
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "packages/$$repo" check EMACS="$(EMACS)"; done

# Only the units a change reaches: a symbol nobody outside uses costs nothing,
# while `check' still proves the whole checkout before a release.
check-affected:
	python3 scripts/refscope.py run --rev '@' --yes
clean:
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "packages/$$repo" clean; done

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
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "packages/$$repo" api-check EMACS="$(EMACS)"; done

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
