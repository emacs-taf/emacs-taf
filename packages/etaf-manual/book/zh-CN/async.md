# 异步模型

不是每个 loader 都能在启动它的那一次调用里结束：一次文件读取、一次 SQLite 查询或一个子进程可能稍后完成，来自定时器或进程过滤器。Resource 与 Data Controller 用同一套加载生命周期承载这类工作。loader 返回一个*异步适配器*，描述如何启动工作；收到它的所有者启动工作、施加可选的超时、记录恰好一个结果，并丢弃已作废的完成。本章描述这个适配器，以及每个所有者都遵守的规则。[Resource](resources.md)、[Data Source](data-sources.md)、[Data Controller](data-controllers.md)、[和解](reconciliation.md) 与 [List Cache](list-cache.md) 各章定义各个所有者本身；工作由哪个 Scope 承载见[响应式系统](reactivity.md#scope)，下文错误的父条件见[响应式系统](reactivity.md#错误与恢复)。

## 加载生命周期

<!-- index: 异步适配器; 加载请求; 待决请求; 作废请求 -->

loader 或 Data source 操作可以返回普通值、结果包装或异步适配器。前两者在同一次调用里完成请求。适配器是惰性的：构造它不启动任何东西。所有者发起请求时，在自己的 Scope 里调用 loader，然后驱动返回的东西；因此适配器没有自己的状态，也没有自己的生命周期——它不是可以等待的 promise，把它从 loader 或 source 操作以外的地方返回也不会启动任何东西。

每个请求最多产生一个结果。适配器的 RESOLVE 交付普通结果，REJECT 交付条件数据；两者中先调用的一方完成请求，之后交付的任何东西都到不了所有者的状态。请求待决期间，所有者把它和超时、取消句柄放在一起持有；新的加载会在开始前把上一个请求变为作废。

loader、适配器的启动函数与完成回调都在所有者的 Scope 里运行，所以其中创建的副作用、子 Scope 与清理函数都归所有者所有，随它释放（[响应式系统](reactivity.md#scope)）。完成可能来自本线程稍后的原生定时器或进程过滤器；因此适配器要自己安排完成，绝不阻塞启动它的那次调用。完成回调不在任何响应式批里，所有者把它的结果发布为一次更新，应用代码若在完成时写多个值则用 `etaf-batch` 开批（[响应式系统](reactivity.md#异步代码)）。

loader 失败会成为可观察状态，而不是抛给调用方的错误：同步 loader 报错与 REJECT 同等对待，所有者把条件记录在应用读取状态、值和错误的地方。所有者自身的发布、渲染或清理抛出的错误不是 loader 失败，照常上抛。

## 描述异步操作

<!-- index: etaf-async; 惰性加载器; 启动函数 -->

适配器用一个函数写成：`etaf-async` 只捕获 START，别的什么都不做。所有者在启动请求时提供 RESOLVE 与 REJECT 这对函数，因此一个适配器值描述的是尚未启动的工作。

#### Function: etaf-async (start)

用 START 描述一个惰性异步 loader。

**参数。** START 是一个函数，接收两个参数 RESOLVE 与 REJECT，二者都是函数。它必须不阻塞地启动工作，并可以返回一个零参取消函数或 nil。

**语义。** 返回值是描述符，不是运行中的操作：它捕获 START，等待拥有它的 Resource 或 Data Controller 启动。所有者启动请求时，用一对只完成该请求的 RESOLVE 与 REJECT 调用 START 一次。RESOLVE 收普通 loader 结果；REJECT 收 Emacs 条件数据。两者中先调用的一方完成请求，之后的完成被忽略。返回 nil 而不是取消函数，只表示所有者没有可停止的外部工作；请求在被替换、取消或释放时照样变为作废，它的迟到完成照样被丢弃。

**返回。** 异步描述符。

**错误。** START 不是函数时 `error→ wrong-type-argument`，数据为 `(functionp START)`。

**示例。**

```elisp
(let ((resource (etaf-resource
                 (lambda ()
                   (etaf-async (lambda (resolve _reject)
                                 (funcall resolve 'rows)
                                 nil))))))
  (list (etaf-resource-status resource)
        (etaf-resource-value resource)))
;; ⇒ (success rows)
```

**参见。** `etaf-resource`、`etaf-resource-result`、`etaf-data-source`。

```elisp :figure load 只结算一次；取消与超时走同一条路径
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 0)
   (row :item-gap '(ch 1)
     (box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "load"))
     (box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
          (text :color (etaf-theme-token :ui-accent "#0969da") "完成一次"))
     (box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
          (text :color (etaf-theme-token :ui-disabled-fg "#687386") "取消"))
     (box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
          (text :color (etaf-theme-token :ui-disabled-fg "#687386") "超时")))
   (text :color (etaf-theme-token :ui-muted-fg "#526174") "晚到的结果被丢弃；取消与超时沿同一路径结算。")))
```

## 只完成一次

<!-- index: resolve; reject; 条件数据; 首个完成 -->

RESOLVE 收普通 loader 结果，即 loader 同步返回时会给出的同一个值；所有者定义了 `etaf-resource-result` 这样的结果包装时，RESOLVE 收到的是包装，从而让结果带上清理函数。REJECT 收 Emacs 条件数据，即 car 为符号的 proper 列表。由于数据会被记录，也可能被重新抛出为条件，它会被校验：不合形的数据被替换为 `etaf-async-error`，数据为 `("Rejection must be condition data" VALUE)`，这样所有者记录到的失败总是良构的。

对任一函数的重复调用，或在请求变为作废之后才到达的调用，都被静默忽略。正因如此，即使事件源很吵，一次性适配器也是安全的：定时器可能触发，进程过滤器可能运行，但请求结束之后交付的完成就是到不了所有者。

## 取消

<!-- index: 取消; 取消函数; 被取代的请求 -->

START 可以返回一个零参取消函数，请求被取消、替换、释放或超时时，所有者至多调用它一次。请求先被置为作废，因此取消函数自身触发的完成也会被丢弃而不是发布。返回 nil 则表示外部工作停不下来；请求照样失效、完成照样被忽略，所以没有取消函数的适配器同样可以安全替换。

取消从不自动重试，也不回滚外部工作。所有者可以自由发起新请求——被取消的读取可以重新加载——而被取代的写入交给和解处理，不会被静默重放（[和解](reconciliation.md)一章）。

## 超时

<!-- index: 超时; :timeout; 等待超时 -->

所有者可以给请求一个以秒计的超时，取 nil 或正数，只作用于异步等待。等待超过它时，所有者按取消同样的方式中止请求：运行取消函数、把结果记录为 `etaf-async-timeout`，数据为 `(TIMEOUT)`，并丢弃此后到达的任何完成。完成或被取消的请求会释放自己的定时器，因此另一个结果记录之后超时不会再触发。所有者在启动任何工作前校验超时；取值不是 nil 或正数时抛出 `etaf-async-error`，数据为 `("Timeout must be nil or positive seconds" VALUE)`。

## 迟到结果

<!-- index: 迟到结果; 丢弃; 丢弃时清理 -->

请求一旦有结果，之后的结果被忽略。请求一旦被替换、取消、超时或释放，它的第一个迟到完成被丢弃：普通值直接丢掉，结果包装的清理函数则在那一刻运行而不是发布，因此 loader 打开的 resource 不会泄漏。第一个被丢弃的完成之后的完成被忽略。

请求因替换或释放而作废时，丢弃是静默的；因取消或超时而作废时，对应的条件被记录为结果；每个所有者章说明各自的接口报告哪些状态。无论哪种情况，作废的完成都不碰所有者已发布的状态。

## 子进程

<!-- index: 子进程; 命令行后端; 进程作业 -->

许多应用通过一个命令行程序与后端通信，这个程序打印一个答案后退出。`etaf-process-run` 在不阻塞 Emacs 的情况下运行这样的程序并报告一个结果，之后作业就结束了。协议（退出码与输出字段的含义）留给调用者；作业只保证结果如何收集与送达。

#### Function: etaf-process-run (command &key callback timeout environment directory (output 'string) (coding 'utf-8-unix) name)

不阻塞地运行 COMMAND，并返回一个作业。

**参数。**

- COMMAND 是非空字符串列表：程序及其参数。不经过 shell。
- CALLBACK 是 nil 或单参函数，参数是结果 plist。
- TIMEOUT 是 nil 或正的秒数。
- ENVIRONMENT 是 `"NAME=VALUE"` 字符串列表，放在 `process-environment` 前面，所以会覆盖继承来的值。
- DIRECTORY 是 nil 或工作目录；nil 使用 `default-directory`。
- OUTPUT 是 `string`（默认）或 `json`。
- CODING 是解码两条流所用的编码系统，默认 `utf-8-unix`；原始字节用 `binary`。
- NAME 是 nil 或 `list-processes` 里显示的进程名。

**语义。** 程序的标准输出与标准错误分开。程序退出时，两条流都读到末尾后才送达结果，所以结果不会漏掉报告退出时仍在途中的输出。CALLBACK 收到一个 plist：

- `:status` 是 `exit`、`signal`、`timeout` 或 `failed`，`failed` 表示程序无法启动。
- `:exit` 是退出码，`signal` 时是信号编号。
- `:output` 是字符串形式的标准输出；OUTPUT 为 `json` 时是解析后的值：对象为 plist、数组为列表、null 为 nil、false 为 `:false`。空的或无效的 JSON 得到 nil。
- `:stderr` 是完整的标准错误文本。
- `:message` 描述超时或启动失败。

即使程序无法启动，CALLBACK 也绝不会在 `etaf-process-run` 返回之前运行，所以调用者可以先保存作业。它最多运行一次。TIMEOUT 先到期时，进程被停止，结果的状态为 `timeout`。

**返回。** 一个作业，传给 `etaf-process-cancel` 与 `etaf-process-live-p`。

**错误。** COMMAND 不是非空字符串列表、TIMEOUT 不是正数，或 OUTPUT 既不是 `string` 也不是 `json` 时 `error→ wrong-type-argument`。程序本身的问题是结果，不是错误。

**示例。** 一个 Resource 通过命令行客户端加载订阅源，替换或释放该 Resource 会停止进程。

```elisp
(etaf-async
 (lambda (resolve reject)
   (let ((job (etaf-process-run
               '("feed-client" "list" "--json")
               :output 'json :timeout 20
               :callback
               (lambda (result)
                 (if (eql (plist-get result :exit) 0)
                     (funcall resolve (plist-get result :output))
                   (funcall reject
                            (list 'error (or (plist-get result :message)
                                             (plist-get result :stderr)))))))))
     (lambda () (etaf-process-cancel job)))))
```

#### Function: etaf-process-cancel (job)

停止 JOB 且不运行它的回调；JOB 尚未结算时返回非 nil。

**语义。** 进程被删除、作业被结算，所以已在途中的结果会被丢弃。取消已结算的作业不做任何事并返回 nil。

#### Function: etaf-process-live-p (job)

JOB 既未结算也未被取消时返回非 nil。

**语义。** 作业从 `etaf-process-run` 返回起一直是活的，直到它的回调被调用或它被取消。用它避免在一个请求未完成时再启动第二个。

## 错误与恢复

<!-- index: etaf-async-error; etaf-async-timeout; etaf-async-cancelled -->

#### Error: etaf-async-error

无效的异步适配器或超时。父条件为 `etaf-reactive-error`。

**语义。** 表示适配器或请求超时不合形：工作根本没启动，或它的完成数据无法解释。用 `condition-case` 捕获；抛出它的调用不返回值。所有者从启动函数收到该条件时，把它记录为请求的失败，因此它与 loader 失败一样可观察。

**原因。** 启动函数返回既不是取消函数也不是 nil 的值；REJECT 收到不是条件数据的数据；所有者的 TIMEOUT 不是 nil 或正数。START 不是函数的情况更早被拒绝，抛出 `wrong-type-argument`。

**恢复。** 没有东西可以重试：修正启动函数、拒绝数据或超时，然后发起新请求。所有者保持先前状态。

**参见。** `etaf-async`、`etaf-async-timeout`、`etaf-async-cancelled`。

#### Error: etaf-async-timeout

异步等待超过其超时。父条件为 `etaf-async-error`。

**语义。** 请求仍待决时，所有者的超时耗尽。所有者已经运行适配器的取消函数，该条件被记录为请求的结果；之后的完成无法发布。数据为 `(TIMEOUT)`，即允许的秒数。

**恢复。** 超时从不证明外部工作没有发生。读取可以重新开始；对写入来说结果不确定，所有者的和解状态描述这种不确定性（[和解](reconciliation.md)一章）。超时从不证明回滚。

**参见。** `etaf-async`、`etaf-async-error`。

#### Error: etaf-async-cancelled

待决工作被取消。父条件为 `etaf-async-error`。

**语义。** 所有者取消了一个待决请求，或用新请求取代了它。第一个迟到的完成被丢弃——带清理函数时连清理一起——取消显式发生时，该条件被记录为请求的结果。取消是刻意行为，本身不说明外部操作是否已经生效。

**恢复。** 所有者可以重新加载；被取消的读取从头开始，被取代的写入交给和解而不是自动重放。与超时一样，取消从不证明回滚。

**参见。** `etaf-async`、`etaf-async-error`。

| 失败 | 还会剩下什么 |
| --- | --- |
| loader 抛错，或 REJECT 交付一个条件 | 请求以该条件完成，成为所有者的错误状态；之后的完成被忽略 |
| 超时耗尽 | 取消函数已运行，`etaf-async-timeout` 被记录，之后的完成被丢弃 |
| 请求被替换或释放 | 上一个请求作废；它的第一个迟到完成被丢弃，清理函数运行；新请求不受影响 |
| 适配器或超时不合形 | 在检测到不合形值的地方抛出 `etaf-async-error`；不为它运行请求，先前状态保留 |
