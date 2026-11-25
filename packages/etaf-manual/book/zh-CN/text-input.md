# 文本输入

已渲染的文本 Host 通常是输出而不是编辑面：画布没有文本选区，未绑定的打印键什么都不做。当用户必须在不离开挂载布局的情况下往一个输入框里打字时，*输入会话*把恰好一个已排布的文本节点变成可编辑的值。用户键入的键是普通的 Emacs 编辑命令，作用在一个保存该值的隐藏 buffer 上；节点在自己的盒子里重绘每次按键，因此值增长收缩时换行、内边距与边框保持原位。本章描述会话模型、ETAF 与 Ebox 入口、点击与选区映射、输入法预编辑、会话如何结束（含 Runtime 结束器），以及错误条件。[事件](events.md)定义从按压开启会话的 Host 事件回调，[键盘](keyboard.md)定义键层——会话编辑期间它会让位。

## 输入会话

<!-- index: 输入会话; 编辑 buffer; 会话值 -->

一个会话连接三样东西：已挂载的文本节点、保存节点值的隐藏编辑 buffer，以及挂载 buffer 的命令循环。创建会话把节点当前文本复制进编辑 buffer，并把到达挂载 buffer 的编辑命令改道到该 buffer——插入、删除、移动、kill ring、undo、选区与输入法都作用于值，而挂载 buffer 本身保持只读。每条命令之后会话把 buffer 读回，值变化时调用变更回调，并重绘节点，因此可见输入框始终与值一致。

编辑期间节点保持布局。换行、内边距与边框属于它外面的盒子，保持不动；值被重新测量，盒子可以变大变小。挂载 buffer 的 point 跟随编辑 caret，上下移动按绘制行而不是值行，因此换行的值按其外观移动。画出的字符带自己的值偏移，会话因此能把点击映射到 caret 位置并反向映射。会话是让用户编辑挂载文本的唯一受支持方式；直接写 buffer 会与保留树冲突。

每个挂载 buffer 至多一个会话。处置挂载会结束它的会话，显式结束调用也一样。会话结束时它的编辑 buffer 会被记住而不是丢弃：如果节点文本自上次会话以来没有变化，下一次会话复用它并保留 caret、选区与 undo 历史，因此关闭再打开的输入框会回到用户离开的位置。

## ETAF 接口

<!-- index: 输入 API; :on-change; :keymap; :local-variables -->

ETAF 函数按 Host 引用寻址会话，与应用其余 API 一致，并把会话选项转发给 Ebox。

#### Function: etaf-input-begin (runtime host-ref &rest options)

开始对已挂载文本 Host 的值的原生编辑；返回一个会话。

**参数。** RUNTIME 是已挂载的 Runtime。HOST-REF 指向已提交的文本 Host；其他种类的 Host 报 `ebox-input-error`。OPTIONS 是输入会话选项：`:on-change` 在每次改变值的命令后收到新值，`:on-leave` 在稍后点击落在 Host 盒外时运行，`:keymap` 保存先于编辑命令查阅的绑定，`:local-variables` 是编辑命令用 buffer-local 设置的 alist，`:caret` 是放置 caret 的值偏移。其余选项属于 Ebox，因此这个清单随 Ebox 契约增长，而不在这里重新定义。

**语义。** Host 的文本成为会话值，caret 默认在末尾，除非 `:caret` 另有所指。键入的键用普通 Emacs 命令、undo 与输入法编辑值，Host 保持布局、内边距与边框并立即显示每次编辑。发布在会话期间继续：把会话值发布进 Host 是 no-op，发布另一个值会替换会话文本并清空它的 undo 历史。会话开始与结束都不需要显式 flush；挂载 buffer 随用户输入更新。

**返回。** 会话对象，供 `etaf-input-text`、`etaf-input-end` 与 `ebox-input-session-node` 使用。

**错误。** RUNTIME 未挂载时报 `error→ etaf-runtime-error`；未知 HOST-REF 时报 `error→ etaf-event-error`，消息 `"No committed Host reference"`；Host 不是已排布文本节点、buffer 已有会话或 `:keymap` 值不是 keymap 时报 `error→ ebox-input-error`。

**示例。** `(etaf-input-begin runtime 'search-field :on-change (lambda (value) (etaf-set-value query value)))`

**参见。** `etaf-input-text`、`etaf-input-end`、`ebox-input-begin`。

#### Function: etaf-input-text (session)

返回会话当前的无属性值；会话结束后返回 nil。

**参数。** SESSION 是 `etaf-input-begin` 返回的会话。

**语义。** 值是剥掉文本属性的编辑 buffer 内容，因此调用者永远看不到 caret overlay 或预编辑标记。读取它不会结束会话，也不发布任何东西。会话结束后值是 nil，因为最终值属于继续显示它的 Host。

**返回。** 当前值字符串；会话结束后为 nil。

**错误。** SESSION 不是会话对象时报 `error→ ebox-input-error`。

**示例。** `(etaf-input-text session)`

**参见。** `etaf-input-end`、`ebox-input-text`。

#### Function: etaf-input-end (session)

结束会话并返回它的值；Host 继续显示该值。

**参数。** SESSION 是一个会话。

**语义。** 会话与 buffer 解绑，Host 的文本被设为不含预编辑的最终值，会话的编辑 buffer 被缓存以便复用。结束一个已经结束的会话——例如它的 buffer 已被卸载——返回 nil 且什么都不做。结束是幂等的，对已结束会话从不报错。

**返回。** 最终值字符串；会话早已结束时为 nil。

**错误。** SESSION 不是会话对象时报 `error→ ebox-input-error`。

**示例。** `(etaf-input-end session)`

**参见。** `etaf-input-text`、`etaf-call-with-input`、`etaf-runtime-set-input-finisher`。

#### Function: etaf-input-active-p (&optional runtime)

返回已挂载 Runtime 的活动输入会话，或 nil。

**参数。** RUNTIME 默认为活动 Runtime 或当前 buffer 的 Runtime。

**语义。** 这是 Runtime 层「用户是否在编辑、在编辑什么」的查询。没有会话的 Runtime 返回 nil 而不是报错，因此这个检查在键处理器与事件回调里可以安全使用。

**返回。** 会话对象，或 nil。

**错误。** RUNTIME 未挂载时报 `error→ etaf-runtime-error`。

**示例。** `(etaf-input-active-p runtime)`

**参见。** `etaf-input-begin`、`ebox-input-active-p`。

#### Function: etaf-input-edit-command-add (command)

把 COMMAND 加入「编辑原生输入会话文本」的命令列表。

**语义。** 列表中的命令若绑定在会话 keymap 里就编辑会话值；其余会话绑定在挂载缓冲区里运行。列表初始包含标准的插入、移动与 yank 命令，目录组件用这个入口登记自己的编辑命令。

**返回。** 更新后的命令列表。

**错误。** COMMAND 不是命令符号时 `error→ wrong-type-argument`，数据点名 `commandp`。

**参见。** `etaf-input-edit-command-remove`、`ebox-input-begin`。

#### Function: etaf-input-edit-command-remove (command)

把 COMMAND 从原生输入会话的文本编辑命令里移除。

**语义。** 组件卸载、或某个命令不该再编辑会话值时用它；之后其余会话绑定重新在挂载缓冲区里运行。

**返回。** 更新后的命令列表。

**错误。** COMMAND 不是命令符号时 `error→ wrong-type-argument`，数据点名 `commandp`。

**参见。** `etaf-input-edit-command-add`。

```elisp :run
(etaf-define-component demo-input-mirror ()
  :bindings ((value (etaf-ref "")))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (etaf-text-input :bind value
                           :label "姓名"
                           :placeholder "在这里输入…"
                           :rows 2)
          (text :color (etaf-theme-token :ui-muted-fg "#526174")
                (expr (format "受控值：%S" (etaf-value value))))))
(etaf-view (demo-input-mirror))
```

## Ebox 接口

<!-- index: Ebox 输入; 会话节点 -->

Ebox 入口是没有 Runtime 层的同一批会话：它们直接寻址已挂载节点，拥有 Ebox 树而不使用 ETAF 的库因此可用。ETAF 应用能用会话做的一切在这里都可用，包括 ETAF 不暴露的部分，例如被编辑的节点与命令分类。

#### Function: ebox-input-begin (buffer-or-name node &rest options)

在 BUFFER-OR-NAME 中开始对已排布文本 NODE 的原生编辑，并返回一个会话。

**参数。** NODE 是存活、已排布的文本节点。OPTIONS 是 plist：`:on-change` 在每次改变值的命令后收到新值；`:keymap` 保存最先查阅的绑定；`:on-leave` 在稍后点击落在节点盒外时运行；`:local-variables` 是 `completion-at-point-functions` 这类 buffer-local 设置的 alist；`:caret` 是放置 caret 的值偏移。

**语义。** 节点文本成为会话值，caret 默认在末尾，除非 `:caret` 指定位置。会话活动期间，BUFFER-OR-NAME 里键入的键被分类：`:keymap` 的绑定在 buffer 里运行，`ebox-input-edit-commands` 里的命令除外——它们编辑值；没有会话绑定的键运行隐藏 buffer 的编辑命令，因此插入、删除、移动、kill 与 yank、undo、选区与输入法都作用于值，而 buffer 保持只读。节点保持布局并重绘每次编辑，point 跟随 caret，上下按绘制行移动，节点盒内的点击移动 caret 或选择。打开会话的手势不算离开它。把节点文本设为会话值是 no-op；另一个字符串替换值并清空 undo 历史。节点文本自上次会话以来未变的会话复用先前的编辑 buffer，保留 caret、选区与 undo 历史。

**返回。** 会话。

**错误。** BUFFER-OR-NAME 没有挂载、NODE 不是存活的已排布文本节点、buffer 已有会话、或 `:keymap` 不是 keymap 时报 `error→ ebox-input-error`。

**示例。** `(ebox-input-begin buffer field :on-change (lambda (value) (message "%s" value)))`

**参见。** `ebox-input-end`、`ebox-input-edit-commands`、`ebox-call-with-input`。

#### Function: ebox-input-text (session)

返回 SESSION 的当前值；会话结束后返回 nil。

**参数。** SESSION 是输入会话。

**语义。** 值无属性，因此 caret overlay 与预编辑标记永远不属于它。它与 `:on-change` 收到的是同一个值，只是按需读取；会话结束后函数返回 nil。

**返回。** 当前值字符串，或 nil。

**错误。** SESSION 不是会话对象时报 `error→ ebox-input-error`。

**示例。** `(ebox-input-text session)`

**参见。** `ebox-input-end`、`etaf-input-text`。

#### Function: ebox-input-end (session)

结束 SESSION 并返回它的值；NODE 继续显示该值。结束一个已经结束的会话返回 nil。

**参数。** SESSION 是输入会话。

**语义。** 会话解绑，节点文本成为不含预编辑的最终值，编辑 buffer 按节点缓存，供之后的会话复用 caret 与 undo 历史。重复调用结束是安全的，buffer 已卸载后也安全。

**返回。** 最终值字符串；会话早已结束时为 nil。

**错误。** SESSION 不是会话对象时报 `error→ ebox-input-error`。

**示例。** `(ebox-input-end session)`

**参见。** `ebox-input-begin`、`ebox-input-session-node`。

#### Function: ebox-input-active-p (&optional buffer-or-name)

返回 BUFFER-OR-NAME 的活动输入会话，或 nil。

**参数。** BUFFER-OR-NAME 默认为当前 buffer。

**语义。** 会话保存在挂载上，因此这是不经过 Runtime 层的直接查询。未挂载或没有会话的 buffer 返回 nil。

**返回。** 会话，或 nil。

**错误。** 无。

**示例。** `(ebox-input-active-p buffer)`

**参见。** `ebox-input-begin`、`etaf-input-active-p`。

#### Function: ebox-input-session-node (session)

返回 SESSION 编辑的节点。

**参数。** SESSION 是输入会话。

**语义。** 节点就是最初传给 `ebox-input-begin` 的已排布文本节点，在会话持续期间保持存活。应用用它把被编辑目标与命中测试比较，或把它交给 Ebox 自己的更新与几何函数。通过会话更新节点是受支持的路径；编辑期间节点身份不变。

**返回。** Ebox 文本节点。

**错误。** SESSION 不是会话对象时报 `error→ ebox-input-error`。

**示例。** `(ebox-node-bounds (ebox-input-session-node session))`

**参见。** `ebox-input-begin`、`ebox-node-set-text`。

#### Variable: etaf-cursor-follows-input-modality

已挂载画布在指针按压之后是否隐藏光标。

**语义。** 画出内容的页面跟随输入模态：按压留下的光标是一个多余的方块，所以它隐藏到下一个键盘命令为止。就地编辑文本的应用把它设为 nil，因为那里的按压确实放置了用户需要看见的 caret。

**返回。** 不适用；变量是一个布尔值。

**参见。** [文本输入](text-input.md)、[焦点](focus.md)。

#### Variable: ebox-allow-text-selection

已挂载画布是否允许 Emacs 原生 mark 与指针文本选择。

**语义。** 默认为 nil，使画布类应用在指针按压或 `set-mark-command` 时不会把布局单元绘成选区。把它设为缓冲区局部非 nil（或向 `etaf-mount` 传入 `:text-selection t`）后，阅读与浏览器缓冲区可以正常使用原生 mark、Shift 方向选区、鼠标拖拽选区与 `kill-ring-save`，同时交互控件仍保留自己的点击与拖拽手势。

**返回。** 不适用；变量是一个布尔值。

**参见。** `etaf-mount`、`etaf-cursor-follows-input-modality`。

#### Variable: ebox-input-edit-commands

会话 `:keymap` 绑定它们时编辑会话值的命令。

**语义。** 当 `:keymap` 条目的绑定是这些命令符号之一——`newline`、`open-line`、`newline-and-indent`、`electric-newline-and-maybe-indent`、`completion-at-point`、`indent-for-tab-command`、`yank`——该键编辑值而不是在挂载 buffer 里运行命令。会话键表里的其他绑定在挂载 buffer 里运行，输入框因此可以把 RET 绑成提交，同时用 Shift-RET 或 C-j 插入换行。这个清单存在的原因是这些命令作用于文本而不是控件：在挂载 buffer 里运行 `newline` 会试图往只读画布里插入，而会话要把换行放进它的值。

**返回。** 不适用；变量保存命令清单。

**参见。** `ebox-input-begin`、[键表](hosts.md#property-keys)。

## 点击、选区与 offset 映射

<!-- index: caret 放置; 指针选区; 值偏移 -->

会话让输入框画出的格子成为 caret 的指针目标。节点盒内的主键按压——包含内边距，有 keymap 拥有者包围时以它为界——把 caret 放到被按字符的值偏移处（它之前）。按下并拖动扩展选区，选区活在两个 buffer 里：在值上拖动会在输入框里高亮同样的字符，作用于 region 的编辑命令也看得到它。双击选中指针下的词，三击选中整个值，与普通 Emacs 行为一致。内边距上的按压仍算落在输入框内；嵌套在输入框框架里的控件拥有的按压同样让会话保持打开，因为该控件的回调可能想在不结束编辑的情况下做事；其他落在盒外的按压才算离开。

映射是值能够换行的原因：每个画出的字符带它在值里的偏移，会话因此把 buffer 位置换算成值偏移并换算回来。上下移动用同一张映射按绘制行移动并保留列，点击或编辑命令放置的 caret 与挂载 buffer 里的 point 保持一致。来自外部的写入——`ebox-node-set-text`、应用更新挂载内容——会被跟随：相同的字符串被忽略，不同的字符串替换值并清空 undo 历史，会话从那里继续编辑。

## 输入法预编辑

<!-- index: 预编辑; 输入法; working text -->

输入法需要一处显示尚未提交的文本。会话活动期间，输入法的 working text 显示在 caret 处，像其他内容一样在输入框盒子里换行，而会话值保持不变；输入法提交时结果字符插入值、预编辑消失。macOS 上 Emacs 用于此的 special events 在任何会话存在期间被路由到活动会话，之后恢复原生绑定，输入法因此在输入框里的工作方式与普通 buffer 完全相同。`ebox-input-text` 读到的值与报告给 `:on-change` 的值都不含预编辑。

## 结束、离开与结束器

<!-- index: 结束会话; on-leave; 结束器; 原生读取 -->

会话通过显式结束调用、它的 buffer 被卸载、或落在别处的按压而结束。最后一种情况是应用可以引导的策略：派发到既不是会话的 Host、也不包含它、也不是最近包围它的 Host 的 press，会先结束编辑会话，因此点击输入框之外会先提交再运行点击回调。会话怎样结束由应用决定，这正是结束器的用途。

#### Property: :on-leave

输入会话在点击落在被编辑盒外时运行的回调。

**参数。** 无参函数或 nil。它作为输入会话选项传入，而不是声明在 Host 上：`:on-leave` 不是 Host 事件属性，事件层从不派发它。

**语义。** 会话活动期间，位置在被编辑节点盒外的稍后点击会调用该回调一次。打开会话的手势不算：点击输入框打开会话，不能立刻报告离开。这个回调是提交值、关闭浮层或把编辑会话移到被点击输入框等策略的钩子。它在挂载 buffer 里、会话仍然活动时运行，因此可以读值或自行结束会话。

**返回。** 返回值被忽略。

**错误。** 回调错误从送达点击的命令传播。

**示例。** `(ebox-input-begin buffer field :on-leave (lambda () (message "left the field")))`

**参见。** `ebox-input-begin`、`etaf-input-begin`、`etaf-runtime-set-input-finisher`。

#### Function: etaf-call-with-input (reader)

从当前 Host 事件回调运行零参原生输入 READER。

**参数。** READER 不接受参数，返回调用者想拿到的值。

**语义。** 这是短程原生读取的事件回调形式：当前事件提供 Host，因此不传 Runtime 或引用。Ebox 恢复该 Host 的逻辑焦点并检查它仍然可见、启用；目标变得不可用时调用抛出 `quit` 的子类。READER 拥有原生编辑——它可以用 minibuffer 或其他 buffer——函数返回其结果而不应用任何应用状态，调用者自行决定拿值做什么。原生编辑不得编辑渲染面本身。

**返回。** READER 的结果，前提是目标仍然有效。

**错误。** 事件回调之外报 `error→ etaf-event-error`，消息 `"Native input requires a Host event callback"`；渲染期调用报 `error→ etaf-render-side-effect-error`，数据为 `(read-input)`；READER 错误与用户 quit 原样传播；目标失效抛出 `ebox-input-cancelled`，它是 `quit` 的子类。

**示例。** `(etaf-call-with-input (lambda () (read-string "Name: ")))`

**参见。** `ebox-call-with-input`、`etaf-input-begin`、`etaf-dispatch-event`。

#### Function: ebox-call-with-input (node reader &optional buffer-or-name)

为 BUFFER-OR-NAME 中可见、启用的 NODE 调用零参 READER。

**参数。** NODE 是要为其读取的 Ebox 节点；BUFFER-OR-NAME 默认为当前 buffer。

**语义。** 调用是同步且有作用域的：READER 在 Ebox 拥有目标校验期间运行，结束后逻辑焦点属于 NODE。如果 NODE 到那时已经消失或不可用，先前焦点在仍可聚焦时恢复，调用仍然报错，调用者因此不会把消失的目标误当成成功读取。

**返回。** READER 的结果。

**错误。** 开始时 NODE 不可聚焦报 `error→ user-error`，消息 `"Ebox input target is not available"`；读取后 NODE 不再可用报 `error→ ebox-input-cancelled` 并带该节点。

**示例。** `(ebox-call-with-input field (lambda () (read-string "Name: ")) buffer)`

**参见。** `etaf-call-with-input`、`ebox-input-begin`。

#### Function: etaf-runtime-set-input-finisher (runtime finisher)

把已挂载 RUNTIME 的原生输入会话结束器设为 FINISHER 或 nil。

**参数。** FINISHER 是收一个参数（Runtime）的函数，或 nil 表示移除。

**语义。** 结束器是应用对「在别处按压时如何离开会话」的策略。当 `press` 被派发到既不是会话自己的 Host、也不是包含它的 Host、也不是最近包围它的 Host 时，Runtime 在目标回调之前调用结束器，结束器应按应用保留或编辑的决定结束会话。组件目录的就地文本输入在它的会话打开期间注册一个。由于结束器在 press 批里运行，结束会话的发布在 press 回调观察树之前落定。没有结束器的 Runtime 只是让会话保持打开。

**返回。** FINISHER。

**错误。** RUNTIME 未挂载时报 `error→ etaf-runtime-error`；FINISHER 既不是函数也不是 nil 时报 `error→ wrong-type-argument`，数据为 `(functionp FINISHER)`。

**示例。** `(etaf-runtime-set-input-finisher runtime (lambda (rt) (etaf-input-end (etaf-input-active-p rt))))`

**参见。** `etaf-runtime-input-finisher`、`:on-leave`、`etaf-input-end`。

#### Function: etaf-runtime-input-finisher (x)

返回 RUNTIME 注册的输入会话结束器，或 nil。

**参数。** X 是被读取槽位的 Runtime。

**语义。** 这是 `etaf-runtime-set-input-finisher` 背后的结构访问器，供读取 Runtime 状态而不是设置它的代码使用。它返回注册的那个函数本身；没有安装时返回 nil；它不调用结束器。

**返回。** 结束器函数，或 nil。

**错误。** X 不是 Runtime 时报 `error→ wrong-type-argument`。

**示例。** `(when (etaf-runtime-input-finisher runtime) (message "input policy installed"))`

**参见。** `etaf-runtime-set-input-finisher`、`etaf-input-active-p`。

## 错误与恢复

<!-- index: 输入错误; 取消 -->

输入会话失败是显式的，因为会话拥有共享资源：一个 buffer 至多一个。在未挂载 buffer、非已排布文本节点、已有会话的 buffer 上创建会话，或传入不是 keymap 的 `:keymap`，都是 `ebox-input-error`；同一条件覆盖用非会话对象调用会话访问器。未知 Host 引用与未挂载 Runtime 由 ETAF 层按应用 API 的惯例报 `etaf-event-error` 与 `etaf-runtime-error`。丢失目标的一次读取抛出 `ebox-input-cancelled`，它是 `quit` 的子类，因此捕获 `quit` 处理用户取消的调用者也会捕获失效目标，不捕获它的调用者则把它当作普通取消。结束会话永远安全：第二次结束返回 nil，卸载 buffer 会静默丢弃它拥有的任何会话。

#### Error: ebox-input-error

Invalid Ebox input session

**语义。** 表示输入会话操作因目标或会话非法而无法执行。它是 `ebox-error` 的子类。用 `condition-case` 捕获；失败的调用不返回值。

**原因。** 未挂载的 buffer；不是存活已排布文本节点的节点；已有会话的 buffer；不是 keymap 的 `:keymap`；用非会话值调用访问器。

**参见。** `ebox-input-begin`、`etaf-input-begin`。

#### Error: ebox-input-cancelled

Ebox input target is no longer available

**语义。** 表示同步读取的目标在 reader 返回之前消失或变得不可用。该条件是 `quit` 的子类，因此 `condition-case` 的 `quit` 处理器同时捕获它与用户取消，目标失效与取消走同一条路。错误数据带失效的节点。

**恢复。** 调用没有应用任何东西；先前焦点在仍可聚焦时恢复。应用可以用新目标重读，或把这次读取当作取消。

**参见。** `ebox-call-with-input`、`etaf-call-with-input`。
