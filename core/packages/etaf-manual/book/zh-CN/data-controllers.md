# Data Controller

Data Controller 是一个 Data Source 的响应式所有者。它把查询、页码、已接受的条目、总数、选择、状态与错误放进 ref；它调用 source 取页和写入；并把每次结果发布为一次响应式更新，因此读取这些 ref 的 View 会跟随数据。本章定义构造与选项、加载、查询与分页、选择、修改、取消与停止，以及各读取接口。[Data Source](data-sources.md)定义它驱动的 source 协议，[异步模型](async.md)定义 source 回调可以返回的适配器，[响应式系统](reactivity.md)定义 ref 与 `etaf-value`。已提交写入之后的五态和解状态机属于[和解](reconciliation.md)章。

## 控制器模型

<!-- index: Data Controller; 控制器 ref; loading; refreshing; 条目保留 -->

Controller 拥有一个子 Scope，读取一个 source，并且一次只持有一个请求。它的公开状态放在 ref 里：`etaf-data-query`、`etaf-data-page`、`etaf-data-page-size`、`etaf-data-items`、`etaf-data-total`、`etaf-data-status`、`etaf-data-error` 与 `etaf-data-selection` 各返回一个。在 View 或副作用里用 `etaf-value` 读取 ref 会让它订阅这个 Controller；每次发布都是一次 `etaf-batch`，因此一次加载结果会一起更新条目、总数、页码元数据、错误与状态。

状态经过六个符号：第一次加载之前 `idle`；请求运行且没有已接受结果时 `loading`；重载运行且旧条目仍被接受时 `refreshing`；成功加载后 `success`；失败或超时后 `error`；取消之后 `cancelled`。加载从不清空已接受的条目：它们在刷新期间、失败之后与取消之后都保持可读，直到一次成功加载替换它们。

Controller 从 `idle` 开始；`:initial-result` 让它像已经成功加载过一样播种，而不触碰 source。`:auto-load` 让它加载一次，之后每当查询、页码或页大小变化就重载——三者组成一个组合键。给定 `:owner-scope`，或存在活跃 Scope 时，Controller 的子 Scope 随该所有者一起释放；否则它是游离的，调用方必须 `etaf-data-stop` 它。停止会取消待决工作并忽略迟到完成；没有任何操作会自动重试。

Controller 一次只做一个请求。开始一次加载或写入会把上一个请求置为作废；两个写不能同时待决。`:item-key` 选项——回退到 source 的 `:item-key` 能力，再回退到条目本身——定义选择所用的稳定身份。

## 创建控制器

<!-- index: etaf-data-controller; auto-load; initial result; owner scope -->

#### Function: etaf-data-controller (source &key query (page 1) (page-size 20) selection auto-load name item-key owner-scope initial-result timeout)

为 SOURCE 创建响应式 Data Controller。

**参数。** SOURCE 是一个 Data source。QUERY、PAGE、PAGE-SIZE、SELECTION、ITEMS、TOTAL、STATUS、ERROR 与选择 ref 从对应选项开始。AUTO-LOAD 非 nil 时立即加载，并在查询或分页变化后重载。NAME 是诊断标签。ITEM-KEY 覆盖 source 的身份函数，用于选择与选中条目状态。OWNER-SCOPE 是释放时连带停止 Controller 的 Scope。INITIAL-RESULT 是规范化的 source 结果，让 Controller 不再次加载即成为成功状态。TIMEOUT 是 nil 或正秒数，作用于每次异步操作。

**语义。** Controller 在 OWNER-SCOPE 或当前活跃 Scope 下创建子 Scope；两者都没有时它是游离的，必须由创建者停止。INITIAL-RESULT 像 source 页面一样规范化——含 `:items` 的 plist，可选 `:total`、`:page`、`:page-size`——让 Controller 以这些值进入 `success`；缺少 `:total` 时按条目数计。INITIAL-RESULT 与 AUTO-LOAD 互斥。AUTO-LOAD 立即加载一次，之后监听查询、页码、页大小的组合键，因此写这三者之一都会重载；成功加载会记录该键，避免重复加载。选择 watch 维护选择快照与每身份的布尔 ref，直接写 selection ref 也会被反映。

**返回。** 新的 Controller。

**错误。** SOURCE 不是 Data source、或 ITEM-KEY 既不是 nil 也不是函数时 `error→ wrong-type-argument`；TIMEOUT 既不是 nil 也不是正数时 `error→ etaf-async-error`；两个选项同时给出时消息为 `"ETAF Data :initial-result and :auto-load are mutually exclusive"` 的错误。

**示例。** `(etaf-data-controller (etaf-data-memory-source '((:id 1)) :id-key :id) :auto-load t)` 立即加载第一页并保持响应式。

**参见。** `etaf-data-load`、`etaf-data-source`、[响应式系统](reactivity.md#ref)。

## 加载页面

<!-- index: 加载; 刷新; 同步结果; 错误记录 -->

#### Function: etaf-data-load (controller)

启动 CONTROLLER 的 source 加载；返回同步结果，待决时为 nil。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 调用把上一个请求置为作废，并以当前查询、页码与页大小启动新的加载。同步 source 返回它的页面，调用返回该结果；异步 source 在请求待决时返回 nil。有已接受结果之前状态是 `loading`；之后的重载是 `refreshing`，旧条目保持可读。成功完成会存入条目（`:total` 缺省为条目数），页面自带 `:page` 与 `:page-size` 时回写对应 ref。同步 source 失败会被记录并向调用方重新抛出；异步失败只记录，因此通过 `etaf-data-error` 与状态观察。在错误、超时或取消之后再加载就是再跑一次 source。

**返回。** 同步页面结果；异步工作待决时为 nil。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`；同步抛出或规范化的失败在记录后重新抛出。

**参见。** `etaf-data-reload`、`etaf-data-status`、`etaf-data-error`。

#### Function: etaf-data-reload (controller)

重载 CONTROLLER；返回同步结果，待决时为 nil。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 与 `etaf-data-load` 相同；当意图是刷新而不是首次加载时使用这个拼写。

**返回。** 同步页面结果；异步工作待决时为 nil。

**错误。** 同 `etaf-data-load`。

## 查询与分页

<!-- index: 查询; 页码; 页大小; 下一页; 上一页 -->

#### Function: etaf-data-query (controller)

返回 CONTROLLER 的查询 ref。

**参数。** CONTROLLER 是存活的 Controller。

**返回。** 查询 ref；用 `etaf-value` 与 `etaf-set-value` 读写。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-set-query (controller query)

把 CONTROLLER 的查询设为 QUERY 并返回 QUERY。

**参数。** CONTROLLER 是存活的 Controller；QUERY 原样交给 source。

**语义。** 查询只存进它的 ref。有 AUTO-LOAD 时，该写入经组合键 watch 触发重载；没有时由应用在需要新页面时调用 `etaf-data-load`。

**返回。** QUERY。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-page (controller)

返回 CONTROLLER 的页码 ref。

**参数。** CONTROLLER 是存活的 Controller。

**返回。** 页码 ref。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-page-size (controller)

返回 CONTROLLER 的页大小 ref。

**参数。** CONTROLLER 是存活的 Controller。

**返回。** 页大小 ref。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-set-page (controller page)

把 CONTROLLER 的页码设为 PAGE 并返回 PAGE。

**参数。** CONTROLLER 是存活的 Controller；PAGE 是新的页码。

**语义。** 页码只存进它的 ref；如何切页由 source 决定。有 AUTO-LOAD 时写入会重载；没有时由应用显式加载。

**返回。** PAGE。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-set-page-size (controller page-size)

把 CONTROLLER 的页大小设为 PAGE-SIZE 并返回 PAGE-SIZE。

**参数。** CONTROLLER 是存活的 Controller；PAGE-SIZE 是新的页大小。

**语义。** 页大小只存进它的 ref；如何切页由 source 决定。有 AUTO-LOAD 时写入会重载；没有时由应用显式加载。

**返回。** PAGE-SIZE。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-next-page (controller)

把 CONTROLLER 移到下一页并返回新页码。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 页码 ref 加一，返回新页码。有 AUTO-LOAD 时由 watch 加载；没有时该调用自己加载，因此两种配置下翻页都只调一次。

**返回。** 新页码。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-previous-page (controller)

把 CONTROLLER 移到上一页并返回新页码。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 页码 ref 减一但不低于 1，返回新页码。加载与 `etaf-data-next-page` 一样遵循 AUTO-LOAD。

**返回。** 新页码。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

## 选择

<!-- index: 选择; selected ref; 选中条目; 条目身份 -->

#### Function: etaf-data-selection (controller)

返回 CONTROLLER 的已选身份列表 ref。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** ref 按选择顺序保存已选身份。直接写它也被支持：Controller 的 watch 会从新列表更新快照与每身份布尔 ref。

**返回。** 选择 ref。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-select (controller identity &optional (selected-p t))

在 CONTROLLER 中选择或取消选择 IDENTITY。

**参数。** CONTROLLER 是存活的 Controller。IDENTITY 是一个选择身份。SELECTED-P 非 nil 加入 IDENTITY；为 nil 则移除。

**语义。** 操作是增量的：身份不存在时加入、SELECTED-P 为 nil 时移除，其它身份不受影响。表格与列表的单选语义请用 `etaf-data-select-one`。

**返回。** 新的选择列表。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-select-one (controller identity)

把 CONTROLLER 的选择替换为单个 IDENTITY。

**参数。** CONTROLLER 是存活的 Controller。IDENTITY 是一个选择身份，nil 表示清空选择。

**语义。** 选择变为只含 IDENTITY 的单元素列表，或 nil。这是表格与列表视图的显式单选操作；`etaf-data-select` 仍是为多选控件保留的增量接口。

**返回。** 新的选择列表。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-selected-ref (controller identity)

返回 CONTROLLER 中 IDENTITY 的稳定布尔选择 ref。

**参数。** CONTROLLER 是存活的 Controller；IDENTITY 是一个选择身份。

**语义。** ref 只在 IDENTITY 进入或离开选择时变化。同一身份重复调用返回同一对象，直到 Controller 生命周期结束。通过选择 API 的更新与直接写 selection ref 的更新都会被反映，因为同步由 Controller 的 watch 负责。

**返回。** 布尔 ref。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-selected-item (controller &optional item-key)

返回与 CONTROLLER 第一个已选身份匹配的已加载条目。

**参数。** CONTROLLER 是存活的 Controller。ITEM-KEY 覆盖传给 `etaf-data-controller` 的函数。

**语义。** 用 ITEM-KEY、或 Controller 的身份函数、或在两者都没有时按 `equal` 直接比较，在已加载条目里查选择中的第一个身份。查询只看当前已加载的条目；选中的条目在别的页时返回 nil。

**返回。** 匹配的条目；选择为空或当前页没有匹配时为 nil。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-item-identity (controller item)

返回 ITEM 在 CONTROLLER 中的稳定选择身份。

**参数。** CONTROLLER 是存活的 Controller；ITEM 是一个已加载条目。

**语义。** 身份先取 Controller 显式的 `:item-key`，再取 source 的 `:item-key` 能力，都没有时就是 ITEM 本身。应用用它比较条目与已选身份，而不必知道键来自哪个 source。

**返回。** 身份值。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

## 修改

<!-- index: 修改; 待决写入; 批量修改; 批; 确定度 -->

#### Function: etaf-data-mutate (controller operation payload)

以 PAYLOAD 运行 source 的 OPERATION，然后和解其结果。

**参数。** CONTROLLER 是存活的 Controller。OPERATION 命名修改，例如内存 source 的 `insert`、`replace`、`update`、`delete`、`reset`。PAYLOAD 是操作的输入。

**语义。** 同步 source 返回结果，调用返回该结果；异步 source 在写入待决时返回 nil，应用通过状态与结果 ref 观察。写入待决期间第二次写会抛出 `etaf-data-error`，数据为 `("A mutation is already pending")`；加载仍可以取代待决的写。v1 结果视为已提交；带 `:mutate-v2` 的 source 返回标记结果，其确定度为 `committed`、`rolled-back` 或 `external-unknown`。已提交的写会触发一次当前页的 reconciliation 加载，结果 ref 之后携带最终信封。回滚或未分类的结果改为发布失败，调用重新抛出提供者的条件。取消、超时或未分类失败从不表示写入被回滚；结果记录 `external-unknown`，可重试的范围由[和解](reconciliation.md)章定义。

**返回。** 同步修改结果；异步写入待决时为 nil。

**错误。** 另一个写待决时、或作为失败修改的父条件时 `error→ etaf-data-error`，数据为 `("A mutation is already pending")`；CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

**参见。** `etaf-data-mutate-many`、`etaf-data-stop`。

#### Function: etaf-data-mutate-many (controller operations)

把 OPERATIONS 应用到 CONTROLLER 的 source 并和解一次。

**参数。** CONTROLLER 是存活的 Controller。OPERATIONS 是非空列表，每项为 `(OPERATION PAYLOAD)`，按顺序应用。

**语义。** 带可选 `:mutate-batch` 能力的 source 原子地应用整表，每对一个结果；其它 source 逐项跑 v1 `:mutate`。这些回调都必须同步完成；异步结果抛出 `etaf-data-error`。已提交结果是 plist，`:operation` 为 `mutate-many`，`:results` 按顺序；每个结果都报告整数变化数时还有 `:changes`。批量像单个写一样只和解一次。某一项抛出时批量停止，失败结果把已完成的前缀放进 `:results`、确定度为 `external-unknown`，条件在发布之后重新抛出。

**返回。** 已提交结果 plist；和解加载待决时为 nil。

**错误。** OPERATIONS 为空或错形、source 缺 `:mutate` 或 `:mutate-batch`、批量回调异步完成、`:mutate-batch` 返回的结果数与操作数不一致、或作为某项抛错后的父条件时 `error→ etaf-data-error`；CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

**参见。** `etaf-data-mutate`、`etaf-data-mutation-outcome`。

## 取消与停止

<!-- index: 取消; 停止; 已释放的控制器; 迟到完成 -->

#### Function: etaf-data-cancel (controller)

取消 CONTROLLER 的待决请求而不停止它；返回 CONTROLLER。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 待决请求被置为作废，适配器提供了取消函数时运行它，第一个迟到完成被丢弃。已加载条目保持可读，Controller 可以再次加载。被取消的写除非提供者已经报告过已提交结果，否则保持 `external-unknown` 确定度；取消已提交写之后的那次刷新也从不改变那个已知结果。

**返回。** CONTROLLER。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-stop (controller)

停止 CONTROLLER，释放它的 Scope，并返回清理错误。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 停止把 Controller 标为已停止、停掉它的 Scope——自动加载 watch、选择 watch 与任何待决请求随之结束——清空内部选择 ref，并运行 source 的 `:dispose` 一次。之后所有数据操作都抛 `etaf-data-stopped-error`；读取接口也不能再调。释放所有者 Scope（例如卸载 Component）以同样方式停止 Controller。停止已停止的 Controller 返回 nil。

**返回。** Scope 收集到的清理条件列表，干净停止时为 nil。

**错误。** CONTROLLER 不是 Controller 时 `error→ wrong-type-argument`。清理错误收进返回值。

**参见。** `etaf-data-cancel`、`etaf-data-controller`、[Data Source](data-sources.md#释放与所有权)。

## 读取状态

<!-- index: etaf-data-status; etaf-data-items; etaf-data-total; etaf-data-error -->

#### Function: etaf-data-status (controller)

返回 CONTROLLER 的状态 ref。

**参数。** CONTROLLER 是存活的 Controller。

**返回。** 状态 ref，其值为[控制器模型](#控制器模型)所述的六个符号之一。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-items (controller)

返回 CONTROLLER 的已加载条目 ref。

**参数。** CONTROLLER 是存活的 Controller。

**返回。** 条目 ref；其值是最近一次被接受的页面，在刷新、失败与取消期间保持可读。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-total (controller)

返回 CONTROLLER 的匹配条目总数 ref。

**参数。** CONTROLLER 是存活的 Controller。

**返回。** 总数 ref；页面没有自带 `:total` 时按条目数计。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

#### Function: etaf-data-error (controller)

返回 CONTROLLER 的可观察错误 ref。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** ref 由 Controller 拥有；消费者只观察，不写它。没有捕获到的失败时值为 nil，否则是条件数据。该函数与同名的错误条件是两套绑定。

**返回。** 错误 ref。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

Component 可以在 `:bindings` 里持有 Controller 并直接渲染它的 ref；每次发布都会重绘读取它的部分。

```elisp :run
(etaf-define-component demo-controller-page ()
  :bindings ((controller (etaf-data-controller
                          (etaf-data-memory-source '((:name "Ada") (:name "Grace"))
                                                   :id-key :name)
                          :auto-load t)))
  :view (column
          (text (expr (format "Status: %s" (etaf-value (etaf-data-status controller)))))
          (text (expr (format "Total: %s" (etaf-value (etaf-data-total controller)))))
          (text :for (item (etaf-value (etaf-data-items controller)))
                :key (plist-get item :name)
                (expr (format "Row: %s" (plist-get item :name))))))
(etaf-view (demo-controller-page))
```

## 错误与恢复

<!-- index: etaf-data-error; etaf-data-stopped-error; 恢复 -->

#### Error: etaf-data-error

无效的 ETAF data 操作；Data 契约失败的父条件。

**语义。** 捕获契约违规而不是提供者失败：两个待决写入、错形的 `etaf-data-mutate-many` 列表、异步批量、source 缺少所需能力、结果不是已提交的修改。用 `condition-case` 捕获；抛出它的调用不返回值。它与用同名读取函数查看 controller 捕获到的失败是两回事。

**原因。** `("A mutation is already pending")`；关于操作列表必须非空、`(OPERATION PAYLOAD)` 条目错形、缺少能力、批量异步结果、结果数与操作数不一致的消息；没有自带条件且结果非已提交时 `"ETAF Data mutation OPERATION was CERTAINTY"`。

**恢复。** 这些失败不回滚任何东西；Controller 保留先前的条目与状态，可和解的已提交写入通过 `etaf-data-retry-reconciliation` 重试而不是重放。修正调用或 source 后重试。

**参见。** `etaf-data-mutate`、`etaf-data-mutate-many`、`etaf-data-error`。

#### Error: etaf-data-stopped-error

ETAF data controller has been stopped

**语义。** 表示对已停止 Scope 的 Controller 执行操作。停止可能来自显式的 `etaf-data-stop`，也可能来自所有者 Scope 的释放。用 `condition-case` 捕获；抛出它的调用不返回值。

**恢复。** 已停止的 Controller 无法复活。在刻意转移 source 所有权之后，用同一 source 新建 Controller，或者在其所有者生命周期内一直持有 Controller 引用。

**参见。** `etaf-data-stop`、`etaf-data-controller`。

| 失败 | 还会剩下什么 |
| --- | --- |
| 同步加载失败 | 条件被记录并重新抛出；条目与总数保持先前的值 |
| 异步加载失败 | 条件记录进错误 ref；条目与总数保持先前的值 |
| 重载进行中 | 状态 `refreshing`；先前接受的条目保持可读 |
| 取消结束加载 | 状态 `cancelled`；条目保持可读，可以再次加载 |
| 写入待决 | 状态 `loading`、结果为 `external-unknown`；第二次写被拒绝 |
| 写入已提交 | 一次和解加载收敛该页，结果变为 `committed` |
| 写入失败或被取消 | 结果保持 `external-unknown` 确定度；不假设回滚 |
| Controller 被停止 | 所有操作抛 `etaf-data-stopped-error`；source 的 `:dispose` 已运行 |
