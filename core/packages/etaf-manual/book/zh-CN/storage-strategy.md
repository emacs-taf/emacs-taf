# 存储策略

数据层给应用四个存放状态的位置，选得是否合适主要取决于寿命与所有权。本章作为本部分的收尾比较这四个位置，说明各部分如何组合——键、查询、分页、刷新、失败——并列出迁移与释放时该做什么。它不定义新接口：点名的每个机制都在它链接的章节里定义。

## 应用状态的四个存放位置

<!-- index: 存储选择; 应用状态; 持久化 -->

| 位置 | 寿命 | 真相来源 | 适用 |
| --- | --- | --- | --- |
| 组件 ref 与 Context（[响应式系统](reactivity.md#ref)、[Context](context.md)） | 实例的 Scope | 应用自身 | 界面状态：展开、输入、临时选择 |
| 一个 Resource（[Resource](resources.md)） | 一个 Scope，如组件 | 外部 loader | 单个异步值：配置、当前用户、快照 |
| 内存 Data Source 加 Controller（[Data Source](data-sources.md#内存-source)、[Data Controller](data-controllers.md)） | Controller 的 Scope | 应用进程，退出即失 | 会话列表：搜索结果、本地索引 |
| SQLite Source 加 Controller（[SQLite 后端](sqlite-backend.md#sqlite-data-source)） | 数据库文件 | 数据库，经由已提交事务 | 必须持久、需要查询或受约束的数据 |

四个问题决定取舍：值要活多久、谁拥有它、是否必须跨重启、是否需要查询、计数或分页而不只是显示。

## 按寿命与所有权选择

<!-- index: 组件状态; Runtime 状态; source 所有权 -->

只被一个组件实例使用、并应随它消亡的状态放在它的 ref 与 `:bindings` 里；它们的生命周期就是实例的 Scope（[组件](components.md)）。被同一棵已挂载树多处共享的状态放在 Runtime 拥有的地方，让它随树释放，而不是被闭包一直引用（[Runtime](runtime.md)）。由应用之外产生、因而可能是异步的值放进 Resource，它的状态、值与错误就是读取者需要的全部状态（[Resource](resources.md#resource-模型)）。应用自己在会话期拥有的列表放进内存 source 加 Controller；同一个列表需要跨重启或由数据库查询时，把 source 换成 SQLite 版本，Controller 代码不变（[SQLite 后端](sqlite-backend.md#sqlite-data-source)）。

cache 按设计从不是真相：它是显示捷径，由策略决定何时把旧副本与新鲜回复比较（[List Cache](list-cache.md#缓存模型)）。让 backend 的回答保持权威，只让 cache 缩短「有东西可看」之前的等待。

所有权必须单一。一个 Controller 拥有一个 source 并运行它的 `:dispose`；用 `etaf-data-source-capabilities` 构造的适配器共享它组合自的 source 的存储，因此不要把底层 source 交给第二个 Controller（[Data Source](data-sources.md#能力快照与组合)）。所有者消失时——组件卸载、会话停止——Controller 随之停止，source 释放它持有的东西。

## 键、查询与分页

<!-- index: 身份; item key; 查询; 分页 -->

用户能选择的每条记录都需要稳定身份：内存 source 的 `:id-key`、SQLite 表的主键，作为 `:item-key` 暴露给 Controller（[Data Controller](data-controllers.md#选择)）。选择保存身份而不是列表位置，因此选中一行再加载另一页不会指错条目；`etaf-data-selected-item` 只在当前页里找身份，这是刻意的——选择可能比它产生的页面活得久。

查询只表达等值，形状决定 source 能做什么：内存 source 接受谓词、搜索字符串、plist、alist、精确值或 nil，SQLite source 把 plist 与 alist 等值翻译成绑定参数的 `WHERE`（[Data Source](data-sources.md#内存-source)、[SQLite 后端](sqlite-backend.md#sqlite-data-source)）。比等值更细的筛选属于自定义 source 能力，或加载之后的应用代码。分页是 Controller 状态：查询、页码与页大小放在 ref 里，`:auto-load` 让任一变化即重载，没有它时应用显式调用 `etaf-data-load`（[Data Controller](data-controllers.md#查询与分页)）。页的含义由 source 决定，因此 cache、页大小与总数来自同一个回复。

## 刷新与不确定性

<!-- index: keep-value; auto-load; 后台重验; 确定度 -->

刷新不应把屏幕清空。`:keep-value` 下 Resource 在重载期间保留最近成功值，只在替换到达时发布；没有它则值立即清空（[Resource](resources.md#加载与重载)）。Controller 始终在刷新、失败与取消期间保留已接受的条目（[Data Controller](data-controllers.md#控制器模型)）。被频繁请求的慢列表可以先从 cache 显示、再在后台比较；cache 的 interval、grace、退避与 stop code 让重验保持克制（[List Cache](list-cache.md#选择下一次刷新)）。

写入是无法靠刷新获得确定性的一部分。v1 source 正常返回即已提交，并由一次重新加载和解；v2 source 自带确定度；拒绝、取消或超时让结果未知，唯一安全的恢复是重新读取，绝不重放写入（[和解](reconciliation.md#不确定的外部结果)）。已提交但刷新失败的写通过 `etaf-data-retry-reconciliation` 按读取重试；回滚或未知的写框架完全不重试。

## 迁移与释放

<!-- index: schema 迁移; 释放; 所有权转移 -->

持久存储会随时间变化。描述新增可空列时，`etaf-sqlite-initialize` 会原地迁移；缺失的主键或非空列会抛出，让应用显式迁移，而不是对着半匹配的表运行（[SQLite 后端](sqlite-backend.md#初始化数据库)）。释放是构造的镜像：`etaf-data-stop` 结束 Controller 的 Scope、取消待决工作并运行 source 的 `:dispose`；Resource 随所有者释放或显式释放；list cache 在会话结束时 disarm。Controller 还在读时释放 source 是所有权 bug，不是数据层的问题。

## 错误与恢复

| 情况 | 该做什么 |
| --- | --- |
| 写入抛出或报告 `rolled-back` | 存储未变；修正后重跑写入 |
| 写入结果为 `external-unknown` | 不要重放；把数据读回来，让和解收敛页面 |
| 已提交写的刷新失败 | 重试和解，它只重新加载而不重放写入 |
| schema 与文件不再匹配 | 显式迁移；初始化只添加可空列 |
| 后台刷新反复失败 | cache 退避，或遇 stop code 暂停等待人工处理 |
| 所有者 Scope 被释放 | Controller 停止、source 被释放；两者都不要再使用 |
