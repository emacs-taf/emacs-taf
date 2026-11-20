# Grid 布局

`grid` 容器把子节点放在二维的轨道网格上。它是表单、仪表盘、类表布局以及任何需要列行对齐而非单轴排布的场景所用的容器。本章讲[样式属性参考](style-properties.md)中 grid 属性背后的模型：轨道如何定义与定尺、隐式轨道如何出现、自动放置与显式放置如何工作、项如何在各自的区域内对齐，以及布局如何推进。[Flex 布局](flex-layout.md)讲这个容器的一维姊妹。

## 轨道

<!-- index: grid 轨道; 固定轨道; 内容轨道; fr; minmax; repeat; 轨道间隙 -->

`:grid-template-columns` 与 `:grid-template-rows` 以有序列表定义显式轨道。一个轨道可以是像素或行长度、内容关键字 `min-content` 与 `max-content`、自动尺寸 `auto`、正数 N 的分数轨道 `(fr N)`、最小值不能为分数的 `(minmax MIN MAX)`，或 `(repeat N TRACK)`（TRACK 是单个轨道或轨道列表）。分数轨道按因子比例瓜分固定轨道与内容轨道定尺之后剩下的空间，`minmax` 把轨道抬到至少最小值、封顶于最大值；区间的两端本身也可以是内容关键字或分数。

内容轨道从它的项取得尺寸。`min-content` 是它最宽不可断开的单位——项最窄的诚实宽度——`max-content` 是项排成一行时的宽度。自动尺寸 `auto` 的工作方式不同：项只有在能表达尺寸时才向 `auto` 轨道贡献尺寸。文本项贡献它的 min-content 宽，带 `:min-width` 的项贡献该宽度，`:overflow` 为 `visible` 的项贡献它的 min-content 宽；其它盒子只贡献自己的 margin 与 padding。因此被裁剪或可滚动的盒子不会撑宽它所在的轨道，`auto` 轨道可能解出零像素，内容溢出到下一轨道，除非有别的什么给该轨道尺寸。`:justify-content stretch` 是最常用的办法，因为 stretch 把剩余空间摊进每个轨道。

轨道之间用 `:column-gap` 分隔列、`:row-gap` 分隔行，只插在轨道之间。间隙从可用于轨道定尺的空间里扣除，所以 `fr` 轨道瓜分的是扣掉间隙之后剩下的部分。

## 隐式轨道与自动放置

<!-- index: 隐式轨道; 自动放置; 自动流; 占用格 -->

落在显式轨道之外的项会产生隐式轨道，尺寸来自 `:grid-auto-columns` 或 `:grid-auto-rows`，两者的初值都是 `auto`。隐式轨道遵循与显式轨道相同的定尺规则——包括上面的 `auto` 贡献规则——网格扩展以容纳它们，所以往三列网格里放第四个项会得到第四列，而不是丢弃或换行。

自动放置按 `:grid-auto-flow` 的顺序填充网格。初值 `row` 下，容器逐行扫描足够放下该项的空区域；`column` 下逐列扫描。跨多个格子的项需要同样大小的空区域，因此扫描会跳过被占的格和放不下它的空洞，而一个跨格项可以把后面的项推到新的隐式轨道。

## 显式放置与跨格

<!-- index: grid 放置; grid 跨格; grid 区域 -->

`:grid-row` 与 `:grid-column` 把项放到从 1 开始编号的线或区域上。整数把项放在该线上、跨一格；`(:span N)` 让它在自动放置决定的位置上跨 N 格；`(START :span N)` 固定起始线并给出跨格数；`(START END)` 从起始线跨到结束线。`:grid-row-span` 与 `:grid-column-span` 单独设置跨格数，而同时带起始与跨格的值取两者中较大的那个。

显式位置在该轴上胜过自动放置。只给一条轴时，另一条轴由限制在该行或该列上的自动扫描填充，所以只写 `:grid-column 2` 的项取第二列的第一个空格。跨格项在放置时占据其区域的每个格子，它跨过的轨道吸收它的尺寸贡献：跨两列把宽度摊到那两列上，跨两行则让每一行都拿到它需要的高度。

**示例。** 列宽为 4、6、2 像素、列间隙 1 像素的网格里，`:grid-column (1 :span 2)` 的项宽 11 像素——4 加间隙加 6——下一个自动项从第三列开始，位于 x 12。

```elisp :run
(etaf-define-component demo-grid-lab ()
  :bindings ((span (etaf-ref 2)))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (etaf-segmented :value 2
                          :options '((1 . "跨 1") (2 . "跨 2") (3 . "跨 3"))
                          :on-change (lambda (key) (etaf-set-value span key)))
          (grid :width '(ch 44)
                :grid-template-columns '((fr 1) (fr 1) (fr 1))
                :gap '((lh 1) (ch 1))
                (box :padding '((lh 1) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                     (text "A"))
                (box :grid-column-span (etaf-value span) :padding '((lh 1) (ch 1))
                     :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
                     (text :color (etaf-theme-token :ui-accent "#0969da") "B"))
                (box :padding '((lh 1) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                     (text "C"))
                (box :padding '((lh 1) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                     (text "D")))))
(etaf-view (demo-grid-lab))
```

```elisp :figure 三列网格，其中一个盒子跨两列
(etaf-view
 (grid :width '(ch 40)
       :grid-template-columns '((fr 1) (fr 1) (fr 1))
       :gap '((lh 1) (ch 1))
   (box :padding '((lh 1) (ch 1))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
     (text "A"))
   (box :grid-column-span 2
        :padding '((lh 1) (ch 1))
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
     (text "B 跨两列"))
   (box :padding '((lh 1) (ch 1))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
     (text "C"))
   (box :padding '((lh 1) (ch 1))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
     (text "D"))))
```

## 对齐

<!-- index: justify-items; justify-self; align-items; justify-content; grid 对齐 -->

项在各自区域内的横向对齐是 `:justify-items`、纵向对齐是 `:align-items`，单项可用 `:justify-self`、`:align-self` 覆盖任一轴。两者的初值都是 `stretch`，因此交叉尺寸为 auto 的项填满自己的区域；声明了尺寸的项保持自己的尺寸，由对齐关键字摆放：`start`、`center`、`end` 在区域内移动它。项可以在一轴上被拉伸、在另一轴上居中。

轨道本身由 `:justify-content`（列）与 `:align-content`（行）摆放，关键字与 [Flex 布局](flex-layout.md)相同。初值 `start` 把轨道靠内容盒起点堆放；`stretch` 把剩余空间摊进每个轨道，这正是让本来零尺寸的 `auto` 轨道可用的办法；`center` 居中整组轨道；`space-between`、`space-around` 与 `space-evenly` 在轨道之间或周围分配剩余。只有轨道合计小于容器时才有剩余可分配。

**示例。** 10 像素宽的列里放 4 像素的项，`:justify-items center` 时位于 x 3，`:justify-self end` 时位于 x 6。20 像素容器里的两个 4 像素列，`:justify-content space-between` 时位于 x 0 与 x 16。

## Grid 如何布局

<!-- index: grid 算法; 列遍; 行遍; 重排 -->

Grid 布局分两遍，因为一行的高度取决于它的项在最终宽度下的高度。先按各项的宽度贡献给列轨道定尺；然后把每一项放进它的列区域布局以取得高度，宽度来自它跨过的列与横向对齐；再按这些高度给行轨道定尺；最后按各自的对齐纵向摆放每项，自动高度的项可能被拉伸到它的行区域。两遍都用可用空间解析分数轨道、冻结超出份额的轨道，并把结果量化到整像素或整行。

grid 项的区域由轨道偏移算出：跨多个轨道的项得到这些轨道尺寸之和加上它们之间的间隙。容器高度是各行轨道合计，所以放置产生的隐式行会把容器变高。任一子节点变化都会完全重排该容器的子节点，因为一个项的尺寸可能改变它所在的轨道，从而影响它之后的每一项；子节点各自的布局缓存让未变的项立即返回。

## 错误与恢复

<!-- index: grid 错误; 零尺寸轨道; 放在模板之外 -->

畸形的轨道、因子非正的分数、分数形式的最小值，或单位不对的长度，都在编译声明时、任何布局运行之前被拒绝，条件见[样式属性参考](style-properties.md)。把项放到显式轨道之外不是错误：网格扩展隐式轨道来容纳它，尺寸取自网格的自动轨道属性。

零尺寸的 `auto` 轨道是这个模型里唯一不声张的意外：项溢出自己的区域而不是把它撑开。恢复办法是给轨道或项作者本来设想的尺寸——轨道上用 `min-content` 或 `max-content`、项上用 `:min-width` 或 `:overflow visible`、一个显式长度，或用 `:justify-content stretch` 共享容器的剩余空间。此后裁剪溢出就是普通的 `:overflow` 行为，[滚动](scrolling.md)一章讲它。
