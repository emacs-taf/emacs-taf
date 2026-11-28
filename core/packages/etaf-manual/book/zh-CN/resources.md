# Resource

Resource 是一个由 Scope 所有、带 loader 的值：它运行 loader，把结果存进响应式状态，并暴露状态、最近成功值和失败。它是 [Data Controller](data-controllers.md) 的单值对应物；loader 无法在启动它的那次调用里结束时，它使用[异步模型](async.md)的加载生命周期。本章定义构造与读取接口、状态机、加载、取消与释放、值的保留与清理，以及随附示例。拥有 Resource 的 Scope 由[响应式系统](reactivity.md#scope)定义。

## Resource 模型

<!-- index: Resource; loader; 状态; keep-value; Resource Scope -->

Resource 持有一个 loader 函数、一个子 Scope、一个当前请求、可选超时，以及包含状态、值和错误的响应式状态。loader 可以返回普通值、带清理函数的 `etaf-resource-result`，或 `etaf-async` 的异步适配器。loader 内部失败、或稍后交付的拒绝，被记录进状态而不是抛给调用方；Resource 自身清理、或向观察者发布时的错误仍然照常上抛。

状态是六个符号之一：

| 状态 | 含义 |
| --- | --- |
| `idle` | 以 `:immediate nil` 创建；还没有请求运行过 |
| `loading` | 请求运行中，且没有保留的旧值 |
| `refreshing` | 请求运行中，且 `:keep-value` 保留了旧值 |
| `success` | 最近一次请求以值完成 |
| `error` | 最近一次请求失败或超时 |
| `cancelled` | 待决请求被取消 |

状态是一个响应式 ref，因此在 View 里读 `etaf-resource-status`、`etaf-resource-value` 或 `etaf-resource-error` 会让那次渲染订阅这个 Resource：完成会让读取它的那部分树重绘。这三个读取函数也是普通函数，可以在渲染之外使用。

一个 Resource 一次只跑一个请求。新的加载在开始前把上一个请求变为作废，因此只有当前请求能发布结果。Resource 在自己的父 Scope 下拥有一个子 Scope；父 Scope 停止时子 Resource 一并释放，Component 卸载时其 `:bindings` 创建的 Resource 就是这样释放的。没有任何父 Scope 的 Resource 是游离的，必须由创建者释放（[响应式系统](reactivity.md#scope)）。

## 创建 Resource

<!-- index: etaf-resource; immediate; keep-value; 超时 -->

#### Function: etaf-resource (loader &key (immediate t) scope name timeout keep-value)

创建一个由 LOADER 支撑、归 Scope 所有的 Resource。

**参数。** LOADER 是产生一个结果的函数：普通值、`etaf-resource-result`，或 `etaf-async` 适配器。IMMEDIATE 非 nil（默认）时在 `etaf-resource` 返回前就加载；为 nil 则 Resource 停在 `idle`。SCOPE 是父 Scope。NAME 是诊断标签。TIMEOUT 是 nil 或正秒数，只作用于异步等待。KEEP-VALUE 非 nil 时重载会保留最近成功值。

**语义。** Resource 在 SCOPE 或当前活跃 Scope 下创建子 Scope；两者都没有时它是游离的，创建者必须释放它。IMMEDIATE 时 loader 在构造返回前运行，因此同步 loader 的结果已经产生，而异步 loader 让 Resource 停在 `loading`（[异步模型](async.md)）。loader 失败被记录进状态，不阻止构造返回；若信号从立即加载中逃逸——清理或发布错误——构造会先释放 Resource 再传播该条件。

**返回。** 新的 Resource。

**错误。** LOADER 不是函数时 `error→ wrong-type-argument`，数据为 `(functionp LOADER)`；TIMEOUT 既不是 nil 也不是正数时 `error→ etaf-async-error`；立即加载中逃逸的信号在释放 Resource 后继续传播。

**示例。**

```elisp
(let ((resource (etaf-resource (lambda () "ready"))))
  (list (etaf-resource-status resource)
        (etaf-resource-value resource)))
;; ⇒ (success "ready")
```

**参见。** `etaf-resource-result`、`etaf-async`、[响应式系统](reactivity.md#scope)。

## 加载与重载

<!-- index: 重载; refreshing; 重试; 清理时机 -->

#### Function: etaf-resource-load (resource)

重载 RESOURCE 并返回它，不等待异步完成。

**参数。** RESOURCE 是一个仍活跃的 Resource。

**语义。** 上一个待决请求在新请求开始前被置为作废，因此只有当前请求能发布。状态变为 `loading`；`:keep-value` 保留值时变为 `refreshing`。没有 `:keep-value` 时旧值被清空、旧清理函数在调用返回前已经运行。同步 loader 在调用内完成，异步 loader 稍后完成。loader 失败——loader 内部抛错或稍后交付的拒绝——被记录进状态而不上抛；清理、发布与渲染错误仍然照常上抛，此时新结果已经记录。没有自动重试：在错误、超时或取消之后再调用一次，就是再跑一遍 loader。

**返回。** RESOURCE。

**错误。** RESOURCE 不是 Resource 或已被释放时 `error→ etaf-resource-error`，数据为 `("ETAF Resource is not active")`。

`:keep-value` 下旧值与它的清理函数一直保留到新结果被接受，因此失败、取消或超时都会留下最近成功值；这让面板能在刷新期间继续显示旧数据。没有它时重载立即清空值，失败之后不会留下值。

旧清理函数在旧值被交出的那一刻运行：立即清空时、接受替换时、或释放时。清理函数可以启动新加载或释放 Resource；若交付替换的那个请求在期间已作废，它仍会被丢弃。

## 取消与释放

<!-- index: 取消; 释放; 发布 -->

#### Function: etaf-resource-cancel (resource)

取消 RESOURCE 的待决加载而不释放它，并返回 RESOURCE。

**语义。** 待决请求被置为作废，适配器提供了取消函数时运行它，第一个迟到完成连同清理一起被丢弃。状态变为 `cancelled`，错误为 `(etaf-async-cancelled)`；`:keep-value` 保留最近的值。没有待决请求时调用不改变任何东西。之后可以再次加载。

**返回。** RESOURCE。

**错误。** RESOURCE 不是 Resource 或已被释放时 `error→ etaf-resource-error`，数据为 `("ETAF Resource is not active")`。

#### Function: etaf-resource-dispose (resource)

释放 RESOURCE，返回其 Scope 收集到的清理错误。

**语义。** 释放先把 Resource 标为不活跃、把待决请求置为作废、运行当前值的清理函数一次，然后停掉 Resource 的 Scope 及其中拥有的一切。之后的加载与取消抛出 `etaf-resource-error`。父 Scope 停止时同样释放其 Resource，因此 Component 的 `:bindings` Resource 在卸载时释放。释放已释放的 Resource 返回 nil。

**返回。** Scope 收集到的拆除条件列表，干净停止时为 nil。

**错误。** RESOURCE 不是 Resource 时 `error→ wrong-type-argument`。清理错误被收进返回值而不是上抛。

**参见。** `etaf-resource`、`etaf-resource-cancel`、[响应式系统](reactivity.md#scope)。

## 读取状态

<!-- index: etaf-resource-status; etaf-resource-value; etaf-resource-error -->

#### Function: etaf-resource-status (resource)

返回 RESOURCE 的状态：idle、loading、refreshing、success、error 或 cancelled。

**参数。** RESOURCE 是一个 Resource。

**返回。** [Resource 模型](#resource-模型)所述的六个状态符号之一。

**参见。** `etaf-resource-load`、`etaf-resource-cancel`。

#### Function: etaf-resource-value (resource)

返回 RESOURCE 的成功值，成功之前为 nil。

**参数。** RESOURCE 是一个 Resource。

**返回。** 最近一次成功结果的值。`:keep-value` 下，刷新期间以及失败、取消或超时之后仍返回保留值；没有它时重载清空值。

**参见。** `etaf-resource-result`、`etaf-resource-status`。

#### Function: etaf-resource-error (resource)

返回 RESOURCE 当前的 loader 失败或取消条件，没有则为 nil。

**参数。** RESOURCE 是一个 Resource。

**返回。** 当前状态的失败；最近结果是成功、或还没有请求运行时为 nil。取消是 `(etaf-async-cancelled)`，超时是 `(etaf-async-timeout TIMEOUT)`；loader 失败是 loader 抛出的条件或交付给适配器 reject 函数的数据。

**语义。** 该函数与同名的错误条件是两套绑定。条件在非法 Resource 操作时抛出；loader 失败从不抛出，通过该函数读取。

**参见。** `etaf-resource`、`etaf-async`、`etaf-resource-error`。

Component 可以直接持有 Resource 并渲染它的读取函数；由于状态是响应式的，每次完成都会重绘读取它的部分。

```elisp :run
(etaf-define-component demo-resource-status ()
  :bindings ((resource (etaf-resource (lambda () "rows"))))
  :view (column
          (text (expr (format "Status: %s" (etaf-resource-status resource))))
          (text (expr (format "Value: %S" (etaf-resource-value resource))))))
(etaf-view (demo-resource-status))
```

## loader 结果与清理

<!-- index: etaf-resource-result; 清理函数; 丢弃 -->

#### Function: etaf-resource-result (value &key cleanup)

返回一个包含 VALUE 与可选 CLEANUP 的 Resource loader 结果。

**参数。** VALUE 是要发布的值。CLEANUP 非 nil 时是零参函数。

**语义。** loader 打开了需要释放的东西时使用它。Resource 在交出值的那一刻运行 CLEANUP 一次：没有 `:keep-value` 的重载、接受替换、释放，以及取消之后第一个迟到完成被丢弃时（此时 VALUE 永不发布）。同一请求的重复完成被忽略，因此清理只跑一次。一个结果只属于一个 Resource：清理的所有权跟着值走，loader 必须把每个结果只交给一个 Resource。

**返回。** 结果包装。

**错误。** CLEANUP 既不是 nil 也不是函数时 `error→ wrong-type-argument`，数据为 `(functionp CLEANUP)`。

**示例。**

```elisp
(let* ((released nil)
       (resource (etaf-resource
                  (lambda ()
                    (etaf-resource-result
                     "rows" :cleanup (lambda () (setq released t)))))))
  (list (etaf-resource-value resource) released))
;; ⇒ ("rows" nil)
```

**参见。** `etaf-resource`、`etaf-resource-load`。

## 随附示例

<!-- index: etaf-resource-example-open; etaf-resource-example-close -->

#### Function: etaf-resource-example-open ()

把异步 Resource 示例挂载到 *ETAF Resource Example* 并返回该 buffer。

**参数。** 无。

**语义。** 挂载随附示例：一个由原生定时器从 loader 完成的 Resource，带 `:keep-value t` 与五秒超时。它的按钮可以重载、模拟失败和取消；面板显示状态、最近值、失败消息和已经运行的清理次数。重复打开会替换上一次挂载，释放它的待决工作与已加载值。

**返回。** 挂载后的 buffer；交互调用会显示它。

**示例。** `M-x etaf-resource-example-open`，然后用 RELOAD、SIMULATE FAILURE 与 CANCEL 按钮。

**参见。** `etaf-resource-example-close`。

#### Function: etaf-resource-example-close ()

卸载并杀掉 *ETAF Resource Example*。

**参数。** 无。

**语义。** 示例已挂载时卸载它并杀掉 buffer，从而取消待决工作并释放已加载值。重复关闭无害。

**返回。** nil。

**错误。** 无。

**参见。** `etaf-resource-example-open`。

## 错误与恢复

<!-- index: etaf-resource-error; 不活跃; 清理错误 -->

#### Error: etaf-resource-error

无效的 ETAF Resource 操作。父条件为 `etaf-reactive-error`。

**语义。** 表示 Resource 因目标非法或不再活跃而无法执行操作。用 `condition-case` 捕获；抛出它的调用不返回值。数据是消息 `("ETAF Resource is not active")`。loader 失败不是该条件：它们被记录进状态，用 `etaf-resource-error` 读取。

**恢复。** 已释放的 Resource 无法复活；新建一个，并修正过早释放它的调用方。失败的调用没有改变任何东西。

**参见。** `etaf-resource-load`、`etaf-resource-cancel`、`etaf-resource-error`。

| 失败 | 还会剩下什么 |
| --- | --- |
| loader 抛错，或稍后交付拒绝 | 状态 `error`，条件在 `etaf-resource-error` 里；值由保留策略决定 |
| 等待超时 | 状态 `error` 并记录 `(etaf-async-timeout TIMEOUT)`；取消函数已运行 |
| 请求被取消 | 状态 `cancelled` 并记录 `(etaf-async-cancelled)`；`:keep-value` 保留值 |
| 请求被替换 | 旧请求无法发布；它的第一个迟到完成连同清理一起被丢弃 |
| Resource 被释放 | 不活跃；待决工作被取消、当前清理已运行；之后的加载抛出 `etaf-resource-error` |
| 发布期间观察者抛错 | 新状态已经记录，条件继续传播 |
