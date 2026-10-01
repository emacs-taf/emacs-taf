#!/usr/bin/env python3
"""Generate a diagnostic wrapper that reports which gate of a proof declined.

Many Ebox/ETAF predicates are one long `(when (and GATE ...) ...)` at the end
of a function.  When such a predicate returns nil it says nothing about which
gate vetoed the change, and adding prints to the engine is both noisy and
short-lived.  This tool reads one function's source, rebuilds it with its final
gate list replaced by a report of the failing gate indices and the original
result, and emits an Elisp adapter that:

  1. defines `<symbol>--gate-diagnosis' with the same arguments and gates,
  2. replaces the live symbol with a wrapper that runs both and records each
     call's report,
  3. prints the recorded failures through `diagnose-gates-report'.

Usage:

    python3 scripts/diagnose-gates.py ebox-incremental--grouped-owner-span-proof \
        --root ebox --output /tmp/grouped.gates.el

Then, in a batch run that triggers the predicate:

    python3 scripts/elisp.py run -p ebox -L ebox/tests \
        -l /tmp/grouped.gates.el -l scenario.el \
        -e '(diagnose-gates-install)' -e '(scenario-run)' -e '(diagnose-gates-report)'

Each printed line is `fails=(GATE-INDICES) ok=BOOL`; the indices count the
clauses of the final `(and ...)` in order, starting at 0.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sources(root: Path) -> list[Path]:
    """Workspace Lisp sources under ROOT, skipping hidden and vendor trees."""
    found = []
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = sorted(d for d in subdirs if not d.startswith("."))
        found.extend(Path(directory, name) for name in sorted(files)
                     if name.endswith(".el"))
    return found


def form_at(text: str, start: int) -> tuple[int, int] | None:
    """Start and end offsets of the balanced form opening at START."""
    depth, index, size = 0, start, len(text)
    while index < size:
        char = text[index]
        if char == ";":
            index = text.find("\n", index)
            if index == -1:
                return None
        elif char == '"':
            index += 1
            while index < size and text[index] != '"':
                index += 2 if text[index] == "\\" else 1
        elif char == "?":
            index += 2
        elif char == "\\":
            index += 1
        elif char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
            if depth == 0:
                return start, index + 1
        index += 1
    return None


def definition(text: str, symbol: str) -> tuple[int, int] | None:
    """Offsets of SYMBOL's definition form in TEXT."""
    pattern = re.compile(r"\(def(?:un|macro|subst)\s+" + re.escape(symbol) + r"[\s)]")
    for match in pattern.finditer(text):
        if text[text.rfind("\n", 0, match.start()) + 1:match.start()].lstrip().startswith(";"):
            continue
        span = form_at(text, match.start())
        if span:
            return span
    return None


def split_and(form: str, and_start: int) -> list[str]:
    """Top-level clause texts of the `(and ...)` form at AND_START."""
    clauses, buffer = [], ""
    depth, index = 0, and_start
    while index < len(form):
        char = form[index]
        if char == ";":
            index = form.index("\n", index)
            continue
        if char == '"':
            end = index + 1
            while form[end] != '"':
                end += 2 if form[end] == "\\" else 1
            if depth >= 2:
                buffer += form[index:end + 1]
            index = end + 1
            continue
        if char == "?" and depth >= 2:
            end = index + 2 if form[index + 1] == "\\" else index + 1
            buffer += form[index:end + 1]
            index = end + 1
            continue
        if char in "([":
            depth += 1
            if depth == 2:
                buffer = ""
            elif depth > 2:
                buffer += char
            index += 1
            continue
        if char in ")]":
            depth -= 1
            if depth == 1:
                clauses.append(buffer.strip())
                buffer = ""
            elif depth > 1:
                buffer += char
            else:
                return clauses
            index += 1
            continue
        if depth >= 2:
            buffer += char
        index += 1
    raise SystemExit("diagnose-gates: unbalanced gate form")


def adapter(symbol: str, form: str) -> str:
    """Return the Elisp adapter text for SYMBOL's definition FORM."""
    when_start = form.rindex("(when (and")
    let_start = form.index("(let*")
    if let_start > when_start:
        raise SystemExit(f"diagnose-gates: {symbol} has no gate `let*' before its final `when'")
    head = form[:let_start].replace(
        f"(defun {symbol}", f"(defun {symbol}--gate-diagnosis", 1)
    let_part = form[let_start:when_start]
    and_start = form.index("(and", when_start)
    clauses = split_and(form, and_start)
    if clauses and clauses[0] == "and":
        clauses = clauses[1:]
    if not clauses:
        raise SystemExit(f"diagnose-gates: {symbol}'s final gate list is empty")
    fails = " ".join(
        f'(condition-case nil (unless C{index} "{index}") (error "{index}-error"))'
        for index in range(len(clauses)))
    bindings = "\n".join(f"                (C{index} ({clause}))"
                         for index, clause in enumerate(clauses))
    conditions = " ".join(f"C{index}" for index in range(len(clauses)))
    return f"""\
;;; {symbol}.gates.el --- generated gate diagnosis -*- lexical-binding: t; -*-
;; Generated by scripts/diagnose-gates.py; do not edit by hand.
;; {len(clauses)} gates of `{symbol}''s final `(when (and ...))'.

(defvar diagnose-gates--log nil
  "Reports recorded by `diagnose-gates-install'.")

{head}{let_part}      (let ({bindings})
        (list :fails (delq nil (list {fails}))
              :ok (and {conditions})))))))

(defun diagnose-gates-install ()
  "Wrap `{symbol}' so every call also records its gate diagnosis."
  (setq diagnose-gates--log nil)
  (unless (fboundp 'diagnose-gates--original)
    (defalias 'diagnose-gates--original
      (symbol-function '{symbol})))
  (fset '{symbol}
        (lambda (&rest arguments)
          (let ((result (apply #'diagnose-gates--original arguments))
                (report (condition-case error-data
                            (apply #'{symbol}--gate-diagnosis arguments)
                          (error (list :fails (list (format "error:%S" error-data))
                                       :ok nil)))))
            (push report diagnose-gates--log)
            result))))

(defun diagnose-gates-report ()
  "Print each recorded gate diagnosis; return how many calls were seen."
  (let ((logs (reverse diagnose-gates--log)))
    (if (null logs)
        (princ "diagnose-gates: predicate was never called\\n")
      (dolist (log logs)
        (princ (format "fails=%S ok=%S\\n"
                       (plist-get log :fails)
                       (and (plist-get log :ok) t)))))
    (length logs)))

(provide '{symbol})
;;; {symbol}.gates.el ends here
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("symbol", help="fully qualified function name")
    parser.add_argument("--root", default=str(ROOT),
                        help="directory to search (default: the workspace root)")
    parser.add_argument("--source", help="exact .el file holding the definition")
    parser.add_argument("--output", help="write the adapter here (default: stdout)")
    arguments = parser.parse_args()

    files = [Path(arguments.source)] if arguments.source else sources(Path(arguments.root))
    for path in files:
        text = path.read_text(errors="replace")
        if arguments.symbol not in text:
            continue
        span = definition(text, arguments.symbol)
        if span:
            generated = adapter(arguments.symbol, text[span[0]:span[1]])
            if arguments.output:
                Path(arguments.output).write_text(generated)
            else:
                sys.stdout.write(generated)
            return 0
    print(f"diagnose-gates: {arguments.symbol} not found under {arguments.root}",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
