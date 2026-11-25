# 扩展语法

> **状态。** 容器词汇表、`@tab` 子块标记、站点组件、`etaf-md-define-node`、`etaf-md-set-attr`（面向容器节点选择器）与 `etaf-md-describe-nodes` 均已实现并支持渲染。源码 buffer 辅助编辑模式（第 7 章 `etaf-md-edit-mode`）以及核心 Markdown 节点样式选择器仍属于规划中的提案。
>
> **怎么读。** 写文档看第 3、5、6 章。写容器定义看第 9、10 章。实现渲染器看第 2、7、8、11 章。想知道今天能用什么，看 6.17。想知道某个名字为什么这么写，看附录 E。
>
> 中英两版一节对一节。改一处，另一处同时改。

## 速查

写一份文档只需要知道这些。

**两条规则。** `:::名字 {属性}` 开一块，`:::` 单独一行结束，关掉最近打开的那个。文件里最后一块可以不写结束行。

一个块容器：

````markdown
:::card {title="缓存命中"}
图片和矢量按页面尺寸缩放，不重新画。
:::
````

一个父类型。子块的名字与写法都由它解释，`tabs` 用 `@tab` 一行一个子块：

````markdown
:::tabs
@tab Emacs 29
用 `image-size` 的旧签名。
@tab {title="Emacs 30+" selected=true}
直接传 buffer。
:::
````

**最常用的属性。**

| 属性 | 类型 | 写在哪 | 例子 |
| --- | --- | --- | --- |
| `title` | string | 容器与子块 | `title="缓存命中"` |
| `description` | string | card | `description="一句话摘要"` |
| `surface` | surface | box | `surface=raised` |
| `accent` | accent | box、card、提示块 | `accent=warning` |
| `text-align` | align | box、card | `text-align=center` |
| `columns` | number 或 string | columns、stats | `columns="2fr 1fr"` |
| `gap` | length | columns | `gap="2ch"` |
| `padding` | length | box、columns | `padding="1lh"` |
| `open` | boolean | collapse、提示块 | `open=true` |
| `selected` | boolean | tab | `selected=true` |
| `list-style` | enum | steps、timeline、file-tree | `list-style=decimal` |
| `href` | string | card | `href="#安装"` |

**七个面：** `none`、`page`、`raised`、`sunken`、`quote`、`table-header`、`table-stripe`。**六个强调：** `neutral`、`primary`、`success`、`warning`、`danger`、`important`。

长度必须带单位，`2ch` 或 `1lh`，光写 `2` 是错的。颜色和字号文档里一个都不写，它们由读者的主题与样式表决定。

属性名想不起来，就用 `etaf-md-describe-nodes` 查（独立的源码辅助模式 `etaf-md-edit-mode` 仍在规划中）。

## 1. 定位

### 1.1 这个包做什么

一件事：把一份 Markdown 文档变成 ETAF 视图，挂在 buffer 里给人读。输入是文本，输出是字符网格上的盒子、文本和 face。

它自带一套容器词汇，让文档能写出普通 Markdown 写不出的结构：提示块、卡片、步骤、标签页、时间线。词汇是关闭的，用户可以在第 10 章的口子上加，但文档本身不能定义新东西。

### 1.2 边界：文档与页面

页面、目录、路由、导航、数据源、发布，这个包一概不知道。那些属于上层应用。

上层应用有自己的页面模型、布局注册表、目录树、站点导航和数据源。它 `require` 这里的根入口，只调用公开接口。这里不为上层的策略加开关、加参数。

两边的接缝只有一处：文档变成视图。`etaf-md-view` 将文本或文件会话返回为可直接挂载到任意区域的 ETAF View，`etaf-md-define-node` 负责注册容器类型；上层应用只需通过这些公开入口与会话生命周期、导航、状态快照和能力诊断接口交互。

这个包也不产出 HTML。它画的是 buffer。要让别人在浏览器里看，那是上层应用自己的后端。

一条容易混的地方先钉住：第 5 章的 `columns` 是**文档内部的栏**，管一段正文怎么排。页面的版式是上层注册表里的名字，不在本文范围内。

### 1.3 参考对象和它的差距

设计参考 `vuepress-theme-plume`。它的 Markdown 扩展在 `plugins/plugin-md-power/` 里，真实结构是三样东西。

- **一个容器工厂**，在 `src/node/container/createContainer.ts`。它暴露 `createContainerPlugin` 和 `createContainerSyntaxPlugin`，前者让内容照常按 Markdown 解析，后者自己处理内容。
- **一张注册表**，在 `src/node/container/index.ts`。一次装二十来个预设：`align`、`tabs`、`code-tabs`、`window`、`steps`、`card`、`card-grid`、`card-masonry`、`encrypt`、`npm-to`、`lang-repl`、`file-tree`、`code-tree`、`timeline`、`collapse`、`chat`、`field`、`table`。
- **三十来个客户端组件**，例如 `VPCodeTabs`、`VPTabs`、`VPCollapse`、`VPField`、`VPTimeline`、`VPCodeTree`、`VPTable`、`VPPlot`、`VPAnnotation`、`VPQRCode`、`VPPdf`、`VPArtPlayer`、`VPCodePen`、`VPCodeSandbox`、`VPCard`、`VPCardGrid`、`VPCaniuse`。

照抄不行，三条硬差别。

1. **产物不同。** plume 的产物是 HTML、Vue 组件和 CSS。我们的产物是字符网格上的盒子、文本和 face。一个容器最后落到 buffer 里，就是若干行带文本属性的字符。
2. **表达力不同。** CSS 有任意长度、绝对定位、渐变、圆角、阴影和动画。字符网格只有行高、字符宽、边框、底色、字重、下划线，加上框线字符。
3. **运行环境不同。** plume 的页面带客户端脚本。我们的页面是纯文本结果，读的人要能用 isearch 搜到它，用 `C-w` 复制，用 org 导出，在终端里看。

照抄的症状很明显。卡片的圆角和阴影会变成乱码字符，标签页的滑动动画会变成逐帧重绘，聊天头像会变成缺字方块。

能借鉴的是两件事，不是实现。

1. **容器工厂。** 二十个效果共用两个工厂函数，说明这个名字收敛得对。我们照这个形状做，渲染钩子返回 ETAF 视图。
2. **效果清单。** plume 解决过的问题就是一张需求表。逐个问「这个问题在字符网格里长什么样」。网格里说得清的吸收，说不清的不做，理由写进附录 D。

## 2. 模型

### 2.1 一种东西：节点

一篇文档是一串节点。节点有类型、属性、子节点。段落、标题、代码、表格、容器都是节点，区别只在类型。

解析器只认三件事：开、关、嵌套。它不知道 `card` 是什么意思，也不知道它收哪些属性。名字归注册表，属性的含义归声明，摆放归画法。

### 2.2 一个模型

系统里只有一种东西：节点类型。文本类型和容器类型在同一张表里，走同一个 `etaf-md-define-node`。

| 类型 | 文档写得出来吗 | 例子 |
| --- | --- | --- |
| 解析器产生 | 写不出，没有 `:name` | `heading`、`quote`、`code`、`table` |
| 文档写得出来 | 写 `:::名字` | `card`、`tabs`、`columns` |

区别只有一处：**文档写得出来的类型有名字**（`:name`）。`heading` 没有，所以 `:::heading` 不存在，它只能由 `###` 产生。

收固定子块的类型写 `:accepts`，例如 `columns` 只收 `col`；不写就是任意块。**子块不是类型，它没有自己的声明**，名字和写法都由父类型解释。默认写法是 `:::name`，`tabs` 与 `code-tabs` 用 `@name` 一行一个。所以 `@tab` 只在声明了 `markers` 的容器里是标记，在提示块里是普通文字；`:::tab` 在 `tabs` 里则是一个错误。

父子关系不跨层。`tabs` 里的 `tab` 可以再装一个 `card`，但 `tab` 不能再装一个 `tab`。要嵌套就再包一层 `tabs`。

### 2.3 一个承载者

每个事实只写在一处，只有一类角色写它，只有一个读者。写不出「谁读」的东西一律删掉。

| 事实 | 谁写 | 存在哪 | 谁读 |
| --- | --- | --- | --- |
| 正文文字 | 作者 | 节点子节点 | 画法 |
| 普通属性 `title`、`accent`、`prefix` | 文档给默认，读者可用 `set-attr` 盖掉 | 节点属性与样式规则 | 画法，经 `attr` |
| 派生属性 `level`、`language`、`number` | 解析器与派生阶段 | 节点属性 | 规则选择器、画法 |
| 主题色值 | 主题 | 令牌表 | 只有样式规则 |
| 契约 | 声明 | 注册表 | 校验、`describe-nodes` |
| 块状态 | 读者交互 | 块状态格子 | 画法 |
| 可用宽度 | 渲染器 | env | 画法 |

三条推论。

1. **令牌不进画法。** 画法读属性，属性的值在样式规则里指向令牌，所以读者永远盖得住颜色。
2. **整篇算出来的值写到节点上。** 章节号是这样进来的，env 不提供读它的函数。
3. **节点是唯一的数据源。** `attr` 读的、规则盖的都是同一个节点；`env` 只补渲染服务、外观换算与块状态，不另存一份。

### 2.4 管道

```
文本 → 解析 → 节点树 → 派生 → 渲染 → 视图
```

- **解析**：封闭。调用共享的 `etaf-ui-markdown-parse`，本文不改它。
- **派生**：整篇算一次。章节号、锚点、块的显示身份都在这一步，结果写到节点属性上。
- **渲染**：按块独立。声明的属性与画法在这一步生效。

派生为什么要单独一步。块是独立重画的，编号却要看整篇。放进渲染，重画一块就要重算全篇；放进解析，又把显示决策混进了语法层。

两条派生规则。

- **锚点从原文算，不从显示文字算。** 标题的 `◆` 前缀是显示层的事。改前缀不能断掉别人收藏的 `#安装` 链接。
- **编号只在样式要求时算。** `numbering` 是 `none` 就不写 `number`，不做无用功。

### 2.5 八条不变量

每个新类型都必须同时满足这八条。少一条，这个类型就不该进注册表。

| 不变量 | 判据 |
| --- | --- |
| 一种语法 | 新效果只加名字，不加标点 |
| 一种子块 | 子块只由 `:accepts` 声明，没有子块自己的定义 |
| 一个内容模型 | 内容是节点，不是字符串，不是 HTML |
| 一个承载者 | 每个事实只有一处声明、一个读者 |
| 一套属性 | 属性名与类型来自共享词汇，类型只挑选，不发明同义词 |
| 一组布局 | 摆放只用 `box`、`columns` 与共享的间距属性 |
| 一条失败规则 | 坏块留源码加一行说明，页面继续渲染 |
| 一条定义边界 | 定义只做声明、校验、翻译；壳与交互归组件 |

### 2.6 三套词汇

词汇按说话的人分，不按包分。一个新名字必须能落进其中一套；落不进就不许加。

| 谁说话 | 用哪套名 | 例子 |
| --- | --- | --- |
| 写文档的人 | HTML 属性名，加主流组件库共用的 prop 名 | `title`、`href`、`selected`、`columns`、`padding` |
| 配外观的人 | CSS 属性名 | `background`、`color`、`font-weight`、`prefix`、`margin-top` |
| 写定义的人 | JSON Schema 的类型名，加本文的声明字段 | `string`、`length`、`:derived`、`:default` |

五条规矩。

1. **不缩写。** 写 `padding` 不写 `pad`，写 `columns` 不写 `cols`。只有 `id` 和 `href` 例外，它们是 HTML 的正式拼写。
2. **不编号。** 写 `surface-raised` 不写 `panel2`。
3. **一个词一个意思。** `number` 是章节号，`numbering` 是它的格式；`surface` 是面，样式键叫 `background`。
4. **值用标准词。** `decimal`、`lower-roman` 取自 CSS 的 `list-style-type`；`boolean` 取自 JSON Schema。
5. **先查再借。** 同一含义已有词就复用，没有就从权威里借，借不到才新造并写明理由。

## 3. 语法

### 3.1 开与关

````markdown
:::box {surface=raised}
图片和公式都按矢量画一次，之后按页面尺寸缩放。

- 命中时读文件
- 未命中时画一次
:::
````

| 规则 | 说明 |
| --- | --- |
| 名字 | 只收小写字母、数字、连字符，例如 `card`、`code-tabs` |
| 属性 | 花括号里的 `键=值`，空格分隔；没有属性时整对花括号省略 |
| 关闭 | 单独一行三个冒号，不写名字，关掉最近打开的那个 |
| 嵌套 | 直接套，内外都用三个冒号；层数不靠冒号个数区分 |
| 深度 | 最多 8 层。第 9 层报错，不渲染 |
| 空容器 | 允许。渲染成只有标题或一个空位，不算错误 |
| 开头 | `:::` 必须独占一行，前面只允许空白 |

关闭只有一种写法，所以只有一种读法：**关掉最近打开的那个**。不数冒号，不对名字，也就不会有对不上的时候。

嵌套不需要多加冒号，同名容器套同名容器也一样：

````markdown
:::card {title="外面"}
:::card {title="里面"}
内容
:::
:::
````

两个 `:::` 后进先出，先关里面再关外面。多写冒号、按名字匹配都会带来第二条规则，而第二条规则只会多一种写错的方式。

深度上限是 8，不是无限。每层都是一个盒子，窄窗口里读的人数不清自己站在第几层；每层还要一次测量和一次重排，深一层就多一层成本。上限把最坏情况钉住。

一个代价要说清：**没有内容的子块也要写关闭行。** 比如 `:::stat` 只带属性，就写成两行。这是为了让关闭只有一种规则；能省这一行的写法，就得让解析器认识名字，而它不认。

### 3.2 子块

子块的名字和写法都由父类型解释。父类型通过 `:accepts` 决定它收哪些子块、子块上哪些属性有效，通过 `:child-syntax` 声明子块怎么写。

````markdown
:::columns {columns="2fr 1fr" gap="2ch"}
:::col
左边这一栏是普通 Markdown。
:::
:::col
右边这一栏也是。
:::
:::
````

父类型必须能处理三种边缘情况，不允许崩溃或者画出半块。

- **没有子块**：画它自己的空状态，不报错。
- **子块顺序不对**：按出现顺序解释，不重排。
- **子块缺必填属性**：那一块降级，别的子块照常。

一个容器只用一种子块写法：

| `:child-syntax` | 写法 | 用于 |
| --- | --- | --- |
| `blocks`（默认） | `:::name` 一个子块一段 | 结构、集合、大部分交互容器 |
| `markers` | `@name 标题` 或 `@name {attrs}` 一行一个 | `tabs`、`code-tabs` |

`markers` 的作用域是声明它的容器自己的层级：

- 提示块、卡片里的 `@tab` 是普通文字；围栏里的 `@tab` 保持代码。
- 第一个标记之前不能有正文，否则页面报一行。
- 标记的正文里可以继续写 `:::` 容器；解析器把 `@` 展开成同样的子块，`:accepts` 与渲染不变。
- 一个容器只认一种写法：`tabs` 里写 `:::tab` 会报错，不会悄悄变成第二页。

### 3.3 属性

九种类型。属性只有两类，用一个标记分开。

| 类别 | 谁写 | 谁能改 | 怎么标 |
| --- | --- | --- | --- |
| 派生属性 | 解析器或派生阶段 | 谁都不能改，读者只能拿它当选择器 | 单独一张 `:derived` 表 |
| 普通属性 | 文档写在花括号里，省略就取 `:default` | 读者用 `set-attr` 盖掉 | 写在 `:attrs` 表 |

判断只需一句话：**这个值在 Markdown 文本里有没有写法。** 有，就写进 `:attrs`；没有，就写进 `:derived`。两张表并列，不混在一起。

| 类型 | 写法 | 值域 | 非法示例 |
| --- | --- | --- | --- |
| `string` | `title="缓存命中"` | 可选 `:pattern` 正则 | `title=缓存 命中` |
| `number` | `start=2` | 可选 `:min`、`:max`、`:integer` | `start=two` |
| `boolean` | `open=true` | 只认 `true` 和 `false` | `open=yes` |
| `length` | `gap="2ch"` | 单位 `ch`、`lh`、`%` | `gap=2` |
| `surface` | `surface=raised` | `none`、`page`、`raised`、`sunken`、`quote`、`table-header`、`table-stripe` | `surface="#24262a"` |
| `accent` | `accent=warning` | `neutral`、`primary`、`success`、`warning`、`danger`、`important` | `accent=urgent` |
| `align` | `text-align=center` | `start`、`center`、`end` | `text-align=middle` |
| `enum` | `list-style=decimal` | 声明里的 `:one-of`，必写 | `list-style=number` |
| `color` | `color=primary` | 令牌名；字面值只有读者规则能写 | `color=blue` |

三个语义类型的词表是包里的常量，见 4.1，声明里不必重复。某个类型只想收其中几个，就在声明里收窄：

```elisp
(accent :type accent :one-of (neutral warning) :doc "只收两种强调")
```

校验时值会换成渲染器要的形态，声明里不用自己解析单位。

| 类型 | 写作 | 校验后拿到的值 |
| --- | --- | --- |
| `string` | `title="缓存命中"` | 字符串 `"缓存命中"` |
| `number` | `start=2` | 数字 `2` |
| `boolean` | `selected=true` | `t` 或 `nil` |
| `length` | `padding="2ch"` | ETAF 的长度 `(ch 2)`，可直接放进属性 |
| `surface` | `surface=raised` | 符号 `raised` |
| `accent` | `accent=warning` | 符号 `warning` |
| `align` | `text-align=center` | 符号 `center` |
| `enum` | `list-style=decimal` | 符号 `decimal` |
| `color` | 只用令牌名 | 已经解析好的颜色 |

三条约定。

- **属性名共享。** `title` 在卡片、提示块、折叠里是同一个意思。类型只挑选词汇表里的名字，不发明 `heading`、`caption` 这类同义词。
- **一个名字一个类型。** `columns` 永远是栏数，不会是别的。
- **没有单位就没有长度。** `gap=2` 是错的，`gap="2ch"` 是对的。一个数字可能是字符、可能是行、可能是百分比，猜错一次就排错一次。

同一个属性写两次是错误，不取后者。重复通常意味着作者改了一半，静默取一个会把问题藏起来。

**派生属性由内置语法产生，一份都不能靠猜。** 附录 A.2 按类型列全，代码里那张表就是 `etaf-md-node-definitions`，取某个类型的派生属性用 `(etaf-md-derived-attributes TYPE)`，见 10.7。

共享属性表在附录 A，普通属性与派生属性各一张。声明里怎么写，见 10.2。

### 3.4 校验、降级与失败目录

校验在搭视图之前一次做完，把这一块的所有错误一起报。报错是一条灰字，写在源码块上方，行号是容器开头那一行。

````markdown
:::card {title="" colour=blue accent=urgent}
内容
:::
````

```
line 42: card 不收 "colour"，它收 title、accent
line 42: title 不能是空白
line 42: card 的 accent 是 "urgent"，它收 neutral、primary、success、warning、danger、important
line 44: 第 9 层嵌套超过上限 8 层
```

失败分二十一种。每一种都有确定的页面表现，不允许「看情况」。

| 情况 | 页面表现 | 影响范围 |
| --- | --- | --- |
| 名字没有定义 | 源码原样加一行说明 | 这一块 |
| 属性不认识 | 源码原样，说明列出它收的属性 | 这一块 |
| 属性值不在值域 | 源码原样，说明给出值域 | 这一块 |
| 必填属性缺失 | 源码原样，说明点名缺哪个 | 这一块 |
| 属性写了两遍 | 源码原样，说明点名重复的那个 | 这一块 |
| 派生属性被文档写 | 源码原样，说明它没有文本写法，由解析或派生填 | 这一块 |
| 父类型没有子块 | 画空状态，不报错 | 这一块 |
| 子块属性不认识或不合法 | 这一项降级，别的项照常 | 这一项 |
| 两个子块都声明 selected | 只认第一项，报一行 | 这一组 |
| 嵌套超过 8 层 | 源码原样，说明层数 | 这一块 |
| 该关的没关 | 内容照常渲染，报在第一个没关的容器开头 | 从那一行起 |
| 子块出现在父类型外 | 源码原样，说明哪个 `:accepts` 收它 | 这一块 |
| 容器出现在不允许的位置 | 源码原样，说明只允许顶层与容器内容 | 这一块 |
| 定义自己报错 | 源码原样，说明是哪个定义、报了什么 | 这一块 |
| 契约版本不符 | 源码原样，说明要哪个版本 | 这一块 |
| 样式规则的选择器引用了没声明的属性 | 这条规则整条忽略，报一行 | 整篇 |
| 样式规则的键是一个派生属性 | 这个键忽略，报一行，说明只能当选择器 | 整篇 |
| `target` 指不到块 | 选择器照常可点，报一行 | 这个选择器 |
| 两个选择器指向同一个区域 | 后出现的生效，报一行 | 这个区域 |
| 子块的 key 重复 | 取第一个，报一行 | 这一组 |
| 选中的 key 没有对应内容 | 区域显示 `empty`，没写就留空，报一行 | 这个区域 |

四条通则。

1. **不弹窗。** 报错是页面的一部分，不是 Emacs 的错误。一份有十处错的文件，弹十次窗就没法读了。
2. **不中断整页。** 只有出错的那一块降级，别的照常渲染；样式规则出错只忽略那一条。
3. **一行一条。** 同一块的多条错误各占一行，按属性在声明里出现的顺序排。
4. **文案从声明生成。** 收了哪些属性、值域是什么，都读声明，不手写。

错误文案跟着页面语言走。中文页面给中文，英文页面给英文，标签机制和提示块的标题共用一套。

### 3.5 未闭合与恢复

一个容器到文件末尾还没关，就当作它在那儿关了：内容照常渲染，页面末尾加一行说明，指出从第几行开始没关。

````markdown
:::card {title="少了一个关闭行"}
这段仍然是正文。

## 后面的标题照常成立
````

这个选择偏向读者。把整块判成源码会让人以为预览坏了；吞掉半篇文档比多一行字糟得多，而且作者改起来也更难发现。

### 3.6 代码块

围栏的 info 里能写四类选项，写在语言名后面，顺序不限。

| 写法 | 作用 |
| --- | --- |
| `title="x"` | 代码块顶部写标题，不写就用语言名 |
| `:line-numbers`、`:line-numbers=3`、`:no-line-numbers` | 开行号，或从 3 起编号；不写不开 |
| `{1,4-7}` | 这些行刷一层强调底色 |
| 行尾 `[!code highlight]`、`[!code focus]`、`[!code ++]`、`[!code --]`、`[!code warning]`、`[!code error]` | 标记这一行是高亮、聚焦、新增、删除、警告还是错误 |

````markdown
```elisp title="lisp/etaf-md-env.el" :line-numbers
(defun etaf-md--muted (env)
  (or (etaf-md--palette-value (etaf-md-env-palette env) :muted)
      "#9198a1"))
```

```elisp
(defun etaf-md--toggle-line (env block line)
  (let ((open (etaf-md-block-state env :open)))        ; [!code --]
    (etaf-md-set-block-state env :open (not open))))   ; [!code ++]
```
````

标记只决定画法，画出来的代码里没有它。聚焦块里没被聚焦的行会退到背景色里；底色的墨色按当前底色重新算过，浅色与深色主题下都读得清。标题行右侧的「复制」把去掉标记的代码放进 kill ring。

代码块由 `etaf-ui` 的 Markdown 渲染器画，页面主题只决定调色板。

### 3.7 源码 buffer 的编辑体验

渲染出来的页面没有标记，所以标记的代价全落在写的人身上。这一节说的东西全部发生在源码 buffer，不改语法，也不改渲染结果。

四层，按收益排。四层合成一个可选 minor mode，名字是 `etaf-md-edit-mode`，默认关。

| 层 | 做什么 | 解决什么 |
| --- | --- | --- |
| 一 | 标记降权：`:::`、花括号、等号用 `markdown-markup-face`；容器名用语言关键字色；属性名与属性值各一色 | 竖线不再和正文抢眼 |
| 二 | 配对提示：光标在容器里时，把它的开行与关行各提亮一档，离开即恢复 | 不用自己数哪个冒号配哪个 |
| 三 | 插入与补全：一条命令补出开行、空行、关行；容器名与它收的属性就地补全 | 名字和属性不用背 |
| 四 | 折叠：只留容器的开行 | 长文档里先看结构 |

四条硬约束，每一条都是「不破坏原有 Markdown 体验」的判据。

1. **只加不改。** 新增的 font-lock 规则只匹配 `^:::` 与属性花括号，这两处在 markdown-mode 今天没有任何规则，不存在覆盖。不动它的键位表、缩进函数、`electric-pair`、`markdown-hide-markup`。
2. **不改 buffer 内容。** 降权、提亮、折叠全部是 face、overlay 与 `invisible` 属性，`buffer-string` 前后相同。否则保存就会改文件。
3. **关掉即复原。** 关闭时移除 font-lock 关键字、删 overlay、清 hook、摘掉自己的 `completion-at-point-functions`。测试断言开启再关闭之后，`font-lock-keywords` 与开启前 `equal`。
4. **不抢键。** 只用自己前缀的键，不 remap 任何既有命令。

性能预算，和 8.3 一样可以量。

| 动作 | 预算 | 靠什么保证 |
| --- | --- | --- |
| 打开一份 2000 行的文档 | 额外耗时 50 毫秒以内 | font-lock 按块惰性走，没有整篇扫描 |
| 光标跨行 | 5 毫秒以内 | 只在行号变化时算一次 |
| 同一行内打字 | 0 次配对计算 | 上一条的直接结果 |
| 空闲 | 0 个定时器 | 没有轮询，没有后台刷新 |
| 折叠与展开 | 一次 overlay 增删 | 不动文字 |

配对提示要找到容器开头，所以它按行数给上限。一份几千行的文档里反查一次，超过上限就跳过这一屏的提示，不做无上限的反向扫描。

它救不了的三处，写在这里免得以后当承诺：GitHub 上、别人的编辑器里、复制出去的一段文字里，都没有这些标记。所以语法必须能在裸文本里读得下去，这一节只是加成。加语法时不拿它当理由。

## 4. 外观与样式

### 4.1 底色与强调

文档写得进的外观属性只有两个：`surface` 管底色，`accent` 管强调色。两套词分开，因为它们是两件事。两个属性的值和令牌一一对应，没有例外，见附录 B。

| `surface` | 落到哪个令牌 | 用在哪 |
| --- | --- | --- |
| `none` | 不画底 | 默认。正文里的卡片、并排的块 |
| `page` | `background` | 需要和正文拉开的地方 |
| `raised` | `surface-raised` | 代码块、卡片面板 |
| `sunken` | `surface-sunken` | 表头、条纹、次要信息 |
| `quote` | `quote` | 引用性质的块 |

| `accent` | 前景 | 浅底 | 语义 |
| --- | --- | --- | --- |
| `neutral` | `foreground` | `surface-raised` | 没有强调 |
| `primary` | `primary` | `primary-soft` | 说明、提示、链接 |
| `success` | `success` | `success-soft` | 成功、建议 |
| `warning` | `warning` | `warning-soft` | 注意 |
| `danger` | `danger` | `danger-soft` | 危险 |
| `important` | `important` | `important-soft` | 重要 |

一个强调值只决定强调色和浅底，不改字号、不改字重、不改行高。要更醒目就换一个强调值，不要叠效果。

### 4.2 令牌

令牌是渲染器内部的名词。文档里写 `surface=raised`，不写 `surface-raised` 令牌，更不写色值。名字取 shadcn/ui 那一套，因为它是现在最通行的语义令牌。

| 令牌 | 用途 |
| --- | --- |
| `background` | 页面底色 |
| `foreground` | 正文 |
| `muted` | 次要文字、说明 |
| `faint` | 最弱的一层，序号、分隔 |
| `border` | 边框、分隔线 |
| `surface-raised` | 抬起的面：卡片、代码块 |
| `surface-sunken` | 下沉的面：表头、条纹 |
| `quote` | 引用块底 |
| `quote-bar` | 引用块左侧竖条 |
| `table-header` | 表格头 |
| `table-stripe` | 表格条纹 |
| `heading` | 标题 |
| `primary` / `primary-soft` | 信息类 |
| `success` / `success-soft` | 成功 |
| `warning` / `warning-soft` | 注意 |
| `danger` / `danger-soft` | 危险 |
| `important` / `important-soft` | 重要 |

令牌在三种配色下各有一套值，跟随 Emacs 主题时由当前 frame 的 face 推出来。容器只声明底色与强调，配色换了它跟着换。

**为什么不收十六进制。** 一个在暗色页上好看的 `#24262a`，换到纸色页就是一块黑斑。写十六进制会报错，报错行里列出这个属性认的语义词。

### 4.3 样式规则

样式规则是读者改外观的地方。它是一串规则，每条以选择器开头，后面是键值。键就是该类型声明过的属性名。

```elisp
(setq etaf-md-styles
      '(((heading)          (:font-weight bold) (:color heading) (:numbering decimal))
        ((heading :level 1) (:prefix "◆ "))
        ((heading :level 2) (:prefix "◇ "))
        ((quote)            (:background quote) (:border-left-width "1ch"))
        ((code)             (:background surface-raised) (:label-color muted))
        ((link)             (:color primary) (:text-decoration underline))))
```

选择器永远是列表，两种形态：`(类型)` 选中该类型的全部节点，`(类型 :属性 值 …)` 再加条件。没有第三种写法，也没有省略形态。

匹配规则三条。

1. 类型相同，并且选择器里列的每个属性都等于节点的同名属性，这条规则才命中。
2. 命中的规则按表的顺序叠加，同一个键后面的赢。
3. 一条都不命中的键，取节点的属性值；属性也没有，取声明里的 `:default`。

`## 依赖` 的 `level` 是 2，命中第一条与第三条，于是 `font-weight`、`color`、`numbering`、`prefix` 都有着落，第二条完全不参与。

读者改外观就写一条同形的规则：

```elisp
(etaf-md-set-attr '(heading :level 2) '((:prefix "## ")))
```

写法与内置规则完全一样，读者不用学第二套。

键的合法性由声明决定。

| 能写什么键 | 依据 |
| --- | --- |
| 该类型的普通属性 | `title`、`accent`、`prefix`、`color`、`font-weight`、`numbering` |
| 派生属性 | 不能当键，只能当选择器；写错报一行并列出可用的键 |

三个值的特殊写法。

- **省略是继承，`nil` 是关闭，`:default` 是回落内置。** `(:prefix nil)` 去掉前缀；把 `:prefix` 删掉就是从别处继承；`:color :default` 回到内置值。
- **`:numbering` 由派生阶段读。** 它决定要不要写 `number`，不参与画法。
- **内置规则也写在这张表里。** 代码里没有字面颜色值，所以你改的和你看的是同一套东西。

改了表要重画整页并重新派生，但不重新解析，见 8.2。

### 4.4 两套颜色权限

| 谁 | 能写什么 | 为什么 |
| --- | --- | --- |
| 文档 | 语义词与令牌名，例如 `surface=raised`、`accent=warning`、`color=heading` | 文档要能在任何主题、任何机器上读 |
| 读者样式 | 令牌名，或字面值 `"#ff0000"` | 读者拥有自己的页面 |

写字面值有一个代价：它不跟随主题切换。暗色页上选的蓝，换到纸色页可能读不清。所以文档里永远不写字面值，这条是硬规矩。

普通属性的文档值是默认值，读者的一条规则可以盖掉它。派生属性只认解析器与派生阶段，读者拿它当键会直接报错。

令牌名只出现在样式规则里，不进画法。画法读到的永远是解析好的色值，所以换主题不需要改任何声明。

### 4.5 字号与度量

文档里没有字号属性，也没有等价的写法。容器和正文永远同一个字号。

读者样式规则里也没有缩放键。字号只由用户的默认字体决定，容器、标题、表格一律继承，谁也不比谁大一号。

层级靠字重、颜色、前缀、一条线、一块底色表达，不靠大小。块流按每块的实际高度排，不假设一行。

两个反例。一个 `size=large` 的卡片，在 12 号字的机器上占 3 行，在 20 号字的机器上占 5 行，同一份文档在两台机器上版面完全不同。一个缩到 80% 的表格，在窄窗口里字比正文小一号，读者会以为自己放大了页面。

### 4.6 装饰字符

装饰只用 ASCII 和框线字符，不用 emoji，不用变体选择符。

允许的集合是 `-`、`=`、`|`、`+`、`*`、`` ` ``、`.`、`o`，加上 `─│┌┐└┘├┤┬┴┼`。

理由：这个集合在等宽字体里都占一格。emoji 的宽度由字体决定，可能一格、可能两格，还会因为缺字变成方块；变体选择符（U+FE0E）在有些字体上会把整行撑高，底部一行被裁掉。

框线字符只在画树和表格时用，不用来画卡片边框。卡片边框由渲染器画，属性里没有「边框字符」这一项。

## 5. 布局

### 5.1 一个结构容器

多栏只有一种写法，`columns`。原来分开的 `layout`、`flex`、`card-grid` 合并成它一个，因为它们的差别只是默认值；Plume 文档里的 `::: flex` 与 `::: card-grid` 对应这里的等宽/轨道写法，`card-grid` 就是 `columns` 里放卡片。`columns` 一个属性收两种形态：给一个数字就是等宽几栏，给一串轨道就是按比例分。

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `columns` | number 或 string | 无 | 数字表示等宽几栏；字符串是一串轨道，空格分隔，单位 `fr`、`ch`、`%` |
| `justify-content` | enum | `start` | `start`、`center`、`end`、`between`、`around`：多栏整体在主轴上的位置 |
| `gap` | length | `"2ch"` | 栏间距 |
| `padding` | length | 无 | 左右内边距，上下由画法固定 |
| `min-width` | length | `"24ch"` | 每栏最小宽度，放不下就叠成一栏 |
| `align-items` | enum | `stretch` | 子块在交叉轴的对齐：`start`、`center`、`end`、`stretch` |
| `justify-content` | enum | `start` | 主轴：`start`、`center`、`end`、`between`、`around` |
| `wrap` | boolean | `false` | 放不下时换行，不叠栏 |
| `divider` | boolean | `true` | 栏与栏之间画一条一像素竖线；卡片网格关掉 |
| `align-self` | enum | `start` | 容器自身在父级里的水平位置：`start`、`center`、`end` |

子块是 `col`，收一个属性。

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `grow` | number | `1` | 分到剩余宽度的份数 |

````markdown
:::columns {columns="2fr 1fr" gap="2ch"}
:::col
## 一次命中

缓存里只有一张图，命中时页面从磁盘读它，不再启动渲染器。
:::
:::col
旁边的说明写成普通段落就行，宽度由栏决定。
:::
:::
````

三张卡片并排，就是 `columns` 的三个 `col` 各放一张 `card`；`col` 是 `columns` 声明的子块，卡片是它的内容。

````markdown
:::columns {columns=3}
:::col
:::card {title="解析"}
文本到语义树。
:::
:::
:::col
:::card {title="排版"}
语义树到视图。
:::
:::
:::col
:::card {title="发布"}
视图到 buffer。
:::
:::
:::
````

### 5.2 轨道、间距、内边距

- `columns=3` 就是三条 `1fr`。
- `columns="2fr 1fr"` 是显式轨道，按 Ebox 的写法：`(fr 2)` 写成 `2fr`，固定宽写 `20ch`，百分比写 `30%`。
- `gap` 只加在块与块之间，不加在外面。外面那一圈归 `padding`。
- `padding` 只收一个长度，四个方向同值。不做 `padding-x`、`padding-y`，两个轴分开给会让同一页出现两种内边距。
- 垂直间距用 `lh` 的整数倍。用像素会让行距和行高对不上，边框压在字上。

### 5.3 窄窗降级

放不下并排的栏时，按顺序降级，不做横向滚动。

1. **减栏。** `columns=3` 先降到 2，再降到 1，每栏不小于 `min-width`。
2. **叠栏。** 用了轨道的，每栏小于 `min-width` 时整块叠成一栏，栏与栏之间留一个空行。
3. **收边距。** `padding` 从 2ch 收到 1ch，`gap` 从 2ch 收到 1ch，外框保留。
4. **保持字号。** 无论降到哪一档，字号不变，行高不变。

`wrap=true` 时先换行，换到一行只剩一栏还放不下，才叠。

### 5.4 三个结构容器怎么选

只有三个，判据是内容关系。

| 想要什么 | 用哪个 | 理由 |
| --- | --- | --- |
| 并排 | `columns` | 唯一的多栏机制 |
| 一块有标题、有边界的材料 | `card` | 标题比正文重，比节标题轻 |
| 一块没有标题、只要底色或内边距 | `box` | 卡片的最简形式，不画标题行 |

**不该用的地方。** 两段并列的正文不要用 `columns` 硬凑成表格；表格用表格。三行两列的键值不要用 `card`，那是 `field`。

## 6. 容器目录

### 6.1 家族总览

| 家族 | 容器 | 共同点 |
| --- | --- | --- |
| 结构 | `columns`、`card`、`box` | 只决定摆放和边界，不解释内容 |
| 提示 | `note`、`tip`、`important`、`warning`、`caution` | 五条定义共用一份画法，强调值固定 |
| 集合 | `steps`、`timeline`、`stats`、`field`、`file-tree`、`chat` | 子块带标签，按顺序或按名字排 |
| 交互 | `tabs`、`code-tabs`、`accordion`（子块 `collapse`） | 有状态，可按键切换 |
| 文稿 | `table`、`window` | 包住别的东西，换一种呈现 |

### 6.2 提示块

已实现的是 GitHub 写法，标记放在引用块第一行。

```markdown
> [!WARNING]
> 这段只在 Emacs 30 及以上可用。
```

容器写法已实现：七个名字共用一套属性和一份画法，`details` 是同一族里的单块折叠，见 6.13。

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 该强调值的固定标题 | 换掉标题文字 |
| `collapsible` | boolean | `false` | 允许收起 |
| `open` | boolean | `true` | 收起时默认展开 |
| `background` | surface | `quote` | 底色，见 4.1 |
| `border-left-width` | length | `1ch` | 左侧竖条宽度 |

```markdown
:::warning {title="兼容性" collapsible=true}
这段只在 Emacs 30 及以上可用。
:::
```

两个写法渲染成同一个东西，画法只有一份。名字到强调值的映射是固定的：`note` 与 `info` 对 `primary`，`tip` 对 `success`，`important` 对 `important`，`warning` 对 `warning`，`caution` 与 `danger` 对 `danger`。固定标题分别是 Note、Info、Tip、Important、Warning、Caution、Danger。

为什么两条路都留。GitHub 上的文档粘贴过来就能用，这是最常见的入口；写长文档时容器写法能和别的容器对齐，也能带属性。

### 6.3 卡片

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 无 | 标题，省略就不画标题行 |
| `icon` | string | 无 | 标题前的图标名，取自图标集 |
| `description` | string | 无 | 标题下一行灰色摘要 |
| `accent` | accent | `neutral` | 见 4.1 |
| `href` | string | 无 | 整张卡片可点，跳到这个地址 |
| `text-align` | align | `start` | 内容水平位置 |
| `width` | length | 省略即占满 | 自身宽度，省略时撑满父级 |

解决的场景：一组并列材料需要一个共同边界。用标题分节会把材料抬到节标题同级，用列表会把图压成一项。

组件：`etaf-card`，默认槽接正文，`title` 和 `description` 直接对应。卡片底色就是组件的面板色，所以 `card` 不再声明 `surface`。

### 6.4 盒子

四个对齐容器：`:::left`、`:::center`、`:::right`、`:::justify`。它们只做一件事，把整段正文按名字对齐；正文里照常写块。

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `surface` | surface | `none` | 见 4.1 |
| `accent` | accent | `neutral` | 见 4.1 |
| `padding` | length | 无 | 内边距 |
| `text-align` | align | `start` | 内容水平位置 |
| `width` | length | 省略即占满 | 自身宽度，省略时撑满父级 |

盒子是卡片的无标题形式。居中一张图就是它。

```markdown
:::box {text-align=center padding="1lh"}
![示意图](figures/hit.png)
:::
```

### 6.5 步骤

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `start` | number | `1` | 起始编号 |
| `list-style` | enum | `decimal` | `decimal` 用数字，`bullet` 用圆点 |

子块是 `step`，属性 `title` 必填。也可以直接写一个有序列表，列表的每一项就是一步，标题取项的文字。

````markdown
:::steps
:::step {title="定位"}
用 `sample` 抓栈，别先猜。
:::
:::step {title="改因"}
改产生现象的那一层，不改它的结果。
:::
:::
````

````markdown
:::steps
1. 定位：先用 `sample` 抓栈
2. 改因：改产生现象的那一层
3. 复验：同一个输入再跑一遍
:::
````

列表写法只带标题，每步的正文用 `step` 子块写。

解决的场景：操作手册里读者要看得出有几步、站在第几步。用有序列表也能写，但编号和标题挤在一行，长标题折行后编号落单。

组件：`etaf-steps`。

### 6.6 时间线

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `list-style` | enum | `bullet` | `bullet`、`decimal`、`none` |
| `start` | number | `1` | 第一项的序号 |

子块是 `event`，属性 `title` 必填；`time` 写时间，`status` 取 `success`、`warning`、`danger` 或 `info`，圆点按它上色并画一个徽标。

````markdown
:::timeline
:::event {time="2026-11-12" title="定位到慢在画图"}
`image-size` 会真的把图画出来。
:::
:::event {time="2026-11-13" title="改成读文件头" status="success"}
打开从 5.4 秒降到 0.33 秒。
:::
:::
````

解决的场景：版本记录、事故经过。用列表会丢掉「时间在上、内容在下」的对齐。

组件：`etaf-timeline`。

### 6.7 字段

同一个容器有两种写法：一个参数一张卡，或者一张名称与值的字段表。

**参数卡**（Plume `::: field` 的写法）：用属性描述这个参数，正文是说明。

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `name` | string | 无 | 参数名；写了就用参数卡的样子 |
| `type` | string | 无 | 类型注解 |
| `type-link` | string | 无 | 类型的链接地址，写了类型可以点 |
| `default` | string | 无 | 默认值 |
| `required` | boolean | `false` | 必填，名字后面画一个「必填」徽标 |
| `deprecated` | string | 无 | 弃用说明，画「已弃用 <说明>」 |
| `experimental` | string | 无 | 实验性说明，画「实验性 <说明>」 |
| `enum` | string | 无 | 可选值，用 `\|` 或逗号分隔 |
| `unit` | string | 无 | 单位 |
| `format` | string | 无 | 格式 |
| `constraint` | string | 无 | 约束 |
| `since` | string | 无 | 引入版本 |

名字一行，状态徽标跟在后面；类型、默认值、引入版本排成第二行；可选值、单位、格式、约束合并成末尾一行；正文照常写块。

```markdown
:::field {name="width" type="number" default="46" unit="列"
          required=true since="0.1"
          enum="8 | 16 | 46" constraint="8 ≤ width ≤ 120"}
图片卡的最大列数，超出页面宽度时自动收窄。
:::
```

Plume 把 `@type`、`@default` 这些 JSDoc 标签写在正文里；这里改成容器属性，值里不要带引号（默认值是空字符串就写 `default="空字符串"`）。

**字段表**：不写 `name`，正文是一个列表，每项第一个冒号前是名称。属性是 `label-width` 与 `separator`。

```markdown
:::field
- 版本：12.3.0
- 渲染器：Chromium，常驻
- 缓存：`~/.cache/etaf-md/typeset`
:::
```

解决的场景：参数说明、环境信息。两列表格要写表头和对齐行，太重。

### 6.8 数字组

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `columns` | number | `3` | 一行放几个，窄窗减少 |

子块是 `stat`，属性 `title` 必填（说明文字），`value` 必填（数字文本）。子块没有内容，也要写关闭行。

````markdown
:::stats
:::stat {title="打开" value="0.33 s"}
:::
:::stat {title="缩放" value="0.18 s"}
:::
:::stat {title="内存" value="349 MB"}
:::
:::
````

数字用 `foreground` 加粗，说明用 `muted`。超过一行换行，不缩字号。组件：`etaf-statistic`。

### 6.9 文件树

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 无 | 树上方一行标题 |
| `lines` | boolean | `true` | 画不画树线。关掉只留缩进 |

内容是缩进列表，一层一个 `-`。

```markdown
:::file-tree {title="lisp/"}
- lisp/
  - etaf-md-model.el
  - etaf-md-views.el
- etaf-md.el
:::
```

解决的场景：讲清一个目录里有什么。围栏代码也能写，但树线要和缩进对齐，手写容易错一格。记号只用 4.6 允许的字符。

名字后写 `# 注释`，注释用灰字跟在名字后面；`++ 名字` 标成新增、`-- 名字` 标成删除，分别画成绿字和红字；名字两边写 `**` 的一行加粗，用来点出要读者先看的那一项。`icon` 只接受 plume 传来的值，文字页面里不画文件图标。

组件：页面自己画树线，一行一项，不挂交互。



### 6.10 对话

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 无 | 对话上方的标题 |

对话内容用标记行分组，照 plume 的写法：`{发送者}` 开始一条消息，`{.}` 是自己说的，`{:时间}` 换一个时间。标记后面的块属于这条消息，可以写多段、列表或代码。

````markdown
:::chat {title="预览为什么还不刷新"}
{:2026-11-14 14:20}

{问}
预览为什么不刷新？

{.}
保存之后才刷新，改到一半不重排。
:::
````

自己说的话靠右，别人的靠左；时间单独占一行。解决的场景：把一段对话原样放进文档，不用截图。

组件：`etaf-chat`（组件目录里没有时就地画）。

### 6.11 标签页

子块是 `tab`，用 `@tab` 一行一个。`title` 必填，也可以直接把标题写在标记后面；`selected` 可选（布尔，一组里只能一项写）。

````markdown
:::tabs
@tab Emacs 29
用 `image-size` 的旧签名。
@tab {title="Emacs 30+" selected=true}
直接传 buffer。
:::
````

`@tab 标题` 是 `@tab {title="标题"}` 的简写；带别的属性时写花括号。`tabs` 只认这一种写法，`:::tab` 会报错，见 3.2。

键盘：`TAB` 进入标签条并停在选中项，左右移动焦点，`RET` 打开。到两端时按键被吃掉，不响铃也不循环。

两处都写 `selected` 时只认第一项，页面报一行，见 3.4。

解决的场景：同一件事的几种写法并行，读者只需要一种。三个并列小节会让目录变长，标签页只占一块位置。

交互按第 7 章的契约，不单独定规则。组件是 `etaf-tabs`，受控，状态由块提供。

### 6.12 代码标签页

子块也是 `tab`，也用 `@tab` 一行一个；`title` 可省，省略时用围栏的语言名。所以 `code-tabs` 有自己的 `:accepts`，不是照抄 `tabs`。

````markdown
:::code-tabs
@tab
```elisp
(etaf-md-open)
```
@tab
```python
print("hi")
```
:::
````

它不是新语义。画法与 `tabs` 走同一条路径，声明不同：`tab` 的 `title` 在这里可省，省略时取第一段围栏的语言名。

### 6.13 折叠

子块是 `collapse`，放在 `:::accordion` 里，同时只开一块。只有一项时就是普通的一折。

子块的属性：`title` 必填（收起时的标题），`open` 可选（布尔，默认 `false`），`index` 可选（显示顺序，省略按书写顺序）。

组本身的属性：`expand` 可选（布尔，默认 `false`，打开时所有块都展开），`accordion` 可选（布尔，默认 `true`，同时只开一块；写成 `false` 可以开多块）。

`:::details` 是同一族里的单块折叠，默认收起，属性是 `title` 与 `open`。

````markdown
:::accordion
:::collapse {title="完整的报错"}
```
后面的长文本放这里。
```
:::
:::collapse {title="版本差异"}
:::
:::
````

只要一折时写一项：

````markdown
:::accordion
:::collapse {title="完整的报错" open=true}
```
长文本。
```
:::
:::
````

解决的场景：长推导、长日志、完整报错。留在页面上备查，但不挡路。

组件：`etaf-accordion`，受控，`open` 与 `multiple` 由块提供；`multiple` 默认 `false`，所以同时只开一块。

### 6.14 表格

普通管道表格已经能用。这个容器管表格的**呈现**，不管表格本身：它给一行标题，标出要看的行、列与单元格，还能整表对齐，以及把整表复制成制表符分隔的文本。边框贴着表格本身，标题与复制行留在框外。不带它，表格照常渲染，只是没有标题和强调。

只有标题一个职责时，名字该是标题相关的词。它现在还管高亮，将来表格的对齐、脚注也归它，职责比一个标题大，所以名字停在 `table`。

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 无 | 表格上方一行标题 |
| `highlight-rows` | string | 无 | 高亮的行号，空格分隔，例如 `2 3` |
| `highlight-columns` | string | 无 | 高亮的列号，空格分隔，例如 `1` |
| `highlight-cells` | string | 无 | 高亮的单元格，写成 `行:列`，空格分隔，例如 `2:3 3:1` |
| `align` | enum | 继承 `text-align` | 整张表的对齐：`left`、`center`、`right`，盖过单元格自己的对齐 |
| `copy` | boolean | `false` | 标题下画一行「复制表格」，激活后把整张表按制表符分隔复制走 |
| `highlight` | accent | `warning` | 高亮用哪个强调值 |
| `background` | surface | `page` | 表格底色 |
| `color` | color | `foreground` | 表格文字色 |
| `header-background` | surface | `table-header` | 表头底 |
| `stripe-background` | surface | `table-stripe` | 条纹底 |
| `text-align` | align | `start` | 单元格文字位置 |
| `margin-top` | length | `0` | 与上一块的距离 |
| `margin-bottom` | length | `0` | 与下一块的距离 |
| `numbering` | enum | `decimal` | 表格编号的格式，派生阶段读 |

```markdown
:::table {title="打开耗时" highlight-rows="3" highlight=warning}
| 版本 | 耗时 |
| --- | --- |
| 0.1.9 | 5.4 s |
| 0.2.0 | 0.33 s |
:::
```

理由：表格最常见的两个需求是给个标题、标出要注意的那一行。为这两件事写一段说明，不如挂两个属性。

### 6.15 演示窗口

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 无 | 标题栏文字 |
| `height` | length | 省略即由内容决定 | 内容区高度 |
| `gap` | length | 省略即不留 | 标题栏与内容之间的空行 |
| `no-padding` | boolean | `false` | 内容区不留内边距 |

```markdown
:::window {title="etaf-md-preview"}
一段界面截图或者一段文字。
:::
```

从 plume 的 `window` 变形而来。它画圆角和阴影，我们只画一条标题栏。圆角在字符网格里画不出来，硬画就是一排乱字符。

### 6.16 窗格容器

三个容器把线画在单元格的边上，不占额外的一行：面板的标题写在顶边上，标签页坐在面板的顶边里，表单行只用一条线托住值。

#### 面板 panel

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `title` | string | 无 | 顶边上的标题 |
| `status` | string | 无 | 顶边右端的说明 |
| `variant` | enum | `default` | `flat` 只留线，不铺底色 |
| `focus` | boolean | `false` | 用强调色画整圈线 |
| `accent` | accent | `neutral` | 框线与标题的颜色；`neutral` 用页面描边色 |
| `width` | length | 铺满一行 | 面板宽度 |
| `margin-top` | length | `1lh` | 与上一块的距离 |

```markdown
:::panel {title="读取设置" status="12.3.0" accent=primary}
面板把标题与状态画在顶边上，正文从下一行开始。
:::
```

解决的场景：一页里并排几块内容，每块要说出自己是什么，又不肯为标题花一整行。

组件：`etaf-edge-panel`。

#### 标签页 tab-panel

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `accent` | accent | `neutral` | 框线与选中标签的颜色 |
| `width` | length | 铺满一行 | 面板宽度 |
| `margin-top` | length | `1lh` | 与上一块的距离 |

子块是 `tab`，属性 `title`（必填）与 `selected`（打开时选中这一页）。

```markdown
:::tab-panel {accent=primary}
@tab notes.md
第一页的正文。
@tab {title="todo.md" selected=true}
第二页的正文。
:::
```

标签与正文在同一个框里：标签那一行就是顶边，选中的一页用强调色填满，换页只换正文。和 6.11 的 `tabs` 区别在这里：`tabs` 是独立的一条标签条，`tab-panel` 的标签长在面板边上。

组件：`etaf-edge-tabs`。

#### 表单 form

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `width` | length | 铺满一行 | 表单宽度 |

正文是一个列表，每项写 `名称：值`；名称在上、值在下，值下面一条线。

```markdown
:::form
- 仓库地址：github.com/emacs-taf
- 渲染器：Ebox
:::
```

解决的场景：设置项、环境信息这类一列名称一列值的内容，不需要表格的表头与对齐行。

组件：`etaf-underline-field`。

### 6.17 状态总表

| 容器 / 语法 | 家族 | 实现层 | 状态 |
| --- | --- | --- | --- |
| GitHub / Obsidian 提示块 `> [!NOTE]`（支持 `+/-` 折叠与自定义标题） | 提示 | 原语 | 已实现 |
| `note`、`info`、`tip`、`important`、`warning`、`caution`、`danger` | 提示 | 原语 | 已实现 |
| `box`、`card`、`columns` + `col`、`details`、`left`/`center`/`right`/`justify` | 结构 | 原语 / `etaf-card` / `etaf-accordion` | 已实现 |
| `steps` + `step`、`timeline` + `event`（支持 `orientation=horizontal` 与 `card`） | 集合 | `etaf-steps` / `etaf-timeline` | 已实现 |
| `stats` + `stat`（支持 `trend`、`accent`、`spark`） | 集合 | `etaf-statistic` | 已实现 |
| `field`、`file-tree`（支持 `lines`/`collapsible`/`clickable`）、`chat` | 集合 | 原语 | 已实现 |
| `tabs` + `tab`、`code-tabs` + `tab`、`accordion` + `collapse`、`swiper` | 交互 | `etaf-tabs` / `etaf-accordion` | 已实现 |
| `table`（支持 `align` 整表对齐、`sortable` 列排序与复制）、`window` | 文稿 | 原语 / `etaf-window-chrome` | 已实现 |
| `panel`、`tab-panel` + `tab`、`form`、`log`、`statusbar` | 窗格 | `etaf-edge-panel` / `etaf-edge-tabs` / `etaf-underline-field` / `etaf-log` / `etaf-status-bar` | 已实现 |
| `chart`（`line` 盲文折线、`bar` 条形、`stacked` 占比、`heatmap` 热力） | 可视化 | `etaf-braille-chart` / 原语 | 已实现 |
| `progress`、`keymap`、`breadcrumb` | 轻量结构 | 原语 | 已实现 |
| `diff`（`@before`/`@after` 配对对齐）、`pros-cons`（`@pro`/`@con` 无外框等高）、`demo` | 对比与实时演示 | 原语 | 已实现 |
| `home-box`、`image-card`、`link-card`、`npm-badge`、`qrcode`、`code-tree`、`npm-to` | 站点与展示 | 原语 / `etaf-badge` / `etaf-qr` | 已实现 |
| `include`、`code-ref`、`symbol`、`project-tree`、`git-log`、`git-diff` | Emacs 原生活文档（L1 只读） | 沙箱资产层（`:asset-data`） | 已实现 |
| `run` | Emacs 原生活文档（L2 显式触发） | 受控动作层（`etaf-md-allow-actions`） | 已实现 |
| 行内轻语义：`!!遮罩!!`、`[+注释]`、`[[双链]]`、`%%注释%%`、`:color[...]`、`:sym[...]` | 行内扩展 | `etaf-ui-markdown` | 已实现 |
| 代码块增强：`:collapsed-lines[=N]`、`/word/`、`[!code word:...]`、`:whitespace`、`:indent-guides` | 代码围栏 | `etaf-ui-markdown` | 已实现 |
| 交互式 GFM 任务复选框（写回源文档）、`C-c t` 独立 Emacs 大纲侧窗、`S` 全局遮罩、`K` 链接/符号预览、图库灯箱 | 阅读器壳层 | `etaf-md-app` / `etaf-media-viewer` | 已实现 |

## 7. 交互契约

### 7.1 交互来自组件

文档不能给任何东西加行为。定义也不能：**能交互是因为它背后是一个组件，不是因为定义里写了什么。** 定义只负责给一块状态格子与一个回调；按键、焦点、方向键归组件。

块与块之间的连接是另一件事：一个块选中了什么，另一个块该显示什么，组件看不到对方。**这条连线由渲染器做，见 7.5。**

这条跟第 9 章的「组件厚」是同一件事：`etaf-tabs` 本来就能用键盘，`:::tabs` 只是把它接到文档里。所以没有「声明可交互」的关键字，也不需要。

### 7.2 选择器与区域

所有交互块归成一个模型：**一个选择器，一个区域，选中的 key 决定区域显示什么。**

| 角色 | 做什么 | 不认识 |
| --- | --- | --- |
| 选择器 | 收集选择、报告变化、画自己的外观 | 区域里有什么 |
| 区域 | 按选中的 key 显示一份内容 | 选择是怎么来的 |

接线只有三种。

| 接线 | 状态存在哪 | 例子 |
| --- | --- | --- |
| 块内 | 父块的块状态 | 标签页、折叠、步骤条 |
| 跨块 | 选择器那块，复制到区域那块 | 文件树加右栏、表格加详情、目录加正文 |
| 宿主 | 应用自己 | 点一行去后端取数据 |

同一个模型盖住这些场景：

| 场景 | 选择器 | 区域 |
| --- | --- | --- |
| 标签页 | 标签条 | 选中的那一页 |
| 折叠组 | 标题行 | 展开的那些块 |
| 文件树 | 树 | 右栏的文件内容 |
| 表格选行 | 行 | 详情面板 |
| 步骤条 | 当前步骤 | 该步正文 |
| 文档站目录 | 侧栏列表 | 正文 |
| 对话列表 | 会话项 | 消息面板 |
| 卡片组 | 一张卡片 | 详情 |
| 分页 | 页码 | 列表内容 |
| 标签筛选 | 一组标签 | 过滤后的列表 |

### 7.3 选择值

- 选择值是一个 key 的集合。单选就是集合最多一个元素。
- 没写 key 的子块按位置取值：第一个是 `0`，第二个是 `1`。
- 树有两套值：`:selected` 与 `:expanded`，各自一个集合。
- 集合存进块状态，不落盘。重排、换主题、改宽度不丢；重新加载文档回默认。

### 7.4 属性

| 属性 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `selected` | boolean 或 string | 无 | 初始选中：子块上写 `true`，选择器上写一个 key |
| `target` | string | 无 | 选择器指向的区域 `id` |
| `key` | string 或 number | 位置 | 子块的选择值 |
| `multiple` | boolean | `false` | 允许同时选中多个 |
| `empty` | string | 无 | 没有选中时区域显示的话 |

```markdown
:::columns {columns="20ch 1fr"}
:::col
:::tree {target="preview"}
- lisp/
  - etaf-md.el
  - views.el
:::
:::
:::col
:::box {id="preview" empty="选一个文件"}
从左边选一个文件。
:::
:::
:::
```

### 7.5 跨块接线

1. 选择器把选择值写进自己的块状态。
2. 带 `target` 的块一改，渲染器把同一份值复制到目标块的 `:selected`。
3. 重画目标块，不重画整页。
4. 目标块和选择器不在同一页时，不动页面，报一行。

冲突按 3.4 处理：`target` 指不到块报一行；两个选择器指向同一个区域，后出现的生效并报一行；子块的 key 重复取第一个并报一行；选中的 key 没有对应内容，区域显示 `empty`，没写就留空并报一行。

### 7.6 宿主推送

数据在应用手里时，区域留占位，宿主换内容：

```elisp
(etaf-md-update-block SESSION ID VIEW)
```

- `ID` 是区域块的 `id`，`VIEW` 是一个视图，可以是原语，也可以是另一段文档渲染出来的。
- 只重画这一块；块高变了，下面的块跟着让位。
- 重载文档后回到文档里写的占位内容。
- `ID` 找不到时不动页面，报一行。

### 7.7 焦点与按键

- 可聚焦目标是容器画出来的元素，不是文字本身。`TAB` 和 `S-TAB` 在它们之间移动。
- `RET` 激活当前目标。
- 组内用左右方向键切换，例如标签行、折叠组。
- 焦点进入容器时，容器在页面上有可见的焦点标记。焦点离开后恢复原样。
- 焦点顺序按文档顺序，不按视觉位置。窄窗口降级后顺序不变。

### 7.8 状态与重绘

- 状态存在容器自己身上，不存在文档上，也不存到磁盘。
- 重排、换主题、改窗口宽度不丢状态。重新加载文档回到默认状态。
- 状态变化只重画这一块，不重建整页。
- 默认状态由属性决定，`selected`、`open`、`key` 三个就够。
- 属性先定初值再进状态：规则与文档值决定初值，之后状态说了算；规则再变，重新种一次。
- 有 `id` 的块按 `id` 认身份，没有的按位置；上面插一段，下面的块回默认。

### 7.9 搜索、复制、导出

- **isearch**：隐藏的内容仍然参与搜索。命中时那一块自动展开，焦点落在命中处。展开是临时覆盖，不写状态，搜完回到原来的开合。
- **复制**：复制的是看得见的文本，包含容器的标签文字，不包含隐藏的内容。
- **导出**：org 或 HTML 导出时，交互容器按 7.10 的方式展开，读者拿到的文本不缺东西。

### 7.10 无交互环境的扁平化

没有键盘、没有焦点的地方，例如批处理、导出、终端截图，交互容器必须能扁平化。

| 容器 | 扁平化后 |
| --- | --- |
| 标签页 | 每个标签一节，标题是标签文字，全部展开 |
| 代码标签页 | 同标签页 |
| 折叠 | 全部展开，标题保留 |

扁平化不是降级，是同一份内容的另一种排法。所以测试可以在批处理里跑，断言不需要模拟按键。

## 8. 渲染与性能

### 8.1 一块一个组件

每个顶层块是一个独立 Component，键是块的类型加源码。改一个字只重画那一个块，别的块连输出都不碰。

容器不是特例。一个 `card` 是一个块，一个 `columns` 是一个块，里面的 `col` 在同一个块里画。

### 8.2 重绘范围

| 发生了什么 | 重画范围 |
| --- | --- |
| 正文改一个字 | 那一个块 |
| 展开一个折叠 | 那一个块 |
| 切一个标签 | 那一个块 |
| 改主题 | 整页，但每块只换颜色，不重排 |
| 改样式表 | 整页重画并重新派生，不重新解析 |
| 改窗口宽度 | 整页重排，不重建 |
| 改容器定义 | 用到它的块 |

样式可以改变块高，所以块流按每块的实际高度排。标题占几行，下面就接第几行。

### 8.3 成本与预算

- 每个块在一次宽度下只测量一次。宽度没变就不重新测量。
- 嵌套的栏只测量自己的子树，不测量整页。
- 一个块的重排目标在 50 毫秒以内。一份 200 块的文档首次打开目标在 1 秒以内。
- 没有定时器，没有后台刷新。页面静止时不动。
- 样式表每个节点查一次，是一次哈希查找，不进字符循环。

预算写在这里是为了验收时有数可对。具体数字在实现时按基准测试校准，校准时改这一节。

## 9. 定义与组件

这一章说清两件事：定义该有多薄，可复用的东西放在哪。

### 9.1 三层

| 层 | 东西 | 一句话 | 谁调用 |
| --- | --- | --- | --- |
| 引擎 | `box`、`column`、`grid`、文本属性 | 只会摆和画，不懂含义 | 组件 |
| 组件 | `etaf-card`、`etaf-tabs`、`etaf-accordion` | 有名字、有参数、可复用 | 应用和定义 |
| 语法 | `:::card`、`:::tabs` | 把文档的名字和属性翻成组件调用 | 渲染器 |

判据只有一句：**删掉这层，别人还能用吗？** `etaf-card` 删了，别的应用就用不了卡片，所以它在组件层；`:::card` 删了，只是这份文档写不了卡片，所以它在语法层。

### 9.2 从组件到语法

做一个新容器的顺序是固定的三步，判据就是 9.1 那一句。

1. **先找组件。** `etaf-ui` 里有语义对得上的组件，定义只写翻译那三行。这一步最常见，也最薄。
2. **没有组件，而这份形状会被第二处用到，就先写组件，再封语法。** 组件放 `etaf-ui`，带参数、测试和文档；定义缩回翻译。
3. **只用这一次，就在 `:view` 里用 `etaf-view` 搭。** DSL 是默认写法，只有它表达不了的地方（运行时才算出来的标签或列表）才降到 `etaf-node`。用够两次，按 9.6 搬进 `etaf-ui`。

第 3 步不是例外，是第一次实现。风险是它永远留在定义里，所以 9.6 那条搬家的规矩跟着它。

**接口边界。** `:body` 里只能用 `etaf-` 开头的公开接口，不能用 `ebox-` 开头的引擎内部函数。这条和应用、组件的规矩一致。

**内置容器走同一条路。** 6.17 的实现层一列写明每个内置容器靠哪个组件，还是靠原语。写自定义容器时照那一列判断自己该走哪条路。

### 9.3 定义只做三件事

一个类型的定义写三样东西，不多写。

1. **声明**：哪些属性文档能写、哪些是派生、各是什么类型与值域。
2. **校验**：交给渲染器统一做，声明只描述。
3. **翻译**：把文档的语义换成组件的参数。

```elisp
(etaf-md-define-node 'card
  :name "card"
  :summary "一张带标题的卡片"
  :attrs '((title       :type string :required t :pattern "\\S" :doc "卡片标题")
           (description :type string                          :doc "标题下一行")
           (href        :type string                          :doc "整张卡片可点")
           (accent      :type accent  :default neutral        :doc "强调")
           (text-align  :type align   :default start          :doc "内容水平位置")
           (width       :type length                          :doc "自身宽度"))
  :view (lambda (env)
          (etaf-view
           (box :width (or (etaf-md-attr env :width) 'stretch)
                :text-align (etaf-md-attr env :text-align)
                :on-press (when-let* ((href (etaf-md-attr env :href)))
                            (lambda () (etaf-md-follow-link env href)))
             (etaf-card :title (etaf-md-attr env :title)
                        :description (etaf-md-attr env :description)
                        :variant (etaf-md-attr env :accent)
               (expr (etaf-md-content env))))))
```

外层的 `box` 只放宽度、位置与点击，边框和内边距仍在 `etaf-card` 里。定义只把文档的词翻成组件的参数，而且 **`accent` 原样传下去**：六个强调值是共享词汇，组件必须认全，定义不做映射。

### 9.4 组件只收语义参数

组件的参数是给写 Elisp 的人用的，不是给文档用的。

- **不收文档词汇。** 组件里不出现 `:container`、`:::card` 这类词，别的应用不该被迫理解 Markdown。
- **不收颜色值。** 组件认 `accent`、`surface` 这类语义角色，不认 `"#c00"`。共享词汇里的每个值它都要认；认不全就是组件未达标。
- **几何参数尽量少。** 内边距、间距由组件自己的默认值负责，定义只在必要时覆盖。

两个反例：组件里加一个 `:markdown-level`，把语法漏进组件；定义里手写一张表把六个强调值压成三个，那会静默丢信息。

### 9.5 一个视觉事实一个权威

| 事实 | 权威 |
| --- | --- |
| 标题、引用、代码、表格长什么样 | 样式规则，读者可改 |
| 容器长什么样 | 定义传给组件的参数 |
| 组件自己的基线 | 组件 |
| 配色 | 令牌，三套配色各一份 |

两处都能改同一个事实，就是 bug。组件的默认值只是基线，定义可以覆盖；定义的值是文档默认，普通属性的值还能被读者盖掉，见 10.3。

### 9.6 用够两次就上移

新类型要的壳没人有，定义只能拿原语自己搭。这不是重复造轮子，是第一次实现。风险是它永远留在定义里。

规则：**第二个应用也要它，就搬进 `etaf-ui`**，连参数、测试和文档一起搬。搬完定义缩回翻译那三行。

### 9.7 内置定义也走定义

`box`、`card`、`columns` 不是渲染器里的特例，它们是同一张注册表里的三条定义。`heading`、`quote`、`code` 也一样，只是没有名字。

这一条是整套分法能不能长期成立的关键。只要有一个类型在渲染器里有专属分支，这套 API 就没被验证过，用户迟早撞上只有那条分支才有的能力。

三个后果。

- 内置定义写在 `lisp/etaf-md-nodes.el`，和用户定义用同一个入口注册。
- 测试里必须有一条：把内置的 `card` 换成用户定义，页面照常渲染。
- 组件改参数时，先红的是定义测试，不是用户。

## 10. 扩展

### 10.1 一个类型的定义

一个定义是数据加一个函数，不是文档里的代码。

```elisp
(etaf-md-define-node 'heading
  :summary "标题，级别由 # 的个数决定"
  :derived '((level  :type number :min 1 :max 6 :integer t :doc "井号个数")
             (number :type string                            :doc "章节号，不编号时没有"))
  :attrs '((font-weight :type enum :one-of (normal bold)     :default bold    :doc "字重")
           (color      :type color                           :default heading :doc "字色")
           (prefix     :type string                          :default ""      :doc "显示前缀")
           (numbering  :type enum  :one-of (none decimal lower-roman upper-alpha)
                       :default decimal :doc "章节号的格式，派生阶段读"))
  :view (lambda (env) …))
```

**「派生」是本文对一类值的统称：解析或派生阶段算出来写上去的值，在 Markdown 文本里没有写法。** `level` 由井号个数定，`number` 由整篇的章节顺序定，两者都不是作者敲进去的。所以它们单独一张 `:derived` 表，和作者能写的 `:attrs` 分开。

| 关键字 | 取值 | 含义 |
| --- | --- | --- |
| 名字 | 符号，第一个参数 | 类型名，注册表里的键 |
| `:name` | 字符串 | 文档写得出的写法，`"card"` 对应 `:::card`。省略表示文档写不出 |
| `:summary` | 字符串 | 一行说明，进帮助与报错 |
| `:attrs` | 属性表 | 普通属性：文档写得进，读者盖得掉 |
| `:derived` | 属性表 | 派生属性：解析或派生阶段填，谁都不能写 |
| `:accepts` | 子块表 | 收哪些子块。有它就是父类型，没有就是任意块 |
| `:child-syntax` | `blocks` 或 `markers` | 子块写法：默认 `:::name`，`markers` 用 `@name` 一行一个 |
| `:contract` | 整数，当前 `1` | 文档侧属性表的版本，见 10.6 |
| `:view` | 函数 | `(lambda (env) VIEW)`，默认画法 |
| `:extends t` | 标记 | 保留内置的声明与画法，你的追加 |
| `:replace t` | 标记 | 丢掉内置的声明与画法 |

**`view` 只收一个 `env`。** 它是画这一块时手里有的东西：当前节点，加上渲染器借给你的能力。一个块画一次建一个，画完就丢；两个卡片同时画，各拿各的。属性已经校验、补过默认值，派生属性也在里面。

除了下面这些，`env` 给不了别的东西，所以定义读不到文件、发不出网络请求、改不了全局。

| 组 | 函数 | 拿什么 |
| --- | --- | --- |
| 读节点 | `(etaf-md-attr env :title)` | 一个属性的最终值，见 10.3。读子节点时把节点放最后：`(etaf-md-attr env :title tab)` |
| | `(etaf-md-type env)` | 类型名，一份画法被几个名字共用时用它分支 |
| | `(etaf-md-children env)` | 子节点，按顺序。只在逐条摆放子块时用它枚举 |
| 查外观 | `(etaf-md-surface env 'raised)` | 面换成底色，`none` 得 `nil` |
| | `(etaf-md-accent env 'warning)` | 强调值换成颜色 |
| 画 | `(etaf-md-content env)` | 这一块的全部子块，画成视图。整块放置时用它 |
| | `(etaf-md-render env nodes)` | 指定的节点画成视图，一个或一串。逐条摆放时用它 |
| | `(etaf-md-default-view env)` | 这个节点用内置画法再画一遍 |
| 服务 | `(etaf-md-follow-link env href)` | 打开一个目标 |
| | `(etaf-md-block-state env :selected)` | 读本块状态，带默认值 `(etaf-md-block-state env :selected v)` |
| | `(etaf-md-set-block-state env :selected VALUE)` | 写本块状态 |
| | `(etaf-md-available-width env)` | 本块可用宽度 |

`content` 与 `render` 的分工只有一句：内容整块塞进组件，用 `content`；组件按项收内容，用 `render` 一块一块画。`children` 只服务后一种，用来枚举子块与读每条的属性。

十二个，没有第十三个。序号怎么格式化是派生阶段的事，不进画法，所以也没有对应的函数。

### 10.2 属性怎么声明

普通属性的每项写四件事：名字、类型、值域、默认值。派生属性的每项写三件：名字、类型、值域，它没有默认值。缺一件就是加载错误。

```elisp
;; 普通属性，写在 :attrs
(title  :type string :required t :pattern "\\S" :doc "卡片标题")
(accent :type accent :default neutral :one-of (neutral warning) :doc "强调")
(prefix :type string :default "" :doc "显示前缀")

;; 派生属性，写在 :derived；条目形状相同，但没有 :default 与 :required
(level  :type number :min 1 :max 6 :integer t :doc "井号个数")
(number :type string                         :doc "章节号")
```

| 字段 | 必写 | 说明 |
| --- | --- | --- |
| `:type` | 是 | `string`、`number`、`boolean`、`length`、`surface`、`accent`、`align`、`enum`、`color` |
| `:default` | 否 | 不写就是 `nil`；只在 `:attrs` 里有效 |
| `:required` | 否 | 只对普通属性有效，与 `:default` 互斥 |
| `:pattern` | 否 | 只对 `string` |
| `:min`、`:max`、`:integer` | 否 | 只对 `number` |
| `:one-of` | 否 | `enum` 必写；三个语义类型可用来收窄 |
| `:doc` | 建议 | 出现在帮助与报错里 |

三条规则。

- **两张表，两类属性。** `:attrs` 里是普通属性，文档写得进，读者盖得掉；`:derived` 里是派生属性，文档写不出，读者改不了，只能当选择器。
- **派生表不写 `:default` 与 `:required`。** 值由解析或派生阶段给，没给就是 `nil`。
- **子块表** `:accepts` 的每项写法相同，只多一个 `title`，由渲染器提供，定义不要重复声明。

### 10.3 一个值怎么定下来

四层，顺序写死。视图只调一次 `attr`，不需要知道自己在读哪一层。

| 顺序 | 来源 | 例子 |
| --- | --- | --- |
| 1 | 读者的样式规则 | `(:accent danger)` |
| 2 | 文档写的值 | `accent=warning` |
| 3 | 声明里的 `:default` | `neutral` |
| 4 | 解析或派生写的值 | `level=2`、`number="1.1"` |

前三条对普通属性生效。第 4 条是派生属性的唯一来源，其余三层对它不生效。

### 10.4 画法默认用 DSL

`etaf-view` 比手工搭节点短，也看得出结构：属性写在前面，子节点写在后面，属性值是普通 Elisp，算出来的子节点用 `(expr …)` 包一层。

```elisp
(etaf-view
 (box :padding '((lh 1) (ch 2))
   (text "标题")
   (expr (etaf-md-content env))))
```

只有一个地方降到 `etaf-node`：标签或属性要在运行时才算出来，比如用 `mapcar` 生成一串行。那种时候 DSL 写不出来，是语言限制，不是风格选择。

### 10.5 给一个类型换画法

```elisp
(etaf-md-set-view 'heading
  (lambda (env)
    (etaf-view
     (box :background-color (etaf-md-surface env (etaf-md-attr env :background))
       (expr (etaf-md-default-view env)))))
  :extends t
  :style-keys '((background :type surface :default none :doc "标题底色")))
```

| 部分 | 含义 |
| --- | --- |
| 第一个参数 | 类型名，`heading` 或 `card` 都行，没有特例 |
| 第二个参数 | `(lambda (env) VIEW)`，与 `:view` 同一个签名 |
| `:extends t` | 保留内置的声明与画法，你的追加 |
| `:replace t` | 丢掉内置的声明与画法 |
| `:style-keys` | 新加的属性声明，只能在这里加，而且必须配函数 |

三条规则。

- 必须返回视图，不能改节点树。
- 函数报错时这类型回退内置，页面继续渲染，错误进 `doctor`。
- **加属性必须配函数。** 数据定义不能加属性，没人读的属性就是死配置。

### 10.6 覆盖与卸载

三种写法，一张表说清。

| 写法 | 效果 | 用在 |
| --- | --- | --- |
| `:extends t` | 保留内置的声明与画法，你的追加 | 想加属性、包一层 |
| `:replace t` | 丢掉内置定义，声明与画法都由你定 | 想彻底换一种做法 |
| 两个都不写 | 只在没有同名类型时生效，重名报错 | 新类型 |

四条约束。

- **文档侧的属性表只能增，不能改。** 新属性只能追加，改名或删掉算破坏性变更，升 `:contract`，旧文档按 3.4 降级并说明。
- **属性名与子块名都只有一份声明。** 别名、同义词一概不做。
- **`:default` 永远指内置原值。** 加载时给内置定义留一份快照，否则「回到默认」没有意义。
- **覆盖要留痕。** `:replace t` 的报错行点名被替换的定义，`doctor` 列出覆盖链与来源文件。

卸载三条，测试才写得出「装上去、卸下来、页面回到内置」。

| 动作 | 怎么写 |
| --- | --- |
| 删掉一条样式规则 | `(etaf-md-set-attr '(heading) nil)` |
| 删掉自己换的画法 | `(etaf-md-set-view 'heading nil)` |
| 删掉一个类型定义 | `(etaf-md-undefine-node 'card)` |

内置类型卸载后回到内置那份；用户定义卸载后名字不再存在，文档写它就是「名字没有定义」。

### 10.7 定义放在哪、什么时候读

- 内置定义写在 `lisp/etaf-md-nodes.el`，加载时按顺序注册一次：先文本类型，再提示，再结构，再集合，最后交互。它们和用户定义走同一个 `etaf-md-define-node`。
- 用户定义放在 `etaf-md-node-directory` 指的目录里，一个 `.el` 一个文件。
- 加载顺序固定：包自带的先，用户目录后，同一目录内按文件名排序。后加载的能覆盖先加载的，但必须显式声明，见 10.6。
- 一个 session 创建时读一次注册表，之后不再读盘。改了定义要 `r` 重载，或者重开预览。
- 文档不能注册类型，也不能执行 Elisp。分享文档不等于分享代码。
- **契约版本由文档自己声明。** front matter 里可以写 `contract: 1`；不写就按当前版本处理。
- **注册表是一个变量，不是藏在函数里。** `etaf-md-node-definitions` 存着类型到定义的表，内置定义与用户定义都在其中，一个类型一条。
- **派生属性从注册表读。** `(etaf-md-derived-attributes 'heading)` 给出 `(level number)`，派生阶段按它填值，校验按它拒绝文档写法，`describe-nodes` 按它打印。附录 A.2 就是这张表的印刷版。

### 10.8 调试

`etaf-md-describe-nodes` 打印注册表，一行一个类型：

```
heading            内置语法，文档写不出名字
  derived   level  number
  ordinary  font-weight  color  prefix  numbering
  rules     (heading)  (heading :level 1)  (heading :level 2)
```

- 出问题先查一条链：这块是什么类型 → 哪条定义 → 调了哪个组件 → 属性值来自哪一层 → 落到哪个令牌。
- 报错行永远在页面上，不用开日志。
- `etaf-md-doctor` 回答页面能用哪些可选能力——`typeset-native`、`ffmpeg`、`mmdc`、`qrencode` 与 `git`——所以读者能知道某个块为什么留着源码。报告注册表本身（几个类型、哪个覆盖生效）还在计划中。

### 10.9 信任模型

- 文档没有执行权限。它能做的只有命名和给属性。
- 定义只从用户配置的目录加载，不读当前目录、不读文档旁边的目录。
- 定义不能读文件、发网络请求、起定时器、改全局状态。要数据就在属性里传。
- 渲染不产生副作用。视图只读 refs 和缓存值。

## 11. 路线图

### 11.1 阶段

| 阶段 | 内容 | 完成判据 |
| --- | --- | --- |
| 0 | GitHub 提示块 | 已实现，51 个测试覆盖 |
| 1 | 渲染路径：解析、派生、样式规则、失败目录，并把 `heading`、`box`、`columns`、`card` 用定义写 | 21 种失败各有一条断言；三层嵌套与超限；窄窗三档截图；用户定义能替掉内置的 `card`；每个内置类型至少一个读者属性生效；改样式规则不重新解析 |
| 2 | 提示容器：五条定义共用一份画法，与 GitHub 写法出同一个结果 | 两种写法渲染成同一个 buffer 文本；五个强调值与类型一一对应 |
| 3 | 集合：`steps`、`timeline`、`stats`、`field`、`file-tree`、`chat` | 每个容器有正例、反例、三种配色截图 |
| 4 | 交互：`tabs`、`code-tabs`、`accordion` 与它的子块 `collapse`，再加跨块接线与宿主推送 | 按键走命令循环；状态经重排与换主题不丢；扁平化输出不缺内容；选择器一改只重画目标块 |
| 5 | 文稿：`table`、`window` | 表格高亮按行列生效；窗口只画标题栏 |
| 6 | 注册表与用户定义 | 示例定义能装能卸，卸载后页面回到内置；给内置类型加一个读者属性并生效；覆盖后 `:default` 仍回内置；契约版本不符有提示；`doctor` 报数量与覆盖链 |
| 7 | 源码 buffer 的编辑体验：降权、配对提示、插入与补全、折叠，合成 `etaf-md-edit-mode` | 关闭后 `font-lock-keywords` 与开启前 `equal`；`buffer-string` 不变；2000 行文档额外耗时 50 毫秒以内；同一行内打字不触发配对计算 |

### 11.2 每个容器的验收矩阵

每个容器都要过这六格，少一格不算完成。

| 格 | 检查什么 |
| --- | --- |
| 正例 | 文档写出来，渲染成预期的样子 |
| 反例 | 少一个必填属性、写错一个值，页面降级且说明准确 |
| 嵌套 | 放进 `columns` 的栏里、放进 `card` 里，仍然成立 |
| 配色 | 暗色、亮色、纸色、跟随主题，四档下都可读 |
| 窄窗 | 宽、中、窄三档，内容不少，字号不变 |
| 样式 | 一个样式键改变了它的外观；一个未知键报错并回退内置 |

渲染路径另有四条断言，跟容器无关。

- 同一份文档，改样式前后解析次数不变。
- 标题加了前缀，锚点不变。
- 关了编号，派生阶段跳过。
- 覆盖了 `heading` 的渲染后，`etaf-md-default-view` 仍是内置画法。

### 11.3 完成判据

一个阶段完成，必须同时满足三条。

1. `make check` 通过，包括结构检查、编译、测试、接口核对。
2. 受影响的示例在真实 GUI 里跑过一遍，截图看过。
3. 附录 A 的属性表、附录 C 的样式表、附录 D 的对照表、附录 E 的词汇表同步更新。

## 12. 不做的事

- 不做 HTML 子集、CSS 子集、`<style>` 标签。一套渲染器里塞两个排版系统，边界会越来越模糊。
- 不做文档内嵌脚本，不让文档注册容器。
- 不做字号参数，也不做缩放参数。字号来自用户的默认字体，视图与规则都不碰它。
- 不做远程 iframe、远程播放器、远程代码执行。
- 不做圆角、阴影、渐变、动画。
- 不做 markdown 之外的第二种文档格式。
- 不做页面、路由、导航、发布。那是上层应用的事，见 1.2。
- 不做 `justify` 文本两端对齐。字符网格里没有字间距可以拉，只能填空格，中文段落行尾会出洞。
- 第一版不解析行内强调与链接，标题里写 `**粗体**`，出来就是星号加文字。这条限制写在文档里，不假装配支持。

## 附录 A：属性参考

两张表。普通属性文档写得进、读者盖得掉；派生属性由解析或派生阶段给，谁都写不进。类型只从这里挑名字，不发明同义词。

### A.1 普通属性

| 属性 | 类型 | 值域 | 默认 | 含义 | 用在 |
| --- | --- | --- | --- | --- | --- |
| `title` | string | 可选 `:pattern` | 无 | 标题文字 | 提示块、card、steps、timeline、file-tree、accordion、table、window；子块里是 tab、step、event、stat、collapse |
| `description` | string | | 无 | 标题下的摘要 | card |
| `href` | string | | 无 | 跳转地址 | card |
| `id` | string | `:pattern "^[^\\s]+$"` | 无 | 稳定锚点 | 所有块 |
| `surface` | surface | 五个面 | 见 6.x | 底色 | box |
| `accent` | accent | 六个强调 | 见 6.x | 强调 | box、card、提示块 |
| `text-align` | align | 三个位置 | start | 内容水平位置 | box、card |
| `width` | length | `ch`、`lh`、`%` | 省略即占满 | 自身宽度 | box、card |
| `height` | length | 同上 | 省略即由内容决定 | 内容区高度 | window |
| `padding` | length | 同上 | 无 | 内边距 | box、columns |
| `gap` | length | 同上 | 2ch | 项间距 | columns |
| `columns` | number 或 string | 数字 1–6，或轨道串 | 见 6.x | 栏数或轨道 | columns、stats |
| `min-width` | length | | 24ch | 最小栏宽 | columns |
| `divider` | boolean | | true | 栏间竖线 | columns |
| `align-items` | enum | start center end stretch | stretch | 项的交叉轴对齐 | columns |
| `justify-content` | enum | start center end between around | start | 项的主轴对齐 | columns |
| `align-self` | enum | start center end | start | 自身在父级里的位置 | columns |
| `wrap` | boolean | | false | 放不下时换行 | columns |
| `list-style` | enum | decimal bullet none | 见 6.x | 列表记号 | steps、timeline |
| `start` | number | `:integer t` | 1 | 起始编号 | steps |
| `open` | boolean | | 见 6.x | 默认展开 | 提示块、collapse 子块 |
| `collapsible` | boolean | | false | 允许收起 | 提示块 |
| `selected` | boolean 或 string | | 无 | 初始选中 | 所有选择器、tab 子块 |
| `target` | string | | 无 | 选择器指向的区域 `id` | 选择器 |
| `key` | string 或 number | | 位置 | 子块的选择值 | 子块 |
| `multiple` | boolean | | false | 允许同时选中多个 | 选择器、collapse 子块 |
| `empty` | string | | 无 | 没选中时区域显示的话 | 区域 |
| `grow` | number | | 1 | 宽度份数 | col 子块 |
| `time` | string | | 无 | 时间文字 | event、message 子块 |
| `value` | string | | 无 | 数字文本 | stat 子块 |
| `from` | string | | 无 | 发送者 | message 子块 |
| `label-width` | length | | 自动 | 名称列宽 | field |
| `separator` | enum | colon none | colon | 名称与值的分隔 | field |
| `self` | enum | left right | left | 自己一侧 | chat |
| `highlight-rows` | string | 空格分隔的行号 | 无 | 高亮行 | table |
| `highlight-columns` | string | 空格分隔的列号 | 无 | 高亮列 | table |
| `highlight` | accent | 六个强调 | warning | 高亮用哪个强调 | table |
| `lines` | boolean | | true | 画不画树线 | file-tree |
| `background` | surface 或色值 | 五个面，或字面色 | none | 底色 | quote、code、table、提示块 |
| `color` | color | 令牌，或字面色 | heading | 字色 | heading、code |
| `font-weight` | enum | normal bold | bold | 字重 | heading |
| `font-style` | enum | normal italic | normal | 倾斜 | quote |
| `prefix` | string | | `""` | 标题前缀，不影响锚点 | heading |
| `numbering` | enum | none decimal lower-roman upper-alpha | decimal | 章节号的格式，派生阶段读 | heading、table |
| `margin-top` | length | | `0` | 上间距 | quote、code、table |
| `margin-bottom` | length | | `0` | 下间距 | quote、code、table |
| `border-left-width` | length | | `1ch` | 左侧竖条宽度 | quote、提示块 |
| `label-color` | color | | muted | 围栏语言标签 | code |
| `header-background` | surface 或色值 | | table-header | 表头底 | table |
| `stripe-background` | surface 或色值 | | table-stripe | 条纹底 | table |

默认列写的是共同默认；类型在自己的表里写了别的，以那张表为准。

一个类型只声明它用得上的那几个，其余不必出现。

### A.2 派生属性

文档写不出，读者改不了，但样式规则的选择器可以按它选。

| 类型 | 派生属性 | 谁填 |
| --- | --- | --- |
| `heading` | `level`、`number` | 解析器给 `level`，派生给 `number` |
| `code` | `language` | 解析器 |
| `table` | `number` | 派生 |
| 其余类型 | 没有 | — |

这张表不是另抄一份，它是注册表的印刷版。注册表是一个变量，只有一个写入口：`etaf-md-define-node`，内置定义和用户定义都从它进去，谁都不直接 `setq` 这个变量。

```elisp
;; 内置定义写在 lisp/etaf-md-nodes.el，是一串 etaf-md-define-node 调用；
;; 加载完就在注册表里，一个类型一条，没有第二份声明。
(alist-get 'heading etaf-md-node-definitions)
;; => (:summary "标题，级别由 # 的个数决定"
;;     :derived ((level …) (number …))
;;     :attrs ((font-weight …) (prefix …) …)
;;     :view …)

;; 派生属性不是另一张表，是从同一条定义里筛出来的
(etaf-md-derived-attributes 'heading)   ; => (level number)
(etaf-md-derived-attributes 'paragraph) ; => nil
```

三条规矩。

- **只有 `etaf-md-define-node` 写注册表。** 用户也不 `setq` 它；要改就再定义一次，加 `:extends` 或 `:replace`。
- **派生属性单独一张表。** 同一条定义里 `:derived` 与 `:attrs` 并列，条目形状相同；`etaf-md-derived-attributes` 读的就是 `:derived`。
- **三处同源。** `describe-nodes`、派生阶段、这张附录读的都是同一个变量，不会各说一套。

## 附录 B：底色、强调与令牌

`surface` 的每个值对应一个令牌，`accent` 的每个值对应一对。

| 属性值 | 前景 | 底色 | 说明 |
| --- | --- | --- | --- |
| `surface=none` | — | 无 | 不画底 |
| `surface=page` | — | `background` | 与正文拉开 |
| `surface=raised` | — | `surface-raised` | 代码块、卡片 |
| `surface=sunken` | — | `surface-sunken` | 表头、次要信息 |
| `surface=quote` | — | `quote` | 引用性质 |
| `accent=neutral` | `foreground` | `surface-raised` | 无强调 |
| `accent=primary` | `primary` | `primary-soft` | 说明、链接 |
| `accent=success` | `success` | `success-soft` | 成功 |
| `accent=warning` | `warning` | `warning-soft` | 注意 |
| `accent=danger` | `danger` | `danger-soft` | 危险 |
| `accent=important` | `important` | `important-soft` | 重要 |

五个提示块名字到强调值的映射见 6.2。

## 附录 C：样式规则怎么写

规则是一条数据，四件事：选择器、键值、三种特殊值、加新属性的口子。键就是 A.1 里该类型声明过的普通属性名，所以这里不再列第二张键表。

```elisp
(setq etaf-md-styles
      '(((heading)          (:font-weight bold) (:color heading) (:numbering decimal))
        ((heading :level 2) (:prefix "◇ "))))
```

选择器两种形态，都是列表：`(类型)` 选中全部，`(类型 :属性 值 …)` 再加条件。没有第三种，也没有省略形态。

| 规则 | 说明 |
| --- | --- |
| 最终值 | 命中的规则按表顺序叠加，同一个键后者赢；没有规则提到这个键，取节点属性值；属性也没有，取声明里的 `:default` |
| 选择范围 | 选择器里的属性必须在该类型声明过，写错整条规则忽略并报一行 |
| 键的合法性 | 键必须是该类型的普通属性；派生属性只能出现在选择器里 |

三种特殊值。

| 写法 | 效果 |
| --- | --- |
| `(:prefix nil)` | 关掉这一项 |
| 整个删掉 `:prefix` 这个键 | 不覆盖，取节点属性值或 `:default` |
| `(:color :default)` | 回落内置值，不管别处写了什么 |

要给一个类型加新属性，只能在 `etaf-md-set-view` 的 `:style-keys` 里声明，而且必须配函数，见 10.5。新属性先加进 `:style-keys` 的声明，再补进 A.1；没声明的键，加载时报错。

## 附录 D：plume 对照

| plume | 我们的决定 | 说明 |
| --- | --- | --- |
| `align` | 并入 `box` 的 `text-align` 属性 | 不为一种对齐加一个容器 |
| `flex` | 并入 `columns` | 一个容器管横向、换行、比例 |
| `card` | 吸收，`card` | 圆角阴影改成一圈边框加面 |
| `card-grid` | 并入 `columns {columns=N}` | 卡片并排就是栏里放卡片 |
| `card-masonry` | 不吸收 | 行高固定，瀑布流装出来就是网格 |
| `steps` | 吸收，`steps` + `step` | 编号加标题 |
| `tabs` | 吸收，`tabs` + `tab` | 键盘可达，切换只重画一块 |
| `code-tabs` | 以 `tabs` 为基础，另立声明 | 子块里放围栏代码，`title` 可省，省略时取语言名 |
| `collapse` | 吸收，`accordion` 的子块 | 同时只开一块，搜索命中自动展开 |
| `field` | 吸收，`field` | 名称列自动对齐 |
| `timeline` | 吸收，`timeline` + `event` | 记号可选 |
| `table` | 部分吸收 | 标题与行列高亮 |
| `file-tree` | 吸收，`file-tree` | 记号只用允许的字符 |
| `code-tree` | 吸收，`code-tree` | 文件列表与代码面板并排，共用 tabs 的 `@file` 记号 |
| `chat` | 吸收，`chat` + `message` | 左右对齐加缩进，不画气泡 |
| `window` | 变形吸收，`window` | 只画标题栏 |
| `encrypt` | 不吸收 | 保密文档不该进预览 |
| `npm-to` | 吸收，`npm-to` | 按固定命令表改写，不执行命令 |
| `lang-repl` | 不吸收 | 要解释器 |
| `qrcode` | 吸收，`qrcode` | 用 `qrencode` 画 PNG，缺程序时保留文本 |
| `plot`、`pdf` | 不吸收 | Plume 的 `plot` 是「隐秘文本」组件，不是图表；PDF 要内嵌文档 |
| `annotation`、`abbreviation` | 不吸收 | 要图上标注和悬停浮层 |
| `code-pen`、`code-sandbox`、`repl`、`caniuse` | 不吸收 | 要浏览器和网络 |

## 附录 E：词汇表

这张表是命名的依据。新名字先在这里查；查不到就从「权威」那一列借一个，再补进这张表。

### E.1 属性名

| 名字 | 出处 | 含义 | 不要写成 |
| --- | --- | --- | --- |
| `title` | HTML | 标题文字 | `heading`、`caption` |
| `description` | Ant、Primer | 标题下的摘要 | `summary`、`subtitle` |
| `surface` | Material、Polaris | 底色角色 | `background`、`fill`、`panel` |
| `accent` | shadcn/ui | 强调值 | `tone`、`variant`、`type`、`intent` |
| `text-align` | CSS | 内容水平位置 | `align`、`position` |
| `align-self` | CSS | 自身在父级里的位置 | `self-align`、`align` |
| `align-items` | CSS | 子块的交叉轴对齐 | `items`、`cross-align` |
| `justify-content` | CSS | 子块的主轴对齐 | `justify` |
| `width` | CSS | 自身宽度 | `w` |
| `height` | CSS | 内容区高度 | `h` |
| `padding` | CSS | 内边距 | `pad`、`inset` |
| `gap` | CSS | 块间距 | `spacing`、`space` |
| `columns` | Bootstrap 栅格、CSS | 栏数或轨道 | `cols`、`tracks`、`grid` |
| `min-width` | CSS | 最小栏宽 | `min`、`threshold` |
| `wrap` | CSS `flex-wrap`、Ant | 放不下时换行 | `flex-wrap`、`nowrap` |
| `grow` | Tailwind | 宽度份数 | `flex`、`ratio`、`weight` |
| `list-style` | CSS `list-style-type` | 列表记号 | `marker`、`bullet` |
| `open` | HTML `<details open>` | 默认展开 | `expanded`、`visible` |
| `collapsible` | Bootstrap、Primer | 允许收起 | `foldable`、`toggle` |
| `selected` | HTML `<option selected>` | 这一项默认选中 | `active`、`current` |
| `derived` | 本文的解析与派生阶段 | 派生属性，文档写不出 | `read-only`、`computed` |
| `href` | HTML | 跳转地址 | `url`、`link`、`to` |
| `start` | HTML `<ol start>` | 起始编号 | `begin`、`from` |
| `separator` | 通用 | 名称与值的分隔 | `divider` |
| `label-width` | CSS 风格组合 | 名称列宽 | `label-w`、`width` |
| `self` | 聊天界面通用 | 自己一侧 | `me`、`own` |
| `target` | 本文的交互接线 | 选择器指向的区域 | `for`、`pane` |
| `key` | SVG、React | 子块的选择值 | `value`、`index` |
| `multiple` | HTML `<select multiple>` | 允许同时选中多个 | `multi`、`many` |
| `empty` | 通用 | 没选中时的占位 | `placeholder`、`empty-text` |
| `from` | 邮件、聊天 | 发送者 | `sender`、`author` |
| `time` | HTML `<time>` | 时间 | `date`、`at` |
| `value` | HTML `<input value>` | 数字文本 | `number`、`figure` |
| `highlight-rows` | 通用 | 高亮行号 | `hl-rows`、`mark` |
| `highlight-columns` | 通用 | 高亮列号 | `hl-cols`、`mark` |
| `highlight` | 本表命名规矩 | 高亮的强调值 | `tone`、`mark-color` |
| `id` | HTML | 稳定锚点 | `anchor`、`slug` |

### E.2 类型

| 名字 | 出处 | 含义 | 不要写成 |
| --- | --- | --- | --- |
| `string` | JSON Schema | 文本 | `str`、`text` |
| `number` | JSON Schema | 整数或小数 | `int`、`float`、`num` |
| `boolean` | JSON Schema | `true` 或 `false` | `bool`、`flag` |
| `length` | CSS 值类型 | 数字加单位 | `size`、`dimension` |
| `enum` | JSON Schema | 定义列出的词之一 | `one-of`、`choice` |
| `surface` | Material、Polaris | 五个面值之一 | `background`、`fill` |
| `align` | CSS | 三个水平位置之一 | `text-align`、`justify` |
| `accent` | shadcn/ui | 六个强调值之一 | `tone`、`variant` |

### E.3 令牌

| 名字 | 出处 | 含义 | 不要写成 |
| --- | --- | --- | --- |
| `background` | shadcn/ui | 页面底色 | `bg`、`page` |
| `foreground` | shadcn/ui | 正文 | `ink`、`text` |
| `muted` | shadcn/ui | 次要文字 | `secondary`、`dim` |
| `faint` | 通用 | 最弱的一层 | `subtle`、`ghost` |
| `border` | shadcn/ui | 边框 | `line`、`stroke` |
| `surface-raised` | Material 分层命名 | 抬起的面 | `panel`、`card-bg` |
| `surface-sunken` | Material 分层命名 | 下沉的面 | `panel2`、`inset` |
| `quote` | 通用 | 引用底 | `quote-bg`、`blockquote` |
| `quote-bar` | 通用 | 引用竖条 | `bar`、`accent-bar` |
| `table-header` | 通用 | 表头底 | `th`、`header` |
| `table-stripe` | 通用 | 条纹底 | `stripe`、`zebra` |
| `heading` | HTML | 标题色 | `title`、`h` |
| `primary` | shadcn/ui | 主要强调 | `accent`、`brand`、`info` |
| `primary-soft` | shadcn 的 `-foreground` 风格 | 主要强调的浅底 | `accent-soft` |
| `success` | Bootstrap、shadcn | 成功 | `ok`、`positive`、`green` |
| `success-soft` | 同上 | 成功的浅底 | `ok-soft` |
| `warning` | Bootstrap、shadcn | 注意 | `warn`、`caution` |
| `warning-soft` | 同上 | 注意的浅底 | `warn-soft` |
| `danger` | Bootstrap、shadcn | 危险 | `error`、`red`、`critical` |
| `danger-soft` | 同上 | 危险的浅底 | `error-soft` |
| `important` | GitHub 提示块 | 重要 | `note`、`emphasis` |
| `important-soft` | 同上 | 重要的浅底 | — |

### E.4 声明里的字段

| 名字 | 出处 | 含义 | 不要写成 |
| --- | --- | --- | --- |
| `:name` | HTML 的 `name` | 文档写得出的写法 | `tag`、`keyword` |
| `:summary` | 通用 | 一行说明 | `desc`、`description`（那是卡片属性） |
| `:attrs` | JSON Schema 的 `properties` | 属性表 | `props`、`fields` |
| `:accepts` | 通用 | 收哪些子块 | `children`、`:kind` |
| `:view` | ETAF | 默认画法 | `:body`、`:render` |
| `:contract` | 通用 | 文档侧属性表的版本 | `:version` |
| `:extends` / `:replace` | 通用 | 覆盖的内置定义 | `:override`、`:merge` |
| `:style-keys` | 本表命名规矩 | 换画法时新加的属性 | `:keys` |
| `:type` | JSON Schema | 属性的类型 | `:kind`、`:value-type` |
| `:derived` | 本表命名规矩 | 派生属性的声明表 | `:read-only`、`:computed`、`:source` |
| `:default` | JSON Schema | 默认值 | `:fallback` |
| `:required` | JSON Schema | 必填 | `:mandatory` |
| `:pattern` | JSON Schema | `string` 的正则 | `:regex` |
| `:min` / `:max` | JSON Schema | `number` 的范围 | `:range` |
| `:integer` | JSON Schema | 只收整数 | `:int` |
| `:one-of` | JSON Schema | 词表 | `:choices`、`:enum` |
| `:doc` | 通用 | 进帮助与报错的说明 | `:help`、`:comment` |

### E.5 函数

| 名字 | 含义 |
| --- | --- |
| `etaf-md-define-node` | 注册一个类型，或用 `:extends`、`:replace` 覆盖 |
| `etaf-md-undefine-node` | 删掉一个类型定义 |
| `etaf-md-set-attr` | 给一个选择器装样式规则，传 `nil` 删掉 |
| `etaf-md-set-view` | 给一个类型换画法，传 `nil` 删掉 |
| `etaf-md-describe-nodes` | 列出注册表 |
| `etaf-md-doctor` | 诊断 |
| `etaf-md-node-directory` | 用户定义的目录 |
| `etaf-md-node-definitions` | 注册表：类型 → 定义，内置与用户都在里面 |
| `etaf-md-derived-attributes` | 取一个类型的派生属性名 |
| `etaf-md-styles` | 样式规则表 |
| `etaf-md-attr` | 读一个属性的最终值 |
| `etaf-md-type` | 读类型名 |
| `etaf-md-children` | 按顺序取子节点，逐条摆放时用 |
| `etaf-md-surface` | 面换成底色 |
| `etaf-md-accent` | 强调值换成颜色 |
| `etaf-md-content` | 把这一块的子块画成视图，整块放置时用 |
| `etaf-md-render` | 把指定的节点画成视图 |
| `etaf-md-default-view` | 取某个节点的内置画法 |
| `etaf-md-follow-link` | 打开一个目标 |
| `etaf-md-block-state` | 读本块状态 |
| `etaf-md-set-block-state` | 写本块状态 |
| `etaf-md-available-width` | 本块可用宽度 |

`etaf-card`、`etaf-tabs`、`etaf-accordion`、`etaf-steps`、`etaf-timeline`、`etaf-statistic`、`etaf-tree` 属于 `etaf-ui` 的组件目录，本包只调用，不改名。

## 附录 F：两个完整的例子

一个自定义容器，一个内置语法。两例都从文档走到页面，用到的每个名字都能在正文里找到出处。

### F.1 自定义容器：文档

````markdown
:::card {title="缓存命中" description="一次缩放，不重画" href="#cache"
        accent=warning text-align=start width="48ch"}
图片和矢量按页面尺寸缩放，不重新画。
:::
````

### F.2 自定义容器：样式

定义见 9.3，这里只看样式与页面。

```elisp
;; 包自带的样式规则：卡片只有一个可盖属性，其余外观归 etaf-card 的基线
(setq etaf-md-styles '(((card) (:accent neutral))))

;; 读者改一处，文档一个字不动
(etaf-md-set-attr '(card) '((:accent danger)))
```

页面：

```
┌ 缓存命中 ──────────────┐    accent=warning，来自文档
│ 图片和矢量按页面尺寸缩放。 │
└────────────────────────┘

┌ 缓存命中 ──────────────┐    读者写 (:accent danger) 之后
│ 图片和矢量按页面尺寸缩放。 │
└────────────────────────┘
```

### F.3 自定义容器：对应关系

| 环节 | 写在哪 | 值 | 谁读 |
| --- | --- | --- | --- |
| 文档 | 花括号 | `title`、`description`、`href`、`accent`、`text-align`、`width` | 校验 |
| 声明 | `:attrs` | `title` 必填，`accent` 默认 `neutral`，其余可省 | 校验、`describe-nodes` |
| 视图 | `attr` | 标题、摘要、强调 | 组件参数 |
| 组件 | `etaf-card` 的 `:title`、`:description`、`:variant` | 原样，不做映射 | 组件自己画 |
| 外壳 | 外层 `box` 的 `:width`、`:text-align`、`:on-press` | 原样 | 宽度、位置、点击 |
| 读者 | `set-attr '(card)` | `:accent danger` | 盖掉文档的值，见 10.3 |

用到的 `env` 函数：`attr`、`content`。没有 `surface`，因为底色归组件。

### F.4 内置语法：文档

```markdown
# 安装

## 依赖
```

解析结果：

| 项 | 第一个标题 | 第二个标题 |
| --- | --- | --- |
| 类型 | `heading` | `heading` |
| `level` | `1` | `2` |
| `number` | `"1"` | `"1.1"` |
| 子节点 | 一段文字节点 | 一段文字节点 |

井号不留痕迹，变成 `level`；整篇顺序算出 `number`。这个类型没有 `:name`，所以 `:::heading` 不存在。

### F.5 内置语法：定义与样式

定义与 10.1 相同，这里只看规则与页面。

```elisp
;; 包自带的样式规则，选择器一律是列表
(setq etaf-md-styles
      '(((heading)          (:font-weight bold) (:color heading) (:numbering decimal))
        ((heading :level 1) (:prefix "◆ "))
        ((heading :level 2) (:prefix "◇ "))))

;; 读者改两处
(etaf-md-set-attr '(heading) '((:color primary)))
(etaf-md-set-attr '(heading :level 2) '((:prefix "## ")))
```

页面：

| 情形 | 输出 |
| --- | --- |
| 不动配置 | `◆ 1 安装` / `◇ 1.1 依赖` |
| 读者改后 | 同上，主色，二级前缀变 `## ` |
| `numbering` 设成 `none` | `◆ 安装` / `◇ 依赖`，`number` 不写 |

### F.6 内置语法：对应关系

| 环节 | 谁写 | 值 | 谁读 |
| --- | --- | --- | --- |
| `## 依赖` | 作者 | 两个井号、一段文字 | 解析器 |
| `level = 2` | 解析器 | 2 | 规则选择器 `(heading :level 2)` |
| `number = "1.1"` | 派生 | 已经格式化好的字符串 | 视图，经 `attr` |
| `prefix`、`color`、`font-weight` | 读者属性 | `"◇ "`、令牌 `heading`、`bold` | 视图，经 `attr` |
| 前缀与章节号 | 视图 | `"◇ "` 与 `"1.1 "` | `text` 节点 |
| 标题正文 | 视图 | 子块的文字 | `content` 画成视图 |

用到的 `env` 函数：`attr`、`content`。

### F.7 两份对照

| 项 | `card` | `heading` |
| --- | --- | --- |
| `:name` | `"card"`，文档写得出来 | 没有，只能由解析器产生 |
| 文档属性 | `title`、`accent` | 没有 |
| 读者属性 | 没有，外观归组件 | `font-weight`、`color`、`prefix`、`numbering` |
| 派生属性 | 没有 | `level`、`number` |
| 选择器 | `(card)` | `(heading)`、`(heading :level 2)` |
| 入口 | `etaf-md-define-node` | 同一个 |

两例合起来只说明一句：**文档写语义，声明定契约，画法做翻译，读者改外观，任何事实只有一处承载者。**

### 6.18 站点组件目录

6.2–6.15 是文档正文里的容器；这一节是站点围绕正文写的组件。它们和一些提示块一样走定义与组件，不改渲染器。

| 类型 | 写法 | 作用 | 子块 |
| --- | --- | --- | --- |
| `home-box` | `:::home-box {title description href}` | 首屏大块：强调标题、摘要、行动链接与正文 | 任意块 |
| `image-card` | `:::image-card {src title description href}` | 图片在上，标题与说明在下 | 无 |
| `link-card` | `:::link-card {href title description}` | 整块可点的链接卡片 | 无 |
| `npm-badge` | `:::npm-badge {name version downloads}` | 一行静态 npm 徽章 | 无 |
| `qrcode` | `:::qrcode {text title}` | 可扫描的二维码；`qrencode` 缺失时保留文本 | 无 |
| `swiper` | `:::swiper` + `@slide {title}` | 一次显示一页，切换条给标题或页码 | `slide` |
| `code-tree` | `:::code-tree {height}` + `@file path` | 左边文件列表，右边选中文件的代码；`height` 是代码区行数，超出可滚动 | `file` |
| `npm-to` | `:::npm-to {tabs}` + 一个 `sh` 围栏 | 把一条 npm 命令换成各包管理器的写法并排成代码标签页 | 一个代码块 |

行内还有四个记号，由共享的 markdown 渲染器提供：`==高亮==`（可带 `{.warning}` 等配色）、`::图标名::`、`:kbd[Ctrl+B]` 与 `:badge[文字]{.tip}`。表情短代码 `:tada:` 本来就在 `etaf` 方言里。

`qrcode` 的绘制与图表一样不发生在渲染里：发布时读缓存，缺失时由定时任务调用 `qrencode`，画好后重发一次页面。`npm-to` 只改它支持的几条命令，其余原样复制。`swiper` 与 `code-tree` 的选择状态存在块状态里，换主题、改宽度都不丢。
