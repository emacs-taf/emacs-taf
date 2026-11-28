# Action、Behavior 与错误边界

有三样东西承载应用行为，却不新增 View 节点：*Action* 是通过 Runtime 派发的具名业务变更；*Behavior* 是可复用的非视觉 Host 属性集合，可选带安装函数；*错误边界* 是把某个抛出的错误变成一个值的显式位置。本章定义两个定义宏与构造函数、Action 如何派发与重定义、Behavior 如何安装、保留或替换自己、用于焦点、开关、拖拽与缩放的内置 Behavior，以及它们抛出的两个条件。

三者都不是 View 节点，也都不渲染：Action 改变应用状态、让响应式系统去发布；Behavior 通过 `:use` 贡献 Host 属性，并在它挂上的 Host 旁边安装代码；错误边界只决定处理哪个条件。Host 属性（包括 `:use`）属于 [Host](hosts.md#property-use)；Action 的写入所发布的树属于[响应式系统](reactivity.md)；透传与重定义的组件一侧属于[组件](components.md)。

<!-- index: Action; Behavior; 错误边界; :use; 安装函数; 清理 -->

## 模型

### Action

Action 是一个业务变更的具名、可测试入口。它以普通符号登记在进程级的表里，并且通过 Runtime 而不是直接调用来触发：`etaf-dispatch` 解析出 Runtime，在一次响应式批处理里把该 Runtime 作为第一个参数调用 Action 的函数，并返回函数返回的东西。由于调用是一次批处理，Action 的每次写入都在它返回时一起发布。Action 既不是节点也不是按键绑定；Host 的 `:on-press` 回调或某个键命令想用它时才调用 `etaf-dispatch`。

### Behavior

Behavior 是规格，不是节点：一个名字、一组语义属性，以及一个可选的*安装函数*。它通过 `:use` 属性到达 Host，而 `:use` 接受构造函数符号、规格或它们的 proper 列表。Host 解析属性时，每个来源解析成一个规格，规格的属性按 [Host](hosts.md#值与冲突)定义的规则合并进 Host 属性：事件回调与 `:disabled` 组合，Host 自己的键在前，其它属性只在 Host 没说的地方补入。之后可选的安装函数为该 Host 运行一次：它可以打开资源，必须返回一个清理函数；该清理函数在 Behavior 被移除、被替换、随 Host 被禁用或卸载时运行。Host 上就地写的 `:on-*` 回调仍是一次性交互的简单选择；只有当同一组东西会被复用、需要带安装函数、或由库提供时，才值得做成 Behavior。

### 错误边界

错误边界回答一个问题：这次调用抛出的错误该怎么办。`etaf-error-boundary-run` 调用一个函数，在它抛出时把原始条件交给处理函数，处理函数的返回值就是边界的结果。这是在一个显式选定点上的收容，不是错误策略：被包裹调用之外抛出的、以及处理函数自己抛出的，都不被捕获。

## Action

#### Macro: etaf-action-define (name arguments &rest body)

用 NAME、ARGUMENTS 和 BODY 定义并登记具名 Action。

**参数。** NAME 是普通符号：非 nil、非 keyword、且尚未登记。ARGUMENTS 是普通函数参数表；Action 被派发时，它的第一个参数是 Runtime。BODY 是 Action 的函数体，可以以 docstring 开头。

**语义。** 宏为 Action 定义一个函数、把它以 NAME 登记进进程级 Action 表，并展开为引用的 NAME。已登记的 NAME 会被拒绝，除非定义发生在 `etaf-action-redefine-run` 里。Action 的函数只经 `etaf-dispatch` 调用，由后者补上 Runtime 作为第一个参数并在一个批处理里运行。渲染期定义 Action 会被拒绝：登记是副作用。

**返回。** NAME，引用后的符号，所以定义形式求值为 NAME。

**错误。** NAME 已登记时 `error→ etaf-action-error`，消息 `"Duplicate ETAF Action: %S"`；NAME 是 keyword 或不是普通符号时消息 `"Invalid Action registration: %S"`。定义发生在渲染期时 `error→ etaf-render-side-effect-error`，数据为 `(register-action)`。

**示例。** 往调用方自己的列表 ref 里加一项的 Action。

```elisp
(etaf-action-define demo-add (runtime tasks title)
  (ignore runtime)
  (etaf-set-value tasks (cons title (etaf-value tasks))))
```

**参见。** `etaf-dispatch`、`etaf-action-redefine-run`，以及[组件](components.md)关于回调内批处理的说明。

#### Function: etaf-dispatch (action &rest arguments)

通过活动 Runtime 派发具名 ACTION，参数为 ARGUMENTS。

**参数。** ACTION 是已登记的 Action 名；也可以把 Runtime 显式作为第一个参数传入：`(etaf-dispatch RUNTIME ACTION ...)`。ARGUMENTS 在 Runtime 之后传给 Action 的函数，而 Runtime 永远是第一个参数。

**语义。** 调用解析出 Runtime--显式传入的那个,或动态活动的那个(事件回调与生命周期代码里可用)--并在一次 `etaf-call-with-batch` 里以 `(RUNTIME ARGUMENTS...)` 运行 Action 的函数。Action 的写入在调用返回时一起发布;返回值就是函数的返回值。重定义之后,未来的派发用新函数,因为表是在派发时查的。Runtime 装了 observer 时,这次派发会作为一次被观测的操作上报,见[增量更新与发布](incremental-updates-and-publication.md)章。

**返回。** Action 函数的返回值。

**错误。** ACTION 没有对应的已登记 Action 时 `error→ etaf-action-error`，消息 `"Unknown ETAF Action: %S"`；ACTION 不是符号时消息 `"Action name must be a symbol"`。既没有显式 Runtime、也没有活动且已挂载的 Runtime 时 `error→ etaf-runtime-error`，消息 `"ETAF runtime is not mounted"`。渲染期调用 `error→ etaf-render-side-effect-error`，数据为 `(dispatch-action)`。Action 函数体抛出的错误在批处理排空之后传播；出错之前做出的写入保留。

**示例。** 按钮回调按名派发；也可以带显式 Runtime 直接派发。

```elisp
(etaf-dispatch 'demo-add tasks "Write tests")
(etaf-dispatch runtime 'demo-add tasks "Review diff")
```

**参见。** `etaf-action-define`、`etaf-action-redefine-run` 与[响应式系统](reactivity.md#批处理与-tick)。

#### Function: etaf-action-redefine-run (function)

在允许有意重定义 Action 的前提下运行 FUNCTION。

**参数。** FUNCTION 是零参函数。其它值 `wrong-type-argument`，数据为 `(functionp FUNCTION)`。

**语义。** 调用期间，`etaf-action-define` 可以替换已登记的 Action 而不是报错。替换只改变未来 `etaf-dispatch` 调用所用的进程级名字绑定：它不 flush、不重渲染、也不重启已挂载的 Runtime，而且已经开始的调用继续用它解析到的那个函数。作者工具与测试工具刻意重定义 Action 时用它。

**返回。** FUNCTION 的返回值。

**错误。** FUNCTION 不是函数时 `error→ wrong-type-argument`。FUNCTION 内部的错误原样传播，表停在失败发生时的状态。

**示例。** 测试工具重定义一个 Action 来观察一次调用。

```elisp
(etaf-action-redefine-run
 (lambda () (etaf-action-define demo-add (runtime tasks title)
              (ignore runtime tasks title)
              'observed)))
```

**参见。** `etaf-action-define` 与[组件](components.md)的 `etaf-component-redefine-run`。

## Behavior

### 定义 Behavior

#### Macro: etaf-define-behavior (name arguments &rest body)

用 NAME、ARGUMENTS 和 BODY 定义普通 Behavior 构造函数。

**参数。** NAME 是非 nil、非 keyword 的符号。ARGUMENTS 是 `defun` 接受的普通参数表：用 `&optional` 与 `&rest`；`(&key ...)` 这样的 keyword 参数表不支持。BODY 是构造函数体，可以以 docstring 开头。

**语义。** 宏是函数定义的便利：它定义一个普通函数，函数体必须返回 `etaf-behavior-create` 造出的数据；通常函数体以那次调用收尾。`:use` 接受构造函数符号的地方都按名解析该函数，所以它在定义前或定义后都能用；它在该 Host 解析 `:use` 属性时被调用。这不是第二套运行时或节点模型：构造函数只造规格，在别的用途上就是普通函数。

**返回。** 被定义的构造函数被调用时返回的东西。

**示例。** 规格带 role 的构造函数。

```elisp
(etaf-define-behavior demo-status (&rest attributes)
  (apply #'etaf-behavior-create 'demo-status
         (append attributes (list :role 'status))))
```

**参见。** `etaf-behavior-create` 与 `etaf-define-component`。

#### Function: etaf-behavior-create (name &rest attributes)

从关键字 ATTRIBUTES 创建名为 NAME 的 Behavior 规格。

**参数。** NAME 是普通符号。ATTRIBUTES 是关键字/值对；每个键都是关键字，同一个键不能重复。保留的 `:install` 属性是可选的零参安装函数；其它属性都是要送到 Host 的语义或样式属性。

**语义。** 调用校验输入并返回一个规格，携带名字、语义属性与安装函数。`:install` 不合并进 Host 属性；它是 Behavior 自己的代码。同一 Host 上重名 Behavior 在 Host 解析 `:use` 时才被拒绝，不在这里。

**返回。** 一个 Behavior 规格。

**错误。** `error→ etaf-behavior-error`，一条消息字符串：NAME 是 keyword 或非符号时 `"Behavior name must be a symbol: %S"`；ATTRIBUTES 不是 proper 偶长表时 `"Behavior attributes must be keyword/value pairs"`；键不是关键字时 `"Behavior attribute must be a keyword: %S"`；键重复时 `"Duplicate Behavior attribute: %S"`；安装函数非函数时 `":install must be a function or nil"`。

**示例。** 一个可以经 `:use` 挂到 Host 上的规格。

```elisp
(etaf-behavior-create 'demo-badge :role 'status :aria-label "build")
```

**参见。** `etaf-define-behavior` 与 [Host](hosts.md#property-use)。

### 安装 Behavior

带 `:install` 属性的 Behavior 每为一个 Host 安装一次，就运行一次该函数。安装函数不接收参数，可以返回 nil 或一个清理函数；其它返回值是错误。它在渲染之外运行，下面两个函数在其中可用。

#### Function: etaf-current-behavior-context ()

返回安装函数运行期间活动的 Behavior 上下文，否则返回 nil。

**语义。** 某个 Behavior 安装函数运行时调用返回上下文对象，其它时候（包括另一个 Behavior 的清理函数里）返回 nil。把结果交给 `etaf-behavior-context-info` 读安装事实。

**返回。** 一个 Behavior 上下文，或 nil。

#### Function: etaf-behavior-context-info (context)

把 CONTEXT 的安装事实作为新的 plist 返回。

**参数。** CONTEXT 是安装函数运行期间 `etaf-current-behavior-context` 的返回值。其它值 `etaf-behavior-error`。

**语义。** 结果有三个键：`:runtime`，所属 Runtime；`:host-ref`，Host 的有效引用（来自 Host 的 `:ref` 或自动生成）；`:properties`，安装时的语义 Host 属性，并补上该引用。plist 与属性容器每次调用都是新的，内含值保持 identity、对调用方只读。事实在清理之后仍可读，但它们不保证 Host 仍挂载、也不保证属性仍然最新：需要当前状态时用 Runtime 的已提交查询，例如 `etaf-runtime-host-props-for`。

**返回。** 含 `:runtime`、`:host-ref`、`:properties` 的 plist。

**错误。** CONTEXT 不是 Behavior 上下文时 `error→ etaf-behavior-error`，消息 `"Expected a Behavior installation context"`。

**示例。** 安装函数为 Host 引用打开一个订阅，并返回它的清理。

```elisp
(etaf-behavior-create 'demo-watch
  :install (lambda ()
             (let* ((context (etaf-current-behavior-context))
                    (ref (plist-get (etaf-behavior-context-info context) :host-ref)))
               (subscribe ref))
             (lambda () (unsubscribe))))
```

**参见。** `etaf-current-behavior-context`、`etaf-runtime-host-props-for` 与 [Runtime](runtime.md#内省)。

### 内置 Behavior

#### Function: etaf-focusable (&rest attributes)

从 ATTRIBUTES 返回一个可聚焦 Behavior。

**参数。** ATTRIBUTES 原样交给 `etaf-behavior-create`，只有 tab stop 例外。

**语义。** ATTRIBUTES 不含 `:tab-index` 时，Behavior 补上标准的第一站 `0`，让 Host 参与 Tab 导航；显式 `:tab-index nil` 把它排除在外。其余属性照常属于 Host。由此产生的停靠点如何导航，见[键盘](keyboard.md)与[焦点](focus.md)章。

**返回。** 名为 `focusable` 的 Behavior 规格。

**错误。** `etaf-behavior-create` 的错误，外加调用方补入的属性自带的错误。

**示例。** `(text :use (list (etaf-focusable)) "Open")`

**参见。** [焦点](focus.md)与 [Host](hosts.md#无障碍与焦点)。

#### Function: etaf-toggleable (&rest attributes)

返回一个把 ATTRIBUTES 转成开关式按下动作的 Behavior。

**参数。** `:value` 是当前值，可以是 ref、计算值或普通值；`:on-change` 是收到下一个值调用的函数，必须有。其余 ATTRIBUTES 保留在返回的 Behavior 里。

**语义。** `:value` 与 `:on-change` 配置动作、不作为属性保留；Behavior 挂上一个按下处理函数，用当前值的取反调用 ON-CHANGE。`:value` 是 ref 或计算值时在按下时用 `etaf-value` 读取，所以开关跟随该源；普通值沿用构造时的值。调用本身不改值：由 ON-CHANGE 决定写什么。

**返回。** 名为 `toggleable` 的 Behavior 规格，属性是其余 ATTRIBUTES 加按下处理函数。

**错误。** `:on-change` 缺失或不是函数时 `error→ etaf-behavior-error`，消息 `"toggleable requires a function-valued :on-change"`；其余属性报 `etaf-behavior-create` 的错误。

**示例。** 一个自己拥有状态的设置行开关。

```elisp :run
(etaf-define-component demo-setting-row (&key label)
  :bindings ((enabled (etaf-ref nil))
             (behavior (etaf-toggleable
                        :value enabled
                        :on-change (lambda (next) (etaf-set-value enabled next)))))
  :view (row :item-gap '(ch 2)
             (text :font-weight 'bold (expr label))
             (box :ref 'switch :use (list behavior)
                  (text (expr (if (etaf-value enabled) "[on]" "[off]"))))))

(etaf-view (demo-setting-row :label "Notifications"))
```

**参见。** [Host](hosts.md#property-use)、[事件](events.md)与[组件](components.md#setup绑定与-state)。

#### Function: etaf-draggable (&key x y axis delta on-start on-move on-end on-cancel)

返回一个 Behavior，用 Ebox 拖拽位移移动调用方拥有的数值坐标 ref。

**参数。** X 与 Y 是可写的 `etaf-ref`，保存数值逻辑坐标；所选 AXIS 至少要有一个。AXIS 是 `x`、`y` 或 `both`；nil 时给了两个 ref 就推断 `both`，否则用给了的那个。DELTA 是可选函数，接收手势并返回 `(DX . DY)` cons，供坐标单位不是 Ebox 像素的调用方使用。ON-START、ON-MOVE、ON-END 与 ON-CANCEL 是可选的单参函数，参数是手势 plist。

**语义。** Behavior 消费 Host 的 `:on-drag` 手势。`start` 时记录各 ref 的当前值；`move` 与 `end` 时把每个被选中的 ref 写成记录的原点加位移，拖拽因此跟随手势；回调在这些写入之后运行，`cancel` 不改任何坐标。手势本身不在这里拥有窗口或指针状态：Ebox 保留手势目标，ETAF 的普通响应式发布根据 ref 更新 Host，由调用方把 ref 映射成几何。Behavior 还会贡献按键，沿所选轴每次按键把 Host 移动一格：`x` 用 `M-<left>` 与 `M-<right>`，`y` 用 `M-<up>` 与 `M-<down>`，`both` 用四个。移动 Behavior 与缩放 Behavior 要挂在不同的 Host 上，因为一个 Host 的拖拽处理函数都会收到每个手势。

**返回。** 名为 `draggable` 的 Behavior 规格。

**错误。** `error→ etaf-behavior-error`，一条消息字符串：没有坐标 ref 时 `"etaf-draggable requires :x or :y"`；axis 不是 x、y、both 时 `"Invalid draggable axis: %S"`；x 与 y 是同一个 ref 时 `"etaf-draggable :x and :y must be distinct refs"`；坐标不是 ref 时 `"%s must be a writable `etaf-ref': %S"`；回调或 DELTA 既不是函数也不是 nil 时 `"%s must be a function or nil: %S"`。手势里的位移非法时在派发期间抛出。

**示例。** 自己拥有 x 坐标的拖拽手柄。

```elisp
(etaf-draggable :x position :axis 'x :on-end (lambda (_gesture) (commit position)))
```

**参见。** `etaf-draggable-controlled`、[拖拽与手势](dragging-and-gestures.md)，以及[键盘](keyboard.md)关于所贡献按键的说明。

#### Function: etaf-resizable (&key x y width height edges min-width max-width min-height max-height delta on-start on-resize on-end on-cancel)

返回一个 Behavior，用 Ebox 拖拽位移缩放调用方拥有的数值几何 ref。

**参数。** WIDTH 与 HEIGHT 是保存数值尺寸的可写 `etaf-ref`；X 与 Y 是可选的可写坐标，left 与 top 边需要它们。EDGES 是 `left`、`right`、`top`、`bottom` 中的一个符号或它们的列表，默认 `right` 与 `bottom`。MIN-WIDTH、MAX-WIDTH、MIN-HEIGHT、MAX-HEIGHT 是可选的数值上下界。DELTA、ON-START、ON-RESIZE、ON-END、ON-CANCEL 与 `etaf-draggable` 相同，只是 `:on-resize` 取代 `:on-move`。

**语义。** Behavior 消费 Host 的 `:on-drag` 手势。`start` 时记录当前几何；`move` 与 `end` 时按被拖的边计算下一个尺寸——left 与 top 还会移动 X、Y，让对边固定——按给定上下界限制后写入 ref；回调在写入之后运行，`cancel` 保留最后一次接受的几何。没给的界就是没有界，所以调用方不设最小值时尺寸可以为负。Behavior 在选中水平边时贡献 `M-S-<left>` 与 `M-S-<right>`（Narrower、Wider），选中垂直边时贡献 `M-S-<up>` 与 `M-S-<down>`（Shorter、Taller）。它不含桌面窗口策略，也不调用 Ebox 私有 API。它与任何移动 Behavior 分挂在不同的 Host 上。

**返回。** 名为 `resizable` 的 Behavior 规格。

**错误。** `error→ etaf-behavior-error`，一条消息字符串：边集为空、重复或含 `left`/`right`/`top`/`bottom` 之外的值时 `"Invalid resizable edges: %S"`；所选边需要的尺寸或坐标缺失、或不是 ref 时 `"%s must be a writable `etaf-ref': %S"`；上下界不是数值时 `"%s must be numeric or nil: %S"`；上下界颠倒时 `"etaf-resizable :min-width exceeds :max-width"` 与 `"etaf-resizable :min-height exceeds :max-height"`；以及 `etaf-draggable` 的回调与位移错误。

**示例。** 锚定左上角、可缩放的画板。

```elisp
(etaf-resizable :width width :height height
                :edges '(right bottom)
                :min-width 20
                :on-end (lambda (_gesture) (store-size width height)))
```

**参见。** `etaf-resizable-controlled` 与[拖拽与手势](dragging-and-gestures.md)。

#### Function: etaf-draggable-controlled (read on-change &key axis delta on-start on-move on-end on-cancel)

返回一个针对聚合几何状态的受控拖拽 Behavior。

**参数。** READ 是返回当前几何的函数，几何是带 `:x` 与 `:y` 事实的 plist；ON-CHANGE 是接收下一个独立几何 plist 的函数。AXIS 是 `x`、`y`、`both`，或 nil 表示按 READ 的返回推断。DELTA 与各回调同 `etaf-draggable`。

**语义。** Behavior 不保留持久几何：`start` 时调用一次 READ，把结果留作瞬时手势原点；`move` 与 `end` 时由该原点加位移构造下一个 plist 交给 ON-CHANGE，然后运行回调。调用方的聚合状态是唯一权威，所以它适合几何天然不是四个独立 ref 的管理器。Behavior 要在保留的所有者（例如 `:bindings` 值）里构造一次，不要放进 `:render`：渲染期构造的 Behavior 是新的处理函数 identity，无法跨父级投影保持一个进行中的手势。

**返回。** 名为 `draggable-controlled` 的 Behavior 规格。

**错误。** 回调不是函数时构造期 `error→ etaf-behavior-error`，消息 `"Controlled draggable ON-CHANGE must be a function"`；手势开始而 READ 不可用时消息 `"Controlled geometry READ must be a function"` 与 `"Controlled draggable READ must expose :x or :y"`；READ 返回形状不对时 `"Controlled geometry READ must return a plist"`；以及 `etaf-draggable` 的位移与回调错误。

**示例。** 受控的窗口位置。

```elisp
(etaf-draggable-controlled
 (lambda () (list :x (plist-get state :x) :y (plist-get state :y)))
 (lambda (next) (setq state next)))
```

**参见。** `etaf-draggable` 与[组件](components.md#setup绑定与-state)。

#### Function: etaf-resizable-controlled (read on-change &key edges min-width max-width min-height max-height delta on-start on-resize on-end on-cancel)

返回一个针对聚合 `:x`/`:y`/`:width`/`:height` 状态的受控缩放 Behavior。

**参数。** READ 是返回当前几何的函数，几何是含数值 `:x`、`:y`、`:width`、`:height` 的 plist。ON-CHANGE 是接收下一个独立几何 plist 的函数。EDGES、上下界与 DELTA 同 `etaf-resizable`。

**语义。** `start` 时 Behavior 把 READ 的结果记作手势原点；`move` 与 `end` 时按被拖的边算出下一个几何、应用上下界与 DELTA 换算，把独立 plist 交给 ON-CHANGE，然后运行回调。Behavior 不保留持久的应用几何；构造规则同 `etaf-draggable-controlled`。

**返回。** 名为 `resizable-controlled` 的 Behavior 规格。

**错误。** 构造期回调不是函数时 `error→ etaf-behavior-error`，消息 `"Controlled resizable ON-CHANGE must be a function"`；边集非法时 `"Invalid controlled resize edges: %S"`；上下界报 `etaf-resizable` 的错误；手势开始而 READ 没有给出所选边需要的数值几何时 `"%s must contain a number, got %S"`。

**示例。** 受控的窗口尺寸。

```elisp
(etaf-resizable-controlled
 (lambda () state)
 (lambda (next) (setq state next))
 :min-width 40 :min-height 12)
```

**参见。** `etaf-resizable` 与[组件](components.md#setup绑定与-state)。

### 手势回调

拖拽与缩放 Behavior 接受接收原始 Ebox 手势的回调：手势是 plist，`:phase` 为 `start`、`move`、`end` 或 `cancel`，`:delta` 是像素 `(DX . DY)` cons。move、end 与 resize 回调在 Behavior 写完 ref 或调用受控 ON-CHANGE 之后运行，所以回调读到的是已接受的值。手势被放弃时用 cancel 代替 move，保留最后一次接受的几何。

#### Property: :on-change

`etaf-toggleable` 的下一个值回调。

**参数。** 单参函数，参数是下一个值；必须有。

**语义。** Behavior 的按下处理函数用当前 `:value` 的取反调用它。写什么由回调决定，所以值是 ref 的开关通常用 `etaf-set-value` 或 `etaf-update-value` 写它。

**错误。** 缺失或不是函数时 `error→ etaf-behavior-error`，消息 `"toggleable requires a function-valued :on-change"`。

**参见。** `etaf-toggleable`。

#### Property: :on-start

拖拽与缩放 Behavior 的手势开始回调。

**参数。** 单参函数，参数是手势 plist；可选。

**语义。** 手势开始时运行，此时 Behavior 已记录原点。适合准备或宣告一次手势；不能假设坐标已经改变。

**错误。** 值不是函数时构造期 `error→ etaf-behavior-error`，消息 `"%s must be a function or nil: %S"`。

**参见。** `etaf-draggable` 与 `etaf-resizable`。

#### Property: :on-move

`etaf-draggable` 与 `etaf-draggable-controlled` 的移动回调。

**参数。** 单参函数，参数是手势 plist；可选。

**语义。** 在接受的移动写入 ref、或交给受控 ON-CHANGE 之后运行。回调可以读新值，但不应再启动另一手势。

**错误。** 值不是函数时构造期 `error→ etaf-behavior-error`，消息 `"%s must be a function or nil: %S"`。

**参见。** `etaf-draggable` 与 `etaf-draggable-controlled`。

#### Property: :on-end

拖拽与缩放 Behavior 的手势结束回调。

**参数。** 单参函数，参数是手势 plist；可选。

**语义。** 在最后一次移动或缩放应用之后运行。适合提交结果，例如持久化释放时的几何，或开始一次后续发布。

**错误。** 值不是函数时构造期 `error→ etaf-behavior-error`，消息 `"%s must be a function or nil: %S"`。

**参见。** `etaf-draggable`、`etaf-resizable` 与它们的受控版本。

#### Property: :on-cancel

拖拽与缩放 Behavior 的手势取消回调。

**参数。** 单参函数，参数是手势 plist；可选。

**语义。** 手势被取消时运行。被取消的移动没有改变任何 ref 或受控状态，所以最后一次接受的几何仍然在位。

**错误。** 值不是函数时构造期 `error→ etaf-behavior-error`，消息 `"%s must be a function or nil: %S"`。

**参见。** `etaf-draggable` 与 `etaf-resizable`。

#### Property: :on-resize

`etaf-resizable` 与 `etaf-resizable-controlled` 的移动回调。

**参数。** 单参函数，参数是手势 plist；可选。

**语义。** 在接受的尺寸写入 ref、或交给受控 ON-CHANGE 之后运行。手势结束时的 `:on-end` 仍会运行。

**错误。** 值不是函数时构造期 `error→ etaf-behavior-error`，消息 `"%s must be a function or nil: %S"`。

**参见。** `etaf-resizable` 与 `etaf-resizable-controlled`。

## 错误边界

#### Function: etaf-error-boundary-run (function handler &key name)

运行 FUNCTION，并用 HANDLER 处理它抛出的错误。

**参数。** FUNCTION 是零参函数，正常返回时其结果就是边界结果。HANDLER 是单参函数，参数是原始条件对象，FUNCTION 抛出时其结果就是边界结果。NAME 供调用方诊断用，不改变控制流。FUNCTION 或 HANDLER 不是函数时 `wrong-type-argument`，数据为 `(functionp VALUE)`。

**语义。** 边界捕获 FUNCTION 抛出的 `error` 条件，其它都不捕获：`quit` 向外传播，调用之外抛出的错误不被捕获，HANDLER 自己抛出的错误带着自己的栈向外传播。处理函数收到的条件对象就是 `condition-case` 产生的那个，car 是条件符号、cdr 是数据。边界是一个把错误转成值的词法位置，例如把失败的渲染计算变成错误载荷，或维护一份诊断列表。

**返回。** FUNCTION 返回时是它的值，否则是 HANDLER 的值。

**错误。** 参数不是函数时 `error→ wrong-type-argument`，数据为 `(functionp FUNCTION)` 或 `(functionp HANDLER)`。FUNCTION 的错误不会被重新抛出；HANDLER 的错误与调用之外的一切原样传播。

**示例。** 把失败的计算变成一份报告。

```elisp
(etaf-error-boundary-run
 (lambda () (compute-report))
 (lambda (condition) (list :failed condition))
 :name 'report)
```

**参见。** [响应式系统](reactivity.md#错误与恢复)关于 Runtime 如何收集并重新抛出排空中的错误。

## 语义细节

### Behavior 的同一性与替换

只要 Host 解析出的是*同一个*规格，Behavior 就保持已安装：同名、安装函数 identity 相同、属性按响应式值同样的浅比较规则相等（conses 递归，ref 与函数按 identity），并且有效 Host 引用相同。这些全部成立时，Host 上别处的属性变化不会碰已安装的 Behavior：安装函数不再运行，清理也不运行。

这些事实中任何一项变化——名字不同、安装函数不同、属性不同、或 Host 引用不同——Behavior 就被替换：清理旧的、安装新的。由于安装函数的 identity 也算数，用新建的 `:install` 闭包把同一规格造两次算替换，而用 nil 或共享函数造两次算同一 Behavior。拥有处理函数 identity 的 Behavior（受控的拖拽、缩放）要在保留的所有者里构造一次、而不是每次渲染都构造，原因就在这里。

Host 不再列出它、Host 被禁用、Host 被卸载时，Behavior 被移除。移除会在同一次提交里运行安装函数返回的清理；清理抛错时 Runtime 收集该错误，而不是丢掉其余的收尾工作。禁用的 Host 不安装任何 Behavior，所以禁用再启用会把它们移除又重装。

### 属性组合

Host 自己的属性与每个 Behavior 的属性用组件透传的同一套规则组合，见 [Host](hosts.md#值与冲突)：Host 的非空样式值压过 Behavior 的；事件回调组合时 Behavior 的回调在前；`:disabled` 用 `or` 组合；Host 自己的键排在每个 Behavior 的键之前；Host 与 Behavior 都声明的归属语义属性是冲突而不是覆盖。同一 Host 上重名 Behavior、未知构造函数符号、构造函数返回的不是规格、以及 `:use` 值超出来源语法，都是 Host 属性解析期的错误。

### 代价

Behavior 未变化时，每次 Host 属性解析的代价是一次规格比较：名字检查、安装函数 identity 检查与浅属性比较。安装的代价是安装函数打开的东西，加上每个 Host 存一个清理函数；移除的代价是那次清理调用。内置的拖拽与缩放 Behavior 每个 Ebox 拖拽阶段付出一次手势回调，以及写入的 ref 带来的普通响应式发布，所以它们的发布代价与变化成比例，与拖拽距离无关。

## 错误与恢复

#### Error: etaf-action-error

消息为 "Invalid ETAF Action"。Action 无法定义、登记或派发时抛出。用 `condition-case` 捕获；失败的调用不返回值。父条件是 `error`，数据是含一个格式化消息字符串的列表。

| 消息 | 起因 |
| --- | --- |
| `"Duplicate ETAF Action: %S"` | 在 `etaf-action-redefine-run` 之外对已登记名字调用 `etaf-action-define` |
| `"Invalid Action registration: %S"` | Action 名是 keyword，或不是普通符号 |
| `"Action name must be a symbol"` | `etaf-dispatch` 的 ACTION 不是符号 |
| `"Unknown ETAF Action: %S"` | `etaf-dispatch` 的名字没有登记 |

**参见。** `etaf-action-define`、`etaf-dispatch` 与[响应式系统](reactivity.md#错误与恢复)关于批处理失败契约的说明。

#### Error: etaf-behavior-error

消息为 "Invalid ETAF Behavior"。Behavior 规格、来源、安装函数或受控几何输入非法时抛出。用 `condition-case` 捕获；失败的调用不返回值。父条件是 `error`，数据是含一个格式化消息字符串的列表。

| 消息 | 起因 |
| --- | --- |
| `"Behavior name must be a symbol: %S"` | `etaf-behavior-create` 或 `etaf-define-behavior` 的名字是 keyword 或非符号 |
| `"Behavior attributes must be keyword/value pairs"` | ATTRIBUTES 不是 proper 偶长表 |
| `"Behavior attribute must be a keyword: %S"` | 属性键不是关键字 |
| `"Duplicate Behavior attribute: %S"` | 同一规格里同一个属性键出现两次 |
| `":install must be a function or nil"` | 安装函数不是函数 |
| `"Behavior %S installer must return cleanup"` | 安装函数返回的既不是 nil 也不是函数 |
| `"Invalid Ebox gesture delta: %S"` | 手势的 `:delta` 不是数值 `(DX . DY)` cons |
| `"Unknown Behavior constructor: %S"` | `:use` 符号没有对应函数 |
| `"Behavior constructor %S returned %S"` | 构造函数返回的不是 Behavior 规格 |
| `"Duplicate Behavior on one Host: %S"` | 同一 Host 挂了两个同名 Behavior |
| `"Expected a Behavior installation context"` | `etaf-behavior-context-info` 的参数不是上下文 |
| `"toggleable requires a function-valued :on-change"` | `etaf-toggleable` 没有函数回调 |
| `"%s must be a writable `etaf-ref': %S"`、`"%s must be a function or nil: %S"`、`"%s must be numeric or nil: %S"` | `etaf-draggable` 与 `etaf-resizable` 的几何或回调参数 |
| `"Invalid draggable axis: %S"`、`"etaf-draggable requires :x or :y"`、`"etaf-draggable :x and :y must be distinct refs"` | 非法的拖拽坐标 |
| `"Invalid resizable edges: %S"`、`"etaf-resizable :min-width exceeds :max-width"`、`"etaf-resizable :min-height exceeds :max-height"` | 非法的缩放边或颠倒的上下界 |
| `"Controlled geometry READ must be a function"`、`"Controlled geometry READ must return a plist"`、`"Controlled draggable READ must expose :x or :y"`、`"%s must contain a number, got %S"` | 受控 READ 无法提供手势需要的几何 |
| `"Controlled draggable ON-CHANGE must be a function"`、`"Controlled resizable ON-CHANGE must be a function"`、`"Invalid controlled resize edges: %S"` | 受控 Behavior 的参数非法 |

**参见。** [Host](hosts.md#property-use) 关于 `:use` 解析；Host 与 Behavior 的归属属性冲突见[组件](components.md#错误与恢复)的 `etaf-component-call-error`；手势派发见[事件](events.md)。

### 恢复

| 失败 | 留下什么 |
| --- | --- |
| 重复定义 Action | 已登记的 Action 保留；要刻意替换就用 `etaf-action-redefine-run` |
| 派发的 Action 函数体抛错 | 出错之前的写入保留并已发布；错误在批处理排空之后传播 |
| 非法的 Behavior 规格或来源 | 该次提交的 Host 属性解析失败；失败的来源没有安装 Behavior |
| 安装函数失败 | 提交像其它失败的提交一样回滚，本次提交中做出的安装会被清理；Host 保留它上一次提交的 Behavior |
| 清理函数失败 | Runtime 收集该错误；其余收尾照常运行 |
| Host 被禁用 | 它的 Behavior 被清理；启用后重新安装 |
| 错误边界函数内部出错 | HANDLER 收到原始条件；边界返回它的值 |
| 边界之外或处理函数出错 | 原样传播，带着自己的栈 |

Action 名、Behavior 构造函数与 `:use` 来源是编程契约：失败就在定义处修。Behavior 处理的手势是数据：位移被拒、或受控 READ 给不出几何时，错误从事件回调抛出，事件回调的失败走 Runtime 的普通错误收集。

**参见。** `etaf-dispatch`、`etaf-behavior-create` 与 `etaf-error-boundary-run`。
