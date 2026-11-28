# 应用

*应用*是一个具名缓冲区里显示的一个已挂载 View，带着用户对一个程序期待的生命周期：在选中窗口里打开，随窗口变化让内容适配窗口，每个单元格都跟随主题，响应自己的键，离开时只保存一次状态。本章定义 `etaf-app-open` 与 `etaf-app-close` 提供的应用生命周期，应用的适配、主题与按键如何运作，以及打开或关闭失败时的恢复规则。运行命令行后端属于[异步模型](async.md#子进程)。

应用建立在 [Runtime](runtime.md) 之上：`etaf-app-open` 准备并显示缓冲区，然后调用 `etaf-mount`。嵌在别的缓冲区里的 View 或测试只需要 Runtime；应用在它外面补上顶层程序需要的东西。

<!-- index: 应用; 应用缓冲区; 应用生命周期 -->

## 模型

应用有一个名字（同时是它的缓冲区名）、一个 View，以及三份以函数提供的可选行为：让应用状态适配显示窗口的适配函数，保存或释放应用所持资源的关闭函数，以及画布的主题颜色。应用还带一个不透明的状态值，通常是它的命令要操作的记录或会话对象。

打开是一个事务：缓冲区被准备成画布、显示、适配、挂载，任何一步失败都会把应用再关掉。关闭有三种触发：杀掉缓冲区、`etaf-app-close`、用同一个名字重新打开；每一种都在 View 仍挂载时恰好运行一次关闭函数。

## 打开与关闭

#### Function: etaf-app-open (name view &key state on-fit on-close background foreground (cursor 'inherit) mode-line (display t) mount-options meta)

把 VIEW 作为应用缓冲区 NAME 打开，并返回该缓冲区。

**参数。**

- NAME 是缓冲区名。同名但不是已打开应用的缓冲区会被复用。
- VIEW 传给 `etaf-mount`：归一化的 View，或返回 View 的零参函数。
- STATE 是任意值；`etaf-app-state` 返回它。
- ON-FIT 是 nil 或单参函数，参数是显示窗口。它在应用缓冲区为当前缓冲区时运行。
- ON-CLOSE 是 nil 或无参函数。它在应用缓冲区为当前缓冲区时运行。
- BACKGROUND 与 FOREGROUND 是 nil 或一种颜色：颜色字符串、ref、computed，或返回颜色字符串或 nil 的零参函数。
- CURSOR 是一个 `cursor-type` 值，或 `inherit`（默认），表示保留缓冲区的光标。
- MODE-LINE 为 nil（默认）时隐藏 mode line，为 t 时保留，否则是一个 `mode-line-format` 值。
- DISPLAY 为 t（默认）时在选中窗口里显示缓冲区，是函数时由它接收并显示缓冲区，为 nil 时不显示。
- MOUNT-OPTIONS 是 `etaf-mount` 的 OPTIONS plist，或一个以显示窗口为参数（缓冲区未显示时为 nil）返回它的函数。函数在缓冲区里、ON-FIT 之后运行，所以固定的 `:viewport-height` 这类选项可以取自适配后的状态。
- META 是可选的 Runtime 元数据 plist（如 `:app`、`:kind`、`:uri`、`:title`，值可以是静态数据、ref、computed 或零参函数）；当 MOUNT-OPTIONS 未显式指定 `:meta` 时自动并入挂载选项。

**语义。** 各步骤按以下顺序运行。

1. 名为 NAME 的已打开应用先被关闭，并运行它的关闭函数。
2. 缓冲区被准备成画布：截断长行，关闭水平滚动与滚动边距，关闭行号，被截断的行不显示续行符号，所以比窗口宽的内容被干净地裁掉。CURSOR 与 MODE-LINE 按上文生效。
3. BACKGROUND 与 FOREGROUND 重映射缓冲区的 default face，让 View 没有绘制的单元格（例如最后一行下面的区域）与应用的表面一致。响应式颜色变化时会重绘，直到应用关闭。
4. DISPLAY 显示缓冲区。为 t 时，用户的 `display-buffer` 规则无法把它转到别的窗口或拆分 frame。
5. 缓冲区有窗口时，ON-FIT 以该窗口运行一次，所以首次渲染就用上适配后的尺寸。
6. VIEW 以 MOUNT-OPTIONS 挂载；它是函数时先调用它。

挂载之后，显示窗口每次稳定下来的变化都会再运行 ON-FIT，见[适配窗口](#适配窗口)。

**返回。** 应用缓冲区。

**错误。** 任何一步的错误都会关闭应用，包括 MOUNT-OPTIONS 无效时的 `etaf-runtime-error`、View 的错误以及打开过程中的 `quit`：关闭函数运行、缓冲区被杀掉、条件向外传播。

**示例。** 一个笔记应用把会话对象当作状态，在适配函数里设定列表大小，关闭时保存。

```elisp
(defun notes-open ()
  (interactive)
  (let ((session (notes-session-create)))
    (etaf-app-open "*notes*" (lambda () (notes-view session))
                   :state session
                   :on-fit (lambda (window)
                             (notes-set-page-size
                              session (- (window-body-height window) 2)))
                   :on-close (lambda () (notes-save session))
                   :background (notes-theme-color session :bg))))
```

**参见。** `etaf-app-close`、`etaf-mount` 与[原生应用窗口](runtime.md#原生应用窗口)。

#### Function: etaf-app-close (&optional buffer-or-name)

关闭 BUFFER-OR-NAME（默认当前缓冲区）里的应用，返回 t。

**语义。** 关闭函数在 View 仍挂载时运行，然后 View 卸载、缓冲区被杀掉。交互调用时关闭当前缓冲区里的应用，所以应用可以在根 `:keys` 里把它绑到 `q`。

**返回。** t。

**错误。** 缓冲区里没有已打开的应用时 `error→ user-error`。关闭函数的错误在缓冲区消失之后向外传播；直接杀掉缓冲区时，同一个错误改为以消息报告，所以 `kill-buffer` 本身从不失败。

#### Property: :on-close

`etaf-app-open` 与 `etaf-pip-open` 的关闭回调关键字。

**参数。** nil 或零参函数。

**语义。** 无论经由 `etaf-app-close`、`etaf-pip-close`、直接杀掉缓冲区还是以同名重新打开，在 View 卸载与缓冲区销毁前都会以当前缓冲区运行一次该回调。

**参见。** `etaf-app-open`、`etaf-app-close`、`etaf-pip-open`。

## 查找应用

#### Function: etaf-app-state (&optional buffer-or-name)

返回 BUFFER-OR-NAME（默认当前缓冲区）里已打开应用的 STATE，没有则返回 nil。

**语义。** 键命令在应用缓冲区里运行，所以它用 `(etaf-app-state)` 找到自己的会话，而不必另设一个缓冲区局部变量。关闭函数仍能看到这个状态，所以它可以保存自己所属的会话；关闭函数返回之后，这个调用返回 nil。

#### Function: etaf-app-buffer (name)

返回已打开应用 NAME 的缓冲区，没有则返回 nil。

**语义。** 入口命令若应回到已打开的应用而不是重新打开，就先检查它，再选中它返回的缓冲区。

## 应用声明与注册表

<!-- index: 应用注册表; etaf-app-define; etaf-app-register; etaf-app-launch -->

基于 ETAF 的应用往往需要运行在多种宿主中而不必感知任何具体宿主：独立 Emacs 缓冲区（`etaf-app-open`）、桌面窗口管理器、浮动子框面板或统一启动器。应用注册表是一层极薄的元数据与会话生命周期契约，把应用和宿主解耦：每个应用只声明自己的身份、支持的宿主、可选的可嵌入 `:session` 回调（`:create`、`:view`、`:close`）与默认布局建议，各宿主直接读取注册表而不硬编码任何应用名。函数字段接受尚未加载的符号，因此各包可以通过 `;;;###autoload` 配合 `with-eval-after-load` 零启动开销地注册清单，直到真正打开时才加载 `:feature`。

#### Function: etaf-app-register (id &rest spec)

用关键字 plist SPEC 注册或更新 ETAF 应用清单 ID。

**参数。**

- ID 是标识应用的非 nil、非关键字符号。
- SPEC 是关键字 plist，包含必填非空字符串 `:title`，可选 `:feature` 符号（默认与 ID 相同）、`:icon` 字符串、`:category`（`media`、`reading`、`productivity`、`communication`、`game`、`system`、`utility` 或 `other`，默认 `other`）、`:description` 字符串、`:hosts`（`(buffer desktop panel pip)` 的非空子集；带 `:session` 时默认为 `(buffer desktop panel)`，否则为 `(buffer)`）、`:open` 可调用符号或函数、`:session` 关键字 plist（必填可调用引用 `:create` 与 `:view`，可选 `:close`、`:keep-alive` 与 `:multiple-instances`）、`:window` 桌面窗口建议 plist、`:panel` 浮动面板建议 plist、`:file-extensions` 字符串列表、`:capabilities` 符号列表及 `:doctor` 可调用引用。

**语义。** 注册时立即校验所有键名与类型，把归一化后的清单写入全局注册表（重复注册同一 ID 原地替换），并以 `(register ID ENTRY)` 运行 `etaf-app-change-functions`。在 `:hosts` 中声明 `desktop` 或 `panel` 时必须提供合法的 `:session`。

**返回。** 归一化应用清单的独立副本。

**错误。** 非法 ID、未知键、缺少 `:title`、不支持的 `:hosts` 或 `:category`、声明嵌入宿主却缺 `:session`、或回调不可调用时触发 `error→ etaf-runtime-error`。

#### Macro: etaf-app-define (id &rest spec)

以声明式语法注册 ETAF 应用 ID 及其关键字清单 SPEC。

**语义。** 展开为 `(etaf-app-register 'ID SPEC...)`，方便各包在 `with-eval-after-load 'etaf` 中简洁声明自身。

**返回。** `etaf-app-register` 返回的独立清单副本。

#### Function: etaf-app-unregister (id)

从注册表中移除已注册的 ETAF 应用 ID。

**语义。** ID 存在时将其移除，并以 `(unregister ID nil)` 通知 `etaf-app-change-functions`。

**返回。** ID 原先存在返回 t，否则返回 nil。

**错误。** ID 不是合法应用符号时触发 `error→ etaf-runtime-error`。

#### Function: etaf-app-get (id)

返回已注册应用 ID 的独立清单 plist，不存在则返回 nil。

**返回。** 独立清单 plist 或 nil。

#### Function: etaf-app-list (&optional host category)

返回按 ID 排序的全部已注册 ETAF 应用独立清单。

**参数。** 可选 HOST 按 `:hosts` 过滤（`buffer`、`desktop`、`panel` 或 `pip`）；可选 CATEGORY 按 `:category` 过滤。

**返回。** 按 ID 字母序排列的独立清单 plist 列表。

**错误。** HOST 或 CATEGORY 非 nil 且不受支持时触发 `error→ etaf-runtime-error`。

#### Function: etaf-app-launch (id)

在独立缓冲区中启动已注册的 ETAF 应用 ID。

**语义。** 交互调用时在已注册应用中补全选择。若 `:feature` 尚未加载则按需 `require`；若声明了 `:open` 则调用它，否则调用 `:session` 的 `:create` 与 `:view` 并经 `etaf-app-open`（`:mode-line t`）打开，同时把 `:close` 接入 `:on-close`。

**返回。** `:open` 的返回值或新打开的应用缓冲区。

**错误。** 交互调用且无已注册应用时触发 `error→ user-error`；ID 未知或既未声明 `:open` 也未声明 `:session` 时触发 `error→ etaf-runtime-error`。

#### Hook: etaf-app-change-functions

应用注册表变化时以 `(EVENT ID ENTRY)` 运行的钩子。

**语义。** EVENT 为 `register` 或 `unregister`，ID 为应用符号，ENTRY 为独立清单 plist（移除时为 nil）。单个观察者的错误被隔离。

## 适配窗口

<!-- index: 适配; 尺寸变化; 显示窗口; 固定视口 -->

应用在 ON-FIT 里让内容适配窗口：页面大小、行数预算、列宽，或者为画布有固有尺寸的应用设定固定视口。函数接收显示窗口并读取它的正文尺寸；它写 ref，View 据此渲染。

挂载之后，ON-FIT 每次稳定下来的变化运行一次：拖动窗口时 Emacs 会多次报告尺寸变化，引擎等这些变化停下来再重新适配 Runtime。随后 ON-FIT 在一个响应式批次里运行，排在 Runtime 自己的视口更新之后，所以重新适配与应用的改动一起发布。显示窗口的正文宽度或高度变化、缓冲区换到另一个窗口、文字缩放变化时它都会运行。minibuffer 或回显区消息临时占用窗口的行时它不运行，因为它们一关闭空间就回来了；重新适配会让内容跳动两次。

以固定 `:viewport-width` 或 `:viewport-height` 挂载的应用仍会收到 ON-FIT，所以可以在里面用新尺寸调用 `etaf-refit`。

## 主题与画布

<!-- index: 画布; default face; 应用背景 -->

View 只绘制它画出的单元格。窗口其余部分（例如短 View 下面的行，或窄 View 的右边缘）显示缓冲区的 default face。BACKGROUND 与 FOREGROUND 让这些单元格与应用一致：传入根 Host 使用的同一组主题颜色；主题可能在应用打开期间变化时，传 ref 或函数。重映射只属于应用缓冲区，并在应用关闭时结束。

## 按键

<!-- index: 应用按键; 根 :keys -->

应用在根 Host 的 `:keys` 里声明它的命令，见[键盘](keyboard.md#host-键)；它不安装自己的 keymap。根上的键出现在帮助里，让位于更近的 Host 与模态作用域，也不会破坏框架键。两条解析规则让根上的键足够应用使用。

- 根上的 RET 作用于应用的选中项，但比根更近的聚焦按钮仍会收到 RET。
- 指针事件（例如 `<wheel-down>`）从指针下的 Host 开始解析，所以一个窗格可以用自己的滚轮绑定滚动自己。

## 跨应用活动与通知

<!-- index: 活动; 实时活动; 通知; 跨应用协议 -->

应用常常需要把持续进行的后台工作或瞬时事件汇报给悬浮灵动岛、桌面顶栏或屏保等系统外壳，而又不依赖任何具体外壳包。ETAF 为此提供两组响应式注册表：承载持续状态的实时*活动*（`media`、`timer`、`task`、`inbox`、`schedule` 或 `status`），以及承载瞬时提醒的*通知*。发布者只提交纯数据与动作回调，外壳通过共享响应式 ref 订阅，无需轮询。

#### Function: etaf-activity-publish (id plist)

用 PLIST 发布或更新跨应用实时活动 ID。

**参数。**

- ID 为非 nil 符号、非空字符串或 cons 单元，按 `equal` 比较。
- PLIST 为合法 plist，必填非空字符串 `:title`，可选 `:app`、`:kind`（`media`、`timer`、`task`、`inbox`、`schedule` 或 `status`，默认 `status`）、`:state`（`active`、`paused` 或 `idle`，默认 `active`）、`:priority`（数值，默认 50）、`:subtitle`、`:compact`、`:icon`、`:tone`（`info`、`success`、`warning`、`danger` 或 `neutral`）、`:progress`（plist）、`:meter`（电平采样函数）、`:actions`（动作 plist 列表，每项含 `:id` 符号、`:label` 字符串与 `:fn` 函数）、`:open`（零参打开函数）以及 `:owner-runtime`（已挂载 Runtime，其卸载时自动移除 ID）。

**语义。** 当忽略 `:updated-at` 后载荷与现有记录一致时跳过发布，避免无变化的后台轮询触发多余重绘。否则更新 `etaf-activity-ref` 并以 `(publish ID ENTRY)` 运行 `etaf-activity-change-functions`。

**返回。** 已存储活动 plist 的独立副本。

**错误。** 非法 ID、非 plist、缺少 `:title`、不支持的 `:kind`、`:state`、`:tone` 或非法 `:actions` 触发 `error→ etaf-runtime-error`。

#### Function: etaf-activity-remove (id)

移除跨应用实时活动 ID，若此前存在则返回非 nil。

**语义。** 移除已存在条目时会更新 `etaf-activity-ref` 并以 `(remove ID nil)` 通知 `etaf-activity-change-functions`。

**返回。** ID 原先存在时返回 t，否则返回 nil。

#### Function: etaf-activity-get (id)

返回跨应用实时活动 ID 的独立副本，不存在则返回 nil。

**返回。** 独立活动 plist 或 nil。

#### Function: etaf-activity-list (&optional kind)

返回按序排列的实时活动独立快照，可选按 KIND 过滤。

**语义。** `active` 活动排在 `paused` 之前，`paused` 排在 `idle` 之前；同级按 `:priority` 降序及最新 `:updated-at` 排列。

**返回。** 独立活动 plist 列表。

**错误。** KIND 非 nil 且不是受支持的活动类型时触发 `error→ etaf-runtime-error`。

#### Function: etaf-activity-ref ()

返回承载有序实时活动快照的共享响应式 ref。

**返回。** 随活动发布或移除自动更新的响应式 ref。

#### Function: etaf-activity-invoke (id action-id)

调用实时活动 ID 声明的动作 ACTION-ID（或 `open`）。

**语义。** ACTION-ID 为 `open` 时查找 `:open`，否则在 `:actions` 中按 `:id` 查找，并零参调用其函数。

**返回。** 动作函数的返回值。

**错误。** ID 未知或未声明对应动作时触发 `error→ etaf-runtime-error`。

#### Hook: etaf-activity-change-functions

实时活动发生变化时以 `(EVENT ID ENTRY)` 运行的钩子。

**语义。** EVENT 为 `publish` 或 `remove`，ID 为活动键，ENTRY 为独立活动 plist（移除时为 nil）。单个观察者的错误被隔离。

#### Function: etaf-notify (title &key id app detail (variant 'info) (ttl 5.0) group actions)

向 ETAF 外壳消费者发布通知 TITLE，并返回独立条目副本。

**参数。**

- TITLE 为非空字符串。
- ID 可选指定稳定标识，省略时自动分配递增整数。
- APP 为可选来源符号。
- DETAIL 为可选补充说明文本。
- VARIANT 为 `info`、`success`、`warning` 或 `danger`（默认 `info`）。
- TTL 为自动折叠秒数（非负数，默认 5.0；0 表示不自动折叠）。
- GROUP 为可选分组键，按 `equal` 比较；命中已有条目时原地替换并递增 `:count`。
- ACTIONS 为可选动作 plist 列表（`:id`、`:label`、`:fn`）。

**语义。** 将条目插入有界通知历史、更新 `etaf-notify-ref` 并运行 `etaf-notify-functions`。交互会话中若 `etaf-notify-functions` 为空，自动回退到 `message` 以防提醒丢失。

**返回。** 通知 plist 的独立副本。

**错误。** 空 TITLE、非法 VARIANT、负 TTL 或非法 ACTIONS 触发 `error→ etaf-runtime-error`。

#### Function: etaf-notify-dismiss (&optional id)

忽略通知 ID（为 nil 时忽略最新一条）并返回剩余列表。

**返回。** 剩余通知的独立列表，最新在前。

#### Function: etaf-notify-clear ()

清空全部已存储的 ETAF 通知并返回 nil。

**返回。** nil。

#### Function: etaf-notify-list ()

返回已存储 ETAF 通知的独立列表，最新在前。

**返回。** 独立通知 plist 列表。

#### Function: etaf-notify-ref ()

返回承载已存储 ETAF 通知的共享响应式 ref。

**返回。** 承载独立通知列表的响应式 ref。

#### Hook: etaf-notify-functions

`etaf-notify` 记录通知时以 `(ENTRY)` 运行的钩子。

**语义。** 单个观察者的错误被隔离。安装至少一个观察者后即抑制回显区 `message` 回退。

## 悬浮画中画

<!-- index: etaf-pip-open; etaf-pip-close; etaf-pip-bounds; 画中画; 子帧 -->

视频与监控类应用常常需要在用户切回其他缓冲区时保留一个置顶小窗。`etaf-pip-open` 把任意 View 宿主在一个可复用的悬浮子帧里，自带原生可拖拽自适应顶栏、4 像素可拖缩放边框、焦点响应边框色、四角停靠、小/中/大预设，以及不锁定视口的实时尺寸同步，让手工拖拉宽高时界面布局与内嵌原生 GPU 视频层同步自适应。

#### Function: etaf-pip-open (id view &key title parent (size 'medium) (corner 'bottom-right) theme on-return on-close on-resize on-size-change on-corner-change)

为符号 ID 打开显示 VIEW 的悬浮自适应画中画窗口。

**参数。** ID 为标识画中画宿主的非 nil 符号；VIEW 为待挂载视图。TITLE 为顶栏标题（字符串、ref、computed 或零参函数）。PARENT 为所属顶层 frame（默认当前 frame）。SIZE 为 `small`、`medium`（默认）或 `large`；CORNER 为 `bottom-right`（默认）、`bottom-left`、`top-left` 或 `top-right`。THEME 为颜色 plist 或零参函数，提供 `:bg`、`:panel`、`:chip`、`:hover`、`:ink`、`:muted`、`:accent`、`:accent-soft` 与 `:border-inactive`。ON-RETURN、ON-CLOSE、ON-RESIZE、ON-SIZE-CHANGE 与 ON-CORNER-CHANGE 为可选回调。

**语义。** 若 ID 已处于打开状态则先关闭旧宿主。图形环境下会把 View 挂载到复用的无装饰子帧中且不锁定视口尺寸，让 Ebox 与 `etaf-pip-bounds` 实时跟随任意边角拖拽并同步原生 GPU 视频层；非图形环境下仍会挂载缓冲区并维护实时尺寸以便测试覆盖完整生命周期。

**返回。** 已挂载的画中画缓冲区。

**错误。** ID 不是非 nil 符号时触发 `wrong-type-argument`。

#### Function: etaf-pip-close (id &optional restore-focus)

关闭悬浮画中画窗口 ID，若此前处于打开状态则返回非 nil。

**语义。** 执行一次 ON-CLOSE，卸载并销毁画中画缓冲区，将图形子帧停放进复用池；当 RESTORE-FOCUS 非 nil 或画中画正持有焦点时把输入焦点交回父 frame。

**返回。** ID 原先存活时返回 `t`，否则返回 nil。

#### Function: etaf-pip-active-p (id)

当悬浮画中画窗口 ID 当前存活时返回非 nil。

**返回。** 存活返回 `t`，否则返回 nil。

#### Function: etaf-pip-bounds (id)

返回悬浮画中画窗口 ID 的响应式实时内部尺寸 plist。

**语义。** 返回 `(:width-px W :height-px H :cols C :rows R :cell-w CW :cell-h LH :size SIZE :corner CORNER)`，关闭时返回 nil。在 Component 的 `:render` 中读取它会自动订阅每次手工拖拽缩放与预设切换。

**返回。** 尺寸 plist 或 nil。

#### Function: etaf-pip-frame (id)

返回悬浮画中画窗口 ID 对应的悬浮子帧，未打开或非图形环境返回 nil。

**返回。** 存活的 frame 或 nil。

#### Function: etaf-pip-buffer (id)

返回悬浮画中画窗口 ID 对应的已挂载缓冲区，未打开时返回 nil。

**返回。** 存活的缓冲区或 nil。

#### Function: etaf-pip-cycle-size (id)

在 `small`、`medium` 与 `large` 预设间循环切换画中画窗口 ID 的尺寸。

**语义。** 按下一预设调整窗口尺寸并重新停靠到当前角落，更新 `etaf-pip-bounds` 并触发 ON-SIZE-CHANGE。

**返回。** 新的尺寸符号；ID 未打开时返回 nil。

#### Function: etaf-pip-cycle-corner (id)

将画中画窗口 ID 顺时针停靠到父 frame 的下一个角落。

**语义。** 按 `(bottom-right bottom-left top-left top-right)` 顺时针移动悬浮窗同时保留用户手动拖拽后的尺寸，并触发 ON-CORNER-CHANGE。

**返回。** 新的角落符号；ID 未打开时返回 nil。

#### Function: etaf-pip-refresh-chrome (id)

重绘画中画窗口 ID 的背景、边框与自适应顶栏。

**语义。** 重新求值 THEME 与 TITLE，同步更新窗口配色、边框色与可拖拽顶栏。

**返回。** ID 存活时返回 `t`，否则返回 nil。

## 两档全屏管理

<!-- index: etaf-fullscreen-mode; etaf-fullscreen-enter; etaf-fullscreen-exit; etaf-fullscreen-toggle; 全屏 -->

视频播放器、阅读器与演示类应用常常需要无干扰全屏，但又不能永久破坏用户的 Emacs 分屏布局或 `mode-line`。ETAF 将全屏拆成清晰的两档：`window`（网页全屏）在当前窗口内临时隐藏 `mode-line` 而不惊动分屏与系统桌面空间；`frame`（系统真全屏）暂存当前分屏配置与 frame 的 `fullscreen` 参数，独占整帧并在图形环境下切入系统全屏，退出或关闭缓冲区时原样还原一切。

#### Function: etaf-fullscreen-mode (&optional buffer)

返回 BUFFER 的响应式全屏模式：nil、`window` 或 `frame`。

**参数。** BUFFER 默认为当前缓冲区。

**语义。** 在 Component 的 `:render` 中读取该函数会自动订阅全屏切换，从而在不卸载重装 `<etaf-video>` 等有状态节点的前提下原地扩缩画布。

**返回。** `window`、`frame` 或 nil。

#### Function: etaf-fullscreen-active-p (&optional buffer)

当 BUFFER 当前处于 `window` 或 `frame` 全屏模式时返回非 nil。

**参数。** BUFFER 默认为当前缓冲区。

**返回。** 处于全屏时返回 `t`，否则返回 nil。

#### Function: etaf-fullscreen-enter (&optional mode buffer &key (hide-mode-line t) on-change)

让 BUFFER 进入全屏 MODE（`window` 或 `frame`）。

**参数。** MODE 默认为 `window`，BUFFER 默认为当前缓冲区。HIDE-MODE-LINE 非 nil（默认 `t`）时暂存并临时隐藏 `mode-line-format`。ON-CHANGE 为可选回调，在模式变化时接收新模式符号。

**语义。** 进入 `frame` 时会先记录分屏布局与原 `fullscreen` 参数，再合并窗口并在图形环境下切至 `fullboth`；从 `frame` 直接切到 `window` 会还原分屏与系统全屏但保留隐藏 `mode-line`。每次切换都会执行多阶段视口重算与原生 GPU 视频层同步，并挂载缓冲区关闭钩子防止异常残留。

**返回。** 进入的目标模式符号（`window` 或 `frame`）。

**错误。** MODE 既非 `window`/`frame` 也非 nil，或 BUFFER 类型非法时触发 `wrong-type-argument`。

#### Function: etaf-fullscreen-exit (&optional buffer)

退出 BUFFER 的全屏状态，还原 `mode-line`、分屏配置与系统全屏参数。

**参数。** BUFFER 默认为当前缓冲区。

**语义。** 未处于全屏时调用幂等无副作用；退出时按原样恢复 `mode-line-format`（原为继承值时移除局部变量），并还原分屏布局、系统全屏状态与画布重算。

**返回。** nil。

#### Function: etaf-fullscreen-toggle (&optional mode buffer &key (hide-mode-line t) on-change)

切换 BUFFER 的全屏 MODE（`window` 或 `frame`）。

**参数。** MODE 默认为 `window`，BUFFER、HIDE-MODE-LINE 与 ON-CHANGE 同 `etaf-fullscreen-enter`。

**语义。** 若 BUFFER 已处于 MODE 则退出全屏；若处于普通模式或另一档全屏则直接切入 MODE。

**返回。** 切换后的模式符号（`window`、`frame` 或 nil）。

## 错误与恢复

打开从不留下半开的应用：某一步失败时，关闭函数运行、缓冲区被杀掉、条件向外传播，调用者可以修正原因后再次打开。关闭函数不应该发出信号；如果发出了，`etaf-app-close` 在缓冲区消失之后报告该错误，杀掉缓冲区则以消息报告它。无论哪种情况，应用都已关闭，它的名字可以再次打开。

Emacs 退出时关闭函数不运行。状态必须跨会话保留的应用还要在 `kill-emacs-hook` 里保存它。
