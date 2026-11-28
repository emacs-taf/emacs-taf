# ETAF — Emacs 文本应用框架（核心仓）

[English](README.md) · [在线文档](https://etaf.top/zh-cn/) · [Monorepo 主仓](https://github.com/emacs-taf/emacs-taf) · [官方包源](https://etaf.top/packages/)

<!-- BEGIN:GENERATED:core-overview-zh -->
> **只读核心聚合投影仓。** 本仓库由 **[Emacs TAF Monorepo](https://github.com/emacs-taf/emacs-taf)** 的 [`core/`](https://github.com/emacs-taf/emacs-taf/tree/main/core) 目录自动同步生成，汇集全部 17 个已发布的核心框架包、通用扩展、官方安装器与中英双语参考手册（另含 1 个孵化包）。
>
> 提交代码与 Pull Request 请统一前往 **[emacs-taf/emacs-taf](https://github.com/emacs-taf/emacs-taf/pulls)**。
<!-- END:GENERATED:core-overview-zh -->

## 安装（推荐）

在 Emacs 29.1+ 中通过官方 `package.el` 源一键安装任意框架包、扩展、应用或游戏：

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

或克隆本仓库后将 `packages/` 下的子目录加入 `load-path`：

```elisp
(dolist (dir '("ecss" "ekp" "ebox" "etaf" "etaf-ui" "etaf-ext"))
  (add-to-list 'load-path (expand-file-name (concat "packages/" dir) "/path/to/etaf")))
(require 'etaf)
```

## 本仓库包含的包

<!-- BEGIN:GENERATED:core-packages-zh -->
### 核心框架

| 包名 | 职责 |
| --- | --- |
| [`ecss`](packages/ecss) | CSS 级联样式引擎：选择器、优先级、自定义属性与计算样式 |
| [`ekp`](packages/ekp) | Knuth–Plass 段落断行引擎，支持可选预编译 C 动态模块 |
| [`ebox`](packages/ebox) | Box / Flex / Grid 布局、渲染与增量 buffer 发布引擎 |
| [`etaf`](packages/etaf) | 声明式组件、响应式状态、宿主与应用生命周期 |
| [`etaf-media`](packages/etaf-media) | 原生视频播放引擎（`etaf-video`、libmpv 硬件 GPU 层、ffmpeg 与音频伴随） |
| [`etaf-ui`](packages/etaf-ui) | 通用 UI 组件库：按钮、表单、面板、表格、导航与窗口壳 |
| [`etaf-doc`](packages/etaf-doc) | 共享文档基础设施（Markdown、QuickJS Mermaid/MathJax、LRU/二维码缓存、工作区资产、节点协议与书刊组件） |
| [`etaf-gamekit`](packages/etaf-gamekit) | 游戏定义、多实例与 Godot / OpenSpiel 桥接 |
| [`etaf-posframe`](packages/etaf-posframe) | 任意 ETAF View 的浮动子 frame 面板宿主 |
| [`etaf-ext`](packages/etaf-ext) | 通用扩展引擎、生命周期管理与宿主钩子 |
| [`etaf-db`](packages/etaf-db) | ETAF 应用数据存储后端（SQLite） |
| [`etaf-install`](packages/etaf-install) | 官方 `package.el` 安装器、环境体检、预编译原生模块与包管理 |

### 通用扩展

| 扩展名 | 说明 |
| --- | --- |
| [`etaf-hints`](packages/etaf-hints) | Vimium 风格交互目标快速键盘跳转提示 |
| [`etaf-highlight`](packages/etaf-highlight) | 跨 ETAF 视图的持久化高亮与锚定批注 |
| [`etaf-translate`](packages/etaf-translate) | 沉浸式行内与对照翻译扩展 |
| [`etaf-export`](packages/etaf-export) | 无浏览器矢量 SVG 与 PDF 导出扩展 |

### 文档与参考手册

| 包名 | 说明 |
| --- | --- |
| [`etaf-manual`](packages/etaf-manual) | 中英双语 ETAF 参考手册（`M-x etaf-manual-open`）与 `https://etaf.top` 官网源码 |

### 孵化包

| 包名 | 说明 |
| --- | --- |
| [`etaf-devtools`](packages/etaf-devtools) | ETAF buffer 实时检查器、盒模型浮层与目标拾取工具（孵化中） |
<!-- END:GENERATED:core-packages-zh -->

## 参与贡献

全部开发、测试与 CI 均在 **[Emacs TAF Monorepo](https://github.com/emacs-taf/emacs-taf)** 中完成，详见组织级 [CONTRIBUTING.md](https://github.com/emacs-taf/.github/blob/main/CONTRIBUTING.md)。

## 许可证

GNU General Public License v3.0 or later（见 [LICENSE](LICENSE)）。
