.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
JOBS ?= 1
# Every package under core/packages/, apps/, games/ in dependency order (providers first).
PACKAGE_PATHS = python3 scripts/refscope.py order --paths
.PHONY: compile test check clean structure-check setup-hooks order plan-affected check-affected
structure-check:
	python3 scripts/check-repository.py --exclude core/packages/ --exclude apps/ --exclude games/
	@set -e; for pkg in $$(python3 scripts/workspace_layout.py list-paths); do python3 scripts/check-repository.py --root "$$pkg" --skip-api; done
	python3 scripts/check-api.py --workspace .
setup-hooks:
	@if [ -d .git ]; then \
		git config --local core.hooksPath .githooks; \
		echo "Configured core.hooksPath=.githooks for this Git checkout."; \
	else \
		echo "jj does not run Git hooks; before publishing, check your message and tree with:"; \
		echo "  python3 scripts/check-commit-message.py /tmp/msg"; \
		echo "  make structure-check"; \
	fi
order:
	python3 scripts/refscope.py order --layers
compile: installer-compile
	@set -e; paths="$$($(PACKAGE_PATHS))"; for dir in $$paths; do $(MAKE) -C "$$dir" compile EMACS="$(EMACS)"; done
test:
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
	@set -e; paths="$$($(PACKAGE_PATHS))"; for dir in $$paths; do $(MAKE) -C "$$dir" test EMACS="$(EMACS)"; done
# Compile before the tool tests: the performance scenarios record whether the
# libraries they load came from source or from byte code, so a stale `.elc'
# beside a newer `.el' turns every sample invalid.
check: structure-check compile
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
	@set -e; paths="$$($(PACKAGE_PATHS))"; for dir in $$paths; do $(MAKE) -C "$$dir" check EMACS="$(EMACS)"; done

# Preview or execute only the units a change reaches: a symbol nobody outside
# uses costs nothing, while `check' still proves the whole checkout before a release.
plan-affected:
	python3 scripts/refscope.py plan --rev '@'
check-affected:
	python3 scripts/refscope.py run --rev '@' --yes --jobs "$(JOBS)"
clean:
	@set -e; paths="$$($(PACKAGE_PATHS))"; for dir in $$paths; do $(MAKE) -C "$$dir" clean; done

RELEASE_DIR ?= /tmp/etaf-release
.PHONY: installer-compile release-build release-drift release-check release-check-full release-publish release-tool-tests
installer-compile:
	$(MAKE) -C core/packages/etaf-install compile EMACS="$(EMACS)"
	python3 scripts/elisp.py run --emacs "$(EMACS)" -L core/packages/etaf-install -L core/packages/etaf-install/lisp -e '(require (quote bytecomp)) (let ((byte-compile-error-on-warn t)) (unless (byte-compile-file "scripts/install-smoke.el") (error "Compilation failed: scripts/install-smoke.el")))'
release-build:
	python3 scripts/package-release.py build --directory "$(RELEASE_DIR)"
release-drift:
	python3 scripts/archive-drift.py --directory "$(RELEASE_DIR)"
release-check:
	python3 scripts/package-release.py verify --directory "$(RELEASE_DIR)" --emacs "$(EMACS)" --scope auto
release-check-full:
	python3 scripts/package-release.py verify --directory "$(RELEASE_DIR)" --emacs "$(EMACS)" --scope full
release-publish:
	python3 scripts/package-release.py publish --directory "$(RELEASE_DIR)"
release-tool-tests:
	python3 -m unittest discover -s tests/tools -p 'test_package_*.py'
	python3 -m unittest discover -s tests/tools -p 'test_install.py'

.PHONY: api-check
api-check:
	@set -e; paths="$$($(PACKAGE_PATHS))"; for dir in $$paths; do $(MAKE) -C "$$dir" api-check EMACS="$(EMACS)"; done

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
