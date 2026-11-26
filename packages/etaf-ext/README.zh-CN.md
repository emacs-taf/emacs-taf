# etaf-ext

[English README](README.md)

`etaf-ext` 是面向 ETAF 生态的纯粹通用扩展引擎与管理中心。本包只包含扩展引擎、权限门禁、独立持久化存储、错误熔断、纯净模式与响应式扩展管理中心（`M-x etaf-ext-manage`），不捆绑任何具体业务插件；具体扩展按独立包（如 `etaf-translate`、`etaf-hints`、`etaf-highlight`、`etaf-export`）或个人配置微脚本的方式按需加载。

## 核心能力

- 声明式扩展清单（`etaf-ext-define` / `etaf-ext-register`）：支持按 `:apps`、`:kinds`、`:uri-regexp`、`:buffer-regexp`、`:predicate` 匹配页面，并支持按应用持久化 `allow` / `deny` 策略。
- 细粒度能力权限门禁：所有上下文原语严格校验 `read-tree`、`decorate`、`companion`、`override`、`overlay`、`interact`、`inspect`、`storage`、`keys`、`popup`、`notify` 权限，越权即抛出 `etaf-ext-permission-error`。
- 多扩展和平共存：基于 ETAF 多宿主表现层槽位与命名根级覆盖层，文本着色装饰、伴生卡片、悬浮层与快捷键层按优先级叠加，卸载后不留残影。
- 独立持久化存储：每个扩展拥有隔离的 SQLite WAL 键值命名空间，未配置磁盘路径或无 SQLite 时自动降级为内存存储。
- 性能与隔离保障：同一提交版本内共享只读 Host 树快照缓存、回调自动防抖、主题切换同步、公共主题色派生（`etaf-ext-theme`）、错误日志留痕、连续异常自动熔断暂停，以及单页纯净模式（`etaf-ext-pure-mode-toggle`）。
- 命令优先、零冲突快捷键体系：扩展只声明 `:prefix-hint` 与 `:subkey`（极少数高频触发器可声明受保护的 `:suggested-key`），统一收敛到 `etaf-ext-key-prefix`（默认 `C-c C-e` / `etaf-ext-dispatch`）与模糊命令面板 `etaf-ext-command-palette`，经过全局/次模式/应用冲突防火墙校验，并支持 SQLite 持久化改键（`etaf-ext-set-key`）。
- 响应式扩展管理中心（`M-x etaf-ext-manage`）：适配宽屏、中屏、窄屏与矮窗，实时展示快捷键冲突并支持在线改键/解绑，保留用户原始 mode-line，全部颜色从当前 Emacs 主题实时派生。

## 配套独立扩展

- [etaf-translate](https://github.com/emacs-taf/etaf-translate)：原生基于 `etaf-ext` 的零侵入沉浸式页面翻译与快译浮窗扩展。
- [etaf-hints](https://github.com/emacs-taf/etaf-hints)：面向任意 ETAF 页面的独立 Vimium 风格快捷跳转扩展。
- [etaf-highlight](https://github.com/emacs-taf/etaf-highlight)：独立通用划词高亮与持久化批注卡片扩展。
- [etaf-export](https://github.com/emacs-taf/etaf-export)：面向任意 ETAF 渲染页面的零浏览器实时矢量预览与 PDF / SVG 导出扩展。

## 快速上手

```elisp
(require 'etaf-ext)
(require 'etaf-hints)
(require 'etaf-highlight)
(etaf-ext-mode 1)
```

在任意已挂载的 ETAF 页面运行 `M-x etaf-ext-manage`（全缓冲区居中卡片工作区）或 `M-x etaf-ext-manage-popup`（居中浮窗面板）即可统一启停扩展、按关键词筛选（`/`）、查看权限与错误日志、设置按应用策略或一键切换纯净模式。

## 文档

- 公共 API 清单与签名：[etaf-ext.el](etaf-ext.el)。
- 使用与扩展开发手册：[docs/manual.md](docs/manual.md)。
- 维护者架构说明：[docs/architecture.md](docs/architecture.md)。
- 变更日志：[CHANGELOG.md](CHANGELOG.md)。

## 校验命令

```sh
make check
```
