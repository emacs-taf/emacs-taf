# etaf-translate

[English](README.md)

面向任意已挂载 [ETAF](https://github.com/emacs-taf/etaf) View 的零侵入沉浸式页面翻译扩展，同时为任意 Emacs 缓冲区提供轻量纯净的光标/选区快译。

## 核心能力

- **原生基于 `etaf-ext` 构建**：直接注册进 [etaf-ext](https://github.com/emacs-taf/etaf-ext) 扩展引擎，共享 Host 树快照缓存、多扩展原子表现层（`companion-inside`、`companion-after`、`override`）、统一 mode-line 徽章、单页纯净模式、异常熔断与 `M-x etaf-ext-manage` 管理中心。
- **5 个正交命令**：`etaf-translate-toggle`、`etaf-translate-panel`、`etaf-translate-at-point`、`etaf-translate-paragraph` 与 `etaf-translate-mode-cycle`；无需额外开关全局 minor-mode，`require` 即就绪。
- **两种模式与三种双语样式**：双语对照（`left-bar` 细线 / `muted` 极简 / `tinted` 轻底）与原地译文替换（带 `:help-echo` 悬停回看原文）；利用缓存 0 延迟瞬切。
- **极简浮动界面**：6 行右上角浮动控制面板（`etaf-translate-panel`，严格跟随 `:theme 'auto`，面板修改的模式/样式/语言/引擎自动稀疏持久化到 `etaf-translate-state-file`，切缓冲区自动收起）、纯译文自适应快译浮窗（`etaf-translate-at-point`，不重复原文，高度随内容自适应至窗口 60%，超长支持滚轮与 `j`/`k` 滚动）以及保留原主题的 Mode-line 进度指示（`译[54/155]` / `译✓` / `译!N`）。
- **结构与公式感知提取**：按段落聚合行内文本，通过 `<N>...</N>` 保留可点击链接与粗斜体样式，通过原子占位符 `⟦cN⟧` 原样保护行内代码、脚注以及 LaTeX 数学公式（`$...$`、`$$...$$`、`\(...\)`、`\[...\]`，不误伤 `$100` 等货币写法），自动跳过代码块、界面控件与目标语种正文，并支持 `:translate 'no`。
- **可视区优先流式调度与持久化 L2 缓存**：基于实时几何同时感知 Emacs 窗口与 `:overflow 'scroll` 容器滚动，支持 SSE 逐段流式返回与滚动即时重排，内置自动重试与回退引擎链；默认启用 Emacs 29+ 原生 SQLite WAL 持久化 L2 缓存（含 TTL 与 LRU 淘汰），并持久化站点记忆规则与术语表。
- **多引擎与内置整段 Provider**：内置 `openai`（OpenAI / DeepSeek / Ollama SSE）、`anthropic`（Claude Messages SSE）、`deepl`（Free/Pro 批量）、`google`（免 Key HTTP）、`command` 与 `function` 引擎；支持命名 Profile、页面标题上下文与风格预设（`technical` / `academic` / `literary` / `concise`），并内置 `maillist` 与 `etaf-reader` 逻辑整段 Provider 及 `etaf-web` 等全生态适配规则。

## 运行环境

- Emacs 29.1 或更高版本（内置 SQLite 时自动启用持久化 L2 缓存，否则优雅降级为内存 L1 缓存）
- `etaf`（>= 0.3.6）、`etaf-ui`（>= 0.3.4）、`etaf-posframe`（>= 0.3.0）与 `etaf-ext`（>= 0.1.0）
- 使用内置 HTTP 引擎（`openai` / `anthropic` / `deepl` / `google`）时需确保 `exec-path` 中有 `curl`

## 快速开始

```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-translate)

(setq etaf-translate-target-lang "zh-CN"
      etaf-translate-default-engine 'openai
      etaf-translate-openai-endpoint "https://api.deepseek.com/v1/chat/completions"
      etaf-translate-openai-model "deepseek-chat"
      etaf-translate-openai-api-key (lambda () (getenv "DEEPSEEK_API_KEY")))

;; 在任意 ETAF 缓冲区中一键开关翻译：
(etaf-translate-toggle)
;; 打开 / 收起右上角浮动控制面板：
(etaf-translate-panel)
;; 在任意 Emacs 缓冲区中快译选区或光标处单词：
(etaf-translate-at-point)
```

## 文档

- 公共 API 清单：[etaf-translate.el](etaf-translate.el)
- 使用与扩展手册：[docs/manual.md](docs/manual.md)
- 维护者架构文档：[docs/architecture.md](docs/architecture.md)

## 验证

```sh
make -C packages/etaf-translate check
```
