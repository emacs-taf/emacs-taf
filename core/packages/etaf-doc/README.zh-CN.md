# etaf-doc

[English](README.md)

[ETAF](https://github.com/emacs-taf/etaf) 共享文档基础设施包：Markdown 解析、代码语法高亮、块级视图渲染、有界磁盘缓存、异步 QR / Mermaid / MathJax 排版、统一文档节点协议与通用排版组件。

## 前置条件

- Emacs 29.1 或更高版本
- `etaf`、`etaf-ui`、`ebox`、`ecss`

## 安装

通过 `M-x etaf-install` 安装 `etaf-doc`，或从 [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) 源码检出加载：

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui" "etaf-doc"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(require 'etaf-doc)
```

## 文档

- 公开 API 清单：[etaf-doc.el](etaf-doc.el) Commentary
- 架构说明：[docs/architecture.md](docs/architecture.md)
- 变更记录：[CHANGELOG.md](CHANGELOG.md)

## 验证

```sh
make -C core/packages/etaf-doc check
```
