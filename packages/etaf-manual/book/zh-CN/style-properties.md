# 样式属性参考

<!-- index: 样式属性; 属性参考; 值语法; 初值; 继承属性 -->

每个 Host 的外观与占位都由本章的样式属性决定。每个属性一个条目，给出它的值语法、初值、接受它的 Host、是否继承，以及改动影响绘制还是几何。

值语法是共用的，见[值](values.md)：带单位与尺寸函数的长度、颜色、字体、简写展开、继承与 CSS 全局关键字。本章逐个属性给出参考；在多个声明之间选出赢家的层是[样式系统总论](style-system.md)，schema 属性怎样变成绘制与几何属于[样式的实现](style-implementation.md)。

**条目的读法。** 首行是一张表：*值*是属性校验器接受的语法；*初值*是没有声明获胜时的计算值；*适用*是作者表单接受该属性的 Host；*继承*说明计算值是否流向后代；*影响*说明改动是重绘、重排还是两者。简写没有自己的计算值：它展开成条目里点名的 longhand，*初值*一栏留空。

表中「所有节点」指 `text`、`box`、`row`、`column`、`flex` 和 `grid` 的节点。`fragment` Host 没有自己的节点，`image` Host 因为图片填满自己的格子而忽略样式属性，所以两者都不接受。「所有非 `text` 节点」是同一集合去掉 `text`。

直接写在某个 Host 上而该 Host 种类不接受的样式属性，会在 View 发布时被拒绝，见 [Host](hosts.md)。值超出语法时，节点建立或更新时报错；该声明不会到达绘制或布局。

只有七个属性继承：`:color`、`:font-family`、`:font-size`、`:font-weight`、`:font-style`、`:text-align` 和 `:wrap-mode`。其余属性在每个节点上都从初值开始，只由显式声明与层叠组合。

```elisp :figure 七个可继承属性：color 与 font-weight 流进子节点，覆盖只影响自己这一支
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 0)
         :color (etaf-theme-token :ui-accent "#0969da")
         :font-weight 'bold
         (text "这一行继承颜色与字重。")
         (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "这一行覆盖颜色，字重仍继承。")
         (text :color (etaf-theme-token :ui-muted-fg "#526174") :font-weight 'normal
               "这一行两个属性都覆盖。")))
```

## 文字

<!-- index: 颜色; 字体; 文字装饰 -->

文字属性设置前景、字体和文字装饰。它们适用于所有节点，因为任何 Host 都能承载文字，而字体变化既影响绘制也影响测量。

#### Style: :color

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 颜色字符串或 `currentColor` | `nil` | 所有节点 | 是 | 绘制 |

设置节点文字的前景色。

**语义。** 字符串不解析色值，直接作为 face 前景；因此任何 face 颜色名都可用。`currentColor` 把前景留给默认 face，边框颜色与 `:text-decoration-color` 会把它解析成文字颜色。该值可继承，后代从父级的计算颜色开始。

#### Style: :font-family

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非空字符串或符号 | `nil` | 所有节点 | 是 | 绘制 + 几何 |

指定测量与绘制节点文字所用的字体族。

**语义。** 字体族同时进入 face 与文字测量，所以改动不仅改变外观，也可能改变节点尺寸。初值把选择留给默认的 frame 字体。该值可继承。

#### Style: :font-size

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 正数，正文的倍数 | `nil` | 所有节点 | 是 | 绘制 + 几何 |

以正文大小的倍数设置字号。

**语义。** 该值是裸的正数，范围 0.3 到 4，不是 `(UNIT NUMBER)` 长度；零、长度和超出这个范围的数会被拒绝，因为那是旧绝对接口留下的像素尺寸，会把整个界面成倍放大。1 是正文大小，1.42 是标题，0.85 是说明文字，所以每个尺寸都跟着读者自己的默认字体走，不假定以像素计的正文大小。字号决定字形度量、行测量和 face 高度，因此同时影响几何与绘制。该值可继承。

#### Style: :font-weight

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `normal`、`bold`、`bolder`、`lighter` 或 `100`–`900` | `normal` | 所有节点 | 是 | 绘制 + 几何 |

选择字重。

**语义。** 关键字或百位档映射到 face 字重并参与测量，所以更重的字重可能让文字变宽。该值可继承。

#### Style: :font-style

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `normal`、`italic` 或 `oblique` | `normal` | 所有节点 | 是 | 绘制 + 几何 |

选择字形倾斜；`:font-slant` 是别名。

**语义。** 该值选择对应的 face，并可继承。它和其他字体属性一样影响测量。

#### Style: :text-decoration-line

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `none`，或 `underline`、`overline`、`line-through` 的列表 | `none` | 所有节点 | 否 | 绘制 |

绘制一条或多条文字装饰线。

**语义。** 列表可组合多条装饰；重复的线会被拒绝，`none` 不绘制任何线。装饰覆盖节点自己的文字段。该属性不继承，所以 box 不会给后代的文字加装饰。

#### Style: :text-decoration-color

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 颜色字符串或 `currentColor` | `currentColor` | 所有节点 | 否 | 绘制 |

设置 `:text-decoration-line` 所绘装饰的颜色。

**语义。** `currentColor` 和 `nil` 使用节点的文字颜色；显式字符串覆盖它。该属性不继承。

#### Style: :text-decoration-style

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `solid`、`double`、`dotted`、`dashed` 或 `wavy` | `solid` | 所有节点 | 否 | 绘制 |

设置文字装饰线的线型。

**语义。** 该值投影到 face 的装饰线样式：`wavy` 选择波浪变体，其他关键字被接受并画成实线。该属性不继承。

## 尺寸

<!-- index: 宽度; 高度; 盒尺寸 -->

`:width`、`:height` 及其最小、最大搭档接受关键字和轴内长度，`:box-sizing` 决定尺寸量到哪里。行内长度解析成像素、块轴长度解析成行，百分比相对包含块。约束的解析算法见[盒与常规流](boxes-and-normal-flow.md)、[Flex 布局](flex-layout.md)、[Grid 布局](grid-layout.md)几章。

#### Style: :box-sizing

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `border-box` 或 `content-box`；其他值按 `border-box` 处理 | `border-box` | 所有非 `text` 节点 | 否 | 几何 |

选择 `:width` 和 `:height` 量的是边框盒还是内容盒。

**语义。** 用 `border-box`（初值）时，声明的尺寸包含 padding 与边框，所以 padding 或边框会压缩内容区。用 `content-box` 时，声明的尺寸是内容盒，padding 与边框加在外侧：宽 20px、padding 2px、边框 1px 时，边框盒占 26px。

#### Style: :width

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `auto`、`stretch`、`min-content`、`max-content`、`fit-content` 或行内轴长度 | `auto` | 所有非 `text` 节点 | 否 | 几何 |

设置节点边框盒的行内尺寸。

**语义。** `auto` 适应可用空间，`stretch` 填满可用空间，`min-content` 与 `max-content` 取节点的固有宽度，`fit-content` 把固有宽度夹在可用空间内。长度相对包含块宽度解析，用行内轴单位。`:min-width` 与 `:max-width` 对结果做夹取。

#### Style: :min-width

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `:width` 的关键字或行内轴长度 | `auto` | 所有非 `text` 节点 | 否 | 几何 |

从下方限制行内尺寸。

**语义。** 最小值在 `:width` 解析之后生效。只有长度或百分比设边界；`auto`、`stretch` 和内容关键字都不设，百分比相对包含块宽度解析。

#### Style: :max-width

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `none`，或 `:width` 的关键字或行内轴长度 | `none` | 所有非 `text` 节点 | 否 | 几何 |

从上方限制行内尺寸。

**语义。** 长度或百分比在 `:width` 与 `:min-width` 之后限制解析出的宽度；其他关键字（含 `none`）不做限制。

#### Style: :height

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `auto`、`stretch`、`min-content`、`max-content`、`fit-content` 或块轴长度 | `auto` | 所有非 `text` 节点 | 否 | 几何 |

设置节点边框盒的块轴尺寸。

**语义。** `auto` 随内容增长，`stretch` 在有定高包含块时填满它，长度相对包含块高度按行解析；内容关键字被接受，并与 `auto` 一样按内容定尺寸。`:overflow` 为 `visible` 的盒子超过定高时继续增高，而不是裁剪内容。`:min-height` 与 `:max-height` 携带长度时对结果做夹取。

#### Style: :min-height

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `:height` 的关键字或块轴长度 | `auto` | 所有非 `text` 节点 | 否 | 几何 |

从下方限制块轴尺寸。

**语义。** 只有长度或百分比设边界；`auto` 与其他关键字都不设，并按行相对包含块高度解析。

#### Style: :max-height

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `none`，或 `:height` 的关键字或块轴长度 | `none` | 所有非 `text` 节点 | 否 | 几何 |

从上方限制块轴尺寸。

**语义。** 长度或百分比限制解析出的高度；其他关键字（含 `none`）不做限制。`:overflow visible` 时盒子仍按内容增高。

## 内外边距

<!-- index: padding; margin; 逻辑边 -->

padding 在边框盒内侧加空间，margin 在外侧加空间。每条物理边有一个 longhand，每条逻辑边也有一个：`:padding-top` 是 block-start 边，`:padding-right` 是 inline-end 边，`:padding-bottom` 是 block-end 边，`:padding-left` 是 inline-start 边，margin 用同一套对应关系。节点同时声明物理边和对应逻辑边时，非初值的逻辑值获胜。

两族属性都取所在边的轴单位：上下边用块轴单位，左右边用行内轴单位。行内边的百分比相对包含块宽度解析；块轴上的百分比虽然被语法接受，但没有百分比基准、不占空间，所以块轴间距用 `lh`。padding 与 margin 都不接受负值。

块轴 padding 可以取小数。`:padding-block (lh 0.5)` 占一整行的空间，但背景只画半行，药丸和气泡因此能获得均匀的纵向留白而不破坏行网格。

#### Style: :padding

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–4 个边长，或带 `:top`、`:right`、`:bottom`、`:left` 键的 plist | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

一次声明设置四边的 padding。

**语义。** 值按 CSS 规则展开成逻辑 longhand：1 值四边、2 值上下与左右、3 值上、左右、下，4 值上、右、下、左。关键字 plist 必须给全四边，直接展开。每条展开出的声明单独校验，所以某个轴不合法的值会在那条边上被拒绝。

#### Style: :padding-inline

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–2 个行内轴长度 | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

设置 inline-start 与 inline-end 边的 padding。

**语义。** 1 值同时作用于两边，2 值先 start 后 end。展开出的 longhand 用行内轴单位。

#### Style: :padding-block

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–2 个块轴长度 | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

设置 block-start 与 block-end 边的 padding。

**语义。** 1 值同时作用于两边，2 值先 block-start 后 block-end。展开出的 longhand 用块轴单位，可以取小数。

#### Style: :padding-top

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

在边框盒内侧的上边加空间。

#### Style: :padding-right

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

在边框盒内侧的右边（inline-end 边）加空间。

#### Style: :padding-bottom

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

在边框盒内侧的下边（block-end 边）加空间。

#### Style: :padding-left

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

在边框盒内侧的左边（inline-start 边）加空间。

#### Style: :padding-block-start

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

在边框盒内侧的 block-start 边加空间，即上边的逻辑名。

#### Style: :padding-inline-end

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

在边框盒内侧的 inline-end 边加空间，即右边的逻辑名。

#### Style: :padding-block-end

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

在边框盒内侧的 block-end 边加空间，即下边的逻辑名。

#### Style: :padding-inline-start

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

在边框盒内侧的 inline-start 边加空间，即左边的逻辑名。

#### Style: :margin

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–4 个边长，或带 `:top`、`:right`、`:bottom`、`:left` 键的 plist | — | 所有非 `text` 节点 | 否 | 几何 |

一次声明设置四边的 margin。

**语义。** 值按与 `:padding` 相同的规则展开成逻辑 longhand。每条展开出的声明单独校验。

#### Style: :margin-inline

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–2 个行内轴长度 | — | 所有非 `text` 节点 | 否 | 几何 |

设置 inline-start 与 inline-end 边的 margin。

**语义。** 1 值同时作用于两边，2 值先 start 后 end。

#### Style: :margin-block

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–2 个块轴长度 | — | 所有非 `text` 节点 | 否 | 几何 |

设置 block-start 与 block-end 边的 margin。

**语义。** 1 值同时作用于两边，2 值先 block-start 后 block-end。

#### Style: :margin-top

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 几何 |

在边框盒外侧的上边加空间。

#### Style: :margin-right

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 几何 |

在边框盒外侧的右边（inline-end 边）加空间。

#### Style: :margin-bottom

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 几何 |

在边框盒外侧的下边（block-end 边）加空间。

#### Style: :margin-left

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 几何 |

在边框盒外侧的左边（inline-start 边）加空间。

#### Style: :margin-block-start

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 几何 |

在边框盒外侧的 block-start 边加空间，即上边的逻辑名。

#### Style: :margin-inline-end

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 几何 |

在边框盒外侧的 inline-end 边加空间，即右边的逻辑名。

#### Style: :margin-block-end

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 几何 |

在边框盒外侧的 block-end 边加空间，即下边的逻辑名。

#### Style: :margin-inline-start

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 几何 |

在边框盒外侧的 inline-start 边加空间，即左边的逻辑名。

## 边框与圆角

<!-- index: 边框; 圆角; 描边宽度 -->

边框宽度用描边单位——`px`、`ch`、`lh`、`vw`、`vh`，不允许百分比——并且只有该边样式为 `solid` 时才绘制；`none` 与 `solid` 是仅有的边框样式。左右边框按解析出的像素宽画成像素空格。上下边框变成该行的 overline 与 underline，因此最多 1 像素：上边框或下边框超过 1px 时，节点建立或更新会报 `ebox-error`。

边框颜色是字符串或 `currentColor`，`currentColor` 使用节点的文字颜色。`:border-radius` 在图形 frame 上给绘制的盒背景和受支持的完整描边加圆角；终端画方角。

#### Style: :border

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 任意顺序的宽度、样式、颜色，或单个值 | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

一次声明设置四条边框。

**语义。** 单个长度设置该宽度并配 `solid`；`solid` 或 `none` 设置 1px 宽度与该样式；字符串设置 1px `solid` 且用该颜色。列表按元素类型识别，可以省略分量：缺省宽度 `(px 1)`、缺省样式 `solid`、缺省颜色不设，因此跟随文字颜色。同一分量重复会被拒绝。

#### Style: :border-top

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 任意顺序的宽度、样式、颜色，或单个值 | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

一次声明设置上边框的宽度、样式与颜色。

**语义。** 展开与分量识别同 `:border`；只设置上边。

#### Style: :border-right

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 任意顺序的宽度、样式、颜色，或单个值 | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

一次声明设置右边框的宽度、样式与颜色。

**语义。** 展开与分量识别同 `:border`；只设置右边。

#### Style: :border-bottom

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 任意顺序的宽度、样式、颜色，或单个值 | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

一次声明设置下边框的宽度、样式与颜色。

**语义。** 展开与分量识别同 `:border`；只设置下边。

#### Style: :border-left

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 任意顺序的宽度、样式、颜色，或单个值 | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

一次声明设置左边框的宽度、样式与颜色。

**语义。** 展开与分量识别同 `:border`；只设置左边。

#### Style: :border-width

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–4 个非负描边长度 | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

一次声明设置四条边框的宽度。

**语义。** 值遵循 TRBL 规则：1 值四边、2 值上下与左右、3 值上、左右、下，4 值上、右、下、左。

#### Style: :border-style

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–4 个 `none` 或 `solid` | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

一次声明设置四条边框的样式。

**语义。** 值遵循 TRBL 规则，展开到四条物理样式 longhand。

#### Style: :border-color

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–4 个颜色字符串或 `currentColor` | — | 所有非 `text` 节点 | 否 | 绘制 |

一次声明设置四条边框的颜色。

**语义。** 值遵循 TRBL 规则，展开到四条物理颜色 longhand。

#### Style: :border-top-p

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `t` 或 `nil` | — | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

打开或关闭上边框。

**语义。** `t` 设置 1px `solid` 上边框，`nil` 把宽度设为 0、样式设为 `none`；不接受其他值。在行上方画分隔线时用它最紧凑。

#### Style: :border-top-width

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负描边长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

设置上边框的描边宽度，最多 1 像素。

#### Style: :border-right-width

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负描边长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

设置右边框的描边宽度。

#### Style: :border-bottom-width

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负描边长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

设置下边框的描边宽度，最多 1 像素。

#### Style: :border-left-width

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负描边长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

设置左边框的描边宽度。

#### Style: :border-top-style

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `none` 或 `solid` | `none` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

选择上边框样式。

#### Style: :border-right-style

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `none` 或 `solid` | `none` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

选择右边框样式。

#### Style: :border-bottom-style

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `none` 或 `solid` | `none` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

选择下边框样式。

#### Style: :border-left-style

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `none` 或 `solid` | `none` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

选择左边框样式。

#### Style: :border-top-color

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 颜色字符串或 `currentColor` | `currentColor` | 所有非 `text` 节点 | 否 | 绘制 |

设置上边框颜色。

#### Style: :border-right-color

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 颜色字符串或 `currentColor` | `currentColor` | 所有非 `text` 节点 | 否 | 绘制 |

设置右边框颜色。

#### Style: :border-bottom-color

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 颜色字符串或 `currentColor` | `currentColor` | 所有非 `text` 节点 | 否 | 绘制 |

设置下边框颜色。

#### Style: :border-left-color

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 颜色字符串或 `currentColor` | `currentColor` | 所有非 `text` 节点 | 否 | 绘制 |

设置左边框颜色。

#### Style: :border-radius

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 绘制 |

在图形 frame 上给绘制的盒背景和完整的单像素描边加圆角。

**语义。** 支持 SVG 时，完整、同色的 1 px solid 边框会在首末行的两个角落都只含空白 padding 时绘制圆角。描边半径不超过一标准行及盒宽高的一半。应留足 padding，让文字或媒体避开角落；否则该行保留方角描边，而不是覆盖内容。中间仍是原生文字，标题色带保留自身背景，几何、焦点与激活不变。非均匀或不完整的边框、无 SVG 支持及终端保留方角描边。没有描边时的背景圆角行为不变；终端画方角、整行的背景。

## 背景与可见性

<!-- index: 背景色; 可见性 -->

`:background-color` 在内容背后绘制盒背景，并传给没有自身背景的后代。`:visibility hidden` 抑制整棵子树的墨迹，同时保留它的布局空间。

#### Style: :background-color

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 颜色字符串 | `nil` | 所有节点 | 否 | 绘制 |

在节点内容背后绘制它的盒子。

**语义。** 字符串不解析色值，直接交给 face。该属性不继承，但没有自身背景的节点会绘制最近有背景的祖先的背景，因此面板背景能透到后代。图形 frame 上 `:border-radius` 会给绘制的背景加圆角。

#### Style: :backdrop-filter

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `nil` 或 `(brightness AMOUNT)` | `nil` | 所有非 `text` 节点 | 否 | 绘制 |

调暗浮层盖住的单元格，同时保留其中的文字与图片。

**语义。** AMOUNT 为非负数字：小于 1 时调暗每个被覆盖像素，等于 1 时不变，大于 1 时提亮，每个颜色通道封顶在最大值。被覆盖文本单元格的有效前景与背景色乘以 AMOUNT，包括嵌套继承 face 和画布 remap 后的默认颜色。支持 SVG 的图形 frame 上，自包含的 PNG、JPEG 与 SVG display 对 sRGB 通道作乘法，保留 alpha、原生 `currentColor`、尺寸、切片和行内 inset。经 `ebox-image-prepare` 准备的文件来源是自包含的；仅含文件的原生 display、其它原生格式及无 SVG 的 frame 保留原图像素，不会把它隐藏。图像合成在内存中缓存，不读取来源或执行外部转换；嵌套滤镜按堆叠顺序应用。移除浮层后恢复原始图像描述符。被滤镜节点自身的空白单元格显示背后调暗的像素，因此一个没有背景、带 `:backdrop-filter` 的全屏盒子会调暗整页而不隐去它，而节点自己绘制的单元格会盖住调暗像素。借用的像素只保留绘制结果：命中身份、原生 keymap、指针、帮助和悬停反馈来自覆盖节点，而非背景文字。因此遮罩可以处理外部点击而不激活被盖住的控件。只用不透明 `:background-color` 纯覆盖的模态背景仍会遮住背后的内容。

合成只过滤浮层空白单元格实际借用的背景片段，不先过滤整条被覆盖的行。每个借用片段用同一个独立副本完成绘制和覆盖层输入属性的赋予，共享来源字符串保持不变。这减少了模态框内部更新时的临时分配，也不需要另存一份持有回调的背景字符串缓存。

#### Style: :visibility

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `visible` 或 `hidden` | `visible` | 所有非 `text` 节点 | 否 | 绘制 |

在不改变布局的前提下隐藏或显示节点及其子树。

**语义。** `hidden` 抑制节点及其下方一切的墨迹，但保留它们的空间，邻项不会移动。它有意不继承：每个节点在绘制时自己检查取值和祖先，因此隐藏一个节点不会重算后代的样式。其他值都正常绘制。

## 行与列

<!-- index: 主轴间隔; 交叉轴对齐 -->

`row` 与 `column` 沿一条轴摆放直接子节点。`:item-gap` 设置主轴间隔，`:cross-align` 设置交叉轴对齐；完整算法见 [Flex 布局](flex-layout.md)。

#### Style: :item-gap

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负主轴长度 | `(px 0)` | `row` 与 `column` | 否 | 几何 |

设置 row 或 column 直接子节点之间的主轴间隔。

**语义。** row 用行内轴单位，column 用块轴单位。间隔只插在相邻子节点之间，首项之前和末项之后都不加。

#### Style: :cross-align

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `start`、`center`、`end` 或 `stretch` | `stretch` | `row` 与 `column` | 否 | 几何 |

沿交叉轴对齐 row 或 column 的直接子节点。

**语义。** `stretch` 让子节点填满容器的交叉尺寸；`start`、`center` 和 `end` 把子节点放在容器交叉轴的开头、中间或末尾。

## Flex

<!-- index: flex 容器; flex 项; 间隔 -->

`flex` 容器用本节中的容器属性分配与对齐直接子节点，子节点则使用项属性。`:gap`、`:row-gap` 和 `:column-gap` 与 `grid` 共用，`:justify-content`、`:align-items` 和 `:align-content` 也适用于 `grid` 容器。算法见 [Flex 布局](flex-layout.md)；本节给出每个属性的语法与作用。

#### Style: :flex-direction

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `row`、`row-reverse`、`column` 或 `column-reverse` | `row` | `flex` | 否 | 几何 |

设置 flex 容器的主轴。

**语义。** `row` 与 `row-reverse` 水平摆放子节点，`column` 与 `column-reverse` 垂直摆放。反向改变的是摆放方向而不只是可见顺序，`:justify-content` 随之改变。

#### Style: :flex-wrap

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `nowrap`、`wrap` 或 `wrap-reverse` | `nowrap` | `flex` | 否 | 几何 |

允许子节点换成多行，并设置各行的交叉轴方向。

**语义。** `nowrap` 保持一行，`wrap` 沿交叉方向开新行，`wrap-reverse` 从相反一侧开新行。

#### Style: :flex-flow

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 任意顺序的一个方向加一个换行关键字 | — | `flex` | 否 | 几何 |

一次声明设置 `:flex-direction` 与 `:flex-wrap`。

**语义。** 两个元素按类型识别，顺序随意；不是恰好一个方向加一个换行关键字的值会被拒绝。

#### Style: :justify-content

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `normal`、`start`、`end`、`flex-start`、`flex-end`、`center`、`stretch`、`space-between`、`space-around` 或 `space-evenly` | `flex-start` | `flex` 与 `grid` | 否 | 几何 |

沿主轴分配子节点。

**语义。** `start` 与 `flex-start` 靠头排、`end` 与 `flex-end` 靠尾排、`center` 居中。`space-between`、`space-around` 和 `space-evenly` 分配剩余空间。flex 容器里 `normal` 与 `stretch` 靠头排；grid 里 `stretch` 与 `normal` 把轨道撑满容器。

#### Style: :align-items

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `normal`、`start`、`end`、`stretch`、`flex-start`、`flex-end`、`center` 或 `baseline` | `stretch` | `flex` 与 `grid` | 否 | 几何 |

在 flex 容器的交叉轴上对齐子节点，在 grid 里让子节点在各自区域内对齐。

**语义。** `stretch` 填满交叉尺寸，`start`、`end`、`center` 和 `baseline` 摆放子节点，`normal` 与 `stretch` 相同。`baseline` 被接受，并按 `start` 对齐。单项可用 `:align-self` 覆盖。

#### Style: :align-content

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `normal`、`start`、`end`、`stretch`、`flex-start`、`flex-end`、`center`、`space-between`、`space-around` 或 `space-evenly` | `stretch` | `flex` 与 `grid` | 否 | 几何 |

沿交叉轴分配 flex 容器的行，或 grid 的轨道。

**语义。** 它接受与 `:justify-content` 相同的分配关键字。`stretch` 把行或轨道撑满容器，其他关键字在它们之间分配剩余空间。

#### Style: :row-gap

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负块轴长度 | `(lh 0)` | `flex` 与 `grid` | 否 | 几何 |

设置 flex 行之间与 grid 行之间的间隔。

**语义。** 值用块轴单位解析，百分比用包含块高度。

#### Style: :column-gap

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负行内轴长度 | `(px 0)` | `flex` 与 `grid` | 否 | 几何 |

设置 flex 项之间与 grid 列之间的间隔。

**语义。** 值用行内轴单位解析，百分比用包含块宽度。

#### Style: :gap

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 1–2 个非负长度 | — | `flex` 与 `grid` | 否 | 几何 |

一次声明设置 `:row-gap` 与 `:column-gap`。

**语义。** 1 值同时作用于两轴，因此必须对两轴都合法——零或百分比——2 值先行后列。这是给工具栏项加间隔的常用写法。

```elisp :run
(etaf-define-component demo-gap-toolbar ()
  :view (flex :gap '((lh 0) (ch 2))
              (text :color "#e5e7eb" "Save")
              (text :color "#e5e7eb" "Cancel"))
  :styles (("&" :background-color "#1f2937")))
(etaf-view (demo-gap-toolbar))
```

#### Style: :order

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 整数 | `0` | 所有非 `text` 节点 | 否 | 几何 |

改变 flex 容器摆放子节点的顺序。

**语义。** 子节点按值升序摆放；值相同保持文档顺序。它作用于 flex 或 grid 容器的直接子节点。

#### Style: :flex-grow

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负数字 | `0` | 所有非 `text` 节点 | 否 | 几何 |

设置该项能拿走多少主轴剩余空间。

**语义。** 剩余空间按因子成比例分配。初值让项保持自己的基准尺寸。[Flex 布局](flex-layout.md)说明增长如何与最小、最大尺寸相互作用。

#### Style: :flex-shrink

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负数字 | `1` | 所有非 `text` 节点 | 否 | 几何 |

设置行溢出时该项收缩多少。

**语义。** 收缩量按因子乘以基准尺寸成比例分配；`0` 让项保持基准尺寸，因此它可能溢出而不是收缩。

#### Style: :flex-basis

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `auto`、`min-content`、`max-content`、`fit-content`、`stretch` 或非负长度 | `auto` | 所有非 `text` 节点 | 否 | 几何 |

设置分配剩余空间之前项的初始主轴尺寸。

**语义。** `auto` 使用项的主轴尺寸属性——row 上是 `:width`，column 上是 `:height`。长度接受全部长度单位，因为声明时还不知道项的轴。

#### Style: :align-self

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `auto`、`normal`、`start`、`end`、`stretch`、`flex-start`、`flex-end`、`center` 或 `baseline` | `auto` | 所有非 `text` 节点 | 否 | 几何 |

为单项覆盖 `:align-items`。

**语义。** `auto` 跟随容器的 `:align-items`；其他值只作用于该项。`normal` 按 `stretch` 对齐，`baseline` 按 `start` 对齐。

#### Style: :flex

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 非负数字、`none`、`auto`、`initial`，或 `(grow shrink basis)` | — | 所有非 `text` 节点 | 否 | 几何 |

一次声明设置项的 grow、shrink 与 basis。

**语义。** 数字 N 展开成 `:flex-grow N`、`:flex-shrink 1` 和 `:flex-basis (% 0)`；`none` 是 0 0 auto，`auto` 是 1 1 auto，`initial` 是 0 1 auto；三元素列表直接给出三个 longhand。

## Grid

<!-- index: grid 模板; grid 放置; 轨道 -->

`grid` 容器把子节点放在显式与隐式轨道上。轨道列表由固定尺寸、内容尺寸、分数单位、`(minmax MIN MAX)` 和 `(repeat N TRACK)` 组成；放置位置从 1 起算。尺寸与放置算法见 [Grid 布局](grid-layout.md)；本节给出每个属性的语法与作用。

#### Style: :grid-template-columns

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `nil` 或列轨道列表 | `nil` | `grid` | 否 | 几何 |

定义 grid 的显式列轨道。

**语义。** 一条轨道是 `auto`、`min-content`、`max-content`、非负行内轴长度、`(fr N)`（N 为正数）、`(minmax MIN MAX)`（最小值不能是分数）或 `(repeat N TRACK)`（TRACK 是一条轨道或轨道列表，N 为正整数）。分数轨道分配剩余空间。

#### Style: :grid-template-rows

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `nil` 或行轨道列表 | `nil` | `grid` | 否 | 几何 |

定义 grid 的显式行轨道。

**语义。** 语法与 `:grid-template-columns` 相同，长度用块轴单位。

#### Style: :grid-auto-columns

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `auto`、单条轨道，或含一条轨道的一元列表 | `auto` | `grid` | 否 | 几何 |

为自动放置产生的隐式列定尺寸。

**语义。** 一条轨道，语法与模板列表相同，但不含 `repeat`。

#### Style: :grid-auto-rows

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `auto`、单条轨道，或含一条轨道的一元列表 | `auto` | `grid` | 否 | 几何 |

为自动放置产生的隐式行定尺寸。

**语义。** 一条轨道，语法与模板列表相同，不含 `repeat`，长度用块轴单位。

#### Style: :grid-auto-flow

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `row` 或 `column` | `row` | `grid` | 否 | 结构 |

选择自动放置沿哪条轴填充 grid。

**语义。** `row` 逐行填充并添加隐式行；`column` 逐列填充并添加隐式列。

#### Style: :grid-column

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `nil`、`auto`、正整数、`(N)`、`(START :span SPAN)`、`(:span SPAN)` 或 `(START END)` | `auto` | 所有非 `text` 节点 | 否 | 几何 |

把项放在一列或多列上。

**语义。** 数字是显式或隐式 grid 上从 1 起算的轨道线。`(:span N)` 从自动放置位置跨 N 条轨道，`(START END)` 是显式范围且末端大于起点，`auto` 把放置交给算法。

#### Style: :grid-row

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `nil`、`auto`、正整数、`(N)`、`(START :span SPAN)`、`(:span SPAN)` 或 `(START END)` | `auto` | 所有非 `text` 节点 | 否 | 几何 |

把项放在一行或多行上。

**语义。** 语法与规则同 `:grid-column`，作用在块轴。

#### Style: :grid-column-span

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 正整数 | — | 所有非 `text` 节点 | 否 | 几何 |

让项跨 N 列。

**语义。** 该简写展开成 `:grid-column (:span N)`。

#### Style: :grid-row-span

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 正整数 | — | 所有非 `text` 节点 | 否 | 几何 |

让项跨 N 行。

**语义。** 该简写展开成 `:grid-row (:span N)`。

#### Style: :justify-items

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `stretch`、`start`、`end` 或 `center` | `stretch` | `grid` | 否 | 几何 |

在行内轴上让 grid 项在其列区域内对齐。

**语义。** 它是没有设置 `:justify-self` 的项的默认值。

#### Style: :justify-self

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `auto`、`stretch`、`start`、`end` 或 `center` | `auto` | 所有非 `text` 节点 | 否 | 几何 |

为单个 grid 项覆盖 `:justify-items`。

**语义。** `auto` 跟随容器的 `:justify-items`；其他值只作用于该项。
## 定位与图层

<!-- index: 绝对定位; z-index; anchor; 浮层 -->

盒子默认在常规流中，除非 `:position` 把它移出。绝对定位的盒子由 `:left` 与 `:top` 相对定位宿主——最近的非行内祖先，`:layer root` 时是根——放置，`:z-index` 决定重叠绘制顺序。`:anchor` 与 `:placement` 让绝对盒相对一个唯一目标定位，而不是相对宿主原点。「[定位、图层与浮层](positioning-layers-and-overlays.md)」一章给出完整模型。

#### Style: :position

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `static`、`relative` 或 `absolute` | `static` | 所有非 `text` 节点 | 否 | 几何 |

设置节点参与父级布局的方式。

**语义。** `static` 是常规流。`relative` 保留节点的流内位置，只通过 `:z-index` 影响绘制顺序；`:left` 与 `:top` 偏移不会移动它。`absolute` 把盒子移出常规流，使它成为定位宿主的浮层。

#### Style: :left

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 有符号行内轴长度 | `(px 0)` | 所有非 `text` 节点 | 否 | 几何 |

设置绝对定位盒相对其定位宿主的水平偏移。

**语义。** 偏移从宿主的内容原点量起；无 anchor 的根层盒子从根的边框盒原点量起。百分比用宿主的 padding 盒宽度；无 anchor 的根层盒子用根的边框盒宽度。非绝对定位的盒子不受该属性影响。

#### Style: :top

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 有符号块轴长度 | `(lh 0)` | 所有非 `text` 节点 | 否 | 几何 |

设置绝对定位盒相对其定位宿主的垂直偏移。

**语义。** 偏移从宿主的内容原点量起；无 anchor 的根层盒子从根的边框盒原点量起。百分比用宿主的边框盒高度。非绝对定位的盒子不受该属性影响。

#### Style: :z-index

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| 整数 | `0` | 所有非 `text` 节点 | 否 | 绘制 |

决定重叠盒子的绘制顺序。

**语义。** 盒子按 `:z-index` 升序绘制。带正值的相对定位流内子节点会画在值更小的绝对兄弟之上，同时保留自己的流内位置，因此能透出它们的背景。

#### Style: :layer

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `local` 或 `root` | `local` | 所有非 `text` 节点 | 否 | 几何 |

选择绝对定位盒画在宿主的图层里还是根的顶层。

**语义。** `local` 把浮层画在定位宿主内部。`root` 把它画在根的顶层，同时保留逻辑父子关系，选择器与继承不变。无 anchor 时，根层盒子的偏移与百分比从根边框盒量起，所以 `:width (% 100)` 和 `:height (% 100)` 覆盖整页。

#### Style: :anchor

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `nil`、符号或字符串 | `nil` | 所有非 `text` 节点 | 否 | 几何 |

让绝对盒跟随 `:id` 与值匹配的节点。

**语义。** 值在盒子的根树里按 `:id` 指名一个节点。浮层用 `:placement` 相对该目标的盒子放置；目标缺失、被隐藏或位于浮层自身内部时，盒子不绘制、没有位置、也不能聚焦。下拉菜单和 tooltip 用它贴住触发它的控件。

#### Style: :placement

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `bottom-start`、`bottom-end`、`top-start` 或 `top-end` | `bottom-start` | 所有非 `text` 节点 | 否 | 几何 |

选择浮层贴住 anchor 目标的哪个角。

**语义。** 名字先纵后横。首选的纵向一侧会顶出宿主时，如果另一侧放得下就翻转到另一侧，结果始终留在宿主内。

## 文本排列与 wrap-mode

<!-- index: 文字对齐; 换行模式 -->

`:text-align` 摆放 box 段落中的各行，`:wrap-mode` 选择这些行怎样断。[文本](text.md)定义换行模式与断行规则。两者都继承。

#### Style: :text-align

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `left`、`center`、`right`；`end` 等同 `right`，其他值等同 `left` | `left` | 仅 `box` | 是 | 几何 |

对齐 box 文字段落中的各行。

**语义。** `center` 居中，`right` 与 `end` 右对齐；其他值左对齐。该值可继承，容器因此把对齐方式传给后代的 box，但只有 `box` 接受这条声明。

#### Style: :wrap-mode

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `word`、`char`、`kp` 或 `none` | `word` | 所有非 `text` 节点 | 是 | 几何 |

选择文字宽于可用空间时怎样断行。

**语义。** `word` 在词之间断，`char` 在字符之间断，`kp` 走 Knuth-Plass 段落断行器，`none` 关闭软换行但保留显式换行。该值可继承。

## 溢出与滚动

<!-- index: 溢出; 滚动锚点 -->

`:overflow` 决定内容大于盒子时发生什么、哪些盒子提供滚动视口；`:scroll-anchor` 决定滚动的盒子是否跟随内容末端。[滚动](scrolling.md)一章定义滚动接口。

#### Style: :overflow

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `visible`、`hidden`、`scroll` 或 `auto` | `scroll` | 所有非 `text` 节点 | 否 | 绘制 + 几何 |

控制内容大于盒子时的裁剪与垂直滚动。

**语义。** `visible` 不裁剪，盒子按内容增高。`hidden` 在整显示单位处水平与垂直裁剪。`scroll`（初值）与 `auto` 显示滚动视口，滚动命令读取并改变它的偏移，并把内容裁剪到盒内。

#### Style: :scroll-anchor

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `start` 或 `end` | `start` | 所有非 `text` 节点 | 否 | 几何 |

把滚动的盒子钉在内容的开头或末尾。

**语义。** 取 `end` 时，钉在最后一行的盒子会随内容增长持续跟随该行，这是聊天与日志的常见行为。`start` 把视图留在顶部。

## 结构属性

<!-- index: outer; 行内盒; 块盒 -->

剩下的属性改变盒子参与容器流的方式，而不是它的外观。

#### Style: :outer

| 值 | 初值 | 适用 | 继承 | 影响 |
| --- | --- | --- | --- | --- |
| `inline` 或 `block` | `block` | 所有非 `text` 节点 | 否 | 结构 + 几何 |

选择盒子参与行内排版还是作为块。

**语义。** `:outer inline` 的盒子在所有子节点都是行内或绝对定位时参与行内排版，因此能和邻项并排。初值 `block`，或存在块级子节点时，盒子在堆叠流中独占自己的行。
