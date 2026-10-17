"""Installer behavior through public commands and real package.el archives.

These tests use local fixture packages and disposable profiles.  They do not
need network access, a user init, sibling packages, native compilation or Git.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
EMACS = os.environ.get("EMACS", "emacs")


@unittest.skipUnless(shutil.which(EMACS), "Installer tests require Emacs")
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.profile = self.base / "profile"
        self.profile.mkdir()
        self.archive = self.base / "archive"
        self.sources = self.base / "sources"
        self.sources.mkdir()
        packages = {
            "ecss": ("0.1.0", '((emacs "29.1"))', ""),
            "ebox": ("3.0.0", '((emacs "29.1") (ecss "0.1.0"))', "(require 'ecss)\n"),
            "etaf": ("0.2.1", '((emacs "29.1") (ebox "3.0.0"))', "(require 'ebox)\n"),
            "etaf-ui": ("0.1.0", '((emacs "29.1") (etaf "0.2.1"))',
                        "(require 'etaf)\n(defun etaf-ui-gallery-open ()\n"
                        '  (interactive) (with-current-buffer (get-buffer-create "*archive-fixture*")\n'
                        '    (erase-buffer) (insert "Installed gallery")))\n'),
            "ekp": ("1.0.0", '((emacs "29.1"))', ""),
        }
        for name, (version, requirements, body) in packages.items():
            source = self.sources / name
            source.mkdir()
            (source / f"{name}.el").write_text(
                f';;; -*- lexical-binding: t; -*-\n;;; {name}.el --- Installer fixture\n'
                f';; Version: {version}\n;; Package-Requires: {requirements}\n'
                f"{body}(provide '{name})\n")
        self.build()
        (self.profile / "init.el").write_text(";; Unrelated user configuration\n")
        (self.profile / "custom.el").write_text(";; Existing customization\n")

    def build(self):
        if self.archive.exists():
            shutil.rmtree(self.archive)
        command = [sys.executable, str(ROOT / "scripts/package_archive.py"), "build",
                   "--directory", str(self.archive)]
        for source in sorted(self.sources.iterdir()):
            command.extend(["--package", f"{source.name}={source}"])
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def run_lisp(self, body):
        quote = lambda value: json.dumps(str(value))
        script = self.base / "scenario.el"
        script.write_text(
            ";;; -*- lexical-binding: t; -*-\n(require 'cl-lib)\n(require 'package)\n"
            f"(setq user-emacs-directory {quote(str(self.profile) + '/')}\n"
            f"      package-user-dir {quote(self.profile / 'elpa')}\n"
            f"      custom-file {quote(self.profile / 'custom.el')}\n"
            f"      package-archives (list (cons \"etaf\" {quote(str(self.archive) + '/')}))\n"
            "      package-directory-list nil native-comp-jit-compilation nil\n"
            "      print-circle t print-level 5 print-length 20)\n"
            f"(load {quote(ROOT / 'etaf-install.el')} nil t)\n"
            f"(setq etaf-install-archive-url {quote(str(self.archive) + '/')})\n"
            f"{body}\n(princ \"scenario=ok\\n\")\n")
        environment = dict(os.environ)
        environment.pop("EMACSLOADPATH", None)
        result = subprocess.run([EMACS, "-Q", "--batch", "-l", str(script)],
                                cwd=self.base, env=environment, capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("scenario=ok", result.stdout)
        self.assertIsNone(re.search(r"Warning:|Error in package", result.stderr), result.stderr)
        self.assertEqual(";; Unrelated user configuration\n", (self.profile / "init.el").read_text())
        self.assertTrue((self.profile / "custom.el").read_text().startswith(";; Existing customization\n"))

    def test_installs_dependencies_opens_target_and_reopens_offline(self):
        self.run_lisp("""
(unless (eq (etaf-install 'etaf-ui) 'etaf-ui) (error "Wrong installation result"))
(dolist (name '(ecss ebox etaf etaf-ui))
  (unless (package-installed-p name) (error "Missing dependency %s" name)))
(with-current-buffer "*archive-fixture*"
  (unless (equal (buffer-string) "Installed gallery") (error "Target was not opened")))
(setq etaf-install-archive-url "/does-not-exist/")
(etaf-install 'etaf-ui)
(unless (memq 'etaf-ui package-selected-packages) (error "Target not selected"))
""")

    def test_interactive_selection_works_with_a_custom_completion_frontend(self):
        self.run_lisp("""
(let ((completing-read-function
       (lambda (_prompt collection predicate _require-match &rest _options)
         (or (car (all-completions "etaf-ui" collection predicate))
             (error "No matching installation choice")))))
  (call-interactively #'etaf-install))
(unless (package-installed-p 'etaf-ui) (error "Interactive target was not installed"))
(with-current-buffer "*archive-fixture*"
  (unless (equal (buffer-string) "Installed gallery") (error "Interactive target was not opened")))
""")

    def test_corrupt_download_rolls_back_only_new_packages_and_preserves_configuration(self):
        (self.archive / "etaf-ui-0.1.0.tar").write_bytes(b"corrupt archive")
        self.run_lisp("""
(package-initialize)
(package-refresh-contents)
(package-install 'ecss)
(let ((selected (copy-sequence package-selected-packages))
      (custom (with-temp-buffer (insert-file-contents custom-file) (buffer-string)))
      failed)
  (condition-case nil (etaf-install 'etaf-ui t) (error (setq failed t)))
  (unless failed (error "Corrupt package was accepted"))
  (unless (and (package-installed-p 'ecss)
               (not (package-installed-p 'ebox))
               (not (package-installed-p 'etaf))
               (not (package-installed-p 'etaf-ui)))
    (error "Failed installation changed the previous package set"))
  (unless (equal selected package-selected-packages) (error "Selection changed"))
  (unless (equal custom (with-temp-buffer (insert-file-contents custom-file) (buffer-string)))
    (error "Failed installation wrote user customization")))
""")

    def test_entry_load_failure_is_not_reported_as_success(self):
        entry = self.sources / "etaf-ui/etaf-ui.el"
        entry.write_text(entry.read_text().replace("(provide 'etaf-ui)", '(error "Fixture entry failure")'))
        self.build()
        self.run_lisp("""
(let (failed)
  (condition-case condition (etaf-install 'etaf-ui t)
    (error (setq failed (string-match-p "Fixture entry failure" (error-message-string condition)))))
  (unless failed (error "Load failure was lost"))
  (when (package-installed-p 'etaf-ui) (error "Broken target remained installed")))
""")

    def test_unused_optional_source_checkout_does_not_block_core_installation(self):
        source = json.dumps(str(self.sources / "ekp"))
        self.run_lisp(f"""
(add-to-list 'load-path {source})
(etaf-install 'etaf-ui t)
(unless (package-installed-p 'etaf-ui) (error "Optional source blocked installation"))
(when (package-installed-p 'ekp) (error "Optional package was installed unexpectedly"))
""")

    def test_required_source_checkout_is_not_shadowed(self):
        source = json.dumps(str(self.sources / "ebox"))
        self.run_lisp(f"""
(add-to-list 'load-path {source})
(let (failed)
  (condition-case condition (etaf-install 'etaf-ui t)
    (user-error (setq failed (string-match-p "load-path" (error-message-string condition)))))
  (unless failed (error "Conflicting checkout was not reported"))
  (when (package-installed-p 'etaf-ui) (error "Installed over a source checkout")))
""")

    def test_preloaded_source_is_rejected_even_after_its_load_path_is_removed(self):
        sources = " ".join(json.dumps(str(self.sources / name)) for name in ("ecss", "ebox"))
        self.run_lisp(f"""
(let ((load-path (append (list {sources}) load-path))) (require 'ebox))
(let (failed)
  (condition-case condition (etaf-install 'etaf-ui t)
    (user-error (setq failed (string-match-p "restart" (error-message-string condition)))))
  (unless failed (error "Preloaded source was not detected"))
  (when (package-installed-p 'etaf-ui) (error "Installed over loaded source")))
""")

    def test_loaded_dependency_upgrade_is_rejected_without_changing_packages(self):
        previous = self.base / "previous"
        shutil.copytree(self.archive, previous)
        entry = self.sources / "ecss/ecss.el"
        entry.write_text(entry.read_text().replace("Version: 0.1.0", "Version: 0.2.0"))
        entry = self.sources / "ebox/ebox.el"
        entry.write_text(entry.read_text().replace('(ecss "0.1.0")', '(ecss "0.2.0")'))
        self.build()
        self.run_lisp(f"""
(package-initialize)
(let ((package-archives (list (cons "etaf" {json.dumps(str(previous) + '/')}))))
  (package-refresh-contents) (package-install 'ecss))
(require 'ecss)
(let ((custom (with-temp-buffer (insert-file-contents custom-file) (buffer-string))) failed)
  (condition-case condition (etaf-install 'etaf-ui t)
    (user-error (setq failed (string-match-p "restart" (error-message-string condition)))))
  (unless failed (error "Loaded dependency upgrade was not rejected"))
  (when (package-installed-p 'ecss '(0 2 0)) (error "Loaded dependency changed"))
  (when (package-installed-p 'etaf-ui) (error "Target installed over loaded dependency"))
  (unless (equal custom (with-temp-buffer (insert-file-contents custom-file) (buffer-string)))
    (error "Rejected upgrade changed customization")))
""")

    def test_failure_requires_restart_and_a_fresh_process_can_retry(self):
        (self.archive / "etaf-ui-0.1.0.tar").write_bytes(b"corrupt archive")
        self.run_lisp("""
(condition-case nil (etaf-install 'etaf-ui t) (error nil))
(let (restart)
  (condition-case condition (etaf-install 'etaf-ui t)
    (user-error (setq restart (string-match-p "Restart Emacs" (error-message-string condition)))))
  (unless restart (error "Retry accepted with partially loaded Lisp")))
""")
        self.build()
        self.run_lisp("""
(etaf-install 'etaf-ui)
(unless (package-installed-p 'etaf-ui) (error "Fresh-process retry failed"))
""")

    def test_installed_target_checks_dependency_source_paths_when_reopening(self):
        source = json.dumps(str(self.sources / "ebox"))
        self.run_lisp(f"""
(etaf-install 'etaf-ui t)
(add-to-list 'load-path {source})
(setq etaf-install-archive-url "/offline/")
(let (failed)
  (condition-case nil (etaf-install 'etaf-ui) (user-error (setq failed t)))
  (unless failed (error "Reopening missed the conflicting dependency checkout")))
""")

    def test_missing_sqlite_capability_is_reported_before_installation(self):
        self.run_lisp("""
(cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil)))
  (let ((facts (etaf-install-doctor 'etaf-db)) failed)
    (when (plist-get facts :ready) (error "Missing capability reported ready"))
    (condition-case condition (etaf-install 'etaf-db t)
      (user-error (setq failed (string-match-p "sqlite3" (error-message-string condition)))))
    (unless failed (error "Capability failure has no actionable explanation"))))
(when (file-exists-p package-user-dir) (error "Preflight failure modified packages"))
""")

    def test_insecure_archive_and_unknown_target_are_rejected(self):
        self.run_lisp("""
(setq etaf-install-archive-url "http://example.invalid/packages/")
(dolist (target '(etaf-ui unknown-target))
  (let (failed)
    (condition-case nil (etaf-install target t) (user-error (setq failed t)))
    (unless failed (error "Invalid installation request accepted"))))
""")

    def test_enabling_the_installer_does_not_access_the_archive(self):
        self.run_lisp("""
(setq etaf-install-archive-url "/does-not-exist/")
(let ((facts (etaf-install-doctor 'etaf-ui)))
  (unless (plist-get facts :ready) (error "Core capability check failed")))
(when (file-exists-p package-user-dir) (error "Read-only diagnosis modified packages"))
""")


if __name__ == "__main__":
    unittest.main()
