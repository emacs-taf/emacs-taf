# 断字

长词能断开的位置多于空格给出的位置，而语言可以指出这些位置。EKP 做的是自由断字：用 Liang 模式算法找出拉丁词内部的合法断点，交给断行器选取，并在断点显示连字符。结果是段落更柔顺——候选方案更多、被拉伸的行更少——代价是一个连字符和语言学上断错的风险；正因如此，这个特性是一条带关闭开关的策略，而不是永远生效的规则。

本章定义断字接口：把语言或字典文件解析成 hyphenator 的函数、它能报出的条件，以及两者背后的语言与字典处理。连字符断点支付的代价属于[断行原理](ekp-principles.md)，悬挂的连字符属于[CJK 排版](ekp-cjk.md)；启用断字与选择语言的选项是用户选项，汇总在[参数参考](ekp-parameters.md)一章。

## 模型

<!-- index: 断字; Liang 算法; 字典; hyphenator; 断字边距 -->

EKP 采用 Frank Liang 的普通模式算法。字典是一组关于词的模式，每个模式为它的字母之间的位置携带优先级。要给一个词断字，EKP 先在词首词尾各补一个边界标记，查出它能匹配的全部模式，并在每个位置保留记录到的最高优先级。优先级为奇数的位置就是合法断点。

字典自身的 `LEFTHYPHENMIN` 与 `RIGHTHYPHENMIN` 声明约束结果：第一个断点前与最后一个断点后至少各保留这么多字符。自带的英文词典声明 2 与 3，所以 `hy-phen-ation` 是 `hyphenation` 的合法切分，而首个字符后或末尾两个字符前不能断。两者都不声明的字典，两侧按默认各保留两个字符。

断字只作用于拉丁词盒。词可以被标点包裹——`(word)`、`word!`、带引号的词——标点会粘在首个或末个音节上，因此连字符不会落在标点旁边。被某条断行策略设为不断字的区间，以及刚性不可断原子，都不会断字。连字符断点胜出时，连字符的宽度计入行宽，断点支付 `ekp-hyphen-penalty`，并带[断行原理](ekp-principles.md)所述的连续行收费；开启右缘悬挂时，连字符本身也可以悬挂到边缘之外。

**示例。** 在五或六像素下，`hyphenation` 排成 `hy-`、`phen-` 与 `ation`，遵守左二右三的边距；在七到十像素下取单一断点 `hyphen-` / `ation`；从十二像素起完全不断字。整段文字里，一长串德文或英文词在 60 像素下断出多个连字符断点、80 像素下只断一个，而把 `ekp-hyphenation` 关掉后同样宽度下不再有任何软连字符。

## 创建 hyphenator

#### Function: ekp-hyphen-create (&optional lang file left right)

为 LANG 或字典 FILE 创建 hyphenator。

**参数。** LANG 是 `"en_US"` 或 `"de"` 这类语言代码。FILE 是字典文件路径，在 LANG 为 nil 或无法解析时使用。LEFT 与 RIGHT 覆盖断点前后保留的最少字符数。

**语义。** LANG 对包内 `dictionaries/` 目录扫描建立的字典注册表解析：先查精确键，再查归一化形式（小写、`-` 写作 `_`），然后逐段缩短前缀，因此短码会解析为扫描序中第一个匹配的字典。能解析的 LANG 优先于 FILE。字典只编译一次并按路径缓存：同一语言的后续调用返回同一个 hyphenator，而给出 LEFT 或 RIGHT 会返回一个新的 hyphenator，共享已编译的模式与逐词结果缓存，只覆盖边距。不做覆盖时，采用字典的 `LEFTHYPHENMIN` 与 `RIGHTHYPHENMIN`，缺省为两侧各两个字符。

**返回。** 解析出的字典对应的 hyphenator。

**错误。** LANG 无法解析且 FILE 为 nil 时 `error→ ekp-hyphen-dictionary-not-found`。字典使用替换模式时 `error→ ekp-hyphen-unsupported-pattern`。FILE 指向打不开的文件时 `error→ file-missing`（属 `file-error`），它不是断字条件。

**示例。**

```elisp
(ekp-hyphen-create "en_US")
     ⇒ a hyphenator for the English (United States) dictionary
(ekp-hyphen-create "en")
     ⇒ a hyphenator for the first matching English dictionary
(ekp-hyphen-create "zz_XX")
     error→ ekp-hyphen-dictionary-not-found
(ekp-hyphen-create "hu_HU")
     error→ ekp-hyphen-unsupported-pattern
```

**参见。** `ekp-hyphen-error`。

## 条件

三个条件构成一个家族：字典问题就是断字错误，因此一个 handler 就能覆盖 EKP 在解析断字时拒绝的一切。

#### Error: ekp-hyphen-error

断字失败的基条件。

**语义。** 它派生自 `error`，自身没有失败路径；下面两个条件从它派生。数据是具体条件附加的内容，消息是 "Hyphenation error"，`error-message-string` 会把数据拼在后面。

**恢复。** 按数据指出的语言或字典修正输入后重新调用。没有任何东西被改动：hyphenator 是值，被拒绝的创建除字典缓存外不留全局状态，而缓存会被之后成功的调用复用。

**参见。** `ekp-hyphen-dictionary-not-found`、`ekp-hyphen-unsupported-pattern`。

#### Error: ekp-hyphen-dictionary-not-found

找不到断字字典。

**语义。** LANG 无法解析成任何字典且没有给出 FILE 时，`ekp-hyphen-create` 抛出该条件。数据是只含 LANG 的单元素列表，因此 handler 能报告是哪个代码失败、并提示最接近的可用语言；条件消息会写出语言名，形如 `Hyphenation dictionary not found: "zz_XX"`。

**恢复。** 检查代码拼写与字典集支持的语言，用 `"de"` 这样的短码取第一个匹配字典，或显式传入字典 FILE。排版引擎把这个条件当作「断字不可用」，静默关掉断字，而不是让排版失败。

**参见。** `ekp-hyphen-create`。

#### Error: ekp-hyphen-unsupported-pattern

字典使用了不受支持的替换模式。

**语义。** Liang 字典可以携带替换规则，在某个断点胜出时改写字形。EKP 的行模型需要定宽盒子，无法如实表达这种改写，因此它拒绝整本字典，而不是产出语言学上错误、宽度也不对的文字。条件数据是语言或路径、字典路径与发现的替换规则条数，形如 `("hu_HU" "…/hyph_hu_HU.dic" 2396)`。与字典缺失不同，排版引擎让这个条件向外传播：选中这类字典的配置会明确报错，而不是静默失去断字。

**恢复。** 换用只含普通模式的语言或字典，或者关闭断字。失败的字典会被记录，之后的调用不再重读文件、直接报出同样的条件。

**参见。** `ekp-hyphen-create`。

## 语言与字典

排版使用的语言由 `ekp-latin-lang` 给出，取值形如 `"en_US"` 或 `"de"`；`ekp-hyphenation` 选择策略，`auto`（默认）与 `on` 在有字典时启用断字，`off` 完全不查字典直接关闭。带 `hyphenate` 断行策略的区域只为该区域启用断字。这些选项在[参数参考](ekp-parameters.md)一章记录；本章负责的是代码怎样变成字典，以及变不成时会发生什么。

包在 `dictionaries/` 下自带 49 本字典，来自 LibreOffice 字典集的一个固定修订。每本文件的上游路径、SHA-256、许可证证据与替换模式条数记录在 `dictionaries/MANIFEST.tsv`，并有一道离线门禁校验清单。包加载时扫描该目录；目录缺失只警告一次，断字保持关闭。

解析先查精确代码，再查归一化形式，然后逐段缩短前缀：只有当 `de_CH` 字典没有注册时，`"de_CH"` 才回退到别的德文字典，而 `"de"` 解析为扫描序中第一本德文字典。解析按字典路径进行，编译结果被缓存，因此每种语言只付一次成本。

自带的字典里有四本使用替换模式，因此被拒绝：`ca`、`eo`、`hu_HU` 与 `sq_AL`。`ekp-hyphen-create` 对它们报 `ekp-hyphen-unsupported-pattern`，选中其一的排版会把条件传播出去。完全没有字典的代码是另一种情况，例如 `zz_XX`：排版会抓住「字典缺失」条件，把段落按无断字排出来，因为对于 EKP 未附带字典的语言，缺字典是正常情况。

## 错误与恢复

断字家族挂在 `ekp-hyphen-error` 之下，而它派生自 `error`。基条件的 handler 能抓住字典缺失与不受支持的模式两个条件；字典文件打不开时的文件错误是普通 `file-error`，不在这个家族里。

恢复手段是修正字典，而且总是局部的：改语言代码、提供文件、移除或替换字典、关掉特性。hyphenator 是不可变值，没有外部所有权，所以被拒绝的创建没有可回滚的东西——修正输入后下一次调用就能成功。在排版中要区分两种失败形状：字典缺失静默降级，字典不受支持则报错；因此绝不能失败的配置应当停留在受支持的语言上。
