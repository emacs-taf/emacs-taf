# 拖拽与手势

直接操作——移动面板、缩放分栏、拖动滑块——与按钮按压建立在同一套事件机制上。Host 声明 `:on-drag`；Ebox 跟踪主键并逐阶段送出手势；ETAF 为每个阶段各开一次响应式批处理。框架在此之上加了两样应用不该自己重建的东西：每个指针手势的键盘等价操作，以及把手势位移变成调用者所有几何的 Behavior。本章把整个手势契约讲完：阶段与载荷、拖拽锁定、供应用自己滚动用的边缘意图、键盘路径、受控几何 Behavior 与随框架附带的缩放示例。[事件](events.md#property-on-drag)定义 `:on-drag` 属性及其载荷，[Host](hosts.md#property-drag-lock-modifier)定义锁定修饰键，[Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)定义 `etaf-draggable`、`etaf-resizable` 与它们的受控版本。

## 手势阶段与载荷

<!-- index: 手势; 拖拽阶段; 拖拽载荷 -->

一次拖拽是一串阶段，全部交给同一个处理器。主键按下时 Ebox 决定拥有者——指针下最近的 keymap 拥有者——并为整个手势保留这个目标，因此移出 Host 不会把拖拽交给指针现在下方的东西。每个阶段以一个 plist 到达，含阶段符号（`start`、`move`、`end`、`cancel` 或 `edge`）、原始事件、节点、窗口与 buffer、文本区像素的起始与当前位置、相对起始的位移、指针越出文本区的距离、取消原因，以及由按键合成的手势上的 `:keyboard` 标志。`edge` 阶段另带 `:edges`，即指针贴住或越过的窗口边缘，以及 `:elapsed`，即距上一个 `edge` 阶段的秒数。每个阶段各自一次响应式批处理，并在读取下一个指针事件前发布，因此写入响应式坐标的处理器在下一阶段看到的是自己已提交的布局，而不是慢一帧。

手势以两种方式之一结束。释放落 `end`，不论指针在哪里；目标变得不可用（被移除、隐藏或禁用），或者被 Escape、其他输入或错误中止的手势以 `cancel` 结束，`:reason` 是 `target-unavailable`、`quit`、`input` 或 `error`。Escape 在取消时被消费，其他输入留给 Emacs。处理器应把 `cancel` 当作「把乐观改动还原」，随附示例正是这么做的。

按住按键时指针可以离开文本区，移到 mode line、别的窗口或 frame 之外，手势会继续跟踪它。`:position` 停在文本区内离指针最近的点，所以 `:delta` 不会描述窗口显示不了的位置；`:overshoot` 以像素给出指针越出文本区的 `(DX . DY)` 距离：向左、向上为负，向右、向下为正，在文本区内为 `(0 . 0)`。在那里释放照常以 `end` 结束手势。

窗口系统可能丢失按键释放；在 macOS 上，这多发生在提示框正在显示或隐藏的时候。因此 Ebox 跟踪手势期间会隐藏已显示或待显示的提示框，并抑制 help echo；未锁定的手势进行中再次按下主键时，Ebox 把这次按下当作丢失的释放：手势在最后位置以 `end` 结束，这次按下随后照常作为新的按下处理。指针位置要读 `:position`，不要读 `:event`：原生拖拽或释放事件的起点是按下的位置，由新按下推断出的 `end` 所带的事件就是那次按下。

## 拖拽锁定

<!-- index: 拖拽锁定; 点击后拖拽 -->

`:drag-lock-modifier` 让手势跨过按键释放继续存活。手势开始时按住该修饰键时，释放按钮不会结束手势：它继续跟踪指针（此时没有按住的按钮），直到下一次主键按下结束它，或 Escape 取消它。点击后拖拽因此合成一个手势，缩放把手在快速点击之后仍然跟着指针，就是这样实现的。修饰键与 `:on-drag` 一起声明在 Host 上，没有拖拽处理器的锁定修饰键在 Host 提交时被拒绝。随附示例用 `shift`，让这个行为可见且需要主动选择。

## 边缘意图与滚动

<!-- index: 边缘意图; 自动滚动; 拖拽边缘 -->

把内容拖到表格、列表或画布的可见边缘之外，是人够到屏幕外内容的方式。引擎报告这个意图；视口归应用所有，滚什么、滚多远由应用决定。

`:drag-edge` 非 nil 的 Host 在拖拽停在或越过窗口边缘带时收到额外的 `edge` 阶段。手势必须已经从按压点移动过；只在边缘按住不动不会报告。第一个阶段在一个 `ebox-drag-edge-interval` 之后到达，之后只要指针停在内侧边缘 `ebox-drag-edge-band` 行或列的范围内，或者越过了这条边，就按这个节奏重复。`:edges` 按固定顺序 `left`、`right`、`top`、`bottom` 给出贴住或越过的边缘；角落会同时给出两个。指针退回窗口内部或手势结束，都会停止这些阶段。`:elapsed` 是距上一个 `edge` 阶段开始的实际秒数，第一个阶段则从指针到达边缘带算起；处理器和随后的发布比间隔慢时，它会大于间隔。配合 `:overshoot`，处理器可以按距离和时间滚动：指针越远滚得越快，速度也不受一次重绘耗时的影响。

引擎不滚动。`:position` 与 `:delta` 只描述指针，因此用 `ebox-node-set-scroll` 或 `etaf-scroll-by` 滚动 Ebox 滚动器时，处理器要把滚过的行与列加到自己应用的位移上，内容锚定的对象才会留在指针下。模型驱动的视口（例如靠改变首个可见行来滚动的表格）在同一个处理器里推进自己的状态。

```elisp
(box :drag-edge t
     :on-drag
     (lambda (gesture)
       (pcase (plist-get gesture :phase)
         ('edge
          (when (memq 'bottom (plist-get gesture :edges))
            ;; 指针越过边缘越远滚得越快；按经过的时间滚动，重绘再慢速度也不变。
            ;; move 分支会把滚过的行加到位移里，内容因此留在指针下。
            (let* ((past (max 0 (cdr (plist-get gesture :overshoot))))
                   (rows-per-second (+ 8 (/ past 4.0)))
                   (rows (max 1 (round (* rows-per-second
                                          (plist-get gesture :elapsed))))))
              (etaf-scroll-by (etaf-current-runtime) 'list rows))))
         ((or 'move 'end) (move-content (plist-get gesture :delta))))))
```

#### Variable: ebox-drag-edge-band

拖拽报告边缘意图时，距窗口边缘的行数与列数。

**语义。** 默认是 1，也就是显示窗口的最后一行与最后一列会报告意图；每个轴按 frame 的字符高与字符宽换算。更大的值会同时加宽两个轴上的边缘带；指针越过边缘、到了窗口外面，也算在边缘带里。手势开始时读取该值。

**参见。** `ebox-drag-edge-interval`、`:drag-edge`。

#### Variable: ebox-drag-edge-interval

拖拽停在或越过边缘带期间，两次 `edge` 手势之间的秒数。

**语义。** 默认是 0.12。指针到达边缘带满一个间隔后送出第一个 `edge` 阶段，之后按这个节奏重复；`:elapsed` 报告实际观察到的间隔，处理器比间隔慢时它会变大。处理器把节奏映射成自己视口的滚动步长。手势开始时读取该值。

**参见。** `ebox-drag-edge-band`、`:drag-edge`。

## 键盘等价操作

<!-- index: 键盘拖拽; 拖拽步进 -->

每个指针手势都有键盘路径，而且由框架提供，而不是让每个应用自己发明按键。内置 Behavior 贡献各自的箭头绑定，见 [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)：可拖拽 Host 用 `M-<方向>` 沿它的轴移动，可缩放 Host 按它的边缘用 `M-S-<方向>` 放大缩小。聚焦且带 `:on-drag` 的 `separator` 或 `slider` 通过 `etaf-direction` 用普通方向键步进，见[键盘](keyboard.md#方向)。应用自己的命令则有一个说同一种手势语言的入口。

#### Function: etaf-drag-step (runtime host-ref columns rows)

从键盘把已挂载 RUNTIME 中的 HOST-REF 按 COLUMNS 与 ROWS 拖拽，并返回 HOST-REF。

**参数。** COLUMNS 与 ROWS 是数字；可以为小数以做亚格移动。RUNTIME 必须已挂载，HOST-REF 必须指向带拖拽处理器的已提交 Host。

**语义。** 该调用恰好派发两个手势：位移为零的 `start` 与紧接着带位移的 `end`，因此所有对指针有效的处理器——包括可拖拽、可缩放 Behavior 与受控版本——无需特例就能从键盘工作。位移使用指针手势的单位：COLUMNS 个字符宽与 ROWS 行高，以像素计，按显示该 buffer 的窗口所在 frame 度量。手势带 `:keyboard` t，与指针输入区分；关心来源的应用也可以在事件层面查 `etaf-event-pointer-p`。由于只送 `start` 与 `end`，处理器看到一个起点与一个终点，括住手势的 `on-start`/`on-end` 回调照常运行。

**返回。** HOST-REF。

**错误。** 参数不是数字时报 `error→ etaf-event-error`，消息 `"Drag step COLUMNS and ROWS must be numbers"`；HOST-REF 未挂载时报 `"No committed Host reference"`；处理器自身的错误照常传播；渲染期调用报 `error→ etaf-render-side-effect-error`。

**示例。** `(etaf-drag-step runtime 'handle 1 0)`

**参见。** `:on-drag`、`etaf-draggable`、`etaf-resizable`、`etaf-direction`。

## 受控几何

<!-- index: 受控几何; 聚合状态; 缩放边缘 -->

内置 Behavior 覆盖每个坐标各自一个 ref 的常见情况。把几何当作一个聚合值的应用——管理器状态里的普通 alist、窗口控制器拥有的记录——改用*受控*版本。它们的形状相同：Behavior 消费 `:on-drag`，通过可选的 `:delta` 函数把像素位移换算成应用单位，再用下一份几何回调应用；应用始终是唯一持久权威，Behavior 在手势期间最多保留一份临时起点。`cancel` 时不写入任何东西并丢弃起点，因此被中止的手势不会留下更新到一半的记录。

`etaf-draggable-controlled` 读取几何 plist，推断或接收轴，并把移动后的坐标经 `on-change` 写回；`etaf-resizable-controlled` 读取 `:x`、`:y`、`:width`、`:height`，沿声明的 `:edges` 缩放，按声明的最小/最大值 clamp，并在左边缘或上边缘移动时移动原点，让对边保持不动。[Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)定义它们的参数、校验与错误条件，包括移动与缩放处理器必须放在不同 Host 上这条规则：一个 Host 的每个 `:on-drag` 处理器都会收到每个手势。

键盘绑定随它们一起到来：受控可拖拽按它的轴贡献移动键，受控可缩放按它的边缘贡献放大缩小键，因此无论应用存四个 ref 还是一条记录，键盘路径都在。

## 保留式缩放示例

<!-- index: 保留式缩放; 可运行示例 -->

框架附带一个应用形态的示例，让整条路径——原生手势、受控几何、响应式发布与键盘取消——不必先写应用就能演练。它是一个普通的已挂载 Runtime，不是特殊模式：面板是一个绝对定位的普通 Host，带受控可缩放 Behavior，旁边的对等控件是独立、可聚焦的控件。

#### Function: etaf-retained-resize-open (&optional buffer-or-name)

挂载一个固定文本的缩放示例，返回 BUFFER-OR-NAME（默认 `*ETAF Retained Resize*`）。

**参数。** BUFFER-OR-NAME 是要挂载进的 buffer 名；默认 `*ETAF Retained Resize*`。

**语义。** buffer 被挂载一个通过受控可缩放 Behavior 上报几何的面板：拖拽缩放它的右边与下边，Shift 在按键释放后锁定手势，因此再按一次才结束它，Escape 取消锁定的手势并把尺寸还原到手势开始时的值。面板的正文是被盒子裁剪的固定文本，有意不做窗口边框或段落重排引擎；旁边的对等控件在面板缩放期间保持独立可聚焦、可激活。用同一个 buffer 重开会替换已有挂载；示例拒绝接管不是它创建的非空 buffer。示例不实现组件目录的窗口边框或文本重排。

**返回。** buffer。

**错误。** buffer 有不是示例挂载的内容时报 `error→ user-error`，消息 `"Refusing to replace unrelated contents in %s"`；挂载错误照常传播。

**示例。** `(etaf-retained-resize-open)`

**参见。** `etaf-resizable-controlled`、`etaf-drag-step`、[焦点](focus.md)。

## 错误与恢复

<!-- index: 手势错误; 取消 -->

手势失败遵循阶段模型。处理器报错会让手势以 `cancel` 结束，`:reason` 为 `error`，错误在该阶段的批处理排空后传播，剩余阶段不再运行。目标在手势中途消失会产生终止性的 `cancel`，`:reason` 为 `target-unavailable`，这是框架告诉处理器释放已获取资源的方式。Escape 会让锁定手势与普通手势都产生 `:reason` 为 `quit` 的 `cancel`。受控 Behavior 在每次 `cancel` 时丢弃起点，因此最安全的处理器模式就是示例用的那种：`start` 时记录起始值，`move` 与 `end` 时写入移动后的值，`cancel` 时还原记录。`etaf-drag-step` 先校验参数，报 `etaf-event-error` 而不是合成一个坏手势。
