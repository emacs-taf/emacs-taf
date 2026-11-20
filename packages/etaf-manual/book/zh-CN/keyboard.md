# 键盘

每种交互都要有键盘路径，框架的规则是应用声明结构而不是按键处理器。Host 用 `:keys` 属性列出自己的按键；方向行为用 `:on-direction` 声明；焦点导航与关闭是框架键，Host 只需提供入口点。本章描述作用域键层：`:keys` 如何按焦点与 point 解析、框架保留键、两套方向方案与它们的处理器链、Escape 关闭、帮助与命令面板两个界面、Ebox buffer 模式与它的键表、原生 keymap 原语，以及这一层如何构成。[Host](hosts.md#property-keys)定义 `:keys` 属性，[事件](events.md#property-on-dismiss)定义 `:on-dismiss`；[焦点](focus.md)定义框架键执行的导航。

## Host 键

<!-- index: :keys; 键绑定; 带标签的键 -->

Host 用 `:keys` 声明键盘命令，它是 `(KEY COMMAND [LABEL])` 条目的列表。KEY 是 `kbd` 字符串或按键向量，COMMAND 不接受参数（是命令时按交互方式运行），可选的 LABEL 在帮助缓冲与命令面板里给命令命名。Host 及其祖先的条目组成它的键作用域：只要作用域的入口——焦点，或没有任何焦点时、以及 point 移出聚焦 Host 后的 point——位于该 Host 内部，键就可用。

命令的运行方式与 keymap 绑定完全相同，不在任何批里：每次写入各自发布，因此命令可以移动 point 到、聚焦或开始编辑一个它刚刚显示出来的 Host。多次写入应当一起发布时用 `etaf-batch` 包起来。正因为如此，键命令才能在一次按压里既显示新内容又作用于它。

多个 Host 可以在不同深度声明同一个键。最近者获胜；禁用的 Host 不贡献自己的条目，搜索继续向外，因此禁用内层控件会回退到容器的绑定而不是丢掉这个键。Component 根 `:keys` 把调用者的条目放在前面，见 [Host](hosts.md#property-keys)。

## 按键解析顺序

<!-- index: 键解析; 键链; 落回; 原生输入 -->

在 Runtime buffer 里按下键时，这一层按固定顺序解析。

1. 作用域链在 point 位于聚焦 Host 或其子树内时从聚焦 Host 开始；否则从 point 处的 Host 开始。指针事件（例如在 `:keys` 里绑定的滚轮或点击）改从指针下的 Host 开始。最内层可见模态作用域不包含该 Host 时，链改从模态 Host 开始。
2. 从最近到最远搜索该 Host 及其祖先的 `:keys` 条目，遇到第一个 `:focus-scope modal` Host 后停止，因此打开的对话框外面的键不可达。禁用的 Host 不贡献任何东西。第一个匹配的条目获胜，只有一个例外：带按下处理器的最近可用 Host 比找到 RET 条目的 Host 更近时，RET 激活这个 Host。这样根上的 RET 条目可以作用于应用自己的选中项，又不会从聚焦的按钮手里抢走 RET。
3. 没有 Host 条目时框架键生效：`M-g` 进入[区域选择](region-navigation.md#选择区域)，Escape 关闭最近的 `:on-dismiss` Host，方向键运行 `etaf-direction`，Tab 与 S-Tab 移动一个焦点停靠点，`?` 打开 `etaf-help`，Home/End 到达组或作用域的首末。
4. 仍未绑定的键落回 buffer 的其他 keymap。原生输入会话编辑期间所有键都落回，让会话自己的编辑命令获胜。

因此 Host 键会遮蔽 buffer 对同一个键的绑定，打开的模态作用域还会吞掉未绑定的打印键，不让它们到达它背后的应用。序列前缀是共享的：Host 可以绑定 `C-c C-u`，同时 buffer 的模式表保留 `C-c C-k`；而同一个 Runtime 里一个键不能既运行命令又开启序列。

## 框架保留键

<!-- index: 保留键; keymap 校验 -->

框架拥有 Escape、`M-g`、`C-g`、`?`、Tab 与方向键。应用不能通过 `:keys` 绑定它们；方向行为改用 `:on-direction` 表达，`C-g` 保留 Emacs 原生的 keyboard quit 语义。保留集由键层固定，不是可变变量，因此组件可以在使用调用者提供的 keymap 之前先检查它。

#### Function: etaf-keymap-reserved-events (keymap)

返回 KEYMAP 顶层绑定的框架保留事件。

**参数。** KEYMAP 是 keymap 或 nil。

**语义。** KEYMAP 的每个顶层绑定都与保留集比较，冲突的事件向量按绑定顺序返回。组件作者在校验调用者提供的 `:keymap` 时调用它，保证组件不会遮蔽 Escape、区域选择入口（`M-g`）、原生 quit（`C-g`）、帮助键（`?`）、Tab 或方向键。绑定其他键的 keymap 无论多少都不算冲突。

**返回。** 事件向量列表；KEYMAP 为 nil、不是 keymap 或没有冲突时返回 nil。

**错误。** 无；参数不是 keymap 时就是 nil 结果。

**示例。** `(etaf-keymap-reserved-events (ebox-keymap-create :bindings '(("TAB" #'ignore))))` ⇒ `([tab])`

**参见。** `:keys`、`:on-direction`、[事件](events.md#property-on-dismiss)。

## 方向

<!-- index: 方向; :on-direction; 方向方案; 分隔条步进 -->

方向键属于框架，但「向下」在某个 Host 处的含义是应用策略。Host 用 `:on-direction` 声明该策略；这一层先运行最近的声明，再让聚焦的 separator 或 slider 走一步，然后移动焦点，最后在什么都动不了时滚动视口。

#### Property: :on-direction

决定方向键对 Host 意味着什么。

**参数。** 收一个参数的函数，参数是方向符号 `up`、`down`、`left` 或 `right`；或 nil。

**语义。** 作用域链上最近的、带处理器的 Host 为方向键作答。处理器返回三个符号之一：`handled` 与 `hold` 就此停住、焦点不动；`release` 把方向传给下面的分隔条步进、区域移动与空间移动。网格、滑块、轮播或编辑器用处理器消费方向键而不绑定它们。它在任何焦点移动之前运行，链与键层使用同一个焦点感知作用域，因此把方向泄漏给嵌套的编辑 Host 只需要在它那里放一个处理器。

**返回。** 返回值必须是 `handled`、`hold` 或 `release`；其他值除下面的错误外被忽略。

**错误。** 提交时值不是函数或 nil 报 `error→ etaf-renderer-error`；处理器返回其他值时报 `error→ etaf-event-error`，消息里给出返回值与期望的符号。

**示例。** `(box :on-direction (lambda (direction) (when (eq direction 'down) (next-line) 'handled)) ...)`

**参见。** `etaf-direction`、`etaf-direction-scheme`。

#### Function: etaf-direction (direction &optional runtime)

在已挂载 RUNTIME 中朝 DIRECTION 移动并返回聚焦的 Host 引用。

**参数。** DIRECTION 是 `up`、`down`、`left` 或 `right`。RUNTIME 默认为活动 Runtime。

**语义。** 顺序固定。先运行作用域内最近的 `:on-direction` 处理器；`handled` 与 `hold` 原样返回当前焦点，`release` 继续。然后，聚焦且 role 为 `separator` 或 `slider`、带 `:on-drag` 的 Host 沿它的 `:aria-orientation` 走一格，以键盘拖拽手势上报：`vertical` 元素（竖线）左右走，`horizontal` 元素上下走。接着焦点在周围区域内移动，有区域时在边缘进入相邻区域，见[区域导航](region-navigation.md#邻接)。没有周围区域时应用 Ebox 空间移动，它找不到停靠点时，下与上各滚动视口一步。没有焦点时由 point 处的 Host 作答，读者因此保留自己行的按键语义。方向键以及 `vim` 方案下的 `h`/`j`/`k`/`l` 运行的就是这个函数。

**返回。** 聚焦的 Host 引用；什么都没动时为 nil。

**错误。** 其他方向报 `error→ etaf-event-error`，消息 `"Unknown direction %S"`；`:on-direction` 返回值非法同样如此；渲染期调用报 `error→ etaf-render-side-effect-error`；Runtime 未挂载报 `error→ etaf-runtime-error`。

**示例。** `(etaf-direction 'down runtime)`

**参见。** `:on-direction`、`etaf-set-direction-scheme`、`etaf-drag-step`。

#### Variable: etaf-direction-scheme

键层的方向方案：`arrows`（默认）或 `vim`。

**语义。** `arrows` 下物理方向键运行 `etaf-direction`，`h`、`j`、`k`、`l` 仍是普通应用键。`vim` 下这四个字母在导航状态额外分发为方向键，适合不想离开主键位行导航的读者。方案是进程级的，在按键时读取而不是创建绑定时读取。请通过 `etaf-set-direction-scheme` 设置它，这样冲突的 Runtime 会被报告而不是被静默遮蔽。

**返回。** 不适用；变量保存当前方案符号。

**参见。** `etaf-set-direction-scheme`、`etaf-direction`。

#### Function: etaf-set-direction-scheme (scheme &optional runtime)

在冲突检查之后选择方向 SCHEME：`arrows` 或 `vim`。

**参数。** SCHEME 是 `arrows` 或 `vim`。RUNTIME 把冲突检查限制在一个已挂载 Runtime；nil 检查每个已挂载 Runtime。

**语义。** 切到 `vim` 前会确认被检查的 Runtime 里没有 Host `:keys` 条目或区域提示字符使用 `h`、`j`、`k`、`l`，因为这些绑定会变得不可达或歧义。冲突会一起报告，旧方案保持生效，因此不会出现只应用了一半的切换。`arrows` 从不冲突；切回去立刻把字母还给应用。

**返回。** SCHEME。

**错误。** `vim` 冲突时 `error→ user-error` 列出冲突的绑定与提示；其他方案报 `error→ etaf-event-error`，消息 `"Unknown direction scheme %S"`；显式 RUNTIME 未挂载时报 `error→ etaf-runtime-error`。

**示例。** `(etaf-set-direction-scheme 'vim runtime)`

**参见。** `etaf-direction-scheme`、`:on-direction`。

## 用 Escape 关闭

<!-- index: Escape; 关闭 -->

Escape 是框架键，用来关闭最近的可以关闭的东西。这一层从焦点向外在作用域链里找最近的、启用的、带 `:on-dismiss` 的 Host，并派发该回调；键不需要 Host 上任何绑定就能工作，被禁用的内层控件也不会让它背后的对话框无法关闭。`C-g` 有意不绑到这个行为：它保留 Emacs 的 keyboard quit 语义。[事件](events.md#property-on-dismiss)定义该回调与包含搜索的模态作用域。

## 帮助与命令面板

<!-- index: 帮助; 命令面板; etaf-help; etaf-palette -->

两个界面呈现键盘状态。帮助用于阅读：它列出当前作用域能到达的东西，从不运行任何命令。命令面板用于运行：它按名字提供带标签的命令与可聚焦控件。两者都是普通 Lisp 入口，应用因此可以从自己的菜单打开它们，而不只是靠框架键。

#### Function: etaf-help (&optional runtime)

在已挂载 RUNTIME 的原有 buffer 内打开只读快捷键模态框。

**参数。** RUNTIME 默认为活动或当前 buffer 的 Runtime。

**语义。** 在事件或响应式批次中调用时，先等待其待处理工作发布。在模态框取得焦点前捕获有效作用域：带标签的 Host 键、实际生效的应用本地 keymap、框架导航、区域入口、作用域内的 `:help` 说明以及可读的控件名称。复用原有 buffer、Emacs window 和应用 Runtime，不创建帮助 buffer 或拆窗。重复调用复用打开时的快照。打开前结束原生编辑并保留已接受的输入，然后由最近启用的 `:on-help-open` 回调准备应用，再捕获快照；回调的错误或 quit 中止打开。核心呈现支持滚动；加载 etaf-ui 后使用可搜索的 `etaf-key-help` 呈现。查看说明不会执行对应命令。Escape 先退出正在进行的搜索编辑，再关闭帮助；点击遮罩也会关闭，且不会激活背景。帮助打开期间，原生窗口从画布顶部显示，保证根浮层模态框可见。关闭后恢复仍有效的入口与原窗口位置；呈现器被拒绝时也恢复原位置。应用后台更新继续进行，但不改变已捕获的作用域。

**返回。** 应用 buffer。

**错误。** Runtime 未挂载时报 `error→ etaf-runtime-error`。

**示例。** `(etaf-help runtime)`

**参见。** `etaf-help-close`、`etaf-help-data`、`etaf-help-view-function`、`etaf-palette`、`:keys`。

#### Function: etaf-help-close (&optional runtime)

关闭 buffer 内的帮助，恢复仍有效的焦点与窗口起始位置。

**参数。** RUNTIME 默认为活动或当前 buffer 的 Runtime。

**语义。** 只释放帮助界面及其编辑会话，保留应用、业务状态和节点滚动位置。在事件或响应式批次内调用时，等模态框移除发布后再恢复焦点与原生窗口起始位置；该恢复不会覆盖新打开的帮助，也不干预同一批次内已经卸载的 Runtime。不重新聚焦已删除的入口。C-g 保持 Emacs 原生中断语义，不是关闭命令。卸载应用也会释放帮助及其快照。

**返回。** 帮助原本打开时返回非 nil，否则为 nil。

**错误。** RUNTIME 未挂载时报 `error→ etaf-runtime-error`。

#### Function: etaf-help-data (&optional runtime)

返回有效键盘作用域的防御性快照，其中不含可执行回调。

**参数。** RUNTIME 默认为活动或当前 buffer 的 Runtime。

**语义。** plist 包含字符串 `:title` 和 `:scope`，以及 `:groups`、`:notes` 和 `:controls`。每组包含 `:title`、`:source`、`:kind`（`application`、`framework` 或 `regions`）与 `:entries`；每个条目包含 `:key`、`:label`、`:source`，以及可选的按键向量 `:events`。说明取自作用域内 Host 的 `:help` 字符串；控件仅为可读名称，不含回调。近层 Host 键即使没有标签也会遮蔽外层绑定。本地实际生效的 keymap 补充其余条目，优先使用原生 menu-item 标签，否则取命令文档首行；无关的全局 minor mode 不属于应用帮助。帮助打开时返回打开时的快照。可变字符串、向量和列表均已复制，修改返回值不会影响应用或后续快照。

**返回。** 快照 plist。

**错误。** RUNTIME 未挂载时报 `error→ etaf-runtime-error`。

#### Variable: etaf-help-view-function

选择帮助呈现器，而不让核心反向依赖组件目录。

**语义。** nil（默认）使用核心的可滚动模态框；非 nil 时为接收 DATA 和 CLOSE、返回根浮层模态 View 的函数。DATA 遵循 `etaf-help-data`，CLOSE 是零参数关闭回调。View 继承打开位置 Host 的 Context 和挂载生命周期，不得创建 buffer 或 window，也不得执行列表中的业务命令。加载 etaf-ui 时仅在此值为 nil 时安装目录呈现器，保留既有自定义呈现器。呈现失败后应用保持可用，并可重试。

**参见。** `etaf-help`、`etaf-key-help`。

#### Function: etaf-palette (&optional runtime)

按名字选择并运行已挂载 RUNTIME 的命令或控件。

**参数。** RUNTIME 默认为活动 Runtime。

**语义。** 候选是当前焦点可达的带 LABEL `:keys`、存在 `:on-dismiss` Host 时的 `Close` 条目，以及模态作用域里每个用 `:aria-label` 或绘制文本命名的可聚焦控件。选一个键就完全像按键一样运行它的命令；选一个控件先聚焦它再派发 press。重名标签得到数字后缀，每个候选都保持可选。面板有意通过 `M-x` 到达，这让执行面保持显式，而 `?` 始终只读。

**返回。** 所选命令的结果，或 nil。

**错误。** 作用域没有候选时报 `error→ user-error`，消息 `"No ETAF command is reachable here"`；Runtime 未挂载时报 `error→ etaf-runtime-error`。

**示例。** `(etaf-palette runtime)`

**参见。** `etaf-help`、`:keys`、`:on-dismiss`。

## Ebox buffer 模式

<!-- index: ebox-buffer-mode; keymap; 画布输入 -->

已挂载的 buffer 是应用输出，不是可编辑文本。`ebox-mount` 因此开启 `ebox-buffer-mode`，这个 minor mode 的键表把常用的阅读键变成导航，并阻止未绑定的打印键把自己插入画布。

#### Function: ebox-buffer-mode (&optional arg)

已挂载 Ebox buffer 的 minor mode。

**参数。** ARG 与任何 minor mode 一样切换模式；nil 切换，正参数开启，负参数关闭。

**语义。** `ebox-mount` 开启该模式，`ebox-unmount-buffer` 关闭它，应用不直接管理。模式开启时，它的键表铺在 buffer 上，overline margin 归零以免上边框增加行高，paren 高亮关闭因为画出的文本不是代码。原生输入会话取走它编辑需要的键。模式还让画布免于选区：在画布上激活的 mark 会被拒绝。

**返回。** 切换后的模式变量。

**错误。** 无。

**示例。** `(ebox-buffer-mode 1)`

**参见。** `ebox-buffer-mode-map`、`ebox-mount`。

#### Variable: ebox-buffer-mode-map

已挂载 Ebox buffer 的键表：滚动、焦点导航与激活。

**语义。** 键表覆盖整个阅读与导航面：滚轮、fringe 与 margin 的滚动事件与水平滚轮 swipe；`n`/`p`、`C-v`/`M-v`、SPC/S-SPC、`<next>`/`<prior>` 以及 `scroll-up-command`/`scroll-down-command` 的重映射；`q` 关闭窗口；Tab 与 S-Tab 移动焦点；RET 与 return 激活；方向键与 `C-n`/`C-p`/`C-b`/`C-f` 运行 `ebox-focus-direction`，该方向没有焦点停靠点时滚动；Home/End 与 `M-<`/`M->` 到达组或作用域的首末停靠点；`mouse-movement` 更新悬停内容。未绑定的打印键被抑制，而不是留给自插入，因此挂载的画布不会意外变成可编辑的。应用在加载 Ebox 之后定制该键表以修改共享绑定；ETAF 把 Host 键与框架键叠在它上面。

**返回。** 不适用；变量保存键表。

**参见。** `ebox-buffer-mode`、`etaf-keymap-reserved-events`。

## Ebox keymap

<!-- index: 原生 keymap; 激活绑定; 手势绑定 -->

Ebox 让库作者创建原生 keymap，其交互形态与 ETAF 把 Host 回调降级进去的形态相同。键表可以在标准键上激活、把额外序列绑到零参回调，或者在主键拖拽手势上接收回调并带可选的锁定修饰键。

#### Function: ebox-keymap-create (&rest options)

从 OPTIONS 创建原生 keymap。

**参数。** OPTIONS 是一个 plist，键有：`:activate`，零参回调，绑定 RET、return、SPC 以及——没有同时声明拖拽手势时——主鼠标键；`:bindings`，按键描述或向量到零参回调的 alist；`:drag`，逐阶段接收手势的一参回调；`:drag-lock-modifier`，`shift`、`control`、`meta`、`super` 或 `hyper` 之一，让拖拽跨过按键释放继续存活；`:drag-edge`，任何非 nil 值，让拖拽停在或越过窗口边缘带时报告 `edge` 阶段。锁定修饰键需要 `:drag`；格式错误的选项或回调在创建键表时报错。

**语义。** 返回的 keymap 是普通 Emacs keymap，适用于 Ebox 画在节点上的 `:keymap` 文本属性。激活绑定占用主键序列，使按压既不开始区域选择也不到达全局命令，并且只在释放落在同一个拥有者上时激活；拖拽绑定占用整个主键序列，并通过手势回调转发移动，plist 带阶段、事件、节点、窗口、buffer、起始与当前像素位置、位移、指针越出文本区的距离以及取消原因。给出 `:drag-edge` 时，回调还会收到带 `:edges` 与 `:elapsed` 的 `edge` 阶段；引擎只报告意图，滚动归应用所有，见[拖拽与手势](dragging-and-gestures.md#边缘意图与滚动)。同时有纯按压与序列绑定的键表会拒绝一个序列成为另一个的前缀，与应用键层拒绝「一个键既运行又开启序列」完全一样。ETAF 就用这个原语构建 Host keymap，因此 `:on-press` Host 的行为像 `:activate` 绑定，`:on-drag` Host 像 `:drag` 绑定。

**返回。** 新的 keymap。

**错误。** 未知或重复的选项、支持的集合之外的锁定修饰键、没有 `:drag` 的锁定修饰键、不是函数的 `:drag`、不是 alist 的 `:bindings`、值不是函数的绑定、既不是字符串也不是向量的键、空键、不接受零参的回调、与已有键重叠的绑定，都报 `error→ error` 并给出违规值。

**示例。** `(ebox-keymap-create :activate (lambda () (save)) :bindings '(("C-r" #'reload)))`

**参见。** [事件](events.md#property-on-drag)、`:keys`、`ebox-mount`。

## 作用域键层

<!-- index: 模拟按键表; 惰性解析; 作用域链 -->

这一层的构建方式是让声明而不是绑定可扩展。每个 Runtime buffer 拥有一张 keymap，为任何可达 Host 声明过的每个键放一个绑定器；这张表安装在 Emacs 的 emulation keymap 之中，从而先于 buffer 自己的表，而不必改写它们。因此应用把它的键声明在根 Host 上，而不是安装自己的 keymap；这些键随之出现在帮助里，遵守模态作用域与禁用 Host，也不会破坏框架键。每个绑定器是惰性过滤器而不是固定命令：按键时过滤器沿当前作用域链——焦点、point 处 Host、直到 modal 边界的祖先——查找并返回最近的匹配命令、某个框架命令，或者什么都不返回，这时键继续走剩下的键表。由于解析发生在按键时，Host 增加或失去绑定会改变有效键表而不需要重装；由于链在 modal 边界停止，打开的对话框在构造上就是隔离的。

序列冲突是结构性的而非运行时的：注册一个扩展了别的绑定的序列，或反过来被别人扩展，都是 render error，因此表里永远不会出现歧义前缀。Vim 字母的方案检查是同一思路用在方向键上：冲突在方案改变之前就被报告。

## 错误与恢复

<!-- index: 键盘错误; 键校验 -->

键盘问题按发现时机分开。格式错误或冲突的 `:keys` 值、绑定保留键、以打印键开头的序列都在 Host 提交时报 `error→ etaf-renderer-error`，消息点名条目。非函数的 `:on-direction` 在提交时失败；非法返回值在方向运行时失败，报 `error→ etaf-event-error`。`etaf-direction` 用 `etaf-event-error` 拒绝未知方向，`etaf-set-direction-scheme` 拒绝未知方案；Vim 冲突则是 `user-error`，列出每个冲突并保持旧方案生效，因此应用解决命名期间键盘仍然可用。`etaf-palette` 没有可达候选时是 `user-error`，而解析不到任何东西的键根本不是错误：它落回 buffer 的键表，挂载画布因此能与用户的编辑命令共存。
