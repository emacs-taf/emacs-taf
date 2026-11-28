# 组合组件

目录里有三个组件存在的意义是组合既有契约而不是引入新契约。`etaf-date-picker` 是目录的原生文本字段加一条日期契约，`etaf-command-palette` 是裹着可选择列表的模态对话框，`etaf-ui-qr-login` 是裹着画好的代码与状态行的模态对话框。三者都受控且无状态：值、命令表或登录周期归调用方所有，组件只负责渲染与报告。[文本输入控件](ui-text-input-controls.md)定义它们所基于的字段，[浮层](ui-overlays.md)定义对话框，[导航与集合](ui-navigation-and-collections.md)定义列表，[UI 组件库总论](ui-overview.md)定义共同契约。`etaf-ui-qr-paint` 把模块行变成登录面板显示的文字代码。

## 日期选择器

<!-- index: etaf-date-picker; ISO date; draft value; submit validation -->

#### Component: etaf-date-picker (&key value label placeholder on-change disabled bind)

在目录的原生文本字段上渲染语义日期输入。

**参数。** VALUE 是受控值：ISO `YYYY-MM-DD` 字符串或 nil。LABEL 默认 `"Date"`。PLACEHOLDER（默认 `"YYYY-MM-DD"`）在字段为空时显示。ON-CHANGE 接收被接受的值：完整日期字符串，或字段被清空时的 nil。DISABLED 移除编辑，BIND 用可写 ref 替代 VALUE 与 ON-CHANGE，遵循 `etaf-text-input`。

**语义。** 编辑是原生、就地的，与文本字段所述完全一致。部分日期是草稿：尚未构成完整日期的击键不会被报告，上一个被接受的值保持不动。提交时会拒绝既不为空也不是完整日期的输入，报出点名标签的可读错误，而不是把它写进去。检查是形状检查——四位、两位、两位——所以形状合法但不存在的日期如 `2026-13-01` 也会被接受为值；强制日历合法性属于应用的业务规则。

**返回。** 一个 View。

**错误。** VALUE 既不是 nil 也不是 ISO `YYYY-MM-DD` 字符串时报 `error→ etaf-component-call-error`。提交非法草稿时报 `user-error`，消息含标签与期望形状，且值保持不变。

**示例。**

```elisp
(etaf-date-picker :value "2026-01-15" :label "Due"
                  :on-change (lambda (date) (setq due date)))
```

**参见。** `etaf-text-input`、`etaf-calendar`。

## 命令面板

<!-- index: etaf-command-palette; modal list; command registry -->

#### Component: etaf-command-palette (&key open title items on-select on-close)

组合模态对话框与列表，用于调用方拥有的命令选择。

**参数。** OPEN 是值、ref 或 computed。TITLE 默认 `"Command palette"`。ITEMS 遵循 `etaf-list`：带唯一 `:key`、非空字符串 `:title` 与可选 `:description` 的 item plist——命令的名字是它的 title，而不是菜单标签。ON-SELECT 接收选中的键，ON-CLOSE 必需。

**语义。** 打开时，面板是宽 `(ch 56)` 的居中模态对话框，正文是一个可选择列表，默认 footer 提供关闭按钮；Escape 与 header 的 `x` 与任何对话框一样请求 ON-CLOSE。面板不拥有命令表、过滤或执行：由应用提供条目、决定键的含义并关闭对话框。

**返回。** 一个 View。

**错误。** ON-CLOSE 不是函数时报 `error→ etaf-component-call-error`；ITEMS 遵循列表自己的 item 契约。

**示例。**

```elisp
(etaf-command-palette :open palette :on-close (lambda () (setf palette nil))
                      :items '((:key save :title "Save file")
                               (:key open :title "Open file"))
                      :on-select #'run-command)
```

**参见。** `etaf-list`、`etaf-dialog`。

## 扫码登录面板

<!-- index: etaf-ui-qr-paint; etaf-ui-qr-login; 可扫描代码; 登录面板 -->

`etaf-ui-qr-paint` 把模块行画成文字代码，`etaf-ui-qr-login` 把代码放进模态登录面板。模块行、请求周期与账号状态都归应用或其后端所有；两者都不读网络或文件。

#### Function: etaf-ui-qr-paint (rows &optional quiet)

把模块行画成可扫描的代码字符串。

**参数。** ROWS 是 `"0"` 与 `"1"` 组成的字符串列表；较短的行在末尾之后视为空白。QUIET 非 nil 时是四周留出的空白模块数；nil 使用 4。

**语义。** 两行模块共用一行文字，用半块字符拼接，所以代码在高度为宽度两倍的文字单元里仍保持方形。一对都置位的模块变成全块，只置位上半或下半的模块变成对应的半块，一对空模块变成空格。两种配色下每个字形都保持纯黑底纯白，因为扫描器需要这个对比度。模块行由调用方或其后端提供；本函数只画文字，不访问任何东西。

**返回。** 由换行分隔的文字行组成的字符串，每个字形都带黑底白字的 face。

**错误。** ROWS 不是字符串列表时报 `error→ wrong-type-argument`，数据为 `(list-of-strings ROWS)`。

**示例。**

```elisp
(etaf-ui-qr-paint '("111" "101" "111"))
```

**参见。** `etaf-ui-qr-login`。

#### Component: etaf-ui-qr-login (&key open code status hint on-close)

在调用方应用之上显示扫码登录面板。

**参数。** OPEN 是 nil、t、ref 或 computed；nil（默认）保持面板关闭，可见性归调用方所有。CODE 是可选的画好的代码字符串或 ref，通常来自 `etaf-ui-qr-paint`；nil 不显示代码。STATUS 是可选的字符串或 ref，用于传输状态或站点自己的错误。HINT 是可选字符串，说明确认步骤。ON-CLOSE 是必需的无参函数，面板隐藏时也会被调用。

**语义。** 面板组合 `etaf-dialog`，所以下面的页面保留内容、只调暗一次并保持可读，面板在应用根画布中居中。把它挂成应用外壳的最后一个子节点，不要挂进单独的 buffer。在支持 SVG 的图形显示下，来自 `etaf-ui-qr-paint` 的半块字符码会自动转为按当前视口适配尺寸的清晰正方形矢量 SVG 图像，避免东亚歧义宽度块字符变形、行间字体缝隙与高二维码被裁切；纯文本终端或无 SVG 构建保留半块字符文本渲染。面板由代码决定大小：调用方画出服务返回的模块行，代码越宽或越高，面板就越高。状态行在代码上方，所以代码很高、占满可用高度时传输状态仍然可见。代码比窗口允许的高度更高时，面板保持窗口高度并滚动，所以每个控件仍然可达。Escape、标题栏关闭控件与底部取消按钮都会请求 ON-CLOSE；面板打开时被覆盖的控件保持不可操作。组件的标题、关闭标签与默认提示是固定的中文字符串（`扫码登录`、`取消` 与 `请用手机客户端扫码，并在手机上确认登录。`）；只有 HINT 可以替换。调用方拥有请求周期（取得并轮询代码、确认后重新加载）与账号状态；组件不发请求，也不要凭据。

**返回。** 打开时是一个 View；关闭时什么都不渲染。

**错误。** OPEN 不是 nil、t、ref 或 computed，CODE 或 STATUS 不是 nil、字符串或 ref，或 HINT 不是 nil 或字符串时报 `error→ etaf-component-call-error`；ON-CLOSE 缺失或不是函数时，组合出的对话框报同一个条件。

**示例。**

```elisp
(etaf-ui-qr-login :open open
                  :code (etaf-ui-qr-paint rows)
                  :status status
                  :on-close (lambda () (setf open nil)))
```

**参见。** `etaf-ui-qr-paint`、`etaf-dialog`、`etaf-ref`。

## Markdown 正文渲染

<!-- index: markdown; 文档树; 调色板; 渲染回调 -->

Markdown 正文渲染把 Markdown 文本转换成普通 ETAF View，供 Markdown 预览器、手册阅读器与其他文档视图共用。它分两步：`etaf-ui-markdown-parse` 把文本解析成不带呈现事实的块树，渲染函数再把块树与一份环境 plist 变成 View。两步都是纯函数，不拥有缓冲区、运行时状态或文件，所以同一代码路径既服务离屏测试，也服务已挂载的 Component。

#### Function: etaf-ui-markdown-parse (text &optional flavor)

把 Markdown 文本解析为文档 plist。

**参数。** TEXT 是 Markdown 源文本。FLAVOR 选择方言：`etaf-ui-markdown-flavors` 中的名字（默认 `gfm`）、覆盖个别扩展标志的特性 plist，或 nil 以使用 `etaf-ui-markdown-flavor`。

**语义。** 解析覆盖 CommonMark 的块与内联结构以及 GitHub 扩展：管道表格、任务列表项、删除线、裸自动链接、脚注与告警块；YAML front matter 被剥离为文档元数据。块是 plist，`:type` 为 `heading`、`paragraph`、`code-block`、`blockquote`、`list`、`table`、`thematic-break`、`html-block` 或 `footnote-def`；内联的 `:type` 为 `text`、`code`、`emph`、`strong`、`strike`、`link`、`image`、`autolink`、`footnote-ref`、`html` 或 `break`。块树不携带呈现事实：样式与 ETAF 节点的选择属于渲染函数。标题获得稳定且唯一的锚点；链接引用定义与脚注定义在块读取时收集，再解析进内联节点。解析是纯 Elisp，不读缓冲区、文件或网络。

**返回。** 文档 plist：`:meta`（front matter alist）、`:title`、`:children`（带标题锚点的顶层块；每个顶层块另带 `:begin` 与 `:end`，即它在 TEXT 中的半开字符区间，供调用方把一次编辑映射回它所在的块）、`:outline`（按文档顺序的 `(LEVEL TEXT ID)`）、`:footnotes`（含 `:label`、`:number` 与 `:children`）与 `:features`（解析出的扩展 plist）。

**错误。** 未知方言名报 `error→ etaf-ui-markdown-error`。

**示例。**

```elisp
(etaf-ui-markdown-parse "# 标题\n\n正文。\n")
```

**参见。** `etaf-ui-markdown-view-blocks`、`etaf-ui-markdown-flavors`。

#### Function: etaf-ui-markdown-view-block (block env)

把一个块渲染为一个 ETAF View，无可渲染内容时返回 nil。BLOCK 是 `etaf-ui-markdown-parse` 的一个顶层块，ENV 是 `etaf-ui-markdown-view-blocks` 描述的环境 plist。展开成多个 View 的块被包进一个 column，因此调用方每块拥有一个节点，可用于滚动、选中或逐块引用。

#### Function: etaf-ui-markdown-view-blocks (blocks env &optional tight)

按文档顺序返回 BLOCKS 的 View 列表，空输入返回 nil。相邻块之间隔一个空行，TIGHT 非 nil 时去掉。返回列表不带容器，调用方自行包裹；需要脚注定义时再渲染 `:footnotes` 的 View 并追加。环境 plist 的 `:palette` 必需，它是语义颜色键到颜色的 alist（`:ink`、`:muted`、`:faint`、`:heading`、`:accent`、`:accent-soft`、`:panel`、`:code-bg`（可选；行内代码与代码块有它时用它，否则回退 `:panel`）、`:border`、`:quote-bg`、`:quote-bar`、`:table-header`、`:table-stripe`、`:heading-rule`（可选；一级与二级标题下方的分隔线缺省时用 `:border`）、`:ok`、`:ok-soft`、`:warn`、`:warn-soft`、`:danger`、`:danger-soft`、`:important` 与 `:important-soft`）；每个颜色都经它读取，因此换调色板不会漏出半更新的颜色，未知键报 `error→ etaf-ui-markdown-error`。其余可选项都是回调：`:open-link` 收到链接 URL，每个渲染出的链接还以 `:accent-soft` 调色板颜色作为指针悬停底色；`:footnote-jump` 收到脚注标签；`:footnote-ref (label)` 返回挂到脚注定义盒上的宿主 `:ref` 符号；`:footnote-back (label)` 在每条脚注定义末尾追加可点击的 `↩` 返回控件；`:on-copy (kind text lines)` 在代码块复制按钮写入剪贴板后收到通知；`:render-media (kind node env)` 返回媒体的 View，KIND 为 `image`、`video`、`inline-image`、`table-image` 或 `html-media`（`table-image` 时 ENV 提供 `:table-cell` t、等于单元格内容宽度的 `:width` 与 `:table-cell-width` 以及 `:table-cell-align`），没有它时媒体退化为 alt 文本或 URL；`:render-code-block (block env)` 可为代码块返回 View，返回 nil 保留默认围栏块；`:code-link (text)` 以每个 code span 的文本调用，可返回 URL 或 (URL . HELP) cons 把该 span 变成链接，它保留代码样式，激活时用 URL 调 `:open-link`，帮助回显为 HELP 或 URL；`:alert-labels` 按种类覆盖告警标签；`:features` 是文档解析出的扩展 plist，控制告警块是否渲染为 callout；`:line-grid` 非 nil 时每一行都保持标准行高，供与其他内容并排滚动的文档使用：标题与脚注引用沿用正文字号，一级标题改用强调色，二级标题加左侧强调条，滚动时显露的行不会改变高度。没有 `:line-grid` 时，一级与二级标题在文字下方画一条 `:heading-rule` 的分隔线，标题色与正文同色的主题里也能分出层级；带语言的围栏块以一条包含语言名的标题条开始，标题条下压一条分隔线，标签因此框住整块而不是浮在第一行上；引用块的正文字用 `:muted` 上色，链接与代码保留各自设的颜色。表格整张是一个 grid：列轨道只解析一次，所有行共用同一组列边界，所以横竖都对齐，任何一行的长单元格都不会把该行挤出列线。各列按最宽单元格的内容分配宽度，并为每列保留一个不可再窄的下限：窄字符组成的一个词（单词、标识符、代码片段）整词保留，含宽字符的一段按固定上限（12 格）计入下限——中文可在字间断行，长句不必撑宽整列。较长的单元格在词边界换行。容器装不下各列下限时表格按底线上限溢出，而不是把列压到词以下。表格画外框、列与列之间的竖线和行与行之间的横线，表头行下方的那条横线比行间更重；调色板把斑马纹与表头行给成同一个表面时，斑马纹不再画。HTML 注释渲染为空。

#### Variable: etaf-ui-markdown-flavor

`etaf-ui-markdown-parse` 的默认方言。

**语义。** 显式的 FLAVOR 参数优先于它。`gfm` 启用 GitHub 扩展与 front matter，`commonmark` 只解析核心规范，特性 plist 可以逐项开关扩展。

**参见。** `etaf-ui-markdown-parse`、`etaf-ui-markdown-flavors`。

#### Variable: etaf-ui-markdown-flavors

具名方言与它们启用的扩展标志。

**语义。** `commonmark` 是 CommonMark 核心；`gfm` 加上渲染器也视为默认的 GitHub 扩展：表格、任务列表、删除线、裸自动链接、脚注与告警块，外加 front matter（它是文档约定而非 Markdown 扩展）。`etaf` 在 `gfm` 之上再读定义列表、上下标、缩写、`$` 公式、表情短代码、`==高亮==`、`::图标::`、`:kbd[按键]` 与 `:badge[文字]`。

**参见。** `etaf-ui-markdown-parse`。

#### Function: etaf-ui-markdown-extension-p (name)

返回正在解析的文档是否启用了扩展 NAME。

**参数。** NAME 是方言 `:extensions` 列表里的一个符号，例如 `emoji` 或 `definition-list`。

**返回。** 启用时返回 t，否则返回 nil。

**语义。** 解析器扩展先用它判断自己的语法要不要运行；未启用的语法原样留作字面文本，与 CommonMark 读法一致，扩展因此能在同一份解析器里开关而不分叉。它读的是当前解析的状态，所以在解析之外调用它没有意义。

**参见。** `etaf-ui-markdown-block-extensions`、`etaf-ui-markdown-inline-extensions`、`etaf-ui-markdown-flavors`。

#### Variable: etaf-ui-markdown-block-extensions

解析器新增的块级语法，按 （NAME RECOGNIZER） 列出。

**语义。** RECOGNIZER 接收剩余源行，认领时返回 （BLOCK . REST）；是否运行由 `etaf-ui-markdown-extension-p` 按方言的 `:extensions` 决定，未启用的语法原样留作字面文本，与 CommonMark 读法一致。新增一种块语法，就是在这里加一条识别器、再把名字加进方言，而不是为每种方言分叉一个解析器。

**参见。** `etaf-ui-markdown-inline-extensions`、`etaf-ui-markdown-flavors`。

#### Variable: etaf-ui-markdown-inline-extensions

解析器新增的行内语法，按 （NAME TRIGGER-CHAR RECOGNIZER） 列出。

**语义。** TRIGGER-CHAR 是能开启该语法的字符，缩写这类从词字符开始的识别器为 nil。RECOGNIZER 接收 （TEXT POSITION END），认领时返回 （NODE . NEXT）。同样受 `etaf-ui-markdown-extension-p` 约束：方言没启用的行内语法永不运行，其文字保持原样。

**参见。** `etaf-ui-markdown-block-extensions`、`etaf-ui-markdown-flavors`。

#### Variable: etaf-ui-markdown-emoji

渲染器绘制的表情短代码，按 （NAME . CHARACTER） 列出。

**语义。** 文档写 `:tada:`，页面显示对应字符；不在表里的名字保留冒号，`12:30:45` 这类时间永不当作短代码。要教渲染器更多表情就在这里加条目。

**参见。** `etaf-ui-markdown-flavors`。

#### Variable: etaf-ui-markdown-subscript-table

`~subscript~` 片段可用的字符，按 （CHAR . SCRIPT） 列出。

**语义。** 表里没有的字符保留源拼写，所以这种写法只画出 Unicode 能表达的形态，不臆造字形。

**参见。** `etaf-ui-markdown-superscript-table`、`etaf-ui-markdown-flavors`。

#### Variable: etaf-ui-markdown-superscript-table

`^superscript^` 片段可用的字符，按 （CHAR . SCRIPT） 列出。

**语义。** 表里没有的字符保留源拼写，所以这种写法只画出 Unicode 能表达的形态，不臆造字形。

**参见。** `etaf-ui-markdown-subscript-table`、`etaf-ui-markdown-flavors`。

#### Variable: etaf-ui-markdown-code-renderers

按围栏语言登记渲染器，形式是 （LANGUAGE . FUNCTION） 的 alist。

**语义。** FUNCTION 接收块与 ENV，返回一个 View，或返回 nil 以沿用默认渲染。需要外部程序的语言——图形语言、排版器——登记在这里，解析器因此保持纯粹；程序缺失只是意味着那个块显示源码。ENV 的 `:render-code-block` 优先于本表，调用方因此能覆盖一次而不改动这张表。

**返回。** 不适用；变量保存渲染器表。

**参见。** `etaf-ui-markdown-highlight-languages`、`etaf-ui-markdown-view-blocks`。

#### Variable: etaf-ui-markdown-highlight-languages

用 Emacs 模式为围栏代码着色的语言表，形式是 （LANGUAGE . MODE）。

**语义。** 一个语言在这里有模式条目，代码块就用该模式着色；不在表里的语言按纯文本绘制，不加载任何模式。新增语言就是加一条映射，着色仍然只在渲染时发生。

**返回。** 不适用；变量保存语言到模式的映射。

**参见。** `etaf-ui-markdown-code-renderers`、`etaf-ui-markdown-view-blocks`。

#### Variable: etaf-ui-markdown-gfm-features

GitHub Flavored Markdown 整体启用的特性 plist。

**语义。** 它是一份写全的标志清单：front matter、表格、任务列表、删除线、裸自动链接、脚注与告警块。方言各自写全自己的标志，所以日后 GFM 的变化不会悄悄改变老方言的含义；要自建方言可以从它起步。

**返回。** 不适用；变量保存特性 plist。

**参见。** `etaf-ui-markdown-flavors`、`etaf-ui-markdown-parse`。

#### Error: etaf-ui-markdown-error

Markdown 文档操作被拒绝时的条件。

**语义。** 未知方言名在解析时抛出；渲染时缺少 `:palette` 或点名调色板里没有的颜色键也在发布任何 View 之前抛出。数据是含描述字符串的列表。

**恢复。** 失败不产生半渲染的文档：解析失败没有块树，渲染失败没有 View 上屏。修正方言或补齐调色板键后重新调用。

**参见。** `etaf-ui-markdown-parse`、`etaf-ui-markdown-view-blocks`。

#### Function: etaf-ui-markdown-highlight-code (language text)

返回把 TEXT 当作 LANGUAGE 着色后的 run，无法着色时返回 nil。

**参数。** LANGUAGE 是围栏语言名，TEXT 是代码块正文。

**返回。** 覆盖 TEXT、按顺序排列的 `(:text STRING :props PLIST)` 列表，PLIST 是 Ebox 样式 plist；nil 表示整块用同一种颜色画。

**语义。** 它在该语言自己的 major mode 里跑这段文本，所以关键字、字符串、注释与数字的取色与源缓冲区里看到的一致。结果按 （LANGUAGE . TEXT） 缓存，下一次重绘只是一次查表。

**参见。** `etaf-ui-markdown-highlight-languages`、`etaf-ui-markdown-code-renderers`。

#### Function: etaf-ui-markdown-math-text (source)

把 TeX 公式 SOURCE 写成纯文本。

**参数。** SOURCE 是公式源码。

**返回。** 一个字符串。

**语义。** 这是排版近似而不是排版器：命令名换成它们的符号，`\frac{a}{b}` 变成 `a/b`，`\sqrt{x}` 变成 `√(x)`，`^{}` 与 `_{}` 变成该位置的 Unicode 字母。不认识的部分保留原字符，所以公式不会变成一行噪声。

**参见。** `etaf-ui-markdown-flavors`、`etaf-ui-markdown-parse`。

## 共享文档基础设施（`etaf-doc`）

<!-- index: etaf-doc; 文档缓存; 二维码; QuickJS 排版; 活文档资产; 文档协议; 编辑组件 -->

`etaf-doc` 包集中提供各文档应用共用的非语法层基础设施（包含 `etaf-ui-markdown-*` 以及六个可复用子系统）：有界 LRU 远程图片缓存、异步二维码生成、原生 QuickJS Mermaid 与 MathJax 排版、工作区沙箱活文档资产、带 schema 校验的自定义节点协议，以及编辑类 UI 组件。

### 文档缓存

#### Function: etaf-doc-cache-prune-directory (directory &optional max-bytes max-files)

调度 DIRECTORY 的延迟空闲 LRU 清理，使磁盘总占用不超过 MAX-BYTES 且文件数不超过 MAX-FILES。同一目录的重复调用合并到同一个空闲定时器上，避免缓存写入阻塞渲染。

#### Function: etaf-doc-cache-http-url-p (url)

当 URL 是以 `http://` 或 `https://` 开头的字符串时返回非 nil。

#### Function: etaf-doc-cache-image-url-p (url)

当远程 URL 指向受支持的图片扩展名时返回非 nil。

#### Function: etaf-doc-cache-image-path (url)

从内存表返回远程 URL 对应的本地缓存图片路径，未命中返回 nil。完全不触碰磁盘或网络，可在 `:render` 中安全调用。

#### Function: etaf-doc-cache-warm-urls (urls &optional directory)

不走网络 I/O，从 DIRECTORY 的磁盘已有文件把远程 URLS 预热进内存缓存表；至少预热了一条记录时返回非 nil。

#### Function: etaf-doc-cache-request-urls (urls on-ready &optional options)

为未缓存的远程图片 URLS 排队异步下载，缓存就绪时调用 ON-READY。OPTIONS 为 plist，接受 `:directory`、`:max-bytes`、`:max-files`、`:max-per-page` 与 `:live-p`。

### 二维码生成

#### Function: etaf-doc-qrcode-available-p ()

当 `qrencode` 可执行文件在 `exec-path` 中可用时返回非 nil。

#### Function: etaf-doc-qrcode-file (text &optional directory)

返回二维码负载 TEXT 在 DIRECTORY（或默认二维码缓存目录）下对应的确定性 PNG 缓存路径。

#### Function: etaf-doc-qrcode-request-texts (texts on-ready &optional directory)

为 DIRECTORY 下尚未缓存的二维码负载 TEXTS 排队异步运行 `qrencode` 子进程，每张 PNG 写入完成时调用 ON-READY。

### 原生 QuickJS 排版

#### Function: etaf-doc-typeset-available-p ()

当内嵌的 QuickJS + Pele + MathJax 原生动态模块已加载且就绪时返回非 nil。

#### Function: etaf-doc-typeset-info ()

返回已加载 QuickJS 原生模块的引擎元数据 plist，不可用时返回 nil。

#### Function: etaf-doc-typeset-options-json (kind palette &optional options)

根据语义调色板 PALETTE 生成 KIND（`mermaid` 或 `math`）对应的 JSON 选项字符串。OPTIONS 接受 `:font-size`、`:pixels`、`:cell-height`、`:scale`、`:font-family` 与 `:mono-family`。

#### Function: etaf-doc-typeset-request (key kind source options-json cache-dir on-done &optional on-error)

把 KEY 对应的 KIND（`mermaid` 或 `math`）源码 SOURCE 排队交给共享后台 QuickJS 工作线程，写出 `CACHE-DIR/KEY.svg`；成功调用 `(ON-DONE PATH)`，失败调用 `(ON-ERROR MESSAGE FATAL-P)`。

#### Function: etaf-doc-typeset-image-pixels (path)

通过快速文件头检测返回图片文件 PATH 的像素尺寸 `(WIDTH . HEIGHT)`，不可读时返回 nil。

#### Function: etaf-doc-typeset-grid-for-pixels (pixels max-columns &optional max-rows cell-metrics)

在 MAX-COLUMNS 与可选 MAX-ROWS 范围内按 CELL-METRICS `(CHAR-WIDTH . LINE-HEIGHT)` 计算保持 PIXELS `(WIDTH . HEIGHT)` 纵横比的字符网格尺寸 `(COLUMNS . ROWS)`。

### 工作区活文档资产

#### Function: etaf-doc-assets-workspace-root (dir)

返回包含 DIR 的规范工作区根目录（向上停在 `.git`、`.jj` 或 DIR 自身）。

#### Function: etaf-doc-assets-safe-path (dir relpath)

相对 DIR 解析 RELPATH 并严格限制在规范工作区根目录内，越界或路径穿越返回 nil。

#### Function: etaf-doc-assets-lang-for-path (path)

根据文件 PATH 的扩展名或文件名推断规范的语法高亮语言标签。

#### Function: etaf-doc-assets-read-slice (dir relpath &optional options)

从 DIR 所在工作区根目录下的 RELPATH 安全读取有界源码切片。OPTIONS 接受 `:lines`、`:region`、`:section`、`:symbol`、`:context`、`:lang`、`:default-lines`、`:max-bytes` 与 `:max-lines`。

#### Function: etaf-doc-assets-inspect-symbol (name &optional workspace-dir)

返回 Emacs 符号 NAME 的实时内省 plist（种类、签名、文档字符串、值预览与相对 WORKSPACE-DIR 的源码位置）。

#### Function: etaf-doc-assets-project-tree (dir relpath &optional options)

计算 DIR 工作区下 RELPATH 的有界目录树结构。OPTIONS 接受 `:depth` 与 `:max-entries`。

#### Function: etaf-doc-assets-git-log-async (dir on-done &optional options)

对 DIR 所在工作区异步执行 Git 或 Jujutsu 日志查询，完成后调用 `(ON-DONE RESULT)`。OPTIONS 接受 `:limit` 与 `:path`。

#### Function: etaf-doc-assets-git-diff-async (dir on-done &optional options)

对 DIR 所在工作区异步执行 Git 或 Jujutsu 差异查询，完成后调用 `(ON-DONE RESULT)`。OPTIONS 接受 `:rev` 与 `:path`。

### 文档节点协议

#### Function: etaf-doc-protocol-convert (type value)

将 VALUE 转换为文档属性类型 TYPE（`string`、`integer`、`number`、`boolean`、`keyword`、`symbol`、`list` 或 `(enum ...)`），不兼容时返回 nil。

#### Function: etaf-doc-protocol-validate-value (key decl value source &optional style)

当来自 SOURCE 的 VALUE 违反 KEY 的属性声明 DECL 时返回诊断消息字符串，合法时返回 nil；STYLE 控制提示格式。

#### Function: etaf-doc-protocol-check-declarations (type decls derived error-symbol &optional allow-nil-default)

校验节点 TYPE 的属性声明 DECLS 与派生键 DERIVED，声明形态不合法时报 ERROR-SYMBOL；ALLOW-NIL-DEFAULT 非 nil 时允许 nil 默认值。

#### Function: etaf-doc-protocol-define-node (registry type args contract error-symbol &optional shipped-p allow-nil-default)

按 CONTRACT 校验定义参数 plist ARGS，在哈希表 REGISTRY 中注册或更新节点 TYPE，违反契约时报 ERROR-SYMBOL；SHIPPED-P 标记内置定义以便取消定义时恢复。

#### Function: etaf-doc-protocol-undefine-node (registry styles type)

从 REGISTRY 与 STYLES 哈希表中恢复内置节点 TYPE 或移除用户自定义节点 TYPE。

#### Function: etaf-doc-protocol-load-directory (directory &optional label)

按文件名排序加载 DIRECTORY 下的所有 `.el` 扩展文件，诊断信息中使用 LABEL 标识来源。

### 编辑类组件

#### Function: etaf-doc-widget-leaf-button (palette label on-press &rest opts)

按 PALETTE 返回带 LABEL 与 ON-PRESS 的单 face 可交互叶子控件。OPTS 接受 `:color`、`:background`、`:hover-bg`、`:help`、`:active`、`:ref` 与 `:padding`。

#### Function: etaf-doc-widget-pill (palette label active-p on-press &optional help hover-p)

按 PALETTE 返回带 LABEL 的紧凑切换胶囊，反映 ACTIVE-P 并在激活时调用 ON-PRESS，支持可选 HELP 提示与 HOVER-P 悬停样式。

#### Function: etaf-doc-widget-status-badge (palette text variant)

按 PALETTE 返回无边框柔色状态徽章，以语义 VARIANT（`ok`、`warn`、`danger`、`important`、`accent` 或 `muted`）展示 TEXT。

#### Function: etaf-doc-widget-notice (palette message &optional variant)

按 PALETTE 与可选 VARIANT 返回行内提示条或加载条，展示 MESSAGE。

#### Function: etaf-doc-widget-progress-bars (palette rows available-width &optional options)

按 PALETTE 与可选显示 OPTIONS，将 ROWS 渲染为适配 AVAILABLE-WIDTH 的无边框编辑风格进度条组。

#### Function: etaf-doc-widget-line-chart (palette series available-width &optional options)

按 PALETTE 与可选坐标轴 OPTIONS，将 SERIES 渲染为适配 AVAILABLE-WIDTH 的不折行框线折线图。

#### Function: etaf-doc-widget-source-card (palette title meta code-view &optional options)

按 PALETTE 渲染包裹 CODE-VIEW 的单框活文档源码卡片，展示 TITLE、META 元信息标签与可选动作 OPTIONS。

## 错误与恢复

- 日期选择器区分草稿与错误：尚不完整的日期文本只是不被报告，提交它报 `user-error` 且不写入值；取消会话恢复激活时的值。
- 面板组合列表的校验：形式非法的 item 列表在任何表面出现之前就以 `etaf-component-call-error` 失败，缺少关闭回调同样失败。
- 扫码登录面板在表面出现前校验属性，对话框自带关闭回调校验；后端失败放进 STATUS，因为面板不发请求，也没有自己的传输错误。
- 三个组件都无状态：被拒绝的输入让调用方的值与已挂载实例保持原样。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)。

```elisp :run
(etaf-view
 (column :width '(ch 60) :height '(lh 18) :item-gap '(lh 1)
   (etaf-date-picker :value "2026-01-15" :label "Due")
   (etaf-command-palette :open t :on-close #'ignore :on-select #'ignore
                         :items '((:key save :title "Save file")))))
```
