# 滚动

滚动盒子的内容比它的视口更大，按行显示内容的某一扇窗口。Ebox 拥有这扇窗口：偏移是节点状态而不是编辑器状态，所以列表可以在缓冲区内部滚动而缓冲区本身不动，多个滚动容器可以嵌套，聊天视图可以把自身钉在最后一行。本章描述滚动容器、偏移 API、末尾锚定、嵌套滚动与 scroll-into-view、命令、滚轮与滑动层，以及内部滚动容器与缓冲区窗口滚动之间的差异。[样式属性参考](style-properties.md)定义 `:overflow` 与 `:scroll-anchor`；[Hosts](hosts.md)描述 `etaf-scroll-*` 的 Host 层 API，本章把它作为同一模型的 ETAF 层来写。

## 滚动容器

<!-- index: 滚动容器; overflow; 滚动偏移; 滚动链 -->

当节点的 `:overflow` 为 `scroll` 或 `auto`，且内容比视口更高时，该节点可滚动。`hidden` 盒子裁剪但不滚动，`visible` 盒子随内容一起长高，两者都不提供滚动范围。可滚动状态不增加任何自己的布局：内容保持行位置，改变的只是内容行到显示行的映射。

滚动从不重排。设置偏移会更新节点的滚动值、把这些行记为受损、并入队挂载；下一次 flush 只重新合成这些行。滚动因此廉价，也因此与改写文本的缓冲区编辑不同。

一个位置可以被多个滚动容器包住。可滚动祖先按由内到外组成的链，就是滚轮或滚动命令在剩余距离交给窗口之前要走过的路径。

```elisp :figure 滚动容器保持声明的高度：显示三行，第四行留在下面
(etaf-view
 (box :width '(ch 26) :height '(lh 3) :overflow 'scroll
      :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
   (column (text "1 first") (text "2 second") (text "3 third") (text "4 fourth"))))
```

## 读写偏移

<!-- index: 滚动偏移; 夹取; 滚动回调 -->

#### Function: ebox-node-scroll-offset (node)

返回 NODE 的滚动偏移（行）。

**参数。** NODE 是任意节点；不能滚动的节点偏移就是 0。

**语义。** 该值是节点视口越过内容行数的量，从 0 起。它是节点状态并在布局后保留：应用、滚轮或 `ebox-node-scroll-into-view` 设置的偏移，在这里读回时是同一个值，直到有东西改变或夹取它。

**返回。** 偏移行数。

**错误。** 无。

**参见。** `ebox-node-set-scroll`、`etaf-scroll-offset`。

#### Function: ebox-node-set-scroll (node offset)

把 NODE 的内容滚动到 OFFSET 行，夹取后返回实际应用的偏移。

**参数。** OFFSET 是行数，会被夹取到滚动范围；内容放得下的节点范围为 0。

**语义。** 到达最后一行会把节点钉住，`:scroll-anchor end` 的节点因此在内容增长时继续显示末尾；任何更小的偏移会解除钉住。变化的偏移更新显示的行而不重排，稳定之后以新偏移调用节点的 `:scroll` 函数——列表在顶部或底部加载更多行的钩子。设置已有的偏移不改变任何东西，也不触发回调。

**返回。** 夹取后实际应用的偏移。

**错误。** 无；不可滚动的节点保持 0。

**参见。** `ebox-node-scroll-offset`、`ebox-node-scroll-into-view`、`etaf-scroll-to`。

## 末尾锚定

<!-- index: 末尾锚定; 钉住; 滚动锚点 -->

聊天或日志视图希望最新一行已经可见，并且在新行到来时继续停在那里。这就是 `:scroll-anchor end` 样式与钉住状态的组合：布局把带末尾锚点的节点偏移解析到当前上限，增长因此无需显式滚动就让它停在末尾，应用只在关心时才读偏移。

增长不经过 `set-scroll`，所以不会上报给 `:scroll`：钉住期间追行的日志不会触发自己的加载更多回调。滚动离开会解除钉住，行为与普通滚动容器一样；滚回末尾则重新钉住。ETAF 包装层用 `etaf-scroll-to` 与符号 `end` 暴露同一行为。

**示例。** 三行视口里的十行列表在 `:scroll-anchor end` 下初始偏移 7；追加一行后偏移是 8，且没有滚动回调，因为被钉住的节点跟随了它的最后一行。

## 嵌套滚动容器与 scroll-into-view

<!-- index: scroll-into-view; 嵌套滚动; 对齐 -->

#### Function: ebox-node-scroll-into-view (node &optional align)

滚动 NODE 的滚动祖先使它的行走入视野；返回 NODE。

**参数。** NODE 是要露出的节点。ALIGN 是 nil、`start` 或 `end`。

**语义。** 每个滚动祖先由内到外移动最少的距离，使节点的外边距盒可见；节点比视口高时以其顶部为准。ALIGN `start` 把节点顶部放到滚动容器的第一行；`end` 把它的底部放到最后一行，以内容允许为限。只有 Ebox 滚动容器会移动：窗口滚动与 point 归调用方，键盘选择因此可以露出某一行而不移动读者的窗口。

**返回。** NODE。

**错误。** ALIGN 不是 nil、`start` 或 `end` 时报 `wrong-type-argument`。

**参见。** `ebox-node-set-scroll`、`etaf-scroll-into-view`。

**示例。** 三行视口里的十行列表，中间一行在默认对齐下得到偏移 3、`start` 得到 5、`end` 得到 3；最后一行三种对齐都得到 7，因为内容会夹取。

## 命令、滚轮与滑动

<!-- index: 滚动命令; 滚轮; 滑动手势; 滑动距离 -->

交互层把按键与指针手势变成同样的偏移写入。按键与滚轮走过 point 处的滚动链，再把剩余距离交给窗口；双指水平滑动是一个带自身距离与静默阈值的手势，作为整体识别而不是逐事件识别。

#### Variable: ebox-scroll-step

一次滚轮步进或 `ebox-scroll-down` 滚动的行数。

**语义。** 默认 3 行。`ebox-scroll-down` 与 `ebox-scroll-up` 不带数值参数时用它，滚轮命令每个事件也用它。修改它会改变整个会话的步进。

**参见。** `ebox-scroll-down`、`ebox-wheel-scroll-down`。

#### Function: ebox-scroll-down (&optional n)

把 point 处的内容向下滚动 N 行（默认 `ebox-scroll-step`）。

**参数。** N 是行数；nil 表示使用滚动步进。

**语义。** point 处每个滚动祖先由内到外尽可能消耗 N，剩余部分滚动窗口。向下滚动把更晚的行移入视野，偏移增大。

**返回。** Nil。

**错误。** 无。

**参见。** `ebox-scroll-up`、`ebox-scroll-page-down`。

#### Function: ebox-scroll-up (&optional n)

把 point 处的内容向上滚动 N 行（默认 `ebox-scroll-step`）。

**参数。** N 是行数；nil 表示使用滚动步进。

**语义。** 与把行数取负的 `ebox-scroll-down` 完全相同：偏移减小，更早的行进入视野。

**返回。** Nil。

**错误。** 无。

**参见。** `ebox-scroll-down`、`ebox-scroll-page-up`。

#### Function: ebox-scroll-page-down (&optional arg)

把 point 处的内容向下滚动一页，或 ARG 行。

**参数。** ARG 是前缀参数；给出时其数值就是距离。

**语义。** 没有 ARG 时一页等于窗口 body 高减去 `next-screen-context-lines`，因此这些命令保留与编辑器自带翻页相同的重叠；给出 ARG 时使用精确行数。距离走与 `ebox-scroll-down` 相同的滚动链。

**返回。** Nil。

**错误。** 无。

**参见。** `ebox-scroll-page-up`。

#### Function: ebox-scroll-page-up (&optional arg)

把 point 处的内容向上滚动一页，或 ARG 行。

**参数。** ARG 是前缀参数；给出时其数值就是距离。

**语义。** `ebox-scroll-page-down` 的向上对应物。

**返回。** Nil。

**错误。** 无。

**参见。** `ebox-scroll-page-down`。

#### Function: ebox-wheel-scroll-down (event)

把滚轮 EVENT 处的内容向下滚动。

**参数。** EVENT 是滚轮事件。

**语义。** 事件所在窗口显示已挂载的 Ebox 缓冲区、且事件落在其文本区时，事件位置的滚动链消耗一个 `ebox-scroll-step`；否则事件交给 `mwheel-scroll`，普通缓冲区上的滚轮因此与从前完全一样。缓冲区模式把它绑定到 `wheel-down`、`mouse-5` 及其多击变体，文本区与 fringe、margin 都算。

**返回。** Nil。

**错误。** 无。

**参见。** `ebox-wheel-scroll-up`、`ebox-scroll-step`。

#### Function: ebox-wheel-scroll-up (event)

把滚轮 EVENT 处的内容向上滚动。

**参数。** EVENT 是滚轮事件。

**语义。** `ebox-wheel-scroll-down` 的向上对应物，共享它的挂载检查与 `mwheel-scroll` 回退。

**返回。** Nil。

**错误。** 无。

**参见。** `ebox-wheel-scroll-down`。

#### Function: ebox-wheel-swipe (event)

从滚轮 EVENT 识别水平双指滑动。

**参数。** EVENT 是水平滚轮事件。

**语义。** 一次手势持续累积位移，达到 `ebox-swipe-distance` 时，指针下最近 enabled、且 `:swipe` 交互属性为函数的节点收到手指方向 `left` 或 `right`，且只收到一次。同一手势后来的事件（包括动量）都被吸收。超过 `ebox-swipe-quiet` 的停顿或方向反转会开始下一次手势，所以反向的连续滑动各自触发，无需等待动量停止。macOS 自然滚动下手指向右报告为 `wheel-left`，方向映射因此查询 `mouse-wheel-flip-direction`；缓冲区模式把该命令绑定到 `wheel-left` 与 `wheel-right`。

**返回。** Nil。

**错误。** 无。

**参见。** `ebox-swipe-distance`、`ebox-swipe-quiet`。

#### Variable: ebox-swipe-distance

手势在被认定为一划之前走过的水平像素数。

**语义。** 默认 60 像素。距离取滚轮事件水平位移的绝对值；事件没有可用位移时按整段距离计，所以只报告方向而不报告位移的设备在第一个事件就能触发。

**参见。** `ebox-wheel-swipe`。

#### Variable: ebox-swipe-quiet

结束一次滑动所需的无水平滚轮事件秒数；方向改变也立即结束。

**语义。** 默认 0.35 秒，正好吸收一次物理滑动之后的动量事件。调大它会把更慢的连续滑动并成一次；调小它会更早把它们分开。

**参见。** `ebox-wheel-swipe`、`ebox-swipe-distance`。

## 内部滚动与缓冲区滚动

<!-- index: 内部滚动; 窗口滚动; 滚动回退; ETAF 滚动 API -->

内部滚动容器与缓冲区窗口是两个不同的垂直位置，命令层按这个顺序使用它们：Ebox 滚动容器先消耗它能消耗的距离，只有剩余部分滚动窗口。缓冲区末尾一旦可见，窗口向下滚动就被抑制，所以放得下整个窗口的树在内层滚动时保持它固定的顶底行。`scroll-into-view` 有意只停在内层，把窗口滚动与 point 留给调用方。

ETAF 层为 Host 包装同样的偏移。Host 属性 `:on-scroll` 中继到 Ebox 的 `:scroll` 函数，在滚轮、滚动键或任何 `etaf-scroll-*` 调用之后收到新偏移；钉住的末尾锚点下的内容增长不算滚动；中继在 Host 重新渲染后仍然保留。

#### Function: etaf-scroll-offset (runtime host-ref)

返回已挂载 RUNTIME 中 HOST-REF 的滚动偏移（行）。

**参数。** RUNTIME 是已挂载的 Runtime；HOST-REF 命名滚动 Host。

**语义。** 值是 Host 的当前偏移，与它的 Ebox 节点上 `ebox-node-scroll-offset` 返回的数字相同。

**返回。** 偏移行数。

**错误。** 未知 HOST-REF 报错。

**参见。** `etaf-scroll-to`、`ebox-node-scroll-offset`。

#### Function: etaf-scroll-to (runtime host-ref offset)

把已挂载 RUNTIME 中的 HOST-REF 滚动到 OFFSET 行并返回夹取后的偏移。

**参数。** OFFSET 是行数，或符号 `start`、`end`。`start` 表示第一行，`end` 表示最后一行。

**语义。** 值被夹取到 Host 的滚动范围后经 Ebox 偏移 API 应用，所以 `end` 会钉住 `:scroll-anchor end` 的 Host，更小的偏移则解除钉住。与该样式组合使用就是聊天与日志模式：Host 从最后一行开始、跟随内容增长，用户滚回末尾时重新钉住。

**返回。** 实际应用的偏移。

**错误。** OFFSET 既不是整数也不是 `start`、`end` 时报 `wrong-type-argument`；未知 HOST-REF 报错。

**参见。** `etaf-scroll-by`、`etaf-scroll-offset`。

#### Function: etaf-scroll-by (runtime host-ref delta)

把已挂载 RUNTIME 中的 HOST-REF 滚动 DELTA 行（负数向上）；返回新偏移。

**参数。** DELTA 是行数；负值向更早的行滚动。

**语义。** 偏移与当前值相加后经夹取 API 应用，越过任一端的滚动正好落在那一端。

**返回。** 夹取后的新偏移。

**错误。** 未知 HOST-REF 报错。

**参见。** `etaf-scroll-to`、`etaf-scroll-offset`。

#### Function: etaf-scroll-into-view (runtime host-ref &optional align)

滚动 RUNTIME 中 HOST-REF 周围的滚动 Host 使它走入视野。

**参数。** HOST-REF 是要露出的 Host；ALIGN 是 nil、`start` 或 `end`。

**语义。** 每个包裹的滚动容器移动最少距离，`start` 把 Host 顶部对齐滚动容器的第一行、`end` 把它的底部对齐最后一行——例如在更早的行被前插之后保持读者所在行不动。窗口滚动与 point 归调用方。

**返回。** HOST-REF。

**错误。** ALIGN 不是 nil、`start` 或 `end` 时报 `wrong-type-argument`；未知 HOST-REF 报错。

**参见。** `ebox-node-scroll-into-view`、`etaf-scroll-to`。

**示例。** `(etaf-scroll-into-view runtime 'row5)` 返回 `row5`，三行视口里十行列表所在面板的偏移为 3。

## 错误与恢复

<!-- index: 滚动错误; 夹取; 未知 host -->

大多数滚动调用不会失败：偏移被夹取，不能滚动的节点保持 0，未达到距离的滑动什么也不做。错误都是参数错误——不是 nil、`start` 或 `end` 的对齐值，传给 `etaf-scroll-to` 的非整数偏移，或未挂载的 Host 引用——它们会指出有问题的值。

有一个行为值得记住：内容变短时偏移会被重新夹取。从已滚动的列表中删行，偏移上移到新的上限；带末尾锚点的 Host 则跟随新的最后一行。保存了自己那份偏移的应用，在改变内容高度的修改之后应当读回偏移，而不是相信上次写入的值。
