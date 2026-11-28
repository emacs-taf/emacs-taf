# etaf-devtools

[English](README.md)

面向任意已挂载 [ETAF](https://github.com/emacs-taf/etaf) 应用的交互式运行时调试与性能分析工具箱，严格构建于 ETAF 公开内省接口之上，对被调试应用零侵入。

## 核心能力

- **组件与宿主统一树视图**：一键切换“仅组件”与“完整 Host 树”，支持按组件名、`#id`、`.class`、`:ref` 或文本过滤；支持直跳 `(etaf-define-component ...)` 源码（`g`）、滚入视口高亮定位（`v`）与触发点击回调（`a`）。
- **纯文本四层盒模型与按需 ECSS 溯源**：直观查看 `margin`、`border`、`padding`、`content` 实际度量、布局模式、滚动与裁剪状态、命中规则与优先级、被覆盖声明删除线、色块预览以及 WCAG 对比度检验，仅在检视单个节点时按需计算，热路径零开销。
- **响应式状态与原地修改 `etaf-ref`**：查看组件 props、`:bindings` 命名变量（自动识别 `ref` / `computed` / `resource` / `data-controller`）、依赖上下游、Context 与 local-ref，并支持安全原地改写可写 `etaf-ref` 即时验证界面变化。
- **零污染元素拾取与重绘热区闪框**：通过精确行区间只读 Overlay 高亮选中节点，在多栏 Flex / Grid 中不串栏、不触发 Ebox flush；支持鼠标与纯键盘双模拾取（`[`/`]` 上下切换父子层级）以及增量/全量重绘实时闪框。
- **Flush 与深度性能剖析**：实时记录 Flush / Commit 流并用 Braille 曲线展现趋势，可按需开启 `etaf-performance` 阶段耗时与 GC 分析。
- **焦点、区域与键位诊断 + 一键视口验收**：查看实时 Tab 停靠顺序并点击测试聚焦、核查 `:region` 与 `:keys` 作用域，内置宽屏/常规/窄屏/矮屏一键 `etaf-runtime-refit` 验收工具。
- **默认右侧停靠且支持浮窗切换**：默认停靠在右侧 side-window 并完整保留宿主原生 mode-line，按 `d` 可在右侧停靠、底部停靠与可拖拽 `etaf-posframe` 浮窗之间切换；配色动态跟随当前 Emacs 主题，绝不缩字。

## 快速开始

```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-devtools)

;; 在当前 ETAF 应用右侧打开 DevTools：
(etaf-devtools)
;; 启动元素拾取器（支持鼠标点击或键盘导航）：
(etaf-devtools-inspect)
;; 开关重绘热区闪框：
(etaf-devtools-highlight-updates)
;; 切换右侧停靠 / 底部停靠 / 浮动 Posframe：
(etaf-devtools-toggle-dock)
;; 关闭并清理全部 overlay、定时器与钩子：
(etaf-devtools-close)
```

## 文档

- 公开接口清单：[etaf-devtools.el](etaf-devtools.el)
- 使用手册：[docs/manual.md](docs/manual.md)
- 维护者架构：[docs/architecture.md](docs/architecture.md)

## 验证

```sh
make -C core/packages/etaf-devtools check
```
