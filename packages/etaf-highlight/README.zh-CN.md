# etaf-highlight

[English README](README.md)

`etaf-highlight` 是基于 `etaf-ext` 公共 API 构建的独立通用划词高亮与持久化批注扩展，可在任意已挂载的 ETAF 应用中使用。

## 核心能力

- 字符级无损高亮（暖黄 / 翠绿 / 晴蓝 / 浅绯），自动适配亮/暗 Emacs 主题对比度。
- 支持为高亮段落挂载伴生批注卡片（`etaf-ext-companion`），内联提供删除按钮。
- 按页面 `:uri`（或缓冲区名）自动存入 `etaf-ext` 独立 SQLite 空间，重开页面自动按文本锚点还原。
- 浮窗高亮列表（`etaf-highlight-list`），支持一键滚动定位与删除。
- 与 `etaf-translate` 双语译文、`etaf-hints` 快捷跳转和 `etaf-devtools` 在同一段落和平共存。

## 快速上手

```elisp
(require 'etaf-ext)
(require 'etaf-highlight)
(etaf-ext-mode 1)
```

在任意已挂载的 ETAF 页面中直接调用公开命令即可使用：

- `M-x etaf-highlight-add`：高亮当前选区或光标所在段落（可选颜色与批注）。
- `M-x etaf-highlight-remove`：清除当前段落的高亮。
- `M-x etaf-highlight-list`：打开本页高亮与批注浮窗清单。

开启 `etaf-ext-mode` 后，全部操作（高亮 / 批注 / 清除 / 列表）也可在 ETAF 页面内通过 `M-x etaf-ext-command-palette` 模糊搜索，或通过可配置的 `etaf-ext` 两级命令分发器（`etaf-ext-dispatch`，默认前缀 `etaf-ext-key-prefix` 为 `C-c C-e`，本扩展默认建议字母 `h`，子键 `h` / `n` / `d` / `l`）调用；前缀与直达快捷键均可在 `M-x etaf-ext-manage` 或经 `etaf-ext-set-key` 自由修改或关闭。

## 文档

- 公共 API 清单：[etaf-highlight.el](etaf-highlight.el)。
- 使用手册：[docs/manual.md](docs/manual.md)。
- 变更日志：[CHANGELOG.md](CHANGELOG.md)。

## 校验

```sh
make check
```
