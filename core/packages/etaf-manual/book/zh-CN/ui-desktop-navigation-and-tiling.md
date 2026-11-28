# 桌面导航与平铺

桌面组件是窗口管理器据以搭建的外壳：任务栏承载打开的窗口，工作区栏切换与管理虚拟桌面，模态启动器与切换器选择应用，分隔条与面板缩放器负责平铺布局。它们是表现式的，有意把选择、工作区、窗口与布局状态全部留在调用方；它们暴露普通回调与 Behavior，因此桌面策略可以在浮动与平铺布局中使用同一批控件，而不新增输入或焦点系统。[UI 组件库总论](ui-overview.md)定义受控契约，[面板与窗口](ui-panels-and-windows.md)定义它们管理的窗口，[浮层](ui-overlays.md)定义启动器打开的对话框，[组件样式与主题](component-styles-and-themes.md)定义 shell token。

## item、tone 与 shell

<!-- index: desktop item; item state; item tone; shell tokens -->

桌面 item 是 item plist：唯一标量 `:key`、非空 `:label`，以及可选的 `:description`、`active`/`minimized`/`error` 的 `:state`（或它们的 ref/computed）、`:disabled` 标志与 `:ref`。caption 从不携带标记字形：状态由按钮的 tone 表达，不改变内边距与字重，这让文本宽度在窗口聚焦与最小化时保持稳定，也避免任务栏变吵。

栏与它们的 item 用 shell token 集绘制——`:ui-shell-bg`、`:ui-shell-fg`、`:ui-shell-muted-fg`、`:ui-shell-item-fg` 与 `:ui-shell-item-minimized-fg`——选择用 accent token，选择器行用 picker token。因为每个键都经延迟 token 解析，提供一次 Theme 就能把整个 shell、它的 item、选择器与分隔线一起换装而不重渲染。

## 任务栏

<!-- index: etaf-taskbar; window buttons; launcher button -->

#### Component: etaf-taskbar (&key items active on-select on-launch launcher-label ref-prefix class)

渲染受控任务栏，展示窗口 item。

**参数。** ITEMS 是带标量 `:key` 与非空字符串 `:label` 的 item plist；可选 `:state` 是 `active`、`minimized`、`error` 或 nil（或它们的 ref/computed），`:disabled` 抑制激活。ACTIVE 标记聚焦项，可以是标量键、nil、ref 或 computed。ON-SELECT 接收一个键；ON-LAUNCH 提供时，经前置的 primary 按钮（标签为 LAUNCHER-LABEL，默认 `"Applications"`）打开调用方的启动器。

**语义。** 任务栏是一行：有启动回调时先是一个启动器按钮，然后每个 item 一个按钮，各自按 tone 绘制——活动项用 accent 浅色，最小化项用 muted 的最小化 token，错误项用语义错误色。空任务栏显示 muted 的 `"No windows"`。全部窗口状态归调用方：选择只报告一个键。

**返回。** 一个 View。

**错误。** 重复键、非法 state、非布尔的 `:disabled`、非法的 active 键、非字符串的启动器标签或非函数回调时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-taskbar :items '((:key editor :label "Editor" :state active)
                       (:key term :label "Terminal" :state minimized))
              :active 'editor :on-select #'focus-window :on-launch #'open-launcher)
```

**参见。** `etaf-workspace-bar`、`etaf-launcher`。

## 工作区栏

<!-- index: etaf-workspace-bar; workspace tabs; layout control; status -->

#### Component: etaf-workspace-bar (&key workspaces active on-select on-add on-close add-label brand status layout-label layout-action settings-label settings-action ref-prefix class)

把受控工作区渲染为可访问的工作区切换栏。

**参数。** WORKSPACES 装标量键或带 `:key`、`:label`、可选 `:description` 与 `:disabled` 的 item plist。ACTIVE 是选中的键、ref 或 computed。STATUS 是字符串、nil、ref 或 computed。ON-SELECT 接收一个键；ON-ADD 与 ON-CLOSE 是可选策略动作，ADD-LABEL（默认 `"New workspace"`）命名新增控件。BRAND 是可选的前导说明。LAYOUT-LABEL 与 LAYOUT-ACTION 渲染尾部的窗口管理控件；LAYOUT-LABEL 可以是字符串、ref 或 computed，控件保持固定宽，因此标签变化以保留文本更新发布。SETTINGS-LABEL 与 SETTINGS-ACTION 再加一个尾部动作。

**语义。** 单行栏显示 brand、每个工作区一个 tab 带关闭控件、新增控件、占满剩余宽并裁剪多余文本的状态区域，以及右缘的布局与设置控件。因此状态长度变化永远不会移动尾部动作。组件不创建、删除或持久化任何东西：回调只请求这些变更。

**返回。** 一个 View。

**错误。** 非法的工作区列表、回调或标签报 `error→ etaf-component-call-error`；重复的工作区键由渲染器以 `etaf-renderer-error` 报出并点名该键。

**示例。**

```elisp
(etaf-workspace-bar :workspaces '((:key 1 :label "One") (:key 2 :label "Two"))
                    :active 1 :on-select #'switch-workspace :on-add #'add-workspace
                    :status "3 windows" :layout-label "Tiled" :layout-action #'toggle-layout)
```

## 启动器与切换器

<!-- index: etaf-launcher; etaf-switcher; application picker -->

#### Component: etaf-launcher (&key open title items on-select on-close close-label backdrop)

从 item plist 渲染受控的模态应用启动器。

**参数。** OPEN 是值、ref 或 computed；为 nil 时启动器不渲染。TITLE 默认 `"Applications"`。ITEMS 用 `:key`/`:label` 与可选 `:description`、`:state`、`:disabled`。ON-SELECT 接收选中的键，ON-CLOSE 必需；CLOSE-LABEL（默认 `"Close"`）命名对话框 footer 的按钮。BACKDROP 默认 t。

**语义。** 启动器是宽 `(ch 56)` 的模态对话框，正文是选择列表；item 显示 caption，可选 muted 描述在其下。启动器不拥有注册表也不拥有打开状态：调用方通常在处理选择后关闭 OPEN；BACKDROP 为 nil 时完全不绘制遮罩，桌面保持完整可见而不被调暗。

**返回。** 一个 View。

**错误。** ON-SELECT 或 ON-CLOSE 不是函数、标签不是字符串、或 item 列表非法时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-launcher :open launcher :on-select #'launch-app
               :on-close (lambda () (setf launcher nil))
               :items '((:key editor :label "Editor" :description "Text editor")))
```

#### Component: etaf-switcher (&key open title items selected on-select on-close close-label backdrop)

渲染受控的模态应用或窗口切换器。

**参数。** props 与 `etaf-launcher` 相同；TITLE 默认 `"Switch application"`，SELECTED 标记当前聚焦项。

**语义。** 呈现、尺寸与遮罩跟随启动器，SELECTED 用选中色调绘制聚焦行，因此键盘驱动的切换器能显示当前目标。item 列表、选择与打开状态归调用方所有。

**返回。** 一个 View。

**错误。** 与 `etaf-launcher` 相同。

**示例。**

```elisp
(etaf-switcher :open switch :selected current :on-select #'switch-to
               :on-close (lambda () (setf switch nil))
               :items '((:key editor :label "Editor") (:key term :label "Terminal")))
```

## 分隔条与面板缩放器

<!-- index: etaf-splitter; divider overlay; etaf-pane-resizer; pane width -->

#### Component: etaf-splitter (&key orientation ratio min-ratio max-ratio on-change use class overlay z-index divider-content overlay-rect visible)

渲染受控分栏布局，带可键盘聚焦的分隔条。

**参数。** ORIENTATION 是 `horizontal`（左右）或 `vertical`（上下）。RATIO 是第一栏比例，归调用方所有，受 MIN-RATIO（默认 0.1）与 MAX-RATIO（默认 0.9）约束。ON-CHANGE 接收原始分隔条手势，USE 可安装把该手势换算成新比例的 ETAF Behavior。`first` 与 `second` slot 装两栏。OVERLAY 只渲染分隔条，供调用方拥有定位宿主；DIVIDER-CONTENT 提供该分隔条的绘制范围——垂直分隔条是一行字符，水平分隔条是每行一个字符——因为定位盒子只绘制它拥有的内容。OVERLAY-RECT 可提供精确的 `:left`/`:top`/`:width`/`:height` 分配；没有它时分隔条相对定位父级按 RATIO 摆放。OVERLAY-RECT 条目、DIVIDER-CONTENT、Z-INDEX 与 VISIBLE 可以是 ref 或 computed，只在 Host 绑定里读取，因此布局策略可以移动、隐藏或显示分隔条而不重渲染它。

**语义。** 分隔条从不保存比例或窗口/布局策略：它渲染两栏并报告分隔条手势，聚焦的分隔条按跨过它的方向键像一格拖动那样步进。比例策略在 `start` 保存初始比例和已分配的像素长度，在 `move`/`end` 加上累计像素位移除以该长度的结果并夹到指定边界，在 `cancel` 恢复初始比例。应测量当前分配，例如对没有额外内边距的具名水平分栏调用 `etaf-host-ref-size`，而不是假定固定视口宽度。MIN-RATIO 与 MAX-RATIO 校验传入比例，不代替回调进行换算。拥有分配方案的调用方可以让分隔条跑在 overlay 模式，并在平铺移动时经 ref 更新其矩形。

**返回。** 一个 View。

**错误。** ORIENTATION 未知、RATIO 越出配置边界、回调既不是函数也不是 nil、或可见性标志不是布尔量时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-splitter :orientation 'horizontal :ratio ratio :on-change #'split-gesture
               (slot :name 'first (text "Left"))
               (slot :name 'second (text "Right")))
```

**参见。** `etaf-pane-resizer`、[拖拽与手势](dragging-and-gestures.md)。

#### Component: etaf-pane-resizer (&key size side min max on-change on-end line background ref)

渲染可缩放相邻固定宽面板的垂直分隔条。

**参数。** SIZE 是面板当前像素宽——数字、ref 或 computed。SIDE 为 `right`（默认）时分隔条位于面板右侧，向右拖动加宽；`left` 服务于分隔条右侧的面板。每次拖动把候选宽（给定 MIN 与 MAX 时按像素夹紧）传给 ON-CHANGE；ON-END 接收最终宽。LINE（默认 t）在 BACKGROUND 上贴着面板画一条发丝线。REF 到达渲染出的分隔条，供调用方聚焦或引用。

**语义。** 分隔条宽到足以抓取，带 `separator` role 与垂直方向，拖动时从不移动其它格子。有回调时它是 Tab 停靠点，Left 与 Right 按压每次把宽度步进一列。宽度归调用方所有：组件报告候选值，应用保存它接受的面板宽。

**返回。** 一个 View。

**错误。** SIDE 既不是 `left` 也不是 `right`、回调既不是函数也不是 nil、或 MIN/MAX 既不是数字也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-pane-resizer :size width :side 'right :min 120 :max 400
                   :on-change #'preview-pane :on-end #'commit-pane)
```

## 桌面 token

<!-- index: ui-shell-bg; ui-shell-item-fg; ui-picker-item-bg; ui-divider-bg -->

#### Token: :ui-shell-bg

桌面栏的背景。

#### Token: :ui-shell-fg

桌面栏的前景。

#### Token: :ui-shell-muted-fg

桌面栏上的弱化文字，例如空任务栏的提示与状态区域。

#### Token: :ui-shell-item-fg

普通窗口或工作区 item 的 caption 颜色。

#### Token: :ui-shell-item-minimized-fg

最小化窗口 item 的 caption 颜色。

**语义。** 五个 shell 键绘制栏与它们的 item；选择与强调用 accent token，因此桌面 Theme 可以不经单个组件就把整个 shell 换装。

#### Token: :ui-picker-item-bg

启动器或切换器行的背景。

#### Token: :ui-picker-item-fg

选择器行的 caption 颜色。

#### Token: :ui-picker-item-muted-fg

选择器行的描述颜色。

**语义。** picker 三件套给启动器与切换器行换装；选中行改用 secondary 按钮对，它在变暗的 shell 之上依然清晰。

#### Token: :ui-divider-bg

分隔条或面板缩放器的分隔颜色。

**语义。** 分隔条与面板缩放器的发丝线都用它绘制，因此桌面上每条可拖拽边界读作同一种材质。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的 prop，消息点名组件、属性、收到的值与期望：重复键、非法 state、越界比例、未知边或方向、非法像素边界与非函数回调。
- 重复键也可能在非法键到达键控列表时由渲染器以 `etaf-renderer-error "View has duplicate sibling key: …"` 报出，它点名的是确切的键而不是列表。
- 手势与选择是请求：忽略手势的分隔条或缩放器回调让调用方的比例或宽度保持不动，忽略选择的启动器保持自己的打开标志。
- 桌面组件完全不拥有状态，因此被拒绝的输入让每个已挂载的栏、面板与对话框保持原样。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[面板与窗口](ui-panels-and-windows.md)。

```elisp :run
(etaf-view
 (column :width '(ch 70) :height '(lh 22) :item-gap '(lh 1)
   (etaf-workspace-bar :workspaces '((:key 1 :label "One") (:key 2 :label "Two"))
                       :active 1 :on-select #'ignore :status "3 windows")
   (etaf-taskbar :items '((:key editor :label "Editor" :state active)
                          (:key term :label "Terminal" :state minimized))
                 :active 'editor :on-select #'ignore)))
```
