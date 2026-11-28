# Flex 布局

`flex` 容器沿一条轴分配子节点，让它们从基础尺寸出发伸缩。它是工具栏、按钮行、页头和任何需要共享可用空间而不是各占一行的组合所用的容器。本章讲[样式属性参考](style-properties.md)中 flex 属性背后的模型：主轴与交叉轴、基础尺寸如何解出并带 min/max 冻结地伸缩、换行如何形成行、对齐与间隙如何摆放项，以及算法如何推进。属性本身的语法与初值在[样式属性参考](style-properties.md)定义；[盒与常规流](boxes-and-normal-flow.md)定义这个容器取代的流。

## 主轴与交叉轴

<!-- index: 主轴; 交叉轴; flex 方向; order -->

`:flex-direction` 选择主轴。初值 `row` 与 `row-reverse` 横向摆放子节点，于是主尺寸是像素宽；`column` 与 `column-reverse` 纵向堆叠，于是主尺寸是行数。另一条轴是交叉轴，flex 容器里的每个摆放都相对这两条轴描述。

子节点按 `:order` 升序摆放，值相同时保持文档顺序；绝对定位的子节点出流，不占项的位置。反向方向在行解析完成后反射摆放，因此它改变的是项从哪一端开始，而不只是视觉顺序，`:justify-content` 也跟随反向后的主轴起点。两条轴还解释了为什么描述它们的属性接受所有单位的长度：`:flex-basis` 相对容器实际使用的轴解析，所以 row 解析像素、column 解析行。

## 基础尺寸、伸缩与冻结

<!-- index: flex 基础尺寸; flex 增长; flex 收缩; 假设尺寸; 冻结 -->

每一项都从一个*基础尺寸*出发。`:flex-basis` 直接给出它；初值 `auto` 使用项在主轴上的尺寸属性——row 用 `:width`，column 用 `:height`——而 `content` 用项的固有内容尺寸。文本项取自己的内容尺寸且从不伸缩，这正是标签在周围项分配空间时不被挤压的原因。基础尺寸被项的最小、最大主尺寸夹紧，形成它的*假设尺寸*，即不分配任何空间时它会取的尺寸。

随后容器把各项假设尺寸与间隙之和同可用主轴空间比较。有多余空间时，按 `:flex-grow` 比例分配增长；项溢出时，按 `:flex-shrink` 乘以基础尺寸加权分配收缩，所以在相同因子下宽项比窄项让出更多空间。因子为零、或基础尺寸已落在分配方向反面的项，冻结在假设尺寸上。

伸缩可能把项推过它自己的最小值或最大值。这时项被夹到边界并冻结在那里，自由空间在仍未冻结的项之间重新分配；循环重复到所有项都冻结，因此最小值或最大值总是胜过分配，差额由其余项吸收。仍在参与的因子之和小于 1 时，只分配自由空间的这个比例，所以单独一个 `:flex-grow 0.5` 的项取走一半自由空间、把其余留下。最终尺寸在累计边界上量化到整像素或整行，因此相邻项之间不会留下半个像素的缝，溢出的行从一开始就少占，而不是在中间开一个口。

**示例。** 基础尺寸 4 像素的两项，第一个增长因子 1、第二个 3，在 20 像素的行里填成 7 与 13 像素。同样两项基础尺寸 10、收缩因子 1，在 12 像素的行里解成 6 与 6；基础尺寸 8、收缩因子 3 与 1 时解成 5 与 7；而一对增长的项中若第一项有 `:min-width (px 15)`，它冻结在 15，另一项取走剩下的 9。

```elisp :run
(etaf-define-component demo-flex-lab ()
  :bindings ((a (etaf-ref 1))
             (b (etaf-ref 2))
             (c (etaf-ref 1)))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (row :item-gap '(ch 2)
               (etaf-number-input :label "A" :value 1 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value a v)))
               (etaf-number-input :label "B" :value 2 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value b v)))
               (etaf-number-input :label "C" :value 1 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value c v))))
          (flex :flex-direction 'row :width '(ch 44) :column-gap '(ch 1)
                (box :flex-grow (etaf-value a) :padding '((lh 1) (ch 1))
                     :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
                     (text :color (etaf-theme-token :ui-accent "#0969da") "A"))
                (box :flex-grow (etaf-value b) :padding '((lh 1) (ch 1))
                     :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                     (text "B"))
                (box :flex-grow (etaf-value c) :padding '((lh 1) (ch 1))
                     :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
                     (text :color (etaf-theme-token :ui-accent "#0969da") "C")))))
(etaf-view (demo-flex-lab))
```

```elisp :figure 一行 flex 里长 1 : 2 : 3 的三个盒子
(etaf-view
 (flex :flex-direction 'row :width '(ch 40) :column-gap '(ch 1)
   (box :flex-grow 1
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
        :padding '((lh 1) (ch 1))
     (text "grow 1"))
   (box :flex-grow 2
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
        :padding '((lh 1) (ch 1))
     (text "grow 2"))
   (box :flex-grow 3
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
        :padding '((lh 1) (ch 1))
     (text "grow 3"))))
```

## 换行

<!-- index: flex 换行; flex 行; wrap-reverse -->

初值 `:flex-wrap nowrap` 把所有项保持在一条线上，放不下的项溢出容器。`wrap` 把项分成*flex 行*：当加入一项会使假设尺寸与间隙之和超过可用主轴空间时，该项另起一行。换行依据假设尺寸、在伸缩之前决定，所以一条将要在伸缩中填满空间的行仍按同样的位置断开。`wrap-reverse` 形成同样的行，但沿交叉轴反射，于是第一行落在远端。

横向换行的 row 容器的高度是各行交叉尺寸之和加上行间间隙；column 容器沿另一条轴同样测量。行内各项相对该行分到的那份主轴空间伸缩，而不是相对整个容器。行本身的对齐是 `:align-content`，见下节。

**示例。** 基础尺寸 4 的三项放在 10 像素宽、`:flex-wrap wrap` 的 row 里，形成第一行两项、第二行一项；容器高两行，第三项在第二行的 x 0。

## 对齐与间隙

<!-- index: justify-content; align-items; align-self; align-content; flex 间隙 -->

`:justify-content` 在自由空间分配之后沿主轴摆放各项：初值 `start` 靠主轴起点，`end` 靠主轴终点，`center` 居中整组，`space-between`、`space-around` 与 `space-evenly` 分别把自由空间分在项之间、项两侧、以及包含两端在内均匀分配。换行容器里，该关键字按行施加。

`:align-items` 在交叉轴上摆放每一项，`:align-self` 为单项覆盖它，`auto` 跟随容器。`start`、`center`、`end` 按项的天然交叉尺寸摆放，初值 `stretch` 让交叉尺寸为 auto 的项填满该行的交叉尺寸；声明了交叉尺寸的项保持自己的尺寸。换行的容器中，各行合计未填满容器交叉尺寸时，`:align-content` 分配这些行：初值 `stretch` 展开行以吃掉剩余，其余关键字像 `:justify-content` 对待项那样摆放或分配行。容器有确定交叉尺寸而只有一行时，那一行被拉到该尺寸。

间隙是主轴与交叉轴布局的一部分：在 row 里，`:column-gap` 沿主轴分隔各项，`:row-gap` 分隔换行的行；column 容器两轴互换。`:gap` 一条声明设置两者。间隙只插在项与行之间，绝不加在外面，因此可用于对齐的自由空间是在扣除间隙之后算出的。

**示例。** 20 像素行里两个 4 像素项，`:justify-content center` 时位于 x 6 与 10，`space-between` 时位于 0 与 16，`space-around` 时位于 3 与 13，`space-evenly` 时位于 4 与 12。高 3 行的 row 里用 `:align-items center`，高 1 行的项坐在中间一行；用 `:align-self end` 则坐在最后一行。

## Flex 如何布局

<!-- index: flex 算法; 重排; 项缓存 -->

这套布局是一个解算循环，不是一个公式。容器先算出每一项的假设尺寸，再把项分成行，然后逐行分配自由空间并冻结违反最小或最大值的项，重复到分配稳定为止。主任尺寸最终确定后，才测量每项的交叉尺寸——row 在每项的最终宽度上测天然高度，column 在最终高度上测宽度——之后才按 `:align-content` 摆放各行、按 `:align-items` 摆放各项。

由于 flex 容器的项摆放依赖每一项的最终尺寸，任一子节点变化都会重排该容器的子节点；子节点各自的布局缓存让未变的项立即返回，所以代价与真正变化的内容成比例。分配刻意取整：row 取整像素，column 取整行，不均匀划分的余数由靠前的项承担。因此 row 在两项之间不会出现半像素的缝，它的右边缘落在像素边界上。

## 错误与恢复

<!-- index: flex 错误; 溢出 -->

flex 布局本身没有运行时错误：畸形值、单位不适合轴、容器不接受的属性都在编译声明时、任何布局运行之前被拒绝，条件见[样式属性参考](style-properties.md)。互相冲突的要求由算法化解而不是报告：增长会超过最大值的项冻结在最大值，剩余空间归别的项；收缩不够的项则溢出。

克制容器不修正溢出。`nowrap` 的 row 放不下各项时就溢出，盒子的 `:overflow` 决定多出的部分是裁剪还是可滚动，[滚动](scrolling.md)一章定义它；换行的 row 则通过另起一行避开这种局面。无法缩到自己内容以下的项——文本项，以及溢出可见且尺寸固定的盒子——保持自己的尺寸，同样可以把行顶出容器。
