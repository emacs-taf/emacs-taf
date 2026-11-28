# etaf-export

[English](README.md)

`etaf-export` 是基于 `etaf-ext` 公开扩展引擎构建的独立拓展，可将任意已挂载的 ETAF 渲染页面在零浏览器环境下实时预览并导出为真矢量 PDF 或 SVG。

## 核心能力

- **所见即所得、零浏览器真矢量出片**：直接采集已挂载 ETAF buffer 的真实像素排版（标题层级、颜色、底色块、盒边框、上下划线、像素对齐表格、内联图标、位图以及 Mermaid / MathJax 原生 SVG），通过 `rsvg-convert -f pdf` 输出多页矢量 PDF，文字可选可复制，图表保持矢量清晰。
- **实时矢量导出预览工作台**：`M-x etaf-export` 直接打开左右分栏的实时打印预览工作台，无需任何外部程序即可逐页核查 A4 / Letter / 单页长图分页、亮色打印映射、页边距与页脚页码效果，调参即时更新并一键导出。
- **灵活分页与智能断页**：支持 A4 自动分页（`a4`，默认）、US Letter 分页（`letter`）与单页无缝长 PDF（`single`），分页时自动避免截断跨行图表和遗留孤立标题，可选显示页脚页码。
- **当前配色与强制亮色打印**：默认跟随当前页面主题（`current`），也支持一键强制亮色打印映射（`light`），在不改动原 Emacs buffer 的前提下把暗色页面与内嵌 SVG 图表映射为清晰的白底打印版。

## 环境要求

- Emacs 29.1+，已加载 `etaf`、`etaf-ui` 与 `etaf-ext`。
- 导出 PDF 需要 `rsvg-convert`（macOS 可执行 `brew install librsvg`，Linux 安装 `librsvg2-bin`）；实时导出预览与导出 SVG 无需任何外部程序。可调用 `(etaf-export-doctor)` 检查环境。

## 快速开始

```elisp
(require 'etaf-ext)
(require 'etaf-export)
(etaf-ext-mode 1)
```

在任意已挂载的 ETAF 页面中直接调用公开命令即可使用：

- `M-x etaf-export`：打开实时矢量导出预览工作台。
- `M-x etaf-export-pdf`：导出当前页面为矢量 PDF。
- `M-x etaf-export-svg`：导出当前页面为矢量 SVG 文件。

开启 `etaf-ext-mode` 后，也可在 ETAF 页面内通过 `M-x etaf-ext-command-palette` 模糊搜索，或通过可配置的 `etaf-ext` 两级命令分发器（`etaf-ext-dispatch`，默认前缀 `etaf-ext-key-prefix` 为 `C-c C-e`，本扩展默认建议字母 `x`，子键 `x` / `p` / `s`）调用；前缀与直达快捷键均可在 `M-x etaf-ext-manage` 或经 `etaf-ext-set-key` 自由修改或关闭。

## 文档与验收

- 公开接口清单见 [etaf-export.el](etaf-export.el) 头部 Commentary。
- 使用手册见 [docs/manual.md](docs/manual.md)，变更记录见 [CHANGELOG.md](CHANGELOG.md)。

```sh
make check
```
