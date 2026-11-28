# 参数参考

驱动 EKP 的每个数值与策略都是用户选项。本章是它们的完整参考：每个选项的含义、默认值与允许取值、适用范围，以及改动何时生效。模型章讲解这些选项所调的机制——[断行原理](ekp-principles.md)讲计分，[CJK 排版](ekp-cjk.md)讲禁则、悬挂与数字单位 token，[断字](ekp-hyphenation.md)讲字典与语言，[交互使用](ekp-interactive-use.md)讲缓冲区层。

## 条目读法

<!-- index: 用户选项; 默认值; 选项作用域; 模式 profile; safe-local 值 -->

条目的说明陈述用途，**语义。** 给出默认值、允许取值与效果。属于缓冲区层的选项在作用域里说明谁能设置它：缓冲区局部值、该主模式缓冲区查询的模式 profile，或者全局值。优先级固定：缓冲区局部值最优先；否则第一个匹配的 profile 条目优先；否则使用全局值。区域断行策略强于这三者，但它是文本属性而不是选项，记录在 `ekp-break-policy`。

模式 profile 是 `ekp-buffer-mode-policy-alist` 的一个条目，一个由主模式到选项 plist 的 alist。`ekp-token-break-policies` 按 token 类别合并不是整体替换：有效 alist 从全局值开始，并入 profile 的类别，再并入任何缓冲区局部类别。正因如此，一个 profile 可以改变 URL 的处理而保留数字单位规则。

多数选项在下一次排版或重排时生效而不是立即生效：段落缓存键、动态规划签名与方案上下文都包含影响其结果的每个选项，因此新值绝不会从旧缓存条目里取出。缓冲区选项在规划一次投影时读取，所以一次排版调用或一次自动重排就会用上新值；控制自动模式时序的选项在相应事件到来时读取。

取值在使用时检查，而不是设置时。封闭取值集的选项遇到未知值时回退到合理行为，形状属于结构性的选项则由读取它的那次排版报类型错误；每个条目都会说明属于哪一种。带 `safe-local` 谓词的取值可以从文件局部或目录局部的变量表读入；谓词与允许取值一致。

## 断行与计分参数

本组选项塑造断行目标本身。它们直接读取全局值或动态绑定值；不属于缓冲区策略上下文。

#### Variable: ekp-alignment

段落对齐模式。

**语义。** `justify`（默认）两端都齐。`ragged-right`、`ragged-left` 与 `center` 让词间胶保持刚性，用行的行尾弹性来平衡三种形状，因此搜索仍在最小化参差程度，而行不必被拉伸到行宽。任何非 justify 模式下，行的最大与最小宽度都不再含胶的拉伸与压缩，行尾余量改由 `ekp-ragged-stretch-pixel` 给出。

**参见。** `ekp-ragged-stretch-pixel`、`ekp-line-penalty`。

#### Variable: ekp-first-line-indent

首行缩进：像素值，或 t 表示段落字体的 2 em。

**语义。** 默认 nil：不缩进。整数把第零行右移该像素数并把它的宽度减少同样多；`t` 用段落 CJK 字体的两个 em。缩进走快速路径与原生引擎。设置 `ekp-parshape` 时本选项被忽略，因为完整形状已经决定了首行。

**示例。** 取 `t` 时，段落 `aaaa bbbb cccc dddd eeee ffff gggg hhhh` 在 30 像素下于 `eeee` 之后断，而不是 `ffff` 之后，因为第零行从四像素处开始。

**参见。** `ekp-parshape`。

#### Variable: ekp-parshape

逐行布局，由 `(INDENT . WIDTH)` cons 单元组成的序列。

**语义。** 默认 nil：每行都用行宽。cons 单元列表塑造段落：第 i 行用第 i 个元素，INDENT 是左侧偏移像素，WIDTH 是文本宽，因此该行占据 INDENT + WIDTH；超出末元素的后续行复用末元素，类似 TeX 的 paragraph shape。依赖行号的宽度需要按位置与行数搜索，因此本选项设置期间原生模块被绕过，只用 Emacs Lisp 引擎。它优先于 `ekp-first-line-indent`。

**示例。** 在 30 像素行宽下使用 `((0 . 20) (6 . 24) (0 . 30))`，第零行宽 20 像素，第一行占据 6 + 24，之后各行宽 30。

**参见。** `ekp-first-line-indent`、`ekp-looseness`。

#### Variable: ekp-line-penalty

每个断行的罚分。越高行数越少。默认 10。

**语义。** 该值以常量的形式加在行的劣度上再平方后进入代价，因此罚分越高，多出的行越昂贵，搜索偏好更紧的段落。它是普通数值，可以为零。

**参见。** `ekp-hyphen-penalty`、`ekp-last-line-short-penalty`。

#### Variable: ekp-hyphen-penalty

连字符断点的罚分。越高越避免断字。默认 50。

**语义。** 该值按 Knuth-Plass 罚分公式以平方形式加入代价，因此只有当几何上的收益超过它时连字符断点才有吸引力。断字关闭或没有可用字典时本选项不起作用。

**参见。** `ekp-hyphenation`、`ekp-consecutive-hyphen-penalty`。

#### Variable: ekp-adjacent-fitness-penalty

相邻行紧密度相差超过一级时的罚分。

**语义。** 每行按它的胶需要拉伸或压缩的程度得到一个适应度等级；相邻两行等级相差两级及以上时，代价上加上这个平坦常量。默认 100 让段落避免在极紧与极松之间交替，即使那样局部更便宜。

**参见。** `ekp-line-penalty`。

#### Variable: ekp-consecutive-hyphen-penalty

连续连字符行的基础罚分倍数。

**语义。** 连字符断点加上基础罚分乘以连字符连续行数的平方——行数统计到本断点为止的连续连字符行。默认 100 使连续两个连字符的成本是单个的四倍、三个是九倍，从而把连字符摊开。

**参见。** `ekp-hyphen-penalty`。

#### Variable: ekp-last-line-min-ratio

最后一行的最低填充比（0.0–1.0）。

**语义。** 默认 0.5 设定「最后一行过短」的填充比阈值。填充比是最后一行的理想宽除以目标宽；达到或高于阈值不额外收费，低于阈值则通过 `ekp-last-line-short-penalty` 收费。

**参见。** `ekp-last-line-short-penalty`。

#### Variable: ekp-last-line-short-penalty

欠满最后一行的罚分倍数。

**语义。** 当最后一行的填充比低于 `ekp-last-line-min-ratio` 时，它的短行劣度是本值乘以一减填充比，最后一行支付 `(ekp-line-penalty + short-badness)²` 而不是普通劣度。默认 50 让几乎空白的最后一行昂贵，但不禁止它。

**参见。** `ekp-last-line-min-ratio`。

#### Variable: ekp-looseness

目标行数偏移：0=最优，+1=更松（更多行），−1=更紧。

**语义。** 默认 0 选择代价最低的方案。非零值切换到按位置与行数的搜索：EKP 先找出代价最低的行数，再选出与该行数加本偏移最接近的行数，代价更低者打破平局。本选项是整数，并会被实际可达的行数夹取。非零值还会绕过原生模块，因为只有 Emacs Lisp 引擎实现二维搜索。

**示例。** 在 12 像素下，`aaa bbb ccc ddd eee fff ggg hhh iii jjj` 取 0 时排三行、取 +1 时四行；不存在可达的两行方案，所以 −1 仍是三行。

**参见。** `ekp-parshape`、`ekp-line-penalty`。

#### Variable: ekp-ragged-stretch-pixel

非 justify 对齐下每行的行尾弹性（像素）。

**语义。** 默认 nil 派生为拉丁词间理想宽的八倍，约两个 em。该值是一行参差文本可以低于行宽而不至于劣度无穷的余量；只有 `ekp-alignment` 不是 `justify` 时才读取。

**参见。** `ekp-alignment`。

#### Variable: ekp-default-cws-stretch-pixel

CJK 字符之间空白可拉伸的最大像素。

**语义。** 默认 2 是自动派生间距时 CJK 胶的拉伸额度。它只在间距为自动时起作用：调用过 `ekp-param-set` 之后 CJK 类使用显式值。它是自动间距里唯一由用户选项而非字体测量决定的取值。

**参见。** `ekp-param-set`、`ekp-param-reset`。

## CJK 与 token 策略

#### Variable: ekp-kinsoku-profile

编译段落断点许可时使用的禁则方案。

**语义。** 默认 `common` 禁止收尾标点起行、开启标点收尾与孤立半角标点，[CJK 排版](ekp-cjk.md)有述。`zh` 当前与 `common` 行为完全相同。`ja` 追加不可更改的日文集合：小假名、音标扩展、长音符与叠字符。`custom` 追加两个 extra 选项列出的字符。`off` 关闭禁止。未知取值按通用规则工作。本方案是段落分析键的一部分，因此改动它会重新解析段落。

**参见。** `ekp-cjk-no-line-start-extra`、`ekp-cjk-no-line-end-extra`。

#### Variable: ekp-cjk-no-line-start-extra

不得起行的自定义/日文 CJK 字符。

**语义。** 默认是空字符串。取值按字符读取而不是当模式：在 `custom` 方案下，盒子不得以字符串中任一字符开头。`ja` 方案改用不可更改的内置集合，通用方案完全忽略本选项。

**参见。** `ekp-kinsoku-profile`。

#### Variable: ekp-cjk-no-line-end-extra

不得收尾的自定义 CJK 字符。

**语义。** 默认是空字符串。在 `custom` 方案下，盒子不得以字符串中任一字符结尾。其它方案一律忽略它。

**参见。** `ekp-kinsoku-profile`。

#### Variable: ekp-protrusion

非 nil 时启用右缘字符悬挂（标点悬挂）。

**语义。** 默认 nil 让每行都留在行宽之内。设置后，行的末字形可以按 `ekp-protrusion-ratios` 给其类别的比例悬挂到排版边缘之外：全角收尾标点、词尾半角收尾字符与可选连字符。释放的像素计入可用宽度，因此标点前面的文字腾出空间；buffer 集成会在排版中预留悬挂宽度。开关本选项会改变段落键，因此下一次排版重新解析。

**参见。** `ekp-protrusion-ratios`。

#### Variable: ekp-protrusion-ratios

类别 → 允许悬挂的字形宽度比例的 alist。

**语义。** 默认是 `((cjk-close . 0.5) (latin-close . 0.5) (hyphen . 1.0))`。`cjk-close` 覆盖 `。`、`」` 这类全角收尾标点，0.5 正好悬挂该字形的空白那一半；`latin-close` 覆盖行首禁止集里收尾的词末字符；`hyphen` 覆盖断点插入的软连字符。释放量是比例乘字形宽后向下取整。alist 可以是不完整的：没有条目的类别不释放任何量。

**参见。** `ekp-protrusion`。

#### Variable: ekp-number-unit-suffixes

紧凑「数字＋单位」分类器识别的精确后缀。

**语义。** 默认表覆盖百分号、角度、像素与字体长度、时间单位、频率、字节单位与常见公制单位。token 以数字开头、后缀之前的部分是整数或 `.`/`,` 小数、并以表里某个字符串收尾时，才判定为数字单位 token；匹配精确且区分大小写。该 token 随后遵循 `ekp-token-break-policies` 给该类别的策略，默认策略让它保持刚性。

**参见。** `ekp-token-break-policies`、`ekp-overlong-token-policy`。

#### Variable: ekp-break-policy

控制区域断行策略的文本属性。

**语义。** 这个条目是一条约定而不是全局设置：属性附加到一段文本上，排版对属性覆盖范围内的文字优先采用该值，而不是自动的 token 与脸策略。`normal` 清除两类自动限制；`hyphenate` 让该区间即使全局策略为 off 也启用自由断字；`no-hyphen` 抑制自由断字但保留普通合法断点。它从不把原子变刚性；那是 `ekp-no-break-region` 所述的独立不断属性。

**示例。** 全局断字关闭时，戴上 `hyphenate` 策略的 `internationalization` 仍然断字；全局断字开启时，`no-hyphen` 策略去掉它的连字符。

**参见。** `ekp-inline-code-policy`、`ekp-hyphenation`、`ekp-no-break-region`。

#### Variable: ekp-inline-code-policy

自动行内代码区间的默认断行策略。

**语义。** 默认 `no-hyphen` 让戴 `ekp-buffer-inline-faces` 中脸的区间保持源码间距原样、抑制字典断字，但仍允许普通断点。`normal` 把该区间当普通正文。`no-break` 让放得下的区间变刚性；宽过行宽的区间会降级为 `no-hyphen` 而不是溢出。本选项不影响显式的不断区域。

**参见。** `ekp-buffer-inline-faces`、`ekp-break-policy`。

#### Variable: ekp-token-break-policies

有界自动 token 分类器的断行策略。

**语义。** 默认是 `((url . no-hyphen) (path . no-hyphen) (identifier . no-hyphen) (number-unit . no-break))`。每个条目把一个 token 类别映射到三种断行策略之一。分类器在普通文本中识别 URL、文件路径、标识符形状与紧凑数字单位 token；默认只有数字单位类别是刚性的。条目按类别合并而不是替换：profile 或缓冲区局部值只改动它点名的类别，其余保持不变。

**参见。** `ekp-number-unit-suffixes`、`ekp-inline-code-policy`。

#### Variable: ekp-overlong-token-policy

宽过行宽的普通非 CJK token 的策略。

**语义。** 默认 `emergency` 让应急一遍放置超宽 token，并把超宽的自动 no-break 区间降级为 `no-hyphen`，使它保持完整地占一行溢出。`overflow` 让这种区间保持刚性。`natural` 把含超宽普通拉丁式 token 的段落原样交给 Emacs 换行，不做规划就返回。本选项不适用于 CJK 文本，也不适用于显式不断区域。

**参见。** `ekp-token-break-policies`、`ekp-no-break-region`。

## 断字与语言

#### Variable: ekp-hyphenation

全局自由断字策略。

**语义。** 默认 `auto` 与取值 `on` 都在有可用字典时使用字典；字典缺失时静默禁用断字。`off` 关闭自由断字。戴 `hyphenate` 断行策略的区域在 `off` 下仍然断字。改动取值会改变段落分析键，因此下一次排版重新解析。

**参见。** `ekp-latin-lang`、`ekp-hyphen-penalty`、`ekp-break-policy`。

#### Variable: ekp-latin-lang

断字的语言代码（例如 "en_US"、"de_DE"）。

**语义。** 默认是 `"en_US"`。代码对自带字典按精确键、归一化形式与逐段缩短的前缀解析，因此 `"de"` 这样的短码会选中扫描序中第一本匹配字典，[断字](ekp-hyphenation.md)有述。取值是段落缓存键的一部分，改动它会重新解析段落；没有字典的代码只会禁用断字，而使用替换模式的字典会让排版抛 `ekp-hyphen-unsupported-pattern`。

**参见。** `ekp-hyphenation`。

## 缓冲区布局

本组选项属于[交互使用](ekp-interactive-use.md)所述的缓冲区层。它们可以全局、在模式 profile 里或缓冲区局部设置，优先级按本章开头所述。

#### Variable: ekp-buffer-measure

自动排版与默认手动排版使用的宽度。

**语义。** 默认 `narrowest-window` 按显示该缓冲区的最窄活动窗口规划。正整数是固定像素宽，与窗口无关；cons `(max . N)` 把最窄窗口上限设为 N 像素。规划一次投影时读取该值，自动模式在窗口变化时跟随它。三者都不是的取值会让排版调用报错。

**参见。** `ekp-buffer-margin-pixel`。

#### Variable: ekp-buffer-margin-pixel

窗口正文宽度内预留的像素。

**语义。** 默认 2 会在计算宽度之前从窗口正文宽里减去，留出取整安全余量，使测宽正好等于窗口宽的行不会在显示引擎里换行。它作用于由窗口派生的宽度，不作用于固定的 `ekp-buffer-measure`。

**参见。** `ekp-buffer-measure`。

#### Variable: ekp-buffer-skip-faces

所在段落保持逐字的脸。

**语义。** 默认是 nil，即空列表。与这些脸相交的段落保持缓冲区自然换行，不被投影。自动模式读取模式 profile，其中为 Org 与 Markdown 提供块脸；`ekp-org-setup` 与 `ekp-markdown-setup` 把这些列表复制进缓冲区供手动排版使用。

**参见。** `ekp-buffer-inline-faces`、`ekp-org-setup`。

#### Variable: ekp-buffer-inline-faces

精确区间使用 `ekp-inline-code-policy` 的脸。

**语义。** 默认是 nil。戴这些脸的区间按行内代码策略排版，因此它的间距与断字遵循策略而不是段落的。单位是脸区间；含这种区间的段落仍会被投影。

**参见。** `ekp-inline-code-policy`、`ekp-buffer-skip-faces`。

#### Variable: ekp-buffer-skip-predicate

以段落字符串为参数、判定其应保持逐字的函数。

**语义。** 默认是 nil。这是缓冲区局部变量：当它持有一个函数时，每个硬段落的文本都会传给该函数，非 nil 的结果让该段落保持逐字。它是文档语法没有可识别脸时的通用逃生口，并与跳过脸及其它保护规则一起被查询。

**示例。** 一个对匹配 `"SKIP"` 的段落返回非 nil 的缓冲区局部谓词，让这些段落保持自然，而缓冲区其余部分照常投影。

**参见。** `ekp-buffer-skip-faces`。

#### Variable: ekp-buffer-mode-policy-alist

自动排版与手动排版查询的模式 profile。

**语义。** 默认带一个 Org 与一个 Markdown profile，各给出其块脸与行内脸。条目按顺序用 `derived-mode-p` 匹配，第一个匹配提供它点名的选项。取值就是缓冲区策略选项本身，因此一个 profile 可以为某主模式的每个缓冲区设置宽度、断字、禁则、超宽 token 行为、脸与 token 策略，而不必改动全局值。

**参见。** `ekp-buffer-measure`、`ekp-token-break-policies`。

## 自动重排

本组选项调节 `ekp-auto-justify-mode`。模式启用时或相应事件到来时读取它们。

#### Variable: ekp-auto-justify-lazy-threshold

超过该缓冲区大小后整缓冲区重排改为可见优先。

**语义。** 默认 20 000 字符。模式本身在段落完成时逐个投影段落，但对大缓冲区的显式重排会拆分：屏幕上的部分同步投影，其余在 tick 预算内按后台分块处理。不高于该阈值的缓冲区一次重排完成。

**参见。** `ekp-auto-justify-tick-budget`、`ekp-auto-justify-mode`。

#### Variable: ekp-auto-justify-paragraph-limit

自动规划的最大硬段落字符数。

**语义。** 默认 2 048 字符。更长的段落编辑期间保持自然换行，因此启用模式、粘贴或普通输入都不会启动无界的规划过程；诊断会报告原因正是该上限。`ekp-refill-paragraph` 不受本值限制，按请求对该段落执行全质量一遍。

**参见。** `ekp-refill-paragraph`、`ekp-diagnose`。

#### Variable: ekp-auto-justify-resize-delay

窗口大小重排的防抖秒数。

**语义。** 默认 0.15 秒。每次改变大小都会重新开始计时；计时结束而不再有大小变化时，缓冲区按新宽度重排一次，因此拖动窗口不会对每个中间尺寸都跑一次重排。

**参见。** `ekp-buffer-measure`。

#### Variable: ekp-auto-justify-tick-budget

一个懒重排 tick 允许的工作秒数。

**语义。** 默认 0.005 秒。它限定大缓冲区重排的每个后台分块，使其余部分跟上的同时空闲时间仍可响应；可见部分优先于尚未处理的分块。

**参见。** `ekp-auto-justify-lazy-threshold`。

#### Variable: ekp-auto-justify-native-append

自动活动追加的 DP 使用已加载的原生模块。

**语义。** 默认 t。它只适用于已经准备好的活动追加路径：普通字符串排版与整缓冲区排版仍然遵循 `ekp-use-c-module`，原生模块不可用时活动路径回退到 Emacs Lisp。设为 nil 会强制活动追加路径走 Lisp，而不影响模块的其它用途。

**参见。** `ekp-use-c-module`、`ekp-auto-justify-mode`。

## 缓存与原生引擎

#### Variable: ekp-para-cache-limit

缓存段落的最大数量。

**语义。** 默认 256。段落缓存达到这么多条目时，整个缓存先被清空再加入新段落；重建成本很低，而这让长时间编辑会话的内存有界。该上限不影响结果。

**参见。** `ekp-clear-caches`。

#### Variable: ekp-use-c-module

非 nil 时用 C 动态模块计算 DP（若可用）。

**语义。** 默认 t，在原生模块已加载时让它计算断行，包括多段落的并行批量路径。nil 强制使用 Emacs Lisp 引擎。本选项无法切换到一个未加载的模块，而且有两项特性无论如何都会绕过它：非零的 `ekp-looseness` 与非 nil 的 `ekp-parshape` 需要 Emacs Lisp 搜索。两个引擎产生相同的布局。

**参见。** `ekp-auto-justify-native-append`、`ekp-c-module-load`、`ekp-looseness`、`ekp-parshape`。

## 错误与恢复

选项在被读取时检查，而不是设置时。封闭取值集的选项遇到未知值时回退到已记录的行为：无法识别的禁则方案按通用规则工作，非字符串的 CJK extra 集被忽略，缺少所需键的悬挂比例表不释放任何量。形状结构性错误的取值由读取它的那次排版报错：不是序列的数字单位后缀表报 `wrong-type-argument`，数据点名 `sequencep`；连 alist 都不是的悬挂比例表点名 `listp`；三者都不是的缓冲区宽度在规划投影时失败。

恢复从不需要编辑文本：修正选项再跑一次排版。因为缓存以影响其结果的选项为键，修正后的取值下次调用即被采用；当调用方想确保不复用早先测量时可以用 `ekp-clear-caches`，但它从来不是必需的。缓冲区层选项可以全局、在模式 profile 里或缓冲区局部修正，最具体的取值获胜。
