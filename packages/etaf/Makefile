.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L examples -L scripts -L benchmarks -L ../ebox -L ../ecss
SOURCES = lisp/etaf-view.el lisp/etaf-compiler.el lisp/etaf-component.el lisp/etaf-reactive.el lisp/etaf-animation.el lisp/etaf-observer.el lisp/etaf-context.el lisp/etaf-async.el lisp/etaf-resource.el lisp/etaf-data.el lisp/etaf-list-cache.el lisp/etaf-runtime.el lisp/etaf-behavior.el lisp/etaf-controlled-behavior.el lisp/etaf-actions.el lisp/etaf-events.el lisp/etaf-keys.el lisp/etaf-regions.el lisp/etaf-help.el lisp/etaf-viewport.el lisp/etaf-app.el lisp/etaf-process.el lisp/etaf-performance.el lisp/etaf-measure.el etaf.el scripts/emacs-gui-verifier.el
SOURCES += scripts/resource-gui-scenarios.el benchmarks/performance-scenarios.el
SOURCES += lisp/etaf-video-source.el lisp/etaf-video-audio.el lisp/etaf-video-mpv.el lisp/etaf-video-session.el lisp/etaf-video-component.el
SOURCES += lisp/etaf-projection.el lisp/etaf-inspect.el lisp/etaf-activity.el lisp/etaf-fullscreen.el lisp/etaf-pip.el
EXAMPLES = examples/etaf-animation-example.el examples/etaf-counter-example.el examples/etaf-data-example.el examples/etaf-resource-example.el examples/etaf-retained-resize.el
TESTS = $(filter-out tests/etaf-docs-tests.el,$(wildcard tests/*-tests.el))

.PHONY: compile native load checkdoc docs-check metadata-check check clean

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval "(setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-warnings '(not obsolete))" \
		--eval "(load-file \"etaf.el\")" \
		--eval "(dolist (file '($(foreach file,$(SOURCES) $(EXAMPLES),\"$(file)\"))) (unless (byte-compile-file file) (error \"Compilation failed: %s\" file)))"

native: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" --eval "(require 'etaf)" \
		--eval "(dolist (file '($(foreach file,$(filter lisp/% etaf.el,$(SOURCES)),\"$(file)\"))) (native-compile (expand-file-name file)))"

load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" --eval "(require 'etaf)" --eval "(princ \"ETAF load OK\\n\")"

docs-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval "(setq load-prefer-newer t)" -l tests/etaf-docs-tests.el \
		-f ert-run-tests-batch-and-exit

metadata-check:
	$(EMACS) -Q --batch --eval "(progn (require 'package) (with-temp-buffer (insert-file-contents \"etaf.el\") (let ((desc (package-buffer-info))) (unless (and (equal (package-desc-version desc) '(0 2 1)) (equal (package-desc-reqs desc) '((emacs (29 1)) (ebox (3 0 0))))) (error \"Unexpected ETAF package metadata: %S\" desc)))))"

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (dolist (directory (list "lisp" "examples" "scripts")) (dolist (file (directory-files directory t)) (when (string-suffix-p ".el" file) (checkdoc-file file)))))'

check: structure-check compile acceptance api-check tool-check

.PHONY: tool-check gui-tool-check
tool-check:
	EMACS="$(EMACS)" python3 -m unittest discover -s tests/tools -p 'test_gui_scenarios.py'
	EMACS="$(EMACS)" python3 -m unittest discover -s tests/tools -p 'test_gui_click.py'

gui-tool-check:
	EMACS="$(EMACS)" python3 -m unittest discover -s tests/tools -p 'test_*.py'

clean:
	rm -f *.elc lisp/*.elc examples/*.elc scripts/*.elc benchmarks/*.elc tests/*.elc

.PHONY: structure-check setup-hooks
structure-check:
	@test -f ../../scripts/check-repository.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/check-repository.py --root . --skip-api
	python3 scripts/check-agents-map.py
setup-hooks:
	@echo "jj does not run Git hooks; the container's 'make setup-hooks' explains what to check."

.PHONY: acceptance
acceptance:
	@test -f ../../scripts/run-acceptance.py || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	python3 ../../scripts/run-acceptance.py --root . --emacs "$(EMACS)"

.PHONY: api-check
api-check:
	@test -f ../../scripts/check-api.el || { \
	  echo "This is a read-only package projection; run shared checks from the emacs-taf monorepo:"; \
	  echo "  make -C packages/$(notdir $(CURDIR)) check"; \
	  exit 2; }
	$(EMACS) -Q --batch -L . $(API_PROVIDER_PATH) --eval '(setq load-prefer-newer t)' -l ../../scripts/check-api.el
API_PROVIDER_PATH = -L ../ecss -L ../ekp -L ../ebox -L ../etaf-ui -L ../etaf-db -L ../ebox-playground -L ../etaf-playground

.PHONY: test
test: acceptance
