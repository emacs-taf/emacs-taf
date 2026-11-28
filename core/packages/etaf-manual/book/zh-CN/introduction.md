# 引言

本书是 ETAF 的参考手册。ETAF 是在 Emacs 中构建文本应用的框架。本书描述框架各包的每一个公共接口：每个函数、宏、变量、属性和组件做什么，事情按什么顺序发生，哪里可能失败，失败后留下什么状态。本书也讲清框架如何工作，包括数据流、时序、不变式和代价，方便开发者扩展和诊断框架。这些内容一律通过概念和公共接口来讲：内部函数和数据结构任何版本都可能改变，本书不点名它们。

本书按子系统组织，不按包组织。样式、焦点这类横跨多个包的子系统只在一处讲，每个定义条目标属于恰好一个包；所属包由「层与稳定性」一节说明。本书不是教程：它假定你熟悉 Emacs Lisp，需要的是精确的答案。

## 安装

除 ECSS 外，这些包要求 Emacs 29.1 或更新版本；ECSS 单独支持 28.1。官方 package.el 包源是 [https://etaf.top/packages/](https://etaf.top/packages/)。源码包由 Emacs 在本地编译；使用框架和组件库不需要 Git、Python、系统编译器或 Pi，安装也不替换用户配置。原生编译是可选能力。SQLite 另需 Emacs 本身具备支持，即 `sqlite-available-p` 返回非 nil；仅安装 sqlite3 可执行程序并不够。图形媒体需要图形 frame 及对应的 Emacs 图像支持。

以下代码只需执行一次，然后选择组件画廊或其他受支持目标：

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

以后运行 `M-x etaf-install` 重开已安装的目标，不必再次下载。`M-x etaf-install-doctor` 只检查必需和可选能力，不访问网络，也不写配置。[Monorepo README](https://github.com/emacs-taf/emacs-taf/blob/main/README.zh-CN.md#在已有-emacs-中安装) 列出可选目标及外部后端边界。包管理仍由 package.el 负责；通过 `M-x list-packages` 更新或卸载，更新已加载代码后重启 Emacs。

安装入口会拒绝冲突的源码加载路径和已加载的源码依赖，不会静默覆盖它们。安装或包入口加载失败时，只移除本次新增的包，保留旧安装和无关包，报告任何清理失败，并要求重启后再试：删除包文件无法撤销进程中已经加载的 Lisp。源码检出用于开发时应放在独立配置中，不要混用同一依赖的两种安装方式。

## 范围

本书涵盖七个包：

| 包 | 提供 | 依赖 |
| --- | --- | --- |
| `ecss` | CSS 层叠引擎：选择器、优先级、层叠、继承、变量与计算样式 | — |
| `ekp` | Knuth–Plass 段落断行，支持 CJK | — |
| `ebox` | 渲染成 buffer 文本的保留盒树：测量、盒/flex/grid 布局、样式投影、滚动、增量 buffer 更新与输入原语 | `ecss` |
| `etaf` | 应用框架：View、Host、Component、响应式状态、Context、Runtime、事件、Behavior、Action、Resource 与 Data | `ebox`、`ecss` |
| `etaf-ui` | 官方组件库及其主题 token | `etaf`、`ebox` |
| `etaf-db` | ETAF Data 的数据库后端，目前实现 SQLite | `etaf` |
| `etaf-posframe` | 浮动面板：把任意 ETAF View 放进子 frame，带落位、标题栏、主题开关与应用注册表 | `etaf`、`etaf-ui` |

应用只经由 ETAF 使用 Ebox 和 ECSS，其他包都不使用 EKP。本书仍然完整描述这三个包的公共接口，因为它们都能单独使用。不经 ETAF 使用 Ebox、把 ECSS 接到别的宿主、用 EKP 给普通 Emacs 文本排版，各有一个部分专门讲。

本书不涵盖用 ETAF 构建的应用、游戏、etaf-desktop 桌面应用和游戏套件。两个 playground 只出现在工具相关的章节里。

本书只写已经实现的行为。工作区架构文档或键盘导航契约中设定了、代码还没做到的目标，本书用一句话说明，只描述当前行为。

## 读者与阅读路径

本书有三类读者。各自从下表所列部分的开头读起，其余内容经[概念索引](concept-index.md)、[符号索引](symbol-index.md)和交叉引用查阅。

| 读者 | 先读 | 然后按需查阅 |
| --- | --- | --- |
| 应用作者：用 View、组件和状态构建应用 | 总论；ETAF 编程模型 | 样式；布局与渲染；交互；数据与异步；[UI 组件库](ui-overview.md) |
| 组件作者：为应用或组件库添加可复用组件 | 同上，加上「样式」部分中[组件样式与主题](component-styles-and-themes.md) | [UI 组件库总论](ui-overview.md)；[增量更新与发布](incremental-updates-and-publication.md)一章；扩展框架一章 |
| 框架开发者：扩展 ETAF，或诊断它的行为与性能 | ETAF 编程模型；布局与渲染 | 框架内部与扩展；[样式的实现](style-implementation.md)、EKP 实现两章 |
| 库用户：不经 ETAF 使用 Ebox、ECSS 或 EKP | 该包所在的部分：独立使用 Ebox、ECSS 作为通用库或 EKP 段落排版 | 样式；布局与渲染 |

每个部分中的章按顺序排列，一章只依赖它之前的章。[响应式系统](reactivity.md)一章能代表本书的深度：请在[组件](components.md)和 [Runtime](runtime.md) 两章之前读它。

## 记法约定

### 术语

<!-- index: 术语; 公共接口; 内部符号 -->

下列术语贯穿全书，各自在所属章节中给出完整定义。

**入口文件与 Commentary 记录。** 每个包有一个以 feature 命名的入口文件，例如 `etaf.el`。它的 Commentary 列出包支持的接口，每个符号一条记录，例如 `;; Function: etaf-mount (buffer-or-name view &optional options)`。

**公共与内部。** 包的 Commentary 列出的符号是公共的。其余符号都是内部的，名字里没有双连字符也一样：它们任何版本都可能改变，本书不描述。

**View。** 对用户界面的不可变描述：由 Host 节点和 Component 节点组成的树。用 `etaf-view` 宏书写，或用 `etaf-node` 构造。

**Host。** ETAF 直接经由 Ebox 渲染的节点种类：`text`、`box`、`fragment`、`row`、`column`、`flex`、`grid` 和 `image`。Host 节点的属性分为样式属性、`:role` 这样的语义属性，以及 `:on-press` 这样的事件属性。

**Component。** 带 props 的具名可复用 View 单元，用 `etaf-define-component` 定义。组件在已挂载 View 中的每一处使用都是一个*实例*，有自己的状态和 Scope。

**Runtime。** `etaf-mount` 为 buffer 创建的对象。它渲染 View，拥有实例树，并经由 Ebox 把变化发布到 buffer。

**ref、计算值、副作用与 Scope。** 响应式系统的对象。ref 保存状态，计算值派生状态，副作用响应状态，Scope 拥有副作用并统一释放。见[响应式系统](reactivity.md)。

**排空与提交。** 状态变化后，ETAF 进行*排空*：运行排队的副作用，直到状态稳定。排空期间，输出有变化的每个 Runtime *提交*一次，把变化写进自己的 buffer。

**Context。** 祖先用 `etaf-provide` 提供、后代用 `etaf-inject` 读取的值。见 [Context](context.md)。

**Action。** 用 `etaf-action-define` 定义、用 `etaf-dispatch` 调用的具名命令。Action 的第一个参数是 Runtime。见 [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)。

**Behavior。** 一组可复用的非视觉 Host 属性，外加一个可选的、返回清理函数的安装函数。用 `etaf-define-behavior` 定义，经 Host 的 `:use` 属性挂上。见 [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)。

**Theme 与 token。** Theme 把具名的值（称为 *token*）映射到颜色和其他样式值。组件库的 token 名字形如 `:ui-fg`、`:ui-panel-bg`。

**样式属性。** Ebox 用于布局和绘制的属性，例如 `:padding`、`:font-weight`。ECSS 根据内联样式、样式表和继承计算出每个样式属性的最终值。

**Ebox 节点与挂载。** Ebox 保留一棵节点树，对它布局，并写进 buffer。*挂载*把一棵树连到一个 buffer，树变化时保持两者一致。

### 求值、渲染、错误与输出的记法

<!-- index: 记法; ⇒; ▷; error→; -| -->

示例中使用四个记号：

| 记号 | 含义 |
| --- | --- |
| `⇒` | 形式求值得到其后的值。 |
| `▷` | View 渲染成其后的 buffer 文本。 |
| `error→` | 对形式求值会抛出其后的条件及其数据。 |
| `-\|` | 对形式求值会向 `*Messages*` 写入其后的文本。 |

每一处 `;; ⇒` 行都声明上方形式的求值结果，book 门禁会求值该形式并比较结果。裸 `⇒` 行展示上方形式产生的效果，通常是缓冲区或窗口状态，因此门禁只检查它前面有一个完整形式、且该行能读作一个值，或以 `; display` 结尾，不会去求值。结果是打印形式不稳定的对象时，该行改为描述它，并以 `; display` 注释结尾。

```elisp
(etaf-value (etaf-ref 3))
;; ⇒ 3

(etaf-value 5)
;; error→ wrong-type-argument (etaf-reactive-source-p 5)

(etaf-next-tick (lambda () (message "published")))
;; -| published
;; ⇒ nil
```

标为可运行的示例求值得到一个 View。Emacs 中的阅读器挂载它，你可以直接与它交互；印刷形式的手册则给出渲染后的文本：

```elisp :run
(etaf-view (text "Hello"))
```

▷ `Hello`

示例中的每个顶层形式以词法绑定分别求值，所以同一示例的各形式不共享局部变量。可运行示例中定义的组件一律以 `demo-` 为名字前缀。

签名中的参数名按 Lisp 的写法用小写：`(etaf-ref initial-value &key test name)`。正文中的参数名用大写：INITIAL-VALUE、TEST。签名采用 `cl-defun` 的 lambda 列表语法：

| 签名元素 | 含义 |
| --- | --- |
| `&optional` | 其后的参数可以省略，默认为 nil。 |
| `&rest` | 其余参数收集成一个列表。 |
| `&key` | 其后的参数是关键字参数，例如 `:test`。 |
| `(name default)` | 省略该参数时取 DEFAULT，DEFAULT 在省略时求值。 |
| `(name default supplied-p)` | 调用者传了该参数时，SUPPLIED-P 非 nil。 |

### 定义条目

<!-- index: 定义条目; 条目种类 -->

每个公共符号、Host、属性、样式属性和 token 都恰好有一个*定义条目*。条目以一个标题开始，标题给出种类、名字，可调用对象还给出签名：

```markdown
#### Function: etaf-ref (initial-value &key test name)
```

签名逐字取自条目的 Commentary 记录，构建检查把它与代码比对，所以两者不会走样。种类标签在各语言中都用英文。

几个连续的标题共用其后的说明。说明的第一段是一句话，说明条目是什么或做什么。之后的段落以标签开头，顺序固定：

| 标签 | 内容 |
| --- | --- |
| **参数。** | 每个参数接受什么、表示什么。 |
| **语义。** | 按顺序发生什么，包括边界情况。 |
| **返回。** | 返回值。 |
| **错误。** | 可能抛出的每个条件，写作 `error→` 加条件、数据和抛出时机。 |
| **示例。** | 用上述记法写的示例。 |
| **参见。** | 相关的条目和小节。 |

简短的条目可以不用标签，全部写成正文。

条目的种类有：

| 种类 | 命名的对象 | 名字和签名比对的依据 |
| --- | --- | --- |
| Function | 函数 | 它的 Commentary 记录 |
| Macro | 宏 | 它的 Commentary 记录 |
| Variable | 变量或用户选项 | 它的 Commentary 记录 |
| Hook | 钩子变量 | 它的 Commentary 记录 |
| Error | 错误条件 | 它的 Commentary 记录 |
| Component | 组件及其 props | 它的 Commentary 记录 |
| Host | Host 种类，例如 `text` | ETAF 定义的 Host |
| Property | Host 的语义属性或事件属性，例如 `:role` | ETAF 读取的属性 |
| Style | 样式属性，例如 `:padding` | Ebox 定义的样式属性 |
| Token | 主题 token，例如 `:ui-fg` | 组件库的 token |
| Syntax | View 语法形式，例如 `expr` | 不比对 |

样式属性的条目以一张表开头，列出属性的取值、初值、适用的节点、是否继承，以及影响几何还是只影响绘制。

键位列在拥有该 keymap 的条目或小节中，用一张「按键、命令、上下文」的表给出。

### 层与稳定性

<!-- index: 层; 稳定性; 兼容性 -->

每个条目恰好属于一个包，即它的*层*。层不写在标题里，而是由代码决定：

| 种类 | 层 |
| --- | --- |
| Function、Macro、Variable、Hook、Error、Component | Commentary 中列出该记录的包 |
| Host、Property、Syntax | `etaf` |
| Style | `ebox` |
| Token | `etaf-ui` |

每个条目都是公共的：它属于所在包支持的接口，对它的不兼容修改会连同迁移说明记入该包的变更日志。

## 版本

<!-- BEGIN:GENERATED:manual-versions-zh -->
本版描述 `ecss 0.1.4`、`ekp 1.0.9`、`ebox 3.1.15`、`etaf 0.3.20`、`etaf-media 0.1.0`、`etaf-ui 0.3.15`、`etaf-doc 0.1.0`、`etaf-db 0.1.5` 和 `etaf-posframe 0.3.6`。本书与代码一同维护：本书已覆盖的包有公共接口缺少条目、签名与代码不符、正文点名了非公共符号，或上面的版本与包不符时，构建检查都会失败。
<!-- END:GENERATED:manual-versions-zh -->

## 在 Emacs 中阅读本手册

<!-- index: etaf-manual 包 -->

`etaf-manual` 包以数据形式提供本书。`etaf-manual-book` 返回解析后的手册，语言由 `etaf-manual-language` 选择；`etaf-manual-definition` 查找某个符号的条目；`etaf-manual-example-view` 把可运行示例求值成一个 View，交给 `etaf-mount` 显示：

```elisp
(plist-get (etaf-manual-definition 'etaf-ref) :chapter)
;; ⇒ reactivity
```

本版提供自动生成的[概念索引](concept-index.md)与[符号索引](symbol-index.md)。`M-x etaf-manual-open` 在 Emacs 中打开阅读器，提供 Info 式章节导航、定义卡片、可运行示例与符号查找；`M-x etaf-manual-lookup` 从任意 buffer 打开某个符号的条目。同一份书源发布为网站 [https://etaf.top](https://etaf.top)，英文在根路径，简体中文在 `/zh-cn/`。
