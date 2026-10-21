.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs

# Providers live beside the application (standalone) or two levels up (workspace).
# Override on the command line to pin a stable checkout while a provider is
# being edited elsewhere:
#   make check PROVIDER_ROOT=/path/to/providers
PROVIDER_ROOT ?= $(if $(wildcard ../etaf/etaf.el),..,$(if $(wildcard ../../etaf/etaf.el),../..,))

LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui \
            -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf-db

SOURCES = $(wildcard lisp/*.el) maillist.el

.PHONY: compile load test check structure-check clean

compile:
	rm -f *.elc lisp/*.elc tests/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(unless (file-exists-p "$(PROVIDER_ROOT)/etaf/etaf.el") (error "找不到 ETAF 检出（../etaf 或 ../../etaf）"))' \
		--eval '(dolist (file (list $(foreach file,$(SOURCES),"$(file)"))) (unless (byte-compile-file file) (kill-emacs 1)))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(require (quote maillist))' \
		--eval '(princ "maillist load OK\n")'

test:
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t)' \
		--eval '(require (quote maillist-tests))' \
		--eval '(ert-run-tests-batch-and-exit)'

check: structure-check compile test

structure-check:
	@test -f maillist.el || { echo "缺少入口 maillist.el"; exit 1; }
	@test -f tests/acceptance.json || { echo "缺少 tests/acceptance.json"; exit 1; }
	@test -n "$(PROVIDER_ROOT)" || { echo "找不到 provider（../etaf 或 ../../etaf）"; exit 1; }
	@echo "maillist structure OK"

clean:
	rm -f *.elc lisp/*.elc tests/*.elc
