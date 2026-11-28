# etaf-hints

[English README](README.md)

`etaf-hints` 是基于 `etaf-ext` 公共 API 构建的独立 Vimium 风格快捷跳转扩展，可在任意已挂载的 ETAF 应用中使用。

## 核心能力

- 调用 `etaf-hints-start` 在当前视口所有可见的可点击 / 可聚焦控件旁浮现无前缀冲突的字母标签。
- 键入对应字母即可实时筛选并触发语义点击（`etaf-ext-press`）或聚焦（`etaf-ext-focus`），完成后自动清除覆盖层。
- 标签配色自动适配亮 / 暗 Emacs 主题，激活期间在 mode-line 展示 `跳N` 状态徽标。

## 快速上手

```elisp
(require 'etaf-ext)
(require 'etaf-hints)
(etaf-ext-mode 1)
```

在任意已挂载的 ETAF 页面运行 `M-x etaf-hints-start` 显示跳转标签，键入字母直达，按 `Esc` 或 `C-g` 取消。开启 `etaf-ext-mode` 后，也可经 `M-x etaf-ext-command-palette` 或可配置的 `etaf-ext` 分发器（`etaf-ext-dispatch`，默认前缀 `etaf-ext-key-prefix` 为 `C-c C-e`，建议字母 `f`）调用；在默认 `safe` 策略下还会注册受冲突防火墙保护的建议直达键 `M-f`，前缀与直达键均可在 `M-x etaf-ext-manage` 或经 `etaf-ext-set-key` 自定义或解绑。

## 文档

- 公共 API 清单：[etaf-hints.el](etaf-hints.el)。
- 使用手册：[docs/manual.md](docs/manual.md)。
- 变更日志：[CHANGELOG.md](CHANGELOG.md)。

## 校验

```sh
make check
```
