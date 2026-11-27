# Ebox 架构

[English](architecture.md)

Ebox 的实现模型是每个 mount 拥有一棵可变 retained 节点树。Public 调用方构建树、把它挂载到 Emacs buffer，然后修改节点。Ebox 在受影响节点上记录 style、layout 与 paint dirt，找到最小安全布局边界，只组合 damaged root lines，并只重写发生变化的 buffer 行内片段。

Public 合同是 [`../ebox.el`](../ebox.el) 的 Commentary。`lisp/` 下的文件是私有实现模块。

## 模块与依赖方向

`ebox.el` 是包入口。它把 `lisp/` 加入 `load-path`，require 实现模块，并维护 public API 清单。

实现模块按职责划分：

| 模块 | 职责 |
| --- | --- |
| `ebox-size.el` | 纯验证与解析 `(unit number)` 长度和尺寸函数。 |
| `ebox-style.el` | Ebox style schema、alias、validator、shorthand expansion、ECSS scope 创建与样式编译。 |
| `ebox-measure.el` | 像素测量、文本单元分段、display-space 构造、属性比较与 display twin。 |
| `ebox-node.el` | Retained node record、child sequence、author 属性解析、author DSL、selector adapter 与 computed-style record。 |
| `ebox-layout.el` | Text、box、row、column 与 positioned layout；line composition；damage range；root-line edit planning。 |
| `ebox-flex.el` | `ebox-layout.el` 使用的 flex 与 grid 算法。 |
| `ebox-buffer.el` | Mount、dirty queue、batching、flush 编排、viewport 测量、buffer diff 写入与几何查询。 |
| `ebox-interaction.el` | Keymap、help/pointer/hover decoration、focus、activation、drag tracking、input session、scrolling 与 selector query。 |
| `ebox-viewport.el` | Window-size event 桥接和稳定后的 viewport refit 调度。 |
| `ebox-image.el` | 图片准备、converter 协议、不可变 raster cache 与图片内容访问。 |
| `ebox-file.el` | `.ebox` source 读取、companion 加载、preview mode 与包 byte compilation helper。 |

底层纯模块不知道 mount。node 依赖 size、style 与 measurement。layout 依赖 retained node，并通过 private function 调用 flex/grid。buffer flushing 依赖 node 与 layout。interaction 位于 mounted buffer 之上。viewport delivery 对尺寸变化 refit，对度量变化刷新，均不重建挂载。图片在 layout 之外准备，随后成为节点内容。

## 核心 record

### Node

`ebox-node` 是 retained tree record。它存储：

- author identity 与 selector facts：tag、id、classes、attributes、states、key 和用户数据；
- 编译后的 declaration、default rule、本地/共享 ECSS scope 与活动 scope environment；
- help、pointer、hover、keymap、tab index、disabled state 等交互属性；
- text 或已准备图片内容；
- chunked sequence 中的 parent/child 链接；
- computed style、measurement cache、intrinsic-size cache 与最后一次 layout；
- dirty bits、dirty children、structural operations 与 overlay registration；
- scroll offset，以及 root 的 owning mount pointer。

children 与 stacked layout items 使用 chunked sequence。每个元素记录自己的 run 和位置，因此插入、删除和 index lookup 的成本受 run size 与 run count 限制，而不是移动 flat vector 中所有后续元素。

### Computed style

`ebox-cs` 是由 ECSS computed values、parent style 和 node tag 生成的 hash-consed computed-style record。它保存完整 normalized values，以及 face、继承 paint、dimensions、edges、borders、overflow、positioning、flex/row/column facts、z order、viewport-unit dependencies 和 layout key 等热路径布局字段。相同局部输入共享同一个 style 对象，因此几何比较可以使用对象 identity 或 interned layout key。

style environment 保存在 node 上。内联 rule 和 default 变为 scope；shared scope 只通过显式 root 和 member 生效。subject-local scope style 可以进入 style cache key；结构 selector 回退到 ECSS 计算。

### Layout 与 mount record

`ebox-geo` 保存已解析 margin、border、padding、border-box size、content-box size、visible height、scroll offset、content height 和 layout items。stacked layout 使用 chunked item sequence；positioned layout 使用 vector。匿名 inline paragraph 是所属 box 的 `ebox-para` record。

`ebox-mount` 将一个 root 绑定到一个 buffer。它存储 viewport 尺寸、line anchors、已写 line parts、update reports、observer、focus、active 与 hover state、input session、queue flag、flush count 和保存的 display settings。

## Dirty bits 与 queueing

每个 mutation 都通过 `ebox--mutation`，先执行变更，再在没有 batch 或 flush 时 flush queued mounts。

Dirty bits 包括：

- `ebox--d-style`：style 或 selector 输入变化。
- `ebox--d-layout`：geometry 或内容尺寸可能变化。
- `ebox--d-paint`：geometry 不变但 paint 可能变化。
- `ebox--d-desc`：descendant 变化。
- `ebox--d-queued`：该节点已列入 parent 的 dirty children。

`ebox--mark` 在变更节点设置 bit、清除 intrinsic cache、把 dirty path 记录到 ancestor，并将 root 的 mount 入队。结构 mutation 还会把简短 operation 描述压入 parent，使 stacked layout 能在可能时记录精确 insert/remove damage。

`ebox-with-batch` 增加动态 batch depth。最外层 unwind path 调用 `ebox-flush`，因此所有 queued mount 会以最终树状态写入一次。

## Flush pipeline

`ebox--flush-mount` 是 retained engine 的中心 pass：

1. 绑定 mount viewport 与 current mount。
2. 在 dirty paths 上运行 style pass。
3. 用当前 viewport 对 root 运行 layout。
4. 放置 anchored absolute boxes 直到稳定。
5. 剪除被更大范围覆盖的 damage records。
6. 将 damage 转成有序 root-line edits。
7. 第一次 flush 重写整个 buffer；之后只重写 edit ranges。
8. 保存并发送 update report。

## Style pass

`ebox--style-pass` 在节点 style bit 已设置、没有 computed style，或 ancestor computed style 改变时访问节点。它根据节点 declarations、active scopes 与 parent style 计算新的 `ebox-cs`。

如果新 style 通过 object identity 相等，则无需更多工作。如果只有 layout key 不变，Ebox 标记 paint dirt。否则标记 layout dirt、清除 intrinsic cache，并在 flex/grid item facts、outer participation 或 absolute positioning 影响 container 时标记 parent layout。

摘下子树时，同时清除节点的 computed-style 引用、layout、viewport dependencies 和浮层宿主登记。重新接入时必须重新访问整棵子树，即使继承输入没有变化；仅复用相同的缓存 style，无法重建已经清除的浮层宿主和 dirty paths。共享 style 对象仍留在缓存中，节点身份、作者属性和滚动状态保持不变。

viewport-unit dependencies 记录在 weak table 中。`ebox-refit` 使用该表，在 mounted viewport 变化时只标记实际读取 `vw` 或 `vh` 的节点。

## Layout pass 与 relayout boundary

`ebox--layout` 接收节点、可用 inline 像素、mode（`stretch`、`shrink` 或 `exact`）、containing block height 和可选 forced height。最后一次 constraint vector 保存在节点上。如果 constraint 与相关 dirty bits 都未变化，layout 会跳过。

当 descendant dirty 时，`ebox--relayout-partial` 尝试只结算记录的 dirty children。stacked container 可以通过移动后续 stack items 并调整自身 content height 来吸收 child height change。这就是常见 relayout boundary：当 ancestor 的 outer size 与 child placements 仍兼容时，damage 保持局部。如果 container 不能吸收变化，Ebox relayout 该 container。如果 full relayout 后 container size 和 child places 不变，则保留 inner damage；否则该 container 的整个 margin box 成为 damage，ancestor 只看到它的新 outer size。如果局部重排已经改过 child 几何再回退，必须标记 container 的整个 margin box：此时重新拍 child-place 快照只会看到新尺寸，不能代表 buffer 中仍显示的旧布局。这样固定高度编辑器内部的文字增减不会变成外部 buffer 的插行或删行。位置快照也包含 layout 是否存在及 overlay 是否已放置：摘下的节点可以保留数值尺寸，重新接入相同坐标仍是新绘制。

文本测量按 text node、font face 与 wrap mode 缓存。paragraph layout 将文本拆成 pixel-width units，保留受支持 cluster 与 fixed display space。face 的行高取正文所用字体中最大的 ascent 加 descent，每帧用拉丁与中日韩字符各探测一次，所以中文回退字体的行框更高时整行跟着变高，不会把中文缩进去。发布出来的每行开头带一个零宽、正好一行高的空格，把只含较矮字形的行也垫到行高；载体在行首，始终落在可见区域里，截断边界碰不到它。它带首格的文字属性，行首的 face、hover、help 与命中判定仍归那一格。buffer 文本在每行开头带这个载体。图形 frame 上，若某 cluster 的回退字体高于其 face 的行高（彩色 emoji、符号、数学字母，或字体 ascent/descent 超过该 face 正文所用字体的任何文字，每个字符只判定一次），则以该 face 自己的字号为基准、取能让该行保持一行高度的最大比例缩放并绘制；判断时与普通字符同处一行，因为行高取最大 ascent 加最大 descent。此外，对于任意解析到非基准字体的非 CJK 回退字形，测量阶段记录其实际解析出的 `:family` 并在绘制时固定到该字符的 `face` 与悬停 `mouse-face` 上：Emacs 按已实现 face（含前景/背景色）独立缓存动态回退字体，固定测量时的字体族可确保不同配色盒体与悬停态渲染出与布局完全一致的像素宽度，不致引起右边框错位。样式里的字号是相对正文的比例，所以标题在任何平台上都保持同一比例：比例一旦换成默认字体给出的 face 高度，被压缩的字形就从那个高度缩，而不是从默认 face 缩。这样每行都保持纵向网格与图像切片所依赖的行高。不使用 SVG 渲染 emoji：librsvg 的 Pango 后端遇到某些 emoji 会使 Emacs 中止。box 在横向解析为像素、纵向解析为行。row 与 column 沿一个轴定位直接子节点。flex 使用 min/max freezing、wrapping 与 alignment 做 main-size grow/shrink。grid 展开 track、解析 fixed/intrinsic/fractional size，并按一基 grid position 放置 item。

所以一个 face 要留两个高度。`ebox--face-text-height` 只量拉丁 `0`，量出这一行最短能有多矮；行末 strut 拿它跟行高比，只决定这一行要不要垫到整行。`ebox--face-body-height` 量 `0汉` 两个探针，代表这个 face 的正文行盒；`ebox--face-line-height` 取它跟默认行盒的较大值，`ebox--fit` 再用这个行高判断字形有没有超高。合成一个两边都会坏：放进中文探针，strut 的 `(> line text)` 判据在等高时判为没有差值，只含拉丁的行不再撑满整行；只量拉丁，放大字号的标题又把中文当成超高回退字形，压到 0.81 倍。strut 关心这一行能多矮，fit 关心这个 face 的正文有多高，两个问题不同，各留一个函数。

absolute box 注册到 positioning host（最近的非 inline 父节点；`:layer root` 时为根）。本地 overlay 在 host 内从其内容原点组合；未锚定的 root-targeted overlay 从根的 border box 原点起算，使页面级遮罩覆盖根 padding，并仍保留逻辑 parent 供 style 与 selector 使用。anchored overlay 从唯一 target 计算 placement，并在 normal layout 后放置，使 target 移动无需触发无关 relayout。

浮层位置、尺寸和层序不变，且 host 流内容未平移时，可保留内部行 damage。只有旧新行数相同，且范围处于根和浮层边界内的替换才走该路径。内部插行或删行、越界范围、位置变化和重排层序仍重绘有界的新旧覆盖范围：浮层内容绝不能增删 host buffer 的物理行。host 完整重排仍保留整浮层 damage。

## Paint 与 parts cache

layout 产生 geometry；paint 按 root line 懒组合。node line 是由 margin、border、padding、content、overlay 与交互属性组成的 string parts tree。节点在高度限制内缓存已组合 line parts；paragraph 缓存 wrapped line strings。damage 会使 changed node 以及已经组合过它 line 的 ancestor 失效。

`ebox--join-parts` 展平嵌套 parts。display space 按 pixel width 与 face intern，拟合字形按 cluster 共享同一个 display。Emacs 会合并相邻且 `display` 对象 `eq` 的字符，因此 `ebox-measure.el` 为每个共享 display 保存一个相等 twin，并在同一 display 相遇处替换为 alternate：拟合相同字形序列时如此，part 边界拼接时也如此。这样既保持精确像素间距和每个字形，又允许 line parts 跨 flush 共享。

完整、同色的 1 px solid 边框在图形 frame 上可对首末行作圆角绘制。只有空白角落会换成缓存的 SVG 切片，中间仍是原生文字和边框 face。切分前检查原始显示单元，避免把被切断的字形误判为空白。半径最多为一标准行且不超过盒宽高的一半；padding 不足、非均匀边框与终端保留方角路径。切片缓存键只含几何、颜色与显示度量，不持有节点或回调；标题色带取相邻内容的背景，不把面板整体栅格化。

交互 decoration 在 composition 中发生。Ebox 填充未设置的 `ebox-node`、`keymap`、`help-echo`、`pointer` 和 `mouse-face` property，使最内层显式节点胜出，ancestor keymap 覆盖未 override 的 descendant。节点拥有自己的装饰缓存，使 hover face 在多行之间保持同一对象。原生 mouse face 先取节点计算出的 face，再叠加 hover 声明：显示时 `mouse-face` 会**替代**文本的 `face`，所以只声明填充色的 hover 样式仍保留标签的墨色、字重与装饰，不会回落到 frame 默认前景。

hover 反馈需要知道指针位置，但 buffer 常驻 `track-mouse` 会把整个 frame 的移动都变成输入，包括移到别的窗口上的移动；命令循环随后会带着这个 buffer 执行那个窗口的 `mouse-movement` 绑定。Ebox 因此在每个 hover 目标上画一个 `help-echo` 探针：Emacs 不需要 `track-mouse` 就会在指针移动时调用它，它绘制进入状态并启动一个短的指针守卫。守卫在拥有该窗口的 frame 内解析指针位置：用 `mouse-pixel-position` 减 `window-pixel-edges`，两者都相对同一个 frame；不要拿指针相对整个显示器的位置去减窗口报告的绝对边缘。子 frame 可能相对父 frame 摆放，而它报告的绝对边缘不含那段原点，两个坐标系一混，命中判定就会落到指针下面几行而不是指针所指的那一行。守卫只在仍有反馈可画时跟着指针，指针离开后恢复原状，再次进入仍由同一个探针接手。每段的原始帮助保存在 `ebox-help-echo` 中并由探针返回，echo area 与 tooltip 的输出因此不变。所有状态 face 都遵循这条规则：状态样式只声明它要改的属性，原生 face 复述节点自己的墨色、字重、斜体与装饰；静止 face 是共享并 intern 的对象，状态 face 先复制再叠加覆盖。样式变化因此会清掉装饰缓存并重建 face，而不是保留上一次的颜色。替换声明属性时立即清空缓存，包括不再组合新行的隐藏节点；节点或声明能力退役后，没有全局缓存继续持有这些包含回调的交互属性。

overlay 拼接进它覆盖的行时不做字符串连接。`ebox--split-parts` 在 overlay 的像素列处切分底层 parts；跨越切点的 string 变为按宽度截取的 substring 加边缘空白（空白保留被切单元除 `display` 外的属性，交互因此不丢失），组合出的 string 把像素宽度记录在 `ebox--part-widths` 中，后续拼接无需重新测量。没有边框的 overlay 行保持为 part list，因此移动 overlay 的成本是覆盖行数乘以各行的 part 数。

带滤镜的 overlay 借用下层绘制，但替换其输入装饰。合成时先按浮层的空白区段裁剪背景，每个借用片段只复制一次，在该副本上完成滤镜和覆盖层输入属性的赋予；被浮层自身内容隐藏的像素不作滤镜处理。共享来源片段保持不变，不新增持有回调字符串的缓存。文本滤镜展平嵌套继承 face，并读取画布 remap 后的默认颜色。输入归属一致的空白恒等滤镜表面遇到不可切片的文字单元时，将截断边界扩展到整个字形；文字保持完整，输入按原生整格归属，而不是把部分文字换成空格。图像与 display space 仍精确到像素切片。PNG、JPEG 与 SVG 的 data 描述符使用内存 SVG component-transfer 合成：在 sRGB 中乘颜色通道，不改变 alpha。栅格字节以内嵌图像绘制；SVG 内容保留为矢量，而不是低分辨率的嵌套图片。SVG 根的 `currentColor` 使用原生前景色，透明像素使用滤镜后的背景色。原生 slice/raise 修饰保持在合成图像之外，局部裁剪和行内 inset 因此保留几何。弱身份缓存按亮度、颜色与 frame，为每个存活的描述符或 display 最多保留八份近期变体，不持有节点或回调。不支持的图片格式、仅含文件的原生 display 及无 SVG 的 frame 保留原图像素，不会把内容丢掉。prepared 图像已经拥有来源字节，合成变体不做来源 I/O。

## Buffer 写入

每个 mount 的第一次 flush 都会 erase 并写入完整 root，即使 root 已有独立渲染或此前挂载留下的 layout：只有当前 mount 已完成的发布才建立 buffer 行坐标。写入直接插入合成片段，不分配拼接整行；完整 root 未超过既有 remembered-parts 上限时填充同一张表，并记录写入后的 buffer tick。更大的 mount 把槽位留给后续发生变化的行，避免开头的静态行挤占局部更新的工作集。后续 flush 从 damage records 计算 root-line edits。每个 edit 是 `(START OLD NEW)`，其中 `START` 使用 preceding edits 后的 post-layout line 坐标。

每 128 行一个 line anchor，使 Ebox 无需为每一行保留 marker 也能定位 edit start。被重写范围内的 point 与 window start 按 line 和 column 记录，写入后再恢复。

对 changed line，`ebox--write-line` 使用 mount 记忆的 part list。`ebox--rewrite-parts` 跳过前后同一共享 string 对象，只把中间变化区间交给 `ebox--rewrite-span`：保留公共字符前后缀，只设置变化的 property runs。单个变化片段或字符边界对齐的多个片段直接使用 remembered strings，无需拼接或复制 buffer 文本；内部同一共享片段也跳过写入。共享两端既不复制也不按值比较。没有 remembered parts 时，同一写入器处理整行。face 按值比较，display、keymap 和带回调的值则保留合成结果的对象身份。只改属性不会删除字符或移动其原生 marker。外部 buffer edit 会通过 buffer tick 使 remembered parts 失效；下一次 flush 从 retained tree 安全重算。

挂载期间禁用 Emacs 原生续行，因为 Ebox 已完成每行的折行和定位。再次原生折行会预留续行列，并可能在右侧露出不属于应用的背景色条。卸载后恢复 buffer 原有的折行设置。

mount 尚无任何行时跳过位置跟踪，因此首次写入空 buffer 的内容保持 point 与 window start 在顶部。每次 flush 结束时 `ebox--sync-canvas` 把 buffer 的 `default` 背景 remap 为根节点的计算背景，使最后一行以下与行尾之后的窗口区域与根一致；卸载时移除该 remap。

## Viewport、scrolling 与 input

mount 记录一个 viewport。`ebox-viewport.el` 监听 frame/window-size notification，等待安静间隔，然后对已显示 mount 调用 `ebox-refit`。临时 minibuffer、completion 或 echo-area 高度变化不会强制更小 viewport，除非 frame 自身改变。

Buffer 文本缩放是另一种 viewport intent。它改变每个已测量字形所用的度量，却不产生 window-size notification；桥接层从 `text-scale-mode-hook` 记录被缩放的 mounted buffer，等缩放稳定后清空一次共享字形缓存并整棵重新布局。flush 期间测量把 `ebox--measure-buffer` 绑定到挂载缓冲区，字形宽度、原始尺寸与行高因而都读该缓冲区自己的 face。Emacs 会就地修改 remapping alist，缓存键因此使用不可变快照；computed style 复用上下文字形缓存，不再自行跨缓冲区缓存字符宽度。两类事件共享尾部任务，中断时保留未开始的工作。刷新后 `ebox-display-change-functions` 发布有效度量，外部图像提供者读取 `ebox-display-metrics` 重新切分固定像素内容。

scroll offset 存在 node 上。scroll mutation 改变可见 content lines，而非 layout constraints，因此 clean scrollable node 可直接为自身 visible height 入队 line damage。

input session 在一个隐藏的编辑 buffer 中编辑某个 text node 的值。挂载 buffer 本身从不被直接编辑：buffer-local pre-command hook 把每个按键转到它在编辑 buffer 中的绑定，因此原生命令、undo、kill ring 与输入法都作用于这个值。每条命令之后，值通过普通 layout mutation 成为节点文本；节点处于编辑状态时，其 piece 为每个字符带上值偏移（`ebox-offset`），用于在两个 buffer 之间映射 point、点击、按行移动与 region。输入法 preedit 文本以带下划线的形式显示在 caret 处；平台 preedit 事件绕过命令循环，所以存在 session 时由 session 经 `special-event-map` 接管。节点盒子内的主键按下由 session 自行跟踪并消费释放事件，因此点击、拖动与多击不会到达画布的按下命令。flush 与 refit 不会等待 session。

## 不变式

- Retained node tree 是事实来源；buffer text 是输出缓存。
- 节点最多有一个 parent。detached root 可以渲染或挂载；mounted descendant 必须留在自己的 root tree 中。
- 只有 public mutation 改变 retained node。实现 cache 由 dirty bits 失效，不从 buffer text 反推。
- computed style 属于构建它时的 parent style、declarations、selector facts 与 scope environment。
- 纵向 geometry 基于行；横向 geometry 基于像素。
- 同 constraint 下的 clean node 保留 layout 与 composed line cache。dirty node 要么记录精确 damage，要么 damage 最小 shape-changing boundary。
- buffer 写入保留无关 buffer state：read-only、undo list、modified flag、point 与 window start。
- 来源读取与外部 converter 执行只发生在图片准备阶段，绝不发生在 layout 或 buffer 写入中。准备会预热原生解码；首次背景或亮度变体可解码内存描述符，此后绘制复用它。
- 图形图片的每一行是一个显示整行切片的字形：redisplay 对每个字形都绘制一次图片（某些平台还会重新缩放），按单元格切片会把滚动和重绘成本乘上列数。在盒子或浮层边缘裁剪这样的行时缩窄切片，而不是换成空格。
- private module 可以变化；consumer 只 require `ebox`，只使用 `ebox.el` 中记录的 symbol。

## 设计理由

retained tree 使小更新无需为每次变化重建完整描述。dirty bits 分类可复用内容。hash-consed computed style 降低继承和 scoped style 复用成本。relayout boundary 将常见编辑（例如垂直 stack 中的文本变化）转成局部 line damage。parts-level buffer diff 避免替换 Emacs redisplay 可保留的字符和属性。最终 public API 保持简单：build、mount、mutate、flush、query、unmount。
