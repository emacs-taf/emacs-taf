# 事件

交互以事件的形式到达应用。Ebox 决定位置或按键归哪个 Host 所有，并触发 ETAF 为它降级出的 keymap 入口；Runtime 随后在一次响应式事件批里运行一个应用回调。本章定义 Host 事件属性、指针与键盘的激活、显式派发、回调组合与祖先 capture 钩子的顺序、描述进行中事件的查询、派生的 `active` 状态、悬停反馈，以及禁用 Host 在命中测试中的行为。[交互总论](interaction-overview.md)描述各章共用的路径；[Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)定义内置 Behavior 的拖拽与缩放回调，它们不是 Host 事件属性。

## 事件属性

<!-- index: 事件属性; :on-press; capture; 拖拽手势; swipe; dismiss -->

Host 为每种事件种类声明一个回调，属性名为 `:on-KIND`，其中 KIND 是小写词以连字符连接，例如 `:on-press` 里的 `press`。值必须是函数或 nil；其他值在 Host 提交时报 `error→ etaf-renderer-error`。值为 nil 表示声明了该属性却不处理事件，在下面的合并规则里这仍算一次声明。

有一种回调没有 Host 属性：拖拽手势以 `:on-start`、`:on-move`、`:on-end`、`:on-cancel`、`:on-resize`、`:on-change` 六种属性到达拖拽与缩放 Behavior，见 [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)。`:on-direction` 是键盘属性，属于[键盘](keyboard.md)；`:on-leave` 是[文本输入](text-input.md)章的输入会话选项。下面的属性是 ETAF Runtime 的事件回调。

#### Property: :on-press

激活 Host 的回调。

**参数。** 无参函数；事件带载荷派发时收一个参数的函数；或 nil。

**语义。** Host 上的主键点击、RET 或 SPC（point 或焦点处是它的 keymap）以及 `etaf-dispatch-event` 都会运行它。只声明 `:on-press` 的 Host 默认得到 `hand` 指针，它的 Ebox keymap 占用主键序列，因此有移动的按压会被跟踪，没有移动的按压在释放时照样激活。普通 press 回调不冒泡：祖先只能通过 [`:on-press-capture`](#property-on-press-capture) 观察后代的按压。禁用的 Host 不运行回调，按压停在禁用 Host 处，不会到达祖先。根 Host 的 press 覆盖它自己不可交互表面上的按压，因为在那里根就是最近的 keymap 拥有者。

**返回。** Runtime 从 `etaf-dispatch-event` 保留回调的返回值；原生激活丢弃它。

**错误。** 回调错误在该事件的批处理排空后从派发处传播；组合在失败回调之后的回调不再运行，错误也会中止祖先 capture 轮。

**示例。** `(text :role 'button :tab-index 0 :on-press #'retry "Retry")`

**参见。** `etaf-activate`、`etaf-dispatch-event`、`:on-press-capture`。

#### Property: :on-press-capture

用于观察落在 Host 内部的按压的祖先钩子。

**参数。** 无参函数；事件带载荷时收一个参数的函数；或 nil。

**语义。** 被按 Host 自己的回调成功返回后，ETAF 从最近的已提交祖先向外运行祖先们的 capture 回调。被按 Host 自己不是祖先，因此 Host 自己的 capture 不会为它自己的按压运行。capture 回调内 `etaf-event-target-within-p` 比较的是被按的 Host 而不是回调的 Host，外壳因此能区分落在打开面板内部的按压与落在它周围表面上的按压；`etaf-event-pointer-p` 仍然描述启动该事件的输入。每次 press 派发只跑一轮 capture：capture 回调里再派发的 press 不会再开一轮。目标回调报错时 capture 轮完全不运行。

**返回。** capture 回调的返回值被丢弃；`etaf-dispatch-event` 返回的是被按 Host 的返回值。

**错误。** capture 回调里的错误在批处理排空后传播，并停止其余 capture 回调。

**示例。** `(column :on-press-capture (lambda () (when (etaf-event-target-within-p 'popover) (close-popover))) ...)`

**参见。** `:on-press`、`etaf-event-target-within-p`。

#### Property: :on-drag

逐阶段接收指针拖拽手势的回调。

**参数。** 收一个参数（手势 plist）的函数，或 nil。

**语义。** Ebox 在 Host 上跟踪主键，每个阶段调用处理器一次，plist 含 `:phase`（`start`、`move`、`end`、`cancel` 或 `edge`）、`:event`（原始鼠标事件）、`:window`、`:buffer`、`:start` 与 `:position`（文本区像素 cons）、`:delta`（相对 `:start` 的位移）、`:overshoot`（指针越出文本区的距离，此时 `:position` 停在文本区内）、取消时的 `:reason`，以及手势来自 `etaf-drag-step` 而非指针时的 `:keyboard`。`edge` 阶段另外带 `:edges`，即指针贴住或越过的窗口边缘，以及 `:elapsed`，即距上一个 `edge` 阶段的秒数。每个阶段各自一次响应式事件批，并在读取下一个指针事件前发布，因此拖拽处理器看到的是每个已提交位置。Ebox 拥有目标保留与跟踪循环：变成禁用的已保留 Host 收到一次终止性的 `cancel`，被移除或卸载的 Host 不再收到任何东西。Host 同时声明 `:on-press` 与 `:on-drag` 时，press 负责键盘激活，拖拽占用主键序列。`:reason` 取值是 `input`、`quit`、`error` 与 `target-unavailable` 之一；离开窗口不会取消手势，在任何地方释放都会结束手势；Escape 以 `quit` 取消并被消费。`:drag-lock-modifier` 可以让手势跨过按键释放继续存活，`:drag-edge` 增加 `edge` 阶段，为应用自己拥有的滚动报告意图；见它们的 [Host 条目](hosts.md#property-drag-lock-modifier)与[拖拽与手势](dragging-and-gestures.md#边缘意图与滚动)。

**返回。** 返回值被忽略。

**错误。** 处理器错误在该阶段的批处理排空后传播，并以 `:reason` 为 `error` 的 `cancel` 结束手势。

**示例。** `(box :on-drag (lambda (gesture) (pcase (plist-get gesture :phase) ('start ...) ((or 'move 'end) ...)))) "Drag me")`

**参见。** `etaf-drag-step`、[拖拽与手势](dragging-and-gestures.md)、`etaf-draggable`、`etaf-resizable`。

#### Property: :on-scroll

观察可滚动 Host 偏移变化的回调。

**参数。** 收一个参数（新的行偏移）的函数，或 nil。

**语义。** 滚轮、滚动键、`ebox-node-set-scroll` 或 `etaf-scroll-*` 调用改变 Host 偏移后，Ebox 用 `ebox-node-scroll-offset` 读回的值调用它。历史列表在视口到达顶部时加载更旧的行、在底部加载更新的行，就靠这个回调。内容增长不算滚动：被 `:scroll-anchor end` 钉在末尾的节点跟随新行时不调用处理器。把偏移设成节点已有的值也不算变化，什么都不调用。

**返回。** 返回值被忽略。

**错误。** 处理器错误从改变偏移的调用者传播。

**示例。** `(box :ref 'messages :overflow 'scroll :on-scroll (lambda (offset) (when (zerop offset) (load-older))) ...)`

**参见。** [滚动](scrolling.md)、`ebox-node-scroll-offset`、`etaf-scroll-to`。

#### Property: :on-swipe

接收水平双指手势的回调。

**参数。** 收一个参数（手指方向 `left` 或 `right`）的函数，或 nil。

**语义。** 触控板手势由 buffer 的 swipe 处理识别：指针下最近的、`:on-swipe` 是函数的启用 Host 每次手势恰好收到一次方向，同一手势的后续事件（包括动量）被吸收。更长的停顿或方向反转会开启下一次手势。该回调不会让 Host 变得可激活，也不改变它的指针；它用于返回列表之类的导航。`ebox-swipe-distance` 与 `ebox-swipe-quiet` 调节识别。

**返回。** 返回值被忽略。

**错误。** 处理器错误从送达手势的滚轮事件传播。

**示例。** `(box :on-swipe (lambda (direction) (when (eq direction 'right) (go-back))) (text "Chat"))`

**参见。** 手势模型见[滚动](scrolling.md)、`ebox-wheel-swipe`。

#### Property: :on-dismiss

用 Escape 关闭或取消 Host 的回调。

**参数。** 无参函数或 nil。

**语义。** Escape 运行当前键链里最近的、声明了该回调的启用 Host，并在模态边界停止搜索。对话框、popover 或查看器因此无需自己绑定按键就能关闭，而且不依赖键盘焦点工作，因为键链先跟焦点、再跟 point。禁用的 Host 被跳过，因此内层控件被禁用不会让它背后的对话框变得无法关闭。

**返回。** 返回值被忽略。

**错误。** 处理器错误从运行它的按键传播。

**示例。** `(column :focus-scope 'modal :on-dismiss close-dialog ...)`

**参见。** 模态作用域见 [Host](hosts.md#property-focus-scope)、键层见[键盘](keyboard.md)。

#### Property: :on-help-open

在新一次快捷键帮助打开前准备当前应用作用域。

**参数。** 无参函数或 nil。

**语义。** 结束原生编辑后，`etaf-help` 在当前按键作用域内派发最近启用 Host 的回调，搜索止于模态边界。回调可以暂停应用的持续活动，而不重新绑定框架帮助键。回调的修改发布后才捕获帮助快照。重复打开复用既有帮助，不再次派发；关闭帮助既不派发，也不撤销应用修改。回调须保持 Runtime 挂载，且不能递归打开帮助。

**返回。** 返回值被忽略。

**错误。** 回调的错误或 quit 中止打开并向调用者传播；已接受的应用状态修改保留。后续打开可以重试。

**示例。** `(column :on-help-open (lambda () (etaf-set-value running nil)) ...)`

**参见。** `etaf-help`、`etaf-help-close`、`:focus-scope`。

#### Property: :on-focus-enter

键盘焦点从外部进入 Host 时运行的回调。

**参数。** 无参函数或 nil。

**语义。** 焦点从外部移入的每个 Host 都会运行它，最近优先，每次移动一次；Tab、方向键、按压与 `etaf-focus` 都算。在 Host 的两个后代之间移动焦点不会再次进入它，因为之前的焦点已经在它内部。禁用的 Host 被跳过。用它可以在键盘到达某个区域时激活它，例如抬起窗口或切换侧栏的上下文，让键盘与指针用户看到同一个激活状态。

**返回。** 返回值被忽略。

**错误。** 处理器错误从运行它的焦点操作传播。

**示例。** `(column :on-focus-enter (lambda () (raise-window 'notes)) ...)`

**参见。** `etaf-focus`、`ebox-focus-change-functions`、[焦点](focus.md)。

#### Property: :on-focus-leave

已接受的键盘焦点离开 Host 子树时运行的回调。

**参数。** 无参数函数或 nil。

**语义。** 焦点离开的启用 Host 由近及远接收此回调，随后新进入的 Host 接收 `:on-focus-enter`；共同祖先不接收任一通知。两个阶段共用一个响应式批次，观察的是已经接受的焦点，Tab、方向、按下与 `etaf-focus` 共用此路径。回调重新定向焦点时，停止通知已被取代的目的地。这是焦点移动通知，不是清理钩子；删除或卸载 Host 时使用组件生命周期清理。

**返回。** 忽略返回值。

**错误。** 回调错误从焦点操作传播。

**示例。** `(column :on-focus-leave (lambda () (etaf-set-value active nil)) ...)`

**参见。** `:on-focus-enter`、`etaf-focus` 与[组件生命周期](components.md)。

### 多个来源如何组合

同一个 Host 最多可以从三个地方拿到同一个事件回调：Host 自己的声明、传给 Component 调用的透传属性、以及经 `:use` 附加的 Behavior。它们组合成一个回调：先跑内层声明，再跑外层，并保留第一个回调的返回值——Host 自己的回调，然后是调用者属性由内到外，最后是 Behavior 按声明序。任何回调报错都会停掉它之后的回调。调用者因此可以用自己的观察包裹控件的业务回调而不替换它，库 Behavior 也可以在它旁边添加行为。这条规则所属的合并表见 [Host](hosts.md#值与冲突)。

## 激活

<!-- index: 激活; RET; 指针激活; 交互移动 -->

激活把主键点击或按键变成 Host 的 `press`。Ebox 把 Host 的激活绑定到 RET、return、SPC，以及——Host 没有拖拽手势时——主鼠标键；`etaf-activate` 对焦点 Host 或 point 处的交互边界执行同样的激活。

#### Function: etaf-activate (&optional runtime)

为焦点 Host、或 point 处的交互边界派发 `press`。

**参数。** RUNTIME 是要激活的已挂载 Runtime；nil 表示活动 Runtime 或当前 buffer 的 Runtime。

**语义。** point 在焦点 Host 内部时目标是焦点 Host；否则是 keymap 覆盖 point 的最近 Host，可能是外层的可按压行。激活通过与点击或 RET 相同的处理器、经 `etaf-dispatch-event` 运行，因此 capture 钩子与响应式事件批行为完全一致。键盘与显式激活不产生 `active` 指针状态，只看点击的策略可以用 `etaf-event-pointer-p` 区分两者。

**返回。** press 回调的派发结果。

**错误。** point 处没有可交互 Host、或目标没有 press 处理器时报 `error→ user-error`；Runtime 未挂载时报 `error→ etaf-event-error`；渲染期调用报 `error→ etaf-render-side-effect-error`，数据为 `(dispatch-event)`。

**示例。** `(etaf-activate (etaf-runtime-for-buffer buffer))`

**参见。** `etaf-dispatch-event`、`ebox-activate`。

#### Function: ebox-activate (&optional position noerror)

调用 POSITION 处节点的 RET 绑定，默认 point。

**参数。** POSITION 是 buffer 位置，nil 表示 point。NOERROR 非 nil 时，没有命令就返回 nil 而不是报错。

**语义。** POSITION 为 nil 时，point 停在焦点节点首个画出字符上则用焦点节点，因为那才是用户看到的焦点；否则由 POSITION 处画出的 keymap 作答。被调用的命令是节点的激活入口：对 ETAF Host 就是派发该 Host 的 press；由 `ebox-keymap-create` 创建、不带 ETAF Host 的 keymap 则运行它自己的 `:activate` 回调。

**返回。** 命令的结果；NOERROR 抑制失败时返回 nil。

**错误。** 该处没有可激活的东西且 NOERROR 为 nil 时报 `error→ user-error`，消息为 `"No Ebox RET command at position"`。

**示例。** `(ebox-activate (ebox-node-position button) t)`

**参见。** `ebox-next-interaction`、`etaf-activate`、`ebox-keymap-create`。

#### Function: ebox-next-interaction (&optional count)

把 point 移动到下一个 keymap 拥有者，重复 COUNT 次；返回位置。

**参数。** COUNT 默认为 1。负值向后移动；0 不动 point。

**语义。** 扫描按 buffer 顺序进行，考虑每个拥有 keymap 的节点，跳过 point 处的拥有者。它与焦点移动不同，不查 `:tab-index`，因此访问的正是指针可以激活的那些交互边界，按文档顺序排列。

**返回。** 新的 point；COUNT 为 0 时返回当前 point。

**错误。** 后面不再有 keymap 拥有者时报 `error→ user-error`，消息为 `"No next Ebox interaction"`。

**示例。** `(ebox-next-interaction)`

**参见。** `ebox-previous-interaction`、`ebox-activate`。

#### Function: ebox-previous-interaction (&optional count)

把 point 移动到上一个 keymap 拥有者，重复 COUNT 次；返回位置。

**参数。** COUNT 默认为 1；扫描前会被取负，因此正的 COUNT 向后移动。

**语义。** `ebox-next-interaction` 的反向版本，拥有者选择相同，同样排除 point 处的拥有者。

**返回。** 新的 point；COUNT 为 0 时返回当前 point。

**错误。** 前面不再有 keymap 拥有者时报 `error→ user-error`，消息为 `"No previous Ebox interaction"`。

**示例。** `(ebox-previous-interaction 2)`

**参见。** `ebox-next-interaction`、`ebox-activate`。

```elisp :run
(etaf-define-component demo-event-log ()
  :bindings ((last (etaf-ref "（还没有事件）"))
             (focus (etaf-ref "（无焦点）")))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (row :item-gap '(ch 1)
               (box :role 'button :tab-index 0 :padding '((lh 1) (ch 2))
                    :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") :pointer 'hand
                    :on-focus-enter (lambda () (etaf-set-value focus "按钮 A"))
                    :on-press (lambda () (etaf-set-value last "press：按钮 A"))
                    (text "按钮 A"))
               (box :role 'button :tab-index 0 :padding '((lh 1) (ch 2))
                    :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff") :pointer 'hand
                    :on-focus-enter (lambda () (etaf-set-value focus "按钮 B"))
                    :on-press (lambda () (etaf-set-value last "press：按钮 B"))
                    (text :color (etaf-theme-token :ui-accent "#0969da") "按钮 B")))
          (text :color (etaf-theme-token :ui-muted-fg "#526174") (expr (format "最近事件：%s" (etaf-value last))))
          (text :color (etaf-theme-token :ui-muted-fg "#526174") (expr (format "当前焦点：%s" (etaf-value focus))))))
(etaf-view (demo-event-log))
```

## 程序化派发

<!-- index: 事件派发; 载荷; 事件种类 -->

#### Function: etaf-dispatch-event (runtime host-ref kind &optional payload (payload-p nil))

通过已挂载的 RUNTIME 为 HOST-REF 派发 KIND。

**参数。** RUNTIME 是已挂载的 Runtime。HOST-REF 寻址一个已提交 Host。KIND 是符号、关键字或字符串；`on-` 前缀与包围的标点会被归一掉，因此 `press`、`:press` 与 `"on-press"` 指同一个事件。PAYLOAD-P 非 nil 时 PAYLOAD 作为回调唯一参数传入；否则无论 PAYLOAD 是什么，回调都以无参调用。

**语义。** Runtime 在 Host 已提交属性里查处理器，并在事件上下文与一次响应式事件批里运行它：`etaf-current-runtime` 是该 Runtime，当前事件记录它的种类、Host 与目标，回调的写入在批边界一起发布。press 在目标回调成功后运行祖先 capture 轮，与指针按压完全一样。press 还会先结束活动的原生输入会话，除非被按 Host 就是会话自己的 Host、包含该会话、或是包含它的最内层 Host，因此点击输入框之外会先提交编辑再运行点击回调。测试与集成用显式派发代替指针；原生指针与键盘激活到达同一批回调。

**返回。** 回调返回什么就返回什么。载荷标志不改变它。

**错误。** RUNTIME 未挂载时报 `error→ etaf-runtime-error`，消息 `"ETAF runtime is not mounted"`。KIND 非法、Runtime 不认识该 Host 引用、或该引用没有 KIND 的处理器（`"No KIND handler for Host reference REF"`）、以及派发到禁用 Host（`"Cannot dispatch to disabled Host reference: REF"`）都报 `error→ etaf-event-error`；唯一例外是 Ebox 给目标变禁用的拖拽处理器送去的终止取消。渲染期调用报 `error→ etaf-render-side-effect-error`，数据为 `(dispatch-event)`。

**示例。**

```elisp
(let ((runtime (etaf-runtime-for-buffer "*etaf-status*")))
  (etaf-dispatch-event runtime 'save 'press))
```

**参见。** `etaf-activate`、`etaf-dispatch`、`etaf-current-runtime`。

## 回调顺序

<!-- index: 回调组合; capture 顺序; 短路 -->

一个事件可以运行多个回调，顺序是固定的。在同一个 Host 上，各声明按[多个来源如何组合](#多个来源如何组合)所述的方式组合：Host 自己的回调在前，调用者包装由内到外随后，Behavior 最后按声明序；第一个返回值被保留，任何错误都会中止链。

press 回调成功返回后，祖先 capture 轮从最近的已提交祖先向外运行。不是目标祖先的 Host 永远不会运行。这轮只跑一次，不是每个祖先派发一次；capture 回调里再派发的 press 也不会跑第二轮。目标回调报错时，capture 回调完全不运行。

除此之外什么都不冒泡。落在嵌套控件上的按压不会运行祖先的 `:on-press`，被 Host 处理的按键也不会再运行同一个键的 buffer 命令。capture 钩子的存在正是为了让外壳无需隐式传播就能表达祖先策略，而 `etaf-event-target-within-p` 是这种策略识别目标的方式。

## 事件上下文

<!-- index: 事件上下文; 指针来源; 事件目标 -->

回调运行期间，ETAF 保留进行中的事件，让回调可以询问它。两个查询在事件回调之外调用都会报错，因为那时没有事件可描述。

#### Function: etaf-event-pointer-p ()

当前事件来自指针按钮时返回非 nil。

**参数。** 无。

**语义。** 鼠标或触控板点击激活的 press 返回非 nil；RET 或 SPC 的键盘激活、以及非鼠标输入的显式派发返回 nil。点击背景关闭模态这类只看点击的策略用它，保证同一个回调被按键触发时绝不套用该策略。取值读的是启动这次投递的输入事件，因此键盘送达的拖拽手势要靠它自己的 `:keyboard` 标志识别，而不是这个查询。

**返回。** 指针按钮为非 nil，否则 nil。

**错误。** 回调之外报 `error→ etaf-event-error`，消息 `"Event source lookup requires a Host event callback"`。

**示例。** `(when (etaf-event-pointer-p) (close-on-backdrop-click))`

**参见。** `etaf-event-target-within-p`、`:on-press`。

#### Function: etaf-event-target-within-p (host-ref)

当前事件的目标是 HOST-REF 或在它内部时返回非 nil。

**参数。** HOST-REF 用 `equal` 比较。

**语义。** 在祖先 `:on-press-capture` 回调里，目标是其 press 回调运行过的 Host；其他回调里就是回调自己的 Host。比较会沿目标的已提交 Host 祖先向上走，因此根外壳能区分落在打开面板内部的按压与落在它周围表面上的按压，只在第一种情况下关闭面板。未提交的 Host 引用只是找不到而已。

**返回。** 目标等于 HOST-REF 或在它内部时为非 nil，否则 nil。

**错误。** 回调之外报 `error→ etaf-event-error`，消息 `"Event target lookup requires a Host event callback"`。

**示例。** `(when (etaf-event-target-within-p 'panel) (raise 'panel))`

**参见。** `:on-press-capture`、`:on-press`、`etaf-host-ref-at`。

## active 状态

<!-- index: active 状态; 指针按压; 状态选择器 -->

Ebox 为当前被主键按住的 Host 派生一个 `active` 选择器状态。它不是作者数据：只要那次按压的跟踪循环还活着它就在，循环结束就消失，ETAF 从不保存它。组件样式与样式表用 `&:active` 匹配它，按钮因此无需应用写任何东西就能画出按住的样子。

状态在跟踪开始时出现，在 press 回调运行前清除。声明拖拽手势的 Host 在按压本身就开始跟踪，所以从按下起就是 active。只声明 press 的 Host 也从 press-claim 序列开始跟踪，但状态本身在第一次指针移动时才应用：按下又释放、完全没移动的点击从不显示 `:active`，而轻微移动就会显示。释放时 Ebox 先清除状态再激活 Host，因此回调看到的是基础样式；拖拽处理器的 `end` 阶段仍看到 active 状态，它在跟踪循环退出时才清除。

RET 或 SPC 的键盘激活与显式 `etaf-dispatch-event` 不产生指针状态，因此 Host 的 `:active` 外观意味着确实有一次指针按压正在被跟踪。状态活在挂载上，手势期间的重发布不会让它消失：拖拽处理器可以更新 Host 的属性或位置，按住的外观一直保留到释放。

## 悬停反馈

<!-- index: 悬停; mouse face; help echo; 悬停内容 -->

悬停反馈是原生的：Ebox 把 `:hover-style` 画成节点的 `mouse-face`、把 `:help-echo` 画成节点的帮助文本，由 Emacs 在指针停在 Host 上时显示。绘制覆盖元素画出的整个区域，包括内边距与它跨的每一行；隐藏元素则什么都不画。两个属性都从祖先继承，显式 nil 阻断继承值，见[交互总论](interaction-overview.md#交互属性的继承)。

`:hover-content` 改变的是元素显示的内容而不是绘制方式：指针悬停在 Host 上——或键盘焦点到达它——期间，ETAF 把 Host 第一个文本后代的文本换成该值，指针或焦点离开时恢复原文。`:hover-group` 让多个 Host 一起切换，工具栏因此可以一次露出所有按钮的完整标签。可以用零参函数计算替换值。

#### Function: ebox-help-create (function)

把零参函数 FUNCTION 适配成原生 `help-echo` 回调。

**参数。** FUNCTION 不接受参数，必须返回字符串或 nil。

**语义。** Ebox 帮助函数是原生三参数 `help-echo` 回调，这个适配器桥接更简单的形式：Emacs 调用返回的函数时，它解析帮助对象对应的 buffer（buffer、overlay buffer 或活窗口的 buffer），把它设为 current，调用 FUNCTION 并返回其字符串。Host 本来就接受普通字符串作为 `:help-echo`，所以这是给必须在显示时计算的帮助文本用的，例如取自指针下的那一行。

**返回。** 适用于原生 `help-echo` 文本属性的函数。

**错误。** 创建时 FUNCTION 不是函数或不接受零参时报 `error→ error`；返回值既不是字符串也不是 nil 时，在 Emacs 显示帮助时报错。

**示例。** `(text :help-echo (ebox-help-create (lambda () (format "Saved %s" (current-time-string)))) "Status")`

**参见。** [Host](hosts.md#property-help-echo)、`:hover-style`、`:hover-content`。

## 禁用与命中测试

<!-- index: 禁用 Host; 空 keymap; 命中测试 -->

禁用的 Host 仍然可见并保留布局位置，但它是惰性的：不运行事件回调或 `:keys`，Behavior 不安装，也不能获得焦点。Ebox 给它一个空 keymap，因此它仍然占住自己的命中区并阻断而不是穿透：点击禁用的按钮永远不会激活它周围的行，即使两者画出的边界重合。应用因此可以只禁用一个控件，而不会意外让它的容器成为目标。

其余边界规则属于[交互总论](interaction-overview.md#命中测试)：激活跟随最近的 keymap，因此可按压行里的标签激活该行，自带回调的嵌套控件自行处理按压，而没有声明按压边界的普通 Host 把 keymap 留给父级。从应用的视角看是哪个 Host 被命中，由 `etaf-host-ref-at` 回答。

## 错误与恢复

<!-- index: 事件错误; 派发错误 -->

#### Error: etaf-event-error

消息为 "Invalid ETAF Event"。当事件操作因事件上下文或目标非法而无法执行时抛出。用 `condition-case` 捕获这个条件；失败的调用不返回值。它的父条件是 `error`，数据是描述违规的值列表。

| 数据 | 原因 |
| --- | --- |
| `("Invalid event kind: %S")` | 派发 KIND 不是符号、关键字或字符串 |
| `("No KIND handler for Host reference REF")` | 目标、或 Runtime 不认识的引用，没有该种类的已提交处理器 |
| `("Cannot dispatch to disabled Host reference: REF")` | 派发到禁用的 Host；终止性拖拽取消例外 |
| `("Event source lookup requires a Host event callback")` | 在回调之外调用 `etaf-event-pointer-p` |
| `("Event target lookup requires a Host event callback")` | 在回调之外调用 `etaf-event-target-within-p` |
| `("Drag step COLUMNS and ROWS must be numbers")`、`("No committed Host reference" REF)` | `etaf-drag-step` 参数非法或 Host 缺失 |
| `("Native input requires a Host event callback")` | 在回调之外调用 `etaf-call-with-input` |

这个错误报告的是坏掉的派发，不是坏掉的 Host：目标缺失或被禁用时已提交的树、焦点与输入会话都不变，应用可以修好引用或禁用状态再派发一次。空白位置不是这个错误：`ebox-activate` 与 `etaf-activate` 在那里报 `user-error`，因为事件本身没有任何问题。
