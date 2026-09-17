# 工作区性能测评

[English](manual.md)

工作区维护一套测量驱动。各包在 `benchmarks/performance-scenarios.el` 注册长期维护的
场景，提供应用初始化、操作和验证条件；计时、profiler、超时和基线比较由通用工具负责。

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

默认每个场景三组、每组十次延迟采样。批处理每个场景的每组使用新 Emacs 进程，
隔离不同负载的缓存和残留状态；GUI 各组在同一
原生进程中重建场景。`series` 场景在一组内复用 fixture，目录明确标注稳态条件。
初始化不计入交互耗时。快速筛查可使用 `--sets 1 --samples 3`，该结果不证明重复性。

保留生成的 `result.json` 即可作为基线：

```sh
python3 scripts/performance.py run --mode gui --scenario gallery.review.mouse --foreground --baseline /path/to/baseline/result.json
python3 scripts/performance.py compare /path/to/before/result.json /path/to/after/result.json
python3 scripts/performance.py summarize /path/to/result.json --scenario gallery.review.mouse --details
```

每个样本必须通过场景的可见结果／语义断言和环境检查。所有慢样本及 GC 都保留。
场景有各自的最大延迟预算，另有独立的 500 ms 硬底线。基线分别比较 p95 和最大值，
回归容差为 2 ms。负载、测量驱动、覆盖、前后台／显示条件或机器不同则不可比较；代码版本变化会被记录。

`passed` 表示所选性能门槛通过；`failed` 表示预算或回归门槛失败；`screened` 表示
较小规模的有效筛查完成；`unverified` 表示缺失、无效或不完整的数据。退出码分别是
0（通过／筛查完成）、1（性能失败）、2（证据无效）。`acceptance_eligible` 单独说明
采样覆盖是否足够。功能执行完成不等于性能通过。已有 `make verify` 继续负责完整批处理
功能检查与 Research Shelf 验证流程。

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
提交工作、TP 准备／发布及接纳，TP 的单独报告与它重叠。Ebox 之外的时间可能来自应用、
输入分发、异步等待和驱动开销。各阶段的中位数之和不一定等于整体耗时的中位数。

提示规则会指出纯状态更新中的完整 source 准备、不必要的布局、扩大的根 owner 及 GC。
它们提供调查线索，不自动宣判根因；小应用使用根 owner 可能合理。原生调用可定位到
Emacs／模块边界，Rust/C 内部仍需相应原生 profiler。场景提供的已加载模块哈希会进入证据。

## 证据与失败

默认结果保存在 `~/.cache/emacs-taf/performance/`（遵循 `$XDG_CACHE_HOME`）。
`--output-dir DIR` 指定空目录，已有证据不会被覆盖。`result.json` 是汇总和比较入口，
逐组 JSON、配置、函数／分配栈及日志保留完整数据。开始初始化或执行动作前，进度文件
会先记录场景、样本和阶段。

`--timeout` 限制单个初始化／动作／等待步骤，`--run-timeout` 限制一组运行。超时会
终止工具自己启动的 batch 子进程。GUI 超时只向同一服务请求取消，保留原生 Emacs；
若 Emacs 本身无法响应，记录最后阶段，可用 `C-g` 中止内部操作。
`python3 scripts/performance.py cancel` 取消当前工具任务。失败会保留已有证据。

GUI 计时终点是显式完成条件满足且强制 redisplay 返回，不包含硬件输入及系统合成器
最终呈现。Batch 结果不证明 GUI 延迟。界面外观仍需运行维护的 GUI 流程并检查当前窗口截图。

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

A/B 对比期间保持场景输入、版本与断言稳定。新应用只需在所属包注册并验证一次场景，
后续重复运行统一命令。工作区 `make check` 中的 `tests/tools/test_performance.py`
验证通用工具的命令、异步、超时、失败和比较契约。
