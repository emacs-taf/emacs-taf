# etaf-install

[English](README.md)

Emacs TAF 生态的官方安装入口。`etaf-install` 构建在 Emacs 内置 `package.el` 之上，不是第二套包管理器；依赖解析、autoload、本地字节编译、更新和卸载仍全部归 `package.el` 管理。

## 能力

- 启用后自动注册官方 ETAF 包归档（`https://etaf.top/packages/`），不改写用户配置文件，也不放宽 TLS 校验策略。
- 优先从归档 `manifest.json` 的 `catalog` 动态读取框架、扩展、应用与游戏目标，离线或旧归档自动回退内置目录。
- 安装或更新目标时，按依赖闭包自动下载、校验 SHA-256、缓存（`~/.cache/emacs-taf/native/`）并激活声明的预编译原生动态模块（可通过 `etaf-install-auto-native` 关闭）。
- 提供 `M-x etaf-install-manage` 生命周期管理面板（`i` 安装、`n` 原生模块、`u` 更新、`U` 全部更新、`d` 卸载、`RET` 打开、`?` 诊断、`g` 刷新）以及 `M-x etaf-install-doctor` 能力检查与合并系统命令生成。

## 前置条件

- Emacs 29.1 或更新版本。

## 快速开始

在 Emacs 中执行一次以下代码，随后选择安装目标（默认打开 `etaf-ui` 组件画廊）：

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

后续直接运行 `M-x etaf-install`、`M-x etaf-install-manage`、`M-x etaf-install-doctor`、`M-x etaf-install-native`、`M-x etaf-install-update` 或 `M-x etaf-install-remove`。

## 用 `use-package` 声明式配置

`https://etaf.top/packages/` 是标准 ELPA 包归档，可以直接在 `init.el` 中用 Emacs 29+ 内置的 `use-package` 配合 `etaf-install-ensure` 做持久化声明管理：

```elisp
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/") t)
(package-initialize)

;; 首次启动自动安装缺失目标及其预编译原生模块；
;; 全部已装时零联网、不拖慢启动。
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

后续升级只需运行 `M-x etaf-install-update`（或在 `M-x etaf-install-manage` 里按 `U`），会自动按依赖闭包自底向上升级，并同步预编译原生模块。

## 文档

- 公共 API 清单：见 [etaf-install.el](etaf-install.el) 头部 Commentary
- 安装参考：<https://etaf.top/zh-cn/introduction/#安装>
- 变更记录：[CHANGELOG.md](CHANGELOG.md)

## 验证

在单仓根目录运行：

```sh
make -C core/packages/etaf-install check
python3 -m unittest tests/tools/test_install.py
```
