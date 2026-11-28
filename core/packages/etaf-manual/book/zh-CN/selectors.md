# 选择器

*选择器*决定一条样式规则作用于哪些主体，也决定一次查询能找出哪些节点。选择器语言形似 CSS，但语义自成一套：ECSS 负责解析、匹配与计分，Ebox 把每个保留节点暴露成主体，因此同一段选择器文本既驱动样式层叠，也驱动直接的树查询。本章定义主体模型，从类型、ID、类、属性，到伪类与组合子，再到 `&` 与 `:scope` 的选择器语言，优先级的计算方式，以及解析、校验、匹配与查询各函数。主体与适配器对象本身见[主体与适配器](ecss-subjects-and-adapters.md)；选择器在层叠里的使用见[样式系统总论](style-system.md)。

## 主体

<!-- index: 主体; Ebox 节点作为主体 -->

*主体*是被选择器匹配的东西。匹配器从一个主体读取七类事实：类型、ID、一个类 token 列表、一个属性 alist、一个状态 token 列表、父节点和一个有序子节点列表。ECSS 既能匹配自己的主体值，也能适配调用方自己的树；因此样式规则和树查询跑的是同一套匹配器、读的是同一组事实。

Ebox 把每个保留节点暴露成主体，选择器词表因此与节点模型一一对应：

| 事实 | Ebox 节点的来源 |
| --- | --- |
| 类型 | tag 名：`text`、`box`、`row`、`column`、`flex`、`grid`、`image` |
| ID | 节点的 `:id` |
| 类 | 节点的 `:class` token；字符串按空白切分，符号表示一个类名 |
| 属性 | 节点的属性，外加节点的 `id` 与 View key |
| 状态 | 节点的作者状态，外加派生的 `disabled`、`focus` 和 `active` |
| 树 | 保留的父节点与子节点 |

类型名、ID 和类 token 一律区分大小写比较。ID 和 key 同时以属性 `id`、`key` 暴露，因此 `[id=…]` 和 `[key=…]` 能匹配 `#…` 写不出的值；普通的 ECSS 主体把 ID 和类保留成独立字段，属性选择器只读它的属性 alist。

状态是一个 token 集合，不是可以随意写入的节点元数据。Ebox 从 Host 的 `:disabled` 派生 `disabled`，从已挂载 buffer 里获得焦点或被按下的节点派生 `focus` 与 `active`；节点还携带作者状态，`ebox-node-set-states` 会替换它们。三个派生名字都不能由作者写入。匹配器不认识的函数形伪类，例如 `:my-state(on)`，只在状态集合恰含字面条目 `("my-state" "on")` 时命中——宿主可以通过同一机制暴露自己的状态。

## 选择器语法

<!-- index: 选择器语法; 复合选择器; 选择器列表 -->

一个选择器是用逗号分隔的复杂选择器列表；主体命中其中任意一项就算命中整个列表。每个复杂选择器是由组合子连接的一串复合选择器，而一个复合选择器是不含空白的一个或多个简单选择器：类型或 `*`、`#id`、`.class`、属性选择器或伪类。

### 类型、ID 与类

<!-- index: 类型选择器; ID 选择器; 类选择器; 通用选择器 -->

类型选择器如 `text` 匹配节点的 tag 名，`#save` 匹配节点的 ID，`.primary` 匹配一个类 token，`*` 是通用选择器、匹配一切主体。同一复合选择器里的简单选择器必须全部命中，所以 `text.primary#print` 只匹配同时具有该类与 ID 的 `text` 节点。类型、ID 与类名区分大小写。

写成 `#…` 的 ID 必须是选择器标识符：字母、数字与转义，标点须是选择器语法允许的那些。其它值改用属性选择器，例如 `[id="save button"]`。

### 属性

<!-- index: 属性选择器; 属性运算符 -->

属性选择器测试一个属性。共有七种形态：存在性，以及六种运算符，每种都可带大小写标志：

| 形态 | 匹配 |
| --- | --- |
| `[name]` | 属性存在，不论值是什么 |
| `[name=value]` | 值恰好是 `value` |
| `[name~=value]` | 值是空白分隔的列表且包含 `value` |
| `[name\|=value]` | 值是 `value`，或以 `value-` 开头 |
| `[name^=value]` | 值以 `value` 开头 |
| `[name$=value]` | 值以 `value` 结尾 |
| `[name*=value]` | 值包含 `value` |

值可以写裸标识符或引号字符串，因此带空格或标点的值也能写。默认全部比较区分大小写；标志 `i` 忽略大小写，标志 `s` 显式声明默认值，例如 `[data-kind=commit i]`。属性名始终区分大小写。存在但值为 nil 的属性满足存在性选择器；除非运算符恰好跟空值比较，否则它不满足带运算符的选择器。

### 伪类

<!-- index: 伪类; 状态伪类; 结构伪类; 位置伪类 -->

伪类用一个冒号书写，用来收窄主体。普通的状态伪类如 `:hover` 或 `:disabled` 在状态集合含该 token 时命中；伪类名不区分大小写，`:HOVER` 与 `:hover` 相同。Ebox 提供 `disabled`、`focus` 和 `active`，以及作者状态；宿主适配器还可以提供任意其它 token。

结构伪类按主体在兄弟中的位置匹配，读取树：`:first-child`、`:last-child`、`:only-child`、`:empty`（没有子节点）、`:root`（没有父节点），以及按类型的 `:first-of-type`、`:last-of-type`、`:only-of-type`——后三者比较兄弟的类型。

位置伪类带参数：`:nth-child(2n+1)`、`:nth-last-child(1)`、`:nth-of-type(2)`、`:nth-last-of-type(odd)`。参数是 `An+B` 表达式：整数、`odd`、`even`，或 `2n`、`2n+1`、`-n+3` 这类形式。两个 child 形式还接受 `of` 过滤器，先用一个选择器把兄弟缩到匹配的那些，例如 `:nth-child(2 of .item)`；`-of-type` 形式不接受过滤器。

元数据伪类 `:lang(en)` 与 `:dir(ltr)` 读取可继承的属性：匹配器先在主体、再沿祖先链查找 `lang` 或 `dir`。`:lang` 在值相等（忽略大小写）或以所请求语言加连字符开头时命中；`:dir` 要求值恰好相等（忽略大小写）。`::` 伪元素不支持。

**示例。**一个列表可以用位置伪类恰好标出其中一行；第二项用规则里的颜色渲染。

```elisp :run
(etaf-define-component demo-selector-pick ()
  :view (column
         (text :class "item" "alpha")
         (text :class "item" "beta")
         (text :class "item" "gamma"))
  :styles (("& .item:nth-child(2)" :color "#B45309")))
(etaf-view (demo-selector-pick))
```

### 逻辑伪类

<!-- index: is; where; not; has; 相对选择器 -->

`:is(SELECTORS)` 在任一参数命中时命中，`:where(SELECTORS)` 做同样的事但不贡献优先级，`:not(SELECTORS)` 在所有参数都不命中时命中。三者都接受完整的选择器列表，所以 `:is(div > .label, .badge)` 这样的复杂选择器可以写在里面。

`:has(SELECTORS)` 在主体拥有一个匹配的相对目标时命中：目标是它的后代，或它后面的兄弟及后续兄弟的后代。相对选择器可以以 `>`、`+` 或 `~` 开头来声明与主体的关系，关系还可以串起来：`:has(> .row)`、`:has(+ .hint)`、`:has(~ .note)`、`:has(+ .row .cell)` 都合法。`:has` 从不看向之前的兄弟。

### 组合子

<!-- index: 后代组合子; 子组合子; 兄弟组合子 -->

四个组合子用来连接复合选择器。空白是后代组合子，匹配任意祖先；`>` 是子组合子，匹配父节点；`+` 是相邻兄弟组合子，匹配紧前的一个兄弟；`~` 是一般兄弟组合子，匹配任一前置兄弟。例如 `box > .row .item` 匹配一个 `box` 之下、`.row` 里面的 `.item`，`button + button` 匹配紧跟另一个按钮之后的按钮。

### & 与 :scope

<!-- index: 作用域根; & 选择器; :scope -->

选择器可以点名它所在作用域的根：`&` 与 `:scope` 都匹配那个根。在 Component 的 `:styles` 规则或 `.ebox` 文件的本地规则里，作用域根就是挂载作用域的那个节点，因此 `&` 给该节点自身设样式，`&.active` 只在它匹配时设样式，`:scope > .row` 给它的直接子节点设样式。

没有点名作用域根的规则选择器会被锚定到作用域上：它被当作该根的后代来匹配，因此 `.title` 选中作用域内部某个节点，永远不会是根自身。作用域以及为它书写的规则，是[组件样式与主题](component-styles-and-themes.md)的主题。

作用域之外没有可点名的根，所以在裸 `ecss-selector-match-p` 调用或 `ebox-selector-query` 里，`&` 与 `:scope` 不匹配任何东西；只有在匹配带作用域的样式表时它们才有意义。

```elisp :figure 组件规则里的类选择器：.item 给每行上色，.item.selected 给选中行，.item .marker 给行内文字
(etaf-define-component demo-selector-list ()
  :styles ((".item" :padding ((lh 0) (ch 1)) :background-color "#f6f8fa")
           (".item.selected" :background-color "#dbeafe")
           (".item .marker" :color "#0969da" :font-weight bold))
  :view
  (column :width '(ch 44) :item-gap '(lh 0)
          (row :class "item" (text "普通行"))
          (row :class "item selected" (text "选中行"))
          (row :class "item" (text :class "marker" "标记文字"))))
(etaf-view (demo-selector-list))
```

## 选择器接口

<!-- index: 选择器 AST; 选择器校验 -->

选择器经 Lisp 接口传递时有两种形态：源文本，或解析后的值——*AST*。`ecss-selector-parse` 把文本变成 AST，`ecss-selector-normalize` 校验并复制 AST，`ecss-selector-match-p` 匹配单个主体，`ecss-selector-specificity` 给单个选择器计分。解析单独成一步，是因为一份 AST 可以存下来反复匹配；层叠里的样式表对象就以这种形式保存规则的选择器。

#### Function: ecss-selector-parse (selector)

把 CSS 风格的 SELECTOR 文本解析成结构化的选择器 AST。

**参数。** SELECTOR 是非空字符串。接受的语言就是上面的选择器语法：选择器列表、复合选择器、类型、`#id`、`.class`、`*`、带六种运算符与 `i`、`s` 标志的属性选择器、状态/结构/位置/元数据伪类、带相对选择器的 `:is`、`:where`、`:not`、`:has`、四个组合子、`&`、`:scope`、反斜杠转义和 `/* */` 注释。

**语义。** 结果是数据。复合选择器变成 `(:and ITEM ...)`；组合子变成 `(:descendant LEFT RIGHT)`、`(:child LEFT RIGHT)`、`(:adjacent LEFT RIGHT)` 或 `(:sibling LEFT RIGHT)`；ID 是 `(:id "save")`，类型是 `(:type "text")`，类是 `(:class "item")`，属性是 `(:attr "name" "=" "value" nil)`，`*` 是 `(:universal)`，`&` 是 `(:scope-root)`。伪类变成 `(:state "hover")`、`(:state ("nth-child" "2n+1"))` 或 `(:state ("nth-child" "2n+1" FILTER))`；逻辑形式变成 `(:is ...)`、`(:where ...)`、`(:not ...)`、`(:has ...)`，`:has` 的参数以主体为锚。伪类名会被转成小写；类型、ID、类与属性名保留原大小写。

解析只检查选择器语法，不检查每个参数：像 `:nth-child(2x)` 这种不合法的 `An+B` 公式也能解析出来，只有在校验或使用时才失败。注释与空白会被跳过，`::` 伪元素被拒绝。

**返回。** 全新的 AST 列表结构。

**错误。** SELECTOR 不是字符串、为空、括号不配对、字符串或注释未闭合、含伪元素、属性标志未知、出现意外字符或结尾转义时 `error→ ecss-invalid-selector`；条件数据指出失败原因，例如 `(:pseudo-elements-unsupported)`、`(:attribute-flag "x")` 或 `(:unclosed-string)`。

**示例。**

```elisp
(ecss-selector-parse "div.app > #save:hover")
     ⇒ (:child (:and (:type "div") (:class "app"))
               (:and (:id "save") (:state "hover")))
```

**参见。** `ecss-selector-normalize` 与 `ecss-selector-match-p`。

#### Function: ecss-selector-normalize (selector)

为字符串或结构化 SELECTOR 返回校验过的防御性 AST。

**参数。** SELECTOR 是选择器字符串或 AST。

**语义。** 字符串先解析；随后校验整个 AST：每种形式参数个数正确，类型、ID、类名非空，属性选择器是已知形态之一，位置参数是合法的 `An+B` 表达式，且 `of` 过滤器只出现在 child 形式上。结果是一份副本，与输入不共享可变结构，因此调用方可以保存并修改返回的 AST 而不影响它来自的选择器。匹配、优先级和层叠都接受已经归一化的 AST，并会再次校验。

**返回。** 校验过的 AST。

**错误。** 选择器非法时 `error→ ecss-invalid-selector`；条件数据是出错的 AST 或字符串。

**示例。**

```elisp
(ecss-selector-normalize "&.active")
     ⇒ (:and (:scope-root) (:class "active"))
```

**参见。** `ecss-selector-parse`。

#### Function: ecss-selector-match-p (selector subject &optional adapter)

当 SELECTOR 经可选 ADAPTER 匹配 SUBJECT 时返回非 nil。

**参数。** SELECTOR 是选择器字符串或 AST。SUBJECT 是适配器能读取的任意值。ADAPTER 是可选的适配器；省略时用内建适配器读取 `ecss-subject-create` 创建的主体。

**语义。** 调用会校验 SELECTOR，字符串先解析，然后用本章的规则匹配 SUBJECT：类型、ID 与类相等，七种属性形态及其大小写标志，状态/结构/位置/元数据伪类，逻辑形式，以及组合子。字符串每次调用都会重新解析，因此同一选择器要匹配多次时，调用方应当解析一次、传 AST。

`:scope` 与 `&` 只在作用域根或相对选择器锚点生效时匹配；应用代码的裸调用两者都没有，所以那里它们不匹配任何东西。类型、ID、类比较区分大小写；属性 `i` 标志与 `:lang`、`:dir` 伪类不区分大小写。

**返回。** SUBJECT 命中时返回非 nil，否则返回 nil；返回值不保证是 `t`。

**错误。** SELECTOR 非法时 `error→ ecss-invalid-selector`。ADAPTER 不是适配器时 `error→ wrong-type-argument`。

**示例。**

```elisp
(let ((subject (ecss-subject-create
                :type "button" :classes '("primary") :states '("hover"))))
  (ecss-selector-match-p "button.primary:hover" subject))
     ⇒ t
```

**参见。** `ecss-selector-parse`、`ecss-selector-normalize` 与 `ebox-selector-match-node-p`。

## 优先级

<!-- index: 优先级; ID 计数; 类计数; 类型计数 -->

选择器的*优先级*是一个 `(ID CLASS TYPE)` 三元组，层叠在比过来源、important 和层叠层之后比较它（见[样式系统总论](style-system.md#层叠顺序)）。ID 计入第一个数，类、属性或伪类计入第二个数，类型计入第三个数；通用选择器与 `&` 不贡献任何数。选择器有多部分时相加，逻辑形式则取各参数的最大值：

| 选择器 | 优先级 |
| --- | --- |
| `#save` | `(1 0 0)` |
| `.item[data-kind]` | `(0 2 0)` |
| `text:hover` | `(0 1 1)` |
| `:is(.a, #b)` | `(1 0 0)` |
| `:where(#b)` | `(0 0 0)` |
| `:not(.a) .b` | `(0 2 0)` |
| `:has(> #save)` | `(1 0 0)` |

#### Function: ecss-selector-specificity (selector)

返回 SELECTOR 的优先级 `(ID CLASS TYPE)` 列表。

**参数。** SELECTOR 是选择器字符串或 AST。

**语义。** 字符串先解析、AST 先校验，与 `ecss-selector-normalize` 相同。复合选择器把各项的贡献相加；组合子或复合的 `:and` 把两侧相加；`:is`、`:not`、`:has` 与选择器列表取各参数的最大值；`:where` 为零；`:scope` 算一个伪类；`of` 过滤器把自己的优先级加到所属位置伪类的类计数上。

**返回。** 全新的、由非负整数组成的三元列表。

**错误。** SELECTOR 非法时 `error→ ecss-invalid-selector`。

**示例。**

```elisp
(ecss-selector-specificity ":is(.a, #b) .x")
     ⇒ (1 1 0)
```

**参见。** [层叠顺序](style-system.md#层叠顺序)。

## 节点树查询

<!-- index: 选择器查询; 文档顺序 -->

同一套选择器也可以跑在保留树上，而不走层叠。`ebox-selector-query` 在一个节点之下找匹配，`ebox-selector-query-buffer` 在某个已挂载 buffer 的根之下找匹配，`ebox-selector-match-node-p` 测试单个节点。查询按文档顺序遍历树——节点先于它的子节点，兄弟按顺序——并且包含起始节点自身，因此从某个节点发起的查询可以返回该节点。查询从不修改树或任何样式。

查询匹配的是节点树，因此 Ebox 状态可见：`:disabled` 跟随 `:disabled` 属性，`ebox-node-set-states` 设置的作者状态也可用；`:focus` 与 `:active` 需要已挂载 buffer 的实时状态。

#### Function: ebox-selector-query (root selector)

按文档顺序返回 ROOT 的后代或自身中匹配 SELECTOR 的节点。

**参数。** ROOT 是 Ebox 节点。SELECTOR 是选择器字符串或 AST。

**语义。** 函数按文档顺序遍历 ROOT 及其全部后代，收集每个匹配节点，包含 ROOT 自身；结果没有重复。匹配期间，若 ROOT 属于已挂载 buffer，还会绑定它所在树的挂载上下文，因此挂载派生的状态可见。裸查询没有活动作用域，`:scope` 与 `&` 在这里不匹配任何东西。

**返回。** 按文档顺序排列的匹配节点列表；没有匹配时返回空列表。同一节点只会返回一次，即使它的多个祖先都被访问过。

**错误。** SELECTOR 非法时 `error→ ecss-invalid-selector`。

**示例。**

```elisp
(let ((root (ebox-build
             '(box
               (text :class "item" "A")
               (text :class "item" "B")))))
  (mapcar #'ebox-node-text-p (ebox-selector-query root ".item")))
     ⇒ (t t)
```

**参见。** `ebox-selector-query-buffer` 与 `ebox-selector-match-node-p`。

#### Function: ebox-selector-query-buffer (buffer-or-name selector)

返回 BUFFER-OR-NAME 里挂载的、匹配 SELECTOR 的节点。

**参数。** BUFFER-OR-NAME 是 buffer 或 buffer 名。SELECTOR 是选择器字符串或 AST。

**语义。** 函数取 BUFFER-OR-NAME 里挂载的根，对它执行 `ebox-selector-query`。buffer 没有挂载根时结果为 nil。

**返回。** 按文档顺序排列的匹配节点列表；没有挂载根时为 nil。

**错误。** 存在挂载根且 SELECTOR 非法时 `error→ ecss-invalid-selector`。

**示例。**

```elisp
(let ((buffer (ebox-render-to-buffer
               "*items*"
               (ebox-build '(box
                             (text :class "item" "A")
                             (text :class "item" "B"))))))
  (mapcar #'ebox-node-text-p (ebox-selector-query-buffer buffer ".item")))
     ⇒ (t t)
```

**参见。** `ebox-selector-query`。

#### Function: ebox-selector-match-node-p (node selector)

当 NODE 匹配结构化或字符串 SELECTOR 时返回非 nil。

**参数。** NODE 是 Ebox 节点。SELECTOR 是选择器字符串或 AST。

**语义。** 函数用与查询相同的适配器和匹配器匹配单个节点，因此整个选择器语言都适用，包括 Ebox 状态集合。字符串每次调用都会重新解析。

**返回。** NODE 命中时返回非 nil，否则返回 nil。

**错误。** SELECTOR 非法时 `error→ ecss-invalid-selector`。

**示例。**

```elisp
(ebox-selector-match-node-p
 (ebox-text-create "Draft" '(:class "item")) ".item")
     ⇒ ("item")
```

**参见。** `ebox-selector-query` 与 `ecss-selector-match-p`。
