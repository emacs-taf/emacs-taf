# 和解

一次写与它改变的页面是两件事实。已提交的修改之后，Data Controller 会重新加载当前页，让显示的数据与提供者提交的事实一致；当提供者说不清写是否生效时，不能假设回滚，结果保持不确定。本章定义结果信封、五种和解状态、只重新读取而不重放已提交写的重试，以及取消或超时之后还确定知道什么。修改调用与状态见 [Data Controller](data-controllers.md)；取消与超时条件见[异步模型](async.md)。

## 结果信封

<!-- index: mutation outcome; certainty; external-unknown; reconciliation token -->

#### Function: etaf-data-mutation-outcome (controller)

返回 CONTROLLER 最新 mutation outcome 信封的副本。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 读取函数返回全新的树，查看或改它都不会影响 Controller。还没有修改时值为 nil。每次写都会在待决期间发布信封：`:pending-p` 非 nil、`:certainty` 为 `external-unknown`，直到提供者给出回答。完成后的信封携带 `:certainty`、原始修改结果、写失败时的条件、操作及其 id，以及不透明的 reconciliation token。批量失败额外在 `:results` 里携带已完成的前缀。信封是响应式值：在 View 或副作用里读它会跟随修改变化。调用方把 token 当作不透明数据，也不要写信封。

**返回。** 最新结果信封的深拷贝；任何写之前为 nil。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

三种确定度回答同一个问题：提供者是否知道这次写发生了什么？

| `:certainty` | 含义 |
| --- | --- |
| `committed` | 写已生效。v1 回调正常返回即此；v2 结果显式声明 |
| `rolled-back` | 提供者明确报告写没有生效 |
| `external-unknown` | 结果无法确定：拒绝、取消、超时或未分类的 v2 结果 |

已提交的写会启动一次当前查询与页码的和解加载。结果信封随后带上最终 token；被拒绝、取消或超时的写作为失败发布，除非提供者已经报告过已提交结果，否则确定度保持 `external-unknown`。

## 五种和解状态

<!-- index: reconciliation-pending; reconciled; reconciliation-error; rolled-back; external-unknown -->

#### Function: etaf-data-reconciliation-state (controller)

返回 CONTROLLER 当前的和解状态符号，没有则为 nil。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 状态描述最近一次产生结果的写。待决写还没有状态——它的信封仍带 `:pending-p`——从未写过的 Controller 返回 nil。状态机有五个符号：

| 状态 | 含义 |
| --- | --- |
| `reconciliation-pending` | 已提交的写在等它的刷新结束 |
| `reconciled` | 刷新成功，页面反映已提交的写 |
| `reconciliation-error` | 刷新失败；写仍是 committed，可以按读取重试 |
| `rolled-back` | 提供者报告写没有生效 |
| `external-unknown` | 写的影响无法确定 |

已提交的写进入 `reconciliation-pending`，离开时变为 `reconciled` 或 `reconciliation-error`；重试失败的刷新会保持 `reconciliation-error` 直到成功一次。回滚结果报告 `rolled-back`；包括被取消或超时的写在内，一切不确定结果都报告 `external-unknown`。

**返回。** 状态符号；没有任何写产生结果时为 nil。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

## 重试已提交的写

<!-- index: 重试; reconciliation error; 不重放写 -->

#### Function: etaf-data-retry-reconciliation (controller)

重新加载已提交的修改，不重放它的 source 写操作。

**参数。** CONTROLLER 是存活的 Controller。

**语义。** 只有 certainty 为 committed、且和解状态为 `reconciliation-pending` 或 `reconciliation-error` 的结果可以重试；未知与回滚结果刻意不重试，因为重新读取无法让它们落定。重试启动一次当前页的加载，返回其同步结果；异步工作待决或无资格时返回 nil。它绝不再次调用 source 的修改能力，因此重试对可能已经提交的写是安全的。用 `etaf-data-status` 与 `etaf-data-reconciliation-state` 区分重试是完成了还是仍在待决；成功的重试最终为 `reconciled`。没有任何自动重试。

**返回。** 同步加载的页面；待决或无资格时为 nil。

**错误。** CONTROLLER 已停止时 `error→ etaf-data-stopped-error`；不是 Controller 时 `error→ wrong-type-argument`。

**参见。** `etaf-data-mutate`、`etaf-data-reconciliation-state`。

## 不确定的外部结果

<!-- index: 恢复; 被取消的写; 超时; 回滚 -->

拒绝、取消、超时与未分类的 v2 结果都让写的影响无法确定，且都不证明回滚：提供者可能在回答丢失之前已经提交了写。安全的恢复是读取而不是重放——重新加载页面，或对已提交的写重试和解——何时读取由应用决定。只有提供者显式的 `rolled-back` 结果意味着写没有生效。取消已提交写之后的刷新从不改变那个已知结果，被取消的写保持 `external-unknown`。

| 失败 | 还会剩下什么 |
| --- | --- |
| 已提交写的刷新失败 | 写保持 `committed`；状态 `reconciliation-error`；`etaf-data-retry-reconciliation` 可以再读一次 |
| 已提交写的刷新成功 | 状态 `reconciled`；页面反映该写 |
| 提供者报告 `rolled-back` | 结果与状态为 `rolled-back`；不重试该写 |
| 写被拒绝、取消或超时 | 结果与状态为 `external-unknown`；读取可以让页面落定，但写不会被重放 |
| 批量中途失败 | 已完成的缀在 `:results`；确定度保持 `external-unknown` |
| Controller 被停止 | 结果不可再读：读取接口抛 `etaf-data-stopped-error` |
