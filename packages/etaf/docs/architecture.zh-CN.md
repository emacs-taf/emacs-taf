# ETAF 架构

本文是 ETAF 已实现运行时的维护者契约，说明职责、依赖方向、数据流和不变量。用户用法写在 [ETAF 参考手册](https://etaf.top/zh-cn/introduction/)，权威公共 API 清单在 [`../etaf.el`](../etaf.el) 的 Commentary 中。

## 1. 职责栈

ETAF 是文本 UI 的公共应用框架。它保持小的作者模型：应用声明 View 与 Component，把状态放进响应式 source，并通过 Host 回调接收事件。更底层的事实由更底层拥有。

```text
ecss → ebox → etaf → etaf-ui → applications
```

- **ECSS** 负责 selector 匹配、cascade 与规范化样式值。
- **Ebox** 负责保留节点、计算后样式、布局、焦点、原生输入会话、行合成以及直接修改 Emacs buffer。
- **ETAF** 负责 View 与 Component 语法、响应式绑定、Runtime 生命周期、Context、Theme、Behavior、Action、Data、Resource 和公共 Host 查询。
- **etaf-ui** 负责可复用 ETAF Component，只依赖 ETAF 公共 API。
- **应用** 组合 Component 并持有业务状态。应用不直接调用 Ebox；缺少的底层能力先通过 ETAF 暴露。

因此 Ebox 是 ETAF 背后的内部引擎。ETAF 可以维护 Host 到节点的索引用于事件和查询，但物理节点树、布局缓存和 buffer 修改都属于 Ebox。

Ebox 的显示稳定通知把 `etaf-display-metrics` 与 Runtime 视口放在同一个响应式 batch 中发布。准备原生图像行的应用读取这些度量并更新自己的图像提供者。ETAF 不重建组件树，也不接管提供者的像素内容。

## 2. 维护者模型

| 概念 | Owner | 维护的事实 |
| --- | --- | --- |
| View | `etaf-view` / compiler | Host 与 Component 结构、字面值、可执行空洞 |
| Segment | Runtime | 保留 identity、父子关系、一个绑定 owner |
| Host segment | Runtime + Ebox | 一个保留 Ebox 节点、语义属性、Host 引用 |
| Component instance | Runtime | Scope、props、bindings、setup 结果、slots、生命周期钩子 |
| Reactive source | `etaf-reactive` | 值、依赖边、阶段队列、Scope 所有权 |
| Ebox node | Ebox | 计算后样式、几何、焦点/输入事实、合成行 |
| Data Controller | `etaf-data` | query、page、items、status、error、reconciliation state |

Host segment 拥有作者声明的 Ebox 节点。fragment、expression、branch、list、slot、Component 和 root segment 组织子节点，或持有维护它们的 effect。只有多根输出或临时界面需要 Runtime 画布 wrapper；普通 Component 结构不会增加不可见的 Ebox wrapper。

快捷键帮助是原 Runtime 拥有的临时 segment，使用与应用内容相同的构建、patch、释放及 Component 生命周期。它继承打开位置 Host 的 Context，并与原节点共享视口大小的画布，因此短根节点和纯 text 应用也能显示帮助。打开与关闭不重建应用 Component 或业务状态，画布重新挂载时节点滚动位置仍保留。根节点替换把帮助节点放在同一次子列表更新中，保留其原生输入投影。卸载同时释放应用和临时 segment。有效键快照与返回位置由核心拥有；可选的目录呈现器只返回 View，不创建其他 buffer 或 Runtime。捕获前，有效按键作用域内最近启用的 `:on-help-open` Host 可准备应用状态，例如暂停持续活动；这一查找止于模态边界。关闭不逆转应用策略。

## 3. View 编译与保留 segment

`etaf-view` 把结构 form 展开为 View 值。编译器会在可识别处把静态结构与可执行空洞分开：

- 字面量属性与字面量文本成为静态节点事实；
- 可执行属性值成为属性程序；
- text Host 内的 `(expr FORM)` 成为文本程序；
- 结构位置的 `expr`、`:if`、`:else-if`、`:else` 和 `:for` 成为动态区域；
- Component 调用被规范化为 props 与 slot 输入。

挂载时从 View 创建一棵保留 segment 树。只要 key 与 kind 继续匹配，segment 就保持身份。`:key` 在同级中选择 identity：放在 Component 上保留 Component instance，放在 Host 上传给 Ebox node。keyed list 按 key 比较、patch 匹配的 segment，并把保留的 Ebox 节点移动到新顺序。

静态子树只构建一次。动态位置由绑定到所属 segment 的 reactive effect 表示。属性绑定调用 `ebox-node-set-props`；文本绑定调用 `ebox-node-set-text`；结构区域只 patch 自己的子列表。绑定不会重建无关 segment。

## 4. Component

`etaf-define-component` 注册一个 Component 定义，并记录声明指纹与规范化库路径；同一路径的 `.el` 和 `.elc` 属于同一库。重载未改变的声明会复用原定义，不使已编译 View 失效，也不重置保留实例，因而支持 package.el 安装后从源码到字节码的重载。原定义捕获的值同样保留。普通求值没有库身份；改变声明或从另一库定义同名组件，仍须先销毁相关 Runtime，再通过 `etaf-component-redefine-run` 显式重定义。

挂载的 Component instance 只初始化一次：

1. 分配 Component Scope；
2. 按声明顺序创建命名 `:bindings`；
3. 在实例环境中运行可选 `:setup`；
4. 编译并绑定 `:view`，或在实例中执行 `:render`；
5. 记录生命周期钩子与 slot 访问。

声明的 props 是每个实例自己的响应式信号。View 与回调通过实例环境读取当前 prop 值，setup 可以用 `etaf-prop` 获得可跟踪输入。prop 更新会 patch 实例输入；只有读取了变化值的绑定或区域会重新运行。`:render` Component 保留其文档化的整输出行为，但输出仍在同一棵保留 segment 树中 patch。

生命周期钩子在让 owner mounted、updated 或 unmounted 的可见 Runtime commit 之后运行。钩子失败会在 commit 后报告；不会回退已经可见的 Ebox 状态。错误边界仍然是包住用户代码的显式函数边界。

## 5. 响应式核心与 commit

`etaf-reactive` 提供 refs、惰性的 push-pull computed、effects、untracked reads 和 Scopes。写入会立即更新 source 并标记 observers。排队 effect 分三阶段运行：

1. **pre** watchers；
2. **render** Runtime bindings；
3. **post** watchers。

`etaf-call-with-batch` 与 `etaf-batch` 把 effect delivery 延迟到最外层 batch 结束。batch 外的一次写入会同步 drain。pre 与 render effects 稳定后，drain 调用 Runtime commit；post watchers 在可见 commit 后运行。

Runtime commit 在任一保留节点发生变化时执行一次 Ebox batch flush。Ebox 随后只写入受损 buffer 区域。每次 commit 改变已挂载 buffer 时，Runtime 的 `etaf-runtime-revision` 增加一次。`etaf-runtime-flush` 在可行时 drain 一个已挂载 Runtime 的待办工作，并返回该 revision。

Scope 拥有 effects、computeds、watchers 和 cleanup。释放 Component Scope 时先停止 child Scopes 与 effects，再运行 cleanup。已停止的 Scope 不能再接收工作。

viewport 是挂载子树排版所依据的区域。挂载本身发布 Runtime viewport
（`etaf-runtime-viewport`）；`etaf-viewport-region` 把内容包进一个 Host，该 Host
已提交的边框盒就成为渲染树下所有 Component 的 viewport。区域按 Runtime 以 Host
引用索引，并在 Ebox 每次 flush 之后用 `etaf-host-ref-size` 重新发布，因此读取方
依赖的是已提交几何而不是猜测。解析沿 Component segment 的祖先链，而不是
Context：经 slot 传入的内容保留调用方 Context，包装组件内 provide 的值到不了
它。在 setup 中创建的 watcher、effect 与 computed getter 会捕获实例的求值环境，
并在之后的运行中重新进入，因此读取方在响应式重跑后仍持有自己的组件环境。

动画是同一张图里的时间。`etaf-transition` 与 `etaf-animation-frames` 通过
普通 ref 发布值，因此一个 tick 只产生一次响应式 batch、一次 Runtime commit
和一次 Ebox flush，不存在第二条绘制路径。共享时钟只在有动画运行时存在，
归 Scope 所有的动画随 Scope 停止。transition 观察自己的 target 并从当前
显示值重新开始，所以中断是连续的。

## 6. Ebox 保留引擎

ETAF 在挂载或插入时为每个 Host 创建一次 Ebox 节点。Ebox 在 Host segment 移除前保留该节点的样式、布局与 buffer 位置。Host 属性与文本变化都是局部节点修改。

Ebox 提供：

- ECSS 计算后样式与 Host 默认值；
- relayout boundaries，固定尺寸盒子会阻断布局传播；
- row、column、flex、grid 与文本内容的行合成；
- 只针对变化 buffer 行的直接局部写入；
- 原生焦点、指针、keymap、drag 与输入会话集成。

text Host 只包含一个文本 payload。ETAF 校验 payload 并保存语义 Host props；Ebox 负责 display string、image display property、几何和交互事实。Grid 与 flex Host 映射为 Ebox layout node；ETAF 不复制布局算法。

有些应用绘制的文档存在别处，就地编辑需要从画布格子回到源文本。`etaf-projection` 以查询回应这个需求：给出 Runtime 与每个 Host 的 `(REF . (SOURCE-START . SOURCE-END))`，它从当前绘制返回若干 run `(DISPLAY-BEG DISPLAY-END SOURCE-BEG SOURCE-END)`。它是查询而非渲染模式，没有源区间的渲染不付出成本，答案也不会描述更早的一帧。

一个 run 里一格画布对应一个源字符。区间若还带着块尾换行，或带着标题中被折叠掉的前缀，范围就摊到不代表任何字符的格子上，此后每个光标位置都偏一个字符。因此条目测量 Host 的 text 叶子，不测量外层 box，因为 box bounds 还包含 padding、border 与行尾换行。run 区间是半开的：源偏移正好落在某个 run 的末端时，它是该 run 在本行的末尾位置；两段之间的画布位置则指向下一段的开头，这样在空行上编辑不会回退到上一块。

## 7. 事件、焦点与输入

事件通过已提交的 Host 引用进入。Runtime 把 Host ref 解析为保留 Ebox 节点和 handler 表，然后在 ETAF batch 内 dispatch 回调。press capture 回调沿已提交祖先 ref 运行。

Ebox 负责原生定位、point 保持、焦点顺序、drag 跟踪和输入会话。ETAF 在校验 Runtime 与 Host 引用后，把 `etaf-activate`、`etaf-focus`、`etaf-focus-next`、`etaf-call-with-input` 和 `etaf-input-begin` 等公共操作转换为 Ebox 操作。键盘激活先把 point 恢复到真实焦点，再解析该节点的原生 keymap；激活转发也覆盖优先于 emulation map 的文本属性 keymap，不让偏移后的 point 选择另一个控件。指针激活保持点击目标；没有焦点时仍按 point 定位。

`ebox-input-begin` 在 Ebox 的隐藏编辑 buffer 中编辑 text Host 的值，使 Emacs 持有按键、point、selection 与 undo，同时 Host 保持自身布局。会话期间发布照常进行：组件在 `:on-change` 中把每个值同步到 ref，把同一个值发布回 Host 不产生任何效果。

键盘输入由 `etaf-keys` 中的作用域按键层处理。每个 Runtime buffer 持有一个 emulation keymap，包含所有已提交 Host 在 `:keys` 中列出的事件；每个绑定是按键时才解析的 menu-item filter。解析从 Ebox 焦点（或 point）开始；起点不在最内层可见的 `:focus-scope modal` 节点内时改从该节点开始，然后由近及远遍历已提交的 Host 祖先，并在第一个 modal 或 `:key-scope local` Host 之后停止。第一个启用的条目胜出；否则应用框架默认值（Escape 交给最近的 `:on-dismiss`，`?` 打开只读帮助，方向键交给已聚焦 separator 或 slider 的 `:on-drag`），其余按键继续落到其他 keymap。这一遍历是唯一的向外按键传播；普通回调仍然不冒泡。方向键不再落到 Ebox：`etaf-direction` 先运行最近的 Host `:on-direction` 处理器，再步进已聚焦的 separator 或 slider，然后把 Ebox 的空间移动限制在当前区域，到边界时进入相邻区域的入口；Tab 分发给 `etaf-focus-next`／`etaf-focus-previous`。`etaf-set-direction-scheme` 在检查 Host 声明与区域提示的冲突后切换方向键与 Vim 映射。这些命令移动的焦点仍由 Ebox 拥有。焦点组、modal 限制和空间方向导航由 Ebox 负责，按键层本身从不移动焦点。键盘拖拽通过 `etaf-drag-step` 复用指针 `:on-drag` 路径，使 Behavior 只保留一种手势实现。

局部键盘边界从同一焦点／point 祖先链派生，不维护另一份应用模式状态。它同时限制关闭、方向处理器、区域邻接、帮助和命令面板控件。Tab、方向别名与首末键把该子树根交给 Ebox 导航，不复制排序或焦点算法。未绑定的打印键和无人处理的 Escape 在边界处停止。原生编辑保留自己的绑定，指针及显式焦点／区域跳转仍可离开局部边界。可见模态范围仍限制来自其外部的入口。

区域导航是在作用域按键之上加的一层。`etaf-regions` 读取已提交的 `:region` 声明（稳定 id、名称、提示键、默认入口和声明的邻接关系），推导它们的 Host 祖先，记住每个区域最后被接受的焦点位置；没有声明的邻接关系时，用已提交几何解算方向邻接。`etaf-region-select`（Runtime buffer 中的 `M-g`）读取选择，`etaf-region-focus` 为应用键执行同样的跳转；焦点仍由 Ebox 拥有。

## 8. Data、Resource 与 reconciliation

Data 是 ETAF 核心能力。Data Source 提供 `:load`、可选 `:mutate` 和可选 `:dispose`。Data 与 Resource 共用异步 start、completion、cancellation、timeout 与 late-result protection。

Data Controller 拥有 query、pagination、item collection、selection、status、error 和 mutation outcome。Reconciliation 状态包括：

- `reconciliation-pending`：已提交的外部写入等待 reload；
- `reconciled`：接受的 reload 成功；
- `reconciliation-error`：该 reload 失败；
- `rolled-back`：source 报告没有发生外部写入；
- `external-unknown`：ETAF 无法证明外部结果。

外部不确定性不代表本地 rollback。重试 reconciliation 会通过 Data Source 刷新，不会重复写入，除非 source 明确选择这样做。

## 9. 保留 Host 更新边界

`etaf-runtime-update-host-content` 与 `etaf-runtime-update-host-contents` 是视频等高频显示 surface 的公共逃生口。它们先校验全部 Host ref，再在一个 Ebox batch 中设置保留 text node，并增加 Runtime revision。

`etaf-runtime-update-host-geometry` 与 `etaf-runtime-update-host-geometries` 为 position、size、layer 等 Ebox 几何事实提供同样的保留边界。它们直接 patch Host node，并把权威应用状态留给调用方。调用方应先更新自己的 ref，使下一次普通 View 绑定与显示一致。

`etaf-runtime-refit` 通过 `ebox-mount-set-viewport` 更新已挂载 viewport。Viewport 变化是 Ebox layout 工作；ETAF 不通过重建 View 树来调整 buffer 尺寸。

## 10. 不变量

1. **单一保留所有权。** 一个已挂载 Runtime 拥有应用 segment 和至多一个临时帮助 segment，共享一棵保留 Ebox node 树。Host/node map 只是这些 segment 的索引，不是第二份权威。
2. **一个可见写入边界。** Runtime commit 至多执行一次 Ebox flush，该 flush 只写一次变化的 buffer 区域。
3. **绑定所有权。** 每个细粒度绑定只拥有一个 Host node 属性集、一个文本 payload 或一个动态子区域。它可以读取多个响应式 source，但只能 patch 自己的目标。
4. **Keyed identity。** 稳定 key 保留 segment、Component Scope、Host ref 与 Ebox node。key 缺失或变化时释放旧 owner。
5. **Scope 所有权。** Effects 与 cleanups 属于其 Scope。释放时先停止响应式工作，再释放外部资源。
6. **渲染无副作用。** 渲染和绑定求值不能写应用状态。写入属于事件、Action、watch、Effect、Data/Resource completion 或显式 batch。
7. **Ebox 权威。** 布局、焦点、原生输入和 buffer 文本从 Ebox 查询。ETAF 暴露公共适配器，但不维护这些事实的平行副本。
8. **公共边界。** 应用与目录 Component 只使用 ETAF 公共 API。`ebox-` 前缀调用保留在 ETAF 或 Ebox 拥有的包内。

## 11. 设计理由

保留式设计在结构创建时记录依赖。状态写入沿依赖边到达拥有受影响节点的绑定，然后 Ebox 只更新受损布局与 buffer 行。这让普通文本、样式和几何变化不再重新计算整棵树，同时保留声明式 View 语法。

让 Ebox 成为唯一布局与 buffer 引擎，可以避免重复几何、焦点和输入状态。让 Component 成为唯一可复用 ETAF UI 单元，可以避免平行的 widget/control 模型。让 Data 与 Resource 位于同一个响应式 batch 边界之上，可以让异步 completion、事件回调和本地状态写入都通过同一条可见 commit 路径发布。

需要新能力时，扩展已经拥有相关事实的最小 owner：布局与原生输入属于 Ebox，公共 Host 生命周期属于 ETAF Runtime，依赖属于 reactive Scopes，请求属于 Data/Resource，可复用组合属于 Component。
