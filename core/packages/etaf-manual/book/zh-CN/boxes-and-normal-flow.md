# 盒与常规流

`box` 是通用布局容器：它堆叠块子节点，并把行内内容排成段落。本章讲常规流——box 如何区分块与行内、三种宽度约束 stretch、shrink、exact 如何驱动子节点、最小/最大尺寸与 `box-sizing` 如何与这些约束互动、边框怎样变成行里的字符，以及 `row` 与 `column` 容器如何沿单轴摆放子节点。[Hosts](hosts.md)定义有哪些盒子种类，[样式属性参考](style-properties.md)定义本章点名的属性；[渲染模型](rendering-model.md)定义本章几何所用的行与像素坐标。

## 块、行内与匿名段落

<!-- index: 常规流; 行内; 块; 匿名段落; outer -->

节点在满足以下条件时参与行内格式化：它是文本节点，或是 `:outer` 为 `inline` 且子节点全部是行内或绝对定位的 `box`。其余都是块。`:outer` 说的就是这个区分，并且可以观察到：行内盒子与邻居共享同一段，而块盒子占据容器内容宽的一整行，把后面的内容往下推。

`box` 按文档顺序安排 in-flow 子节点并分组。连续的行内子节点构成一段，这段在 box 的内容宽上作为*匿名段落*参与布局：行内片段共享段落的行、一起换行、作为一组行定位。每个块子节点自成一组。然后把各组按行堆叠：每个块子节点以内容宽 stretch 布局，每个段落的高度按行计入。子节点只有一段行内内容的 box 直接把这段作为段落布局；只放文本的 box 就是这种常见情形。

绝对定位子节点不参与：它出流，改由包含宿主定位，[定位、图层与浮层](positioning-layers-and-overlays.md)一章讲这件事。段落是布局构造而非公共节点——它在 box 布局期间存在，持有其行内片段换行后的行——所以公共的观察方式是 box 的几何与渲染出的行。

## 三种宽度约束

<!-- index: 宽度约束; stretch; shrink; exact; 固有宽度 -->

盒子解出宽度之前，会拿到一个可用像素宽和三种约束之一。*stretch* 意味着盒子可以填满可用宽。*shrink* 意味着盒子应跟随内容，并以可用宽为界：它的固有最小宽（不破坏必须保持完整的单位所能有的最窄宽度）与固有最大宽（内容排成一行时的宽度），再夹到可用宽。*exact* 意味着盒子取另一个算法已经为它决定好的宽度，忽略它自己的声明。

约束由父节点选择。`box` 的块子节点被 stretch 到内容宽，`column` 子节点在交叉轴对齐为 `stretch` 时也是；非文本树的根被 stretch 到视口宽。`row` 子节点与交叉轴不 stretch 的 `column` 子节点 shrink 到自己的内容。exact 是 flex 与 grid 算法把目标宽交给一个项的方式，因此只出现在这两种容器内部，[Flex 布局](flex-layout.md)与 [Grid 布局](grid-layout.md)两章讲它们。

宽度声明优先于模式：固定的 `:width` 在 stretch 与 shrink 下都解析为该值；`min-content`、`max-content` 与 `fit-content` 显式选择固有宽度，其中 `fit-content` 是固有最小与最大宽夹到可用宽。初值 `auto` 表现得与该模式一致——stretch 下填满、shrink 下等价 fit-content——而 `stretch` 关键字在有包含块可填时显式填满。高度同理、按行计：固定的 `:height` 优先，`stretch` 高度在已知包含高时填满它，否则高度取内容高。`overflow` 为 `visible` 的盒子在内容所需行数超过自身高度时改取内容高而不是裁剪，于是一行行长大的文本会把容器顶高。

## 最小、最大与盒尺寸

<!-- index: box-sizing; 最小尺寸; 最大尺寸 -->

`:box-sizing` 决定声明的尺寸量的是什么。初值 `border-box` 下，`:width` 与 `:height` 描述边框盒，因此 padding 与边框会缩小内容区；`content-box` 下它们描述内容盒，padding 加边框另加在外，于是 20 像素宽加 2 像素 padding 与 1 像素边框占 25 像素。解出的尺寸随后被 `:min-width`、`:max-width`、`:min-height`、`:max-height` 夹紧：最小值大于声明尺寸时最小值胜，最大值更小时盒子收紧，而更小的内容宽放不下一行文本时文本换行。最小与最大尺寸跟随与声明尺寸相同的 `box-sizing`。

互相冲突的尺寸的恢复规则是：夹紧最后施加，而且不声张——几何从不拒绝声明尺寸与最小/最大尺寸的组合，只解为夹紧后的值。`:overflow visible` 是内容可以盖过声明高度的唯一情形，如上一节所述；`hidden` 与 `scroll` 保留声明高度，把多出的部分交给溢出接口处理。

## 边框作为字符

<!-- index: 边框绘制; 像素空格边框; overline; underline -->

边框用文本缓冲区有的工具绘制。左边框与右边框是以边框色为背景的像素空格：3 像素宽的左边框就是一个宽 3 像素的 display space，其 face 带该背景。它们的宽度就是几何——在 `border-box` 里缩小内容区，在 `content-box` 里加到外尺寸上——而且因为是 display space，它们在任意像素宽度上都保持精确。

上边框与下边框不是字符。它们用边框色给边框盒第一行或最后一行的每个字符加上 overline 或 underline 装饰，于是上边框在字符上方画线、下边框在字符下方画线，宽度正好等于盒子的像素宽。一个 face 只有一条这样的线，所以宽于一个像素的上/下边框没有诚实的画法；Ebox 报 `ebox-error`，而不是画近似。边框只在其样式为 `solid` 且宽度大于零时存在：初值样式 `none` 把边框解为零宽，因此既不占几何也不绘制。

```elisp :run
(etaf-define-component demo-box-lab ()
  :bindings ((pad (etaf-ref 2))
             (edge (etaf-ref 1))
             (gap (etaf-ref 1)))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (row :item-gap '(ch 2)
               (etaf-number-input :label "内边距" :value 2 :min 0 :max 6
                                  :on-change (lambda (v) (etaf-set-value pad v)))
               (etaf-number-input :label "边框" :value 1 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value edge v)))
               (etaf-number-input :label "外边距" :value 1 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value gap v))))
          (box :width '(ch 44)
               :padding (list (list 'lh (etaf-value gap)) (list 'ch (etaf-value gap)))
               :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
            (box :padding (list (list 'lh (etaf-value pad)) (list 'ch (etaf-value pad)))
                 :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                 :border-width (list 'px (etaf-value edge))
                 :border-style 'solid
                 :border-color (etaf-theme-token :ui-accent "#0969da")
              (text "内容")))))
(etaf-view (demo-box-lab))
```

```elisp :figure 一个盒子的内容、内边距、边框与外边距
(etaf-view
 (box :width '(ch 40) :padding '((lh 1) (ch 2))
      :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
   (box :padding '((lh 1) (ch 2))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
        :border-width '(px 1)
        :border-style 'solid
        :border-color (etaf-theme-token :ui-panel-border "#687386")
     (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "内容")
     (text :color (etaf-theme-token :ui-muted-fg "#526174")
           " 两边是内边距，细线是边框，灰底是外边距"))))
```

## row 与 column

<!-- index: row; column; item-gap; 交叉轴对齐; 单轴 -->

`row` 沿水平轴摆放直接子节点，`column` 沿垂直轴，两者都把子节点放在容器内容盒内的像素或行位置上。`:item-gap` 在那条主轴上分隔相邻子节点——row 用行内单位，column 用块单位——而且只插在子节点之间，绝不在第一个之前或最后一个之后。`:cross-align` 在交叉轴上摆放每个子节点：`start`、`center`、`end` 定位子节点，初值 `stretch` 让子节点填满容器的交叉尺寸。

两种容器的差别在于子节点如何取得主轴尺寸，以及子节点放不下时发生什么。`column` 不给交叉对齐设限时让子节点占满内容宽；`row` 让子节点 shrink 到自己的内容，图标加标签这类组合因此自然取到自己的大小。`row` 从不换行：放不下的子节点溢出容器，由 `:overflow` 决定这份多出的内容是裁剪还是可滚动，[滚动](scrolling.md)一章定义它。需要换行或分配多余空间的容器是 `flex` 容器，[Flex 布局](flex-layout.md)定义它。

## 错误与恢复

<!-- index: 边框宽度错误; 尺寸拒绝; 夹紧 -->

宽于一个像素的上边框或下边框报 `ebox-error`，数据里带边与违规宽度；这项检查在布局过程中构造节点计算样式时运行，因此在更新运行时报出——单独设置该属性本身不报。单位不适合轴的长度，比如块轴上的像素 padding，会更早在编译声明时以 `ebox-size-error` 拒绝，并报出允许的单位；[样式属性参考](style-properties.md)描述单位域。

互相对立的尺寸不是错误：声明尺寸、最小值与最大值解为夹紧后的一个值，`visible` 溢出的盒子长到内容高，而不是报告内容放不下。其余的恢复路径——滚动被裁剪的盒子、尺寸变化后只重写损坏的行——属于[滚动](scrolling.md)与[增量更新与发布](incremental-updates-and-publication.md)两章。
