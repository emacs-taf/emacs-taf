# 视口

挂载的树并不拥有屏幕，它拥有一个视口——布局据以解析的那块矩形。缓冲区的窗口决定这块矩形，用户的缩放决定它何时变化，而 Ebox 是把这些编辑器事件变成一次稳定重排的那一层。本章描述挂载如何取得视口、窗口测量与稳定等待如何工作、Ebox 与 ETAF 两层的 refit 接口、视口单位，以及应用用来为窗格而非整个缓冲区布局的嵌套视口区域。[渲染模型](rendering-model.md)定义其中的像素与行，[Runtime](runtime.md)描述挂载生命周期，[样式属性参考](style-properties.md)定义读取视口的 `vw` 与 `vh` 单位。

## 挂载的视口

<!-- index: 视口; 挂载视口; 固定视口; 窗口测量 -->

视口是一对宽度（像素）与高度（行）。调用方传入 `:width` 与 `:height` 时，`ebox-mount` 固定视口；否则挂载测量显示它缓冲区的窗口，树于是填满它被打开的编辑区。批处理会话没有窗口高度，所以测得的高度可能是不确定的：此时以视口高为单位表达的块尺寸按内容而定，而不是按屏幕。测得的宽度依次回退到后备视口变量，最后是 80 列的默认值。

#### Function: ebox-mount-viewport (&optional buffer-or-name)

返回 BUFFER-OR-NAME 已挂载视口的 （WIDTH . HEIGHT），没有则 nil。

**参数。** BUFFER-OR-NAME 命名一个已挂载的 Ebox 缓冲区，默认当前缓冲区。

**语义。** WIDTH 是像素，HEIGHT 是行。没有固定视口时，尺寸跟随显示该缓冲区的窗口，批处理会话也一样。HEIGHT 不确定时为 nil，依赖高度的单位因此按内容而定；固定挂载则精确报告挂载时的值。

**返回。** 该 cons；缓冲区没有挂载时返回 nil。

**错误。** 无。读取未挂载的缓冲区是 nil 结果，不是错误。

**参见。** `ebox-mount-set-viewport`、`ebox-viewport-measure`。

#### Function: ebox-mount-set-viewport (buffer-or-name width height)

为 BUFFER-OR-NAME 的挂载按 WIDTH×HEIGHT 视口布局。

**参数。** WIDTH 是像素，HEIGHT 是行；任一为 nil 表示该维度跟随显示窗口。

**语义。** 固定值存到挂载上并立即 refit。两次都传 nil 会解除固定视口，两个维度重新跟随显示。真正改变尺寸的 refit 在布局稳定后运行 `ebox-viewport-change-functions`。

**返回。** refit 的结果：布局变化时为非 nil；缓冲区没有挂载时为 nil。

**参见。** `ebox-mount-viewport`、`ebox-refit`。

## 窗口测量与稳定

<!-- index: 窗口宽度; 测量优先级; 稳定延迟; 临时占用 -->

两个细节决定测得的视口是否正确。第一是窗口 body 与实际可提供的像素之差：fringe、滚动条、margin 与截断列都占布局不能使用的空间。第二是时机：拖动 frame 产生的尺寸事件比一次重排更快，Ebox 因此只安排一次尾部重排，而不是每个事件重排一次，并且区分真实缩放与临时 UI 借走的行。

#### Function: ebox-viewport-window-width (window)

返回 WINDOW 提供给已挂载树的像素宽。

**参数。** WINDOW 是活动窗口；其它值返回 nil。

**语义。** 宽度是窗口外框像素宽减去 fringe、滚动条与 margin。当 body 宽与该计算相差超过一个小的字符宽容差时，以 body 宽为准。没有右 fringe 的窗口再减一列，因为 Emacs 把最后一列文本列留给截断字形；图形 frame 上再减一个像素，以免整行被截断。

**返回。** 可用像素宽。

**错误。** 无。

**参见。** `ebox-viewport-measure`、`ebox-mount-viewport`。

#### Function: ebox-viewport-measure (buffer-or-name &optional width height)

返回 BUFFER-OR-NAME 的挂载现在会使用的 （WIDTH . HEIGHT） 视口，无论是否已挂载。

**参数。** WIDTH 与 HEIGHT 是显式覆盖值；任一可为 nil。

**语义。** 优先级为：显式参数、`ebox-viewport-width` 与 `ebox-viewport-height` 变量、显示该缓冲区的窗口、后备默认值。缓冲区不必已挂载：在挂载前先计算内容的层可以用它把内容定到挂载将要取得的视口。传入未知缓冲区时回退到当前缓冲区的窗口。

**返回。** 像素与行的 cons；高度不确定时可为 nil。

**错误。** 无。

**参见。** `ebox-mount-viewport`、`ebox-viewport-width`、`ebox-viewport-height`。

#### Variable: ebox-viewport-settle-delay

最后一次尺寸变化后 Ebox 重排前所需的静默秒数。

**语义。** 窗口尺寸事件与缓冲区变化被记录为意图，按 frame 去重，由单个任务等待这段延迟；每个新事件重新计时。延迟期间没有新事件时，该 frame 中显示的挂载才被 refit。默认 0.12 秒让拖动 frame 保持响应：中间尺寸永远不布局。

**示例。** 图形 frame 从 80 列 34 行缩到 70 列 18 行，resize 刚结束时视口仍是旧值；半秒后视口为 490 像素乘 16 行，每列 7 像素，视口变化钩子恰好运行一次。

**参见。** `ebox-viewport-change-functions`、`ebox-refit`。

临时 UI 不算缩放。活跃的 minibuffer、补全弹窗或 echo area 消息从显示窗口借走行时，frame 本身没变；挂载保持已提交的视口，直到这些 UI 归还这些行，minibuffer 退出时会再安排一次检查。frame 变化或窗口变高是真实几何，照常 refit。

### Buffer 文本缩放

<!-- index: 文本缩放; 滚轮缩放; 度量刷新 -->

更改 buffer 的 text scale 会改变每个已测量字形所用的字号度量，但不产生 window-size notification，尺寸桥接因此听不到它。Ebox 把被缩放的 mounted buffer 当作一种独立的 viewport intent：`text-scale-mode-hook` 记录该缓冲区，等待与窗口缩放相同的稳定延迟，整批只清空一次共享字形缓存，然后整棵重新布局。测得的宽度、行高与内在尺寸于是跟随缓冲区的新 face，对已挂载应用做滚轮缩放会画出对齐的行，而不是按上一档度量切开。连续缩放会合并成一次重排，缩回默认大小也同样重排一次。

挂载之外的渲染读同一套测量上下文：`ebox-render` 按当前缓冲区的 face 测量。应用预先生成的像素图像不随字体放大：图像提供者读取有效度量，按新行高重新切分像素。这样既保持图形的固有尺寸，也不会在条带之间留下空隙。

#### Function: ebox-display-metrics (&optional buffer-or-name)

返回描述 BUFFER-OR-NAME 有效默认 face 度量的新 plist。

**参数。** BUFFER-OR-NAME 默认当前缓冲区。显示它的 frame 提供基准字体；隐藏缓冲区使用选中 frame。

**语义。** `:char-width` 和 `:line-height` 是正数像素尺寸，`:ascent` 是对齐基线所需的图像 ascent 百分比。度量包含缓冲区局部文本缩放。文本显示返回单位格子和 100% ascent。结果归调用方所有，修改它不会影响之后的读取。

**错误。** 缓冲区不存在时触发 error→ `error`。

**示例。** `(plist-get (ebox-display-metrics) :line-height)` 给出原生图像提供者的一条图像条带的逻辑高度。

#### Hook: ebox-display-change-functions

报告显示度量已稳定的挂载缓冲区。

**语义。** 每个函数接收已重新测量保留树的挂载缓冲区。连续文本缩放共享视口的稳定延迟。回调读取 `ebox-display-metrics`，重新生成外部准备的图像行；挂载与应用状态不重建。已释放的挂载不再收到通知。固定尺寸视口也会运行此钩子；视口尺寸钩子则只报告尺寸变化。

#### Function: etaf-display-metrics (&optional runtime)

响应式地读取已挂载 Runtime 的有效默认 face 度量。

**参数。** RUNTIME 默认为活动组件的 Runtime 或当前缓冲区的 Runtime。

**语义。** 返回新的 plist，键与 `ebox-display-metrics` 一样，包含 `:char-width`、`:line-height` 和 `:ascent`。读取它的渲染、computed 或 effect 会在缓冲区文本缩放稳定后重新运行，即使视口尺寸固定也如此。ETAF 把度量与视口变化放在同一个响应式 batch 中发布，原生图像提供者可调整图像行而不重建组件或重置状态。

**错误。** 缺少 Runtime 或 Runtime 未挂载时触发 error→ `etaf-runtime-error`。

**示例。** `(etaf-computed (lambda () (plist-get (etaf-display-metrics) :line-height)))` 为生成图像的应用跟踪行高。

## 两层的 refit

<!-- index: refit; 重排; 固定视口; 自适应视口 -->

refit 是一次操作、一个结果：测量视口，与已提交值不同时更新它，并只重排依赖它的部分。在 Ebox 里，这意味着宽度变化时或块尺寸跟随容器高度时的根，以及变化轴上声明了 `vw`、`vh` 单位的每个节点。在 ETAF 里，refit 是一次 Runtime 操作：挂载 observer 与性能记录会看到 kind `refit`，布局变化时修订号前进。

#### Function: ebox-refit (&optional buffer-or-name)

在视口尺寸变化时重排 BUFFER-OR-NAME 的挂载。

**参数。** BUFFER-OR-NAME 命名已挂载的 Ebox 缓冲区，默认当前缓冲区。

**语义。** 重新测量视口；尺寸未变化时直接返回 nil，不触碰布局。尺寸变化时更新挂载视口，标记读取变化轴的节点，flush 重排，并运行 `ebox-viewport-change-functions`。完整显示整个缓冲区的窗口会回到顶部，因此临时 UI 借行期间滚动过的树会回到原位。

**返回。** 布局变化时为非 nil。

**错误。** 无。

**参见。** `ebox-mount-set-viewport`、`ebox-viewport-change-functions`。

#### Function: etaf-runtime-refit (runtime viewport-width &optional viewport-height)

把已挂载的 RUNTIME 重设为 VIEWPORT-WIDTH 像素、VIEWPORT-HEIGHT 行。

**参数。** RUNTIME 是已挂载的 Runtime。VIEWPORT-WIDTH 是像素，VIEWPORT-HEIGHT 是行；任一为 nil 表示该维度跟随显示窗口，所以应用可以固定行数而保持宽度自适应。

**语义。** 固定维度存到 Runtime 上，Ebox 重排挂载。视口单位与依赖视口的布局重新解析，只重写变化的区域。refit 是一次被观测的 Runtime 操作：挂载 observer 与性能记录会收到 kind `refit` 及其 Ebox flush 报告。

**返回。** 布局变化时为非 nil。

**错误。** 未挂载的 Runtime 报 `etaf-runtime-error`；非正尺寸报 `wrong-type-argument`；渲染期间调用报 `etaf-render-side-effect-error`。

**参见。** `etaf-refit`、`etaf-runtime-viewport`、`ebox-mount-set-viewport`。

#### Function: etaf-refit (&optional runtime window)

按显示窗口当前视口尺寸重排已挂载的 Runtime。

**参数。** RUNTIME 默认当前缓冲区的 Runtime，WINDOW 默认显示该缓冲区的窗口。

**语义。** Runtime 的固定视口被解除，窗口当前尺寸成为视口。已挂载的 Runtime 本就通过 Ebox 视口桥跟随窗口缩放，所以这个调用用于桥不覆盖的窗口，例如窗口管理器显示之前就已挂载的缓冲区。

**返回。** 新视口 （WIDTH . HEIGHT）；没有已挂载 Runtime 或没有活动窗口时返回 nil，因此在 window-change 钩子里调用是安全的空操作。

**错误。** 无。

**参见。** `etaf-runtime-refit`、`etaf-runtime-viewport`。

## 视口单位

<!-- index: vw; vh; 后备视口 -->

`vw` 与 `vh` 单位读取视口：一个 `vw` 是视口宽的百分之一，一个 `vh` 是视口高的百分之一。挂载之内，数值来自测得的窗口；挂载之外——用 `ebox-render` 渲染而不是挂载的树——数值来自两个变量。

#### Variable: ebox-viewport-width

挂载外渲染时的视口像素宽，或 nil。

**语义。** 设置后，该值就是挂载外渲染的视口宽，也是显示可用之前的后备值。为 nil 时，图形会话测量当前窗口，批处理会话用 80 列。设置它不会缩放任何挂载，只提供单位与测量所依据的数字。

**参见。** `ebox-viewport-height`、`ebox-viewport-measure`。

#### Variable: ebox-viewport-height

挂载外渲染时的视口行高，或 nil。

**语义。** 为 nil 时高度不确定：`vh` 单位无法解析，块尺寸回退到内容，批处理会话中的挂载同样没有视口高度。固定该变量为离屏渲染提供确定高度，用 `ebox-mount-set-viewport` 固定挂载则为已挂载的树提供高度。

**参见。** `ebox-viewport-width`、`ebox-mount-set-viewport`。

```elisp :figure 视口单位跟着挂载走：两个盒子分别占 25 vw 与 50 vw
(etaf-view
 (column :width '(ch 40) :item-gap '(lh 0)
   (box :width '(vw 25) :padding '((lh 0) (ch 1))
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
     (text :color (etaf-theme-token :ui-accent "#0969da") "25 vw"))
   (box :width '(vw 50) :padding '((lh 0) (ch 1))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
     (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "50 vw"))))
```

## 视口区域

<!-- index: 视口区域; 嵌套视口; 窗格 -->

应用常常要为更大挂载内部的窗格布局：侧栏、编辑区、仪表盘里的面板。视口区域把自身已提交的盒子发布给下方每个 Component 作为视口，同一份应用代码因此无论填满整个缓冲区还是一个窗格，读到的都是同一个响应式视口。

#### Function: etaf-viewport ()

以 （PIXELS . ROWS） 返回当前 Component 子树的视口。

**语义。** 在 `etaf-viewport-region` 内部，值是区域的已提交尺寸；其它位置是已挂载 Runtime 的视口，即 `etaf-runtime-viewport` 读到的值。区域在首次 flush 提交几何之前读到 nil，所以那一刻渲染的 Component 必须容忍 nil。该值是响应式的：读取它的 render、effect 或 computed 会在区域或 Runtime 视口变化后重跑。

**返回。** 视口 （PIXELS . ROWS）；区域首次提交之前为 nil。

**参见。** `etaf-viewport-region`、`etaf-runtime-viewport`。

#### Component: etaf-viewport-region ()

把内容包进一个嵌套视口区域。

**语义。** 区域填满父级给它的空间，并把已提交的盒子发布为下方每个 Component 的视口。调用点传入的 Host 属性（`:class`、`:width`、`:height` 及其它 Host 属性）覆盖区域自身的默认值。区域沿 Component 祖先链解析，而不是沿继承的 Context，因为经 slot 传入的内容在调用点编译。不要给区域加 padding 或边框：它的边框盒就是发布的视口，内缩要在区域内部做。

**返回。** 与任何 Component 一样返回一个 View 节点。

**错误。** 在已挂载的 Component setup 之外使用区域会报错。

**示例。** 60×12 的 column 里放一个 40×3 的区域，区域内组件读到 `(40 . 3)`，区域外组件读到挂载的视口，直到 refit 改变挂载。

**参见。** `etaf-viewport`、`etaf-runtime-viewport`。

#### Function: etaf-runtime-viewport (&optional runtime)

以 （WIDTH . HEIGHT）（像素与行）返回已挂载 RUNTIME 的视口。

**语义。** 值就是挂载测得的视口，与渲染器布局所依据的数字完全相同。读取是响应式的：读取它的 render、computed 或 effect 会在视口变化后重跑，所以 Component 可以按挂载尺寸自我定尺。树挂载之前的首次渲染也能拿到挂载即将取得的视口，初次渲染因此尺寸正确。

**返回。** 视口 cons。

**错误。** 未挂载的 Runtime 报 `etaf-runtime-error`。

**参见。** `etaf-viewport`、`etaf-runtime-refit`。

#### Function: etaf-runtime-window-viewport (&optional runtime)

把 RUNTIME 的显示窗口视口作为 (WIDTH . HEIGHT) 返回。

**语义。** WIDTH 是窗口提供给挂载树的宽度：图形 frame 上是像素，文本终端上是字符格。HEIGHT 是它的主体行数。RUNTIME 默认为当前缓冲区的 Runtime。这是一次普通快照，不是响应式读取；需要在窗口变化时重排的组件应读 `etaf-runtime-viewport`，它由视口变化结算后更新。显示面需要匹配窗口几何、而不是排版出的文本视口时，用这个入口；浮层在两种显示上都靠它居中并限制尺寸。

**返回。** 窗口视口 cons；没有窗口显示 RUNTIME 的缓冲区时返回 nil。

**错误。** 未挂载的 Runtime 报 `etaf-runtime-error`。

**参见。** `etaf-runtime-viewport`、`etaf-runtime-refit`。

## 视口变化钩子

<!-- index: 视口变化钩子; 稳定尺寸 -->

#### Hook: ebox-viewport-change-functions

视口尺寸变化后，在已挂载缓冲区上运行的异常钩子，窗口 resize 或 `ebox-mount-set-viewport` 触发的都算。

**语义。** 它在新尺寸的重排稳定后运行一次，所以钩子内读 `ebox-mount-viewport` 会得到新尺寸，而且缓冲区已显示新布局。ETAF 用它更新 Runtime 的响应式视口 cell，`etaf-viewport` 的读者随之重跑；应用也可以用它做一些必须发生在渲染之外的自适应工作。

**返回。** 钩子的返回值被忽略。

**错误。** 其中一个函数报错不会阻止其它函数。

**参见。** `ebox-mount-viewport`、`ebox-viewport-settle-delay`。

#### Hook: ebox-display-window-change-functions

窗口变化稳定后，以已挂载缓冲区和它的显示窗口为参数运行的异常钩子。

**语义。** 视口任务在 refit 该缓冲区的挂载之后运行它，条件是这个窗口刚成为缓冲区的显示窗口，或者它的正文像素尺寸自上次为该缓冲区运行以来变了。固定视口让布局保持不变时它照样运行，这正是它与 `ebox-viewport-change-functions` 的区别：跟随窗口而不是跟随挂载画布的状态（页大小、行预算、调用方自己固定的画布高度）在这里重新适配。minibuffer、补全弹窗或回显区借走行时，窗口变矮不算变化，钩子不运行；变高和 frame 缩放是真实几何，会运行。

**返回。** 钩子的返回值被忽略。

**错误。** 出错会中止该 frame 这一批的剩余工作，视口任务在这一批结束后报告错误。

**参见。** `ebox-viewport-change-functions`、`ebox-viewport-settle-delay`。

#### Function: etaf-canvas-cell (&optional runtime)

返回画布绘制时用的格子，单位是像素，形式为 （CHAR-WIDTH . LINE-HEIGHT）。

**参数。** RUNTIME 默认为当前缓冲区里的画布。

**返回。** 一个 cons，两个值都不小于 1。

**语义。** 已挂载的画布回答它真正用来绘制的格子；未挂载的画布只能按 frame 的默认 face 回答，那是挂载前唯一剩下的测量。把布局按格子换算的渲染因此不会在挂载前后量出两种字号。

**参见。** `etaf-canvas-columns`、`etaf-display-metrics`。

#### Function: etaf-canvas-columns (&optional runtime)

返回 RUNTIME 的画布视口有多少个完整格子宽。

**参数。** RUNTIME 默认为当前缓冲区里的画布。

**返回。** 不小于 1 的整数列数。

**语义。** 这是一次响应式读取：按它安排布局的渲染会在视口或格子变化时重跑。视口还没有像素宽时按一个格子回答，所以首帧不会除以零。

**参见。** `etaf-canvas-cell`、`etaf-fit-columns`、`etaf-runtime-viewport`。

#### Function: etaf-fit-columns (available preferred minimum &optional gap)

返回一份把 AVAILABLE 个画布格子排成多列的布局 plist。

**参数。** 每个条目想要 PREFERRED 个格子，最少保留 MINIMUM 个；GAP 是条目之间的格子数，默认 3。

**返回。** `(:across ACROSS :item ITEM :offset OFFSET)`，ACROSS 是一行放几个，ITEM 是每个的宽度，OFFSET 是留在一侧的格子数，让余量对称。

**语义。** 只有每个条目都还能保住 MINIMUM 时才加列，所以宽画布会多一列而不是空出一侧；比一个 PREFERRED 还窄的画布保留整个条目，不为了凑满而缩它。

**参见。** `etaf-canvas-columns`、`etaf-canvas-cell`。

## 错误与恢复

<!-- index: 视口错误; 高度不确定; 首次 flush -->

对未挂载缓冲区设置视口是空操作而不是错误，读取则返回 nil；为已卸载的缓冲区触发的钩子要记得这一点。ETAF 的 refit 接口更严格：未挂载的 Runtime 报 `etaf-runtime-error`，非正尺寸报 `wrong-type-argument`，渲染期间调用报 `etaf-render-side-effect-error`；而没有窗口可测时 `etaf-refit` 返回 nil，因此在窗口钩子里是安全的。

高度不确定是唯一看起来像失败、实际不是的视口值：批处理会话没有窗口，所以 `vh` 单位与跟随视口的块尺寸回退到内容。当这确实有影响时——断言全屏布局的测试，或离屏渲染——用 `ebox-mount-set-viewport` 或 `ebox-viewport-height` 固定高度，单位就会重新可解析。

区域在首次 flush 提交几何之前读到 nil。因此渲染时读取 `etaf-viewport` 的 Component 在区域内的第一遍可能看到 nil；处理 nil 分支或渲染占位内容即可，响应式更新会在区域布局完成后补上真实尺寸。
