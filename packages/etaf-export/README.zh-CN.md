# etaf-export

[English](README.md)

`etaf-export` 是基于 `etaf-ext` 公开扩展引擎构建的独立拓展，可将任意已挂载的 ETAF 渲染页面在零浏览器环境下导出为真矢量 PDF 或 SVG。

## 核心能力

- **所见即所得、零浏览器真矢量出片**：直接采集已挂载 ETAF buffer 的渲染结果（标题层级、颜色、底色块、盒边框、下划线/上划线、像素对齐表格、位图以及 Mermaid / MathJax 原生 SVG），通过 `rsvg-convert -f pdf` 输出多页矢量 PDF，文字可选可复制，图表保持矢量清晰。
- **灵活分页与智能断页**：支持 A4 自动分页（`a4`，默认）、US Letter 分页（`letter`）与单页无缝长 PDF（`single`），分页时自动避免截断跨行图表和遗留孤立标题，可选显示页脚页码。
- **当前配色与强制亮色打印**：默认跟随当前页面主题（`current`），也支持一键强制亮色打印映射（`light`），在不改动原 Emacs buffer 的前提下把暗色页面映射为清晰的白底打印版。
- **任意 ETAF 页面通用**：作为独立 `etaf-ext` 拓展，可无缝挂载到 `etaf-md`、`etaf-org`、`etaf-manual`、`etaf-agenda` 等任意已挂载 ETAF 视图，并提供浮动设置面板。

## 环境要求

- Emacs 29.1+，已加载 `etaf`、`etaf-ui` 与 `etaf-ext`。
- 导出 PDF 需要 `rsvg-convert`（macOS 可执行 `brew install librsvg`，Linux 安装 `librsvg2-bin`）；导出 SVG 无需任何外部程序。可调用 `(etaf-export-doctor)` 检查环境。

## 快速开始

```elisp
(require 'etaf-ext)
(require 'etaf-export)
(etaf-ext-mode 1)
```

在任意已挂载的 ETAF 页面中按以下快捷键即可导出：

- `C-c C-e x p`（或 `M-x etaf-export-current-pdf`）：按当前配色导出 A4 分页 PDF。
- `C-c C-e x l`：导出单页无缝长 PDF。
- `C-c C-e x L`：强制亮色打印配色导出 A4 PDF。
- `C-c C-e x s`：导出矢量 SVG 文件。
- `C-c C-e x x`（或 `M-x etaf-export-popup`）：打开浮动导出设置面板。

## 文档与验收

- 公开接口清单见 [etaf-export.el](etaf-export.el) 头部 Commentary。
- 使用手册见 [docs/manual.md](docs/manual.md)，变更记录见 [CHANGELOG.md](CHANGELOG.md)。

```sh
make check
```
