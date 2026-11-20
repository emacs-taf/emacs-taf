# 不变式总表

本部分的机制——编译、响应式、保留布局、增量写缓冲区——之所以可以放心使用，是因为它们维持着一小组不变式。一条不变式说出框架运行期间始终为真的一个事实、把它保持为真的那一层，以及它不被维持时会出什么问题。本章把 ETAF 与 Ebox 的不变式收进两张表。本章不定义接口；每一条都能通过「检查」列点名的公共接口观察到。

## 不变式怎么被维持

<!-- index: 不变式; 拥有者; 脏位失效 -->

三个习惯让这张清单保持很短。第一，每个事实恰好有一个拥有者：Runtime 拥有段树，段拥有它的节点，节点拥有计算样式与布局，挂载拥有它的缓冲区。因此一条不变式总能找到该负责的一层、也该在该层修。第二，派生状态从变化失效，绝不从缓冲区重新推导：公共修改设置脏位，flush 重算脏位覆盖的部分，所以缓存无法与它所属的树不一致。第三，公共边界本身是机械检查的——工作区的结构与 API 门禁读取 provider 源码，消费者调用未列出的符号会被拒绝，所以这条边界不是要记住的约定。

「检查」列给出的是各包验收清单里代表性的场景，而不是全集；场景名来自 provider 仓库，怀疑某条不变式时，第一个该看的就是失败的场景。

## ETAF 的不变式

<!-- index: 保留树; 写边界; 绑定所有权; keyed 身份 -->

| 不变式 | 由谁保证 | 违反后果 | 检查 |
| --- | --- | --- | --- |
| 单一保留树：一个已挂载 Runtime 恰好有一棵段树与一棵 Ebox 节点树，它的 Host 表与实例表都只是指向这棵树的索引。 | 挂载与卸载生命周期；提交把保留树当作唯一权威。 | 一个节点有两个拥有者，或查询从挂载已不持有的树回答。 | *etaf-view-keyed-list-retains-instances*、*etaf-view-unmount-and-kill-release-runtime* |
| 一个可见写边界：一次提交至多做一次 Ebox flush，pre 或 render 副作用失败会在任何缓冲区写入之前丢弃整个事务。 | 提交日志与 Ebox 批处理；[一次更新的完整追踪](update-trace.md)走这条链。 | UI 处于半更新状态，或修订号与缓冲区不一致。 | *etaf-view-batches-writes-into-one-commit*、*etaf-data-completion-publishes-atomically* |
| 绑定所有权：每个细粒度绑定恰好拥有一个 Host 属性集、一个文本载荷或一个动态子区域，并且只能补丁那个目标。 | Runtime 按站点编译绑定；没有重跑的副作用不碰它的目标。 | 两个绑定互相覆盖输出，或一次更新重建了没有发生改变的子树。 | *etaf-selector-notifies-only-the-changed-keys*、*etaf-component-tracked-props-update-without-setup* |
| keyed 身份：种类与 key 稳定时保留段、它的 Component 实例、它的 Host 引用与节点；key 缺失或改变会释放旧拥有者。 | 和解在保留任何东西之前比较种类与 key。 | 重排时状态重置，或被移除的 keyed 项继续运行。 | *etaf-view-keyed-list-appends-and-clears*、*etaf-view-component-props-update-retained-instance* |
| Scope 所有权：副作用与清理属于它们的 Scope，释放先停掉响应式工作、再放掉外部资源。 | Scope 按顺序停掉子级与副作用；已停的 Scope 不接受新工作。 | 已释放的拥有者继续发布，或清理与仍在运行的副作用撞车。 | *etaf-scope-stop-releases-effects-and-owned-children*、*etaf-data-owner-scope-disposes-controller*、*etaf-async-mounted-owner-unmount-invalidates-late-work* |
| 无渲染副作用：渲染与绑定求值不得写应用状态。 | 写入属于事件、Action、侦听器、副作用、异步完成与显式批处理；Runtime 拒绝渲染期间的 ref 写入。 | 重渲染循环，或出现无人能解释的值。 | Runtime 用 `etaf-render-side-effect-error` 拒绝；其余靠评审 |
| Ebox 权威：布局、焦点、原生输入与缓冲区文本都从 Ebox 查询，ETAF 不保留并行拷贝。 | Host 查询读已提交的 Ebox 事实；ETAF 只存索引与语义属性。 | 查询从陈旧的 ETAF 状态回答，或焦点与布局不一致。 | *etaf-events-host-queries*、*etaf-events-retained-host-updates* |
| 公共边界：应用与目录组件只用 ETAF 公共 API；Ebox 前缀的调用留在 ETAF 或 Ebox 自己的包里。 | 工作区的结构门禁与 API 门禁读取源码；手册自己的门禁拒绝正文里的私有名字。 | 门禁失败；行为也许仍然能用，但接口契约已破。 | `make api-check`、各包的 `check` 目标 |

## Ebox 的不变式

<!-- index: 保留权威; 损坏; 缓冲区状态 -->

| 不变式 | 由谁保证 | 违反后果 | 检查 |
| --- | --- | --- | --- |
| 保留节点树是事实来源；缓冲区文本是输出缓存。 | 每次 flush 恰好重写损坏覆盖的行；[增量更新与发布](incremental-updates-and-publication.md)一章解释唯一有意的例外：尚未被更新触及的外来编辑。 | 缓冲区与树在一行无人编辑的内容上不一致。 | *ebox-node-set-text-updates-buffer-like-fresh-render* |
| 一个节点至多有一个父；分离的根可以被渲染或挂载，已挂载的后代必须留在自己的根树里。 | 插入拒绝已经有父的子节点。 | 一个节点处在两棵树里，损坏与几何从此有歧义。 | *ebox-node-insert-remove-move-and-replace-children-update-order* |
| 只有公共修改改变保留节点；内部缓存由脏位失效，绝不通过读缓冲区文本失效。 | 每次修改标记它改变了什么、以及可能必须重算什么。 | 缓存保留了本该被修改清掉的值。 | *ebox-node-mutation-errors-leave-buffer-at-last-successful-render* |
| 一个计算样式属于构造它所用的父样式、声明、选择器事实与 scope 环境。 | 样式 pass 在节点的样式位置位、没有计算样式、或某个祖先样式改变时重算它。 | 输入不同的两个节点共享同一个样式，或继承落后于变化。 | *ebox-parent-restyle-updates-inheriting-descendants*、*ebox-inline-ecss-cascades-to-descendants* |
| 纵向几何按行、横向几何按像素。 | 布局把高解成整行、宽解成像素，用显示空格做精确像素填充。 | 行之间错位，或像素列对不齐。 | *ebox-render-wraps-aligns-and-measures-cjk* |
| 同一宽度约束下的 clean 节点保留自己的布局与已合成行缓存；dirty 节点或者记录精确损坏，或者只损坏形状改变的最小边界。 | 脏位在 flush 之前把样式、布局、绘制与后代变化分类。 | 多余的重新布局与重绘，或未被触碰的行出现在更新报告里。 | *ebox-with-batch-flushes-mutated-mount-once*；更新报告的行范围 |
| 缓冲区写入保留无关的缓冲区状态：read-only 标志、undo 列表、modified 标志、point 与窗口起点。 | Ebox 在写入期间抑制 undo 与修改钩子，并在卸载时恢复保存的显示设置。 | 一次重绘移动了 point，或污染了 undo 历史。 | *ebox-first-content-keeps-point-and-window-start-at-top*、*ebox-mounted-rows-own-wrapping-and-restore-buffer-settings* |
| 图片解码与外部转换器执行只发生在准备阶段，绝不发生在布局或缓冲区写入期间；准备结果按来源身份、尺寸与帧缓存，缓存有界。 | 准备在布局之前运行并保存结果；布局与绘制复用它们。 | 一次 flush 卡在解码上，或同一张图片每次绘制都被重新解码。 | *ebox-image-identical-preparation-reuses-a-screenful-of-images*、*ebox-image-cache-stays-bounded-and-usable-under-churn* |
| 图形图片的一行是一个 glyph，显示一条全宽切片；在盒或浮层边缘截断时，切片变窄而不是被替换成空格。 | 图片行以整条切片输出，边缘只裁窄切片。 | 图片在盒边缘可见的部分消失。 | *ebox-image-slice-cut-at-a-box-edge-keeps-its-visible-part* |
| 私有模块可以变化；消费者只 require `ebox`、只用 `ebox.el` 里记录在案的符号。 | 工作区的结构门禁与 API 门禁。 | 门禁失败，而运行时看起来仍然能用。 | `make api-check`、各包的 `check` 目标 |

## 看起来像被违反时

<!-- index: 虚惊; 外来编辑; 失败提交 -->

有两种日常情形会冒充违反，值得在找缺陷之前先排除。第一是缓冲区被外部编辑过而与树不一致：Ebox 只在下一次 flush 触到那一行时修复它，所以未被触到的行在此之前可以不一致。第二是写入根本没到缓冲区：相等的 ref 值、没有损坏的提交，或失败后被回滚并搁置的副作用。更新报告与修订号把三种情况区分开——没有报告、修订号也没变，说明什么都没发布；有新报告，则报告点名了确切写了哪些行。

真的违反要从拥有它的那一层诊断，而不是从症状。陈旧的 Host 查询指向 Runtime 的索引或一个已释放的拥有者；节点被抢走指向插入或和解；样式落后指向样式 pass 的脏位；缓冲区状态被改写指向写入路径。找到拥有者就在那里修：绕过坏拥有者的读者会增添第二个事实来源，把一次违反变成两次。
