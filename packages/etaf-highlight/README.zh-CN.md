# etaf-highlight

[English README](README.md)

`etaf-highlight` 是基于 `etaf-ext` 公共 API 构建的独立通用划词高亮与持久化批注扩展，可在任意已挂载的 ETAF 应用中使用。

## 核心能力

- 字符级无损高亮（暖黄 / 翠绿 / 晴蓝 / 浅绯），自动适配亮/暗 Emacs 主题对比度。
- 支持为高亮段落挂载伴生批注卡片（`etaf-ext-companion`），内联提供删除按钮。
- 按页面 `:uri`（或缓冲区名）自动存入 `etaf-ext` 独立 SQLite 空间，重开页面自动按文本锚点还原。
- 浮窗高亮列表（`C-c C-e h l`），支持一键滚动定位与删除。
- 与 `etaf-translate` 双语译文、`etaf-hints` 快捷跳转和 `etaf-devtools` 在同一段落和平共存。

## 快速上手

```elisp
(require 'etaf-ext)
(require 'etaf-highlight)
(etaf-ext-mode 1)
```

在任意 ETAF 页面按 `C-c C-e h h` 高亮选区/段落，`C-c C-e h n` 添加批注高亮，`C-c C-e h d` 清除当前段落高亮，`C-c C-e h l` 打开本页高亮清单（也可经 `M-x etaf-ext-command-palette` 检索执行，或在 `M-x etaf-ext-manage` 中自助绑定直达快捷键）。

## 文档

- 公共 API 清单：[etaf-highlight.el](etaf-highlight.el)。
- 使用手册：[docs/manual.md](docs/manual.md)。
- 变更日志：[CHANGELOG.md](CHANGELOG.md)。

## 校验

```sh
make check
```
