# 性能工程

框架保持一份很小的计时契约：Runtime 可以为它执行的一次 operation 的每个 stage 发出扁平报告，观察者接收这些报告。性能工程就是消费这份契约的东西——可选的 `etaf-performance-*` 记录器，把报告变成保留的 operation 记录与可携带报告；以及工作区的场景与预算工具，通过已挂载的应用测量端到端工作。本章定义记录器的公共接口，描述一条已记录的 operation 包含什么，并给出让一个数字可信的测量与诊断规则。它不给渲染路径增加任何东西：没有观察到观察者时，operation 直接运行，记录器不会进入任何决策。

## 记录器与报告模型

<!-- index: operation; stage; 报告; 观察者契约 -->

描述一次测量有三个层次。一个 *operation* 是一个有界的运行时工作单元，用 kind 与 label 打开、工作结束时闭合；一个 Runtime 同时最多运行一个 operation，嵌套调用并入已打开的那个，而不是打开第二个。一个 *stage* 是 operation 内一个 provider 发出的报告——Runtime 自己的计时，以及工作写了缓冲区时描述这次写入的 Ebox flush 报告。一份 *report* 是已完成 operation 的保留、可携带视图：不可变的 operation 记录，加上环境快照、摘要与机器可读的 operation 列表。

记录器自己不计时。Runtime 与它的 provider 给各自的 stage 计时并发出扁平 plist；记录器把一条 operation 的报告收拢起来，把闭合的 operation 存进有界环形缓冲。这就是为什么开启记录改变的是你看到的东西，而不是框架做的事。

挂载记录器是显式、按 Runtime 进行的。一个 Runtime 接受一个观察者；`etaf-performance-start` 认领它，`etaf-performance-stop` 释放它，被别的观察者拥有的 Runtime 不会被悄悄接管。`etaf-performance-mode` 是便利包装：它把记录器挂到当前缓冲区的 Runtime 上，关闭时摘下。

## 记录器的生命周期

<!-- index: 记录器生命周期; 保留上限 -->

#### Function: etaf-performance-mode (&optional arg)

记录当前缓冲区所挂载 Runtime 的 operation。

**参数。** ARG 遵循次模式惯例：nil 或省略开启模式，正数开启，零或负数关闭，`toggle` 取反。

**语义。** 开启时查找缓冲区已挂载的 Runtime，并经 `etaf-performance-start` 挂上记录器；缓冲区没有 Runtime 时模式保持关闭并报告。关闭时摘下这个模式建立的 attachment。变量 `etaf-performance-mode` 报告状态，记录期间模式行显示 `ETAF-Perf`。

**返回。** 模式变量。

**错误。** error→ `user-error` `"Current buffer has no mounted ETAF runtime"`：在没有 Runtime 的缓冲区里开启时。挂载失败（例如已有别的观察者）传播它自己的条件，模式保持关闭。

**参见。** `etaf-performance-start`、`etaf-performance-stop`。

#### Function: etaf-performance-start (runtime)

把记录器挂到已挂载的 RUNTIME 上并返回 RUNTIME。

**参数。** RUNTIME 是一个已挂载的 Runtime。

**语义。** 对同一个记录器，挂载是幂等的：在它已经拥有该 Runtime 时再调用，保持同一个 attachment 与未完成的 operation。已被别的观察者拥有的 Runtime 会被拒绝而不是替换，所以两个记录器永远不会分掉同一个 Runtime 的报告。后续 stage 永远不会到达的未完成 operation 在 attachment 结束时丢弃。

**返回。** RUNTIME。

**错误。** error→ `etaf-runtime-error`：RUNTIME 未挂载时。error→ `error` `"ETAF runtime already has a different observer"`：别的观察者拥有它时。

**示例。**

```elisp
(let* ((buffer (etaf-mount "*work*" view))
       (runtime (etaf-runtime-for-buffer buffer)))
  (etaf-performance-start runtime)
  (etaf-performance-with-operation (runtime 'refresh "reload")
    (etaf-set-value count 1)))
```

**参见。** `etaf-performance-stop`、`etaf-performance-mode`。

#### Function: etaf-performance-stop (runtime)

从 RUNTIME 摘下这个记录器并返回 RUNTIME。

**参数。** RUNTIME 是一个 Runtime。

**语义。** 记录器的 attachment、它未完成的 operation 与观察者所有权一起释放。若别的观察者已经替换了记录器的 sink，则保留该观察者，只丢弃记录器的记账。停止一个记录器从未挂载的 Runtime 是空操作。

**返回。** RUNTIME。

**错误。** error→ `wrong-type-argument` `(etaf-runtime-p X)`：RUNTIME 不是 Runtime 对象时。

**参见。** `etaf-performance-start`。

#### Function: etaf-performance-clear ()

清除已完成与未完成的性能记录。

**语义。** 每条保留的 operation 与每条未完成的 operation 都被丢弃。性能面板若开着，会被还原成空集。记录器的 attachment 不受影响：清空之后记录继续。

**返回。** nil。

**参见。** `etaf-performance-records`、`etaf-performance-show`。

#### Variable: etaf-performance-max-records

记录器保留的已完成 operation 上限。

**语义。** 默认 200。记录器按这个大小维持环形缓冲，超过上限时丢弃最旧的已完成 operation；调小时，下一次 operation 完成时按最新记录重建环形缓冲。零表示停止保留：下一次完成会丢弃已保留的集合、什么都不留。上限只覆盖已完成 operation；仍在进行中的不计入。

**参见。** `etaf-performance-records`、`etaf-performance-clear`。

## 运行一次 operation

<!-- index: operation 边界; 嵌套 -->

#### Macro: etaf-performance-with-operation ((runtime kind label) &rest body)

经 RUNTIME 的规范 operation 边界求值 BODY。

**参数。** RUNTIME 是已挂载的 Runtime，KIND 是 operation 符号，LABEL 是描述性字符串。BODY 是要做的工作。

**语义。** 宏打开一条 operation，求值 BODY，并用体的状态闭合这条 operation。同一个 Runtime 上的嵌套 `etaf-performance-with-operation` 并入已打开的 operation，而不是打开第二条；另一个 Runtime 上的嵌套调用不被这一条观察到。只有记录器拥有该 Runtime 的观察者时，operation 的报告才会发出。

**返回。** BODY 的值。

**错误。** BODY 的错误与退出被记为 operation 的状态，然后原样重抛；operation 仍然闭合。

**示例。** 一次写 ref 后读回记录中 stage 耗时的刷新。

```elisp
(etaf-performance-with-operation (runtime 'refresh "reload")
  (etaf-set-value query "etaf"))
```

**参见。** `etaf-performance-call-operation`、`etaf-performance-records`。

#### Function: etaf-performance-call-operation (runtime kind label function)

经 RUNTIME 的 operation 边界把 FUNCTION 当作 KIND 与 LABEL 调用。

**参数。** RUNTIME 是已挂载的 Runtime，KIND 是 operation 符号，LABEL 是字符串，FUNCTION 是无参函数。

**语义。** `etaf-performance-with-operation` 的函数形式，给必须以函数传递的回调使用，而不是就地写体。

**返回。** FUNCTION 的结果。

**错误。** error→ `etaf-runtime-error` `"ETAF runtime is not mounted"`：RUNTIME 未挂载时。error→ `wrong-type-argument` `(symbolp KIND)`、`(stringp LABEL)` 或 `(functionp FUNCTION)`：参数类型不对时。FUNCTION 自身的错误被记录并重抛。

**参见。** `etaf-performance-with-operation`。

## operation 记录

<!-- index: operation 记录; 耗时; 垃圾回收 -->

#### Function: etaf-performance-operation-p (x)

X 是已完成的 operation 记录时返回非 nil。

**语义。** 在从它读取槽位之前，用它检查集合里的值；否则槽位读取器报 `wrong-type-argument`。

**返回。** operation 记录返回非 nil，其它任何值返回 nil。

**参见。** `etaf-performance-records`。

#### Function: etaf-performance-operation-id (x)

读取 `etaf-performance-operation' 结构 X 的 "id" 槽。

**语义。** 身份是整数，在所属 Runtime 内唯一、随调用顺序递增。嵌套调用报告外层 operation 的身份。

**返回。** 整数身份。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-operation-kind`、`etaf-performance-operation-label`。

#### Function: etaf-performance-operation-runtime-id (x)

读取 `etaf-performance-operation' 结构 X 的 "runtime-id" 槽。

**语义。** 值是产生这条记录的 Runtime 的整数观察者报告身份，也就是 `etaf-performance-records` 用来过滤的身份、可携带报告以 `:runtime-id` 携带的身份。Runtime 存活期间它保持稳定；缓冲区名被复用或 Runtime 卸载之后，它仍能标识历史记录。

**返回。** 整数报告身份。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-records`、`etaf-performance-operation-id`。

#### Function: etaf-performance-operation-kind (x)

读取 `etaf-performance-operation' 结构 X 的 "kind" 槽。

**语义。** kind 是调用方传给 operation 边界的符号，例如 `refresh`、`event` 或包自定义的名字。`etaf-performance-summary` 就是按 kind 分组。

**返回。** operation 符号。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-operation-label`、`etaf-performance-summary`。

#### Function: etaf-performance-operation-label (x)

读取 `etaf-performance-operation' 结构 X 的 "label" 槽。

**语义。** label 是调用方传入的描述性字符串；它补充 kind，例如 kind `refresh` 配 label `"reload"`。记录器保存防御性副本。

**返回。** label 字符串。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-operation-kind`。

#### Function: etaf-performance-operation-status (x)

读取 `etaf-performance-operation' 结构 X 的 "status" 槽。

**语义。** 取 `success`（工作正常返回）、`error`（报了错）或 `quit`（被打断）之一。状态描述 operation 自身的结果，而不是缓冲区的状态；缓冲区状态由可携带报告里的修订号槽位描述。

**返回。** 三个状态符号之一。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-report-data`。

#### Function: etaf-performance-operation-elapsed (x)

读取 `etaf-performance-operation' 结构 X 的 "elapsed" 槽。

**语义。** 整条 operation 的墙钟耗时，单位毫秒，从打开计到闭合。它包含其中各 stage 的时间；它不是 stage 耗时之和，因为 stage 耗时可能重叠。

**返回。** 非负浮点毫秒数。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-operation-gc-elapsed`、`etaf-performance-operation-stage-summary`。

#### Function: etaf-performance-operation-gc-count (x)

读取 `etaf-performance-operation' 结构 X 的 "gc-count" 槽。

**语义。** operation 期间发生了多少次垃圾回收。耗时不长而次数很多，指向的是分配压力而不是慢代码。

**返回。** 非负整数。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-operation-gc-elapsed`。

#### Function: etaf-performance-operation-gc-elapsed (x)

读取 `etaf-performance-operation' 结构 X 的 "gc-elapsed" 槽。

**语义。** 这些垃圾回收花掉的时间，单位毫秒。operation 自身的耗时就包含它。

**返回。** 非负浮点毫秒数。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-operation-gc-count`。

#### Function: etaf-performance-operation-stages (x)

读取 `etaf-performance-operation' 结构 X 的 "stages" 槽。

**语义。** operation 的扁平 provider 报告，按发出顺序排列：Runtime 自己的 stage，以及工作期间有写入的 provider 的缓冲区 flush 报告。列表是防御性副本；改动它不会改动保留的记录。

**返回。** stage 记录列表。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation X)`：其它值时。

**参见。** `etaf-performance-stage-name`、`etaf-performance-operation-stage-summary`。

#### Function: etaf-performance-operation-stage-summary (operation)

按 category 汇总 OPERATION 里的扁平 provider stage。

**语义。** 每项含 `:category`、`:count` 与 `:duration-ms`，按耗时之和从大到小排序。该耗时是可能重叠的 provider 耗时之和，所以它只能给类别排序，永远不是独占时间；要看整体就读 operation 的 elapsed。

**返回。** `(:category :count :duration-ms)` plist 列表。

**错误。** error→ `wrong-type-argument` `(etaf-performance-operation-p OPERATION)`：OPERATION 不是 operation 记录时。

**示例。** 在 operation 里写一次 ref 之后，上面那条 operation 的摘要是：runtime 类一个 stage、ebox 类一个 stage；flush 更慢时 ebox 在前。

**参见。** `etaf-performance-stage-category`、`etaf-performance-summary`。

## stage 记录

<!-- index: stage 记录; provider; 类别 -->

#### Function: etaf-performance-stage-name (x)

读取 `etaf-performance-stage' 结构 X 的 "name" 槽。

**语义。** provider 报告过来的 stage 名，例如 Runtime 的闭合 stage 叫 `runtime-operation`，Ebox 的缓冲区写入叫 `flush`。

**返回。** 符号。

**错误。** error→ `wrong-type-argument` `(etaf-performance-stage X)`：其它值时。

**参见。** `etaf-performance-stage-provider`。

#### Function: etaf-performance-stage-provider (x)

读取 `etaf-performance-stage' 结构 X 的 "provider" 槽。

**语义。** 发出报告的层名符号，例如 `etaf` 或 `ebox`。provider 告诉你一项开销该去哪个层找主人。

**返回。** 符号。

**错误。** error→ `wrong-type-argument` `(etaf-performance-stage X)`：其它值时。

**参见。** `etaf-performance-stage-category`。

#### Function: etaf-performance-stage-category (x)

读取 `etaf-performance-stage' 结构 X 的 "category" 槽。

**语义。** 摘要使用的公共分组：ETAF Runtime 自身发出的报告归 `runtime`，其它 provider 保留自己的名字，所以 `flush` 报告归 `ebox`。类别是拿来趋势化的，provider 是拿来点名的。

**返回。** 符号。

**错误。** error→ `wrong-type-argument` `(etaf-performance-stage X)`：其它值时。

**参见。** `etaf-performance-operation-stage-summary`。

#### Function: etaf-performance-stage-status (x)

读取 `etaf-performance-stage' 结构 X 的 "status" 槽。

**语义。** 取 `success`、`error`、`quit` 之一，或 provider 不报告时为 nil。状态缺失表示 provider 认为这个 stage 正常。

**返回。** 状态符号或 nil。

**错误。** error→ `wrong-type-argument` `(etaf-performance-stage X)`：其它值时。

**参见。** `etaf-performance-operation-status`。

#### Function: etaf-performance-stage-duration (x)

读取 `etaf-performance-stage' 结构 X 的 "duration" 槽。

**语义。** 该 stage 自己的耗时，单位毫秒，由它的 provider 测量。各 stage 的 provider 耗时可能彼此重叠，所以只单独比较或按类别汇总，绝不加成一个独占总数。

**返回。** 非负浮点毫秒数。

**错误。** error→ `wrong-type-argument` `(etaf-performance-stage X)`：其它值时。

**参见。** `etaf-performance-stage-metadata`。

#### Function: etaf-performance-stage-metadata (x)

读取 `etaf-performance-stage' 结构 X 的 "metadata" 槽。

**语义。** 报告里类型化 stage 字段没有表示的、provider 特有的字段。Ebox 的 flush stage 在这里带上更新报告的策略、编辑数、行数、范围与 flush 计数器，所以记录器给出的细节与 `ebox-buffer-update-report` 相同，而不需要第二条采集路径。值是防御性副本，内容可能是 provider 报告的任何值。

**返回。** plist，可能为空。

**错误。** error→ `wrong-type-argument` `(etaf-performance-stage X)`：其它值时。

**参见。** `etaf-performance-stage-duration`、`ebox-buffer-update-report`。

## 记录、摘要与报告

<!-- index: 可携带报告; 摘要; 导出 -->

#### Function: etaf-performance-records (&optional runtime-id)

返回已完成记录的不可变快照，最新在前。RUNTIME-ID 非 nil 时只选该整数观察者报告身份，它由 `etaf-performance-operation-runtime-id` 给出、也是可携带报告里的 `:runtime-id`。这也会选中缓冲区名被复用或 Runtime 卸载之后的历史记录。省略或 nil 的 RUNTIME-ID 选中全部保留记录。

**参数。** RUNTIME-ID 是整数身份或 nil。

**语义。** 每条记录都是保留 operation 的隔离副本，调用方可以保存、打印或改写它而不影响记录器；最新完成的 operation 排在最前。这个身份是 Runtime 的挂载身份，可携带报告数据里每条 operation 都带着它；按它过滤，是在缓冲区名后来被复用时继续追踪同一个 Runtime 的方式。因为记录在卸载之后仍然保留，这也是 Runtime 被释放之后的读取集合。

**返回。** operation 记录列表，最新在前。

**错误。** error→ `wrong-type-argument` `(integerp RUNTIME-ID)`：参数既非 nil 又非整数时。

**示例。** 挂上记录器并运行一次操作后，测试断言存在一条已记录 operation。

```elisp
(etaf-performance-with-operation (runtime 'demo "work") 42)
(etaf-performance-operation-kind (car (etaf-performance-records)))
     ⇒ demo
```

**参见。** `etaf-performance-report-data`、`etaf-performance-max-records`。

#### Function: etaf-performance-report-data (&optional (records (etaf-performance-records)))

为已完成的 RECORDS 返回一份脱离记录器的可携带报告。省略 RECORDS 会选中保留记录，显式 nil 一个都不选。带版本的 plist 含 :format-version、:environment、:summary 与 :operations。每条 operation 标识 :id、:runtime-id 与 :buffer-name，并含扁平的 :stages，每项带 :provider、:stage、:duration-ms 与 provider 的 :metadata。嵌套 provider 的耗时可能重叠。这个只读操作不清空记录、不安装观察者、不改动 Runtime，也不调用被记录的应用代码。

**参数。** RECORDS 是 operation 记录列表，或 nil 表示空报告。

**语义。** 报告是交换格式：它与记录器分离、带 `:format-version` 版本（当前 2）、按从旧到新排序，读者可以按时间顺序重放一次会话。每条 operation 还带前后修订号、elapsed、status、GC 计数与 stage 摘要；每个 stage 带扁平 provider 字段。省略 RECORDS 与显式 nil 不同：省略报告全部保留内容，nil 给出空 operation 列表加环境与空摘要。

**返回。** 含 `:format-version`、`:generated-at`、`:environment`、`:summary` 与 `:operations` 的 plist。

**参见。** `etaf-performance-summary`、`etaf-performance-environment-data`、`etaf-performance-export`。

#### Function: etaf-performance-summary (&optional (records (etaf-performance-records)))

按 operation kind 与 label 汇总已完成的 RECORDS。省略 RECORDS 会选中全部保留记录，显式 nil 一个都不选。

**参数。** RECORDS 是 operation 记录列表。

**语义。** 每组是一个 kind 与 label 组合，每项含 `:count`、`:min-ms`、`:p50-ms`、`:p95-ms`、`:max-ms` 与 `:mean-ms`，按 p95 从大到小排序。百分位按最近秩取该组 elapsed 的实际观测值，所以小样本报告的是真实观测而不是插值。摘要描述的是 *operation*——整个请求的延迟；时间花在哪一段，用 `etaf-performance-operation-stage-summary`。

**返回。** 摘要 plist 列表；没有可汇总内容时为 nil。

**错误。** error→ `wrong-type-argument`：RECORDS 既非 nil 也非 operation 记录列表时。

**参见。** `etaf-performance-report-data`、`etaf-performance-operation-stage-summary`。

#### Function: etaf-performance-copy-report ()

把所有保留的性能记录复制到 kill ring。

**语义。** 命令写出与 `etaf-performance-export` 相同的可读 `;; ETAF performance report` 文本，放进 kill ring，并在回显区报告 operation 数。它是把报告粘进消息或 issue 的交互方式。

**返回。** 报告字符串。

**参见。** `etaf-performance-export`、`etaf-performance-show`。

#### Function: etaf-performance-export (file)

把所有保留的性能记录导出到 FILE。

**参数。** FILE 是目标路径。交互调用时从 minibuffer 读取，建议带时间戳的 `.eld` 名。

**语义。** 文件收到与 `etaf-performance-copy-report` 相同的可读报告文本，写成完整的 Elisp 数据。已存在的文件会被拒绝而不是覆盖，所以导出永远不会毁掉更早的测量；回显区报告 operation 数与缩写路径。

**返回。** FILE。

**错误。** error→ `file-already-exists` `("File exists" FILE)`：FILE 已存在时。error→ `file-error`：路径不可写或是目录时。

**参见。** `etaf-performance-copy-report`、`etaf-performance-report-data`。

#### Function: etaf-performance-show ()

在表格化的面板里显示保留的 ETAF operation 与 stage。

**语义。** 面板每条 operation 一行，随后它的每个 stage 一行，列为身份、类型、名字、类别、provider、sequence、耗时与状态；头部行重复环境快照，所以一张截图自带它的上下文。面板里 `c` 运行 `etaf-performance-copy-report`，`w` 运行 `etaf-performance-export`。再次调用命令复用面板缓冲区。

**返回。** nil；面板用 `pop-to-buffer` 显示。

**参见。** `etaf-performance-copy-report`、`etaf-performance-export`、`etaf-performance-clear`。

#### Function: etaf-performance-environment-data ()

返回用于解读延迟记录的环境快照。

**语义。** 快照在生成报告时取得，而不是在 operation 运行时，它记录决定两次测量可不可比的事实：Emacs 版本、系统类型、窗口系统与帧是否图形、帧与窗口的像素尺寸、GC 阈值与百分比、原生编译设置、负载均值，以及本机电源状态。电源状态报告当前来源（`battery`、`ac` 或 `unknown`）与系统低电量模式是开、关还是未知；读不到的系统两项都是 `unknown`，这是关于测量的陈述，不是错误。

**返回。** 含上述键的 plist。

**参见。** `etaf-performance-report-data`。

## Ebox 的更新报告

<!-- index: flush stage; 更新报告 -->

当一次 operation 写缓冲区时，Runtime 的 provider 路径把 Ebox 的 flush 报告转成名为 `flush`、provider 与类别都是 `ebox` 的 stage。它的耗时是测到的 flush 时间，它的 metadata 就是那份 flush 报告：策略、编辑范围数、行数、范围与 flush 计数器——与 `ebox-buffer-update-report` 返回、`ebox-buffer-set-observer` 交付的是同一份信息。因此记录器同时给出两个层次的每条 operation 成本：整条 operation 的耗时，以及它各 stage 中的 flush。

这个 stage 也是把一次慢更新连回造成它的损坏的地方。`:lines` 与 `:ranges` 都大的 flush 确实做了很多工作；只有一处编辑却耗时不短的 flush，指向的是沉重的布局或绘制边界，而不是宽泛的写入。[增量更新与发布](incremental-updates-and-publication.md)一章定义报告字段，[一次更新的完整追踪](update-trace.md)走产生 flush 的那次提交。

## 性能场景与预算

<!-- index: 性能场景; 基线; 预算 -->

记录器回答「这次 operation 的时间花在哪」。工作区的场景工具回答「这次改动有没有让应用变慢」，它才是受维护的测量方式：`make perf-list` 列出包在 `benchmarks/performance-scenarios.el` 里注册的场景，`scripts/performance.py run` 在 batch 或 GUI 模式下执行一个场景，带延迟、trace、CPU 与分配几趟，并可选择诊断。`python3 scripts/performance.py gate` 在 GUI server 内按固定预算跑快速的逐改动检查，`compare` 与 `summarize` 检查保存的证据，`make verify-baseline` 加上 `make verify BASELINE=…` 生成并核对批量性能门禁；最终验收结论用三组独立采样。

两条规则让数字有意义。改动前后测同一个场景、同一份检出状态；证据无效或不完整的运行算未验证，而不是通过。并且把批量测量与 GUI 测量分开：批量运行近似 operation 与 CPU 成本，而真实渲染与输入延迟必须在 GUI 会话里测量，因为只有那里才有重绘与输入调度的参与。

## 诊断方法

<!-- index: 主导成本; 重叠; 证据 -->

诊断从一条已记录的 operation 出发，而不是从一个猜想。把记录器挂到慢的那个 Runtime 上，走一遍确切的那次交互，读 `etaf-performance-show` 或该 operation 的 stage 摘要；最大的类别就是第一候选。然后缩小它：`:ranges` 很大的 `ebox` flush stage 是布局或损坏问题；Ebox 时间很少的 `etaf` runtime stage 是应用或响应式记账；耗时不长而 GC 次数很多指向分配。provider 耗时可能重叠，所以要在同一条 operation 内比较类别与 stage，而不是把它们相加。

一次只改一件事，然后重测同一个场景，对比修订号、flush 计数与你预期会动的那个 stage 类别；测不出改善的改动应当回退。原始证据留在版本控制之外，在打开具体日志之前先看紧凑结果。当问题不是单条 operation——一次滚动、一次缩放、反复编辑——用场景工具，因为一条记录看不出分布；而当症状是视觉或交互时，最后要在 GUI 里收尾，因为批量数字不能证明外观或输入延迟。

## 错误与恢复

<!-- index: 记录器错误; 观察者冲突; 卸载 -->

记录器的错误都是普通的参数与状态错误，而且都不会破坏已经记录的内容。从错误类型的值读取槽位报 `wrong-type-argument`，数据是 operation 或 stage 谓词与那个值；`etaf-performance-records` 同样拒绝非整数过滤器；`etaf-performance-summary` 拒绝非列表集合。经 `etaf-performance-start` 挂到未挂载的 Runtime 报 `etaf-runtime-error`；挂到别的观察者拥有的 Runtime 报普通错误 `"ETAF runtime already has a different observer"`，并让观察者原样留在那里——记录器从不从别的观察者手里抢 Runtime。在没有 Runtime 的缓冲区里开启模式报 `user-error`，模式保持关闭。

未完成的 operation 不会泄漏：attachment 停止时，它还在收集的 operation 被丢弃；Runtime 卸载之后再 stop 仍然释放记录器的记账并返回 Runtime，因为观察者交换是被容错的。保留的记录在卸载之后仍在，所以事后读 `etaf-performance-records` 时缓冲区可能已经没了；挂到另一个 Runtime 上的新 attachment 有自己的未完成集合。`etaf-performance-clear` 同时丢弃已完成与未完成的记录，这是会话收集了噪声时的恢复步骤。停止后的记录器让 Runtime 的观察者保持 `etaf-performance-stop` 看到的样子，所以移除记录会无残留地回到未观察路径。
