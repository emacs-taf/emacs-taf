# etaf-install

[中文](README.zh-CN.md)

The official installation entry for the Emacs TAF ecosystem. `etaf-install` is a thin layer over Emacs's built-in `package.el`—not a second package manager. `package.el` continues to own dependency resolution, autoloads, local byte compilation, updates and removal.

## Capabilities

- Registers the official ETAF package archive (`https://etaf.top/packages/`) automatically when activated, without modifying user init files or TLS policy.
- Discovers available framework, extension, application and game targets dynamically from the archive's `manifest.json` catalog, with a built-in fallback for offline use.
- Automatically downloads, SHA-256 verifies, caches (`~/.cache/emacs-taf/native/`) and activates prebuilt native dynamic modules declared by installed packages (opt out via `etaf-install-auto-native`).
- Provides `M-x etaf-install-manage` for lifecycle management (`i` install, `n` native, `u` update, `U` update all, `d` remove, `RET` open, `?` doctor, `g` refresh) and `M-x etaf-install-doctor` for capability diagnostics and combined OS package-manager install commands.

## Prerequisites

- Emacs 29.1 or newer.

## Quick start

Evaluate once in Emacs, then pick a target (the `etaf-ui` component gallery is the default):

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

Afterward, run `M-x etaf-install`, `M-x etaf-install-manage`, `M-x etaf-install-doctor`, `M-x etaf-install-native`, `M-x etaf-install-update`, or `M-x etaf-install-remove`.

## Declarative configuration (`use-package`)

Because `https://etaf.top/packages/` is a standard ELPA archive, you can declare ETAF packages directly in `init.el` with Emacs's built-in `use-package` (Emacs 29+) and `etaf-install-ensure`:

```elisp
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/") t)
(package-initialize)

;; Install missing ETAF targets and their prebuilt native modules once.
;; Performs zero network requests on subsequent startups when all are installed.
(use-package etaf-install
  :ensure t
  :pin etaf
  :config
  (etaf-install-ensure '(etaf-md etaf-org etaf-ncm etaf-xiangqi)))

(use-package etaf-md
  :ensure t
  :pin etaf
  :commands (etaf-md-open etaf-md-preview)
  :bind (:map markdown-mode-map ("C-c m e" . etaf-md-preview)))
```

When everything is already installed, startup stays completely offline and lazy-loaded. Upgrade cleanly at any time with `M-x etaf-install-update` (or `U` in `M-x etaf-install-manage`), which upgrades ETAF dependency closures bottom-up and syncs prebuilt native modules automatically.

## Documentation

- Public API inventory: Commentary in [etaf-install.el](etaf-install.el)
- Installation reference: <https://etaf.top/introduction/#installation>
- Changelog: [CHANGELOG.md](CHANGELOG.md)

## Checks

From the monorepo root:

```sh
make -C core/packages/etaf-install check
python3 -m unittest tests/tools/test_install.py
```
