.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L ../etaf -L ../ebox -L ../ecss

.PHONY: all compile check checkdoc load clean

all: check

compile:
	rm -f *.elc lisp/*.elc tests/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' \
		--eval '(load-file "etaf-db.el")' \
		--eval '(progn (byte-compile-file "lisp/etaf-sqlite-store.el") (byte-compile-file "etaf-db.el"))'

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-db))' \
		--eval '(princ "etaf-db load OK\n")'

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (file (directory-files "." t)) (when (string-suffix-p ".el" file) (checkdoc-file file))))'

check: structure-check compile acceptance api-check

clean:
	rm -f *.elc lisp/*.elc tests/*.elc

.PHONY: structure-check setup-hooks
structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a published package checkout; run the shared checks from the etaf-mono workspace:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

.PHONY: acceptance
acceptance:
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../ebox -L ../etaf -L ../etaf-ui -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance
