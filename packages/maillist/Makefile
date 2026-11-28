.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
EMACSCLIENT ?= emacsclient

# Providers live beside the application (standalone) or two levels up (workspace).
# Override on the command line to pin a stable checkout while a provider is
# being edited elsewhere:
#   make check PROVIDER_ROOT=/path/to/providers
PROVIDER_ROOT ?= $(if $(wildcard ../etaf/etaf.el),..,$(if $(wildcard ../../etaf/etaf.el),../..,))

LOAD_PATH = -L . -L lisp -L tests -L $(PROVIDER_ROOT)/etaf -L $(PROVIDER_ROOT)/etaf-ui \
            -L $(PROVIDER_ROOT)/ebox -L $(PROVIDER_ROOT)/ecss -L $(PROVIDER_ROOT)/etaf-db

SOURCES = $(wildcard lisp/*.el) maillist.el

.PHONY: compile load test check structure-check acceptance api-check setup-hooks gui clean

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

acceptance:
	@test -f ../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

test: acceptance

check: structure-check compile acceptance api-check

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	@test -f maillist.el || { echo "缺少入口 maillist.el"; exit 1; }
	@test -f tests/acceptance.json || { echo "缺少 tests/acceptance.json"; exit 1; }
	@test -n "$(PROVIDER_ROOT)" || { echo "找不到 provider（../etaf 或 ../../etaf）"; exit 1; }
	python3 ../../scripts/check-repository.py --root . --skip-api

api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t)' \
		-l ../../scripts/check-api.el

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

# Run the maintained GUI scenario in an existing owned server and print a fresh
# evidence directory; pass SERVER=<name> for a dedicated verification instance.
gui:
	$(EMACSCLIENT) $(if $(SERVER),--socket-name "$(SERVER)",) --eval '(progn (require (quote maillist)) (add-to-list (quote load-path) (expand-file-name "scripts" (file-name-directory (locate-library "etaf")))) (add-to-list (quote load-path) "$(CURDIR)/scripts") (load "$(CURDIR)/scripts/maillist-gui-scenarios.el" nil t) (let ((directory (make-temp-file "maillist-gui-" t))) (run-at-time 0.05 nil (function maillist-gui-run) directory t) directory))'

clean:
	rm -f *.elc lisp/*.elc tests/*.elc scripts/*.elc
