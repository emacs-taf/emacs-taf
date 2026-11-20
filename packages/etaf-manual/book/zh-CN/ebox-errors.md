# 错误条件

Ebox 的错误条件也是公共接口的一部分。直接驱动这个库的程序——建树、挂载、编译样式或打开文件——靠捕获这些条件来区分输入错误与缺失的挂载，并在恢复时不留下半成品树或过期缓冲区。本章把条件汇总成一套层级，说明 API 的哪个部分抛什么，并描述每个条件携带的数据。[节点构造](ebox-node-construction.md)、[挂载与生命周期](ebox-mount-lifecycle.md)、[树查询](ebox-tree-queries.md)与 [`.ebox` 文件与预览](ebox-files-and-preview.md)记录各自条目的错误；本章解释它们背后的模型。

## 错误层级

<!-- index: 错误条件; 条件层级; quit; 恢复 -->

Ebox 的条件挂在 Emacs 的两条根上。`ebox-error` 继承自 `error`，是「Ebox 操作被拒」的条件：调用者让库用给定的输入做它做不到的事。两个条件直接继承 `error` 而不是 `ebox-error`——尺寸校验失败用 `ebox-size-error`，schema 词表用自己的 `ebox-style-schema-error`。`ebox-input-cancelled` 则继承 `quit`：取消不是错误，而是用户或目标的决定，它走与键盘 quit 相同的路径，因此普通的错误处理不会把它吞掉。

| 条件 | 父条件 | 何时报出 |
| --- | --- | --- |
| `ebox-error` | `error` | 公共 Ebox 操作拒绝了它的输入 |
| `ebox-input-error` | `ebox-error` | 输入会话操作没有有效的会话或目标 |
| `ebox-input-cancelled` | `quit` | 同步读取的目标消失了 |
| `ebox-size-error` | `error` | 尺寸值超出其语法或单位域 |
| `ebox-style-schema-error` | `error` | 样式 schema 词表自己的条件 |

父子关系决定哪些处理器能看到哪个条件。`ebox-error` 的处理器能抓到构造、挂载与更新错误，也能抓到 `ebox-input-error`，但抓不到尺寸错误：尺寸校验属于样式层，只有在跨过作者表单边界时才被包成 `ebox-error`。`error` 的处理器能抓到除取消外的每个 Ebox 错误，而用户 quit 与 `ebox-input-cancelled` 都由 `quit` 的处理器接住。

## 条件

#### Error: ebox-error

Ebox 操作被拒时的基础条件。

**语义。** 公共入口拿到无法使用的输入时报出它——未知 tag 或畸形作者表单、不是偶数长度的属性列表、超出域的样式或交互值、已有父节点的节点、传给渲染或挂载的非 root 节点。它是应用围绕构造、挂载与节点更新捕获的条件。错误数据是列表，首元素为人类可读的描述；`error-message-string` 把它变成 `Ebox error: DESCRIPTION` 形式的消息。

**恢复。** 失败的调用没有应用任何东西：构造丢弃它建出的节点，被拒的挂载让之前的挂载与文本保持原样，校验失败的属性列表不会被安装。修正输入再重试。

**示例。**

```elisp
(condition-case err
    (ebox-build '(widget "x"))
  (ebox-error (error-message-string err)))
     ⇒ "Ebox error: \"Unknown Ebox author tag\", widget"
```

**参见。** `ebox-input-error`、`ebox-size-error`、`ebox-build`、`ebox-node-create`。

#### Error: ebox-size-error

尺寸值非法时的条件。

**语义。** 尺寸校验失败时报出它，例如长度使用了它所在轴不允许的单位。样式编译器直接抛出它：`ebox-style-compile-declarations`、`ebox-style-compile-form` 与 `ebox-style-compile-rules` 都让它在数据里带着属性与允许的单位穿过。更高层的入口会包装它：作者表单的构造与属性替换走同一条流水线编译声明，并改报一个描述里点名 tag 与被拒属性的 `ebox-error`，所以只跟节点打交道的应用看到的是 `ebox-error`。错误数据是 `(REASON VALUE)`：REASON 是点名属性与其接受单位的描述，VALUE 是出错的值。

**恢复。** 声明没有被安装，也没有布局用它跑过。改对值——通常是单位或轴——再编译或构造。

**示例。**

```elisp
(condition-case err
    (ebox-style-compile-declarations '(:width (bogus 1)) t)
  (ebox-size-error (cdr err)))
     ⇒ ("Invalid value for :width; allowed units: (px ch vw %)" (bogus 1))
```

**参见。** `ebox-style-compile-declarations`、`ebox-node-create`、`ebox-node-set-props`。

其余三个条件定义在它们所属的子系统里。[ebox-input-error](text-input.md#error-ebox-input-error) 与 [ebox-input-cancelled](text-input.md#error-ebox-input-cancelled) 属于[文本输入](text-input.md)；[ebox-style-schema-error](style-implementation.md#error-ebox-style-schema-error) 属于[样式的实现](style-implementation.md)，今天没有公共路径抛出它。

## 谁抛什么

<!-- index: 错误位置; user-error; 读取错误 -->

| API 区域 | 条件 |
| --- | --- |
| 建树（`ebox-build`、`ebox-node-create`、`ebox-text-create`、`ebox-node-copy`） | `ebox-error`；子节点不是节点时是类型错误 |
| 渲染与挂载（`ebox-render`、`ebox-mount`） | 非 root 或畸形表单报 `ebox-error` |
| 更新节点（`ebox-node-put`、`ebox-node-set-props`、`ebox-node-insert`、`ebox-node-remove`、`ebox-node-move`、`ebox-node-replace-children`） | `ebox-error` |
| 直接编译样式（`ebox-style-compile-declarations`、`ebox-style-compile-form`、`ebox-style-compile-rules`） | 尺寸报 `ebox-size-error`；列表畸形与未知属性报 `user-error`；重复声明与语法违规报其它错误 |
| 同一条流水线经节点或作者表单 | `ebox-error`，包装原条件并点名 tag 与属性 |
| 输入会话（`ebox-input-begin`、`ebox-input-end`、`ebox-call-with-input`） | `ebox-input-error`；目标丢失时 `ebox-input-cancelled` |
| `.ebox` 文件（`ebox-file-read-form`、`ebox-file-read-file`、`ebox-file-evaluate-form`、`ebox-file-evaluate-buffer`、`ebox-file-preview`） | 文件与格式问题报 `user-error`；内容报普通的读取与 Lisp 错误 |

## 语义细节

<!-- index: 错误数据; 包装; 原子失败 -->

错误数据是给人读的。`ebox-error` 携带描述列表，首元素是字符串；`error-message-string` 把它打印成 `Ebox error: DESCRIPTION`，描述本身点明被拒的东西，诊断因此不需要解码结构。尺寸错误的数据把原因与出错值分开，调用者不用解析消息就能把值原样引用回来。取消的数据携带过时的节点，[文本输入](text-input.md)对此有描述。

构造边界会包装。样式流水线使用的条件点名属性与值，但节点调用者要的是一棵树而不是声明列表，所以构造捕获样式条件并改报 `ebox-error`，描述里带上 tag 与属性。这个区别在选择处理器时很重要：直接驱动样式编译器时接 `ebox-size-error`，建树或更新节点时接 `ebox-error`，而参数形状检查（先于两者运行）报 `user-error`。取消被有意放在 `error` 之外：捕获 `error` 的程序不会拦下被取消的读取，而处理 `quit` 的程序已经处理了它。

失败在要紧的地方是原子的。可能留下半改动树的操作都先校验后改动：声明的编译发生在属性安装之前，子节点的父节点检查发生在挂接之前，挂载的输入构建发生在旧挂载释放之前。因此失败的调用要么留下之前的状态，要么留下一棵从未发布过的树。

## 错误与恢复

捕获能描述你所能处理的最窄条件。构造或更新周围的处理器通常要 `ebox-error`；样式编译器周围的处理器要 `ebox-size-error` 与 `user-error`；输入代码应处理 `ebox-input-error`，并单独决定 `ebox-input-cancelled` 意味着「用户走了」还是「目标变了」。泛化的 `error` 处理器抓到除取消外的一切；`quit` 处理器连同真正的 quit 一起抓取消。

恢复办法随类别而定。`ebox-error` 意味着输入有错、失败的调用什么都没有改，所以修正在本地：改对表单、属性或节点再重试。尺寸错误意味着一处声明有错；改对值——数据点明了属性与其单位。输入错误意味着没有可操作的会话；重试前检查挂载与节点，取消之后若目标仍在就开一次新的读取。文件错误意味着文件没有恰好装一个可用表单、或 companion 路径不对；预览与树都没有被动过。而且因为布局与绘制都是树的输出，错误从不破坏屏幕上的内容：下一次成功的 flush 决定文本。
