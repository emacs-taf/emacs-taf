# 样式的实现

<!-- index: Ebox schema; 属性词表; 样式 pass -->

Ebox 拥有样式属性词表，并把声明变成绘制与几何。本章讲[样式属性参考](style-properties.md)背后的机制：schema 定义的形状与建立在它之上的两个查询、编译与缓存、计算样式记录与等价样式的共享、传播脏状态的样式 pass、视口单位依赖表，以及新增一个属性的步骤。选择声明的层叠见[样式系统总论](style-system.md)；本章的函数是 Ebox 的库接口，因此只通过概念与公共条目描述行为。

## schema 定义

<!-- index: schema 字段; contexts; dirty kind; validator; normalizer; 别名 -->

样式属性以不可变数据的形式注册。每条定义给出规范名及其 namespaced ECSS id、别名、初值、是否继承、接受它的作者 tag、所属 group、改动产生的 dirty kind、区分绘制与布局的 signature，以及 normalizer 与 validator。简写属性额外给出展开器；长度类属性额外给出尺寸域。没有显式写出时，改动影响与投影归属由 group 与名字推导。

注册会构造一个 ECSS schema 包，同一份数据还被索引成按规范名、id 与别名快速查找的表。这个索引回答其他层提出的两个问题：该属性由哪个 ECSS id 承载，以及哪些作者表单接受它。属性的语法事实在编译声明时校验，长度类属性的轴域与值一起校验，因此非法单位会在点名该属性的那条声明上报错。

#### Function: ebox-style-schema-id (name)

返回 Ebox 属性 NAME 的 namespaced ECSS schema id，未知则返回 nil。

**参数。** NAME 是 `:color` 这样的规范属性名，或 `:bgcolor` 这样的别名。

**语义。** 查找覆盖规范名、别名与 id 本身。id 是层叠与 ECSS 样式表承载的名字；返回 nil 表示 NAME 在 Ebox 样式词表之外，ETAF 正是借此把样式属性与语义属性、事件属性区分开。

**返回。** namespaced id，或 nil。

#### Function: ebox-style-property-accepted-p (tag name)

当作者表单 TAG 接受属性 NAME 时返回非 nil。

**参数。** TAG 是作者表单 tag——`text`、`box`、`row`、`column`、`flex` 或 `grid`。NAME 是规范属性名或别名。

**语义。** 判定依据属性的 contexts。显式给出 author-contexts 的属性只在这些 tag 上被接受。否则 tag 必须出现在 contexts 里，或者对每个非 `text` 的 tag，contexts 必须包含 `box` 或 `item`；因此 `(text box)` 的属性在 box、row、column、flex、grid 上也被接受，而 `(row column)` 的属性不会。未知名字一律不接受。

**返回。** TAG 接受 NAME 时非 nil，否则 nil。

#### Error: ebox-style-schema-error

Ebox 样式 schema 非法的条件。

**语义。** 该条件属于包公开的错误词表，让扩展 schema 的宿主有一个稳定的可检查条件。属性 schema 本身是固定的注册数据，当前公共接口对声明做的是按它校验，而不是触发该条件；今天没有公共路径抛出它。

## 编译与缓存

<!-- index: 声明编译; strict 模式; 声明缓存; 简写展开; 共享作用域 -->

编译把作者数据变成规范的 ECSS 声明。流水线检查声明列表的形状，把别名与简写恰好展开一次，按 schema 校验每个值，返回以 namespaced id 为键的规范 longhand。编译对输入是纯的，并用有界缓存记忆结果，因此重复出现的声明——组件的静态规则、子树的 Theme 默认值——只展开与校验一次。

规则与作用域建立在同一条流水线上。一条规则把选择器编译成 ECSS 选择器 AST，并在 strict 模式下编译声明；一个作用域把有序规则列表编译成不可变的样式表。同来源的相等规则列表共享同一份编译结果，作用域可以在保留成员身份的前提下换一组新规则，Theme 变化就是这样重新降级组件规则而不重新绑定节点。

#### Function: ebox-style-compile-declarations (plist &optional strict)

把 Ebox PLIST 的别名编译成 ECSS schema 声明。

**参数。** PLIST 是属性名与惰性值组成的偶数长度属性列表。STRICT 非 nil 时拒绝 Ebox 样式域之外的属性名。

**语义。** 列表必须是 proper 偶数长度 plist；解析到同一规范属性的两条条目——包括经别名——会被拒绝。别名被规范化，简写恰好展开一次成规范 longhand；值保持数据形状，`!important`、CSS 全局关键字标签与自定义属性原样保留。每个值按属性的语法与单位域校验：长度类属性里畸形的长度会报出该属性允许的单位，超出关键字语法的值会报出属性与值，同一条物理边被物理属性与逻辑属性重复指向时报 duplicate edge target。strict 模式下未知属性被拒绝，而不是作为不透明的非样式条目继续携带。结果缓存在以 PLIST 的纯样式内容与 STRICT 为键的有界表里，返回的 plist 是新脊柱；输入不被修改。

**返回。** 规范声明 plist。

**错误。** PLIST 不是偶数长度列表时，以及 strict 模式下属性在 Ebox 样式域之外时 `error→ user-error`；规范属性重复或值超出语法时 `error→ error`；长度单位或轴非法时 `error→ ebox-size-error`，数据里带允许的单位；同一条物理边被指向两次时 `error→ ecss-invalid-declaration`，数据 `(:duplicate-edge-target …)`。

**示例。**

```elisp
(ebox-style-compile-declarations '(:bgcolor "red" :padding ((lh 1) (px 2))))
     ⇒ (ebox/background-color "red" ebox/padding-block-start (lh 1)
        ebox/padding-inline-end (px 2) ebox/padding-block-end (lh 1)
        ebox/padding-inline-start (px 2))
```

#### Function: ebox-style-compile-form (tag plist)

把求值后的作者 PLIST 编译一次，并针对 TAG 校验。

**参数。** TAG 是书写这些声明的作者表单 tag。PLIST 是该表单求值后的属性列表。

**语义。** 流水线在 `ebox-style-compile-declarations` 之上加入作者表单规则：nil 只允许用于语法是 boolean 或可选 anchor 的属性，因此颜色或长度上的显式 nil 会被拒绝；展开后每条声明必须已经是规范属性 id；TAG 必须是六个作者表单 tag 之一；tag 必须通过自己的 contexts 接受每个属性。结果像它包装的声明编译一样被缓存。

**返回。** TAG 接受的规范声明。

**错误。** 作者值在 boolean 与 anchor 语法之外为 nil、作者表单 tag 未知、声明不是规范形式、规范声明重复，或 tag 不接受该属性时，`error→ error`。

#### Function: ebox-style-compile-rules (rules)

把有序的 (SELECTOR PROPERTY VALUE ...) RULES 经 ECSS 语法与 strict Ebox 属性 schema 编译。

**参数。** RULES 是有序规则列表；每条规则是一个选择器加一串声明。

**语义。** 每条规则的形状按 ECSS 规则契约校验，选择器被解析成 AST；声明在 strict 模式下编译，因此未知属性或非法值会拒绝整份列表。值保持惰性：不求值任何声明，也不构建样式表或作用域。结果适合用作作用域或样式表的规则字段。

**返回。** `(SELECTOR-AST . DECLARATIONS)` 对的列表。

**错误。** 规则或选择器畸形时报 ECSS 条件；strict 模式下报 `ebox-style-compile-declarations` 的声明错误。

**参见。** `ebox-style-scope-create`、`ebox-style-scope-with-rules`。

#### Function: ebox-style-scope-create (rules &key (origin 'author))

在 ORIGIN 上用有序 RULES 创建不可变共享作用域。

**参数。** RULES 是 `ebox-style-compile-rules` 接受的有序规则列表。ORIGIN 是规则进入的层叠来源，默认 `author`。

**语义。** 规则被编译一次成不可变的共享样式表：同 ORIGIN 的相等 RULES 复用同一个编译对象，样式表按内容缓存且有上限。返回的作用域带稳定的成员身份，与其他作用域区分，即使由相同规则构造。作用域只影响挂到它上面的根；它不声明层叠层，因此规则在 ORIGIN 上是未分层的。把作用域挂到节点上，节点就通过它的作用域绑定成为成员，根使用自己的快照作用于其内的成员；没有挂到任何根上的作用域不产生规则。创建作用域不修改 RULES 或其他任何输入。

**返回。** 共享作用域。

**错误。** `ebox-style-compile-rules` 的规则与声明错误。

**参见。** `ebox-style-scope-with-rules`。

#### Function: ebox-style-scope-with-rules (scope rules &key (origin 'author))

返回保留 SCOPE 成员身份的新 RULES 快照。

**参数。** SCOPE 是 `ebox-style-scope-create` 返回的作用域。RULES 是新的有序规则列表，ORIGIN 是层叠来源，默认 `author`。

**语义。** 结果是一个新作用域，它的成员身份就是 SCOPE 的，因此已经通过该身份挂上的节点无需重新绑定仍是成员。新规则按 `ebox-style-scope-create` 的方式编译；RULES 可以为 nil，此时去除该作用域的规则但保留成员身份。SCOPE 与任何先前构造的输入都不被修改。增量宿主用它替换规则快照，例如 Theme 变化后要把组件的静态规则重新降级。

**返回。** 新的作用域快照。

**错误。** SCOPE 不是作用域时 `error→ error`；否则报 `ebox-style-compile-rules` 的规则与声明错误。

## 计算样式记录

<!-- index: 计算样式; hash-consing; 继承键; 布局键 -->

每个节点保留一条计算样式记录：所有 longhand 的规范值，加上绘制与布局直接读取的事实——tag、隐藏状态、背景、face、字体度量、装饰、八条 padding 与 margin 边、四条边框的宽度与颜色、盒尺寸、定位、外部参与、溢出、换行模式、对齐、间隔、堆叠与锚定。这条记录是绘制与几何的唯一来源，样式 pass 以整体替换对象的方式更新它，而不是在原地修改。

记录是 hash-cons 的。计算样式以节点的 tag、编译后的声明、以及适用作用域的快照为键缓存，因此样式相同的节点共享同一个对象，样式比较可以用对象身份。子节点按「能从父级继承到的东西」分桶查找：父级的继承键覆盖继承值，所以继承结果相同的兄弟复用父级那条记录。显式 `inherit` 声明可以复制不可继承的父值，这种节点就用父样式本身分桶。

几何比较还有自己的共享键：记录的几何相关值列表被放进弱表里共享，于是两条记录也能用身份比较布局输入。这个键决定样式改动只需重绘还是需要重排。

## 样式 pass

<!-- index: 样式 pass; 脏位; 重排边界 -->

节点被强制标记、样式脏位置起、或还没有计算样式时，样式 pass 会访问它。算出新记录后与旧记录按身份比较；两者是同一对象就结束——这是 hash-consing 的回报。记录变化时，pass 标记路径，让布局与绘制能从根找到它。

随后对改动分类。布局键不变，或只差不改变度量的字重时，只标重绘。否则清空固有尺寸缓存并标重排；父级如果是摆放依赖子项事实的容器——flex 或 grid 容器，或任何外部参与、绝对定位发生变化的子节点的父级——父级也标重排。获得或失去绝对定位的节点会被移出或重新登记为宿主，锚定浮层会重新登记。

传播沿继承走，而不是整棵树。父级的继承键变化，或节点环境变化时，才强制访问子节点；否则只下降到已经记录为脏的子节点。因此继承结果不变的改动——某张卡片的背景微调、一次悬停重绘——不会遍历很大的子树。

## 视口单位依赖

<!-- index: 视口单位; refit; 依赖表 -->

长度可能读取 `vw` 或 `vh`，它们的值取决于挂载的视口而不是节点树。样式 pass 把计算样式读取这些单位的节点记进弱表，并记下每个节点用的是哪个单位；某次重样式不再读取它们时，登记被移除。

缓冲区视口尺寸变化时，`ebox-refit` 使用这张表。宽度变化标记根，因为根的可用宽度就是视口，并只标记登记为读 `vw` 的节点；高度变化只在根本身的块尺寸跟随包含高度时标记根，并只标记登记为读 `vh` 的节点。随后重排，视口变化钩子运行。没有视口依赖、约束也未变的节点不会重排。

## 新增样式属性

<!-- index: 扩展 schema; 属性注册; 验收测试 -->

新属性加在 schema 数据里，再通过投影与测试落地：

1. 加定义：规范名、namespaced id、别名、初值、继承、contexts、group、dirty kind、signature、validator，以及需要时的 normalizer、简写、尺寸轴、显式的 impacts 或 projections。group 与名字能推导出影响与投影归属时，它们可以省略。
2. 把值语法定准：validator 决定接受什么，尺寸轴约束单位，轨道类语法还要约束嵌套值。
3. 简写要加展开器，产出规范 longhand，且只展开一次；别名只需要在名字索引里加一项。
4. 在消费处投影计算值：绘制类在合成 face 与部件时读取，几何类在布局解析尺寸与位置时读取，结构类在决定参与与摆放时读取。会让父级必须重算的属性归入影响父级的 dirty 类别。
5. 用公共行为验收：覆盖值语法、初值与继承行为、适用的 tag、以及影响绘制还是几何；然后把条目补进[样式属性参考](style-properties.md)，词表齐全后再加入它的覆盖清单。

配套的 ETAF 工作——让某个 Host 属性到达该属性，或让组件规则声明它——使用现有的作者界面；属性本身只在 schema 条目里定义。
