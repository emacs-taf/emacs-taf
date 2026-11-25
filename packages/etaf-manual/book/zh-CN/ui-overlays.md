# 浮层

浮层是画在 root 图层、位于应用之上的临时表面：上下文面板、模态对话框、工具提示、通知或侧边抽屉。目录的浮层都是受控的——打开标志与对关闭请求的反应归调用方所有——它们共享同一套卡片结构、同一套焦点策略与同一条关闭规则。Ebox 拥有定位、遮挡与锚点契约；组件拥有面板的呈现与键盘作用域。[定位、图层与浮层](positioning-layers-and-overlays.md)定义锚定、root 层坐标与浮层所需的画布预留，[焦点](focus.md)定义模态作用域，[UI 组件库总论](ui-overview.md)定义受控契约，[组件样式与主题](component-styles-and-themes.md)定义面板 token。

## 浮动表面

<!-- index: floating surface; card anatomy; open flag; modal scope; backdrop -->

每个浮层在 `:open` 为 nil 时不渲染任何东西，为真时渲染同一张卡片：一行 header 在细线下方承载标题，一个上下各一行、左右各两列内边距的 body column，以及可选的右对齐 footer 行。模态表面在 header 增加一个小小的 `x`——仅指针可用，好让键盘焦点仍落在第一个正文控件上——并在组件定义的地方增加 footer 确认按钮。header 与面板用面板三件套绘制，所以提供一次 Theme 就能同时给每个表面换装。

面板是一个 root 层 Host：模态时 role 为 `dialog`，否则为 `group`，Tab 序号为负，并把组件的 `:on-close` 安装为它的关闭处理器。定位全部委托出去：有锚点的表面遵循 Ebox 的锚点与 placement 契约，侧边抽屉整高占满一条边，居中的对话框在可见窗口内定尺寸并约束自身高度，因此矮窗口裁剪的是对话框正文而不是应用的几何。模态表面在自己身后绘制全屏遮罩：遮罩调暗下方的应用而不是覆盖它，被盖住的文字与图片仍然可见，而控件失去指针与焦点目标。省略遮罩时面板在键盘意义上仍是模态，应用的表面保持完整绘制。

焦点的规则对所有浮层一致。打开时焦点落在面板内第一个可用控件（没有则落在面板本身）；打开期间面板是模态键盘作用域，Tab、方向键与 Escape 都留在表面内，关闭把焦点还给打开它的控件。嵌套也能工作：每个表面记录自己打开时的焦点路线，内层表面关闭时沿这条链把手焦点交还，跳过已经不存在的目标。

## popover 组件

<!-- index: etaf-popover; anchored panel; controlled open -->

#### Component: etaf-popover (&key open anchor placement width title on-close)

在 Ebox 的 root 层显示受控的 OPEN 内容，锚定到唯一的语义 ID。

**参数。** OPEN 是值、ref 或 computed。ANCHOR 是指向面板所依附 Host 的非空符号或字符串。PLACEMENT 默认 `bottom-start`，遵循[定位、图层与浮层](positioning-layers-and-overlays.md)的锚点契约。WIDTH 默认 `(ch 32)`。TITLE 是可选字符串。ON-CLOSE 必需且不收参数。default 与 `footer` slot 装调用方的容。

**语义。** popover 是通用的锚定表面；菜单、工具提示与通知都建立在它之上。打开期间面板是模态键盘作用域，Escape 关闭，面板自己的关闭处理器请求 ON-CLOSE 而不改变调用方状态。应用根必须为浮动内容预留画布高度——否则面板无处绘制——打开标志归调用方所有，所以两个 popover 可以各自独立打开。

**返回。** 一个 View。

**错误。** ON-CLOSE 不是函数、ANCHOR 不是非空语义 ID、或 TITLE 既不是字符串也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-popover :open open :anchor 'status-chip :title "Details"
              :on-close (lambda () (setf open nil))
              (text "All checks passed."))
```

**参见。** `etaf-dialog`、`etaf-tooltip`。

## dialog 组件

<!-- index: etaf-dialog; modal panel; backdrop; fixed height -->

#### Component: etaf-dialog (&key open title width height compact close-label on-close backdrop keys on-direction animated)

用与 Popover 相同的浮动表面显示受控模态面板。

**参数。** OPEN 是值、ref 或 computed。TITLE 默认 `"Dialog"`。WIDTH 默认 `(ch 48)`。HEIGHT 为 nil 或 `(lh N)`（N 为正），把面板限制在可见窗口内的若干文本行。COMPACT 去掉正文的纵向留白，让短表单保持紧凑。CLOSE-LABEL 默认 `"Close"`；nil 时省略默认 footer 按钮，让 footer slot 决定全部动作。BACKDROP 默认 t。ON-CLOSE 必需。KEYS 与 ON-DIRECTION 声明面板 Host 的作用域 `:keys` 和 `:on-direction`，不绑定遮罩。ANIMATED 非 nil（默认 nil）时，打开后经共享动画时钟平滑渐暗模态遮罩。

**语义。** 显示 buffer 的窗口是图形窗口时，对话框在窗口内居中，且永不移动应用的几何或全局焦点策略。header 显示 TITLE 与一个仅指针可用的 `x`，它请求 ON-CLOSE，Escape 同样如此，所以模态总有一条键盘出口。带 BACKDROP（默认）时，遮罩调暗 root 画布，同时让被盖住的应用（包括文字与图片）保持可见；被覆盖的控件及其焦点目标仍被挡住。点击遮罩请求 ON-CLOSE，不会穿透并点击背景；点击面板内部不会关闭。嵌套模态遮罩只关闭自己所属的最上层界面，不关闭被覆盖的父界面。BACKDROP 为 nil 时完全不绘制遮罩，外部按压策略归调用方。固定 HEIGHT 需要正文行数再加五（header、正文留白与 footer）；窗口太矮时裁剪对话框正文，而不溢出 frame。对话框不拥有表单数据。

**返回。** 一个 View。

**错误。** ON-CLOSE 不是函数、TITLE 不是字符串、HEIGHT 既不是 nil 也不是 `(lh 正整数)`、COMPACT 不是布尔量、或 CLOSE-LABEL 既不是字符串也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-dialog :open ask :title "Confirm" :width '(ch 40)
             :on-close (lambda () (setf ask nil))
             (text "Proceed?")
             (slot :name 'footer
               (etaf-button :label "Delete" :variant 'primary :on-press #'delete)))
```

**参见。** `etaf-popover`、`etaf-confirm-dialog`。

## 快捷键帮助

<!-- index: etaf-key-help; 只读帮助; 帮助搜索 -->

#### Component: etaf-key-help (&key data on-close)

在可搜索的只读模态框中呈现有效快捷键快照。

**参数。** DATA 是 `etaf-help-data` 返回的快照。ON-CLOSE 是零参数回调。

**语义。** 按来源分组：宽窗中应用和区域键与通用导航并列，紧凑窗口改为可滚动单栏。面板跟随继承的 Theme，并调暗背景。`/` 开始原生搜索，对按键、标签、来源与说明做不区分大小写的字面匹配。未编辑时方向键滚动，C-v/M-v 或 Page Down/Page Up 翻页。条目从不执行业务命令。Escape 先退出搜索编辑，再关闭帮助；点击遮罩则关闭帮助，不激活被覆盖的控件。关闭后恢复仍有效的入口。最小可用视口为 48 字符宽、18 行；更小的视口有意裁剪，不缩小字体。

**语义。** 加载 etaf-ui 时会把此组件安装为 `etaf-help` 的呈现器，但已有非 nil 的 `etaf-help-view-function` 时不覆盖。普通应用调用 `etaf-help` 即可，不另持打开状态、buffer 或 Runtime。直接组合适用于已有受控对话框生命周期的调用方；应在打开前捕获 DATA，并像其他浮层一样预留根画布。

**返回。** 一个 View。

**错误。** DATA 不是包含字符串 `:title` 的列表，或 ON-CLOSE 不是函数时报 `error→ etaf-component-call-error`。

**示例。** `(etaf-key-help :data snapshot :on-close close)`

**参见。** `etaf-help`、`etaf-help-data`、`etaf-dialog`、`etaf-kbd`。

## 工具提示与通知

<!-- index: etaf-tooltip; etaf-toast; transient notice -->

#### Component: etaf-tooltip (&key open anchor text placement on-close)

用 Popover 的放置方式在锚点附近显示受控的短文本。可见性由调用方控制；不引入第二套 hover 事件系统。

**参数。** OPEN 是值、ref 或 computed。ANCHOR 是语义 ID。TEXT 是字符串或响应式字符串。PLACEMENT 默认 `top-start`。ON-CLOSE 必需。

**语义。** 工具提示是承载一个 label 的小锚定 popover，因此它的关闭、焦点作用域与图层行为与 `etaf-popover` 完全一致。因为可见性受控，何时显示提示由应用决定——按钮的事件回调是通常的触发点，而不是隐式的 hover 定时器。

**返回。** 一个 View。

**错误。** TEXT 不能解析为字符串、或 ON-CLOSE 不是函数时报 `error→ etaf-component-call-error`。

**示例。** `(etaf-tooltip :open hint :anchor 'copy-button :text "Copy" :on-close #'hide-hint)`

#### Component: etaf-toast (&key open anchor message title variant on-close)

显示受控的可关闭锚定通知。生命周期与消息状态归调用方所有。

**参数。** MESSAGE 是字符串或响应式字符串。TITLE 默认 `"Notification"`。VARIANT 选择语义状态色，默认 `info`。ANCHOR 与 ON-CLOSE 与 `etaf-popover` 相同；宽度为 `(ch 42)`，放置为 `top-end`。

**语义。** 正文在消息之上显示一个承载 variant 名（首字母大写）的状态 badge，因此 success、warning、danger 或 info 通知读起来与目录其余部分共用同一套状态色。通知从不自行过期：应用决定何时清掉 OPEN 并移除它。

**返回。** 一个 View。

**错误。** MESSAGE 不能解析为字符串、TITLE 不是字符串、或 ON-CLOSE 不是函数时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-toast :open notice :anchor 'status-chip :message "Saved" :variant 'success
            :on-close (lambda () (setf notice nil)))
```

## 抽屉组件

<!-- index: etaf-drawer; side panel; modal side surface -->

#### Component: etaf-drawer (&key open title placement width modal on-close)

显示受控的左右侧边表面，带 default 与 footer slot。

**参数。** OPEN 是值、ref 或 computed。PLACEMENT 是 `left` 或 `right`（默认 `right`）。WIDTH 默认 `(ch 42)`，受 root 画布约束。MODAL 默认 t。TITLE 默认 `"Drawer"`。ON-CLOSE 必需。

**语义。** 抽屉在画布的一条边上整高填充，宽度取自 prop，应用其余部分保持可见。它的焦点、关闭、返回与释放遵循 Dialog 契约：模态模式加遮罩并接管键盘作用域，非模态模式让周围表面保持可交互，而 Escape 仍请求 ON-CLOSE。表单数据与抽屉内容仍归调用方所有。

**返回。** 一个 View。

**错误。** PLACEMENT 既不是 `left` 也不是 `right`、MODAL 不是布尔量、TITLE 既不是字符串也不是 nil、或 ON-CLOSE 不是函数时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-drawer :open filters :title "Filters" :placement 'right
             :on-close (lambda () (setf filters nil))
             (etaf-checkbox :label "Only stale"))
```

## 确认与外部按压

<!-- index: etaf-confirm-dialog; etaf-ui-dismiss-outside-press; outside policy -->

#### Function: etaf-confirm-dialog (prompt)

从 Host 回调里用原生 yes/no minibuffer 询问非空字符串 PROMPT。确认时返回非 nil，否则返回 nil；只在确认之后改变应用状态。

**语义。** Emacs 拥有 yes/no 提示，Ebox 之后把焦点恢复到仍然有效的条目；C-g 中止回调，条目失效同样如此。不编辑任何表面内容。在 Menu 的 ON-SELECT 或按钮的 ON-PRESS 里组合使用。

**返回。** 确认时非 nil，否则 nil。

**错误。** Host 事件回调之外报 `error→ etaf-event-error`；PROMPT 不是非空字符串时报 `error→ etaf-view-error`。

**示例。** `(etaf-confirm-dialog "Delete this file?")`

**参见。** `etaf-dialog`。

#### Function: etaf-ui-dismiss-outside-press ()

关闭当前事件的 Runtime 中所有面板不含被按 Host 的已挂载浮层，逐个请求它们的 ON-CLOSE，并返回关闭的数量。

**语义。** 在包围应用的 Host（例如 shell 根）的 `:on-press` 或 `:on-press-capture` 回调里调用它，让未绘制遮罩（`:backdrop` nil）的模态与 popover 获得点击外部关闭。Runtime 中每个面板不含被按 Host 的 dialog、launcher、switcher、popover、menu 或 drawer 都收到一次关闭请求；正在处理的那次按压所打开的表面尚未挂载，保持打开。函数经正常事件路径请求关闭，所以拥有者忽略请求的表面就保持打开。

**返回。** 被关闭表面的数量。

**错误。** Host 事件回调之外报 `error→ etaf-event-error`。

**示例。**

```elisp
(box :ref 'shell :on-press-capture #'etaf-ui-dismiss-outside-press
  (etaf-popover :open open :anchor 'status-chip
                :on-close (lambda () (setf open nil))
                (text "Details")))
```

**参见。** `etaf-popover`、`etaf-drawer`。

#### Component: etaf-drop-zone (&key side label ratio cols rows accent width ref)

把 LINES 画成一块面板，投放预览落在 SIDE 那一侧。

**参数。** SIDE 是 nil、`top`、`bottom`、`left`、`right` 或 `center`，nil 表示平淡地画这些行；LABEL 写在预览的虚线上；RATIO 默认 0.5，是预览占面板的比例；COLS 与 ROWS 是面板的格子尺寸；ACCENT 覆盖预览的颜色；WIDTH 与 REF 是常规的布局与寻址参数。

**返回。** 一个 ETAF Component。

**语义。** 预览占 RATIO 那么大一块，把自己的文字留在里面，所以读者既看到面板会落在哪，也看到它会盖住什么。着色是把 ACCENT 混进面板表面，文本 frame 的「半透明」就是这么画出来的。

**参见。** `etaf-drawer`、[拖拽与手势](dragging-and-gestures.md)。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的 prop，消息点名组件、属性、收到的值与期望：缺失或非函数的 ON-CLOSE、非法锚点、形式非法的固定高度、非布尔标志或非字符串标题。
- 关闭是请求而不是状态变更：Escape、header 的 `x` 与外部按压都会运行 ON-CLOSE，由应用决定表面是否关闭。忽略请求的回调会让表面保持打开。
- 关闭的 dialog 或 drawer 把焦点还给打开它的控件，或沿嵌套链回退到最近仍有效的目标；已卸载的返回目标被跳过而不是报错。
- 被拒绝或被取消的确认什么都不改变：`etaf-confirm-dialog` 在回答否时返回 nil、在 C-g 时中止回调，所以调用方状态保持原样。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[焦点](focus.md)。

```elisp :run
(etaf-view
 (column :width '(ch 60) :height '(lh 18)
   (box :id 'status-chip (text "Status: ready"))
   (etaf-popover :open t :anchor 'status-chip :title "Details" :on-close #'ignore
                 (column (text "All checks passed.")))))
```
