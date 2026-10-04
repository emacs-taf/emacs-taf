# 工作区开发工具

[English](manual.md)

工作区维护共用的开发命令：`scripts/elisp.py` 跨各仓库查找和运行 Lisp，
`scripts/performance.py` 是唯一的测量驱动。各包在 `benchmarks/performance-scenarios.el` 注册长期维护的
场景，提供应用初始化、操作和验证条件；计时、profiler、超时和基线比较由通用工具负责。

## 查找和运行 Lisp

`scripts/elisp.py` 读取工作区各仓库下的全部 `.el` 文件，跳过 `.jj`、`.worktrees`
等隐藏目录。查一个定义只需一条命令，不必先搜索再猜行号范围；批量运行也不必手写
`load-path`。

```sh
python3 scripts/elisp.py def ebox-surface--project etaf-ecosystem-require
python3 scripts/elisp.py refs ebox-surface--project
python3 scripts/elisp.py run -p etaf-desktop -e '(featurep (quote etaf-desktop))'
python3 scripts/elisp.py run -p ebox -L ebox/tests -l ebox/tests/ebox-active-tests.el -f ert-run-tests-batch-and-exit
```

- `def SYMBOL...` 打印每个定义的完整形式，标题为 `;; 文件:起始行-结束行`，库文件排在
  测试、基准和示例之前。`cl-defstruct` 生成的访问函数解析到对应结构体。超过
  `--max-lines`（默认 250，0 表示不限）的形式在末尾给出剩余行范围。符号没有定义时
  列出相近的已定义名称，退出码为 1。
- `refs SYMBOL` 按文件和所在的顶层形式（`defun 名称: 行号`）列出引用，排除定义处和
  注释行。第一行给出引用数和定义位置。
- `run` 启动 `emacs -Q --batch`，由 `scripts/ecosystem.el` 把各仓库加入 `load-path`。
  `-p FEATURE` 加载工作区 feature，`-L DIR` 追加测试目录等路径，`-l FILE`、
  `-f FUNCTION`、`-e FORM` 按命令行顺序执行。每个 `-e` 的值打印时不带文本属性。
  整个运行期间设置 `print-circle`、`print-length`（50）和 `print-level`（8），
  循环或带属性的结构都能有限地打印。
- `--timeout`（120 秒）、`--max-rss-mb`（2048）以及 64 倍 `--max-output-kb` 的
  输出上限会终止 Emacs。输出超过 `--max-output-kb`（32）时只打印首尾，完整日志保留
  在给出的路径。最后一行是
  `status=ok|error|timeout|memory|output exit=N seconds=S peak_rss_mb=M`，输出被截断时
  追加 `log=PATH`。退出码沿用 Emacs 自身的退出码；被上限终止时为 124，用法错误为 2。

## 执行一次测评

```sh
make perf-list
python3 scripts/performance.py run --mode batch --scenario 'ebox.focus.*' --diagnose
python3 scripts/performance.py run --mode gui --scenario gallery.review.mouse --diagnose
```

可以重复指定 `--scenario` 选择相关场景。`--scenario-file FILE` 加载额外的场景入口，
`--load-path DIR` 添加包的公共加载根。GUI 模式使用已有 `emacsclient` 服务和原生配置；
`--server NAME` 选择已存在的命名服务。GUI 默认允许后台运行，逐个记录样本开始与结束时的
焦点状态；保持渲染窗口可用，避免修改测试 buffer。后台结果不证明前台输入延迟。
`--foreground` 在开始时激活当前 frame，并要求正式延迟采样保持前台；
`--focus-policy foreground` 只要求前台而不激活窗口。诊断采样始终允许后台运行并记录
实际焦点状态。按窗口截图和录屏本身不要求前台激活。

先完成编译，再进行 GUI 验收。预检记录进程、加载来源和库文件；如果加载自另一份
checkout、已有 profiler 正在运行，或已加载包在 Emacs 启动后被修改或重编译，则拒绝
验收。保存工作、重启同一个原生 Emacs，再执行 `M-x server-start`，可建立新的代码代。
这是保守的代码新鲜度检查，工具不会热重载包实现。

每个样本在计时前后记录所选包根入口、`lisp/` 实现和 `examples/` 应用代码的实际
加载文件，排除显式加载的 benchmark 适配器。`runtime_code` 将其归类为 `compiled`、
`interpreted`、`mixed`；没有加载所选运行库时标为 `not-applicable`。Emacs 的加载记录
可能把原生代码记在对应 `.elc` 下，因此 `.elc` 只证明采用编译加载，不能证明仅执行
字节码。各库的详细路径和格式保留供诊断。
原生文件使用 Emacs 已知的源码来源映射；没有来源映射的外部 `.eln` 另存为
`unmapped_native_libraries`，因无法确认所属包，不计入包加载策略分类。这些证据描述
库的加载方式，不断言进程中每个动态重定义函数的执行形式。

混合格式、证据缺失或场景运行期间格式变化均使结果保持未验证。对比要求执行策略
相同，允许 checkout 路径变化或新增已编译模块；两次全部从源码解释加载的运行仍可
比较。磁盘上存在 `.elc` 或 `native_jit` 相同都不能证明采用编译代码：
`load-prefer-newer` 会选择更新的源码。要比较编译执行，须在目标 checkout 完成编译；
工具不会修改时间戳或自动重编译来制造新鲜度证据。

默认每个场景三组，每组先记录五次预热，再执行十次正式延迟采样。`--warmups N` 调整
预热次数；零次适合冷启动筛查。预热与正式样本采用相同的准备、计时、完成条件、
前台要求和正确性检查，保留耗时、结果及失败，但不计入正式延迟分位数和预算门槛。
独立的 500 ms 硬底线同时覆盖预热与正式交互。
独立诊断 pass 不插入预热。批处理每个场景的每组使用新 Emacs 进程，
隔离不同负载的缓存和残留状态；GUI 各组在同一
原生进程中重建场景。`series` 场景在一组内的预热和正式采样之间复用 fixture，
目录明确标注稳态条件。`fresh` 场景仍为每次操作重新创建 fixture。
初始化不计入交互耗时。快速筛查可使用 `--sets 1 --samples 3`，该结果不证明重复性。
采样覆盖门槛要求至少三组、每组三十次正式样本和五次预热
（`--sets 3 --samples 30 --warmups 5`）；较小规模即使每次操作都满足预算，也只算筛查。

保留生成的 `result.json` 即可作为基线：

```sh
python3 scripts/performance.py run --mode gui --scenario gallery.review.mouse --foreground --baseline /path/to/baseline/result.json
python3 scripts/performance.py compare /path/to/before/result.json /path/to/after/result.json
python3 scripts/performance.py summarize /path/to/result.json --scenario gallery.review.mouse --details
```

每个样本必须通过场景的可见结果／语义断言和环境检查。所有慢样本及 GC 都保留。
场景有各自的正式最大延迟预算，另有覆盖预热的独立 500 ms 硬底线。基线分别比较 p95 和最大值，
回归容差为 2 ms。负载、测量驱动、预热协议、覆盖、前后台／显示条件或机器不同则不可比较；代码版本变化会被记录。

Gallery 测量在显示 buffer 后、开始计时前同步 Ebox 的布局视口；批处理使用 120 个
字符宽度和 40 行。新版负载与先前隐藏挂载时视口未确定的样本分开编号，不能直接比较。
已有页面场景借用调用者当前的视口，不重置页面。

`passed` 表示所选性能门槛通过；`failed` 表示预算或回归门槛失败；`screened` 表示
较小规模的有效筛查完成；`unverified` 表示缺失、无效或不完整的数据。退出码分别是
0（通过／筛查完成）、1（性能失败）、2（证据无效）。`acceptance_eligible` 单独说明
采样覆盖是否足够。功能执行完成不等于性能通过。已有 `make verify` 继续负责完整批处理
功能检查与 Research Shelf 验证流程。

## 在真实 GUI 中验证隔离检出

`jj workspace add` 检出必须在完整用户配置里运行，且绝不能加载主检出的代码代。用户 init 会从
`emacs-taf-dir` 取包根，但 `init-etaf.el` 与提前加载的 `use-package` 还会添加
`~/emacs-taf` 路径，且已加入的路径会赢得解析。

1. 用 `EMACSLOADPATH=<私有目录>:` 让私有的 `site-start.el` 排在加载路径最前。它在 init
   文件之前运行，因此可以用 `setq`（不能用 `defvar`）把 `emacs-taf-dir` 指向隔离根，设置
   私有 `server-name`、`load-prefer-newer` 和有界的 `kill-emacs` 看门狗，并对 `require`
   与 `load` 加 advice，把 `~/emacs-taf` 库与相对名重定向到隔离根。只 advice
   `load` 不够：Emacs 31 的 `require` 不会调用被 advice 的 subr。
2. 不抢焦点地启动后台实例：`open -g -n -a Emacs --env 'EMACSLOADPATH=<私有目录>:'
   --args -l <启动文件>`。启动文件在 init 文件之后运行：把隔离根放到最前、移除
   `~/emacs-taf` 条目、启动命名 server 并记录 PID。后台测量不能被 App Nap
   限制；按「执行一次测评」一节的方法确认，不要传 `-NSAppSleepDisabled`，
   Emacs 会把它当作未知选项拒绝。
3. 测量前先证明只有一个代码代：每个 provider 的 `locate-library` 结果与 `load-history`
   里的 `(provide . feature)` 条目都必须落在隔离根下。性能驱动会在预检里重复这项检查，
   并拒绝加载自另一份 checkout 的库。
4. 运行 `scripts/performance.py run --mode gui --server <名字> --root <隔离根>
   --load-path <应用根>`，并按记录的 PID 关闭实例，不要按进程名杀。

这两个辅助文件只属于一次测量会话，不属于检出；放在系统临时目录下。

## 读取诊断

`--diagnose` 在正常延迟采样完成后，另行运行三种诊断：

| 诊断 | 提供的数据 | 用途 |
| --- | --- | --- |
| Trace | 公共提供方报告、更新 owner、投影选择、拒绝局部更新的原因、Ebox 独占阶段耗时 | 找到数据流中昂贵的阶段。 |
| CPU | 自身／含子调用的采样权重、调用栈、函数名称与源文件位置 | 定位需要分析的函数；采样不是精确的单次调用计时。 |
| Memory | 分配权重及调用栈 | 解释分配和 GC 压力；分配量本身不能证明泄漏。 |

诊断样本不进入延迟统计。CPU 与内存 profiler 分开运行，且不同时开启提供方记录器。
CPU 样本不足会明确标记，可针对单个场景增大 `--diagnostic-samples`。驱动不调整 GC
阈值；前后 GC 设置作为动态状态记录，因为框架的 render burst 可以暂时改变这些值。
字体、几何、目标、后端能力和代码代仍是有效性条件。

Ebox 的公共 observer 给出互不重计的 `source`、`style`、`plan`、`layout`、
`projection`、`transaction` 毫秒数。嵌套阶段只计入最内层；`transaction` 包含其余
提交工作、Ebox 内部发布准备及接纳，`ebox-publication` 写入阶段的报告与它重叠。Ebox 之外的时间可能来自应用、
输入分发、异步等待和驱动开销。各阶段的中位数之和不一定等于整体耗时的中位数。

提示规则会指出纯状态更新中的完整 source 准备、不必要的布局、扩大的根 owner 及 GC。
它们提供调查线索，不自动宣判根因；小应用使用根 owner 可能合理。原生调用可定位到
Emacs／模块边界，Rust/C 内部仍需相应原生 profiler。场景提供的已加载模块哈希会进入证据。

Trace 的 `native_declined` 保留原生输入能力不足的原因，`native_fallback` 保留执行
尝试失败的原因。模块已加载不代表布局已走原生路径；应结合这些有界信息、实际投影
策略和阶段耗时决定优化方向。

适配器可用 `:outcome` 回调在计时和 profiler 停止后，通过公共接口读取有界、可序列化
的结果，不得修改应用状态。结果与该条延迟样本一起保存；详细摘要显示最慢样本的结果。
Gallery 记录最后一次提交的投影、脏节点数、根节点归属和发布操作数。这不包含同一次
输入中更早的提交，完整提交序列仍由独立 trace pass 提供。

## 证据与失败

默认结果保存在 `~/.cache/emacs-taf/performance/`（遵循 `$XDG_CACHE_HOME`）。
`--output-dir DIR` 指定空目录，已有证据不会被覆盖。`result.json` 是汇总和比较入口，
逐组 JSON、配置、函数／分配栈及日志保留完整数据。每条原始记录包含 `phase`
（`warmup`、`latency` 或 `diagnostic`）、分类内的样本编号和连续操作序号 `iteration`。
汇总的 `warmups` 保留次数、最大值、全部耗时和失败；`all_latency` 汇总包含首次使用
在内的预热与正式样本次数、最大值和失败。`attempted_count` 还包括未完成计时的中断
操作；此时不可用的最大值保持 null，失败和进行中的阶段仍然可见。预热慢样本不会
被通过的正式分布隐藏，预热失败会使整次运行无效。开始初始化或执行动作前，进度文件
会先记录场景、组、采样分类、样本和执行阶段。

`--timeout` 限制单个初始化／动作／等待步骤，`--run-timeout` 限制一组运行。超时会
终止工具自己启动的 batch 子进程。GUI 超时只向同一服务请求取消，保留原生 Emacs；
若 Emacs 本身无法响应，记录最后阶段，可用 `C-g` 中止内部操作。
`python3 scripts/performance.py cancel` 取消当前工具任务。失败会保留已有证据。

GUI 计时终点是显式完成条件满足且强制 redisplay 返回，不包含硬件输入及系统合成器
最终呈现。Batch 结果不证明 GUI 延迟。界面外观仍需运行维护的 GUI 流程并检查当前窗口截图。

最后一个 GUI fixture 默认由工具保管，下一次运行时会清理。若要继续手动使用该页面，
或测量它当前的状态，请在任务结束后通过同一个 emacsclient 调用
`(taf-benchmark-detach-fixture)`。它返回仍存活的 buffer，移交清理责任并保持应用挂载；
运行中的任务不允许移交。使用现有页面的适配器也应在清理时保留借用的 buffer。

## 一次注册，重复使用

注册及 fixture 接口见 [performance-driver.el](../benchmarks/performance-driver.el)
的 Commentary。场景只调用包入口声明的公共接口。

```elisp
;;; -*- lexical-binding: t; -*-
(taf-benchmark-register
 "example.counter" :version 1 :modes '(batch gui) :budget-ms 10
 :impact 'local :isolation 'series :description "One visible counter update"
 :setup
 (lambda (_mode)
   (let ((buffer (generate-new-buffer " *Counter benchmark*")) (count 0))
     (list :buffer buffer
           :invoke (lambda (_sample)
                     (with-current-buffer buffer
                       (erase-buffer) (insert (number-to-string (cl-incf count)))))
           :verify (lambda ()
                     (with-current-buffer buffer
                       (equal (buffer-string) (number-to-string count))))
           :cleanup (lambda () (when (buffer-live-p buffer) (kill-buffer buffer)))))))
```

`:prepare` 在显示 GUI buffer 后、计时前定位输入目标；`:ready` 等待初始加载完成；
`:settled` 定义异步操作完成条件，5 ms 轮询分辨率会被记录。`:observe` 接受报告接收器，
返回计时／采样停止后调用的清理与收集函数；`:required-providers` 用于发现缺失的预期
观测；`:environment` 返回可 JSON 化的能力信息。验证必须返回 `t` 或简短失败说明。
清理函数只释放本 fixture 的资源，最后一个 GUI fixture 保留供检查。
`:invoke` 接收的序号在每个场景／组从零开始，跨预热和正式样本连续递增；诊断 pass
拥有各自的序号序列。

A/B 对比期间保持场景输入、版本与断言稳定。新应用只需在所属包注册并验证一次场景，
后续重复运行统一命令。工作区 `make check` 中的 `tests/tools/test_performance.py`
验证通用工具的命令、异步、超时、失败和比较契约。
