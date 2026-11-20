# 挂载与生命周期

建好的树有两种消费方式。`ebox-render` 把它布局成字符串返回，不涉及缓冲区；`ebox-mount` 把它绑到一个缓冲区，并让缓冲区跟随之后每一次修改。本章沿第二条路径走完它的一生：挂载如何创建、拥有一个缓冲区意味着什么、如何检视活着的挂载、以及如何把它释放。树由[节点构造](ebox-node-construction.md)建成；[树查询](ebox-tree-queries.md)一章从挂载把它读回来；[视口](viewport.md)定义挂载据以布局的尺寸，[增量更新与发布](incremental-updates-and-publication.md)定义让文本保持最新的 flush。

## 挂载对象

<!-- index: 挂载; root 绑定; 缓冲区所有权; flush 计数; 画布背景 -->

挂载是一个 root 节点与一个缓冲区之间的绑定。树仍是模型；缓冲区是挂载不断同步的输出。挂载会替换缓冲区文本，从那以后文本归 Ebox 所有：外部做的编辑会在所属行被写入时被覆盖，[增量更新与发布](incremental-updates-and-publication.md)对此有描述。挂载在世期间还会接管几项缓冲区级显示设置——缓冲区按从左到右排布整行、截断长行、并用 root 的背景色绘制最后一行之后的窗口区域——并在释放时逐项还原。

挂载也是更新的单位。布局与绘制按挂载进行，`ebox-mount-flush-count` 统计它们发生的次数，视口处理、观察者与输入会话都挂在它上面。因为 root 会记录自己喂给哪个挂载，一个 root 只挂载一次：把同一 root 挂进第二个缓冲区并不复制它，之后的修改只到达最新的挂载。要在两个缓冲区显示同样的内容，就得用 `ebox-node-copy` 复制树，或建两棵树。

生命周期有三个状态。树在构造后是 detached；当挂载把它绑到缓冲区时它是活的；释放挂载后树又回到 detached，缓冲区则保留最后一次渲染出的文本。杀掉缓冲区也会释放挂载，并运行与显式卸载相同的钩子；之后缓冲区消失。

## 渲染成字符串

#### Function: ebox-render (input)

渲染 INPUT——节点或作者表单——并把它的各行作为字符串返回。

**参数。** INPUT 是 detached 的根节点，或 `ebox-build` 能理解的作者表单。

**语义。** 树按 `ebox-viewport-width` 与 `ebox-viewport-height` 给出的视口布局（[视口](viewport.md)），绘制后拼成一个字符串，root 行之间用换行分隔。不创建缓冲区、不存在挂载，所以这是廉价地查看树输出的方式——预览、测试断言，或复制出的子树的快照。字符串携带绘制行的文本属性，包括 face 与 display 描述，其余就是一个归调用者所有的普通字符串。

**返回。** 渲染结果，字符串。

**错误。** INPUT 是有父节点的节点时报 `error→ ebox-error`（"Cannot render a non-root node"）；INPUT 是畸形作者表单时报[节点构造](ebox-node-construction.md)的构造错误。

**示例。**

```elisp
(let ((ebox-viewport-width 40))
  (ebox-render '(text "pin")))
     ⇒ "pin"
```

**参见。** `ebox-mount`、`ebox-render-to-buffer`、`ebox-node-copy`。

## 挂载树

#### Function: ebox-mount (buffer-or-name input &rest options)

把 INPUT——根节点或作者表单——挂载到 BUFFER-OR-NAME，返回根节点。

**参数。** BUFFER-OR-NAME 是活着的缓冲区或缓冲区名；缓冲区不存在时会创建。INPUT 是 detached 的根节点或作者表单。OPTIONS 可以含 `:width` 与 `:height`，用于固定视口的相应维度，而不是跟随显示窗口（[视口](viewport.md)），还可含 `:observer`，其值为接收 buffer 与报告的函数或 nil。观察器在首次 flush 前安装，使用与 `ebox-buffer-set-observer` 相同的报告；nil 关闭观察。

**语义。** 挂载用渲染出的树替换缓冲区文本、开启 `ebox-buffer-mode`（[键盘](keyboard.md)），并在返回之前写出第一版，所以调用结束的那一刻缓冲区就是最新的。root 的计算背景成为缓冲区默认背景，最后一行之后的窗口空间因此与表面一致。缓冲区已有挂载时，先释放旧挂载，与 `ebox-unmount-buffer` 的释放完全相同。树的身份不变：还是同一批节点在做模型，修改继续通过 flush 流水线流向缓冲区。一个 root 只挂一次——同一 root 的第二次挂载不复制树，并接管修改所到达的挂载位置。

**返回。** 被挂载的根节点。

**错误。** INPUT 是有父节点的节点时报 `error→ ebox-error`（"Cannot mount a non-root node"）；畸形表单报[节点构造](ebox-node-construction.md)的构造错误。`:observer` 既不是函数也不是 nil 时，在替换旧挂载前报 `error→ wrong-type-argument`。构建输入期间失败的挂载不会改动已有的挂载与缓冲区文本。

**示例。**

```elisp
(let ((buffer (generate-new-buffer "*demo mount*")))
  (ebox-mount buffer '(text "hello"))
  (prog1 (with-current-buffer buffer
           (buffer-substring-no-properties (point-min) (point-max)))
    (kill-buffer buffer)))
     ⇒ "hello"
```

**参见。** `ebox-render-to-buffer`、`ebox-unmount-buffer`、`ebox-buffer-root`。

#### Function: ebox-render-to-buffer (buffer-or-name input &rest options)

用 OPTIONS 把 INPUT 挂载到 BUFFER-OR-NAME 并返回缓冲区。

**语义。** 给想要缓冲区而不是根节点的代码使用——设置窗口、mode line 或缓冲区局部设置通常从这里开始。行为与 `ebox-mount` 完全相同、OPTIONS 相同，只有返回值不同。

**返回。** 缓冲区。

**错误。** 与 `ebox-mount` 相同。

**参见。** `ebox-mount`、`ebox-buffer-mount`。

## 检视挂载

#### Function: ebox-buffer-mount (&optional buffer-or-name)

返回 BUFFER-OR-NAME（缺省当前缓冲区）的挂载，或 nil。

**语义。** 挂载对象是所有挂载级东西的句柄：它的视口、flush 计数、观察者与输入会话。没有挂载的缓冲区、被杀掉的缓冲区、以及不存在的名字都返回 nil。用它区分活的挂载与只是持有渲染文本的缓冲区。

**返回。** 挂载对象，或 nil。

**错误。** 无。

**参见。** `ebox-buffer-root`、`ebox-mount-viewport`、`ebox-input-active-p`。

#### Function: ebox-buffer-root (&optional buffer-or-name)

返回 BUFFER-OR-NAME 中挂载的根节点，或 nil。

**语义。** 根节点就是传给 `ebox-mount` 的节点；它的子节点不能被挂载，所以这也是程序为修改缓冲区显示内容而保留的节点。缓冲区没有挂载时返回 nil。

**返回。** 根节点，或 nil。

**错误。** 无。

**参见。** `ebox-buffer-mount`、`ebox-node-children`。

#### Function: ebox-mount-flush-count (&optional buffer-or-name)

返回写过 BUFFER-OR-NAME 挂载的 flush 次数。

**语义。** 计数从挂载那次 flush 之后为 1，之后每写一次挂载加一，不论触发者是一次修改、一次批处理的结束，还是一次视口变化。不改变任何东西的修改不 flush，也不计数。计数属于挂载而不是缓冲区：挂载释放后随之消失，重新挂载从 1 重新开始。测试与诊断用它断言一次更新只用了一次 flush，而不是好几次。

**返回。** 计数；缓冲区没有挂载时为 0。

**错误。** 无。

**参见。** `ebox-flush`、`ebox-with-batch`、`ebox-buffer-update-report`。

## 释放挂载

#### Function: ebox-unmount-buffer (&optional buffer-or-name)

释放 BUFFER-OR-NAME 的挂载，保留其文本。有挂载被释放时返回非 nil。

**参数。** BUFFER-OR-NAME 是缓冲区或缓冲区名，缺省当前缓冲区。

**语义。** 释放按顺序运行 abnormal 钩子 `ebox-unmount-functions`、还原 Ebox 接管的显示设置、移除背景重映射、结束正在进行输入会话（若有），最后把根节点解绑。文本不被触碰，所以缓冲区继续显示树最后渲染的内容；它现在只是文本，之后修改树不再到达它。挂载对象不再作答，root 重新变回 detached，缓冲区可以挂载一棵新树。杀掉有挂载的缓冲区同样会释放挂载，并在缓冲区消失前运行同一个钩子。

**返回。** 释放了挂载时非 nil；缓冲区没有挂载或已死时 nil。

**错误。** 自身无；钩子报错会传播出去并中止释放，挂载保持活着。

**参见。** `ebox-mount`、`ebox-buffer-mount`、`ebox-unmount-functions`。

#### Hook: ebox-unmount-functions

在缓冲区挂载被释放时以该缓冲区为参数运行的 abnormal 钩子。

**语义。** 每个函数只收到缓冲区一个参数，调用发生在挂载解绑之前、显示设置还原之前，所以在钩子内部 `ebox-buffer-mount` 仍有回答、缓冲区看起来仍是挂载状态。函数按顺序运行。报错会传出 `ebox-unmount-buffer` 并中止其余释放步骤，所以钩子应当只做自己的事然后返回——它运行期间缓冲区处于半接管状态。

**参见。** `ebox-unmount-buffer`、`ebox-buffer-mount`。

## 条目之间的关系

`ebox-render` 与 `ebox-mount` 共享同一个输入契约——detached 根节点或作者表单——也共享同一套布局；前者返回字符串，后者把它持续写入缓冲区。`ebox-render-to-buffer` 是返回缓冲区的挂载变体。挂载的程序通常会保留传给它的根节点：挂载不给树增加任何 API，[增量更新与发布](incremental-updates-and-publication.md)里的每个修改入口都照旧可用。

查询条目回答调用者对活挂载的三个问题：这个缓冲区挂载了吗（`ebox-buffer-mount`）、它显示哪棵树（`ebox-buffer-root`）、它做过多少工作（`ebox-mount-flush-count`）。释放条目结束这段绑定：`ebox-unmount-buffer` 做显式释放，杀缓冲区则用于本来就即将消失的缓冲区；两条路径都运行钩子。两者之后，缓冲区与树重新彼此独立，树可以挂到别处。

## 语义细节

<!-- index: 显示设置; 背景重映射; 缓冲区 kill -->

挂载是一笔小事务。替换缓冲区文本、开启模式、安装背景重映射、运行第一次 flush，这一切都在 `ebox-mount` 返回之前完成；输入无法构建时什么都不碰，旧挂载维持原样。重新挂载是同一操作加上先隐式释放旧挂载，所以卸载钩子会跑，显示设置先还原再被接管。

有三块缓冲区状态属于挂载。显示设置让整行行为与布局拼出的结果一致：没有原生的续行折行、没有 bidi 重排、没有长行扫描。背景重映射让最后一行之后的窗口区域显示 root 背景而不是 frame 背景。两者都在释放时移除；缓冲区原本的局部设置还原为先前值。若输入法会话正在运行，释放会结束它。

杀掉缓冲区通过缓冲区的 kill 钩子释放挂载，并运行 `ebox-unmount-functions`：还原显示设置与背景重映射、结束输入会话、解绑根节点，与显式卸载相同，只有 mode 的收尾对垂死缓冲区没有意义。因此释放外部资源的回调在两条路径上都会跑。

## 错误与恢复

| 情形 | 报出 |
| --- | --- |
| INPUT 有父节点，渲染或挂载时 | `error→ ebox-error`，"Cannot render a non-root node" 或 "Cannot mount a non-root node" |
| INPUT 是畸形作者表单 | [节点构造](ebox-node-construction.md)的构造错误 |
| 构建期间挂载失败 | 旧挂载与文本保持原样 |
| 卸载钩子报错 | 错误传播，释放停止；挂载保持活着 |
| 缓冲区被杀 | 挂载被释放、钩子运行，缓冲区消失 |

恢复办法随状态而定。被拒的输入让树保持 detached、缓冲区保持原样，修好表单再挂即可。钩子报错让挂载保持活着，修好钩子后再释放即可。挂载一旦释放——无论经过 `ebox-unmount-buffer` 还是杀缓冲区——树就是 detached 的，可以重新挂载或渲染成字符串。
