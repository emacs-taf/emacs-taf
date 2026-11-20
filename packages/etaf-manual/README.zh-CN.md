# ETAF 参考手册

[English](README.md)

《ETAF 参考手册》记录 ETAF 核心包 ecss、ekp、ebox、etaf、etaf-ui 和 etaf-db 的全部公共接口。它仿照《Emacs Lisp 参考手册》，按子系统和对象组织，为每个公共函数、宏、变量、钩子、错误、组件、Host、属性、样式属性和主题 token 各写一个定义条目，并通过概念和公共接口讲清每个子系统怎样工作。手册有英文和简体中文两个版本。

本仓库包含全书源文件、`etaf-manual` 包和用 ETAF 自身实现的 Emacs 阅读器应用；这个包把全书作为数据读取，供 Emacs 工具和网站构建使用。全书与代码对照检查：签名与包的 Commentary 不符、正文点名了非公共符号、写出的版本号过期、译本与原文结构不一致，或者可运行示例挂载失败时，构建都会失败。

全书已完成：十二个部分共 87 章、附录 A–K、概念索引与符号索引，两种语言齐全。`M-x etaf-manual-open` 可直接在 Emacs 中阅读；同一份源文件也发布成网站 <https://etaf.top>，英文在根路径，中文在 `/zh-cn/` 下。`make site` 生成站点，`make site-publish` 发布。

## 环境要求

Emacs 29.1 或更高版本、ETAF 0.2.2 和 etaf-ui 0.1.3。门禁还会读取 ecss、ekp、ebox、etaf、etaf-ui 和 etaf-db 的检出目录，它们应与本仓库相邻。

## 使用

把仓库根目录连同 ETAF 及其依赖加入 `load-path`，然后加载本包：

```elisp
(require 'etaf-manual)

(plist-get (etaf-manual-definition 'etaf-ref) :chapter)
     ⇒ reactivity
```

按 Markdown 阅读某一章，直接打开 `book/en/` 或 `book/zh-CN/` 下的文件；按应用阅读整本书，用下面的阅读器。受支持的 API 以 [`etaf-manual.el`](etaf-manual.el) 的 Commentary 为准。

## 在 Emacs 中阅读本手册

`M-x etaf-manual-open` 在独立缓冲区中打开手册，界面本身由 ETAF 构建：左侧是三级目录栏，右侧是正文，含定义条目卡片与可运行示例；顶栏显示当前位置并提供语言切换，底栏显示键位提示；外观默认跟随 Emacs 主题（随），`t` 在亮、暗之间切换；面板标题栏给出 `亮`、`随`、`暗` 三档，写的是同一格状态。每一行都保持标准行高，滚动时版面不会跳动；窗口变窄时目录栏折叠为整屏目录。

![宽窗口下的阅读器：目录栏、正文与键位提示](examples/etaf-manual-reader-wide.png)

![窄窗口下的阅读器：目录栏折叠为整屏目录开关](examples/etaf-manual-reader-narrow.png)

- `n` / `p` 上下节，`u` 升一级，`l` / `r` 在阅读历史中前后移动。
- `[` / `]` 切换章节，`i` 打开术语与定义条目索引，`g` 切换中英文，`t` 切换深浅色，`q` 退出。
- `?` 打开 ETAF 键位帮助，列出阅读器的全部按键与说明。
- `TAB`、方向键、`RET`、`M-g` 与 `Escape` 保留框架行为，所以可运行示例里的控件可以聚焦、可以操作。

每个 `elisp :run` 示例就地在文档中渲染：查看器带「源码 / 预览 / 并排」三种模式和运行、重跑、停止控件，预览就是示例构建出的真实 ETAF 界面，可交互。

`M-x etaf-manual-lookup` 可从任意缓冲区打开某个符号的定义条目。

## 文档

- [编写本手册](docs/manual.zh-CN.md)：全书格式、门禁和命令。
- [引言](book/zh-CN/introduction.md)：本书的范围和记法。

## 开发

克隆后运行 `make setup-hooks`。`make book-check` 运行门禁，`make coverage` 列出每个包已有条目的接口数，`make check` 另外运行结构检查、编译、[tests/acceptance.json](tests/acceptance.json) 中的公共场景、API 边界检查和门禁的工具测试。
