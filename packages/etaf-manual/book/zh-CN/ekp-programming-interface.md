# 编程接口

EKP 可以完全脱离缓冲区使用。字符串接口把文本当作值来接收、把排版好的文本当作值返回，从不触碰当前缓冲区或窗口：应用把它嵌进来排版一段即将显示的正文，其它包调用它为自己渲染器准备文本。本章定义这条边界：两个排版调用、它们背后的语义方案，以及与之配套的缓存控制。

断行模型见[断行原理](ekp-principles.md)；把同一批方案投影到编辑缓冲区的命令见[交互使用](ekp-interactive-use.md)。控制宽度选择、断字、禁则与超宽 token 策略的选项都是用户选项，汇总在[参数参考](ekp-parameters.md)一章；本章在函数结果取决于它们时点名。

## 字符串边界

<!-- index: 字符串排版; 段落; 布局方案; 缓存; 自然超宽 token -->

一个字符串参数是由换行符分隔的一个或多个段落。每个换行分隔的片段作为独立段落规划，空片段保持为空：空行保留在输入放置它们的位置，任何断行决定都不跨越换行。段落层面没有单独的宽度参数——宽度参数就是段落规划所依据的整个行宽。

输入上的文本属性与在缓冲区里一样被尊重：刚性不可断原子保持完整，携带断行策略的区间保住策略，因此纯字符串的一段文字也能被强制断字或禁止断字。逐字保护属于缓冲区层——字符串接口会规划收到的每一个段落——所以想原样保留段落的调用方，直接不要把它传进来。

排版的结果是一个新字符串，而不是对参数的改动。它包含源字符，加上让段落两端对齐的合成间距与断行；被替换掉的源片段记录为文本属性，供包自己的缓冲区层在同一个字符串插入缓冲区时反变换。因此需要未改动源文本的调用方保留输入；对结果去掉属性并不能还原它。调用是确定性的：同样的字符串与宽度产生相等的（含属性的）结果。

原生模块已加载且输入多于一个非空段落时，字符串排版会先并行规划各段落再渲染，这正是由许多短段落组成的宽文档能快起来的原因；结果不取决于是否走了这条路径。本层里有一个策略有可见的捷径：`ekp-overlong-token-policy` 为 `natural` 且段落里含有宽过行宽的普通拉丁式 token 时，该段落原样返回而不做规划，整段交给 Emacs 换行。

## 排版字符串

#### Function: ekp-pixel-justify (string line-pixel)

把多行 STRING 排版到 LINE-PIXEL 像素宽。

**参数。** STRING 是文本，每个换行分隔的片段是一个段落。LINE-PIXEL 是目标像素宽，必须是正整数。

**语义。** 每个非空段落按 LINE-PIXEL 规划并渲染；空片段原样复制。STRING 上的文本属性按字符串边界所述充当排版输入，被超宽 token 策略判为自然的段落原样返回。原生模块可用且输入含多个段落时，规划并行进行。结果是全新的确定性字符串：同样的输入与宽度总产生相等的结果。

**返回。** 排版后的字符串。它的可见形式就是两端对齐的段落；每次合成所替换的源文本片段记录在它的文本属性里，供包自己的渲染层使用。

**错误。** STRING 不是字符串时 `error→ wrong-type-argument`，数据点名 `stringp`。LINE-PIXEL 不是正整数时 `error→ user-error`，消息为 `Line width must be a positive integer, got PIXEL`。规划本身的错误原样传播，例如选中的字典不可用时抛 `ekp-hyphen-unsupported-pattern`。

**示例。**

```elisp
(ekp-pixel-justify "one two three four five six seven eight nine ten" 60)
     ⇒ the same words laid out at a 60-pixel measure
(length (split-string
         (ekp-pixel-justify "one two three four five six seven eight nine ten" 60)
         "\n"))
     ⇒ 1 with automatic spacing, 2 after (ekp-param-set 4 8 2 3 6 2 0 4 0)
```

**参见。** `ekp-pixel-range-justify`、`ekp-layout-plan`、`ekp-clear-caches`。

#### Function: ekp-pixel-range-justify (string min-pixel max-pixel)

在 MIN-PIXEL 与 MAX-PIXEL 之间为 STRING 找出最优宽度。

**参数。** STRING 是文本，规划方式与 `ekp-pixel-justify` 完全一致。MIN-PIXEL 与 MAX-PIXEL 是限定候选宽度的正整数，且 MIN-PIXEL 不得大于 MAX-PIXEL。

**语义。** 函数在区间内搜索使各段平均代价最低的宽度——代价是段落支付的代价，对非空段落取平均，因此很长的输入不会压过很短的输入。搜索是三分搜索加一次局部扫描，得到的是好的局部最优而不是保证：所选行数一变，代价关于宽度就会跳变，曲线并非严格单峰。区间只有一个宽度是合法的，直接按该宽度排版。返回的文本正好等于按返回宽度调用 `ekp-pixel-justify` 的结果。

**返回。** 一个 cons 单元 `(JUSTIFIED . PIXEL)`：排版后的字符串与从区间中选出的宽度。

**错误。** STRING 不是字符串时 `error→ wrong-type-argument`，数据点名 `stringp`。任一界限不是正整数时 `error→ user-error`，消息为 `Line width must be a positive integer, got WIDTH`；界限颠倒时消息为 `Min-pixel (MIN) must be <= max-pixel (MAX)`。

**示例。**

```elisp
(ekp-pixel-range-justify
 "Pack my box with five dozen liquor jugs. The five boxing wizards jump quickly."
 60 120)
     ⇒ (justified-text . 116)
```

**参见。** `ekp-pixel-justify`、`ekp-layout-plan`。

## 布局方案

字符串接口渲染它的方案，缓冲区接口投影它，而调用方也可以直接索取方案本身。方案是「决定」与「显示」之间的表示边界：它描述段落长什么样——哪些源盒子同处一行、胶放在哪里放多少、可选连字符取在何处——而不承诺空格、换行、文本属性或任何其它输出形式。它既是包自己的渲染器消费的对象，也是未来消费者用来在别处显示同一布局的对象。

方案要么是 `planned`，要么是 `natural`。规划好的方案携带各行；自然方案不带任何行，并记录该段落因超宽 token 策略而交给 Emacs 换行。驱动字符串排版的那组策略输入同样驱动方案，因此方案就是某个宽度上一次布局决定的完整描述。

#### Function: ekp-layout-plan (string line-pixel)

返回 STRING 在 LINE-PIXEL 宽下的语义 KP 布局方案。

**参数。** STRING 是一个或多个段落的文本，与排版调用一样按换行切分。LINE-PIXEL 是目标像素宽。

**语义。** 方案记录段落的源偏移、各行、每行的胶目标、缩进与剥掉的行缘，以及该行是否以可选连字符结尾。布局是完整的，但没有显示表示：方案里没有任何东西说明空格就是空格字符、断行就是换行。被超宽 token 策略判为自然的段落方案没有行，状态为 `natural`；否则状态为 `planned`。方案按段落与布局上下文缓存，命中时返回调用方拥有的副本，因此改动收到的东西不会影响之后的方案。与两个排版调用不同，本函数不校验宽度：小到放不下一个盒子的宽度也会被接受，并产生每个盒子一行的方案。

**返回。** 一份布局方案记录。经 `ekp-layout-plan-string`、`ekp-layout-plan-lines` 与 `ekp-layout-plan-state` 读取它，再用 `ekp-layout-line-*` 行读取器与 `ekp-layout-gap-*` 胶读取器读取细节。

**错误。** STRING 既不是字符串也不是缓冲区时 `error→ wrong-type-argument`，数据点名 `buffer-or-string-p`。不校验宽度：任何整数都会被接受。

**示例。**

```elisp
(ekp-layout-plan "aaaa bbbb cccc dddd eeee ffff gggg" 30)
     ⇒ a plan with two lines, the first ending after "ffff"
```

**参见。** `ekp-pixel-justify`、`ekp-clear-caches`。

#### Function: ekp-layout-plan-string (plan)

返回 PLAN 计划时所依据的清理后源文本。

**语义。** 方案的源偏移索引这个字符串，所以某一行的源范围切出的就是它渲染的确切文本。

**返回。** 源字符串。

**错误。** error→ `wrong-type-argument` `(ekp-layout-plan PLAN)`：PLAN 是另一种值时。

**参见。** `ekp-layout-plan`、`ekp-layout-line-source-start`。

#### Function: ekp-layout-plan-lines (plan)

把 PLAN 的显示行作为行记录向量返回。

**语义。** 每行带它渲染的源范围、前后像素、可选连字符标志与语义胶。状态为 `natural` 的方案返回空向量。

**返回。** 行记录向量。

**错误。** error→ `wrong-type-argument` `(ekp-layout-plan PLAN)`：PLAN 是另一种值时。

**参见。** `ekp-layout-plan-state`、`ekp-layout-line-source-start`。

#### Function: ekp-layout-plan-state (plan)

返回 PLAN 的状态：`planned`，或被超宽 token 策略判为不打断的 `natural`。

**语义。** 读行之前先读它：`natural` 方案保持字符串不打断、没有行，渲染器应把源文本显示在测量宽度之外，而不是使用计划好的断点。

**返回。** 状态符号。

**错误。** error→ `wrong-type-argument` `(ekp-layout-plan PLAN)`：PLAN 是另一种值时。

**参见。** `ekp-layout-plan-lines`。

#### Function: ekp-layout-line-index (line)

返回 LINE 在所属方案里的零基序号。

**语义。** 行按显示顺序排列，所以序号也是渲染器会显示的行号。

**返回。** 整数行号。

**错误。** error→ `wrong-type-argument` `(ekp-layout-line LINE)`：LINE 是另一种值时。

**参见。** `ekp-layout-line-source-start`。

#### Function: ekp-layout-line-source-start (line)

返回 LINE 起始的源偏移。

**语义。** 偏移索引 `ekp-layout-plan-string`；与 `ekp-layout-line-source-end` 一起，这个范围就是该行渲染的确切文本。

**返回。** 整数起始偏移。

**错误。** error→ `wrong-type-argument` `(ekp-layout-line LINE)`：LINE 是另一种值时。

**参见。** `ekp-layout-line-source-end`。

#### Function: ekp-layout-line-source-end (line)

返回 LINE 源范围之后的那个源偏移。

**语义。** 终点不含断行本身，所以相邻行不重叠，两段之间的文本就是断行吃掉的那个空白或连字符。

**返回。** 整数结束偏移。

**错误。** error→ `wrong-type-argument` `(ekp-layout-line LINE)`：LINE 是另一种值时。

**参见。** `ekp-layout-line-source-start`。

#### Function: ekp-layout-line-leading-pixel (line)

返回 LINE 在第一个盒子之前保留的像素宽。

**语义。** 这个宽度覆盖行的缩进与布局剥掉的行缘，渲染器在行的源文本前加上它。

**返回。** 前导像素宽。

**错误。** error→ `wrong-type-argument` `(ekp-layout-line LINE)`：LINE 是另一种值时。

**参见。** `ekp-layout-line-trailing-pixel`。

#### Function: ekp-layout-line-trailing-pixel (line)

返回 LINE 在最后一个盒子之后携带的尾随像素宽。

**语义。** 行的总宽是前导、内容、各行内胶与尾随之和；不调节的行把余量留在这里。

**返回。** 尾随像素宽。

**错误。** error→ `wrong-type-argument` `(ekp-layout-line LINE)`：LINE 是另一种值时。

**参见。** `ekp-layout-line-leading-pixel`。

#### Function: ekp-layout-line-hyphen-p (line)

LINE 以可选连字符结尾时返回非 nil。

**语义。** 带连字符的断行会插入源文本里没有的连字符，渲染器要在行的源范围之后补上它。

**返回。** 行尾带连字符时非 nil，否则 nil。

**错误。** error→ `wrong-type-argument` `(ekp-layout-line LINE)`：LINE 是另一种值时。

**参见。** `ekp-layout-line-source-end`。

#### Function: ekp-layout-line-gaps (line)

把 LINE 的语义胶作为胶记录向量返回。

**语义。** 每条胶位于两个盒子之间，带它覆盖的源范围、自然宽与布局选定的目标宽；相邻盒子之间零宽的胶不出现。渲染时按顺序把胶插进行内盒子之间。

**返回。** 胶记录向量。

**错误。** error→ `wrong-type-argument` `(ekp-layout-line LINE)`：LINE 是另一种值时。

**参见。** `ekp-layout-gap-target-pixel`。

#### Function: ekp-layout-gap-natural-pixel (gap)

返回 GAP 未经伸展的自然像素宽。

**语义。** 与 `ekp-layout-gap-target-pixel` 比较，可以看出布局把这条胶拉伸或压缩了多少。

**返回。** 自然像素宽。

**错误。** error→ `wrong-type-argument` `(ekp-layout-gap GAP)`：GAP 是另一种值时。

**参见。** `ekp-layout-gap-target-pixel`。

#### Function: ekp-layout-gap-target-pixel (gap)

返回布局为 GAP 选定的目标像素宽。

**语义。** 目标宽是渲染器应给这条胶的宽度，好让该行到达测量宽；不调节的行里它等于自然宽。

**返回。** 目标像素宽。

**错误。** error→ `wrong-type-argument` `(ekp-layout-gap GAP)`：GAP 是另一种值时。

**参见。** `ekp-layout-gap-natural-pixel`。

## 缓存

排版是确定性的，但代价高昂，因此结果会被缓存。段落缓存按字符、文本属性、字体、宽度上下文与影响排版的选项保存段落的切分、测量与索引形态；每段一份的动态规划缓存按宽度与罚分设置保存选中的断点与代价；方案缓存保存语义方案本身。单个字形的测量同样有缓存。这些缓存对结果不可见——清掉它们只改变速度，从不改变输出——所以一条命令就足以处理唯一会使测量失效的情况：改变字形宽度的字体、主题或文字缩放变化。

#### Function: ekp-clear-caches ()

清除全部段落缓存与测量缓存。

**参数。** 无。

**语义。** 它丢弃段落缓存、策略分析缓存、最近段落快路径与字形宽度测量缓存。下一次排版调用会重建它需要的一切。在改变字形宽度的字体或主题变化之后、或在文字缩放之后运行它，因为此时缓存的测量已不再描述文本的绘制方式。当调用方为了测量或诊断想让一次布局从头重算时，它也是首选工具。

**返回。** 未指定；清除就是效果。

**错误。** 无。命令不接收参数，缓存也接受清空。

**示例。**

```elisp
(ekp-clear-caches)
     ⇒ the next justification re-measures every glyph
```

**参见。** `ekp-pixel-justify`、`ekp-layout-plan`。

## 错误与恢复

字符串接口在规划之前校验自己的参数。非字符串输入抛 `wrong-type-argument`；不是正整数的宽度、或界限颠倒的区间抛 `user-error`，消息里带上出错的取值。被拒绝的调用什么都不留下：字符串是值，参数校验不会改动任何缓冲区、缓存条目或全局状态。

规划产生的错误原样传播。最可能抛出的一层是断字：使用替换模式的已配置字典会被拒绝而不是降级，[断字](ekp-hyphenation.md)有述。任何情况下的恢复都一样：修正参数或配置后重新调用。缓存从不需要恢复——清除它总是安全的，而方案或排版好的字符串都可以从输入重现。
