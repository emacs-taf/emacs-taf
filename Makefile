.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
MODULE_DIRS := ecss tp ekp ebox etaf etaf-ui etaf-db ebox-playground etaf-playground
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
	python3 -m unittest discover -s tests -p 'test_*.py'
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" test EMACS="$(EMACS)"; done
check: structure-check
	python3 -m unittest discover -s tests -p 'test_*.py'
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" check EMACS="$(EMACS)"; done
clean:
	@set -e; for repo in $(MODULE_DIRS); do $(MAKE) -C "$$repo" clean; done
