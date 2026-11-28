# Data Source

Data Source 是数据层面向存储的一半：一个描述如何读写记录的值。它刻意是被动的——一串回调，而不是响应式对象，也不是运行中的请求。[Data Controller](data-controllers.md) 一章定义调用 source、保存条目、状态与选择并发布变化的响应式所有者。本章定义协议及其能力、如何构造与适配 source、独立分页加载器与内存 source。[异步模型](async.md)定义回调可以代替返回值给出的适配器。

## source 协议

<!-- index: Data Source; 能力; :load; :mutate; :mutate-batch; :item-key; :dispose; :provider -->

Data source 是携带回调的普通值。在拥有它的 Controller 调用某个能力之前什么都不会运行，因此构造 source 没有副作用，读取能力也不启动任何工作。

| 能力 | 接收 | 返回 |
| --- | --- | --- |
| `:load` | QUERY、PAGE、PAGE-SIZE | 至少含 `:items` 的 plist，可选 `:total`、`:page`、`:page-size` |
| `:mutate` | OPERATION、PAYLOAD | 操作结果；正常返回表示写入已提交 |
| `:mutate-v2` | OPERATION、PAYLOAD | 带 `:certainty` 的标记结果；已提交时含 `:result` |
| `:mutate-batch` | `(OPERATION PAYLOAD)` 对的列表 | 每对一个结果；事务型后端把整表原子地应用 |
| `:item-key` | 一个条目 | 该条目的稳定选择身份 |
| `:dispose` | — | 在拥有它的 Controller 停止时运行，让 source 释放外部资源 |

只有 `:load` 必需；其余能力都可选，Controller 有什么用什么。`:provider` 是 source 在观察报告里的名字，默认 `data`。

加载与变更回调可以返回 `etaf-async` 适配器而不返回值：Controller 启动它，并以普通结果解决（[异步模型](async.md)）。v1 变更的普通返回表示已提交；v2 结果自带确定度；拒绝、取消或超时始终让外部写入的确定度未知，由和解——而不是回滚——处理（[和解](reconciliation.md)一章）。

source 自己不持有状态，且恰好有一个拥有它的 Controller。释放由 Controller 负责：停止它会让 `:dispose` 运行一次。

## 创建 source

<!-- index: etaf-data-source; 能力校验 -->

#### Function: etaf-data-source (&rest capabilities)

用可调用的 CAPABILITIES 创建 Data source。

**参数。** CAPABILITIES 是 plist。`:load` 必需且必须是函数；`:mutate`、`:mutate-v2`、`:mutate-batch`、`:dispose`、`:item-key` 是可选函数；`:provider` 是可选的、非关键字符号；`:name` 是可选元数据。

**语义。** 回调捕获存储；source 本身只携带它们。`:load` 以 QUERY、PAGE、PAGE-SIZE 调用并返回该页。`:mutate` 与 `:mutate-v2` 以 OPERATION、PAYLOAD 调用。`:mutate-batch` 以 `(OPERATION PAYLOAD)` 对的列表调用，每对返回一个结果。`:item-key` 以单个条目调用。`:dispose` 在拥有它的 Controller 停止时运行。这些回调都可以返回 `etaf-async` 适配器。取值在这里一次性校验，因此非函数能力、缺失的 `:load`、或不是非关键字符号的 `:provider` 会在触碰数据之前被拒绝。

**返回。** Data source。

**错误。** `:load` 缺失或不是函数、或其它能力存在但不是函数时 `error→ wrong-type-argument`，数据为 `(functionp VALUE)`；`:provider` 不是非关键字符号时 `error→ wrong-type-argument`，数据为 `(symbolp PROVIDER)`。

**示例。** `(etaf-data-source :load (lambda (query page page-size) (list :items (list query page page-size))) :provider 'demo)` 构造一个页面原样回显参数的 source。

**参见。** `etaf-data-source-capabilities`、`etaf-data-memory-source`。

## 能力快照与组合

<!-- index: etaf-data-source-capabilities; 适配; source 所有权 -->

#### Function: etaf-data-source-capabilities (source)

返回 SOURCE 受支持能力的全新 plist，供组合使用。

**参数。** SOURCE 是一个 Data source。

**语义。** 返回的 plist 只含 SOURCE 实际拥有的条目，取自 `:load`、`:mutate`、`:mutate-v2`、`:mutate-batch`、`:dispose`、`:item-key`、`:provider` 与 `:name`。回调与元数据是同一批对象，因此快照保留存储；替换快照里的条目不影响 SOURCE。在快照上改条目再把结果交给 `etaf-data-source` 就是适配：把 `:load` 包成异步适配器、加上 `:mutate-v2` 的确定度、挂上 `:dispose`。读取能力不启动工作、不转移所有权：适配后的 source 共享同一份存储，底层 source 不能再交给第二个 Controller。

**返回。** 全新的能力 plist。

**错误。** SOURCE 不是 Data source 时 `error→ wrong-type-argument`。

**示例。**

```elisp
(let* ((source (etaf-data-memory-source '((:id 1)) :id-key :id))
       (capabilities (etaf-data-source-capabilities source)))
  (list (eq (plist-get capabilities :load) (plist-get source :load))
        (plist-get capabilities :provider)))
;; ⇒ (t memory)
```

**参见。** `etaf-data-source`、`etaf-data-memory-source`。

## 不建 Controller 加载一页

<!-- index: etaf-data-source-load-page; 分页契约; 规范化 -->

#### Function: etaf-data-source-load-page (source &optional query page page-size)

在不创建 Controller 的情况下加载并规范化 SOURCE 的一页。

**参数。** SOURCE 是一个 Data source。QUERY 原样交给 `:load`。PAGE 与 PAGE-SIZE 默认 1 与 20，下限都取 1。

**语义。** 调用 `:load` 一次并规范化页面：结果必须是含 `:items` 的 plist。这个辅助函数用来读取初始数据、给 Controller 的 `:initial-result` 播种，或不做任何响应式机制地测试 source。它不创建响应式状态，加载本身也不通知任何观察者。这里只支持同步 source：`:load` 返回 `etaf-async` 时直接抛错、不启动适配器，因为只有 Controller 能拥有异步工作。

**返回。** 规范化后的页面 plist。

**错误。** `:load` 返回适配器时 `error→ etaf-async-error`，数据为 `("Asynchronous sources require a Data Controller")`；回调返回非 plist 时消息为 `"ETAF Data source load must return a plist: VALUE"` 的错误；plist 没有 `:items` 时消息为 `"ETAF Data source load result lacks :items"` 的错误。

**参见。** `etaf-data-source`、`etaf-async`。

## 内存 source

<!-- index: etaf-data-memory-source; 内存记录; 查询; 变更 -->

#### Function: etaf-data-memory-source (items &key id-key name)

在 ITEMS 上创建内存 Data source。

**参数。** ITEMS 是初始记录列表，会被拷贝，因此之后改动调用方的列表不会进入 source。ID-KEY 是变更与选择用来识别记录的字段名。NAME 是 source 的标签。

**语义。** source 保存记录，并由自己的 `:load` 提供：按 QUERY 过滤、按 PAGE 与 PAGE-SIZE 切页，始终返回 `:items`、`:total`、`:page`、`:page-size`。它的 provider 是 `memory`。记录通常是 plist，alist 与 hash table 也可以，查询按记录自身的种类读取字段。

| 查询 | 选择 |
| --- | --- |
| nil | 全部记录 |
| 函数 | 对它返回非 nil 的记录；以记录为参数调用 |
| 字符串 | 打印形式包含它的记录，大小写不敏感 |
| plist | 每个关键字键的记录值都等于查询值的记录 |
| alist | 每个键的记录值都等于查询值的记录 |
| 其它值 | 与它 `equal` 的记录 |

source 支持的变更：

| 操作 | 载荷 | 效果 |
| --- | --- | --- |
| `insert` | 一条记录 | 追加 |
| `replace`、`update` | 一条记录 | 替换身份相同的记录，找不到则抛错 |
| `delete` | 一个身份 | 删除该身份的记录 |
| `reset` | 记录列表 | 整表替换 |

记录的身份是 ID-KEY 字段的值；ID-KEY 为 nil 时身份就是记录本身。source 通过 `:item-key` 暴露身份，让 Controller 能比较选择身份。

**返回。** Data source。

**错误。** `replace` 或 `update` 找不到匹配记录时消息为 `"No memory source record for id ID"` 的错误；其它操作时消息为 `"Unsupported memory source mutation: OPERATION"` 的错误；两者抛出时记录列表不变。

**示例。** 辅助函数与内存 source 组合成完整的读取路径：大小写不敏感的查询挑出记录，分页参数取过滤结果的一部分。

```elisp :run
(etaf-define-component demo-memory-page ()
  :bindings ((page (etaf-data-source-load-page
                    (etaf-data-memory-source
                     '((:name "Ada") (:name "Grace") (:name "Alan"))
                     :id-key :name)
                    "a" 1 2)))
  :view (column
          (text (expr (format "Total: %s" (plist-get page :total))))
          (text :for (item (plist-get page :items))
                :key (plist-get item :name)
                (expr (format "Row: %s" (plist-get item :name))))))
(etaf-view (demo-memory-page))
```

**参见。** `etaf-data-source`、`etaf-data-source-load-page`。

## 释放与所有权

<!-- index: source 所有权; :dispose; 适配 -->

每个 source 只有一个拥有它的 Controller，停止该 Controller 会让 source 的 `:dispose` 运行一次。这是唯一的释放钩子；内存 source 没有可释放的东西，因此不定义它。适配后的 source 与它组合自的 source 共享存储，所有权必须保持单一：底层 source 只交给一个 Controller，包装它的适配器就是那个所有者。

## 错误与恢复

| 非法输入 | 会发生什么 |
| --- | --- |
| `:load` 缺失或不是函数，或其它能力不是函数 | `etaf-data-source` 抛 `wrong-type-argument`；没有存下任何东西 |
| `:provider` 不是非关键字符号 | `etaf-data-source` 抛 `wrong-type-argument`；没有存下任何东西 |
| 页面不是 plist，或 plist 没有 `:items` | `etaf-data-source-load-page` 抛错；调用方保留先前的数据 |
| 把异步 `:load` 交给 `etaf-data-source-load-page` | `etaf-async-error`；适配器没有启动 |
| 内存 source 的 `replace` 或 `update` 找不到身份 | 抛错；记录列表不变 |
| 内存 source 的未知操作 | 抛错；记录列表不变 |
