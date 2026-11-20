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
	python3 ../../scripts/check-repository.py --root . --skip-api
setup-hooks:
	git config --local core.hooksPath .githooks

.PHONY: acceptance
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../ebox -L ../etaf -L ../etaf-ui -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance
