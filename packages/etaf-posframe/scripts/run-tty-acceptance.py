#!/usr/bin/env python3
"""Run the terminal child frame scenarios on a real terminal.

The batch runner has no terminal, so the `etaf-posframe-tty-` cases skip there.
This runner starts a tmux session of a known size and runs the same ERT suite
in an interactive `-nw` Emacs, where `tty-child-frames` is usable.  The ERT
summary is written to a file, so the runner reports it even after the session
closes.  Exit status: 0 passed, 1 failed, 2 could not run.
"""
import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emacs", default="emacs", help="Emacs executable")
    parser.add_argument("--root", default=".", help="Package root")
    parser.add_argument("--columns", type=int, default=100, help="terminal columns")
    parser.add_argument("--rows", type=int, default=40, help="terminal rows")
    parser.add_argument("--timeout", type=float, default=120.0, help="seconds")
    return parser.parse_args()


def posframe_dir():
    """Return the installed Posframe directory, or the POSFRAME_DIR value."""
    configured = os.environ.get("POSFRAME_DIR")
    if configured:
        return Path(configured)
    candidates = sorted(Path.home().glob(".emacs.d/elpa/posframe-*"))
    return candidates[-1] if candidates else None


def load_path(root):
    root = Path(root).resolve()
    directories = [root, root / "tests", root.parent / "etaf-ui", root.parent / "ebox",
                   root.parent / "ecss", root.parent / "ekp", root.parent / "etaf"]
    installed = posframe_dir()
    if installed:
        directories.append(installed)
    return directories


def emacs_command(args, root):
    command = [args.emacs, "-nw", "-Q"]
    for directory in load_path(root):
        command += ["-L", str(directory)]
    command += ["-l", str(Path(root).resolve() / "tests" / "etaf-posframe-tests.el")]
    return command


def runner_form(result_file):
    """Return the Elisp runner that records the ERT report of the tty cases."""
    lines = [
        ";;; -*- lexical-binding: t; -*-",
        "(setq load-prefer-newer t)",
        "(require 'ert)",
        "(let* ((stats (ert-run-tests-batch \"^etaf-posframe-tty-\"))",
        "       (failed (ert-stats-completed-unexpected stats)))",
        f"  (with-temp-file {elisp_string(str(result_file))}",
        "    (insert (format \"Ran %d tests\\n%d unexpected\\n\"",
        "                    (ert-stats-total stats) failed))",
        "    (when (> failed 0)",
        "      (insert (with-current-buffer \"*Messages*\" (buffer-string))))))",
        "(kill-emacs 0)",
        "",
    ]
    return "\n".join(lines)


def elisp_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def strip_ansi(text):
    return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][A-Za-z0-9]",
                  "", text)


def main():
    args = parse_args()
    if not shutil.which("tmux"):
        print("tty acceptance needs tmux", file=sys.stderr)
        return 2
    root = Path(args.root).resolve()
    workspace = Path(tempfile.mkdtemp(prefix="etaf-posframe-tty-"))
    result_file = workspace / "results.txt"
    flag_file = workspace / "done"
    runner_file = workspace / "runner.el"
    runner_file.write_text(runner_form(result_file), encoding="utf-8")
    command = emacs_command(args, root) + ["-l", str(runner_file)]
    shell_command = " ".join(shlex.quote(part) for part in command)
    shell_command += f"; echo done > {shlex.quote(str(flag_file))}"
    session = f"etaf-posframe-tty-{os.getpid()}"
    subprocess.run(["tmux", "kill-session", "-t", session],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    started = subprocess.run(
        ["tmux", "new-session", "-d", "-s", session,
         "-x", str(args.columns), "-y", str(args.rows), shell_command],
        capture_output=True, text=True)
    if started.returncode != 0:
        print(started.stderr.strip() or "tmux could not start the session",
              file=sys.stderr)
        return 2
    deadline = time.time() + args.timeout
    try:
        while time.time() < deadline:
            if flag_file.exists():
                break
            time.sleep(0.5)
        else:
            screen = subprocess.run(
                ["tmux", "capture-pane", "-p", "-t", session],
                capture_output=True, text=True)
            print(screen.stdout[-2000:], file=sys.stderr)
            print("tty acceptance timed out", file=sys.stderr)
            return 2
    finally:
        subprocess.run(["tmux", "kill-session", "-t", session],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not result_file.exists():
        print("tty acceptance produced no report", file=sys.stderr)
        return 2
    text = strip_ansi(result_file.read_text(encoding="utf-8", errors="replace"))
    for line in text.splitlines():
        if line.startswith(("Ran ", "FAILED", "   passed", "   failed")):
            print(line)
    ran = re.search(r"Ran (\d+) tests?", text)
    failed = re.search(r"(\d+) unexpected", text)
    if not ran:
        print("tty acceptance did not report a test run", file=sys.stderr)
        print(text[-2000:], file=sys.stderr)
        return 2
    if failed and int(failed.group(1)) > 0:
        print(text[-4000:], file=sys.stderr)
        return 1
    if int(ran.group(1)) == 0:
        print("tty acceptance ran no tests", file=sys.stderr)
        shutil.rmtree(workspace, ignore_errors=True)
        return 2
    shutil.rmtree(workspace, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
