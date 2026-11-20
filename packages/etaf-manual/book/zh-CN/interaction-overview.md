# 交互总论

文本应用通过两个协作的层接收输入。Ebox 拥有原生原语：保留在节点上的交互能力、把这些能力画成 Emacs 文本属性、命中测试、焦点、指针状态与原生输入会话。ETAF 拥有回调：Host 的 `:on-*` 属性是按 Host 引用寻址的应用代码，在响应式批处理里运行。本章把这条路径从头到尾画出来——输入如何到达回调、命中测试如何选择目标、交互属性如何继承——随后各章分别展开每一部分：[事件](events.md)、[焦点](focus.md)、[键盘](keyboard.md)、[区域导航](region-navigation.md)、[拖拽与手势](dragging-and-gestures.md)与[文本输入](text-input.md)。[Host](hosts.md)定义语义属性与事件属性本身，[Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)定义回调如何变成具名业务变更或可复用的 Behavior。

## 交互路径

<!-- index: 交互路径; 降级; 交互边界; 事件批处理 -->

分工是有意为之：Ebox 不知道 Component、Action 或响应式值，ETAF 也从不读 buffer 去判断点了什么。Ebox 回答指针下面是什么、某个键归谁；ETAF 回答运行哪段应用代码。

Host 提交时，Runtime 把它的属性降级到代表它的 Ebox 节点上。`:on-press` 与 `:on-drag` 变成一个用 `ebox-keymap-create` 创建的 Ebox keymap：它的激活入口分发该 Host 的 press，拖拽入口转发每个手势阶段。`:on-swipe` 与 `:on-scroll` 变成稳定的中继函数，装为节点自己的交互回调。指针 affordance `:help-echo`、`:pointer`、`:hover-style`、`:hover-content` 与 `:drag-lock-modifier` 按作者写的值到达节点，`:disabled` 与 `:tab-index` 加入节点的交互状态。键盘声明走另一条路：`:keys`、`:region` 与 `:on-direction` 留在 Runtime 的键盘层，不落到节点上。

并非每个 Host 都会成为交互边界。带 press 或 drag 回调的 Host 会成为边界；禁用、或声明了 `button`、`link`、`option`、`slider` 这类控件角色的 Host 也是边界，因为即使还没有回调，这些事实也关系到目标与无障碍身份。只有引用或无障碍标签的普通文本仍属于父级。这既让整段带标签的正文不会吞掉本该给外层行的点击，又让真正的控件保留自己的身份。

随后 Ebox 把每个节点的能力画成原生文本属性，覆盖它画出的全部内容——内容、内边距与边框；内联节点带在字符串上，盒带在格子上。隐藏节点什么都不画，因此不提供任何交互反馈。从这一刻起，buffer 自己带着交互事实：Emacs 把点击或按键解析到该位置最近的 keymap 属性，Ebox 的命令包装再带着指针的 buffer 位置或焦点节点运行。

最后一段是 Runtime。包装调用 `etaf-dispatch-event`，它按 Host 引用在已挂载的 Runtime 里查处理器，建立事件上下文（`etaf-current-runtime` 以及事件的种类、Host 与目标），并在一次响应式批处理里运行回调，因此回调的写入在批边界一起发布。press 的回调成功后，祖先的 `:on-press-capture` 回调从最近的已提交祖先向外运行，外壳因此能观察嵌套的按压，而不必让每个叶子都知道它。拖拽、swipe 与 scroll 回调经由同一条路径收到载荷。

应用通过五个面接触这条路径。局部 `:on-*` 回调最直接，适合一次性交互。当交互是一次业务变更时，`etaf-dispatch` 运行具名 Action。经 `:use` 安装的 Behavior 把同一批属性以及它们需要的资源打包复用。`etaf-dispatch-event` 显式派发，测试与集成用它代替指针。`etaf-activate` 对焦点或 point 解析出的目标做键盘激活，与 RET 和 SPC 完全一致。

两层所有权划分清楚。Ebox 拥有目标选择、焦点、输入会话生命周期、`:active` 与 `:disabled` 这类指针状态、手势识别与 keymap 执行。ETAF 拥有回调身份、在重渲染后仍然存活的登记表、响应式批处理与公共 Lisp API。由于降级出的 keymap 按回调身份缓存、中继函数身份稳定，用同一批处理器重渲染 Host 不会让它失效重排；被移除或卸载的 Host 不再收到应用回调。

## 命中测试

<!-- index: 命中测试; 激活; 禁用的命中区; 引用回溯 -->

命中测试把一个 buffer 位置变成拥有它的节点。位置上是某个内联节点画出的文本时，通过该节点的属性解析；否则由几何决定。几何遍历按绘制逆序走树——图层高者先，同层则后画者先——返回覆盖该格的最深节点。这条规则让浮层面板上的点击到达面板，尽管下面还压着另一行，也让悬停反馈遵循同样的归属。

激活用覆盖该位置的最近 keymap。指针按压与 RET、SPC 都调用这个 keymap 的激活入口，因此指针与键盘激活落在同一个目标上；`ebox-activate` 调用 point 处节点的 RET 绑定，point 停在焦点节点首个画出字符上时则用焦点节点。`ebox-next-interaction` 与 `ebox-previous-interaction` 在 keymap 拥有者之间移动 point，这是交互区域键盘遍历背后的原语。

由于 keymap 会被继承，内部元素若自己没声明回调，就不会把按压从容器手里夺走：可按压行里的标签仍然激活该行，只有角色、没有处理器的控件也一样。自己声明 press 或 drag 回调的元素则成为更近的拥有者，自行处理按压。禁用元素是有意设置的例外：它画一个空 keymap，占住该位置并终止查找，因此禁用的控件永远不会落回它周围的行，即使两者画出的边界重合也一样。

ETAF 用 Host 属性表达同一个边界，并加上引用层。`etaf-host-ref-at` 从某位置最深的 Host 向外走，返回第一个显式 `:ref`，可用 predicate 过滤，因此应用问的是「按到了哪个面板」而不是「哪个叶子」。生成的引用永远不会被返回。`etaf-host-ref-bounds`、`etaf-host-ref-position` 与 `etaf-host-ref-size` 暴露该目标的几何，供直达键与命中测试集成使用。带 press 或 drag 回调的 Host 还会自动得到 `hand` 指针形状，除非它声明了别的形状。

## 交互属性的继承

<!-- index: 属性继承; 显式 nil; 空 keymap; 悬停覆盖 -->

交互能力沿节点树向下继承。Ebox 先画祖先的值，后代只在空缺处补上，因此容器上的 keymap、`help-echo` 文本、指针形状或悬停 face 会作用到它内部画出的一切。显式 nil 也是一个值：它被画成一个存在的 nil——keymap 的位置上则是一个空 keymap——并为该子树阻断继承来的能力。行因此能让自己可点击，而不会悄悄把内部每个标签都变成单独目标；子元素也借此退出自己不要的悬停效果。

keymap 查找在禁用节点处停止，因此禁用容器挡住它背后的 keymap，而不是把它暴露出去。悬停反馈覆盖整个绘制区域：元素的内边距格与多行元素的每一行合为一个区域，填充还会跟随元素自身的圆角。并排元素彼此独立：指针只重绘所指元素的盒子，邻居与它们之间的空隙保持静止样式。同一目标内的移动不产生变化，发布后高亮仍留在同一目标上。已挂载的 buffer 按悬停节点自身的计算样式重绘；渲染文本把同样的声明作为原生 mouse face 携带。离开 buffer 或卸载时恢复静止样式。隐藏元素什么都不画，因此它保留布局空间，但不提供悬停、指针形状、帮助文本或激活。

ETAF 语义属性——身份、Behavior、类、无障碍元数据等——的继承遵循 [Host](hosts.md#值与冲突) 的合并规则，包括它们各自的显式 nil 阻断，以及归属语义冲突时报错。上面这些交互能力是 ETAF 降级进去的 Ebox 层事实；逐属性的说明在 [Host](hosts.md) 参考里。键盘焦点显示与指针相同的悬停 affordance，因此控件无论被指到还是被键盘到达，都会露出完整标签。

## 错误与恢复

<!-- index: 交互错误; 事件上下文 -->

- 在事件回调之外调用事件上下文查询 `etaf-event-pointer-p` 或 `etaf-event-target-within-p` 会报 `error→ etaf-event-error`；它们描述的是进行中的事件，不是全局状态。
- 显式派发到禁用的 Host、没有该种类处理器的 Host，或 Runtime 不认识的引用，报 `error→ etaf-event-error`。在没有任何命令的位置上激活则报 `user-error`，因为空白处只是普通输入，不是坏掉的派发。
- 从渲染代码里派发是一次副作用，报 `error→ etaf-render-side-effect-error`，数据为 `(dispatch-event)`；事件回调只在提交之后运行，见[响应式系统](reactivity.md#渲染不产生副作用)。
- 回调自己的错误在该事件的批处理排空后向派发的调用者传播；为同一事件组合的其余回调不再运行，已经做出的业务写入不会回滚。组合顺序与 capture 钩子由[事件](events.md)完整定义。
