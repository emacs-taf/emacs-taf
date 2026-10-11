.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
MODULE_DIRS := ecss ekp ebox etaf etaf-ui etaf-db etaf-desktop ebox-playground etaf-playground etaf-manual
.PHONY: compile test check clean structure-check setup-hooks sync-policy
structure-check:
	python3 scripts/workspace.py check
sync-policy:
	python3 scripts/workspace.py sync
setup-hooks:
	python3 scripts/workspace.py setup-hooks
	git config --local core.hooksPath .githooks
compile:
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" compile EMACS="$(EMACS)"; done
test:
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" test EMACS="$(EMACS)"; done
check: structure-check
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" check EMACS="$(EMACS)"; done
clean:
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" clean; done

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
