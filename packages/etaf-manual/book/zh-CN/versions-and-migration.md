# 版本与迁移

本手册记录下表这一版本组合。除 EKP 1.0.1 和 Ebox 3.1.0 外都是 1.0 之前的发布线，接口可能随版本变化；每个包的 `CHANGELOG.md` 是用户可见变更的权威清单。本附录给出环境要求，以及需要在既有代码或文件里改动的迁移项。

<!-- index: 版本; 环境要求; 迁移 -->

## 版本

| 包 | 版本 | 配套版本 |
| --- | --- | --- |
| `ecss` | 0.1.0 | Emacs 28.1 |
| `ekp` | 1.0.1 | Emacs 29.1 |
| `ebox` | 3.1.3 | Emacs 29.1、`ecss 0.1.0` |
| `etaf` | 0.3.5 | Emacs 29.1、`ebox 3.1.3`、`ecss 0.1.0` |
| `etaf-ui` | 0.3.4 | Emacs 29.1、`etaf 0.3.5`、`ebox 3.1.3` |
| `etaf-db` | 0.1.0 | Emacs 29.1、`etaf 0.3.5` |
| `etaf-posframe` | 0.3.0 | Emacs 29.1、`etaf 0.3.5`、`etaf-ui 0.3.4`、Posframe 0.9.0 |
| `etaf-manual` | 0.1.12 | Emacs 29.1、`etaf 0.3.5`、`etaf-ui 0.3.4` |

第三列是本版记录的版本组合。每个包在 `Package-Requires` 头里声明它能安装的最低版本，可能更低。

## 环境要求

Emacs 29.1 或更新版本可以运行全部包；ECSS 单独还支持 Emacs 28.1。可选部分见[安装、加载与构建](installation-and-loading.md)：EKP 的 C 模块需要 C 编译器，macOS 彩色 emoji 辅助程序用 `swiftc` 编译，视频播放需要 ffmpeg 程序（`etaf-video-ffmpeg-program`、`etaf-video-ffplay-program` 与 `etaf-video-ffprobe-program`），ETAF DB 需要带 SQLite 支持的 Emacs 构建，EKP 断字读取 `dictionaries/` 下随包发布的字典。

## 迁移说明

- **仓库根的包入口。** 加载源码检出时把仓库根加入 `load-path`，再 require 包入口，例如 `(require 'etaf)`。`lisp/` 下的 feature 模块是内部实现，不是受支持的导入路径；从归档安装的包保持同一目录布局。
- **ECSS 规则文件。** 静态 `.ecss` 文件现在存放不带引号的规则列表。请去掉既有文件外层引号。
- **ECSS Scope 的父参数。** `ecss-scope-create` 的可选父级改用 `:parent PARENT` 传入，不再按位置传参。
- **Runtime generation。** 早先的 generation API 已删除。要观察一次发布是否到达 buffer，比较 `etaf-runtime-revision`，或 `etaf-runtime-flush` 的返回值。
- **Ebox 引擎。** 早先引擎的 canonical input、source builder 与显式更新 API 已删除。保留节点引用：`ebox-node-insert`、`ebox-node-remove`、`ebox-node-move` 与 `ebox-node-replace-children` 改变子节点；`ebox-node-set-text` 与 `ebox-node-set-image` 改变内容；`ebox-node-set-props`、`ebox-node-put`、`ebox-node-set-states` 与 `ebox-node-restyle` 改变属性；`ebox-with-batch` 把工作分组。改为构造或复制一棵保留的根树再挂载，而不是提供整棵输入的替换。
- **数据和解。** 成功状态现在是 `reconciled`，不再是 `projected`；比较 `etaf-data-reconciliation-state` 符号的消费方需要更新。
- **强调色控件。** `etaf-taskbar` 与 `etaf-workspace-bar` 不再接受 `:accent-color`；改为提供带 `:ui-accent` 与 `:ui-accent-soft-bg` 的 Theme。
- **EKP 字典。** 随包的字典清单按文件固定并校验。梵文字典因固定的上游数据没有权威许可声明而被移除；如果文档语言不再被覆盖，请确认断字仍能选到字典。
