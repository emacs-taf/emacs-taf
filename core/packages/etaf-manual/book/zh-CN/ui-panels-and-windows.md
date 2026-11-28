# 面板与窗口

窗口壳是带标题栏、交通灯与缩放手柄的受控表面。目录的面板与窗口有意保持表现式：它们把调用方的几何投影给 Ebox，把手势报告给调用方的回调，自身不保存窗口状态、不分配 z 序，也不实现工作区或窗口管理器。位置、尺寸、可见性与模式归调用方所有，通常存成 ref；改动其中一个会重绘保留的窗口壳，而不重建它。[UI 组件库总论](ui-overview.md)定义受控契约，[定位、图层与浮层](positioning-layers-and-overlays.md)定义它们使用的绝对定位与 z 序，[拖拽与手势](dragging-and-gestures.md)定义手势与锁定协议，[组件样式与主题](component-styles-and-themes.md)定义窗口 token。

## 受控几何与模式

<!-- index: window geometry; reactive geometry; window mode; gesture callbacks -->

每个几何 prop——位置、尺寸、z 序与可见性——都是普通 Host 属性，可以是值、ref 或 computed，窗口壳把它作为保留绑定发布。把矩形存进 ref 的调用方通过写这些 ref 来移动窗口：框架、slot 与手势路由不变，每次指针移动只更新几何格子。约束（`:min-width`、`:max-width`、`:min-height`、`:max-height`）随同样的 prop 传递，由 Ebox 解算。

模式是一个小的封闭词汇——`normal`、`minimized`、`maximized`——组件响应式地读取它。响应式 MODE 让窗口壳的模式类、Zoom 动作的目标与内容折叠都成为保留绑定，因此最小化或最大化永不重建窗口。`minimized` 是呈现而不是几何：仍保持可见的最小化窗口折叠到自己的标题栏；MODE 为 `maximized` 时按 Zoom 调 ON-RESTORE，否则调 ON-MAXIMIZE。窗口永不改变全局焦点或 z 序策略；抬升、堆叠与持久化属于调用方或桌面 shell。

手势只被报告，不被施加。标题栏把 Ebox 的手势 plist 转发给 ON-MOVE，缩放手柄把边缘与手势转发给 ON-RESIZE，`:drag-lock-modifier` 让该修饰键下的移动或缩放与按键释放无关。希望键盘也能走同样操作的调用方可以免费得到：焦点在窗口内任意位置时，`M-方向键` 经标题栏的处理器移动窗口，`M-S-方向键` 拖动右、下或右下手柄。手柄是命中目标而不是 Tab 停靠点，所以 Tab 继续在真实控件之间移动。

## 可调整面板

<!-- index: etaf-resizable-panel; resize handles; header slot; full bleed -->

#### Component: etaf-resizable-panel (&key x y width height position z-index visible min-width max-width min-height max-height resizable resize-edges resize-refs resize-use on-resize on-move header-style drag-lock-modifier full-bleed font-size font-family ref id class role use overflow)

渲染受控的定位面板，可带边缘与角落的缩放手柄。

**参数。** X、Y、WIDTH、HEIGHT、Z-INDEX、VISIBLE、MIN-WIDTH、MAX-WIDTH、MIN-HEIGHT、MAX-HEIGHT 与 CLASS 接受值、ref 或 computed。POSITION 是 `absolute`（默认）或 `relative`。RESIZABLE 默认 t，RESIZE-EDGES 列出 `top`、`right`、`bottom`、`left` 与四个角中生效的边缘。RESIZE-REFS 把边缘映射到调用方引用或每边缘的引用函数，RESIZE-USE 把边缘映射到 Behavior。ON-MOVE 接收面板根部的手势 plist，ON-RESIZE 接收 EDGE 与该手势。HEADER-STYLE 把标题行的角格按标题样式呈现；FULL-BLEED 让 default slot 拥有整个正文，手柄覆盖其边缘格。FONT-SIZE 与 FONT-FAMILY 为 nil 时继承。

**语义。** 带 `header` slot 或可交互手柄的面板会被框起来：标题占据角格之间的第一行，`header-style` 让它的背景与底线跨越窗口外侧列保持连续。控件经调用方的 ref 移动与缩放——可以是 ETAF Behavior，也可以是窗口壳安装的 `M-方向键`/`M-S-方向键` 绑定。组件不保存几何、约束、z 序或交互状态；Ebox 拥有手势的确认与取消，调用方必须让定位内容落在画布共享行高之内。

**返回。** 一个 View。

**错误。** POSITION 既不是 `absolute` 也不是 `relative`、RESIZABLE 或 FULL-BLEED 不是布尔量、RESIZE-EDGES 含不支持的边缘、RESIZE-REFS 或 RESIZE-USE 不是形状正确的边缘 alist、某个回调既不是函数也不是 nil、DRAG-LOCK-MODIFIER 既不是 nil 也不是受支持的修饰键、或 FONT-SIZE 不是正 CSS 像素值（或 FONT-FAMILY 不是字符串）时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-resizable-panel :x px :y py :width pw :height ph
                      :min-width '(px 160) :min-height '(lh 4)
                      :on-move #'move-window :on-resize #'resize-window
                      (slot :name 'header (text "Inspector"))
                      (text "Body"))
```

**参见。** `etaf-window`、[拖拽与手势](dragging-and-gestures.md)。

## 窗口控件与标题栏

<!-- index: etaf-window-controls; traffic lights; etaf-window-chrome; title bar -->

#### Component: etaf-window-controls (&key mode show-minimize show-maximize show-close active on-minimize on-maximize on-restore on-close group class)

渲染可复用的 macOS 风格交通灯控件。

**参数。** MODE 是 `normal`、`minimized`、`maximized`、ref 或 computed。SHOW-MINIMIZE、SHOW-MAXIMIZE 与 SHOW-CLOSE 默认 t。ACTIVE 切换 macOS 表现：非活动窗口三灯同为灰色，活动窗口保持红黄绿。GROUP 是转发给 Ebox 的共享 hover 组键，让三灯在一个增量批里更新。回调只请求调用方拥有的转换。

**语义。** 灯的顺序是关闭、最小化、Zoom。绿色 Zoom 控件只有一个稳定目标：MODE 为 `maximized` 时调 ON-RESTORE，否则调 ON-MAXIMIZE；MODE 为响应式时在按下时读取，因此模式变化永不重建控件。没有 SVG 时灯回退为一格 ASCII 标记，保持同样的动作目标与悬停标签。整组是一行高的工具栏焦点组。

**返回。** 一个 View。

**错误。** MODE 不是三个值之一也不是响应式源、ACTIVE 不能解析为布尔量、GROUP 不是标量键、或某个回调既不是函数也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。** `(etaf-window-controls :mode mode :active active :on-close #'close-window)`

#### Component: etaf-window-chrome (&key title mode show-minimize show-maximize show-close active on-minimize on-maximize on-restore on-close on-move drag-lock-modifier title-font-size font-family group ref class use)

渲染受控标题栏，带最小化、Zoom 与关闭动作按钮。

**参数。** TITLE 是居中标题。MODE、SHOW-*、各动作回调、ACTIVE、DRAG-LOCK-MODIFIER（默认 `shift`）与 GROUP 与 `etaf-window-controls` 相同。ON-MOVE 接收标题栏的手势。TITLE-FONT-SIZE 与 FONT-FAMILY 默认 nil 表示继承；显式尺寸是正文大小的倍数，取 0.3 到 4。`actions` 与 default slot 在内建灯右侧追加自定义控件。

**语义。** 标题栏是一行保留行：前导间隔、交通灯、等宽固定列的标题表面（无需定位子节点即保持居中）、固定宽的 actions 列。响应式 MODE 改变标题栏的模式类与 Zoom 目标而不重渲染标题栏，标题的色调随 ACTIVE 作为保留绘制更新。整条标题栏把拖拽手势交给 ON-MOVE，因此按压并拖动它会经调用方的处理器移动窗口。

**返回。** 一个 View。

**错误。** 与 `etaf-window-controls` 相同，另有非法的 `:drag-lock-modifier`、非正的 `:title-font-size` 或非字符串的 `:font-family`。

**示例。**

```elisp
(etaf-window-chrome :title "Editor" :mode mode :active active
                    :on-move #'move-window :on-close #'close-window)
```

## 窗口

<!-- index: etaf-window; window shell; viewport region; keyboard move -->

#### Component: etaf-window (&key title mode x y width height z-index visible min-width max-width min-height max-height resizable resize-edges resize-refs resize-use move-use full-bleed on-move on-resize on-focus drag-lock-modifier title-font-size content-font-size font-family controls-group controls-active on-minimize on-maximize on-restore on-close show-minimize show-maximize show-close ref id chrome-ref class use overflow)

从 `etaf-resizable-panel` 与 `etaf-window-chrome` 组合受控窗口壳。

**参数。** TITLE、MODE 与每个几何或约束 prop 与 `etaf-resizable-panel` 及标题栏相同。ON-MOVE 与 ON-RESIZE 接收上述手势，MOVE-USE、RESIZE-USE 与 USE 安装 Behavior。ON-FOCUS 在正文激活、嵌套控件按压经祖先 capture 钩子、以及键盘焦点进入窗口时运行。TITLE-FONT-SIZE 与 CONTENT-FONT-SIZE 各自独立覆盖自己的区域，FONT-FAMILY 为两者选择一个字体族。CONTROLS-GROUP 与 CONTROLS-ACTIVE 配置交通灯。slot 有 `header`、`actions`、`default` 与 `footer`。

**语义。** 窗口壳组合面板与标题栏：标题栏占据第一行，正文是包在一个 viewport region 里的 default slot，其中的组件经 `etaf-viewport` 读到 `(PIXELS . ROWS)`，actions 与 footer slot 环绕其组合。焦点在窗口内任意位置时，`M-方向键` 经标题栏的处理器移动窗口，`M-S-方向键` 经右、下或右下手柄缩放；手柄是命中条而不是 Tab 停靠点。`minimized` 把可见窗口折叠到标题栏；最大化永不改变几何或全局焦点策略。所有定位内容必须落在所在画布的共享行高之内；Ebox 在发布前拒绝更大的解析字体。

**返回。** 一个 View。

**错误。** 面板与标题栏的校验同样适用；非法的 MODE、几何约束或回调让调用以 `error→ etaf-component-call-error` 失败并点名属性。

**示例。**

```elisp
(etaf-window :title "Editor" :mode mode :x wx :y wy :width ww :height wh
             :on-move #'move-window :on-resize #'resize-window
             :on-close #'close-window
             (text "Document"))
```

**参见。** `etaf-resizable-panel`、`etaf-window-chrome`。

## 窗口 token

<!-- index: ui-window-fg; ui-window-bg; ui-window-title-bg; ui-window-title-active-fg -->

#### Token: :ui-window-fg

窗口内容的前景。

#### Token: :ui-window-bg

窗口或面板表面的背景。

#### Token: :ui-window-border

窗口或面板周围的框架。

**语义。** 与 `:ui-window-fg`、`:ui-window-bg` 一起构成窗口表面三件套；同一个键也绘制普通可调整面板，所以面板与完整窗口读作同一种材质。

#### Token: :ui-window-title-bg

窗口标题栏的背景。

#### Token: :ui-window-title-fg

非活动窗口的标题颜色。

#### Token: :ui-window-title-active-fg

活动窗口的标题颜色。

**语义。** 标题表面在保留 Host 属性里读取活动或非活动键，因此焦点变化只重绘标题色而不重渲染标题栏。

#### Component: etaf-edge-panel (&key title status variant focus width ref)

画一块面板，TITLE 落在面板的上边线上。

**参数。** STATUS 给定时画在同一条线的右端；VARIANT 默认 `default`，`flat` 去掉表面只留边线；FOCUS 让边线与标题取强调色；WIDTH 与 REF 是常规参数。

**返回。** 一个 ETAF Component。

**语义。** 标题占的是边线本身的那一格，所以面板既报了名字又没多占一行；状态也挤在同一行右端，信息密度比带独立标题栏的面板高。

**参见。** `etaf-edge-tabs`、`etaf-underline-field`、`etaf-window`。

#### Component: etaf-edge-tabs (&key items active on-change width ref)

把 ITEMS 画成嵌在面板上边线里的标签。

**参数。** ITEMS 是 plist 列表，每个含唯一的 `:key` 与非空 `:label`；ACTIVE 是选中的 key，也可以是 ref；ON-CHANGE 接收被按下标签的 key；WIDTH 与 REF 是常规参数。

**返回。** 一个 ETAF Component。

**语义。** 边线横穿整个标签行，标签因此坐在面板边缘而不是上方的一条横条里。选中的标签取强调墨色与加粗字重，其余保持次要；边线不为标签断开，所以整块看起来仍是一个框。

**参见。** `etaf-edge-panel`、`etaf-tabs`。

#### Component: etaf-underline-field (&key label value placeholder focus width ref)

画一个只读字段，形式是值下面的一条线。

**参数。** LABEL 在字段上方用次要墨色命名它；VALUE 是线上承载的内容；PLACEHOLDER 在 VALUE 为空时以次要墨色显示；FOCUS 让线取强调色；WIDTH 与 REF 是常规参数。

**返回。** 一个 ETAF Component。

**语义。** 它把表单画成一行行带标签的文字而不是一堆方框，线不额外占一行。字段只读：编辑它要开一个输入会话，由[文本输入](text-input.md)一章定义。

**参见。** `etaf-edge-panel`、[文本输入](text-input.md)。

#### Component: etaf-log (&key rows level-width time-width width ref)

把 ROWS 画成日志，一行一条。

**参数。** 每行是含 `:time`、`:level` 与 `:message` 的 plist；LEVEL-WIDTH 默认 5，TIME-WIDTH 默认 8；WIDTH 与 REF 是常规参数。

**返回。** 一个 ETAF Component。

**语义。** 时间与级别用次要墨色且着色，级别列有 LEVEL-WIDTH 格、时间列有 TIME-WIDTH 格，消息填满剩余宽度。它不加框，因为面板本身已经画了框架；把它放进 `etaf-edge-panel` 或抽屉里才是完整的外观。

**参见。** `etaf-status-bar`、`etaf-edge-panel`。

#### Component: etaf-status-bar (&key mode keys note width ref)

画一行状态栏，承载 MODE、KEYS 与 NOTE。

**参数。** MODE 是命名当前模式的实心标签；KEYS 是 （KEY . LABEL） 列表，画成一个键与它的含义；NOTE 靠着右端；WIDTH 与 REF 是常规参数。

**返回。** 一个 ETAF Component。

**语义。** 状态栏自己不画框架，读起来是窗口的下边缘。KEYS 的顺序就是显示顺序，调用方决定哪些键值得占用这一行。

**参见。** `etaf-log`、`etaf-window`。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的 prop，消息点名组件、属性、收到的值与期望：不支持的模式、位置、边缘列表、引用或 Behavior alist，非布尔标志，非法的锁定修饰键，以及不是正数的字体尺寸。
- 手势是请求：忽略手势的移动或缩放处理器让几何保持不变，组件从不写调用方的 ref。锁定修饰键按住时释放会经同样的回调结束手势。
- Ebox 仍然拥有手势的确认与取消：非法几何值在发布时被拒绝，上一次已提交的矩形保持可见。
- 超出画布共享行高的内容在发布前被拒绝；此前的像素与输入仍可用，因此被拒绝的字体不会破坏窗口。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[拖拽与手势](dragging-and-gestures.md)。

```elisp :run
(etaf-view
 (column :width '(ch 70) :height '(lh 22)
   (etaf-window :title "Editor" :x '(px 0) :y '(lh 0)
                :width '(ch 40) :height '(lh 10)
                :on-move #'ignore :on-resize (lambda (edge gesture) (ignore edge gesture))
                (text "Document"))))
```
