# 值

一条样式声明给属性一个值，值决定属性的行为：长度占位，颜色绘制，关键字选择模式。本章定义 Ebox 接受的值语法——带单位与尺寸函数的长度、颜色、字体——以及围绕它们的一套机制：简写展开与别名、继承与 CSS 全局关键字、自定义属性与变量引用、`!important`，以及从声明值走到计算值与来源追溯的路径。属性本身属于[样式属性参考](style-properties.md)；在多个声明之间做选择的层叠属于[样式系统总论](style-system.md)。

## 长度

<!-- index: 长度; 尺寸单位; 尺寸函数 -->

长度写成两元素列表 `(UNIT NUMBER)`。Ebox 认识六种单位：`px` 与 `ch` 沿水平轴测量，`lh` 沿垂直轴测量，`%` 相对包含盒，`vw` 与 `vh` 相对视口。属性接受哪些单位取决于它按哪条轴定尺寸：`:width`、`:left` 这类水平属性接受 `px`、`ch`、`vw` 和 `%`；`:height`、`:top` 这类垂直属性接受 `lh`、`vh` 和 `%`；边框宽度接受 `px`、`ch`、`lh`、`vw`、`vh`，但不接受百分比。混用轴的值——垂直属性上的 `(px 4)`、水平属性上的 `(lh 1)`——会被属性校验器拒绝，消息里会列出允许的单位。

长度可以计算。支持 `(calc EXPR)`、`(min ...)`、`(max ...)` 和 `(clamp MIN PREFERRED MAX)`；其中 `+` 与 `-` 组合同一维度的值，`*` 与 `/` 各取一个标量操作数，因此 `(calc (+ (px 1) (px 2)))`、`(calc (* 2 (px 3)))`、`(calc (/ (px 6) 2))`、`(min (px 1) (vw 50))`、`(clamp (px 1) (vw 50) (px 9))` 都是长度。裸数字不是长度，旧的像素简写不是长度，`+` 或 `-` 把数字与长度混在一起也会被拒绝。

有些尺寸属性接受关键字而非长度：`auto`、`min-content`、`max-content`、`fit-content`、`stretch`，以及最大尺寸允许的 `none`。这些关键字是尺寸值，不是长度。

长度在计算样式里保持带类型:声明 `(% 50)` 就算成 `(% 50)`,解析成像素发生在之后、对着实测上下文进行——`%` 相对包含盒,`vw` 与 `vh` 相对视口,`ch` 与 `lh` 相对当前字体。[视口](viewport.md)一章定义这些测量从哪里来、变化时何时重排。非法长度抛 `ebox-size-error`,数据里带属性名与原因。

## 颜色

<!-- index: 颜色; currentColor -->

颜色值是字符串或符号 `currentColor`。Ebox 不解析颜色语法：任何字符串都接受并作为 face 属性交给 Emacs，因此十六进制字符串 `"#B45309"` 与颜色名 `"red"` 都能用。`currentColor` 引用元素自己计算出的 `:color`，也是边框颜色与 `:text-decoration-color` 的初值。

```elisp :figure 长度单位与颜色值：ch、px、百分比与计算长度，以及命名色、十六进制色与 token 色
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 1)
         (row :item-gap '(ch 1)
              (box :height '(lh 1) :width '(ch 6) :background-color "red")
              (box :height '(lh 1) :width '(px 48) :background-color "#0969da")
              (box :height '(lh 1) :width '(% 25) :background-color (etaf-theme-token :ui-accent "#0969da"))
              (box :height '(lh 1) :width '(calc (* 2 (ch 3))) :background-color "#e5e7eb"))
         (text :color (etaf-theme-token :ui-muted-fg "#526174")
               "宽度依次用 ch、px、% 与 calc。")
         (text :color (etaf-theme-token :ui-muted-fg "#526174")
               "颜色依次用命名色、十六进制与 token。")))
```

## 字体

<!-- index: 字体族; 字号; 字重; 字体样式 -->

四个属性承载字体，它们的值语法比 CSS 窄。`:font-family` 是非空字符串或符号，例如 `"DejaVu Sans Mono"` 或 `mono`。`:font-size` 是正数，读作正文大小的倍数，范围 0.3 到 4，不是长度列表；Ebox 绘制时把它乘成 face 高度。`:font-weight` 是 `normal`、`bold`、`bolder`、`lighter` 或一百到九百的 `100`…`900`。`:font-style` 是 `normal`、`italic` 或 `oblique`。前三者默认可继承，因此没有自己声明的子 Host 跟随父级的字体。

## 简写与别名

<!-- index: 简写; 别名; 声明展开 -->

*简写*是一个值代表多个 longhand 属性的属性；*别名*是一个规范属性的另一个名字。Ebox 把两者都登记进属性 schema，因此每种书写界面都接受同一批名字、按同一方式展开。简写包括四边与成对形式——`:padding`、`:margin`、`:border` 及各自的边与分量变体、`:gap`——以及组合形式 `:flex`、`:flex-flow`、`:grid-column-span` 和 `:grid-row-span`。别名只有两个：`:bgcolor` 对应 `:background-color`，`:font-slant` 对应 `:font-style`。

四边形式接受一到四个值，按上、右、下、左的顺序分配（一个值作用于四边，两个值先作用于前两边再重复，依此类推），也接受同时给出 `:top`、`:right`、`:bottom`、`:left` 四个键的关键字 plist。值映射到逻辑 longhand：`top` 设置 `padding-block-start`，`right` 设置 `padding-inline-end`；因为单个值会同时到达两条轴，它必须对两条轴都合法，实践中那就是 `%`，或者用带分边单位的关键字 plist。`:border` 接受一个宽度、一个样式和一个颜色作为单个原子或任意顺序的列表；单独的宽度表示该宽度的 `solid` 边框，单独的样式或颜色用 `1px` 与 `solid` 补齐缺失分量，而 `solid` 与 `none` 是仅有的样式。`:gap` 取一个值同时作用于行与列，或取一对，`:flex` 取一个系数，或 `none`、`auto`、`initial`，或三元素 `(GROW SHRINK BASIS)`，两个 grid span 简写取一个正整数，变成自动的 `(:span N)` 放置。

展开与合并是显式函数，方便宿主在层叠读取之前准备好声明。`ecss-expand-declarations` 把别名规范化、把每个简写展开一次，返回 longhand plist；`ecss-merge-declarations` 对若干组做同样的事，并从左到右合并。两者都不解析带标签的值，也不校验具体值——schema 校验器仍在计算样式时运行——但都会拒绝未知属性与形式错误的声明列表。

**示例。**一个边框值展开成宽度、样式和颜色；下面的盒子用声明的颜色画出边框。

```elisp :run
(etaf-define-component demo-value-badge ()
  :view (box (text "Draft"))
  :styles (("&" :border "#B45309")))
(etaf-view (demo-value-badge))
```

#### Function: ecss-expand-declarations (schemas declarations)

经 SCHEMAS 校验 DECLARATIONS，并把每个简写展开一次。

**参数。** SCHEMAS 是组合好的 schema 集合。DECLARATIONS 是属性/值偶数列，属性是规范 ID 或别名。

**语义。** 每个别名解析成规范属性，每个简写由 schema 的展开函数恰好展开一次，显式 nil 保留为声明。important、CSS 全局值和变量标签原样透传，由层叠而非这里解析。函数只检查属性身份与声明列表的形状，不检查具体值：schema 校验器会拒绝的值也照样展开。

**返回。** 全新的 longhand plist，属性是规范 ID。

**错误。** 属性不在 SCHEMAS 中时 `error→ ecss-invalid-declaration`，数据 `(:unknown-property NAME)`；DECLARATIONS 不是偶数列时数据 `(:declarations VALUE)`。

**示例。**

```elisp
(ecss-expand-declarations schemas '(app/padding 1 :fg "red"))
     ⇒ (app/padding-top 1 app/padding-right 1
        app/padding-bottom 1 app/padding-left 1 app/color "red")
```

**参见。** `ecss-merge-declarations` 与 `ebox-style-canonical-name`。

#### Function: ecss-merge-declarations (schemas &rest declaration-groups)

经 SCHEMAS 从左到右展开并合并 DECLARATION-GROUPS。

**参数。** SCHEMAS 是组合好的 schema 集合。DECLARATION-GROUPS 是若干个偶数列，形状与 `ecss-expand-declarations` 接受的一致。

**语义。** 每组先按 `ecss-expand-declarations` 展开，再按顺序合并：后面的 longhand 覆盖前面的值，显式 nil 也是普通值，因此一组可以用 nil 清掉先前的声明。结果是 longhand plist；具体值不校验。

**返回。** 合并后的 longhand plist。

**错误。** 与 `ecss-expand-declarations` 相同。

**示例。**

```elisp
(ecss-merge-declarations schemas
                         '(app/padding 1 :fg "blue")
                         '(app/padding-left 4 :fg nil))
     ⇒ (app/padding-top 1 app/padding-right 1
        app/padding-bottom 1 app/padding-left 4 app/color nil)
```

**参见。** `ecss-expand-declarations`。

#### Function: ebox-style-canonical-name (name)

返回 NAME 的规范 CSS 风格 longhand 属性名。

**参数。** NAME 是关键字或符号形式的 Ebox 属性名：规范名或别名。

**语义。** 函数在 Ebox 的属性 schema 里查找名字，返回该属性的公开规范名。别名解析成它命名的属性，因此 `:bgcolor` 返回 `:background-color`。不是 Ebox 属性的名字，包括自定义属性，返回 nil。

**返回。** 关键字形式的规范属性名，或 nil。

**示例。**

```elisp
(ebox-style-canonical-name :font-slant)
     ⇒ :font-style
```

**参见。** `ecss-expand-declarations`。

## 继承与全局关键字

<!-- index: 继承; 全局关键字; initial; inherit; unset; revert -->

属性要么可继承、要么不可继承，由 schema 决定。声明没有提供的可继承属性取父级的计算值；不可继承的属性取 schema 初值。声明可以用 `ecss-wide-value` 产生的 CSS 全局关键字覆盖这两种选择：`initial` 选 schema 初值，`inherit` 复制父级计算值（对不可继承属性也一样），`unset` 对可继承属性选继承值、否则选初值，`revert` 移除赢家声明所在的整个来源后再从剩余候选里重选，`revert-layer` 只移除赢家声明所在的层叠层再重选。

全局关键字是带标签的值，不是普通符号：声明值是符号 `inherit` 时它是普通值，而 `(ecss-wide-value 'inherit)` 才是全局关键字。`!important` 与变量引用同样如此；在层叠之前检查声明值的宿主可以问 `ecss-declaration-value-tagged-p` 一个值是否需要层叠计算，并用 `ecss-declaration-value-valid-p` 运行自己的值检查，而不会把带标签的值误当底层数据。

#### Function: ecss-wide-value (kind)

返回 KIND 的带标签 CSS 全局值。

**参数。** KIND 是 `initial`、`inherit`、`unset`、`revert` 或 `revert-layer`。

**语义。** 返回值是带标签的值，由层叠按属性解析：`initial` 用 schema 初值，`inherit` 用父级计算值，`unset` 按属性是否可继承在两者间选择。`revert` 移除赢家声明所在的整个来源——普通与 important 声明一并移除——再从剩余候选里重选；`revert-layer` 只移除该来源里赢家所在的层。没有候选剩下时，属性回退到继承值或初值。

**返回。** 带标签的值。它不等于命名 KIND 的那个符号，普通数据也不会被扫描出它。

**错误。** KIND 不是五种之一时 `error→ ecss-invalid-declaration`，数据 `(:wide-value KIND)`。

**示例。**

```elisp
(ecss-computed-style-value
 (ecss-compute-style schemas subject
                      :parent-style parent
                      :declarations (list 'app/color (ecss-wide-value 'inherit)))
 'app/color)
     ⇒ "red"   ; 父级计算出的颜色
```

**参见。** [层叠顺序](style-system.md#层叠顺序)。

#### Function: ecss-declaration-value-valid-p (value predicate)

在层叠计算之前用 PREDICATE 检查具体声明值 VALUE。

**参数。** VALUE 是声明值。PREDICATE 是一元函数，回答一个具体值是否可接受。

**语义。** important 标签是透明的：内层值交给 PREDICATE。CSS 全局值和变量引用依赖上下文，函数直接返回真而不调用 PREDICATE；解析后的值仍会在计算样式时由 schema 校验器检查。其它值原样交给 PREDICATE，函数把它的结果布尔化后返回。函数从不解析变量、不求值来源、不修改 VALUE；PREDICATE 抛出的错误原样传播给调用方。

**返回。** 布尔值。

**错误。** PREDICATE 抛出的任何条件。

**示例。**

```elisp
(ecss-declaration-value-valid-p (ecss-important "red") #'stringp)
     ⇒ t   ; PREDICATE 收到 "red"
```

**参见。** `ecss-declaration-value-tagged-p`。

#### Function: ecss-declaration-value-tagged-p (value)

返回 VALUE 是否带有必须在投影前计算的 ECSS 重要性、CSS 全局值或变量语义。

**参数。** VALUE 是任意声明值。

**语义。** 函数只检查顶层值：important 标签、CSS 全局值或变量引用算带标签，普通嵌套数据不会被扫描。既不解析也不修改 VALUE。

**返回。** 布尔值。

**示例。**

```elisp
(list (ecss-declaration-value-tagged-p "red")
      (ecss-declaration-value-tagged-p (ecss-var '--tone)))
     ⇒ (nil t)
```

**参见。** `ecss-declaration-value-valid-p`。

## 自定义属性

<!-- index: 自定义属性; 变量引用; var -->

*自定义属性*是具名值，其它声明可以引用它。自定义属性没有 schema：它们的名字是以 `--` 开头的符号，值是层叠在计算层携带的普通数据。属性可以像声明任何属性一样声明一个自定义属性，另一条声明用 `ecss-var` 创建的*变量引用*读取它。引用针对同一主体的已计算自定义属性解析，因此自定义属性可以设在祖先、由后代读取；名字缺失且没给 fallback 时，引用它的属性回退到继承值或初值。fallback 本身还可以是变量引用；引用成环会记进诊断，同时属性回退到初值。自定义属性可以通过[计算样式](ecss-computed-style.md)的自定义属性列表与访问器看到。

#### Function: ecss-var (name &rest fallback)

返回对 NAME 的自定义属性引用，可带 FALLBACK。

**参数。** NAME 是自定义属性符号，即名字以 `--` 开头的符号。FALLBACK 是零个或一个值，在 NAME 未定义时使用；它本身也可以是变量引用。

**语义。** 函数返回带标签的引用。计算样式时，引用解析为所命名自定义属性的计算值；该属性不存在时，有 FALLBACK 就用它，没有则引用它的属性回退到继承值或初值。自定义属性之间成环时，环会出现在计算样式的诊断里，受影响的属性使用初值。

**返回。** 带标签的变量引用。

**错误。** NAME 不是自定义属性符号时 `error→ ecss-invalid-declaration`，数据 `(:custom-property NAME)`。给出多于一个 FALLBACK 时 `error→ wrong-number-of-arguments`。

**示例。**

```elisp
(ecss-computed-style-value
 (ecss-compute-style schemas subject
                      :declarations (list '--tone "teal"
                                          'app/color (ecss-var '--tone)))
 'app/color)
     ⇒ "teal"
```

**参见。** [计算样式](ecss-computed-style.md)。

## 重要性

<!-- index: important; 重要性标签 -->

`!important` 把声明抬到它所属来源的 important 档，在那里它压过同一来源的所有普通声明，并且对 user 与 UA 来源而言，压过更低来源的所有 important 声明。它不改变值的语法：标签里的值照常校验与计算。重要性由 `ecss-important` 产生；预检值的宿主通过 `ecss-declaration-value-valid-p` 看到内层值；展开与编译会保留标签，直到层叠消费它。重要性的档位顺序是[样式系统总论](style-system.md#来源)所述层叠的一部分。

#### Function: ecss-important (value)

返回被标记为 important 声明的 VALUE。

**参数。** VALUE 是任意声明值，普通值或已带标签的值均可。

**语义。** 返回值保留 VALUE 并加上重要性。层叠把该声明放到它所属来源的 important 档来比较，而不是普通档；值的语法与校验不变，其它声明值函数把标签视为透明。

**返回。** 带标签的值。

**示例。**

```elisp
(ecss-declaration-value-tagged-p (ecss-important "red"))
     ⇒ t
```

**参见。** [来源](style-system.md#来源)。

## 计算值与来源追溯

<!-- index: 计算值; 来源追溯; 无效赢家 -->

声明值沿一条确定的路径变成计算值。层叠先从内联声明、样式表规则和继承默认值中为每个 longhand 选出一个获胜声明；随后解析赢家的值——CSS 全局关键字在继承值与初值之间选择，变量引用读取自定义属性集合，重要性已经在赢家的层级上决定了胜负——然后 schema 的归一化器与校验器产出规范的算值，由 Ebox 投影成绘制与几何。

赢家的值无效时，层叠不会把属性让给下一个候选。改用 schema 的继承值或初值，并把无效赢家记录下来，使结果保持确定、可诊断：该属性没有计算出的声明，但重跑层叠也永远不会选出不同的赢家。样式的来源追溯会说明哪个声明获胜、为什么——来源、重要性、层叠层、优先级、作用域邻近度、源顺序与声明顺序，以及是否通过校验——逐属性的事实还给出一并带上计算值的赢家。[计算样式](ecss-computed-style.md)一章定义这些查询；[层叠顺序](style-system.md#层叠顺序)定义产生赢家的比较。
