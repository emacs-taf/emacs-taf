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


if __name__ == "__main__":
    unittest.main()
