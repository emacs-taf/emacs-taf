# Host

*Host* 是拥有 Ebox 节点的 View 节点：Ebox 布局、设样式、绘制和命中测试都以它为单位。用户界面的每个可见部分都是 Host，View 里其他东西的存在都是为了组合、重复或替换 Host。本章定义八种 Host、它们接受的属性、多个来源的属性如何合并、Host 元数据如何变成选择器主体，以及解析 Host 引用、读取已提交几何的函数。

View 语法、属性表达式的求值时机和 Host 节点的身份，见 [View](views.md)。组件、`:use` Behavior 和调用者属性属于 [组件](components.md)与 [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)两章；样式属性如何声明与层叠，属于样式各章。本章是 Host 层本身的参考。

<!-- index: Host; Host 种类; 语义属性; Host 引用; 选择器主体; 几何查询 -->

## 模型

### 唯一拥有 Ebox 节点的 View 节点

View 是节点的树。View 挂载或渲染时，ETAF 把它降为一棵保留的段树；只有 Host 段拥有 Ebox 节点。

- Host 节点由 Host 名字（`text`、`box`、`fragment`、`row`、`column`、`flex`、`grid` 或 `image`）、属性和子节点写出。
- Host 段恰好拥有一个 Ebox 节点；`fragment` 没有节点，它的子节点直接并入所在布局。
- View 产生多个根时，渲染器会自己加一个 column 包装；包装不是 Host，也不带任何应用属性。
- 只有 Host 带样式属性、Host 引用和无障碍元数据，也只有 Host 能被几何查询测量。

Host 也是 View 里的身份单位：和解按名字和 `:key` 匹配 Host 子节点（见 [View](views.md#身份)），匹配上的 Host 保留它的 Ebox 节点和保留状态。

### 八种 Host

| Host | 内容 | 在布局中的默认角色 |
| --- | --- | --- |
| `text` | 恰好一个文本载荷 | 由父节点排布的文本 |
| `box` | 子节点 | 块级流式容器 |
| `fragment` | 子节点 | 无节点；子节点并入父节点 |
| `row` | 子节点 | 一行水平排布，不换行 |
| `column` | 子节点 | 垂直堆叠 |
| `flex` | 子节点 | flex 容器 |
| `grid` | 子节点 | 自动轨道的 grid |
| `image` | 无 | 固定 `:columns` × `:rows` 个字符格 |

每个 Host 都接受语义属性、事件属性和指针 affordance；`fragment` 没有节点来承载它们。样式属性按种类接受：

| Host 种类 | 接受的样式属性 |
| --- | --- |
| `text` | 排版与着色集：`:color`、`:background-color`、`:font-family`、`:font-size`、`:font-weight`、`:font-style`、`:text-decoration-line`、`:text-decoration-color`、`:text-decoration-style` |
| `box` | 上述集，加上 `:text-align`、`:wrap-mode`，以及盒模型与几何集 |
| `row`、`column` | Box 集，加上 `:cross-align` 和 `:item-gap` |
| `flex` | Box 集，加上 `:flex-direction`、`:flex-wrap`、`:flex-flow`、`:justify-content`、`:align-items`、`:align-content`、`:row-gap`、`:column-gap` 和 `:gap` |
| `grid` | Box 集，加上 `:grid-template-columns`、`:grid-template-rows`、`:grid-auto-columns`、`:grid-auto-rows`、`:grid-auto-flow`、`:justify-items`、`:justify-content`、`:align-items`、`:align-content`、`:row-gap`、`:column-gap` 和 `:gap` |
| `image` | 无；它的来源和大小来自 `:src`、`:columns`、`:rows`、`:adapter` 和 `:inset` |
| `fragment` | 无；它没有节点 |

`flex` 或 `grid` Host 的子节点还可以声明子项属性（`:order`、`:flex-grow`、`:flex-shrink`、`:flex-basis`、`:flex`、`:align-self`、`:justify-self`、`:grid-column`、`:grid-row`、`:grid-column-span`、`:grid-row-span`），它们影响父节点如何摆放该子项。样式属性从 schema 初值开始——没有 padding、margin 和 border，颜色继承，字重和字形为 normal，加上各 Host 条目里点名的布局初值——所以不带任何样式属性的 Host 也已经排好版。[样式属性参考](style-properties.md)列出每个属性的值语法、初值和继承。

```elisp :figure 八种 Host；fragment 是唯一不产生 Ebox 节点的
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 0)
   (grid :width '(ch 44)
         :grid-template-columns '((fr 1) (fr 1) (fr 1) (fr 1))
         :gap '((lh 0) (ch 1))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "text"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "box"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "row"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "column"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "flex"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "grid"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "image"))
     (box :padding '((lh 0) (ch 1)) :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
          (text :color (etaf-theme-token :ui-disabled-fg "#687386") "fragment")))
   (text :color (etaf-theme-token :ui-muted-fg "#526174") "fragment 不产生节点；其余七种各绑定一个 Ebox 节点。")))
```

## Host 种类

### text

#### Host: text

显示一段文本的 Host；多数界面的叶节点。

**语义。**

- 内容恰好一个载荷：字符串，或结果能解析成文本的 `expr`。第二个子节点是渲染错误，空字符串合法。
- 渲染器把它建成一个 Ebox 文本节点。Ebox 在它的父节点里排布它：`box` 里的 `text` Host 参与流式段落，`row` 里的则成为单行子项。
- 它接受排版与着色属性。`:padding`、`:width`、`:wrap-mode`、`:text-align` 这类布局属性属于排布文本的容器；Text Host 从祖先继承排版、颜色和 `:text-align`。
- 它的内容本身不可交互：除非 Text Host 自己声明交互属性，否则点击由最近的可激活祖先处理。

**错误。** 载荷不是文本时 `error→ etaf-renderer-error`，例如结构位置里的数字，或解析结果不是字符串的载荷。

**示例。** `(text :font-weight 'bold "Unread (3)")`

**参见。** `box`、`row` 和 `image` 三种 Host。

### box

#### Host: box

块级流式容器，通用布局 Host。

**语义。**

- 子节点按常规流排布。连续的行内子节点（通常是 `text` Host）组成一个匿名段落，因此写成多个文本节点的一句话会作为一个整体折行；块级子节点另起一行。
- 它接受完整的盒模型与几何集：padding、margin、border、width/height 及其 min/max 形式、`:box-sizing`、`:position`、`:left`/`:top`、`:z-index`、`:layer`、`:anchor`、`:placement`、`:visibility`、`:outer`、`:overflow`、`:scroll-anchor`、`:border-radius`、`:wrap-mode`、`:text-align`，以及 Box 作为 flex 或 grid 子项时的子项属性。
- `:overflow scroll` 或 `:auto` 配合有界高度会把 Box 变成滚动容器，细节见[滚动](scrolling.md)章。

**示例。** `(box :background-color "gray15" (text "Ready"))` 已经是一个可用的面板；`(box :padding '(px 4) :border-radius '(px 1) ...)` 再加上留白和圆角。

**参见。** 常见堆叠场景用 `column` 和 `row`；布局规则见[盒与常规流](boxes-and-normal-flow.md)。

### fragment

#### Host: fragment

没有 Ebox 节点的分组 Host。

**语义。**

- 渲染器把它的子节点按序插入所在布局，因此 fragment 不增加视觉盒子、间距和样式目标。组件返回多个根时就是这样做的，见 [fragment](views.md#fragment)。
- fragment 接受 `:key` 和编译器指令（`:if`、`:else-if`、`:else`、`:for`）。其他 Host 属性没有节点可以作用，会被忽略。

**示例。** `(fragment (text "left") (text "right"))` 把两个文本节点并排放进父节点。

**参见。** [fragment](views.md#fragment)。

### row

#### Host: row

把子节点排成一行的容器。

**语义。**

- 子节点从左到右摆放，不折行；比剩余空间宽的子节点会被压缩到剩余宽度，行的高度是最高的子节点。
- `:cross-align`（初值 `stretch`）沿垂直轴对齐子节点；`:item-gap`（初值零）设置横向间距。
- 它接受 Box 集加 `:cross-align` 和 `:item-gap`。内容需要折行或反向时用 `flex` Host；工具栏、按钮条、面包屑和单行状态栏用 `row`。

**示例。** `(row :item-gap '(ch 1) (text "Name:") (text (expr name)))`

**参见。** `column`，它垂直堆叠子节点，交叉轴与间距属性相同。

### column

#### Host: column

垂直堆叠子节点的容器。

**语义。**

- 子节点按序从上到下排布；`:cross-align` 沿水平轴对齐它们，`:item-gap` 设置纵向间距。
- 它接受 Box 集加 `:cross-align` 和 `:item-gap`。页面、表单和行列表的根通常用它。

**示例。** `(column :item-gap '(lh 1) ...heading... ...rows...)`

**参见。** `row`。

### flex

#### Host: flex

完整的 flex 容器。

**语义。**

- 方向、折行、主轴分布和交叉轴对齐由 flex 容器集决定：`:flex-direction`（初值 `row`）、`:flex-wrap`（初值 `nowrap`）、`:flex-flow`、`:justify-content`（初值 `flex-start`）、`:align-items` 与 `:align-content`（初值 `stretch`），加上 `:row-gap`、`:column-gap` 和 `:gap` 简写。
- 与 `row` 不同，flex 容器会换行、反向，并遵循子节点的子项属性，所以放不下的工具栏可以折到下一行。
- 它接受 Box 集加 flex 容器集。

**示例。** `(flex :flex-wrap 'wrap :gap '((lh 0) (px 2)) ...cards...)` 把卡片排成会折行的条带。

**参见。** [Flex 布局](flex-layout.md)。

### grid

#### Host: grid

带显式或自动轨道的 grid 容器。

**语义。**

- `:grid-template-columns` 和 `:grid-template-rows` 定义轨道；保持初值 nil 时 grid 自动创建轨道。`:grid-auto-columns`、`:grid-auto-rows` 和 `:grid-auto-flow` 控制显式模板之外的轨道与摆放；`:justify-items`（初值 `stretch`）、`:justify-content`、`:align-items` 和 `:align-content` 对齐子项与轨道组；`:row-gap`、`:column-gap` 和 `:gap` 设置间距。
- 子节点用子项属性 `:grid-column`、`:grid-row`、`:grid-column-span`、`:grid-row-span`、`:justify-self` 和 `:align-self` 摆放自己。
- 它接受 Box 集加 grid 容器集。

**示例。** `(grid :grid-template-columns '((fr 1) (fr 2)) ...cells...)` 得到一个两列表单，第二列宽度是第一列的两倍。

**参见。** [Grid 布局](grid-layout.md)。

### image

#### Host: image

固定大小的本地图片。

**语义。**

- `:src` 是本地文件路径，或 Emacs 图片描述符 `(image ... :type TYPE :file FILE)` / `:data DATA`。`:columns` 和 `:rows` 是图片的正整数字符格大小。
- `:adapter` 选择图片如何变成字符格：`auto`（初值）先尝试当前 frame 的图形图片，再尝试注册的转换器，最后是单色 ASCII 占位图；`text` 跳过图形；`placeholder` 总是生成 ASCII 形式。来源缺失或无法解码时生成占位图，而不是报错。
- `:inset` 是 nil 或 `(TOP . BOTTOM)`，即图形图片在行内上下各留空的像素数。
- image Host 不接受子节点；它是叶节点，`:padding`、`:color` 这类样式属性会被忽略，因为图片填满自己的格子。

**错误。** `:src` 不是路径或带 `:type` 与 `:file`/`:data` 的描述符、`:columns` 或 `:rows` 不是正整数、`:adapter` 不是 `auto`/`text`/`placeholder`、`:inset` 不是 nil 或非负的 pair、或给了子节点时，`error→ etaf-renderer-error`。

**示例。** `(image :src "/tmp/chart.png" :columns 40 :rows 10 :adapter 'placeholder)`

**参见。** [图像](images.md)。

## 语义属性

语义属性是 ETAF 自己的 Host 元数据：身份、无障碍、引用、Behavior、指针反馈、键盘操作和布局持续。它们不改变节点的视觉样式；它们到达 Runtime、Ebox 节点，或两者，本章把它们全部定义完。

语义属性在它的 Host 提交时校验。成功提交保留之前的状态；失败提交不为该 Host 发布任何东西，因此 Host 不会带着只应用了一半的属性集存在。事件属性（`:on-*`）是第三个领域，由[事件](events.md)定义，它们如何组合由 [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)定义。`:on-direction` 是键盘属性，在[键盘](keyboard.md)章定义。

### 值与冲突

一个 Host 可以从三处收到属性。内联属性写在 Host 自己身上。*透传属性*是调用者传给根节点是 Host 的组件调用的属性，合并进那个根 Host。`:use` 挂上的 Behavior 属性也合并进 Host。Theme 和组件样式提供的是 Ebox 层的输入，不是 Host 属性：主题的 Host 默认值和组件的样式规则由 Ebox 层叠在 Host 自己的声明之下应用。

合并让每个领域保持自洽：

| 属性 | 多个来源都提供时 |
| --- | --- |
| 样式属性 | 外层来源的非 nil 值替换内层值；nil 保持内层值；Behavior 的样式值只在 Host 没有时补入 |
| `:class` | 各值合并成一个稳定并集，内层 token 在前，重复去掉 |
| `:id` | 外层值替换内层值 |
| 事件属性 | 各回调串联，内层在前，且保留内层回调的返回值 |
| `:disabled` | 各值按 `or` 组合 |
| `:use` | Behavior 来源列表拼接 |
| `:keys` | 绑定列表合并；Host 自己的条目优先 |
| 其他语义属性 | 外层值替换内层值；Behavior 只在 Host 没有时补入 |
| `:role` 与多数 `:aria-*` | 归属语义：两个不同的值是冲突，不是覆盖 |

归属语义冲突时报错而不是静默覆盖，因为在调用者背后改掉控件的角色或无障碍状态，既会破坏无障碍约定，也会破坏已经匹配它的选择器。`:aria-label` 和 `:aria-description` 是例外：它们描述而不是标识，因此调用者可以替换。

**错误。** 透传或 Behavior 值与根 Host 的归属语义属性冲突时 `error→ etaf-component-call-error`；消息里给出组件或 Behavior 的名字、Host 种类和属性。

**参见。** 透传属性见[《组件》章](components.md)，`:use` 见 [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)。

### 角色与 ARIA

Host 的无障碍元数据是 Ebox 节点上的 `role` 属性和 `aria-*` 属性。它们是普通的选择器主体，样式表和测试都可以按角色或无障碍状态选择 Host，也是键盘层和焦点层读取的事实。

- `:role` 写入节点的 `role` 属性。`button`、`option`、`checkbox`、`slider` 这类角色在[焦点](focus.md)与[键盘](keyboard.md)章有约定行为。
- 每个 `:aria-*` 属性写入一个属性，名字是冒号后的部分。显式传 nil 仍会写入值为 nil 的属性，这与省略不同：nil 属性是存在的，测试该属性的选择器会匹配，Ebox 的继承阻塞也能分辨差别。
- 值是字符串、数字或符号；数字和符号转换成打印形式。列表或其他值以 `error→ etaf-renderer-error` 拒绝。
- `:role` 和标识类 `aria-*` 属性是上面说的归属语义属性；`:aria-label` 和 `:aria-description` 是描述性的，调用者可以替换。

**示例。** `(box :role "progressbar" :aria-valuenow 62 :aria-valuemin 0 :aria-valuemax 100 ...)`

**参见。** 角色特有行为见[焦点](focus.md)与[键盘](keyboard.md)章。

### 身份与元数据

#### Property: :class

选择器和组件样式匹配的一个或多个类名。

**参数。** 字符串、符号，或由字符串和符号组成的真列表。字符串按空白切分，列表被摊平，所以 `"task done"` 和 `'(task done)` 都得到类 `task` 和 `done`。默认是 nil，没有类。其他值被拒绝。

**语义。** 类写入 Ebox 节点并成为选择器主体：`.task` 这样的规则匹配该 Host，[组件样式与主题](component-styles-and-themes.md)解释组件自己的规则怎样使用它们。调用者属性或 Behavior 提供 `:class` 时，两组 token 合并成一个稳定并集，内层 Host 的 token 在前、重复去掉，因此调用者可以加类而不丢掉 Host 自己的类。

**示例。** `(text :class "status error" "Deployment failed")`

**错误。** 值不是字符串、符号或它们的列表、且节点被建立时 `error→ ebox-error`；合并后的值非法时 `error→ etaf-component-call-error`。

**参见。** [选择器主体](#选择器主体)与[组件样式与主题](component-styles-and-themes.md)。

#### Property: :id

Host 的标识符，被 `#name` 选择器匹配。

**参数。** 字符串、符号或数字，用作 token 值；nil 表示没有 id。

**语义。** 值作为节点的 id 写入，并成为选择器主体。调用者属性替换根 Host 的 id，不做合并。

**示例。** `(box :id "results" ...)` 配合规则 `#results { ... }`。

**参见。** [选择器主体](#选择器主体)。

### 无障碍与焦点

#### Property: :role

Host 的无障碍角色。

**参数。** 符号或字符串，或 nil。取值不限于 ARIA 词表；只要不是符号或字符串，ETAF 就拒绝。

**语义。** 非 nil 角色作为节点的 `role` 属性写入，并成为选择器主体。[焦点](focus.md)与[键盘](keyboard.md)章定义 `button`、`slider`、`separator`、`option` 这类角色如何参与焦点顺序、方向键和激活。`:role` 是归属语义：Host 一旦声明，调用者或 Behavior 就不能用不同的值替换它。

**示例。** `(text :role 'button :tab-index 0 :on-press #'retry "Retry")`

**错误。** 值不是符号、字符串或 nil 时 `error→ etaf-renderer-error`。

**参见。** `:aria-*`、[角色与 ARIA](#角色与-aria)。

#### Property: :aria-*

ARIA 命名空间里的一个属性；`:aria-*` 代表所有以 `:aria-` 开头的属性。

**参数。** nil、字符串、数字或符号。nil 是显式给出的值：它写入一个值为 nil 的存在属性，而不是省略属性。

**语义。** 该属性写入一个属性，属性名是冒号后的名字：`:aria-label` 写 `aria-label`，`:aria-selected` 写 `aria-selected`。该属性是选择器主体，Ebox 还会把部分属性当作状态读取（`aria-selected`、`aria-checked`、`aria-current`），用于焦点组选择入口。显式 nil 的存在有两重意义：针对该属性写的选择器会匹配，且内层 nil 在 Ebox 的继承规则里阻塞祖先的值。

**示例。** `(box :role "listbox" :aria-label "Open tabs" ...)`

**错误。** 值不是 nil、字符串、数字或符号时 `error→ etaf-renderer-error`。

**参见。** `:role`、[角色与 ARIA](#角色与-aria)。

#### Property: :tab-index

Host 在 Tab 顺序里的位置。

**参数。** nil 或整数。默认是 nil，表示该 Host 不是焦点停靠点。

**语义。** 非负整数让 Host 成为焦点停靠点：焦点导航可以按 Tab 进入和离开。停靠点按整数值排序，小的在前；整数相同的按树序，因此同一区域的控件会连续访问。没有 tab index 的 Host 仍可由指针激活，也仍可包含自己的焦点停靠点。导航模型其余部分见[焦点](focus.md)。

**示例。** `(row :tab-index 0 :on-press (lambda () (open item)) (text (expr item)))`

**错误。** 值不是整数或 nil 时 `error→ etaf-renderer-error`。

**参见。** [焦点](focus.md)章。

#### Property: :disabled

把 Host 标记为不可用而不移除它。

**参数。** nil 或 t。其他值被拒绝。默认是 nil。

**语义。** 禁用的 Host 不运行事件回调或 `:keys`；它的 Behavior 不安装；Ebox 给它一个空 keymap，因此禁用的控件会阻塞继承来的 keymap 而不是落回它；它的节点导出 `disabled` 选择器状态，样式表可以用 `:disabled` 匹配。Host 仍然可见，并保持它在布局中的位置。

**示例。** `(text :role 'button :tab-index 0 :disabled (not (etaf-value valid)) :on-press #'save "Save")`

**错误。** 值不是 nil 或 t 时 `error→ etaf-renderer-error`。

**参见。** 激活见[事件](events.md)，焦点见[焦点](focus.md)。

#### Property: :focus-group

让容器的焦点停靠点成为上层导航的一个停靠点。

**参数。** nil、`vertical`、`horizontal` 或 `grid`。默认是 nil。

**语义。** 带焦点组的容器在 Tab 顺序里只贡献它的入口：Tab 从记住的成员进入，没有记住的成员时进入 `aria-selected`、`aria-current` 或 `aria-checked` 为真的成员，再没有就进入第一个成员。组内方向键按声明的方向移动，越过边缘则移到组外最近的停靠点。嵌套的组属于最近的祖先组。

**示例。** `(column :focus-group 'vertical ...rows...)`

**错误。** 值不是 nil、`vertical`、`horizontal` 或 `grid` 时 `error→ etaf-renderer-error`。

**参见。** [焦点](focus.md)章。

#### Property: :key-scope

嵌套应用或窗格的非模态键盘边界。

**参数。** `local` 启用边界；nil 使 Host 不截断键盘作用域解析。

**语义。** 焦点位于 Host 内，或没有焦点而以 point 为回退起点时，最近的 local 或 modal 边界包含按键、关闭、方向与首尾导航、区域、帮助准备和命令面板控件。未绑定的可打印键与未处理的 Escape 不调用外层 Host 或缓冲区动作；原生编辑仍拥有自己的按键。子树仍持有焦点时，仅将 point 移到外面不会改变归属，真实焦点变化才会改变归属。指针操作和显式焦点、区域跳转可以离开 local 边界。关闭回调可以显式聚焦宿主应用而不销毁嵌套应用；同一 Host 上的区域会记住其合格入口控件。

**返回。** 此属性配置解析，没有独立返回值或第二份焦点状态。

**错误。** 不支持的值报告 `error→ etaf-renderer-error`。

**示例。** `(column :key-scope 'local :on-dismiss (lambda () (etaf-focus nil 'toolbar)) ...)`

**参见。** `:focus-scope`、`:region`、`:on-dismiss` 与[键盘交互](keyboard.md)。

#### Property: :focus-scope

把键盘操作限制在一棵子树内。

**参数。** nil 或 `modal`。默认是 nil。

**语义。** `modal` Host 可见期间，Tab、方向键和 `:keys` 优先在它里面解析；最内层的可见 modal 作用域获胜。外层 `:keys` 不可达，作用域内没有绑定任何东西的打印键会被忽略，而不是落到缓冲区自己的 keymap。对话框打开期间保持焦点就是用这个机制。

**示例。** `(box :focus-scope 'modal :role "dialog" ...)`

**错误。** 值不是 nil 或 `modal` 时 `error→ etaf-renderer-error`。

**参见。** [焦点](focus.md)与[键盘](keyboard.md)章。

#### Property: :region

在 Host 上声明一个用户可寻址的功能区域。

**参数。** 属性 plist，键为 `:id`（必需，一个非 nil 符号，标识该区域）、`:label`（显示名）、`:key`（一个提示字符，不能是 `?`）、`:enter`（默认入口 Host 引用）和 `:neighbors`（把 `:left`、`:right`、`:up`、`:down` 映射到区域 id 的 plist）。未知键被拒绝。

**语义。** 区域按 Host 祖先关系嵌套，因此窗口里的窗格在父区域里也能找到。[区域导航](region-navigation.md)章定义在区域间跳转的选择器、入口记忆，以及邻接如何决定移动方向。

**示例。** `(box :region (list :id 'editor :label "Editor" :key ?e :neighbors (list :right 'files)) ...)`

**错误。** plist 结构不对、键未知、`:id` 缺失或不是符号、`:key` 非法、或邻居方向不在四个方向内时，`error→ etaf-renderer-error`。

**参见。** [区域导航](region-navigation.md)。

### 引用与 Behavior

#### Property: :ref

应用用来拿到 Host 的句柄。

**参数。** nil、符号或函数。其他值被拒绝。

**语义。** 显式引用把已提交的 Host 注册在该值下，几何查询、焦点函数和事件函数都接受它。符号是最常见的形式；实例内的不透明句柄来自 `etaf-local-ref`。函数可作为不透明句柄，ETAF 从不调用它。没有非 nil 语义属性的 Host 不会被注册，也无法用引用找到；`:ref` 本身就是这样一个属性，所以显式引用总会注册。ETAF 还给每个 Host 一个内部生成的引用，应用拿不到。

两个已提交 Host 带同一显式引用时，后提交的获胜；它离开后，即使另一个 Host 还带着这个名字，引用也解析为空。因此显式引用是同一时刻一个 Host 的名字，不是共享别名。

**示例。** `(box :ref 'search-results ...)`，之后 `(etaf-host-ref-bounds runtime 'search-results)`。

**错误。** 值不是 nil、符号或函数时 `error→ etaf-renderer-error`。

**参见。** [Host 引用](#host-引用)与 `etaf-local-ref`。

#### Property: :use

给 Host 挂上一个或多个 Behavior。

**参数。** 一个 Behavior 来源：命名零参构造器的符号、用 `etaf-behavior-create` 创建的 Behavior spec，或由这些来源组成的真列表。nil 合法，表示不挂任何东西。

**语义。** 每个来源解析成一个 Behavior，其属性按[值与冲突](#值与冲突)所述合并进 Host：事件回调和 `:disabled` 组合，样式值只在 Host 没说的地方补入，归属语义属性冲突而不是覆盖。禁用的 Host 不安装任何 Behavior。构造函数、可选安装函数和清理见 [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)。

**示例。** `(text :use 'etaf-focusable "Open")`

**错误。** 值不是 Behavior 来源或由其组成的真列表时 `error→ etaf-renderer-error`；未知构造器、构造器返回别的东西、或同一 Host 上两个 Behavior 同名时 `error→ etaf-behavior-error`。

**参见。** [Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)。

### 呈现与指针反馈

#### Property: :help-echo

为 Host 显示的帮助文本。

**参数。** 字符串、原生三参数 `help-echo` 函数，或 nil。

**语义。** Ebox 把它画成节点的 `help-echo` 文本属性，因此指针停在 Host 上时 Emacs 会显示文本（或调用函数）。它不创建交互边界、keymap 或 ETAF hover 事件。显式 nil 会阻塞祖先的值。

**示例。** `(text :help-echo "Reload from disk" :on-press #'reload "Reload")`

**参见。** 视觉反馈见 `:hover-style` 和 `:hover-content`。

#### Property: :pointer

Host 的鼠标指针形状。

**参数。** Ebox 指针符号（如 `hand`），或 nil。

**语义。** 指针画成节点的 `pointer` 文本属性。有 press 或 drag 回调的 Host 若没有给出 `:pointer`，会自动获得 `hand` 指针；显式 nil 保持默认指针并阻塞祖先的值。

**示例。** `(text :pointer 'hand :on-press #'open "Read more")`

**参见。** `:help-echo` 和 `:hover-style` 所述的指针 affordance。

#### Property: :hover-style

指针悬停在 Host 上时显示的着色。

**参数。** 由着色属性组成的偶 plist：`:color`、`:background-color`、`:font-weight`、`:font-style`、`:text-decoration-line`、`:text-decoration-style` 和 `:text-decoration-color`。Theme token 按普通样式值解析。

**语义。** 指针停在 Host 上期间，Ebox 把这些声明合并到节点的计算样式上重绘整个节点，因此填充色会跟随 Host 自身的 `:border-radius` 并覆盖每一行内边距；未挂载的渲染文本则把同样的声明作为原生 mouse face 携带。指针离开后恢复静止样式。不支持的键或奇 plist 在节点绘制时报错。显式 nil 会为子树挡住悬停。

**示例。** `(row :hover-style (list :background-color "gray25") ...menu item...)`

**错误。** 属性不在着色列表内，或 plist 为奇数长度时 `error→ ebox-error`。

**参见。** `:hover-content`。

#### Property: :hover-content

悬停时用来替换 Host 内容的文本。

**参数。** 字符串，或返回字符串的零参函数；其他值被接受但不显示任何东西。nil 表示不替换。

**语义。** 指针在 Host 上期间——或键盘焦点进入它时，因为焦点显示与悬停相同的 affordance——ETAF 用该值替换 Host 第一个文本后代的文本，指针或焦点离开时恢复原文。紧凑格子借此显出一行完整标签、短路径显出长路径，或状态按需显示细节。Host 的其他属性保持生效，只有文本改变。

**示例。** `(text :hover-content "src/etaf-runtime.el (1420 lines)" "runtime.el")`

**参见。** `:hover-group`，它让多个 Host 一起切换。

#### Property: :drag-lock-modifier

让拖拽手势跨过按钮松开继续存活。

**参数。** `shift`、`control`、`meta`、`super`、`hyper` 之一，或 nil。默认是 nil，即松开按钮手势结束。

**语义。** 带锁定修饰键开始的拖拽，在按钮松开后仍保持活动，直到下一次按下；应用因此可以实现先点击再拖拽的序列，而不用一直按住按钮。该属性要求拖拽回调：没有拖拽手势的 Host 给出锁定修饰键时，挂载报错，因为没有手势可保持。

**示例。** `(box :on-drag (lambda (gesture) (move-panel gesture)) :drag-lock-modifier 'shift ...)`

**错误。** 修饰键不支持，或同一 Host 给出 `:drag-lock-modifier` 却没有拖拽回调时 `error→ error`。

**参见。** [拖拽与手势](dragging-and-gestures.md)。

#### Property: :drag-edge

拖拽停在或越过窗口边缘带时报告边缘意图。

**参数。** 任何非 nil 值启用这些阶段；nil 是默认值，手势保持安静。

**语义。** 从这个 Host 开始的拖拽进行中、已经离开按压点移动过，并且停在距窗口内侧边缘 `ebox-drag-edge-band` 行或列的范围内或越过了这条边时，Ebox 在 `ebox-drag-edge-interval` 秒后送出一个 `edge` 阶段，之后按同一间隔重复，直到指针退回窗口内部或手势结束。`:edges` 按固定顺序给出贴住或越过的边缘：`left`、`right`、`top`、`bottom`；角落会同时给出两个。该阶段只报告意图：Ebox 不滚动，也不修改 `:delta`；在边缘按下却没有移动时什么也不报告。越过边缘到了窗口外面，这些阶段照常继续：`:overshoot` 以像素给出指针越出文本区的距离，`:elapsed` 给出距上一个阶段的秒数，处理器因此可以让指针越远滚得越快。视口、滚动步长以及内容锚定目标如何跟随滚动都归应用所有；见[拖拽与手势](dragging-and-gestures.md#边缘意图与滚动)。

**示例。** `(box :on-drag (lambda (gesture) (when (eq (plist-get gesture :phase) 'edge) (scroll-view (plist-get gesture :edges)))) :drag-edge t ...)`

**参见。** [拖拽与手势](dragging-and-gestures.md#边缘意图与滚动)、`:on-drag`、`:drag-lock-modifier`。

#### Property: :hover-group

让多个 Host 共享一个悬停状态。

**参数。** 任何能当组键的值；nil 给 Host 自己的私有组。

**语义。** 同时带 `:hover-content` 和相同组键的每个 Host 一起切换悬停内容：悬停或聚焦其中任一成员，会显示所有成员的内容。成员不必是兄弟，只有一个成员的组与普通 `:hover-content` 一样。

**示例。** `(row (text :hover-group 'toolbar :hover-content "Bold (C-b)" "B") (text :hover-group 'toolbar :hover-content "Italic (C-i)" "I"))` 在任一按钮被悬停时显示两个完整标签。

**参见。** `:hover-content`。

### 布局持续

#### Property: :sticky

缓冲区滚动时让 Host 保持可见。

**参数。** nil 或 `top`。其他值被拒绝。默认是 nil。

**语义。** `top` Host 像粘性表头一样保持可达。窗口起点到达 Host 后，ETAF 把 Host 的第一行镜像进该窗口的 header line，并让窗口正文从 Host 之后开始，因此该行既不重复也不位移；point 在 Host 内时，Host 原位显示。点击镜像格子的主键会在该格子的缓冲区位置运行它的 press 绑定。sticky Host 挂载期间 Runtime 拥有缓冲区的 `header-line-format`，且每个 Runtime 只有一个 Host 是 sticky：最后提交的 `top` Host 获胜。

sticky 是行级 affordance：让 Host 保持单行，如工具栏或小节标题，而不是整个面板。

**示例。** 一个构建日志，滚动日志时表头保持可见。

```elisp :run
(etaf-view
 (column
  (row :sticky 'top :background-color "gray20"
       (text :font-weight 'bold "Build log"))
  (text :for (line '("12:01  configure"
                     "12:02  compile"
                     "12:03  link"
                     "12:04  test"
                     "12:05  package"
                     "12:06  publish"))
        :key line
        (expr line))))
```

**错误。** 值不是 nil 或 `top` 时 `error→ etaf-renderer-error`。

**参见。** [视口](viewport.md)和[滚动](scrolling.md)两章。

### 键盘操作

#### Property: :keys

声明在 Host 获得焦点或包含 point 时运行的 Host 键绑定。

**参数。** `(KEY COMMAND [LABEL])` 条目的列表：KEY 是 `kbd` 字符串或向量形式的键或键序列，COMMAND 是零参函数，可选的 LABEL 是字符串，在 ETAF 帮助面板里命名该命令。nil 表示不声明绑定。

**语义。** 焦点或（没有焦点时）point 在 Host 内时，绑定可用。绑定该键的最近 Host 获胜；禁用的 Host 不贡献任何东西；Host 绑定优先于缓冲区自己的 keymap，包括应用的模拟按键表。命令像 keymap 绑定一样运行，因此可以移动到或开始输入一个它刚刚显示出来的 Host；把多次写入包进 `etaf-batch` 可以只发布一次。键与区域共存：框架保留方向键、Tab、`?`、Escape、`M-g` 和 `C-g` 给焦点、帮助和区域导航，绑定不得与保留键或同一 Runtime 内别处的序列冲突。[键盘](keyboard.md)定义完整模型，包括前缀、保留键和诊断。

**示例。** `(row :tab-index 0 :keys (list (list "RET" (lambda () (open item)) "Open")) ...)`

**错误。** Host 提交时由键盘层给出 `error→ etaf-renderer-error`：条目结构不对、键为空、序列以打印键开头、绑定框架保留键，或与同一 Runtime 里另一个绑定冲突。

**参见。** [键盘](keyboard.md)，以及区域级导航的 `:region`。

#### Property: :help

为当前作用域的只读快捷键帮助补充非绑定说明。

**参数。** nil、字符串或字符串的正规列表。

**语义。** `etaf-help-data` 从打开位置的 Host 作用域由近及远收集这些说明，并在模态边界停止。说明用于工作流建议与限制；按键及其标签来自实际有效绑定，不应再手写一张重复键表。这不是原生悬停提示；悬停文字使用 `:help-echo`。

**错误。** 值不是 nil、字符串或字符串的正规列表时报 `error→ etaf-renderer-error`。

**示例。** `(column :help "Changes are kept when you leave the editor." ...)`

## 选择器主体

Host 的身份与无障碍元数据就是 Ebox 选择器查询匹配的事实：

- `:class` token 成为节点的类；`:id` 成为它的 id。
- 非 nil `:role` 成为 `role` 属性。
- 每个 `:aria-*` 属性，包括显式设为 nil 的，都成为名字为冒号后部分的属性。
- `disabled` 状态来自保护激活的同一个 `:disabled` 输入，因此提交时禁用的 Host 能被 `:disabled` 匹配。

选择器匹配沿着渲染后的 Host 树，而不是 View 树，比较使用 ECSS 的值格式化。适配器事实 `:selector-attributes` 和 `:selector-state` 是 Ebox 库用户附加额外主体的方式；它们不能作为 View 属性给出，ETAF 以 `error→ etaf-renderer-error` 拒绝。这个边界让组件样式和应用样式表按语义而不是按位置选择 Host；[组件样式与主题](component-styles-and-themes.md)在此基础上构建。

## Host 引用

#### Function: etaf-local-ref (name)

获取作用域为一个组件实例的稳定 Host 引用。

**参数。** NAME 是在该实例内命名引用的非 nil 符号或字符串。

**语义。**

- 在组件 setup 期间调用，从 `:bindings` 或 `:setup` 里。同一实例内相同的名字返回同一个不透明引用；不同实例从不共享，新实例得到新引用。把它传给 Host 的 `:ref`，或传给接受 Host 引用的焦点、事件和几何函数。
- 引用是名字，不是状态，也不是 key：它标识被挂上的 Host，而不是任何东西的当前值。
- 只有已提交的 Host 才解析引用。发布失败时保留之前的目标；带引用的 Host 被移除后几何查询返回 nil；后续实例不会继承旧句柄。

**返回。** 一个不透明的非 nil 引用值。

**错误。** 在组件 setup 之外调用，或 NAME 不是非 nil 符号或字符串时 `error→ etaf-component-definition-error`。

**示例。** 面板保留一个主体句柄，让调用者测量或滚动它。

```elisp
(etaf-define-component demo-panel ()
  :bindings ((body (etaf-local-ref 'body)))
  :view (box :ref body ...))
```

**参见。** `:ref`、[Host 引用](#host-引用)与[《组件》章](components.md)。

### 唯一性与生命周期

一个引用最多解析到一个已提交 Host。所以被移除 Host 的旧名字会解析为空，而不是回落到另一个仍带着它的 Host；应用也应给每个 Host 不同的引用。`etaf-local-ref` 按实例维持这一性质；手写符号则由应用自己负责。ETAF 给每个 Host 生成的引用是内部的：几何查询不返回它们，应用也不能把它们传进去。

## 几何查询

几何查询读取已挂载 Runtime 的*已提交*几何：Ebox 最后一次布局并绘制出来的结果。它们是只读的，不发布也不重新布局，Runtime 未挂载时抛错。改动排空之后再查询——写入发布之后，或 `etaf-runtime-flush` 之后——才能看到新几何，见[响应式系统](reactivity.md#恢复)。

#### Function: etaf-host-ref-bounds (runtime host-ref)

返回 Host 的实时缓冲区区段。

**参数。** RUNTIME 是已挂载的 Runtime。HOST-REF 是在它里面注册的显式引用。

**语义。** 结果是从 Host 第一个可见绘制格到最后一个绘制行末尾的 `(START . END)` pair。处于常规流中 `:visibility hidden` 的 Host 会报告它的空白占位；不拥有任何格子的 Host，或引用未注册时，返回 nil。

**返回。** buffer 位置组成的 pair，或 nil。

**错误。** RUNTIME 未挂载时 `error→ etaf-runtime-error`。

**示例。** 布局之后，按行的边界把它滚入视野，或让截图区域对齐面板。

**参见。** `etaf-host-ref-position`、`etaf-host-ref-size` 与[滚动](scrolling.md)章。

#### Function: etaf-host-ref-at (runtime &optional position predicate)

找出绘制在某个缓冲区位置的 Host 的显式引用。

**参数。** RUNTIME 是已挂载的 Runtime。POSITION 默认是 point。PREDICATE 非 nil 时是一个接受一个引用的函数，决定哪个 Host 可接受。

**语义。** 查询从绘制在 POSITION 处最内层的 Host 开始，沿已提交祖先向外走，返回第一个显式引用——有 PREDICATE 时返回它接受的第一个引用。生成引用从不返回，因此应用没有引用过的 Host 对这个查询不可见。按键处理函数借此把 point 对应到它所在的行；`etaf-host-ref-position` 是它的逆。

**返回。** 一个引用值；POSITION 外没有匹配 Host 时 nil。

**错误。** RUNTIME 未挂载时 `error→ etaf-runtime-error`。

**示例。** `(etaf-host-ref-at runtime (point) (lambda (ref) (string-prefix-p "row-" (symbol-name ref))))` 停在最内层名字像行的祖先上。

**参见。** `etaf-host-ref-position` 与[键盘](keyboard.md)。

#### Function: etaf-host-ref-size (runtime host-ref)

返回 Host 绘制出来的大小。

**参数。** RUNTIME 是已挂载的 Runtime。HOST-REF 是在它里面注册的显式引用。

**语义。** 结果是 Host 最后一次布局的已提交边框盒大小：`(WIDTH-PIXELS . HEIGHT-ROWS)`。margin 和相邻列不算在内，裁剪会缩小结果，不存在或完全隐藏的 Host 返回 nil。布局之后读取它来准备资源——比如判断预览装不装得下——不要逐帧轮询。

**返回。** `(WIDTH . HEIGHT)`，两者都是正数，或 nil。

**错误。** RUNTIME 未挂载时 `error→ etaf-runtime-error`。

**示例。** `(etaf-host-ref-size runtime 'preview)` 判断预览窗格能否显示一张图。

**参见。** `etaf-host-ref-bounds`。

#### Function: etaf-host-ref-position (runtime host-ref)

返回 Host 的第一个实时缓冲区位置。

**参数。** RUNTIME 是已挂载的 Runtime。HOST-REF 是在它里面注册的显式引用。

**语义。** 结果是 Host 在缓冲区里的起始位置。未被绘制的 Host，或引用未注册时，返回 nil。

**返回。** 一个 buffer 位置，或 nil。

**错误。** RUNTIME 未挂载时 `error→ etaf-runtime-error`。

**示例。** `(goto-char (etaf-host-ref-position runtime 'message-log))` 把 point 移到日志第一行。

**参见。** `etaf-host-ref-at`，它把位置映射回引用。

### 读取几何

这些查询共享同一套约定：

- 它们对已提交状态解析引用，因此看不到已移除的 Host，也看不到尚未排空的属性更新。
- 它们不发布：在 watch 或副作用里调用不会引起另一次渲染，也不得用来逐帧轮询。布局变化后再准备资源。
- 在确认 Runtime 已挂载后，可以安全地从普通应用代码（包括键盘处理函数）调用。
- 四个函数对未挂载 Runtime 都以 `error→ etaf-runtime-error` 拒绝。

## 语义细节

### Host 与它们的 Ebox 节点

每种 Host 降为一个 Ebox 节点：

| Host 种类 | Ebox 节点 |
| --- | --- |
| `text` | 装解析后载荷的文本节点 |
| `box`、`row`、`column`、`flex`、`grid` | 装子节点节点的容器节点 |
| `image` | 装准备好的图片的叶节点 |
| `fragment` | 无；它的子节点节点被插入父节点的子节点列表 |

映射是一 Host 对一节点，节点跟着 Host 走：和解按 Host 身份匹配段，匹配上的 Host 保留节点，原地更新属性和子节点；被移除的 Host 释放节点。

### 属性解析与代价

属性解析按 Host 进行：Host 段初始化或属性变化时，ETAF 求值该 Host 的延迟属性表达式一次，解析 Theme token，合并 Behavior，算出 Ebox 属性表。只有该表和已提交的不同时才更新节点。

- 属性和 Theme 都没变的 Host，更新时只付一次同一性比较。
- 只有普通样式值变化的 Host 走较轻的路径：把变化的值应用到保留节点，不重算元数据、Behavior 和子节点。
- key、语义或 Theme 变化走完整路径：Host 重新解析属性、重新注册引用、和解自己的 Behavior。
- 解析后的属性值中，样式属性到达节点；身份、无障碍和交互事实按[选择器主体](#选择器主体)的表和[事件](events.md)所述的交互边界分流。ETAF 自己保留一份语义属性副本，用于查询和事件分发。

因此一次 Host 更新的代价与该 Host 自己的属性成正比，而与 View 的大小或兄弟节点数量无关；只读静态值的 Host 在首次绑定之后不再有代价。

### Sticky Host

粘性机制由 Runtime 拥有，而不是布局。带 `:sticky top` 的 Host 提交时，Runtime 记录它；窗口起点到达该 Host 边界后，ETAF 把 Host 第一行镜像进该窗口的 header line，调整窗口起点让正文从 Host 之后开始，并在窗口滚回 Host 上方或 point 在 Host 内时移除镜像。因为 header line 属于窗口，机制按窗口生效：显示同一缓冲区的每个窗口可以各有各的状态。镜像是显示用的副本；Host 重绘时刷新，点击镜像格子会在它原来的缓冲区位置运行该格子的 press 绑定。

#### Function: etaf-projection (runtime entries &optional source)

返回由 ENTRIES 描述的 RUNTIME 投影。

**参数。** ENTRIES 是 （REF . （SOURCE-START . SOURCE-END）） 的 alist，每个条目对应一个 Host，它的绘制格子代表一段源文本。SOURCE 是源缓冲区，默认为运行时自己的缓冲区。

**返回。** 按显示位置排序的 run 向量，每个 run 是 （DISPLAY-BEG DISPLAY-END SOURCE-BEG SOURCE-END）。

**语义。** 它把「画在哪」与「来自源文本哪一段」连起来：不绘制任何东西的 Host，以及长度为零的源区间，都被跳过。投影是纯数据，点击映射与 caret 放置都从它读，而不是各自再遍历一次 Host 树。

**参见。** `etaf-projection-position`、`etaf-projection-source-offset`、[文本输入](text-input.md)。

#### Function: etaf-projection-source-offset (projection position)

返回绘制位置 POSITION 所代表的那段源文本偏移。

**参数。** PROJECTION 是 `etaf-projection` 的返回值；POSITION 是缓冲区位置。

**返回。** 一个源偏移。

**语义。** 正好落在 run 之后的位置算那一段源的结尾，也就是 caret 停在折行处时的位置。run 之外的任何位置报告最近 run 的边缘，第一个 run 之前的位置报告源的起点，所以映射处处有答案。

**参见。** `etaf-projection`、`etaf-projection-position`。

#### Function: etaf-projection-position (projection offset)

返回源偏移 OFFSET 所对应的绘制位置，没有对应时返回 nil。

**参数。** PROJECTION 是 `etaf-projection` 的返回值；OFFSET 是源文本偏移。

**返回。** 一个缓冲区位置，或 nil。

**语义。** run 内部的偏移映射到它的格子；绘制跳过的偏移——例如被渲染折叠掉的标记——映射到下一段 run 的起点，因此把 caret 放到折叠内容上不会失位。

**参见。** `etaf-projection`、`etaf-projection-source-offset`。

## 错误与恢复

Host 问题按发现它们的层分为几组。

| 失败 | 条件 | 留下什么 |
| --- | --- | --- |
| Host 种类不接受的样式属性，或 `:class` 值非法 | 节点建立时 `error→ ebox-error` | 该 Host 不发布任何东西；已挂载的先前状态保留 |
| 语义值非法，或给出 `:content`、`:selector-attributes` 这类只能由 Ebox 层拥有的属性 | Host 提交前 `error→ etaf-renderer-error` | 之前已提交的属性和引用继续生效 |
| 调用者或 Behavior 的归属语义属性冲突 | 合并期间 `error→ etaf-component-call-error` | 之前已提交的属性保留；冲突须由调用者解决 |
| Behavior 来源非法或 Behavior 重复 | 解析期间 `error→ etaf-behavior-error` | Host 保留之前的属性和 Behavior |
| `etaf-local-ref` 在 setup 之外，或名字非法 | 调用时 `error→ etaf-component-definition-error` | 不创建引用；组件实例不受影响 |
| 对未挂载 Runtime 做几何查询 | 调用时 `error→ etaf-runtime-error` | 查询不返回值，状态不变 |

恢复原则各处一致：Host 作为一个单位提交。失败时保留它之前的已提交状态——属性、节点、引用和 Behavior；由数据引起的失败会在下一次排空时重试，由非法属性引起的失败必须在源码里修好。被移除的 Host 对查询而言就是不存在：它的引用解析为空，几何查询返回 nil。
