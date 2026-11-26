# 容器

目录的容器组件给内容一个表面：一块带内边距、可选边框的区域，把属于一起的东西聚起来；还有一个分隔线，把各组分开而不自成元素。面板与卡片共享同一套表面结构——相同的内边距、相同的内部间隙、相同的三个主题 token——区别在于组织什么：面板命名一块区域并提供 header slot，卡片呈现带标题与描述的摘要。三者都是表现式、无状态的：它们不拥有应用数据，内容是调用方的 slot。[UI 组件库总论](ui-overview.md)定义目录契约，[值](values.md)定义内边距与间隙声明用到的长度语法，[组件样式与主题](component-styles-and-themes.md)定义表面读取的 token 机制。

## 面板与卡片表面

<!-- index: panel surface; card anatomy; flat variant; content order -->

表面是一个 column：上下各一行、左右各两列的内边距，子项之间一行间隙，并且——除非是 flat——带有来自面板 token 的前景、背景与一条细边框。内边距属于表面本身而不是内容，所以调用方的文字从框内开始，框一直伸到外层布局的边缘。空表面也仍显示它的内边距行；框是组件的一部分，不是有内容的副产物。

面板的子项顺序是标题、`header` slot、`default` slot。标题是代表面板的 strong label，于是一块区域读起来像带正文的标题；提供 `header` slot 让调用方自己组合头部内容，两者可以并存。没有标题也没有 header 的面板就是一个朴素的有框盒子。它的 `variant` 选择呈现：`flat` 去掉背景与边框但保留内边距，其它符号成为表面的第二个类名——调用方用静态规则给某一个面板换装而不注册组件的钩子。

卡片的子项顺序是标题、描述、`default` slot。标题是 strong label，描述是 muted label，于是这一对读作标题与辅助行；正文随后。卡片的 `variant` 只是一个类名：组件只提供一种外观，由调用方的规则或主题区分变体，而不是在内部切换绘制。卡片默认撑满可用宽，面板跟随 column 默认值，所以放进窄 row 的面板会收缩到内容宽。

两块表面都读同一组三个 token——`:ui-panel-fg`、`:ui-panel-bg` 与 `:ui-panel-border`——它们是声明被下降时才读取的延迟值。因此提供 Theme（包括响应式的）会让已挂载表面经绘制槽位换装，而不重渲染树；Theme 未定义某个键时，每个 token 回退到目录的内置值。

## 面板组件

<!-- index: etaf-panel; header slot; titled region -->

#### Component: etaf-panel (&key title variant)

渲染一个带标题、具名 header 与 default slot 的面板。

**参数。** TITLE 是可选字符串，渲染为 strong label；nil 则不渲染标题。VARIANT 是选择呈现的符号：`default`（默认）保留背景与边框，`flat` 去掉两者但保留内边距，其它符号追加到表面的类名。default slot 装面板正文，`header` slot 装调用方组合的头部内容。

**语义。** 表面是一个 column，上下各一行、左右各两列的内边距，子项之间一行间隙。内容顺序是标题、`header` slot、`default` slot。命名普通 Host 属性的未识别 prop 会落到表面的根 Host——例如 `:color` 覆盖面板正文前景——而既不是已声明 prop、也不是受支持 Host 属性的名字会被拒绝。

**返回。** 一个 View。

**错误。** VARIANT 不是符号时报 `error→ wrong-type-argument (symbolp)`，因为变体会成为类名。未知名字既不是已声明 prop 也不是 Host 属性时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-panel :title "Environment"
            :variant 'flat
            "All targets succeeded")
```

**参见。** `etaf-card`、`:ui-panel-fg`。

## 卡片组件

<!-- index: etaf-card; description line; variant class -->

#### Component: etaf-card (&key title description icon variant width text-align on-press)

渲染一个可复用的带标题表面，带 default 内容 slot。

**参数。** TITLE 是可选的 strong 标题；DESCRIPTION 是可选的 muted 辅助行；VARIANT 是追加到表面类名的符号。default slot 装卡片内容。

**语义。** 内容顺序是 TITLE、DESCRIPTION、default slot。表面使用与 `etaf-panel` 相同的内边距、间隙与面板 token，撑满可用宽，并将 TEXT-ALIGN 同时作用于标题行与正文内容。VARIANT 为语义强调值（`primary`、`info`、`success`、`warning`、`danger`、`important`）时，标题与左侧 3px 竖条取对应 Theme 强调色；`default`、`neutral` 及自定义名称保持默认面板边框与加粗标题并追加类名。传入 ON-PRESS 时整张卡片附带手形指针。

**返回。** 一个 View。

**错误。** 未知名字既不是已声明 prop 也不是 Host 属性时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-card :title "Build" :description "last run 2m ago"
           "All targets succeeded")
```

**参见。** `etaf-panel`、`:ui-panel-bg`。

```elisp :figure 面板与卡片两种表面
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 1)
   (etaf-panel :title "面板"
     (text "面板正文"))
   (etaf-card :title "卡片" :description "卡片描述")))
```

## 分隔线组件

<!-- index: etaf-divider; horizontal rule; vertical rule; separator label -->

#### Component: etaf-divider (&key orientation label)

渲染水平或垂直分隔线，可带居中标签。

**参数。** ORIENTATION 是 `horizontal`（默认）或 `vertical`。LABEL 是可选字符串；只在水平分隔线上渲染。

**语义。** 水平分隔线是一行高的 flex 线：两个等分增长的盒子在垂直中心用 `:ui-border` 画一条细线，有 LABEL 时标签坐在两者之间，左右各留一列间隙。标签是 muted 说明文字，读起来是线条的替代而不是内容。垂直分隔线是一列宽的盒子，用分隔线颜色作背景并拉伸高度；它没有标签。分隔线自身高度就是一个标准行，垂直分隔线填满容器给它的高度，所以需要可见线条时把它放进有尺寸的容器。

**返回。** 一个 View。

**错误。** ORIENTATION 既不是 `horizontal` 也不是 `vertical` 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-divider :label "or")
```

**参见。** `:ui-border`、[盒与常规流](boxes-and-normal-flow.md)。

## 表面 token

<!-- index: ui-panel-fg; ui-panel-bg; ui-panel-hover-bg; ui-panel-border; surface triple -->

#### Token: :ui-panel-fg

目录表面的前景。

**语义。** 面板与卡片用它绘制内容，目录的浮层表面也用同一个键作为自身前景。读取它的组件自带内置回退值，所以没有提供 Theme 时表面也能绘制。

#### Token: :ui-panel-bg

目录表面的背景。

**语义。** 面板与卡片内容之后的填充，也是浮层表面底板的填充。`flat` 面板变体有意省略它。

#### Token: :ui-panel-hover-bg

目录表面上可交互行或标题栏的悬停背景。

**语义。** 折叠手风琴标题等可交互目录表面用它绘制指针悬停反馈，以在浅色与深色主题下都保持清晰可读。Theme 未提供时由 `:ui-panel-bg` 派生。

#### Token: :ui-panel-border

目录表面的边框。

**语义。** 与 `:ui-panel-fg`、`:ui-panel-bg` 一起构成表面三件套；分隔线改用共享的 `:ui-border`，因为分隔线不是表面。

## 错误与恢复

- `error→ etaf-component-call-error` 报告分隔线被拒绝的 `:orientation`，以及表面组件收到的、既不是已声明 prop 也不是 Host 属性的未知名字，消息点名组件、属性与收到的值。
- `error→ wrong-type-argument (symbolp)` 报告面板变体不是符号的情况，因为变体被用作类名；卡片的变体被格式化为类名，因此接受任何值。
- 表面是无状态的：没有需要回滚的东西。经 slot 提供的内容属于调用方，保留调用方的 Context 与状态；被拒绝的调用不影响已挂载的表面。
- Theme 的拒绝发生在绘制之前：[组件样式与主题](component-styles-and-themes.md)说明非法提供的 Theme 如何被拒绝而不是发布。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)。

```elisp :run
(etaf-view
 (etaf-panel :title "Environment"
   (etaf-card :title "Build" :description "last run 2m ago"
              "All targets succeeded")
   (etaf-divider :label "or")
   (etaf-card :variant 'compact "Run a manual check")))
```
