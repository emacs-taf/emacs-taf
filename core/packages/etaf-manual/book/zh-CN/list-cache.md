# List Cache

list cache 是慢变化、被频繁请求的列表的显示捷径。它把每个列表连同到达时间存在 key 下，让会话能立刻画出一节，同时在后台与新鲜回复比较——stale-while-revalidate。cache 只保留每个应用否则都会重复的策略：条目何时算旧、下一次刷新哪个列表、失败如何退避，以及哪种失败需要人工处理。它从不是真相来源；每次加载 backend 回复都替换条目，应用保留自己的行、请求与重绘。本章定义 cache、条目操作、新鲜度规则、刷新选择、定时器与失败策略。[Data Controller](data-controllers.md)提供 cache 镜像的页面，[异步模型](async.md)定义后台加载可以返回的适配器。

## 缓存模型

<!-- index: list cache; 条目; interval; grace; 退避; stop code; stale-while-revalidate -->

cache 把 key 映射到由 `:rows`、`:total`、`:at` 与可选 `:version` 组成的条目，`:at` 是列表到达或最近被检查的时间。四个策略值来自 `etaf-list-cache-create`：新鲜度 interval、启动或 arm 之后的静默 grace、退避上限，以及需要人工处理的 stop code。cache 预期存活一个 session；它自己不启动任何工作，并通过忙标记把后台刷新限制为至多一个。消费者保留自己的数据；cache 只记住上次回复的样子与时间。

## 创建缓存

<!-- index: etaf-list-cache-create; 新鲜度; grace; max backoff -->

#### Function: etaf-list-cache-create (&key interval grace max-backoff stop-codes)

返回一个条目新鲜 INTERVAL 秒、静默 GRACE 秒的 list cache。

**参数。** INTERVAL 是条目的新鲜秒数，默认 120。GRACE 是启动或 arm 之后后台刷新不开始的静默期，默认 3。MAX-BACKOFF 是重试延迟的上限秒数，默认 1800。STOP-CODES 是「之后暂停后台刷新直到加载成功」的失败代码列表，默认 `("auth" "blocked")`。

**语义。** 返回的 cache 只拥有策略与已存条目。后台刷新绝不在 grace 期内开始，因此刚打开的一节不会与预取争资源。失败的刷新从 INTERVAL 起每次加倍退避，上限 MAX-BACKOFF；stop code 则完全暂停刷新，直到 `etaf-list-cache-note-success` 记录一次成功加载。

**返回。** 新的 cache。

**错误。** 无。

**参见。** `etaf-list-cache-start`、`etaf-list-cache-arm`、`etaf-list-cache-note-failure`。

## 存取条目

<!-- index: etaf-list-cache-put; 版本 token; 到达时间; touch -->

#### Function: etaf-list-cache-put (cache key rows total &key version at)

在 KEY 下缓存 ROWS 与 TOTAL 并返回存入的条目。

**参数。** CACHE 是 list cache；KEY 标识列表。ROWS 与 TOTAL 是已接受的回复。VERSION 是可选的、不透明的 backend 版本 token。AT 是可选的、自纪元起的非负观测秒数，用于恢复持久化快照；省略时记录当前时间。

**语义。** 条目替换 KEY 的旧条目，并记录到达时间；staleness 规则与后台刷新顺序都读它。未来的 AT 被 clamp 到当前时间，非法 AT 让 cache 不变。cache 从不解释版本 token，只保存它，让调用方把它随下一次条件请求发出，并用 `etaf-list-cache-touch` 回应 not-modified。

**返回。** 存入的条目 plist。

**错误。** AT 存在但不是非负数时 `error→ wrong-type-argument`；cache 不变。

**示例。** `(etaf-list-cache-put cache '(:shelf) '(1 2) 2 :version "v1")` 存入行、总数与 token 并返回该条目。

**参见。** `etaf-list-cache-entry`、`etaf-list-cache-touch`。

#### Function: etaf-list-cache-version (cache key)

返回 KEY 的版本 token，没有则为 nil。

**参数。** CACHE 是 list cache；KEY 标识列表。

**语义。** token 就是调用方传给 `etaf-list-cache-put` 或 `etaf-list-cache-touch` 的东西；cache 从不解释它。没有条目的 key 没有 token。

**返回。** 存入的 token，或 nil。

**错误。** 无。

#### Function: etaf-list-cache-touch (cache key &optional version)

把 KEY 的条目标为刚检查过，不替换它的行。

**参数。** CACHE 是 list cache；KEY 标识列表。VERSION 非 nil 时替换存入的 token。

**语义。** backend 对条件请求回答「没有变化」时用它报告：条目的到达时间变成当前时间，因此重新变新鲜、不需要重绘，而它的行与总数保持原样。touch 一个没有条目的 key 什么都不做并返回 nil。

**返回。** 被 touch 的条目；KEY 没有条目时为 nil。

**错误。** 无。

**参见。** `etaf-list-cache-put`、`etaf-list-cache-unchanged-p`。

#### Function: etaf-list-cache-entry (cache key)

返回 KEY 的缓存条目 `(:rows :total :at)`，没有则为 nil。

**参数。** CACHE 是 list cache；KEY 标识列表。

**返回。** 条目 plist；KEY 从未存入时为 nil。

**错误。** 无。

#### Function: etaf-list-cache-rows (cache key)

返回 KEY 的缓存行，没有则为 nil。

**参数。** CACHE 是 list cache；KEY 标识列表。

**返回。** 存入的行；KEY 从未存入时为 nil。

**错误。** 无。

#### Function: etaf-list-cache-total (cache key)

返回 KEY 的缓存总数，没有则为 0。

**参数。** CACHE 是 list cache；KEY 标识列表。

**返回。** 存入的总数；KEY 从未存入时为 0。

**错误。** 无。

## 新鲜度与未变化回复

<!-- index: stale-p; unchanged-p; missing 与 stale -->

#### Function: etaf-list-cache-stale-p (cache key &optional now interval)

返回 KEY 的条目是否比 INTERVAL 秒更旧。

**参数。** CACHE 是 list cache；KEY 标识列表。NOW 覆盖当前时间，INTERVAL 覆盖 cache 自己的 interval，供确定性调用方使用。

**语义。** 条目到达后经过的时间严格大于 interval 时算旧。没有条目的 key 是 missing 而不是 stale——它是预取候选——因此想知道有没有东西可显示的调用方还要读 entry。

**返回。** 条目存在且比 interval 旧时非 nil；否则 nil。

**错误。** 无。

#### Function: etaf-list-cache-unchanged-p (cache key rows total)

返回 ROWS 与 TOTAL 是否等于 KEY 已持有的内容。

**参数。** CACHE 是 list cache；KEY 标识列表。ROWS 与 TOTAL 是新回复。

**语义。** 调用方在重绘前比较后台回复：回复未变化时页面可以原样保留，这正是切节不闪烁的原因。没有条目的 key 永远不算未变化。

**返回。** 条目存在且两个值都 `equal` 时非 nil；否则 nil。

**错误。** 无。

**参见。** `etaf-list-cache-touch`、`etaf-list-cache-put`。

## 选择下一次刷新

<!-- index: etaf-list-cache-next; 刷新顺序; 预取; 一次一个 -->

#### Function: etaf-list-cache-next (cache keys &optional now interval)

返回后台刷新接下来应该加载的 KEY，没有则为 nil。

**参数。** CACHE 是 list cache。KEYS 是调用方有序的候选列表。NOW 与 INTERVAL 像 `etaf-list-cache-stale-p` 那样覆盖当前时间与新鲜度 interval。

**语义。** 最旧的 stale 条目优先；所有条目都新鲜时，返回第一个没有条目的候选，让那一节在打开前预热。cache 尚未 start、有刷新在途、处于 grace 期、因 stop code 暂停、或在失败退避期内时返回 nil——这就是一次只跑一个刷新——每个候选都新鲜且都有条目时也返回 nil。应用加载返回的 key，并通过 `etaf-list-cache-put` 加 `etaf-list-cache-note-success` 或 `etaf-list-cache-note-failure` 报告结果。

**返回。** KEYS 中的一个 key；不应开始刷新时为 nil。

**错误。** 无。

**参见。** `etaf-list-cache-start`、`etaf-list-cache-set-busy`。

## 启动、定时与停止

<!-- index: etaf-list-cache-start; etaf-list-cache-arm; 后台定时器; disarm -->

#### Function: etaf-list-cache-start (cache)

启动 CACHE：进入 grace 期并允许后台刷新。

**参数。** CACHE 是 list cache。

**语义。** 启动记录 cache 变为活跃的时间，开启 grace 期并让 `etaf-list-cache-next` 返回候选。已经自己跑定时器的调用方在 session 开始时调用一次，然后询问加载什么。

**返回。** CACHE。

**错误。** 无。

**参见。** `etaf-list-cache-next`、`etaf-list-cache-arm`。

#### Function: etaf-list-cache-arm (cache function &key interval)

让 CACHE 每 INTERVAL 秒调用 FUNCTION，直到被 disarm。

**参数。** CACHE 是 list cache。FUNCTION 是零参函数，通常是加载 `etaf-list-cache-next` 返回 key 的函数。INTERVAL 覆盖 cache 自己的 interval 作为定时器周期。

**语义。** arm 先 disarm 上一个循环，再重新 start cache 并安装一个重复定时器，因此 arm 两次是替换定时器而不是叠加，并重启 grace 期。函数在 Emacs 定时器队列上运行；`etaf-list-cache-disarm` 永久停止该循环。

**返回。** CACHE。

**错误。** 无。

**参见。** `etaf-list-cache-disarm`、`etaf-list-cache-armed-p`。

#### Function: etaf-list-cache-armed-p (cache)

返回 CACHE 是否装有后台刷新定时器。

**参数。** CACHE 是 list cache。

**返回。** 装有定时器时非 nil；`etaf-list-cache-disarm` 之后为 nil。

**错误。** 无。

#### Function: etaf-list-cache-disarm (cache)

停止 CACHE 的后台刷新并清除忙标记。

**参数。** CACHE 是 list cache。

**语义。** disarm 取消定时器、清除活跃启动时间与忙标记，因此已 disarm 的 cache 即使条目变旧也不再启动后台工作。在拥有它的 session 释放时调用。disarm 已 disarm 的 cache 无害。

**返回。** CACHE。

**错误。** 无。

**参见。** `etaf-list-cache-arm`、`etaf-list-cache-next`。

## 失败、退避与忙态

<!-- index: etaf-list-cache-note-failure; 退避; stop code; 忙标记 -->

#### Function: etaf-list-cache-note-success (cache)

记录一次加载成功：清除失败退避与任何暂停。

**参数。** CACHE 是 list cache。

**语义。** 在所有加载路径（前台或后台）调用它。它把失败计数归零、清除重试时间并解除 stop code 暂停，于是后台刷新可以重新开始。

**返回。** CACHE。

**错误。** 无。

**参见。** `etaf-list-cache-note-failure`、`etaf-list-cache-blocked-p`。

#### Function: etaf-list-cache-note-failure (cache &optional code)

记录一次以错误 CODE 失败的加载并限制重试。

**参数。** CACHE 是 list cache。CODE 是 backend 报告的失败类别。

**语义。** CODE 缺失或未知时下一次尝试退避：延迟从新鲜度 interval 开始，此后每次失败翻倍，上限为最大退避。CODE 列在 cache 的 stop code 里表示需要人工处理——登录过期、流程被阻断——cache 于是完全暂停后台刷新，直到一次加载成功；暂停期间没有重试时间。

**返回。** CACHE。

**错误。** 无。

**参见。** `etaf-list-cache-note-success`、`etaf-list-cache-retry-at`、`etaf-list-cache-blocked-p`。

#### Function: etaf-list-cache-blocked-p (cache)

返回 CACHE 是否已暂停后台刷新直到加载成功。

**参数。** CACHE 是 list cache。

**返回。** stop code 失败后非 nil，成功之后为 nil。

**错误。** 无。

#### Function: etaf-list-cache-retry-at (cache)

返回 CACHE 在此时间之前不开始后台刷新，没有则为 nil。

**参数。** CACHE 是 list cache。

**语义。** 值是上次失败设置的、自纪元起的绝对秒数。成功加载清除它；stop code 失败让 cache 暂停期间它保持 nil。

**返回。** 重试时间；没有待决退避时为 nil。

**错误。** 无。

#### Function: etaf-list-cache-busy-p (cache)

返回 CACHE 是否有后台刷新在途。

**参数。** CACHE 是 list cache。

**返回。** 忙标记的布尔值。

**错误。** 无。

**参见。** `etaf-list-cache-set-busy`。

#### Function: etaf-list-cache-set-busy (cache busy)

记录 CACHE 有或没有后台刷新在途。

**参数。** CACHE 是 list cache；BUSY 非 nil 表示刷新正在运行。

**语义。** 调用方在开始后台加载前把 cache 标为忙，在回复到达时清除；这就是一次只跑一个刷新的机制；忙时 `etaf-list-cache-next` 返回 nil。

**返回。** CACHE。

**错误。** 无。

```elisp :run
(etaf-define-component demo-paged-rows ()
  :bindings ((controller
              (etaf-data-controller
               (etaf-data-memory-source
                (cl-loop for i from 1 to 10000
                         collect (list :id i :name (format "第 %d 行" i)))
                :id-key :id)
               :page-size 8 :auto-load t)))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (text :color (etaf-theme-token :ui-muted-fg "#526174")
                (expr (format "共 %s 行；一次只渲染当前 8 行"
                              (etaf-value (etaf-data-total controller)))))
          (text :for (item (etaf-value (etaf-data-items controller)))
                :key (plist-get item :id)
                (expr (plist-get item :name)))
          (etaf-pagination :controller controller)))
(etaf-view (demo-paged-rows))
```

## 错误与恢复

| 失败 | 会发生什么 |
| --- | --- |
| `etaf-list-cache-put` 收到负数或非数字 AT | `wrong-type-argument`；该 key 保留先前的条目 |
| 后台加载以普通代码失败 | 下一次尝试等待——interval 起，每次翻倍至最大退避 |
| 后台加载以 stop code 失败 | 刷新暂停，直到 `etaf-list-cache-note-success` |
| 后台回复与缓存的行和总数相等 | `etaf-list-cache-unchanged-p` 让调用方跳过重绘 |
| 条件回复为 not modified | `etaf-list-cache-touch` 刷新时间并保留行 |
| session 被释放 | `etaf-list-cache-disarm` 停止定时器，不再返回候选 |
