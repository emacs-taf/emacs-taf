# 交互使用

字符串接口排版它自己拥有的文本；本章的缓冲区命令排版用户拥有的文本。排版是一种投影：EKP 为一个硬段落算出方案，并把它作为显示属性装到现有字符上。字符序列从不改变，因此保存、搜索、语法高亮与普通 Lisp 看到的是逻辑文本，而窗口显示的是两端对齐的行。移除投影会恢复缓冲区的朴素外观，任何只是排版决定的东西都不可能进入文件。

本章定义交互层：排版与撤销排版命令、带编辑事务的自动模式、会话局部保护区域、Org 与 Markdown 接入，以及布局诊断。[断行原理](ekp-principles.md)给出断行模型，[CJK 排版](ekp-cjk.md)给出禁止与行缘规则，[断字](ekp-hyphenation.md)给出断字模型。这里点名的每个宽度、容差与策略都是用户选项，汇总在[参数参考](ekp-parameters.md)一章。

## 投影模型

<!-- index: 投影; 缓冲区排版; 会话局部保护; 有效宽度; 布局冲突 -->

投影只通过文本属性触碰缓冲区。不插入、删除或移动任何字符，不创建 overlay，不写入文件局部状态，因此缓冲区的文本、point、mark 与 marker 的行为与之前完全一样。投影的安装过程抑制修改记录：排版不会置位 modified 标志、不产生 undo 条目、不运行外部 change 钩子。point 与 mark 的位置、以及标记是否活跃，都在操作前后保持不变。

一个排版单位是一个硬段落：换行之间的文本。每个段落独立规划，因此硬换行总会保留，投影过的区域只包含与它相交的段落。段落里有些内容按设计保持原样：**会话局部**标记为逐字（verbatim）的段落、戴有该缓冲区跳过集合中脸的段落、被缓冲区跳过谓词接受的段落、包含字段或只读文本的段落，以及带有外来 display 或 line-prefix 所有者的段落，全都不参与投影。当自动模式因为段落超过规划上限、或因为 EKP 的 `natural` 超宽 token 策略而跳过某个段落时，诊断会记录原因。

投影使用的宽度是有效宽度：默认是显示该缓冲区的最窄活动窗口，或者缓冲区宽度选项选定的固定宽或带上限的宽。换行与方案都由该宽度算出，因此投影只对规划时所用的窗口成立；在另一个宽度上重排，就是用那个宽度再调一次排版，或者在自动模式启用时改变窗口大小。

只要缓冲区还带有任何投影，EKP 就安装它的复制与 kill 集成，在复制文本时剥掉 EKP 的布局属性，同时保留其它属性以及缓冲区原有的任何过滤器。最后一个投影消失时集成也会被移除，因此从未排版过的缓冲区不受影响。

## 排版与撤销

#### Function: ekp-justify-region (beg end &optional pixel)

在不改变文本的前提下把 BEG 到 END 投影为 PIXEL 宽的 KP 布局。

**参数。** BEG 与 END 界定区域，顺序无所谓。PIXEL 是目标像素宽；省略时按有效宽度投射该区域，即显示缓冲区的最窄活动窗口，或宽度选项选定的固定宽或带上限的宽。

**语义。** 区域按硬段落切分，每段独立规划并独立安装，因此段落始终留在自己的换行之间。给出 PIXEL 时它必须是正整数。受保护内容按投影模型所述跳过。区域里已有的投影会被替换：同一宽度重复排版与只排一次结果相同，换宽度排版是全新布局而不是叠加。操作保留 point、mark 与活动区域；若 font lock 启用且存在任何基于脸策略，它会先把区域 fontify 到最新。交互调用读取区域，没有活动区域时用 point 所在的硬段落，并把数值前缀参数当作 PIXEL；交互调用还会拒绝只读缓冲区。

**返回。** 未指定；投影就是效果。

**错误。** PIXEL 为零、负数或非整数时 `error→ user-error`，消息为 `Line width must be a positive integer, got PIXEL`。只读缓冲区中的交互调用在做任何事之前报 `buffer-read-only`。

**示例。**

```elisp
(with-current-buffer "notes.txt"
  (ekp-justify-region (point-min) (point-max))
  (buffer-substring-no-properties (point-min) (point-max)))
     ⇒ the original characters, now displayed as justified lines
```

**参见。** `ekp-unjustify-region`、`ekp-justify-buffer`。

#### Function: ekp-justify-buffer (&optional pixel)

把可访问的缓冲区投影为 PIXEL 宽的 KP 布局。

**参数。** PIXEL 是目标像素宽，与 `ekp-justify-region` 一样缺省为有效宽度。

**语义。** 它就是对整个可访问区域调用 `ekp-justify-region`，因此 narrowing 会像那里一样限制工作范围；硬段落、保护、替换旧投影以及保持 point 与 mark 的行为都相同。交互调用把数值前缀参数当作 PIXEL，并拒绝只读缓冲区。

**返回。** 未指定；投影就是效果。

**错误。** PIXEL 非法时 `error→ user-error`；只读缓冲区中的交互调用报 `buffer-read-only`。

**示例。**

```elisp
(with-current-buffer "notes.txt"
  (ekp-justify-buffer))
     ⇒ every hard paragraph in the accessible region projected at window width
```

**参见。** `ekp-justify-region`、`ekp-unjustify-buffer`。

#### Function: ekp-unjustify-region (beg end)

移除与 BEG 到 END 相交的 EKP 显示投影。

**参数。** BEG 与 END 界定区域，顺序无所谓。

**语义。** 与区域相交的每个投影都会被移除，包括延伸出区域之外的投影：移除单位是受影响的投影，而不是参数字符范围。文本与非 EKP 属性保持原样。缓冲区里最后一个投影消失时，复制与 kill 集成也一并移除，缓冲区回到排版前的状态。交互调用与排版一样使用活动区域或 point 所在段落。

**返回。** 未指定；移除就是效果。

**错误。** 自身没有错误。它不要求区域曾经被投影；只读缓冲区中的交互调用在触碰任何东西之前报 `buffer-read-only`。

**示例。**

```elisp
(ekp-unjustify-region (point-min) (point-max))
     ⇒ the whole buffer displays as plain text again
```

**参见。** `ekp-justify-region`、`ekp-unjustify-buffer`。

#### Function: ekp-unjustify-buffer ()

移除可访问缓冲区的 EKP 显示投影。

**参数。** 无。

**语义。** 它移除可访问区域里的全部投影，效果与对整缓冲区调用 `ekp-unjustify-region` 相同，并在不再有任何投影时撤掉复制与 kill 集成。哪些内容曾被投影由投影本身决定，因此被 narrowing 的缓冲区只释放可访问的那部分。

**返回。** 未指定；移除就是效果。

**错误。** 只读缓冲区中的交互调用报 `buffer-read-only`；Lisp 调用则不管缓冲区的只读标志都移除投影，因为投影是显示状态而不是文本。

**示例。**

```elisp
(ekp-unjustify-buffer)
     ⇒ no EKP layout properties remain in the buffer
```

**参见。** `ekp-unjustify-region`、`ekp-justify-buffer`。

## 自动模式

`ekp-auto-justify-mode` 让已完成的段落保持投影，同时继续普通编辑。这个模式不会每敲一个键就重排一切，因为边输入边做整段重排既慢又打扰。它在正在编辑的行周围维护一个编辑事务：在活动视觉行内打字只改变该行的显示，周围的已提交行原样保留；当编辑自然跨过一条视觉行、硬换行或段落完成、下一次真实编辑发生在别处、显式 refill，或者宽度、字体、脸、布局上下文变化时，才发布一份完整方案。单纯移动 point 从不规划也不写入任何东西，也没有任何空闲定时器会把整段突然对齐。

模式跟随缓冲区的有效宽度，因此投影跟得上窗口。改变窗口大小会先经过 resize 延迟防抖再重排，避免拖动窗口时对每个中间尺寸都跑一次重排。大缓冲区采用可见优先重排：屏幕上的部分立即更新，其余按有界后台分块跟进。自动规划还受每段上限约束，因此很长的段落保持自然、保持可编辑，而不会阻塞输入；`ekp-refill-paragraph` 是显式命令，对 point 所在段落执行不受上限约束的完整一遍。

模式与手动命令一样不改动文本：启用、编辑、改变窗口大小与关闭都不产生 undo 条目、不置位 modified 标志、不运行外部 change 钩子。它会暂时接管缓冲区的行截断，使窄的并排窗口仍能软换行；关闭模式时会连同移除全部投影一起，把那些设置的所有权还给原来的一方。

#### Function: ekp-auto-justify-mode (&optional arg)

维护一个不改动文本的 KP 显示投影。

**参数。** ARG 遵循次模式约定：省略、nil 或正数启用模式，零或负数关闭，`toggle` 翻转。交互调用不带前缀参数时翻转。

**语义。** 启用时先计算有效宽度，投影已完成段落，安装监视窗口大小、滚动、文字缩放、字体与主题变化以及缓冲区变化的钩子，并安装复制与 kill 集成。模式开启期间，活动硬段落按上文所述在局部编辑事务里编辑，模式菜单提供排版、撤销排版、区域保护与诊断命令。关闭时取消待决的异步工作与定时器，释放编辑事务，移除全部投影，并恢复模式改动过的截断所有权。已完成段落使用有效宽度；因为模式会查询缓冲区的模式 profile 与跳过规则，Org 或 Markdown 缓冲区对代码的保护，与显式调用 `ekp-org-setup` 或 `ekp-markdown-setup` 的效果相同。

**返回。** `ekp-auto-justify-mode` 的新值。

**错误。** 缓冲区的宽度选项既不是 `narrowest-window`、也不是正整数、也不是 `(max . N)`（N 为正）时 `error→ error`，消息为 `Invalid ekp-buffer-measure: MEASURE`。失败发生在安装任何投影之前，因此缓冲区保持原样。

**示例。**

```elisp
(ekp-auto-justify-mode 1)
     ⇒ t
(ekp-auto-justify-mode -1)
     ⇒ nil
```

**参见。** `ekp-refill-paragraph`、`ekp-diagnose`、`ekp-justify-buffer`。

#### Function: ekp-refill-paragraph ()

对 point 所在的硬段落应用完整 KP 布局。

**参数。** 无。

**语义。** 它释放自动模式对该段落的活动编辑事务与已提交状态，然后用一次排版调用按有效宽度排版整个硬段落。约束自动规划的那条上限不适用：当长段落必须真正被排版而不是保持自然时，就运行这条命令；在模式之外，它也可以用来在编辑之后重新投影单个段落。在模式的键位图里，它取代普通的 `fill-paragraph` 命令。

**返回。** 未指定；段落的投影就是效果。

**错误。** 只读缓冲区中的交互调用报 `buffer-read-only`。宽度选项非法时的失败与 `ekp-auto-justify-mode` 相同。

**示例。**

```elisp
(with-current-buffer "notes.txt"
  (ekp-refill-paragraph))
     ⇒ the paragraph at point planned as a whole, however long it is
```

**参见。** `ekp-auto-justify-mode`、`ekp-justify-region`。

## 保护区域

有两种会话局部保护把特定内容排除在排版之外。不断区域成为刚性原子：无论宽度多窄，EKP 都不会在它内部断行、不会对它断字、不会拉伸它内部的间隙。逐字区域让整段保持原样：与区域相交的任何段落都由 Emacs 自己的换行排版。两种保护都作为文本属性活在缓冲区里，只对当前缓冲会话生效，保存并重新打开文件后消失；由配对的清除命令移除。

保护命令都有可选的 ANNOUNCE 参数。非 nil 时，命令在回显区报告效果，并说明它只在当前缓冲会话内有效。交互调用总是传入 ANNOUNCE，并使用活动区域。

#### Function: ekp-no-break-region (beg end &optional announce)

把 BEG 到 END 标为不可断的会话局部原子。

**参数。** BEG 与 END 界定区域。ANNOUNCE 请求交互反馈。

**语义。** 被标记的范围在之后每次投影里都表现为一个原子：内部的断点与断字点一概不用，内部的胶保持刚性，因此超宽原子宁可占一行溢出也不拆开。这条保护强于断行策略，并且在任何方向的重新排版中都持续存在，因为它是排版的输入而不是结果。重复标记已受保护的范围是幂等的，标记已有原子的一部分会扩展保护。

**返回。** 未指定；标记就是效果。

**错误。** 无。区域可以为空，也可以跨多个段落。

**示例。**

```elisp
(ekp-no-break-region 10 25)
     ⇒ "the-no-break-atom" keeps its shape at any width
```

**参见。** `ekp-allow-break-region`、`ekp-verbatim-region`。

#### Function: ekp-allow-break-region (beg end &optional announce)

清除 BEG 到 END 的不可断区域保护。

**参数。** BEG 与 END 界定区域。ANNOUNCE 请求交互反馈。

**语义。** 它移除该范围的不断保护；之后的投影又可以在那里断行与断字。清除从未受保护的范围、或只清已受保护原子的一部分，都是允许的，且只移除范围覆盖到的部分。命令自身不会重新投影；改动在区域下次被排版时生效，自动模式下则在区域策略变化后立即重排。

**返回。** 未指定；移除就是效果。

**错误。** 无。

**示例。**

```elisp
(ekp-allow-break-region 10 25)
(ekp-justify-region 1 40 20)
     ⇒ the former atom may now wrap at any legal point inside it
```

**参见。** `ekp-no-break-region`、`ekp-clear-verbatim-region`。

#### Function: ekp-verbatim-region (beg end &optional announce)

让与 BEG 到 END 相交的段落本次会话保持逐字。

**参数。** BEG 与 END 界定区域。ANNOUNCE 请求交互反馈。

**语义。** 与范围相交的每个硬段落都保持缓冲区的自然换行，而缓冲区其余部分照常投影。单位是段落而不是被标记的字符：标记单个词会保护包含它的整个段落，因为对单段做部分排版没有意义。保护是会话局部的，而且是排版的输入，所以与排版的先后无关：先标记再排版、或先排版再标记，该段落都保持自然。

**返回。** 未指定；标记就是效果。

**错误。** 无。

**示例。**

```elisp
(ekp-verbatim-region (point) (line-end-position))
(ekp-justify-buffer)
     ⇒ the paragraph at point keeps its own wrapping
```

**参见。** `ekp-clear-verbatim-region`、`ekp-org-setup`、`ekp-markdown-setup`。

#### Function: ekp-clear-verbatim-region (beg end &optional announce)

清除 BEG 到 END 的逐字保护。

**参数。** BEG 与 END 界定区域。ANNOUNCE 请求交互反馈。

**语义。** 它移除该范围的逐字保护，于是相交的段落重新可以被投影。与不断清除命令一样，移除在下一次排版调用时生效，自动模式下则立即生效；它也是把保护误加到错误段落时的撤销手段。

**返回。** 未指定；移除就是效果。

**错误。** 无。

**示例。**

```elisp
(ekp-clear-verbatim-region (point) (line-end-position))
(ekp-refill-paragraph)
     ⇒ the paragraph is projected again
```

**参见。** `ekp-verbatim-region`、`ekp-allow-break-region`。

## Org 与 Markdown

Org 与 Markdown 用脸限定代码范围，每个主模式的模式 profile 都列出必须保持逐字的块脸，以及使用行内代码断行策略的行内脸。自动模式开启时这些预设自动生效；两个 setup 函数把同一份策略复制进缓冲区局部变量，供手动排版使用，因此在 Org 或 Markdown 缓冲区里调用一次 `ekp-justify-buffer` 就能保护代码，无需更多配置。

#### Function: ekp-org-setup ()

保护当前缓冲区里常见的 Org 结构脸。

**参数。** 无。

**语义。** 它把缓冲区的跳过脸列表设为 Org 的结构脸——block、block-begin-line、block-end-line、table 与 meta-line——把行内脸列表设为 `org-code` 与 `org-verbatim`。戴跳过脸的段落保持逐字；戴行内脸的区间遵循行内代码策略，默认策略保持其源码间距原样、抑制字典断字，但仍允许普通断点。这些值是缓冲区局部的：在某个缓冲区里调用本函数不影响别的缓冲区，也不改动全局默认值。

**返回。** 未指定；缓冲区局部的脸列表就是效果。

**错误。** 无。

**示例。**

```elisp
(add-hook 'org-mode-hook #'ekp-org-setup)
     ⇒ Org code blocks stay verbatim under manual justification
```

**参见。** `ekp-markdown-setup`、`ekp-verbatim-region`。

#### Function: ekp-markdown-setup ()

保护当前缓冲区里常见的 Markdown 代码脸。

**参数。** 无。

**语义。** 它是 `ekp-org-setup` 的 Markdown 对应物：把缓冲区局部的跳过脸设为 code、pre 与 table 脸，把行内脸设为行内代码脸。随后适用同样的规则——块脸让所在段落保持逐字，行内区间遵循行内代码策略。派生自 `markdown-mode` 的模式通过模式 alist 继承这份 profile，显式调用本函数则把选择固定在当前缓冲区。

**返回。** 未指定；缓冲区局部的脸列表就是效果。

**错误。** 无。

**示例。**

```elisp
(add-hook 'markdown-mode-hook #'ekp-markdown-setup)
     ⇒ fenced code stays verbatim while prose is justified
```

**参见。** `ekp-org-setup`、`ekp-verbatim-region`。

## 诊断布局

当缓冲区看起来不像源码所暗示的样子时，问题通常在于用了哪个宽度、以及哪些段落被跳过。`ekp-diagnose` 不改动任何东西就同时回答这两点：它报告宽度情况、当前生效策略，以及上一次排版记录的每个冲突。

#### Function: ekp-diagnose ()

报告权威宽度与任何被跳过的投影冲突。

**参数。** 无。

**语义。** 它读取缓冲区的窗口、宽度选项与策略上下文，在回显区发一条摘要：请求的宽度模式、最窄活动窗口宽度、有效宽度、有效宽度是否超过窗口（溢出风险），以及冲突数量，随后是当前生效的行内代码、断字、禁则与超宽 token 策略。冲突列表为上一次排版没有投影的每个段落保存一条记录，含范围与原因，例如外来 display 所有者或自动段落上限。

**返回。** 一份诊断 plist，含请求值、最窄值、有效值与 `:width`，`:overflow-risk` 标志，本次排版所用的 `:policy` plist，以及 `:conflicts` 列表。plist 是全新数据；改动它不影响缓冲区。

**错误。** 无。诊断从未排版过的缓冲区时报告零冲突，以及一次排版将会使用的宽度。

**示例。**

```elisp
(let ((report (ekp-diagnose)))
  (list (plist-get report :width) (plist-get report :conflicts)))
     ⇒ (77 ((1 45 "foreign `display' property")))
```

**参见。** `ekp-auto-justify-mode`、`ekp-justify-region`。

## 错误与恢复

交互层的失败模式很少，而且没有一个会损坏文本。宽度参数要么是正整数，要么是用户错误：`ekp-justify-region`、`ekp-justify-buffer` 与自动模式（经由其宽度选项）都会校验将要使用的宽度，被拒绝的调用什么都不改。只读缓冲区里的交互命令在开始前报 `buffer-read-only`；从 Lisp 调用同一命令则不受只读标志阻拦，因为安装或移除显示状态并不修改缓冲区。

恢复直接来自模型。宽度不合法就换一个合法宽度再调一次；缓冲区只读就先行解锁。投影总可以用撤销排版命令移除，保护总可以用配对的清除命令移除，因此误排版或误保护的缓冲区无需编辑文本就能回到朴素状态。保护是会话局部的，保存并重新打开文件不留残留；重新施加保护是有意而明确的动作。
