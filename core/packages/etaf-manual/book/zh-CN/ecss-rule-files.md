# 规则文件

规则文件是 stylesheet 离开 Lisp 后的形态：一个 `.ecss` 文件以惰性数据保存一份有序规则列表，工具或应用把它读回来、校验其语法，再用自己拥有的 schema 挂载。读取器刻意与层叠分离：读文件从不求值、从不查询 schema、也不挂载任何东西。本章定义文件契约与围绕它的三个函数。[stylesheet、scope 与作者所有权](ecss-stylesheets-and-scopes.md)定义校验过的列表被加进的对象；[值](values.md)与[选择器](selectors.md)定义文件里的值与选择器在应用 schema 之后是什么意思。

## 模型

<!-- index: 规则文件; 惰性数据; 读取阶段; schema 校验阶段 -->

一个 `.ecss` 文件恰好包含一个 Lisp 表达式：规则列表。没有 quote、也没有包裹形式——文件是数据，不是构造数据的代码。规则按顺序排列，列表前后可以有空白的注释。

一条*规则*是 `(SELECTOR PROPERTY VALUE ...)`。选择器是 ECSS 选择器字符串，每个属性是非 nil 符号，其后的条目把属性与值成对排列。列表可以是空的（`nil` 或 `()`），这是合法的空规则集；一条规则也可以完全没有声明。文件不说明规则属于哪个来源、层或 scope；那是加进列表时由 stylesheet 层提供的书写信息。

读取分两个阶段，这个划分正是契约的要义。*读取阶段*解析文本并检查语法：一个表达式、proper list、字符串选择器、符号属性、偶数条声明。*schema 阶段*稍后发生，在规则对某个 schema 集合展开时：那时才解析属性名并校验值。因此规则文件可以在一个完全没有 schema 的进程里读取、存储和传递。

值永不求值。读取器绑定读取表使 `#.` 直接被拒，声明里的函数或表单是普通数据，原样透过。这才让读取安全：规则文件不能运行代码，声明里的函数值保持同一，直到消费者的 `:value-resolver` 选择求值它，[计算样式](ecss-computed-style.md)有述。

## 校验规则

`ecss-validate-rules` 是对内存中列表的语法检查。已经用 `list` 构造好规则、或以别的方式读到规则的调用方，用它获得与文件读取器同样的契约。

#### Function: ecss-validate-rules (rules)

校验有序静态 RULES 并原样返回，不求值其中的值。

**参数。** RULES 是 `(SELECTOR PROPERTY VALUE ...)` 规则的 proper list。SELECTOR 是 ECSS 选择器字符串；PROPERTY 是非 nil 符号。空列表与空声明都允许。

**语义。** 调用检查列表形状、每条规则的形状与声明条数，经选择器引擎解析每个选择器，并确认每个属性是非 nil 符号。它不看值、不把属性名解析到任何 schema，也不改动输入；合法调用返回收到的那个列表本身，因此调用方可以接着串。属性名与值稍后对消费者的 schema 校验。

**返回。** RULES 本身。

**错误。** RULES 不是 proper list 时 `error→ user-error` "ECSS rules must be a proper list"；规则不是 proper list、不以字符串开头、或声明条数为奇数时 `error→ user-error` "Invalid ECSS rule: RULE"；选择器被解析器拒绝时 `error→ ecss-invalid-selector`；声明的属性不是非 nil 符号时 `error→ user-error` "ECSS property must be a non-nil symbol: VALUE"。

**示例。**

```elisp
(ecss-validate-rules '((".card" :color "red") ("& > .title")))
     ⇒ ((".card" :color "red") ("& > .title"))
```

**参见。** `ecss-read-rules`、`ecss-stylesheet-add-rule`。

## 读取源码

`ecss-read-rules` 把字符串——文件内容，或编辑器里的内容——变成校验过的规则列表。它恰好读一个表达式，别的一概拒绝。

#### Function: ecss-read-rules (source)

从字符串 SOURCE 恰好读出一个惰性规则列表。

**参数。** SOURCE 是字符串。规则列表前后允许注释与空白。

**语义。** 读取器在禁用 `#.` 求值的情况下解析一个 Lisp 表达式，检查它是源码里唯一的表达式，再把结果交给 `ecss-validate-rules`。什么都不求值：看起来像调用的声明值是数据，`'`、`styles` 或 `progn` 之类的包裹会因为没有通过校验而失败。空源码、或只有注释的源码，根本没有提供所需的表达式。

**返回。** 校验过的规则列表，可以为空。

**错误。** SOURCE 不含表达式时 `error→ end-of-file`；`#.` 报 `error→ invalid-read-syntax`；后面还有第二个表达式时报 `error→ user-error` "ECSS source must contain one rule list"；其余错误来自 `ecss-validate-rules`，包括非法选择器的 `ecss-invalid-selector`。

**示例。**

```elisp
(ecss-read-rules "; header\n((\".card\" demo/color \"red\")) ; footer\n")
     ⇒ ((".card" demo/color "red"))
```

**参见。** `ecss-validate-rules`、`ecss-file-read`。

## 读取文件

#### Function: ecss-file-read (file)

经 `ecss-read-rules` 把 FILE 读成一份惰性规则列表。

**参数。** FILE 是可读文件的路径。

**语义。** 函数先确认 FILE 可读，把内容读进临时缓冲区并把文本交给 `ecss-read-rules`，因此文件与源码字符串的契约完全一致：一个表达式、无 quote 或 styles 包裹、允许注释、值惰性、文件里的规则顺序保留。不查询任何 schema、也不挂载；返回的列表与调用方要交给 stylesheet 的数据相同。文件名只用于读取，同样的规则可以来自任何路径。

**返回。** 校验过的规则列表，可以为空。

**错误。** FILE 无法读取时 `error→ user-error` "ECSS file is not readable: FILE"；其余错误来自 `ecss-read-rules`，包括空文件的 `end-of-file` 与非法选择器的 `ecss-invalid-selector`。

**参见。** `ecss-read-rules`、`ecss-validate-rules`。

## 语义细节

<!-- index: 错误分层; read-eval; 值保持 -->

语法错误与选择器错误来自不同层，工具报告它们时这个区分很有用。形状问题——不是列表、规则的头不是字符串、声明条数为奇数、属性不是符号——是带出错值消息的 `user-error`。选择器问题是选择器解析器报的 `ecss-invalid-selector`，带解析器数据，例如失败位置。源码层的两个问题是 Lisp 读取条件：空输入是 `end-of-file`，`#.` 是 `invalid-read-syntax`。

读取在两个方向都是惰性的。没有东西检查属性名是否已知：文件可以点名任何词表的属性，是否合法在规则遇见 schema 集合时才决定。也没有东西求值：`#.` 被禁用，被引用的表单仍是列表，函数值保持为函数，让稍后的 `:value-resolver` 决定怎么处理它。这让规则文件成为安全的交换格式：可以从磁盘读取、可以经由网络收到，而不会给发送方任何执行权。

静态列表不是 stylesheet。它不带来源、层或 scope，也不能单独参与计算；宿主把它加进 stylesheet（在那里提供书写参数），再挂载该 stylesheet。读取、校验、加入、挂载——每一步只有一个所有者，文件格式保持为纯数据契约。

## 错误与恢复

<!-- index: 规则文件错误; 恢复 -->

每次拒绝都不给调用方留下部分应用的状态：校验要么返回值要么报错，读取不创建规则，挂载是尚未发生的独立一步。恢复方式是修好文件或列表再读一次。

| 情形 | 信号 |
| --- | --- |
| RULES 不是 proper list，或规则是点对 | `error→ user-error` "ECSS rules must be a proper list" |
| 规则不是列表、不以字符串开头，或声明条数为奇数 | `error→ user-error` "Invalid ECSS rule: RULE" |
| 选择器无法解析 | `error→ ecss-invalid-selector`，带解析器数据 |
| 属性为 nil 或不是符号 | `error→ user-error` "ECSS property must be a non-nil symbol: VALUE" |
| 源码不含表达式（空或只有注释） | `error→ end-of-file` |
| 源码含第二个表达式 | `error→ user-error` "ECSS source must contain one rule list" |
| 源码使用 `#.` | `error→ invalid-read-syntax` |
| 源码带外层 quote、`styles` 或其它包裹 | `error→ user-error` "Invalid ECSS rule: …" |
| FILE 不可读 | `error→ user-error` "ECSS file is not readable: FILE" |
| FILE 是目录 | 文件系统读取报 `error→ file-error` |
