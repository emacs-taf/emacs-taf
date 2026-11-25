.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
PROVIDERS = -L ../etaf -L ../etaf-ui -L ../etaf-posframe -L ../etaf-ext -L ../ebox -L ../ecss -L ../ekp
LOAD_PATH = -L . -L tests $(PROVIDERS)
SOURCES = etaf-highlight.el

.PHONY: all compile load test check clean structure-check setup-hooks acceptance api-check

all: check

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-warnings '(not obsolete))" \
		--eval "(load-file \"etaf-highlight.el\")" \
		--eval "(unless (byte-compile-file \"etaf-highlight.el\") (error \"Compilation failed: etaf-highlight.el\"))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' \
		--eval '(require (quote etaf-highlight))' \
		--eval '(princ "etaf-highlight load OK\n")'

acceptance:
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

test: acceptance

structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a published package checkout; run the shared checks from the etaf-mono workspace:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api

setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

api-check:
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../ebox -L ../etaf -L ../etaf-ui -L ../etaf-posframe -L ../etaf-ext

check: structure-check compile acceptance api-check

clean:
	rm -f *.elc tests/*.elc
