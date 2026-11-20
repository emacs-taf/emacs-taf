# .ebox 文件与预览

`.ebox` 文件是写进文件的作者表单：一个 Elisp 表达式，带引号因而 tag 是数据，旁边可以放 companion。[节点构造](ebox-node-construction.md)定义文件里装的作者表单，[样式系统](style-system.md)定义 `.ebox` 文件可以挂接的规则文件，[挂载与生命周期](ebox-mount-lifecycle.md)定义预览所创建的挂载缓冲区。文件契约属于核心包——读取、求值与预览 `.ebox` 文件不需要应用、也不需要 playground——本章记录它。

## 文件契约

<!-- index: .ebox 文件; 带引号表单; companion; 规则文件; 预览缓冲区 -->

一个文件恰好装一个表达式；表达式先在不求值的情况下被读取，然后被求值一次。实践里这个表达式是带引号的作者表单：

```elisp
'(box :width (ch 32) :height (lh 4)
      (text "Inbox")
      (row :item-gap (ch 1) (box "open") (box "done")))
```

引号不是装饰。文件先被当作数据读取，所以 `#.` 会被拒绝而不是求值；随后才被求值，所以不写引号的 `(box ...)` 会试图把 `box` 当函数调用并失败。两步之间 Lisp 能做的一切都可用——文件可以算出表单的一部分——但本意是树的表单必须求值成一棵树。

两类 companion 放在 `.ebox` 文件旁边。同基名的 `.el` 文件在表单求值之前被加载，因此可以定义表单要调用的辅助函数。同基名的 `.ecss` 文件，或表单里 `:ecss-file` 属性点名的文件，提供样式规则；随后表单被返回时，这些规则的快照已经嵌入 `:ecss`，可以直接交给 `ebox-build`。companion 是可选的，从不强制：核心文件契约在光秃秃的 `.ebox` 文件上照样工作。

预览就是普通的挂载缓冲区。`ebox-file-preview` 求值文件并把得到的树渲染进自己的缓冲区，随后显示；该缓冲区在世期间归 Ebox 所有。打开 `.ebox` 文件时还会启用一个派生自 Emacs Lisp 的模式，带 header line，`C-c C-c` 绑定到预览。

## 读取

#### Function: ebox-file-read-form (source)

从 SOURCE 恰好读取一个 Elisp 表达式。

**参数。** SOURCE 是字符串，内容为文件内容。

**语义。** 字符串在 Emacs Lisp buffer 里用标准语法表读取，读期求值被关闭，所以 `#.` 报读取错误而不是运行代码。表达式周围的空白与注释允许；除一个表达式外的任何内容都被拒。结果是惰性数据：`box` 这样的符号还是符号，`(px 20)` 还是列表。函数只读文本——不打开文件、不加载、不求值。

**返回。** 表达式数据。

**错误。** 空或纯空白输入报 `error→ user-error` "The Ebox DSL source is empty"；多于一个表达式报 "The Ebox source must contain one Elisp expression"；畸形读取报普通的读取错误。

**示例。**

```elisp
(ebox-file-read-form "(box :width (px 20) \"x\")")
     ⇒ (box :width (px 20) "x")
```

**参见。** `ebox-file-read-file`、`ebox-build`。

#### Function: ebox-file-read-file (file)

从 FILE 读取一个 Ebox 表达式，不求值。

**语义。** 文件必须可读；内容读进临时 buffer 后交给 `ebox-file-read-form`。不求值、不加载 companion，所以它是文件契约安全的前半段，工具想检视文件表单时用它。

**返回。** 表达式数据。

**错误。** FILE 不可读报 `error→ user-error` "Ebox DSL file is not readable: FILE"；内容错误报 `ebox-file-read-form` 的错误。

**参见。** `ebox-file-read-form`、`ebox-file-evaluate-form`。

## 加载 companion

#### Function: ebox-file-load-companion (&optional file)

FILE 存在同基名 `.el` companion 时加载它。

**语义。** 只在 FILE 命名 `.ebox` 文件、且旁边存在可读的同基名 `.el` 时加载；其它情况（包括 nil）都是空操作。加载使用 `load-prefer-newer`，所以编译过的 `.elc` companion 只在不比源文件旧时使用。companion 是普通 Emacs Lisp，定义文件表单可能调用的内容；加载发生在求值之前，所以表单运行时定义已经就位。

**返回。** 未指定；效果就是加载。

**错误。** companion 自己代码的错误会传播；companion 缺失或不可读不是错误。

**参见。** `ebox-file-evaluate-form`、`ebox-file-read-file`。

## 求值

#### Function: ebox-file-evaluate-form (form &optional source-file)

求值 FORM 一次，加载 SOURCE-FILE 的 companion 与本地样式。

**参数。** FORM 是从文件读出的表达式。SOURCE-FILE 是它来自的文件，用于 companion 与相对路径；nil 表示没有 companion、没有样式表，相对路径按当前目录解析。

**语义。** 求值时 `default-directory` 绑定到 SOURCE-FILE 的目录，所以表单里的路径相对于文件所在目录解析，而不是 Emacs 恰好所在的目录。求值之前加载同基名 `.el` companion；当 SOURCE-FILE 命名一个 `.ebox` 文件、且旁边有同基名 `.ecss` 文件时，那份规则列表成为根的第一批文件规则。求值之后遍历结果里的每个 Box 表单：`:ecss-file` 属性（若有）点名的规则文件被读取并快照；内联 `:ecss` 规则追加在文件规则之后；每个属性值被重新引用，使结果重新成为惰性数据。返回的表单就是 `ebox-build` 消费的东西；它包含样式，而不是文件名。整个过程不求值任何声明值。

**返回。** 求值并解析好样式的表单。

**错误。** 属性不是字符串报 `error→ user-error` ":ecss-file requires a file name"；存在同基名 `.ecss` 而表单的根不能承载样式时报 "An ECSS companion requires a Box root"；点名的规则文件不可读时报规则读取器自己的错误；求值 FORM 或加载 companion 的错误会传播。

**示例。**

```elisp
(ebox-file-evaluate-form '(quote (box "x")))
     ⇒ (box "x")
```

**参见。** `ebox-file-evaluate-buffer`、`ebox-file-read-form`、`ebox-style-scope-with-rules`。

#### Function: ebox-file-evaluate-buffer (&optional buffer)

通过核心文件契约求值 BUFFER 里的 Ebox 表达式。

**语义。** buffer 文本用 `ebox-file-read-form` 读取，并以 buffer 的文件名作为 SOURCE-FILE 求值，所以访问文件的 buffer 得到与磁盘文件相同的 companion、相对路径与样式快照。BUFFER 缺省为当前缓冲区。不访问文件的 buffer 没有 companion、没有样式表；相对的 `:ecss-file` 那时从当前目录解析，找不到就报错。

**返回。** 求值并解析好样式的表单。

**错误。** `ebox-file-read-form` 与 `ebox-file-evaluate-form` 的错误。

**示例。**

```elisp
(with-temp-buffer
  (insert "'(column \"a\" \"b\")")
  (ebox-file-evaluate-buffer))
     ⇒ (column "a" "b")
```

**参见。** `ebox-file-evaluate-form`、`ebox-file-preview`。

## 预览

#### Function: ebox-file-preview (&optional buffer)

把 BUFFER 里的 `.ebox` 源渲染进专门的预览缓冲区。

**语义。** BUFFER 缺省为当前缓冲区。内容经 `ebox-file-evaluate-buffer` 求值，结果用 `ebox-build` 建成树，再用 `ebox-render-to-buffer` 挂载到名为 `*Ebox Preview: NAME*` 的缓冲区，其中 NAME 是文件路径，或没有文件时源缓冲区的名字。预览缓冲区被显示并返回；再次运行命令会重新求值源，并通过普通挂载路径替换预览内容。预览是普通的挂载 Ebox 缓冲区，滚动、焦点与交互在其中都可用；它会一直存在到被杀掉或被替换。

**返回。** 预览缓冲区。

**错误。** `ebox-file-evaluate-buffer` 的错误，以及构建表单的错误。

**示例。**

```elisp
;; 在访问某个 .ebox 文件的缓冲区里：
(string-prefix-p "*Ebox Preview: " (buffer-name (ebox-file-preview)))
     ⇒ t
```

**参见。** `ebox-file-evaluate-buffer`、`ebox-render-to-buffer`、`ebox-unmount-buffer`。

## 条目之间的关系

读取器与求值器把文件契约一分为二。`ebox-file-read-form` 与 `ebox-file-read-file` 把文本变成数据、从不运行它；`ebox-file-evaluate-form` 与 `ebox-file-evaluate-buffer` 把这份数据送过文件所需的那一次求值、companion 加载与样式快照。`ebox-file-load-companion` 是求值之前跑的那块，样式解析是求值之后跑的那块。`ebox-file-preview` 是交互式的整体：读、求值、建树、挂载。

参考仓库 ebox-playground 在同一契约上搭出更丰富的工作流：把 DSL 文件渲染进缓冲区、把当前 DSL buffer 渲染到右侧预览、打开默认示例。它的 `examples/` 目录是阅读 `.ebox` 文件的最佳集合，而它的一切都不是加载 `.ebox` 文件所必需的。

## 语义细节

<!-- index: 规则快照顺序; 文件规则优先级; 相对路径 -->

样式快照有确定的顺序。同基名 `.ecss` companion 排在最前，然后是同一个 Box 上 `:ecss-file` 点名的文件规则，最后是 Box 的内联 `:ecss` 规则。同特异性的规则后来者胜，所以内联规则覆盖文件规则，Box 点名的文件覆盖 companion。规则作为惰性数据被复制进表单：求值之后结果不再提及这两个文件，所以移动或编辑它们不会改变已经建好的树。companion `.ecss` 作用于根，因此需要能承载样式的根——一个 Box 表单；嵌套 Box 上的 `:ecss-file` 在它被书写的地方解析，子 Box 也会被处理。

求值顺序对文件很重要。`.el` companion 在表单运行之前加载，所以表单可以调用 companion 定义的东西。路径在 SOURCE-FILE 的目录里解析，而不是调用者的目录里，这正是 `.ebox` 文件能自成一体的原因：它可以点名自己旁边的 `:ecss-file "theme.ecss"`，从任何地方加载都成立。相对地，读取是纯粹的：不为 companion 打开任何文件、不求值任何值、`#.` 被拒绝——`.ebox` 文件可以被安全地检视。

编辑模式补完整个工作流。打开 `.ebox` 文件时启用一个派生自 Emacs Lisp 的模式，header line 写明预览键，不截断行，从左到右显示；`C-c C-c` 运行 `ebox-file-preview`。这个模式是编辑便利：它绑定的命令就是本章定义的这些公共入口。

## 错误与恢复

| 情形 | 报出 |
| --- | --- |
| 源为空或纯空白 | `error→ user-error`，"The Ebox DSL source is empty" |
| 多于一个表达式 | `error→ user-error`，"The Ebox source must contain one Elisp expression" |
| 源里的 `#.` | 读取错误；读期求值被关闭 |
| 文件不可读 | `error→ user-error`，"Ebox DSL file is not readable: FILE" |
| `:ecss-file` 不是字符串 | `error→ user-error`，":ecss-file requires a file name" |
| 有 `.ecss` companion 但根不是 Box | `error→ user-error`，"An ECSS companion requires a Box root" |
| 点名的规则文件不可读 | 规则读取器的不可读文件错误 |
| 表单或 companion 报错 | 错误从求值阶段传播 |

恢复办法随阶段而定。读取错误意味着文件不是恰好一个表达式；改文件，或直接使用 buffer 里的内容。求值错误通常是表单少了引号、或 companion 缺少定义；补上引号或 companion 即可。规则文件缺失是路径问题：路径相对于源文件，所以从某个目录起可用的文件，只有在 companion 跟随它时才能从别处继续可用。失败的预览不改动磁盘上的任何东西，也不动已有的预览缓冲区，因为失败发生在挂载之前。
