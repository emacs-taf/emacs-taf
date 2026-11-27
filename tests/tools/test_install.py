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
            "etaf-telega": (
                "0.1.0", '((emacs "29.1") (etaf "0.2.1"))',
                "(require 'etaf)\n"
                "(defun etaf-telega-doctor ()\n"
                '  (list :required (list (list "telega-server" nil '
                '"Install TDLib, then run M-x telega-server-build."))))\n'
                "(defun etaf-telega-open () (interactive))\n"),
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
            f"(load {quote(ROOT / 'packages/etaf-install/etaf-install.el')} nil t)\n"
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

    def test_status_reports_versions_runtime_and_dependency_closure(self):
        self.run_lisp("""
(etaf-install 'etaf-ui t)
(let ((status (etaf-install-status 'etaf-ui)))
  (unless (equal (plist-get status :installed) "0.1.0") (error "Wrong installed version"))
  (unless (equal (plist-get status :available) "0.1.0") (error "Wrong available version"))
  (unless (plist-get status :installed-p) (error "Installed target not marked installed"))
  (when (plist-get status :update) (error "Spurious update"))
  (unless (equal (plist-get status :runtime) "Ready") (error "Runtime not ready"))
  (unless (member 'etaf (plist-get status :dependencies)) (error "Dependency closure missing etaf"))
  (unless (member 'ebox (plist-get status :dependencies)) (error "Dependency closure missing ebox")))
""")

    def test_manage_buffer_lists_targets_and_status(self):
        self.run_lisp("""
(etaf-install 'etaf-ui t)
(etaf-install-manage)
(unless (get-buffer "*ETAF Packages*") (error "Manage buffer missing"))
(with-current-buffer "*ETAF Packages*"
  (unless (derived-mode-p 'tabulated-list-mode) (error "Manage buffer is not a tabulated list"))
  (unless (string-match-p "etaf-ui" (buffer-string)) (error "Installed target missing from manage buffer"))
  (unless (string-match-p "Installed" (buffer-string)) (error "Installed status missing from manage buffer")))
;; One window holds the table: the summary and keys live on the mode line, so
;; no second buffer and no frame split.
(unless (null (get-buffer "*ETAF Packages Header*"))
  (error "Manage interface opens a separate header buffer"))
(unless (= 1 (length (get-buffer-window-list "*ETAF Packages*")))
  (error "Manage buffer is not the only thing its window shows"))
(unless (= 1 (length (window-list)))
  (error "Manage interface left another window open beside the table"))
""")

    def test_manage_menu_opens_beside_the_manager(self):
        self.run_lisp("""
(etaf-install 'etaf-ui t)
(etaf-install-manage)
(let ((manager (get-buffer "*ETAF Packages*"))
      (menu (get-buffer-create "*Packages*")))
  ;; The archive fetch belongs to package.el; this scenario checks only that
  ;; opening the package menu cannot take over the manager's window.
  (cl-letf (((symbol-function 'list-packages)
             (lambda (&optional _no-fetch) (pop-to-buffer menu))))
    (execute-kbd-macro "l"))
  (unless (get-buffer-window menu)
    (error "The package menu did not open"))
  (unless (get-buffer-window manager)
    (error "The package menu replaced the ETAF manager window"))
  (unless (eq (window-buffer (selected-window)) menu)
    (error "The package menu did not get its own window")))
""")

    def test_manage_echoes_key_hints_on_open_navigation_and_refresh(self):
        self.run_lisp("""
(etaf-install 'etaf-ui t)
(let (messages)
  (cl-letf (((symbol-function 'message)
             (lambda (format-string &rest args)
               (push (apply #'format format-string args) messages))))
    (etaf-install-manage))
  (let ((latest (and (car messages) (substring-no-properties (car messages)))))
    (unless latest (error "Opening manage buffer produced no echo message"))
    (when (string-match-p "Install ETAF" latest)
      (error "Open echo message still includes target details: %S" latest))
    (dolist (hint '("i install" "n native" "u update" "U update all"
                    "d remove" "RET open" "? doctor" "g refresh"
                    "l packages" "q quit"))
      (unless (string-match-p (regexp-quote hint) latest)
        (error "Open echo message missing key hint %S: %S" hint latest)))))
(with-current-buffer "*ETAF Packages*"
  (goto-char (point-min))
  (unless (search-forward "etaf-ui" nil t) (error "Target missing from manage buffer"))
  (beginning-of-line)
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (run-hooks 'post-command-hook))
    (let* ((raw (car messages))
           (latest (and raw (substring-no-properties raw)))
           (pos (and latest (string-match "i install" latest))))
      (unless (and latest pos
                   (not (string-match-p "ETAF components and gallery" latest))
                   (string-match-p "q quit" latest))
        (error "Navigation echo should show only key hints: %S" latest))
      (unless (eq (get-text-property pos 'face raw) 'bold)
        (error "Echo key hint did not use bold face: %S"
               (get-text-property pos 'face raw)))))
  (goto-char (point-max))
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (run-hooks 'post-command-hook))
    (unless (and (car messages) (string-match-p "i install" (car messages)))
      (error "Blank line echo missing key hints: %S" messages)))
  (goto-char (point-min))
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages)))
              ((symbol-function 'frame-width) (lambda (&rest _) 80)))
      (let ((noninteractive nil))
        (run-hooks 'post-command-hook)))
    (let* ((latest (and (car messages) (substring-no-properties (car messages))))
           (hint-lines (and latest (split-string latest "\n"))))
      (unless (and hint-lines
                   (= (length hint-lines) 2)
                   (cl-every (lambda (line) (<= (length line) 78)) hint-lines)
                   (string-match-p "RET open" (car hint-lines))
                   (string-match-p "q quit" (cadr hint-lines)))
        (error "80-column echo key hints did not wrap cleanly: %S" latest))))
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (execute-kbd-macro "g"))
    (let ((latest (and (car messages) (substring-no-properties (car messages)))))
      (unless (and latest
                   (string-match-p "package archives refreshed" latest)
                   (string-match-p "i install" latest))
        (error "Refresh echo lost status or key hints: %S" latest))))
  (unless (and (consp mode-line-format) (eq (car mode-line-format) :eval))
    (error "Unexpected manage mode-line-format: %S" mode-line-format))
  (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 180)))
    (let ((ml (substring-no-properties (eval (cadr mode-line-format)))))
      (unless (and (string-match-p "ETAF Packages" ml)
                   (string-match-p "Refresh" ml))
        (error "Mode line missing summary or Refresh button: %S" ml))
      (when (string-match-p "i install" ml)
        (error "Mode line should not duplicate key hints: %S" ml)))))
""")

    def test_missing_runtime_reports_remedy_without_claiming_ready(self):
        self.run_lisp("""
(let (messages)
  (cl-letf (((symbol-function 'message)
             (lambda (format-string &rest args)
               (push (apply #'format format-string args) messages))))
    (etaf-install 'etaf-telega t))
  (unless (cl-some (lambda (message) (string-match-p "telega-server" message)) messages)
    (error "Missing runtime was not reported"))
  (unless (cl-some (lambda (message) (string-match-p "telega-server-build" message)) messages)
    (error "Runtime remedy was not reported"))
  (when (cl-some (lambda (message) (string-match-p "is ready" message)) messages)
    (error "Missing runtime was reported as ready")))
(let ((status (etaf-install-status 'etaf-telega)))
  (unless (equal (plist-get status :runtime) "telega-server missing")
    (error "Wrong runtime status: %S" (plist-get status :runtime)))
  (unless (string-match-p "telega-server-build" (or (plist-get status :remedy) ""))
    (error "Status has no remedy")))
(etaf-install-manage)
(with-current-buffer "*ETAF Packages*"
  (goto-char (point-min))
  (unless (search-forward "etaf-telega" nil t) (error "Target missing from manage buffer"))
  (beginning-of-line)
  (execute-kbd-macro "?")
  (with-current-buffer "*ETAF Installation*"
    (unless (string-match-p "telega-server-build" (buffer-string))
      (error "Doctor buffer from manage view has no remedy"))))
""")

    def test_update_upgrades_an_installed_target_from_the_archive(self):
        self.run_lisp("(etaf-install 'etaf-ui t)")
        entry = self.sources / "etaf-ui/etaf-ui.el"
        entry.write_text(entry.read_text().replace("Version: 0.1.0", "Version: 0.1.1"))
        self.build()
        self.run_lisp("""
(package-initialize)
(let ((report (etaf-install-update 'etaf-ui)))
  (unless (package-installed-p 'etaf-ui '(0 1 1))
    (error "Target not updated: %S" report))
  (unless (plist-get report :updated) (error "Update was not reported"))
  (unless (plist-get report :restart) (error "Restart was not reported")))
""")

    def test_remove_deletes_target_and_selection_but_keeps_shared_dependencies(self):
        self.run_lisp("(etaf-install 'etaf-ui t)")
        self.run_lisp("""
(package-initialize)
(etaf-install-remove 'etaf-ui t)
(when (package-installed-p 'etaf-ui) (error "Target remained installed"))
(unless (package-installed-p 'etaf) (error "Shared etaf dependency was removed"))
(unless (package-installed-p 'ebox) (error "Shared ebox dependency was removed"))
(when (memq 'etaf-ui package-selected-packages) (error "Target selection remained"))
""")

    def _add_native_etaf_md_fixture(self, binary_bytes, version="0.3.0",
                                    platform_key="darwin-arm64", suffix=".dylib",
                                    urls=None):
        import hashlib
        sha = hashlib.sha256(binary_bytes).hexdigest()
        filename = f"etaf-md-typeset-native-v1-{platform_key}{suffix}"
        src = self.sources / "etaf-md"
        (src / "native").mkdir(parents=True, exist_ok=True)
        (src / "etaf-md.el").write_text(
            ';;; -*- lexical-binding: t; -*-\n;;; etaf-md.el --- Native fixture\n'
            f';; Version: {version}\n;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0"))\n'
            '(defun etaf-md-open () (interactive))\n'
            '(defun etaf-md-doctor () (list :required nil :optional (list (list "typeset-native" nil "Run M-x etaf-install-native."))))\n'
            "(provide 'etaf-md)\n")
        (src / "native/manifest.json").write_text(json.dumps({
            "schema": 1,
            "package": "etaf-md",
            "modules": [{
                "name": "etaf-md-typeset-native",
                "version": "1",
                "description": "Fixture native renderer",
                "platforms": {
                    platform_key: {
                        "file": filename,
                        "urls": urls or [f"https://etaf.top/native/etaf-md/1/{filename}"],
                        "sha256": sha,
                        "size": len(binary_bytes),
                    }
                },
            }],
        }, indent=2) + "\n")
        if self.archive.exists():
            shutil.rmtree(self.archive)
        command = [sys.executable, str(ROOT / "scripts/package_archive.py"), "build",
                   "--directory", str(self.archive)]
        for source in sorted(self.sources.iterdir()):
            command.extend(["--package", f"{source.name}={source}"])
        command.extend(["--resource", "etaf-md=native/manifest.json"])
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        return filename, sha

    def test_install_native_downloads_over_http_verifies_caches_and_survives_upgrade(self):
        import functools
        from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
        import threading

        native_root = self.base / "native-server"
        payload = b"verified-prebuilt-native-module-bytes-v1"
        filename, sha = self._add_native_etaf_md_fixture(payload)
        served_file = native_root / "etaf-md" / "1" / filename
        served_file.parent.mkdir(parents=True)
        served_file.write_bytes(payload)

        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0),
                                     functools.partial(QuietHandler, directory=str(native_root)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join(timeout=5)))
        native_url = f"http://127.0.0.1:{server.server_port}"
        cache_dir = self.base / "native-cache"

        self.run_lisp(f"""
(setq etaf-install-auto-native nil
      etaf-install-native-directory {json.dumps(str(cache_dir))}
      etaf-install-native-url {json.dumps(native_url)}
      etaf-install--native-platform-override "darwin-arm64")
(etaf-install 'etaf-md t)
(let ((before (etaf-install-status 'etaf-md)))
  (unless (eq (plist-get before :native) 'available)
    (error "Expected native available before download: %S" before))
  (unless (equal (plist-get before :runtime) "Ready · native: n")
    (error "Wrong runtime label before download: %S" before)))
(let (loaded-paths)
  (cl-letf (((symbol-function 'module-load) (lambda (path) (push path loaded-paths) t)))
    (let ((report (etaf-install-native 'etaf-md)))
      (unless (equal (plist-get report :platform) "darwin-arm64")
        (error "Wrong platform in report: %S" report))
      (unless (= 1 (length (plist-get report :installed)))
        (error "Expected 1 installed native module: %S" report))
      (unless (= 1 (length loaded-paths))
        (error "Installed native module was not activated")))
    ;; Second call hits the verified cache without re-downloading.
    (let ((second (etaf-install-native 'etaf-md)))
      (unless (null (plist-get second :installed))
        (error "Second install re-downloaded cached binary: %S" second))
      (unless (= 1 (length (plist-get second :skipped)))
        (error "Second install did not report cache hit: %S" second))
      (when (plist-get second :restart)
        (error "Cache hit should not request restart: %S" second)))
    ;; Force re-download of an already-loaded module flags :restart t without reloading.
    (let ((forced (etaf-install-native 'etaf-md t)))
      (unless (= 1 (length (plist-get forced :installed)))
        (error "Force re-install did not download binary: %S" forced))
      (unless (plist-get forced :restart)
        (error "Force re-install of loaded module did not set :restart t: %S" forced))
      (unless (= 1 (length loaded-paths))
        (error "Force re-install must not call module-load again in same Emacs: %S" loaded-paths)))))
(let ((after (etaf-install-status 'etaf-md)))
  (unless (eq (plist-get after :native) 'installed)
    (error "Expected native installed after download: %S" after))
  (unless (equal (plist-get after :runtime) "Ready · native")
    (error "Wrong runtime label after download: %S" after)))
""")
        # Upgrade etaf-md from 0.3.0 -> 0.3.1: cached native binary MUST survive outside elpa/.
        self._add_native_etaf_md_fixture(payload, version="0.3.1")
        self.run_lisp(f"""
(setq etaf-install-native-directory {json.dumps(str(cache_dir))}
      etaf-install-native-url "/nonexistent-offline-native/"
      etaf-install--native-platform-override "darwin-arm64")
(package-initialize)
(etaf-install-update 'etaf-md)
(unless (package-installed-p 'etaf-md '(0 3 1))
  (error "etaf-md did not upgrade to 0.3.1"))
(let ((status (etaf-install-status 'etaf-md)))
  (unless (eq (plist-get status :native) 'installed)
    (error "Cached native binary was lost across package upgrade: %S" status)))
""")

    def test_install_native_rejects_tampered_binary_and_cleans_partial(self):
        native_dir = self.base / "native-local"
        expected = b"authentic-module-bytes"
        filename, _sha = self._add_native_etaf_md_fixture(expected)
        tampered = native_dir / "etaf-md" / "1" / filename
        tampered.parent.mkdir(parents=True)
        tampered.write_bytes(b"corrupted-module-bytes")
        cache_dir = self.base / "native-cache-bad"

        self.run_lisp(f"""
(setq etaf-install-auto-native nil
      etaf-install-native-directory {json.dumps(str(cache_dir))}
      etaf-install-native-url {json.dumps(str(native_dir))}
      etaf-install--native-platform-override "darwin-arm64")
(etaf-install 'etaf-md t)
(let (err-msg)
  (condition-case err
      (etaf-install-native 'etaf-md)
    (user-error (setq err-msg (error-message-string err))))
  (unless (and err-msg (string-match-p "SHA-256 mismatch" err-msg))
    (error "Tampered binary was not rejected with SHA-256 mismatch: %S" err-msg)))
(when (directory-files-recursively {json.dumps(str(cache_dir))} "\\\\.dylib\\\\|\\\\.partial\\\\'")
  (error "Corrupt or partial binary remained in cache"))
""")

    def test_manage_n_key_installs_native_module_and_refreshes_status(self):
        native_dir = self.base / "native-manage"
        payload = b"manage-key-native-module"
        filename, _sha = self._add_native_etaf_md_fixture(payload)
        target = native_dir / "etaf-md" / "1" / filename
        target.parent.mkdir(parents=True)
        target.write_bytes(payload)
        cache_dir = self.base / "native-cache-manage"

        self.run_lisp(f"""
(setq etaf-install-auto-native nil
      etaf-install-native-directory {json.dumps(str(cache_dir))}
      etaf-install-native-url {json.dumps(str(native_dir))}
      etaf-install--native-platform-override "darwin-arm64")
(etaf-install 'etaf-md t)
(etaf-install-manage)
(with-current-buffer "*ETAF Packages*"
  (goto-char (point-min))
  (unless (search-forward "etaf-md" nil t)
    (error "etaf-md missing from manage buffer"))
  (beginning-of-line)
  (unless (string-match-p "Ready · native: n" (buffer-substring (line-beginning-position) (line-end-position)))
    (error "Expected native prompt in manage row"))
  (cl-letf (((symbol-function 'module-load) (lambda (_path) t)))
    (execute-kbd-macro "n"))
  (goto-char (point-min))
  (search-forward "etaf-md")
  (beginning-of-line)
  (unless (string-match-p "Ready · native" (buffer-substring (line-beginning-position) (line-end-position)))
    (error "Manage row did not refresh after installing native module")))
""")

    def test_install_auto_installs_native_modules_including_dependencies(self):
        import hashlib
        # Add etaf native manifest (etaf-video-mpv) AND etaf-video-player depending on etaf,
        # plus etaf-md native manifest, and stage binaries in sibling native/ beside archive.
        mpv_payload = b"prebuilt-etaf-video-mpv-v1"
        mpv_sha = hashlib.sha256(mpv_payload).hexdigest()
        mpv_file = "etaf-video-mpv-v1-darwin-arm64.dylib"
        etaf_src = self.sources / "etaf"
        (etaf_src / "native").mkdir(exist_ok=True)
        (etaf_src / "native/manifest.json").write_text(json.dumps({
            "schema": 1,
            "package": "etaf",
            "modules": [{
                "name": "etaf-video-mpv",
                "version": "1",
                "description": "Fixture mpv module",
                "platforms": {
                    "darwin-arm64": {
                        "file": mpv_file,
                        "urls": [f"https://etaf.top/native/etaf/1/{mpv_file}"],
                        "sha256": mpv_sha,
                        "size": len(mpv_payload),
                    }
                },
            }],
        }, indent=2) + "\n")

        vp_src = self.sources / "etaf-video-player"
        vp_src.mkdir(exist_ok=True)
        (vp_src / "etaf-video-player.el").write_text(
            ";;; etaf-video-player.el --- Video player fixture -*- lexical-binding: t; -*-\n"
            ";; Version: 0.3.0\n"
            ';; Package-Requires: ((emacs "29.1") (etaf "0.1.0"))\n'
            "(require 'etaf)\n"
            "(defun etaf-video-player-open () (interactive))\n"
            "(provide 'etaf-video-player)\n")

        md_payload = b"prebuilt-etaf-md-typeset-v1"
        md_file, _md_sha = self._add_native_etaf_md_fixture(md_payload)

        # Rebuild archive including etaf's native/manifest.json as well.
        shutil.rmtree(self.archive)
        command = [sys.executable, str(ROOT / "scripts/package_archive.py"), "build",
                   "--directory", str(self.archive)]
        for source in sorted(self.sources.iterdir()):
            command.extend(["--package", f"{source.name}={source}"])
        command.extend(["--resource", "etaf-md=native/manifest.json",
                        "--resource", "etaf=native/manifest.json"])
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

        # Stage binaries in sibling directory `native/` beside `self.archive` (auto-discovered!).
        sibling_native = self.archive.parent / "native"
        (sibling_native / "etaf-md" / "1").mkdir(parents=True, exist_ok=True)
        (sibling_native / "etaf-md" / "1" / md_file).write_bytes(md_payload)
        (sibling_native / "etaf" / "1").mkdir(parents=True, exist_ok=True)
        (sibling_native / "etaf" / "1" / mpv_file).write_bytes(mpv_payload)
        cache_dir = self.base / "native-cache-auto"

        # Single `etaf-install` on etaf-video-player auto-fetches transitive dependency etaf's module,
        # and single `etaf-install` on etaf-md auto-fetches etaf-md's module — zero extra commands!
        self.run_lisp(f"""
(setq etaf-install-native-directory {json.dumps(str(cache_dir))}
      etaf-install--native-platform-override "darwin-arm64")
(let (loaded)
  (cl-letf (((symbol-function 'module-load) (lambda (p) (push p loaded) t)))
    (etaf-install 'etaf-video-player t)
    (unless (eq (plist-get (etaf-install-status 'etaf-video-player) :native) 'installed)
      (error "etaf-install did not auto-install transitive etaf native module for etaf-video-player"))
    (unless (cl-some (lambda (p) (string-match-p "etaf-video-mpv" p)) loaded)
      (error "etaf-video-mpv was not activated during etaf-install: %S" loaded))
    (etaf-install 'etaf-md t)
    (unless (eq (plist-get (etaf-install-status 'etaf-md) :native) 'installed)
      (error "etaf-install did not auto-install etaf-md native module"))
    (unless (cl-some (lambda (p) (string-match-p "etaf-md-typeset-native" p)) loaded)
      (error "etaf-md-typeset-native was not activated during etaf-install: %S" loaded))))
""")

        # Upgrade etaf-md with a new native binary digest: etaf-install-update auto-downloads it!
        md_payload_v2 = b"prebuilt-etaf-md-typeset-v2-updated"
        md_file_v2, _ = self._add_native_etaf_md_fixture(md_payload_v2, version="0.3.1")
        (sibling_native / "etaf-md" / "1" / md_file_v2).write_bytes(md_payload_v2)
        self.run_lisp(f"""
(setq etaf-install-native-directory {json.dumps(str(cache_dir))}
      etaf-install--native-platform-override "darwin-arm64")
(package-initialize)
(cl-letf (((symbol-function 'module-load) (lambda (_p) t)))
  (let ((report (etaf-install-update 'etaf-md)))
    (unless (package-installed-p 'etaf-md '(0 3 1))
      (error "etaf-md did not upgrade to 0.3.1"))
    (unless (= 1 (length (plist-get report :native-installed)))
      (error "etaf-install-update did not auto-download updated native binary: %S" report))))
(unless (eq (plist-get (etaf-install-status 'etaf-md) :native) 'installed)
  (error "Updated native binary is not marked installed"))
""")

    def test_install_auto_native_failure_keeps_elisp_working(self):
        native_dir = self.base / "native-broken"
        filename, _sha = self._add_native_etaf_md_fixture(b"authentic-bytes")
        tampered = native_dir / "etaf-md" / "1" / filename
        tampered.parent.mkdir(parents=True)
        tampered.write_bytes(b"corrupted-bytes")
        cache_dir = self.base / "native-cache-resilient"

        # Default etaf-install-auto-native = t: bad native mirror must NOT fail or roll back etaf-md!
        self.run_lisp(f"""
(setq etaf-install-native-directory {json.dumps(str(cache_dir))}
      etaf-install-native-url {json.dumps(str(native_dir))}
      etaf-install--native-platform-override "darwin-arm64")
(etaf-install 'etaf-md t)
(unless (package-installed-p 'etaf-md)
  (error "Optional native download failure rolled back etaf-md installation"))
(unless (featurep 'etaf-md)
  (error "etaf-md failed to load when optional native binary was corrupt"))
(unless (eq (plist-get (etaf-install-status 'etaf-md) :native) 'available)
  (error "Expected native status to remain available for retry"))
(when (and (file-directory-p {json.dumps(str(cache_dir))})
           (directory-files-recursively {json.dumps(str(cache_dir))} "\\\\.dylib\\\\|\\\\.partial\\\\'"))
  (error "Corrupt or partial binary remained in cache after resilient auto-install"))
""")

    def test_manage_system_cli_column_lists_only_manual_cli_tools(self):
        self.run_lisp("""
(let ((etaf-install--package-manager-override 'brew))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (prog &rest _)
               (when (member prog '("node" "python3"))
                 (concat "/usr/local/bin/" prog)))))
    ;; Zero-CLI targets (including prebuilt-native `ekp' and managed-engine `etaf-tanks')
    ;; must have nil :system-cli and show "—" in System CLI.
    (dolist (pkg '(etaf-ui ekp etaf-tanks etaf-db))
      (when (plist-get (etaf-install-status pkg) :system-cli)
        (error "Expected no manual System CLI for %s: %S" pkg (etaf-install-status pkg))))
    ;; `etaf-ncm' lists only manual OS CLIs (node/python3/mpv + optional qrencode),
    ;; never its bundled `backends/netease/' scripts, and works before installation.
    (let* ((ncm (etaf-install-status 'etaf-ncm))
           (cli (plist-get ncm :system-cli)))
      (unless (equal (plist-get cli :missing-required) '(mpv))
        (error "Wrong missing required CLI for etaf-ncm: %S" cli))
      (unless (equal (plist-get cli :install-command) "brew install mpv")
        (error "Wrong install command for etaf-ncm: %S" cli)))
    ;; `etaf-md' lists only optional manual CLIs, never `typeset-native'.
    (let* ((md (etaf-install-status 'etaf-md))
           (cli (plist-get md :system-cli)))
      (when (plist-get cli :required)
        (error "etaf-md should have no required manual CLI: %S" cli))
      (when (assq 'typeset-native (plist-get cli :optional))
        (error "Auto-downloaded native module leaked into System CLI: %S" cli)))
    (etaf-install-manage)
    (with-current-buffer "*ETAF Packages*"
      (let ((cols (mapcar #'car (append tabulated-list-format nil))))
        (unless (member "System CLI" cols)
          (error "Manage table missing System CLI column: %S" cols)))
      (let* ((find-row (lambda (pkg)
                         (goto-char (point-min))
                         (let (entry)
                           (while (and (not entry) (not (eobp)))
                             (if (eq (tabulated-list-get-id) pkg)
                                 (setq entry (tabulated-list-get-entry))
                               (forward-line 1)))
                           entry)))
             (cli-idx (cl-position "System CLI"
                                   (mapcar #'car (append tabulated-list-format nil))
                                   :test #'equal)))
        (unless (equal (substring-no-properties (aref (funcall find-row 'ekp) cli-idx)) "—")
          (error "ekp System CLI cell should be —"))
        (unless (equal (substring-no-properties (aref (funcall find-row 'etaf-tanks) cli-idx)) "—")
          (error "etaf-tanks System CLI cell should be —"))
        (let ((ncm-cell (aref (funcall find-row 'etaf-ncm) cli-idx)))
          (unless (equal (substring-no-properties ncm-cell) "✓ node · ✓ python3 · ✗ mpv")
            (error "Wrong etaf-ncm System CLI cell: %S" (substring-no-properties ncm-cell))))
        (let ((md-cell (substring-no-properties (aref (funcall find-row 'etaf-md) cli-idx))))
          (unless (string-prefix-p "opt: ffmpeg, qrencode" md-cell)
            (error "Wrong etaf-md System CLI cell: %S" md-cell)))
        (let ((exp-cell (substring-no-properties (aref (funcall find-row 'etaf-export) cli-idx))))
          (unless (string-match-p "rsvg-convert" exp-cell)
            (error "Wrong etaf-export System CLI cell: %S" exp-cell)))))))
""")

    def test_platform_package_manager_commands_combine_missing_tools(self):
        self.run_lisp("""
(unless (equal (etaf-install--cli-combined-command '(node python3 mpv) 'brew)
               "brew install node python mpv")
  (error "Wrong brew combined command"))
(unless (equal (etaf-install--cli-combined-command '(node python3 mpv) 'apt)
               "sudo apt install nodejs python3 mpv")
  (error "Wrong apt combined command"))
(unless (equal (etaf-install--cli-combined-command '(node python3 mpv) 'pacman)
               "sudo pacman -S nodejs python mpv")
  (error "Wrong pacman combined command"))
(unless (equal (etaf-install--cli-combined-command '(node python3 mpv) 'dnf)
               "sudo dnf install nodejs python3 mpv")
  (error "Wrong dnf combined command"))
(unless (equal (etaf-install--cli-combined-command '(node mpv) 'winget)
               "winget install OpenJS.NodeJS.LTS && winget install shinchiro.mpv")
  (error "Wrong winget combined command"))
(unless (equal (etaf-install--cli-combined-command '(ffmpeg ffmpeg) 'brew)
               "brew install ffmpeg")
  (error "Duplicate tools were not deduplicated"))
""")

    def test_doctor_works_before_install_and_supports_copy_and_recheck(self):
        self.run_lisp("""
(let ((etaf-install--package-manager-override 'brew)
      (available-bins nil))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (prog &rest _)
               (when (member prog available-bins)
                 (concat "/opt/homebrew/bin/" prog)))))
    (let ((facts (etaf-install-doctor 'etaf-ncm)))
      (when (plist-get facts :ready)
        (error "Uninstalled etaf-ncm reported ready when node/python3/mpv missing"))
      (etaf-install--display-doctor 'etaf-ncm facts))
    (with-current-buffer "*ETAF Installation*"
      (unless (derived-mode-p 'etaf-install--doctor-mode)
        (error "Doctor buffer did not enable etaf-install--doctor-mode"))
      (let ((text (buffer-string)))
        (unless (string-match-p (regexp-quote "brew install node python mpv") text)
          (error "Doctor buffer missing combined brew command: %s" text))
        (unless (string-match-p (regexp-quote "[Copy command (c)]") text)
          (error "Doctor buffer missing Copy command button"))
        (unless (string-match-p (regexp-quote "[Re-check (r)]") text)
          (error "Doctor buffer missing Re-check button")))
      (let ((kill-ring nil))
        (execute-kbd-macro "c")
        (unless (equal (car kill-ring) "brew install node python mpv")
          (error "Pressing c did not copy combined install command: %S" (car kill-ring))))
      ;; Simulate user installing the missing tools and pressing `r'.
      (setq available-bins '("node" "python3" "mpv"))
      (execute-kbd-macro "r")
      (unless (string-match-p "Prerequisites met" (buffer-string))
        (error "Pressing r did not refresh doctor buffer to ready state: %s" (buffer-string))))))
""")

    def test_interactive_install_auto_opens_doctor_guide_when_required_cli_missing(self):
        self.run_lisp("""
;; Interactive `etaf-install' (no-open = nil, noninteractive = nil) must automatically
;; display `*ETAF Installation*' when a required external tool is missing so users
;; cannot miss a vanishing echo-area line.
(let ((noninteractive nil))
  (etaf-install 'etaf-telega nil))
(unless (get-buffer-window "*ETAF Installation*")
  (error "Interactive install did not auto-display *ETAF Installation* when required CLI missing"))
(with-current-buffer "*ETAF Installation*"
  (unless (string-match-p "telega-server-build" (buffer-string))
    (error "Auto-opened doctor buffer missing telega-server remedy")))
;; Pressing RET on an installed package with missing runtime in `*ETAF Packages*'
;; should display `*ETAF Installation*' rather than calling its open command.
(let (opened)
  (cl-letf (((symbol-function 'etaf-telega-open) (lambda () (interactive) (setq opened t))))
    (etaf-install-manage)
    (with-current-buffer "*ETAF Packages*"
      (goto-char (point-min))
      (search-forward "etaf-telega")
      (beginning-of-line)
      (execute-kbd-macro (kbd "RET"))))
  (when opened
    (error "Manage RET opened target despite missing required runtime"))
  (unless (get-buffer-window "*ETAF Installation*")
    (error "Manage RET did not show *ETAF Installation* for missing required runtime")))
""")

    def test_manage_layout_fits_content_adapts_to_width_and_provides_tooltips(self):
        self.run_lisp("""
(etaf-install 'etaf-ui t)
;; 1) Content-driven Runtime width: when only `Ready' and `—' exist, Runtime
;; must stay tight (<= 9 cols) instead of wasting 27 columns of dead space.
(let ((etaf-install--manage-width-override 190))
  (etaf-install-manage)
  (with-current-buffer "*ETAF Packages*"
    (let* ((fmt (append tabulated-list-format nil))
           (run-col (assoc "Runtime" fmt)))
      (unless (and run-col (<= (cadr run-col) 9))
        (error "Runtime column wasted space when only Ready/— exist: %S" run-col)))))

;; 2) When a package with a longer runtime (`telega-server missing') is installed,
;; Runtime expands dynamically to fit it!
(etaf-install 'etaf-telega t)
(let ((etaf-install--manage-width-override 190))
  (etaf-install-manage)
  (with-current-buffer "*ETAF Packages*"
    (let* ((fmt (append tabulated-list-format nil))
           (run-col (assoc "Runtime" fmt)))
      (unless (and run-col (>= (cadr run-col) 21))
        (error "Runtime column did not expand for telega-server missing: %S" run-col)))))

;; 3) Across wide (180), medium (135), compact (105) and narrow (80) viewports:
;; every rendered row must stay strictly inside the viewport width (zero right-edge
;; truncation arrows) while preserving full descriptions, System CLI lists and
;; complete dependency closures on `help-echo' tooltips!
(cl-letf (((symbol-function 'executable-find)
           (lambda (prog &rest _)
             (when (member prog '("node" "python3"))
               (concat "/usr/local/bin/" prog)))))
  (dolist (width '(180 135 105 80))
    (let ((etaf-install--manage-width-override width))
      (etaf-install-manage)
      (with-current-buffer "*ETAF Packages*"
        (dolist (line (split-string (buffer-string) "\n" t))
          (when (> (string-width line) width)
            (error "Row overflowed viewport width %d (got %d): %S"
                   width (string-width line) line)))
        (let* ((find-row (lambda (pkg)
                           (goto-char (point-min))
                           (let (entry)
                             (while (and (not entry) (not (eobp)))
                               (if (eq (tabulated-list-get-id) pkg)
                                   (setq entry (tabulated-list-get-entry))
                                 (forward-line 1)))
                             entry)))
               (ui-row (funcall find-row 'etaf-ui))
               (ncm-row (funcall find-row 'etaf-ncm))
               (trans-row (funcall find-row 'etaf-translate)))
          ;; Target tooltip ALWAYS holds full description even when compacted.
          (let ((tip (get-text-property 0 'help-echo (aref trans-row 1))))
            (unless (and (stringp tip)
                         (string-match-p "Immersive page translation extension" tip))
              (error "Target tooltip missing full description at width %d: %S" width tip)))
          ;; System CLI tooltip ALWAYS holds all tools and missing status.
          (let ((tip (get-text-property 0 'help-echo (aref ncm-row 6))))
            (unless (and (stringp tip)
                         (string-match-p "mpv" tip)
                         (string-match-p "node" tip))
              (error "System CLI tooltip incomplete at width %d: %S" width tip)))
          ;; On narrow widths, missing `✗ mpv' must stay visible ahead of `+N'.
          (when (<= width 105)
            (let ((cell (substring-no-properties (aref ncm-row 6))))
              (unless (string-match-p "✗ mpv" cell)
                (error "Missing CLI hidden behind +N at width %d: %S" width cell))))
          ;; Depends on tooltip ALWAYS holds full dependency closure.
          (let ((tip (get-text-property 0 'help-echo (aref ui-row 7))))
            (unless (and (stringp tip)
                         (string-match-p "etaf" tip)
                         (string-match-p "ebox" tip)
                         (string-match-p "ecss" tip))
              (error "Depends on tooltip incomplete at width %d: %S" width tip)))))))

  ;; 4) Dynamic resize hook reflows columns cleanly when window width changes.
  (let ((etaf-install--manage-width-override 180))
    (etaf-install-manage))
  (with-current-buffer "*ETAF Packages*"
    (let ((wide-target-w (cadr (aref tabulated-list-format 1))))
      (let ((etaf-install--manage-width-override 90))
        (etaf-install--manage-on-resize (selected-window)))
      (let ((narrow-target-w (cadr (aref tabulated-list-format 1))))
        (unless (< narrow-target-w wide-target-w)
          (error "Resize handler did not shrink Target column (%d -> %d)"
                 wide-target-w narrow-target-w))))))
""")

    def test_install_native_downloads_companion_libraries_before_activating_module(self):
        import functools
        import hashlib
        from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
        import threading

        mod_payload = b"prebuilt-windows-etaf-video-mpv-v2"
        lib_payload = b"prebuilt-windows-libmpv-2-companion-dll"
        mod_sha = hashlib.sha256(mod_payload).hexdigest()
        lib_sha = hashlib.sha256(lib_payload).hexdigest()
        mod_file = "etaf-video-mpv-v2-windows-x86_64.dll"
        lib_file = "libmpv-2-v2-windows-x86_64.dll"

        etaf_src = self.sources / "etaf"
        (etaf_src / "native").mkdir(exist_ok=True)
        (etaf_src / "native/manifest.json").write_text(json.dumps({
            "schema": 1,
            "package": "etaf",
            "modules": [{
                "name": "etaf-video-mpv",
                "version": "2",
                "description": "Fixture Windows GPU mpv module with companion libmpv",
                "platforms": {
                    "windows-x86_64": {
                        "file": mod_file,
                        "urls": [f"https://etaf.top/native/etaf/2/{mod_file}"],
                        "sha256": mod_sha,
                        "size": len(mod_payload),
                        "libraries": [{
                            "name": "libmpv-2.dll",
                            "file": lib_file,
                            "urls": [f"https://etaf.top/native/etaf/2/{lib_file}"],
                            "sha256": lib_sha,
                            "size": len(lib_payload),
                        }],
                    }
                },
            }],
        }, indent=2) + "\n")

        shutil.rmtree(self.archive)
        command = [sys.executable, str(ROOT / "scripts/package_archive.py"), "build",
                   "--directory", str(self.archive)]
        for source in sorted(self.sources.iterdir()):
            command.extend(["--package", f"{source.name}={source}"])
        command.extend(["--resource", "etaf=native/manifest.json"])
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

        native_root = self.base / "native-http-libs"
        (native_root / "etaf" / "2").mkdir(parents=True)
        (native_root / "etaf" / "2" / mod_file).write_bytes(mod_payload)
        (native_root / "etaf" / "2" / lib_file).write_bytes(lib_payload)

        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0),
                                     functools.partial(QuietHandler, directory=str(native_root)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join(timeout=5)))
        native_url = f"http://127.0.0.1:{server.server_port}"
        cache_dir = self.base / "native-cache-libs"

        self.run_lisp(f"""
(setq etaf-install-auto-native nil
      etaf-install-native-directory {json.dumps(str(cache_dir))}
      etaf-install-native-url {json.dumps(native_url)}
      etaf-install--native-platform-override "windows-x86_64")
(etaf-install 'etaf t)
(let ((loaded nil)
      (lib-existed-before-load nil)
      (lib-dest (expand-file-name "etaf/2/libmpv-2.dll" {json.dumps(str(cache_dir))})))
  (cl-letf (((symbol-function 'module-load)
             (lambda (path)
               (setq lib-existed-before-load (file-exists-p lib-dest))
               (push path loaded)
               t)))
    (let ((report (etaf-install-native 'etaf)))
      (unless (= 2 (length (plist-get report :installed)))
        (error "Expected module + companion library installed: %S" report))
      (unless lib-existed-before-load
        (error "Companion libmpv-2.dll was not installed before module-load"))
      (unless (= 1 (length loaded))
        (error "module-load must run only on the dynamic module, not companion libraries: %S" loaded))
      (unless (eq (plist-get (etaf-install-status 'etaf) :native) 'installed)
        (error "Expected native installed status after module + companion library"))
      ;; Removing companion library must drop status back to `available'.
      (delete-file lib-dest)
      (unless (eq (plist-get (etaf-install-status 'etaf) :native) 'available)
        (error "Missing companion library did not revert native status to available"))
      ;; Re-running etaf-install-native fetches only the missing companion library.
      (let ((repair (etaf-install-native 'etaf)))
        (unless (equal (mapcar #'car (plist-get repair :installed)) '("libmpv-2.dll"))
          (error "Repair should re-download only missing companion library: %S" repair))
        (unless (equal (mapcar #'car (plist-get repair :skipped)) '("etaf-video-mpv"))
          (error "Repair should skip already cached dynamic module: %S" repair))))))
""")


    def _bump_core_stack_v2(self):
        """Bump ecss, ebox, etaf and etaf-ui with chained minimum requirements."""
        updates = {
            "ecss": [("Version: 0.1.0", "Version: 0.1.1")],
            "ebox": [("Version: 3.0.0", "Version: 3.0.1"), ('(ecss "0.1.0")', '(ecss "0.1.1")')],
            "etaf": [("Version: 0.2.1", "Version: 0.2.2"), ('(ebox "3.0.0")', '(ebox "3.0.1")')],
            "etaf-ui": [("Version: 0.1.0", "Version: 0.1.1"), ('(etaf "0.2.1")', '(etaf "0.2.2")')],
        }
        for name, pairs in updates.items():
            entry = self.sources / name / f"{name}.el"
            text = entry.read_text()
            for old, new in pairs:
                self.assertIn(old, text, f"Missing {old!r} in {entry}")
                text = text.replace(old, new)
            entry.write_text(text)
        self.build()

    def _elpa_dirs(self):
        return sorted(p.name for p in (self.profile / "elpa").iterdir()
                      if p.is_dir() and p.name != "archives")

    def test_update_all_upgrades_bottom_up_and_prunes_old_versions(self):
        self.run_lisp("(etaf-install 'etaf-ui t)")
        self._bump_core_stack_v2()
        self.run_lisp("""
(package-initialize)
(let ((report (etaf-install-update)))
  (unless (equal (plist-get report :updated)
                 '((ecss . "0.1.1") (ebox . "3.0.1") (etaf . "0.2.2") (etaf-ui . "0.1.1")))
    (error "Expected bottom-up updates for entire stack, got: %S" report))
  (when (plist-get report :failed)
    (error "Unexpected failures: %S" report))
  (dolist (name '(ecss ebox etaf etaf-ui))
    (let ((descs (cdr (assq name package-alist))))
      (unless (= 1 (length descs))
        (error "Stale package-alist entries for %s: %S" name descs))))
  ;; Second update must be a clean no-op with no leftover old versions.
  (let ((second (etaf-install-update)))
    (when (or (plist-get second :updated) (plist-get second :pruned))
      (error "Second update was not a clean no-op: %S" second))))
""")
        self.assertEqual(
            ["ebox-3.0.1", "ecss-0.1.1", "etaf-0.2.2", "etaf-ui-0.1.1"],
            self._elpa_dirs(),
        )

    def test_single_target_update_prunes_transitively_upgraded_dependencies(self):
        self.run_lisp("(etaf-install 'etaf-ui t)")
        self._bump_core_stack_v2()
        self.run_lisp("""
(package-initialize)
(let ((report (etaf-install-update 'etaf-ui)))
  (unless (equal (plist-get report :updated)
                 '((ecss . "0.1.1") (ebox . "3.0.1") (etaf . "0.2.2") (etaf-ui . "0.1.1")))
    (error "Expected transitive dependency updates reported bottom-up, got: %S" report))
  (dolist (name '(ecss ebox etaf etaf-ui))
    (unless (= 1 (length (cdr (assq name package-alist))))
      (error "Stale package-alist entries remain for %s" name))))
""")
        self.assertEqual(
            ["ebox-3.0.1", "ecss-0.1.1", "etaf-0.2.2", "etaf-ui-0.1.1"],
            self._elpa_dirs(),
        )

    def test_single_target_update_upgrades_etaf_dependencies_without_requires_bump(self):
        self.run_lisp("(etaf-install 'etaf-ui t)")
        self.run_lisp("(etaf-install 'ekp t)")
        # Bump ebox, etaf, etaf-ui and unrelated ekp WITHOUT changing Package-Requires.
        for name, old, new in (
            ("ebox", "3.0.0", "3.0.1"),
            ("etaf", "0.2.1", "0.2.2"),
            ("etaf-ui", "0.1.0", "0.1.1"),
            ("ekp", "1.0.0", "1.0.1"),
        ):
            entry = self.sources / name / f"{name}.el"
            entry.write_text(entry.read_text().replace(f"Version: {old}", f"Version: {new}"))
        self.build()
        self.run_lisp("""
(package-initialize)
(let ((report (etaf-install-update 'etaf-ui)))
  (unless (equal (plist-get report :updated)
                 '((ebox . "3.0.1") (etaf . "0.2.2") (etaf-ui . "0.1.1")))
    (error "Expected ETAF dependency closure updated bottom-up without requires bump, got: %S" report))
  (dolist (name '(ebox etaf etaf-ui))
    (unless (= 1 (length (cdr (assq name package-alist))))
      (error "Stale package-alist entries remain for %s" name)))
  (when (package-installed-p 'ekp '(1 0 1))
    (error "Unrelated sibling ETAF target ekp should not be upgraded when updating etaf-ui")))
""")
        # Even when etaf-ui itself is already latest, updating etaf-ui still upgrades outdated ETAF deps.
        ebox_entry = self.sources / "ebox" / "ebox.el"
        ebox_entry.write_text(ebox_entry.read_text().replace("Version: 3.0.1", "Version: 3.0.2"))
        self.build()
        self.run_lisp("""
(package-initialize)
(let ((report (etaf-install-update 'etaf-ui)))
  (unless (equal (plist-get report :updated) '((ebox . "3.0.2")))
    (error "Expected outdated dependency ebox upgraded when target is current, got: %S" report))
  (unless (= 1 (length (cdr (assq 'ebox package-alist))))
    (error "Stale package-alist entry remains for ebox")))
""")
        self.assertEqual(
            ["ebox-3.0.2", "ecss-0.1.0", "ekp-1.0.0", "etaf-0.2.2", "etaf-ui-0.1.1"],
            self._elpa_dirs(),
        )

    def test_installing_new_target_prunes_superseded_deps_and_spares_unrelated_packages(self):
        self.run_lisp("(etaf-install 'etaf t)")
        # Simulate an unrelated third-party package that has two versions in elpa/.
        elpa = self.profile / "elpa"
        for ver in ("1.0", "2.0"):
            d = elpa / f"unrelated-{ver}"
            d.mkdir(parents=True)
            (d / "unrelated-pkg.el").write_text(
                f'(define-package "unrelated" "{ver}" "Third-party" nil)\n'
            )
            (d / "unrelated.el").write_text(f"(provide 'unrelated)\n")
        self._bump_core_stack_v2()
        self.run_lisp("""
(package-initialize)
(etaf-install 'etaf-ui t)
(dolist (name '(ecss ebox etaf etaf-ui))
  (unless (= 1 (length (cdr (assq name package-alist))))
    (error "Stale package-alist entries remain for %s" name)))
""")
        self.assertEqual(
            ["ebox-3.0.1", "ecss-0.1.1", "etaf-0.2.2", "etaf-ui-0.1.1",
             "unrelated-1.0", "unrelated-2.0"],
            self._elpa_dirs(),
        )

    def test_update_cleans_preexisting_obsolete_etaf_versions_and_respects_retention(self):
        self.run_lisp("(etaf-install 'etaf-ui t)")
        self._bump_core_stack_v2()
        # Install v2 via raw package-install so v1 and v2 coexist on disk.
        self.run_lisp("""
(package-initialize)
(package-refresh-contents)
(package-install (cadr (assq 'etaf-ui package-archive-contents)) t)
""")
        self.assertIn("etaf-ui-0.1.0", self._elpa_dirs())
        self.assertIn("etaf-ui-0.1.1", self._elpa_dirs())
        # 1) Emacs 31 `package-retention-policy' = t retains all old versions.
        self.run_lisp("""
(package-initialize)
(when (boundp 'package-retention-policy)
  (let ((package-retention-policy t))
    (let ((report (etaf-install-update)))
      (when (plist-get report :pruned)
        (error "Retained versions should not be pruned: %S" report)))))
""")
        self.assertIn("etaf-ui-0.1.0", self._elpa_dirs())
        self.assertIn("etaf-0.2.1", self._elpa_dirs())
        # 2) `package-load-list' pinning keeps the pinned version while cleaning unpinned ones.
        self.run_lisp("""
(package-initialize)
(let ((package-load-list '((etaf-ui "0.1.0") all)))
  (let ((report (etaf-install-update)))
    (when (member "etaf-ui-0.1.0" (plist-get report :pruned))
      (error "Pinned version should not be pruned: %S" report))
    (unless (member "etaf-0.2.1" (plist-get report :pruned))
      (error "Expected unpinned obsolete etaf-0.2.1 pruned: %S" report))))
""")
        self.assertIn("etaf-ui-0.1.0", self._elpa_dirs())
        self.assertNotIn("etaf-0.2.1", self._elpa_dirs())
        # 3) With default policy and no archive updates, etaf-install-update cleans remaining old ETAF dir.
        self.run_lisp("""
(package-initialize)
(let ((report (etaf-install-update)))
  (when (plist-get report :updated)
    (error "Unexpected updates: %S" report))
  (when (plist-get report :restart)
    (error "Pruning inactive old dirs should not require restart: %S" report))
  (unless (equal (plist-get report :pruned) '("etaf-ui-0.1.0"))
    (error "Expected preexisting obsolete etaf-ui-0.1.0 pruned: %S" report)))
""")
        self.assertEqual(
            ["ebox-3.0.1", "ecss-0.1.1", "etaf-0.2.2", "etaf-ui-0.1.1"],
            self._elpa_dirs(),
        )

    def test_remove_deletes_duplicate_versions_and_refuses_required_dependency(self):
        self.run_lisp("(etaf-install 'etaf-ui t)")
        self._bump_core_stack_v2()
        # Leave both v1 and v2 on disk for etaf and etaf-ui.
        self.run_lisp("""
(package-initialize)
(package-refresh-contents)
(package-install (cadr (assq 'etaf-ui package-archive-contents)) t)
""")
        self.run_lisp("""
(package-initialize)
;; Removing etaf while etaf-ui requires it must refuse without deleting anything.
(let (refused)
  (condition-case err
      (etaf-install-remove 'etaf t)
    (user-error (setq refused (string-match-p "etaf-ui" (error-message-string err)))))
  (unless refused (error "Expected removal of required dependency etaf to be refused")))
(unless (= 2 (length (cdr (assq 'etaf package-alist))))
  (error "Refused remove should not alter etaf descriptors"))
;; Removing leaf etaf-ui must remove BOTH duplicate versions completely.
(etaf-install-remove 'etaf-ui t)
(when (package-installed-p 'etaf-ui)
  (error "etaf-ui remained installed after remove"))
(when (assq 'etaf-ui package-alist)
  (error "Stale etaf-ui entry remained in package-alist"))
""")
        dirs = self._elpa_dirs()
        self.assertFalse(any(d.startswith("etaf-ui-") for d in dirs), dirs)
        self.assertIn("etaf-0.2.1", dirs)
        self.assertIn("etaf-0.2.2", dirs)

    def test_private_helpers_and_modes_stay_out_of_mx(self):
        self.run_lisp("""
(let (public-cmds private-cmds)
  (mapatoms
   (lambda (sym)
     (let ((name (symbol-name sym)))
       (when (and (commandp sym)
                  (or (string= name "etaf-install")
                      (string-prefix-p "etaf-install-" name)))
         (if (string-prefix-p "etaf-install--" name)
             (push sym private-cmds)
           (push sym public-cmds))))))
  (when private-cmds
    (error "Private etaf-install commands leaked into M-x: %S"
           (sort private-cmds #'string<)))
  (let ((expected '(etaf-install etaf-install-doctor etaf-install-manage
                    etaf-install-native etaf-install-remove etaf-install-update))
        (actual (sort public-cmds #'string<)))
    (unless (equal actual expected)
      (error "Unexpected public M-x commands: expected=%S actual=%S"
             expected actual))))
""")

    def test_dynamic_manifest_catalog_discovers_new_target_and_system_tools(self):
        # Publish a brand-new package NOT hardcoded in etaf-install--targets or
        # etaf-install--system-tools, declaring it only in manifest.json catalog.
        new_src = self.sources / "etaf-dynamic"
        new_src.mkdir()
        (new_src / "etaf-dynamic.el").write_text(
            ";;; -*- lexical-binding: t; -*-\n"
            ";;; etaf-dynamic.el --- Dynamic catalog target\n\n"
            ";; Version: 0.1.0\n"
            ";; Package-Requires: ((emacs \"29.1\"))\n\n"
            ";;; Code:\n"
            "(defun etaf-dynamic-open () (interactive) 'opened)\n"
            "(provide 'etaf-dynamic)\n",
            encoding="utf-8",
        )
        self.build()
        manifest_path = self.archive / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["catalog"] = {
            "etaf-dynamic": {
                "group": "application",
                "label": "Dynamic app from manifest",
                "open": "etaf-dynamic-open",
                "capabilities": [],
                "system_tools": {
                    "required": ["ffmpeg"],
                    "optional": ["rg"],
                },
            }
        }
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        verify = subprocess.run(
            [sys.executable, str(ROOT / "scripts/package_archive.py"), "verify",
             "--directory", str(self.archive)],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(0, verify.returncode, verify.stdout + verify.stderr)
        self.run_lisp("""
(when (assq 'etaf-dynamic etaf-install--targets)
  (error "etaf-dynamic must not be hardcoded in etaf-install--targets"))
(let ((target (etaf-install--target 'etaf-dynamic)))
  (unless (equal (nth 1 target) "Dynamic app from manifest")
    (error "Wrong dynamic label: %S" target))
  (unless (eq (nth 2 target) 'application)
    (error "Wrong dynamic group: %S" target))
  (unless (eq (nth 3 target) 'etaf-dynamic-open)
    (error "Wrong dynamic open command: %S" target)))
(let ((cli (etaf-install--system-cli-summary 'etaf-dynamic)))
  (unless (assq 'ffmpeg (plist-get cli :required))
    (error "Missing dynamic required CLI ffmpeg: %S" cli))
  (unless (assq 'rg (plist-get cli :optional))
    (error "Missing dynamic optional CLI rg: %S" cli)))
(etaf-install 'etaf-dynamic t)
(unless (package-installed-p 'etaf-dynamic)
  (error "etaf-dynamic failed to install via dynamic catalog"))
""")


if __name__ == "__main__":
    unittest.main()
