# 编写 ETAF 参考手册

[English](manual.md)

本文写给编写或检查《ETAF 参考手册》章节的人，也写给通过 `etaf-manual` 包读取本书的工具。内容包括源文件布局、章节格式、门禁检查哪些问题，以及运行检查的命令。受支持的 Lisp API 以 [`etaf-manual.el`](../etaf-manual.el) 的 Commentary 为准。

## 手册写什么

本书记录核心包 ecss、ekp、ebox、etaf、etaf-ui 和 etaf-db 的公共接口，并通过概念和公共接口讲清各个子系统怎样工作，包括数据流、时序、不变式、错误和代价。书中不点名私有函数、内部数据结构，也不点名包的 Commentary 没有列出的符号，即使名字里没有双连字符。书中只写已经实现的行为；计划中的能力至多注明尚未实现。本书是参考手册，按子系统和对象组织，不是教程。

## 源文件布局

| 路径 | 内容 |
| --- | --- |
| `book/book.json` | 全书描述：书名、语言、包、部分、章、附录和索引 |
| `book/en/ID.md` | 标识为 ID 的章的英文版 |
| `book/zh-CN/ID.md` | 同一章的简体中文译本 |
| `etaf-manual.el`、`lisp/` | 把全书作为数据读取的包 |
| `scripts/check-book.el` | 门禁 |
| `scripts/check-references.py` | 检查其他仓库指向手册的站点链接能否落到章和标题 |
| `site/` | 把全书发布到 <https://etaf.top> 的网站 |
| `tests/` | 可运行示例与读书接口的场景，以及门禁的工具测试 |

英文是主语言。每一章在每种语言下都有同名文件。

`site/` 是发布全书的 Astro 工程。`site/scripts/export-site.el` 读取解析好的书，
把页面和侧栏写到 `site/src/content/` 下（生成内容不进版本库）；`site/astro.config.mjs`
配置 Starlight，英文在根路径、简体中文在 `/zh-cn/` 下；`site/scripts/publish.py`
构建站点并把新版本部署到 `current` 软链之后。页面内的章间链接会改写成站点路由，
`elisp :run` 与 `:figure` 代码块会变成带标签的普通 `elisp` 块，因为静态页面无法挂载 View。
导出器还会重新生成含安装说明与手册链接的双语未找到页面。`site/src/content/i18n/` 维护本地化无障碍文案；Markdown 处理器保留原标点，使章节锚点与书稿一致。

首页是独立的 Astro 页面，不是 Starlight splash：`site/src/components/Landing.astro`
按 `site/src/data/landing.mjs` 里的文案、截图和仓库链接渲染，
`site/src/pages/index.astro` 与 `site/src/pages/zh-cn/index.astro` 选择语言。
Starlight 的内容流、标题包装和栏宽会和自由布局冲突，所以它只负责阅读页。
两者共用 `site/src/styles/brand.css`，其中定义字体和浅色、深色两套配色；
`site/src/styles/custom.css` 把它们映射到 Starlight 并设定阅读尺寸。
配色主题存放在 `starlight-theme` 键下，在任一侧切换都会同步到另一侧。手册页头复用首页的
主题按钮和语言链接，不再使用 Starlight 的下拉选择。

站点保持书籍式的排版风格，修改时调整这些设定，不要另加局部样式：

- 字体：拉丁文正文与标题用 Source Serif 4，中文正文用霞鹜文楷，中文标题用
  Noto Serif SC，代码与小号标签用 IBM Plex Mono 加霞鹜文楷等宽。字体来自
  fontsource 包，按 unicode-range 切片自托管；霞鹜文楷从其 webfont CDN 加载。
- 阅读：正文 18px、行高 1.75（中文 1.85），栏宽 44rem；导航与页内目录保持
  15px 和 14px。
- 配色：暖色纸墨，ETAF 标志的紫色只用于链接和小处点缀。深色主题是带细颗粒的
  哑光炭灰，让表面像纸面而不是黑玻璃。不用渐变、光晕、毛玻璃和仿窗口外框。
- 布局：任何宽度下都没有元素横向滚动，代码块与表格改为折行；改动后检查
  390 与 360 CSS 像素。

## 发布站点和包归档

`make site-publish` 重新构建站点，通过非交互 SSH 上传普通文件，并部署到 `current` 之后；现有 `packages/` 目录保持不变。`PUBLISH_ARGS=--build-only` 只做本机构建，`--no-build` 发布已有构建。主机必须已通过 HTTPS 提供 `/srv/etaf.top/current`；发布过程不修改 Caddy 或 SSH 配置。

同时发布站点和已验证的工作区包归档：

```sh
make site-publish PUBLISH_ARGS='--packages /path/to/release'
```

`PUBLISH_ARGS='--packages-only /path/to/release'` 只更新包归档，不重新构建或改变当前页面。两种包发布模式都调用相邻工作区的 `scripts/package-release.py stage`：必须有封口检查点、匹配的验证摘要，以及每个受支持目标的两条安装路径证据；局部诊断报告会被拒绝。只上传索引、公开清单和其中列出的源码 tar 包，安装报告和日志保持私有。构建与安装检查流程以工作区工具手册为准。

`PUBLISH_ARGS='--pages-only /path/to/archive'` 只根据已有的公开归档重新生成 `packages/index.html` 与各包详情页。清单和其中列出的 tar 包仍须通过校验，部署器会把历史 tar 包原样带入新版本；包字节没有变化时用它交付页面修改，不必重新构建和重跑安装门禁。

默认 SSH 路径经 `lightos` 到 `root@aliyun-hk`。`ETAF_TOP_ROOT=direct` 使用直连；`ETAF_TOP_HOST` 更换主机，`ETAF_TOP_KEEP` 控制保留的站点版本数（默认 5，最少 2）。服务端需要 Python 3.10+。部署锁串行化站点与包发布；原子切换前检查 tar 路径、文件类型、摘要和公开文件白名单。已有包文件名不能被不同字节替换，包版本不能倒退。即使旧站点版本被清理，历史 tar 包也会带入新版本继续提供下载。

每次包发布还会生成可浏览的归档。`packages/index.html` 按框架、应用、游戏分组列出
每个包；`packages/<名>/index.html` 是该包的详情页——用途、安装片段、GitHub 仓库、
构建所用的源码提交、校验和与源码包。包名链接指向详情页，而不是直接下载；手册链接
写在正文里，不在页头放菜单。`package.el` 仍只读 `archive-contents`，浏览器打开裸目录
看到的是归档说明而不是 404。两个页面每次发布都从清单重新生成，不属于清单内容。

归档页还会显示每个包的下载次数。服务端的 `site/scripts/download-stats.py` 由 systemd 定时器（`etaf-download-stats`，每十分钟）运行，统计的是「安装」而不是「取文件」：版本化 tar 包只有同一客户端在一分钟内也请求它的 `.tar.sig` 才计数——package.el 会这么做，爬虫或手工 `curl` 不会；同一客户端每个包每个 UTC 日只算一次，所以反复跑测试不会把数字抬高；部署校验带 `?deployment=` 的请求直接跳过。它把 `packages/downloads.json` 写在不可变版本目录之外。页面在浏览器里读取该文件，文件缺失时保留破折号，所以没有 JavaScript 或定时器时归档仍可阅读。访问日志、定时器与 `/srv/etaf.top/stats` 服务路径属于主机配置，发布过程不改动它们。

链接预览复用同一套生成页面。手册页头提供 `https://etaf.top/og/manual.png` 和统一描述；归档的每个页面输出自己的 canonical、标题和描述，并指向 `https://etaf.top/og/archive.png`。首页预览用 `/shots/etaf-ncm.png`。卡片是 `site/public/og/` 下的 1200×630 PNG；保持路径稳定，已有链接的预览才不会失效。Telegram 按 URL 缓存预览：换图后把链接发给 `@WebpageBot`，或用带版本参数的 URL 分享一次，强制重新抓取。

切换后，部署器经 HTTPS 回读页面入口和包文件字节。检查失败则恢复上一条 `current`，再检查恢复后的服务；恢复检查遇到网络错误会明确标记为未验证，不声称回滚验证成功。客户端也回读 `current`。传输中断后应先查看该软链，再决定是否重试；SSH 响应丢失不等于发布没有发生。

## 全书描述

`book/book.json` 是一个 JSON 对象，字段如下：

| 字段 | 值 |
| --- | --- |
| `title` | 语言到书名的映射 |
| `languages` | 语言代码；第一个是翻译检查的基准 |
| `packages` | 本书记录的包，它们的入口文件提供 Commentary 记录和版本号 |
| `references` | 正文可以点名的其他仓库，例如两个 playground；它们的 Commentary 记录同样算公共接口 |
| `coverage` | 每个接口都必须有定义条目的包和词表 |
| `parts` | 对象列表，每项有 `id`、按语言给出的 `title`，以及按阅读顺序排列的 `chapters` |
| `appendices` | 对象列表，每项有 `id`、按语言给出的 `title`，并且要么对应 `LANGUAGE/ID.md` 下的一个章节文件，要么用 `generate` 指定一个已实现的生成器 |
| `indices` | 对象列表，每项有 `id`、`generate` 和按语言给出的 `title` |

部分用罗马数字编号，章在全书范围内用整数编号，附录用字母编号，顺序都取自这个文件。因此编号并不固定：正文里用标题称呼一章，链接时用文件名。

生成的附录和索引没有源文件。包从定义条目和索引标记构造它们的 Markdown，用同一个章节解析器解析，并保存在该章的 `:content` 里，因此生成内容与手写章一样接受检查、翻译和读取。

## 章节格式

每章是一个 Markdown 文件。每个段落、列表项和表格行都写成一行，由渲染器按窗口宽度折行：中文段落里的换行会被渲染成一个空格。

### 章节结构

一章按下面的顺序组织，用不到的部分可以省略：章首导语，不带标题，说明本章讲什么；「模型」一节，讲概念以及概念之间的关系；若干「接口」小节，每个对象一节，先讲概念，再列定义条目，最后讲条目之间怎样配合；「语义细节」一节，讲时序、边界情况、机制和代价；最后是「错误与恢复」一节。机制只通过概念和公共接口来讲，不点名内部函数或数据结构。

### 标题

- `#` 是章标题，每章恰好一个。
- `##` 和 `###` 是节。
- `####` 一律是定义条目，不允许出现第四级以下的标题。

每个标题都有锚点，算法与 GitHub 相同：文字转为小写，链接只保留链接文字，保留字母、数字、组合符号、连字符和下划线，空格变成连字符，其余字符丢弃。重复的锚点依次加 `-1`、`-2`。所以 `## Errors and recovery` 的锚点是 `errors-and-recovery`，`## 错误与恢复` 的锚点是 `错误与恢复`。

### 定义条目

定义条目的标题是 `#### KIND: NAME SIGNATURE`。各语言都用英文的种类标签。

| 种类 | 指什么 | 对照检查的依据 |
| --- | --- | --- |
| `Function` | 函数 | 它的 Commentary 记录 |
| `Macro` | 宏 | 它的 Commentary 记录 |
| `Variable` | 变量或用户选项 | 它的 Commentary 记录 |
| `Hook` | 钩子变量 | 它的 Commentary 记录 |
| `Error` | 错误条件 | 它的 Commentary 记录 |
| `Component` | 组件及其 props | 它的 Commentary 记录 |
| `Host` | Host 种类，例如 `text` | ETAF 定义的 Host |
| `Property` | Host 的语义属性或事件属性，例如 `:role` | ETAF 读取的属性 |
| `Style` | 样式属性，例如 `:padding` | Ebox 定义的样式属性 |
| `Token` | 主题 token，例如 `:ui-fg` | 组件库的 token |
| `Syntax` | View 语法的一种形式，例如 `expr` | 不检查 |

签名照抄 Commentary 记录，空白差异忽略不计。连续的几个条目标题组成一组，共用一段说明。条目正文以一句话概述开头，随后按下面的顺序写带标签的段落，没有内容的标签省略：

| 英文 | 中文 | 内容 |
| --- | --- | --- |
| `**Arguments.**` | `**参数。**` | 每个参数、可接受的值和默认值 |
| `**Semantics.**` | `**语义。**` | 按顺序说明发生什么，包括边界情况和时机 |
| `**Returns.**` | `**返回。**` | 返回值 |
| `**Errors.**` | `**错误。**` | 每个错误条件，写成 ``error→ `CONDITION` ``，并说明附带数据和触发时机 |
| `**Example.**` | `**示例。**` | 简短示例 |
| `**See also.**` | `**参见。**` | 相关条目 |

样式条目开头是一张表，列出值语法、初始值、适用对象、是否继承，以及影响绘制还是几何。键位不设条目种类：在拥有该 keymap 的条目或小节里用一张「键、命令、上下文」表列出。

### 记法

| 记号 | 含义 |
| --- | --- |
| `⇒` | 前面那个表达式的值 |
| `▷` | 缓冲区显示的内容 |
| `error→` | 该表达式发出后面写的错误条件 |
| `-\|` | 写到 `*Messages*` 的文字 |

写成 `;; ⇒` 注释的结果行会受到检查：门禁会求值该行前面那个顶层表达式，并把它与 `⇒` 之后的文字比较。结果是打印形式不稳定的对象时，该行改为描述它，并以 `; display` 注释结尾，不做比较。

签名里的参数名用小写。正文里提到参数时用大写，例如「SOURCE 是一个 ref」。

### 索引词

在标题后单独一行写 `<!-- index: 词; 词 -->`，为这一节标记索引词。概念索引由这些词生成，符号索引由定义条目生成。

### 可运行示例

以 ```` ```elisp :run ```` 开头的代码块是可运行示例。包逐个读取顶层表达式，在加载了 etaf 和 etaf-ui 的环境里以词法绑定求值；最后一个表达式的值必须是 ETAF View。不同的顶层表达式之间不共享局部绑定。示例里定义的组件以 `demo-` 命名。由 Lisp 计算出来的 View 子节点要包成 `(expr FORM)`。验收测试会在每种语言下挂载每个可运行示例，所以示例求值失败、挂载失败或产生警告，`make check` 都会失败。

示例必须服务于它所属的条目或小节：给出结果可见的真实任务，只聚焦那一个特性，不要为它拼一个展示多个特性的大 demo。`**示例。**` 里的短例遵循同一要求。

### 插图

以 ```` ```elisp :figure ```` 开头（可在同一行跟一句图注）的代码块是插图。包把它最后一个表达式求值为 ETAF View，阅读器直接在章节里渲染这个 View，作为静态图示，没有运行与停止控件；因此在文字讲不清的地方可以用插图展示盒模型、布局或组件。插图在它所在的小节首次渲染时求值一次；验收测试会在每种语言下挂载每个插图，所以插图求值或挂载失败时 `make check` 会失败。需要读者操作结果时改用 `:run` 示例，并给每个插图写一句说明它展示什么的图注。

### 链接和名字

链接到其他章时，以文件名作为链接目标，可以再加标题锚点，例如 `reactivity.md` 或 `reactivity.md#scope`，并且只链接已经存在的章。尚未写成的章，用纯文本写它的标题。该章写成后，在同一次交付里把这些提及改成链接。

带包前缀的代码片段，例如 `etaf-ref`，必须是本书所记录的包或参考仓库的 Commentary 记录，或者是包名、参考仓库名。其他名字，例如本书范围以外的应用，写成纯文本。写出包名和版本号的代码片段，例如 `etaf 0.2.1`，必须与该包入口文件的 `Version:` 头一致。

### 翻译

各语言的章节相同，节的层级序列相同，定义条目及其签名相同，可运行示例的数量也相同，插图的数量也相同。可运行示例与插图的代码保持一致；其他代码块里的注释可以翻译。中文里以下术语不翻译：Runtime、Host、Context、View、Action、Theme 和 Scope。

## 门禁检查什么

门禁读取本书和相邻的各个提供者仓库，每个问题报告为 `FILE:LINE: MESSAGE`。工具测试中的 `scripts/check-references.py` 会校验外部仓库指向本书的链接和锚点。

| 消息 | 原因 |
| --- | --- |
| `Missing chapter`、`Chapter needs a level-1 title`、`Chapter has several titles` | 章节文件缺失，或章标题不对 |
| `Level-4 headings are definition entries`、`Headings deeper than level 4` | 标题既不是合法的节，也不是合法的条目 |
| `Unclosed code fence` | 代码块没有结束 |
| `chapter is not listed in book.json` | 语言目录里有一个不属于本书的 Markdown 文件 |
| `KIND NAME is not a Commentary record` | 需要对照 Commentary 的条目找不到该种类的记录 |
| `signature of NAME differs from PACKAGE Commentary: SIGNATURE` | 条目签名与记录不一致 |
| `unknown KIND NAME` | Host、Property、Style 或 Token 条目指向不存在的项 |
| `duplicate KIND entry for NAME` | 同一种类的两个条目指向同一项 |
| `` `NAME' is not a public interface `` | 代码片段点名了非公共符号 |
| `` `NAME' has no definition entry `` | 代码片段点名了已列入覆盖范围、却没有条目的公共接口 |
| `NAME has no definition entry (coverage: SUBJECT)` | 已列入覆盖范围的包或词表有接口缺少条目 |
| `PACKAGE is version X, not Y` | 版本号片段与包不一致 |
| `link to unknown chapter: TARGET`、`link to unknown heading: TARGET` | 链接目标不存在 |
| `hard-wrapped line: write each paragraph on one line` | 段落或列表项在下一行继续 |
| `result line claims X but the form returns Y`、`result line is no readable value: TEXT`、`result line has no preceding form`、`result form signals ERROR` | `;; ⇒` 结果行与它前面形式的求值结果不一致，或裸 `⇒` 行前面不是完整形式、行内文本不能读作值 |
| `appendix does not list KIND NAME` | 附录 A、B 或 D 漏掉了核心包的某个公共错误条件、钩子或变量 |
| `definition entries differ from LANGUAGE`、`section structure differs from LANGUAGE`、`runnable examples differ from LANGUAGE`、`index terms differ from LANGUAGE` | 译本与基准语言不一致 |
| `generated NAME does not link KIND NAME`、`generated concept index does not link TARGET`／`does not list TERM` | 生成内容缺少它承诺包含的接口或索引词 |
| `Unknown generated content` | `generate` 没有对应已实现的生成器 |
| `provider checkout missing: DIRECTORY`、`cannot read provider source`、`cannot load provider package PACKAGE` | 读不到或加载不了提供者仓库 |

## 命令

在仓库根目录运行，各提供者仓库要作为相邻目录检出：

| 命令 | 作用 |
| --- | --- |
| `make book-check` | 运行门禁 |
| `make coverage` | 运行门禁，并列出每个包和词表已有条目的接口数 |
| `make test` | 运行 `tests/acceptance.json` 中的公共场景，包括挂载每个可运行示例 |
| `make check` | 结构、编译、门禁、场景、API 边界和工具测试 |
| `make site` | 由 `book/` 生成网站到 `site/dist/` |
| `make site-publish` | 生成网站并发布到 <https://etaf.top> |

也可以直接运行门禁：`emacs -Q --batch -L . -L lisp -l scripts/check-book.el [--book DIRECTORY] [--providers DIRECTORY] [--coverage]`。`--book` 默认是 `book/`，`--providers` 默认是上级目录。

其他仓库用站点链接引用章节，例如 `https://etaf.top/zh-cn/ebox-node-construction/`。`scripts/check-references.py` 会把每个这样的链接对照书源解析：章必须存在，带锚点时锚点必须是该章的某个标题；工具测试会在整个工作区上运行它，旧的仓库路径会被报为问题。

包改动公共接口时，在同一次交付里更新所有语言中受影响的章节。一个包的全部接口都有条目后，把它加入 `coverage`，门禁会保证它始终完整。

## 在 Lisp 中读取本书

```elisp
(require 'etaf-manual)

(plist-get (etaf-manual-definition 'etaf-ref) :chapter)
     ⇒ reactivity

(mapcar (lambda (chapter) (plist-get chapter :title))
        (plist-get (etaf-manual-book "zh-CN") :chapters))
     ⇒ ("引言" "响应式系统")
```

`etaf-manual-book` 会缓存解析结果，直到某个源文件改变；源文件格式有误时发出 `etaf-manual-error`。`etaf-manual-example-view` 对可运行示例求值，返回可交给 `etaf-mount` 的 View。
