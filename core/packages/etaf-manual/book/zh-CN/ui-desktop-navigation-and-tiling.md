# 桌面导航与平铺

`etaf-ui` 提供用于缩放相邻固定宽面板的 `etaf-pane-resizer`，以及共享的 shell、选择器与分隔线主题 token。桌面外壳专用控件（任务栏、工作区栏、启动器、切换器与平铺分隔条）归属 etaf-desktop 应用包，不放在通用组件目录中。[UI 组件库总论](ui-overview.md)定义受控契约，[面板与窗口](ui-panels-and-windows.md)定义窗口装饰，[组件样式与主题](component-styles-and-themes.md)定义延迟 token 如何经 Theme 解析。

## 面板缩放器

<!-- index: etaf-pane-resizer; pane width; divider -->

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

**参见。** [拖拽与手势](dragging-and-gestures.md)、[面板与窗口](ui-panels-and-windows.md)。

## 外壳与分隔线 token

<!-- index: ui-shell-bg; ui-shell-item-fg; ui-picker-item-bg; ui-divider-bg -->

#### Token: :ui-shell-bg

外壳栏的背景。

#### Token: :ui-shell-fg

外壳栏的前景。

#### Token: :ui-shell-muted-fg

外壳栏上的弱化文字，例如空栏提示与状态区域。

#### Token: :ui-shell-item-fg

普通外壳 item 的 caption 颜色。

#### Token: :ui-shell-item-minimized-fg

最小化外壳 item 的 caption 颜色。

**语义。** 五个 shell 键绘制外壳栏与它们的 item；选择与强调用 accent token，因此 Theme 可以不经单个控件就把整个应用外壳换装。

#### Token: :ui-picker-item-bg

选择器行的背景。

#### Token: :ui-picker-item-fg

选择器行的 caption 颜色。

#### Token: :ui-picker-item-muted-fg

选择器行的描述颜色。

**语义。** picker 三件套给选择器行换装；选中行改用 secondary 按钮对，在变暗的表面之上依然清晰。

#### Token: :ui-divider-bg

面板缩放器或分栏边界的分隔颜色。

**语义。** 面板缩放器的发丝线用它绘制，使每条可拖拽边界读作同一种材质。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的 prop，消息点名组件、属性、收到的值与期望：未知边、非法像素边界与非函数回调。
- 拖拽手势是请求：忽略手势的缩放器回调让调用方的宽度保持不动。
- `etaf-pane-resizer` 完全不拥有状态，因此被拒绝的输入让每个已挂载的面板保持原样。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[面板与窗口](ui-panels-and-windows.md)。

```elisp :run
(etaf-view
 (row :width '(ch 48) :height '(lh 6)
   (box :width '(px 180) (text "Sidebar"))
   (etaf-pane-resizer :size 180 :side 'right :min 120 :max 320 :on-change #'ignore)
   (box :width '(ch 20) (text "Content"))))
```
