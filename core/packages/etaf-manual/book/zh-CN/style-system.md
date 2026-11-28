# 样式系统总论

每个 Host 的外观与占位都由同一套样式模型决定。*声明*给一个样式属性一个值，*规则*给声明配一个选择器，层叠为每个属性选出一个赢家。这套模型只有一套语义、三种写法——直接写在 Host 上的属性、Component 的 `:styles` 里的静态规则、以及规则文件——由三层分工：ECSS 计算赢家和最终值，Ebox 拥有属性词表并把计算值投影成绘制与几何，ETAF 提供书写界面和 Theme。本章说明这个分工、五种层叠来源、层叠层，以及完整的比较顺序。[选择器](selectors.md)详述规则选择器；[值](values.md)详述值的语义、继承、自定义属性和来源追溯；[样式属性参考](style-properties.md)是每个属性的参考；[组件样式与主题](component-styles-and-themes.md)讲组件规则与 Theme；[样式的实现](style-implementation.md)讲 schema 与样式 pass。

## 一套语义，三种写法

<!-- index: 声明; 规则; 内联属性; 规则文件 -->

*声明*给一个样式属性一个值，例如 `:color "#B45309"`。*规则*给一条或几条声明配一个选择器。无论用哪种写法，声明都进入同一套属性词表和同一套值语法，选择器与层叠的语义也一样决定哪条声明获胜。

*内联属性*是最短的写法：把样式关键字和 Host 的其他属性一起写在 View 里。

```elisp
(text :color "#B45309" "Draft")
```

ETAF 先问 Ebox 的 schema，一个关键字是不是样式属性，从而把样式键与语义属性、事件属性区分开；所选的 Host 不接受的样式属性会在 View 发布时被拒绝。[Host](hosts.md)一章定义属性的域，以及多个来源的属性如何合并。

*组件样式*是 Component 定义里 `:styles` 子句的静态规则：

```elisp
(etaf-define-component demo-badge ()
  :view (text "Draft")
  :styles (("&" :color "#B45309")))
```

规则列表在定义 Component 时就校验，选择器相对 Component 自己的根书写。[组件样式与主题](component-styles-and-themes.md)定义规则格式、`&` 选择器和样式替换接口。

*规则文件*用惰性数据保存一整份有序规则列表，不加 quote 或包装：

```
((".badge" :color "#B45309")
 (".badge.active" :color "#334155"))
```

读规则文件从不求值里面的值。`ecss-file-read` 读文件，`ecss-read-rules` 和 `ecss-validate-rules` 接受内存里的同一份列表。`.ebox` 文件可以加载同名的 `.ecss` 同伴，或在表达式里指定一个；工具也可以用 `etaf-component-set-styles` 把文件里的规则装成某个 Component 的样式。[规则文件](ecss-rule-files.md)一章定义文件契约，[组件样式与主题](component-styles-and-themes.md)定义替换接口。

```elisp :figure 同一条声明，写成组件样式规则或行内属性
(etaf-define-component demo-badge ()
  :view (box (text "Draft"))
  :styles (("&" :color "#B45309"
            :background-color "#fef3c7"
            :padding ((lh 0) (ch 1)))))

(etaf-view
 (row :item-gap '(ch 1) :cross-align 'center
   (demo-badge)
   (box :color "#334155" (text "Plain text"))))
```

## 所有权

<!-- index: 样式所有权; 属性 schema -->

样式事实归谁，跟随[生态与分层](ecosystem-and-layers.md)的分层。

| 层 | 在样式模型里拥有 |
| --- | --- |
| `ecss` | 选择器匹配、层叠、归一化、计算值及其来源追溯 |
| `ebox` | 属性词表、保留的计算样式、样式 pass，以及把值投影成绘制与几何 |
| `etaf` | 三种书写写法、Theme，以及把书写的数据降级成 Ebox 输入 |

ECSS 是纯计算。给定 schema 集合、subject、声明与规则，它匹配选择器、给候选排序、选出赢家、归一化并校验值，返回计算样式；需要时保留每个赢家的来源追溯。它不知道值在屏幕上的样子。

Ebox 拥有作者书写的词表：属性的规范名与别名、每个属性的初值、是否继承、值的语法、哪些 Host 种类接受它，以及改动它影响绘制还是几何。Ebox 也拥有每个节点保留的计算样式，并决定何时必须重算，所以没有变化的样式不会重算，相同输入共享同一个样式对象。

ETAF 拥有书写界面。Host 属性与 Component 的 `:styles` 规则被降级成 Ebox 输入，Theme 默认值被降级成 UA 来源的声明，同一份规则列表数据被 `:styles`、`etaf-component-set-styles` 和文件读取函数共同接受。ETAF 不维护第二份属性词表：名字、默认值和校验器都来自 Ebox。

## 来源

<!-- index: 层叠来源; important; ua; user; author; animation; transition -->

ECSS 有五种来源：`ua`、`user`、`author`、`animation` 和 `transition`。它们与 important 一起组成八个档位，按下列顺序比较：

| 档位 | |
| --- | --- |
| 1（最高） | transition |
| 2 | UA important |
| 3 | user important |
| 4 | author important |
| 5 | animation |
| 6 | author normal |
| 7 | user normal |
| 8（最低） | UA normal |

档位更高的无论选择器、层叠层还是顺序如何都获胜。important 不改变值的语法，只把声明抬到它所属来源的 important 档。animation 声明压过所有普通声明，但输给 important 声明；transition 声明压过一切。

ETAF 与 Ebox 的书写界面产生其中两种来源。Theme 被降级为 *UA* 声明：`etaf-theme-provide` 向一个 Component 子树提供属性 plist，ETAF 解析出该 Host 接受的条目，Ebox 把它们作为该 Host 的默认值放进 UA 来源。因此 Component 自己的规则或内联属性会压过 Theme 默认值，而 important 的 Theme 默认值仍能压过 important 的 author 声明。内联 Host 属性、Component 的 `:styles` 规则和 `.ebox` 文件的本地规则都是 *author* 声明。*user* 来源留给直接构建 ECSS stylesheet 的宿主，Ebox 的共享 scope 也可以通过 `ebox-style-scope-create` 带显式来源创建，但 ETAF 自己的书写界面不产生 user 声明。*animation* 与 *transition* 是 ECSS 层叠的一部分；Ebox 与 ETAF 今天都不产生它们，因为 ETAF 的动画是响应式值更新，不是层叠声明；[动画](animation.md)一章讲那些。

## 层叠层

<!-- index: 层叠层; 声明层叠层 -->

层叠层在一个来源内部给规则排序。ECSS 用 `ecss-stylesheet-declare-layers` 声明顺序，规则通过 `ecss-stylesheet-add-rule` 的 `:layer` 参数带上自己的层。规则先用了一个尚未声明的层时，这个层在首次使用处加入该来源的顺序；之后用 `ecss-stylesheet-layers` 查询到的就是生效顺序。每个来源各有一份自己的顺序：为 author 来源声明的层不影响 user 或 UA 规则。

在同一个来源、同一个 important 档内，层叠层这一步这样排序候选。普通声明里，未分层的规则压过所有分层的普通声明；分层的普通声明之间，声明得更晚的层获胜。important 声明把两条规则都反过来：分层的 important 声明压过未分层的 important 声明；分层的 important 声明之间，声明得更早的层获胜。

支撑内联声明、组件样式和 `.ebox` 本地规则的 Ebox scope 都把规则按未分层加入，ETAF 也不暴露自己的层叠层声明。因此层叠层主要是给直接构建 ECSS stylesheet 的宿主用的——比如把多份样式表混合起来的应用，或内嵌 Ebox 的库；[stylesheet、scope 与作者所有权](ecss-stylesheets-and-scopes.md)描述那个接口。Ebox 另外有一个名叫 `:layer` 的样式属性，它决定元素在绘制顺序中的位置，与层叠层是两回事，属于[定位、图层与浮层](positioning-layers-and-overlays.md)一章。

## 层叠顺序

<!-- index: 层叠顺序; 优先级; 作用域邻近度; 源顺序 -->

多条声明提供同一个属性时，ECSS 按一个固定顺序比较它们，第一处差异就决定结果：

1. 匹配与相关性：规则的选择器必须匹配 subject，规则的 scope 必须允许它；每条匹配的规则记录自己的 scope 邻近度。
2. 来源与 important：按上面的八个档位。
3. 层叠层：按上一节。
4. 优先级（specificity）：选择器的 ID、类、类型计数，按这个次序比较。
5. 作用域邻近度：scope 离 subject 更近的候选获胜。
6. 源顺序：加入得更晚的规则获胜。
7. 声明顺序：同一条规则内，后写的声明获胜。

内联属性是 author 声明，在层叠层这一步位于所有 author 规则之上，因此无论普通 author 规则的优先级多高都压不过它。important 的 author 规则仍压过普通内联属性，important 的内联属性压过 important 的 author 规则。

没有任何声明提供的属性，如果 schema 标记为可继承且父级有值，就用继承值，否则用初值。赢了但计算出非法值的声明，不会把属性让给更低的候选：改用 schema 的继承值或初值兜底，并把无效赢家保留在来源追溯里，因此重跑层叠永远不会改变哪个声明获胜。继承、全局关键字、自定义属性、`revert` 和来源追溯查询由[值](values.md)详述。

**示例。**下面两条规则选择器与优先级都相同，只有源顺序决定结果：徽标用第二条规则的颜色渲染。

```elisp :run
(etaf-define-component demo-cascade-badge ()
  :view (text "Draft")
  :styles (("&" :color "#334155")
           ("&" :color "#B45309")))
(etaf-view (demo-cascade-badge))
```
