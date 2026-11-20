# 核心记录详解

本部分面对的每条机制都作用在一小组记录上，这些记录与它们描述的事物同寿：一个已挂载的 View 是一棵保留段树，一个保留段拥有一个 Ebox 节点，一个节点拥有计算样式与布局，而一次挂载把一个根绑到一个缓冲区。本章把这些记录集中在一处，逐条列出每个记录持有什么、程序怎样读取它。本章不定义接口；它点名的读取器都在各自的章节里定义。

## 记录与读取器

<!-- index: 记录; 读取器; 不透明把手 -->

这些记录的暴露程度不同。有的是不透明把手：程序拿到对象、保存它、把它传回其它函数、按同一性比较它，但从不直接读它的字段。缓冲区的挂载与 Component 的实例记录就是这样。另一些为消费者正当需要的事实发布了读取器。因此下面每张表有三列：记录里的字段、它的含义、读取它的公共接口——本版本没有导出读取器、只能通过行为看到的字段写「—」。

记录随其拥有者创建而创建、随其销毁而销毁。段与它们的 Ebox 节点在挂载或插入时创建，在身份存续期间一直保留；节点的计算样式与布局随节点变化就地替换；段落记录是被缓存、按策略淘汰的；挂载从 `ebox-mount` 存活到 `ebox-unmount-buffer` 或缓冲区死亡。本章不增添第二个事实来源：每个字段恰好由一个记录拥有，读取器交出的是快照或只读视图。

## 保留段记录

<!-- index: 保留段; key 身份 -->

挂载中的 Runtime 把 View 变成一棵保留段树。一个段记录它实例化自哪个 View 节点、它的种类（Host、Component、fragment、expression、branch、list、slot 或根），以及它在兄弟之间的 key。它还持有到父与子的链接、维护其动态内容的那一个响应式副作用，以及它的生命周期状态——新建、已挂载、已更新或已移除。

| 字段 | 含义 | 读取方式 |
| --- | --- | --- |
| 源 View 节点 | 创建这个段的结构形式 | — |
| 种类 | Host、Component、fragment、expression、branch、list、slot 或根 | — |
| Key | 兄弟间的身份 | key 身份决定复用；见[视图](views.md#身份) |
| 父与子 | 保留树的形状 | 经 ETAF 的 Host 内容与查询；Component 计数用 `etaf-runtime-instances` |
| 绑定副作用 | 那一个补丁本段自己的 Host 节点属性、文本载荷或子区域的副作用 | — |
| 生命周期状态 | 段是已挂载、已更新还是正在移除 | `etaf-on-mounted`、`etaf-on-updated`、`etaf-on-unmounted` |

身份规则是这条记录最重要的部分。段的种类与 key 持续匹配期间，它保持自己的身份、自己的 Component 实例与自己的 Ebox 节点，所以更新补丁已有节点而不是替换它。key 改变或缺失会释放旧段及其拥有的一切，下一次更新建造新段。

## 实例记录

<!-- index: 组件实例; prop 单元; setup Scope -->

每个存活的 Component 有一个实例记录，在 Component 第一次发布时创建、在 Component 被移除时销毁。它的字段是身份（定义与 key）、每个已声明 prop 一个响应式单元、当前调用及其解析后的 slot、为 setup 创建的 Scope、状态或具名 bindings 的值、保留的已渲染 View、prop 变化时重跑前端的那个副作用、注册的生命周期钩子，以及 Runtime 用来发布与退役它的记账标志。

| 字段 | 含义 | 读取方式 |
| --- | --- | --- |
| 身份 | 定义加上调用的 `:key` | Runtime 的实例表：`etaf-runtime-instances` |
| Prop 单元 | 每个已声明 prop 一个响应式单元 | prop 绑定与 `etaf-prop`；前端内部用 `etaf-current-prop` |
| 调用与 slot | 当前调用及其解析后的 slot 内容 | Component 内的 slot 访问 |
| Setup Scope | 拥有实例副作用与清理的 Scope | 释放行为；`etaf-on-scope-dispose` |
| 状态或 bindings | setup 状态，或具名 bindings 的值 | setup 状态用 `etaf-state`；binding 名字直接读 |
| 已渲染 View | 前端保留的输出 | — |
| 输入副作用 | prop 单元变化时重跑前端 | — |
| 生命周期钩子 | 挂载、更新与卸载回调 | `etaf-on-mounted`、`etaf-on-updated`、`etaf-on-unmounted` |
| 记账标志 | 发布与退役标志 | — |

[组件](components.md#实例记录)一章讲实例如何初始化与更新，[Runtime](runtime.md)一章讲存放全部存活实例、供内省的那张表。记录本身是不透明的：比较身份、统计实例数、断言一次更新复用了某个实例，才是这张表的用途。

## 节点记录

<!-- index: Ebox 节点; 作者身份; 保留内容 -->

每个 Host 段恰好拥有一个 Ebox 节点，在 Host 插入时创建、移除时释放。节点记录是这组记录里最大的：它持有作者与选择器事实（tag、id、classes、attributes、states、key、用户数据）、为它定样式而编译的声明、默认规则与 ECSS scope、交互属性、内容、父与子、计算样式与布局、缓存与脏状态。

| 字段 | 含义 | 读取方式 |
| --- | --- | --- |
| 作者与选择器事实 | tag、id、classes、attributes、states、key、用户数据 | 作者属性；ETAF 的 Host 语义用 `etaf-runtime-host-props-for` 与 `etaf-runtime-host-props-entries` |
| 样式输入 | 编译后的声明、默认规则、局部与共享 ECSS scope、活动环境 | `ebox-node-set-props`、`ebox-node-restyle`；[样式的实现](style-implementation.md)讲那一遍 |
| 交互事实 | help、pointer、hover、keymap、tab index、焦点组、焦点 scope、disabled 状态 | Host 属性；焦点与指针查询 |
| 内容 | 一个文本载荷，或一张已准备的图片 | `ebox-node-text-p`、`ebox-node-set-text`、`ebox-node-set-image` |
| 父与子 | 树链接，以分块子序列存储 | `ebox-node-parent`、`ebox-node-children`、`ebox-node-child`、`ebox-node-child-count`、`ebox-node-index` |
| 计算样式 | 计算样式记录，局部输入相等时共享 | 下一节的读取器 |
| 度量与布局缓存 | 度量过的文本、固有尺寸、上一次布局 | 经几何与区间；缓存本身没有读取器 |
| 脏状态 | 脏位、脏子节点、结构操作、浮层登记 | 通过 flush 行为观察；[增量更新与发布](incremental-updates-and-publication.md) |
| 滚动与挂载指针 | 节点的滚动偏移；根节点上指向所属挂载 | `ebox-node-scroll-offset`、`ebox-node-set-scroll`、`ebox-node-scroll-into-view`、`ebox-node-buffer` |

树读取器还提供与形状无关的查询：`ebox-node-root`、`ebox-node-ancestor-p`、`ebox-node-walk` 与 `ebox-node-buffer`。不读任何内部字段也能比较并遍历节点，而所有修改都经[增量更新与发布](incremental-updates-and-publication.md)一章列出的公共修改函数。

## 计算样式记录

<!-- index: 计算样式记录; 哈希合并; 来源 -->

计算样式记录是一个节点经过层叠后的归一化结果：全部解析后的值，外加布局需要的事实。它由 ECSS 计算值、父样式与节点 tag 构造；局部输入相等时共享同一个对象，因此几何比较可以依赖同一性。[计算样式接口](ecss-computed-style.md)一章定义它的读取器；记录的字段面恰好就是它们暴露的那些。

| 字段 | 含义 | 读取方式 |
| --- | --- | --- |
| 值 | 每个被覆盖属性的解析值，按 schema 顺序 | `ecss-computed-style-values`、`ecss-computed-style-value` |
| 自定义属性 | 声明的自定义属性及其解析值 | `ecss-computed-style-custom-properties` |
| active 与 specified 集合 | 哪些属性有值，哪些由声明指定过 | `ecss-computed-style-active-properties`、`ecss-computed-style-present-p`、`ecss-computed-style-specified-properties`、`ecss-computed-style-specified-p` |
| 声明事实 | 每个属性的声明、有效性与回退细节 | `ecss-computed-style-property-fact`、`ecss-computed-style-precedence-winner` |
| 来源 | 每个值从哪来：声明、初值、继承或自定义属性解析 | `ecss-computed-style-provenance` |
| 诊断 | 计算期间记录下的无效或延后计算 | `ecss-computed-style-diagnostics` |
| 布局热字段 | 字体面、继承的绘制、尺寸、边缘、边框、溢出、定位、flex 与 grid 事实、z 序、视口单位依赖与布局键 | — |

热字段正是这条记录与 ECSS 值映射并存的原因：样式 pass 把它们一次填好，布局、绘制与比较就不必每次 flush 都从值里重新推导。需要它们的程序通过节点的行为去问——一次几何查询、一次 restyle——而不是去读记录。

## 几何记录

<!-- index: 几何记录; 边框盒; 绘制区间 -->

布局过的节点保存它解析后的几何：margin、border 与 padding 边缘，边框盒与内容盒尺寸，可见高度，滚动偏移，内容高度，以及堆叠或定位容器的布局项。

| 字段 | 含义 | 读取方式 |
| --- | --- | --- |
| 边框盒 | 布局坐标里的 `:x`、`:y`、`:width`、`:height` | `ebox-node-geometry` |
| root 行 | 只取纵向位置 | `ebox-node-root-line` |
| 绘制区间 | 节点画出的缓冲位置 | `ebox-node-bounds`、`ebox-node-position`、`ebox-node-at` |
| 解析后的边缘与盒 | margin、border、padding、内容盒与内容尺寸 | — |
| 可见高度、内容高度、滚动偏移 | 内容可见多少、滚到了哪里 | 偏移用 `ebox-node-scroll-offset` |
| 布局项 | 堆叠或定位容器里已摆放的子节点 | — |

关于这条记录有两条规则要讲准确，因为文本节点同时落在两种情况里。作为自己的布局项布局的文本节点——例如 `row` 或 `column` 的直接子节点——有边框盒、会报告几何。行布局由所属 `box` 持有的匿名段落拥有的文本节点没有自己的边框盒：`ebox-node-geometry` 与 `ebox-node-root-line` 对它回答 nil，它画出的区间由 `ebox-node-bounds` 报告。和所有布局事实一样，这条记录是快照：节点布局之后它才可用，之后的修改在下次 flush 时改变它。

## 段落记录

<!-- index: 段落记录; 缓存键 -->

EKP 不把它的工作存进 Ebox 树。一次排版调用产生由布局拥有的段落记录：每段、每个布局上下文一条，存放 box 向量及其宽度、类型与胶值，断字位置，使行度量成为常数时间的前缀数组与按类别计数器，生效间距参数的快照，以及断点搜索与语义方案的结果缓存。

记录的键覆盖一切能改变段落成形方式的东西——字符、它们的文本属性区间、探测到的字体、宽度上下文、断字语言、对齐与布局策略——键按结构比较，所以输入相等就共享一条记录，哈希碰撞无法把两段混为一个。它是缓存而不是公共对象：本版本没有为它的字段导出读取器，释放缓存的公共方式是 `ekp-clear-caches`。`ekp-layout-plan` 返回由记录构造的语义方案，方案的读取器见[编程接口](ekp-programming-interface.md)一章。[实现](ekp-implementation.md)一章讲填充并消费这条记录的流水线。

## 挂载记录

<!-- index: 挂载记录; 行锚点; 输入会话 -->

一次挂载把一个根节点绑到一个缓冲区。它由 `ebox-mount`（或 `ebox-render-to-buffer`）创建，由 `ebox-unmount-buffer` 或缓冲区被杀释放。所有限定在单个已挂载缓冲区上的东西都在这里：根、视口、使增量写入成为可能的行锚点与记住的已写行片段、flush 计数器与最新更新报告、观察者、保存并恢复的显示设置、焦点状态及其记忆、hover 与激活状态，以及活动的输入会话。

| 字段 | 含义 | 读取方式 |
| --- | --- | --- |
| 根 | 已挂载的根节点 | `ebox-buffer-root` |
| 缓冲区 | 显示这次挂载的缓冲区 | 把手传给每个限定挂载的函数 |
| 视口 | 固定或由窗口推导的宽与高 | `ebox-mount-viewport`、`ebox-mount-set-viewport` |
| flush 计数器与报告 | 写了多少次，最近一次写了什么 | `ebox-mount-flush-count`、`ebox-buffer-update-report`、`ebox-buffer-set-observer` |
| 行锚点与已写片段 | 增量行替换背后的保留记账 | — |
| 保存的显示设置 | 挂载时安装、卸载时恢复的缓冲区局部设置 | — |
| 焦点状态与记忆 | 聚焦的节点、它的锚点与按组的记忆 | `ebox-focused-node`、`ebox-focus-within` |
| Hover 与激活状态 | 交互属性使用的指针状态 | Host hover 属性与指针查询 |
| 输入会话 | 原生编辑会话（若有） | `ebox-input-session-node`、`ebox-input-active-p` |
| 队列标志 | 挂载是否在等一次 flush | — |
| 挂载对象本身 | 限定挂载的一切所用的不透明把手 | `ebox-buffer-mount` |

`ebox-buffer-mount` 返回的挂载对象是本章不透明那一类：调用方保存它、与 nil 比较来判断存活、不再把它传给别处——限定挂载的函数接收的是缓冲区。这条记录的读取器就是上表的函数；它的内部字段驱动着[增量更新与发布](incremental-updates-and-publication.md)一章所述的 flush 流水线。

## 记录之间的所有权

<!-- index: 记录所有权 -->

这组记录构成一条严格的拥有链：Runtime 拥有段树，一个段最多拥有一个 Component 实例与最多一个 Ebox 节点，一个节点拥有一个计算样式与一条几何记录，一次挂载拥有一个根节点与一个缓冲区，而 EKP 把它的段落记录放在 Ebox 树旁边而不是树里。每个事实恰好有一个拥有者，这正是读取器可以很小、更新可以保持局部的理由：改变一个值只碰拥有它的那条记录与拥有该记录的段，不会碰到别处的第二份拷贝。
