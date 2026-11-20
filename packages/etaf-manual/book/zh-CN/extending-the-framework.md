# 扩展框架

前几部分讲框架现在是什么；本章讲它怎么生长。有些扩展通过公共宏或协议对任何消费者开放，另一些则是包本身的工作，因为本版本有意不为它们导出注册点。下面每节取本文档化的七条扩展路线之一，说明什么时候用这条路线、用到哪些公共接口，以及让结果保持生态形状需要哪些检查。所有路线最后都落在同样的三项义务上：一条公共清单记录、一份两种语言的手册条目、一个验收测试。

## 哪些路线是开放的

<!-- index: 扩展点; 包内工作 -->

| 路线 | 对消费者开放 | 公共接口 |
| --- | --- | --- |
| 新增 Behavior | 是 | `etaf-define-behavior`、`etaf-behavior-create` |
| 新增 UI 组件 | 是 | `etaf-define-component` |
| 新增 Data 后端 | 是 | `etaf-data-source`、`etaf-data-source-load-page` |
| 新增图片转换器 | 是 | `ebox-image-converters`、`ebox-image-prepare` |
| 把 Ebox 能力暴露到 ETAF | 是，通过扩展 ETAF | 新的 ETAF 适配器，加上它封装的 Ebox 接口 |
| 新增 Host 种类 | 否：Ebox 与 ETAF 的包内工作 | Ebox 作者 tag；ETAF Host 种类 |
| 新增样式属性 | 否：Ebox 的包内工作 | `ebox-style-schema-id`、`ebox-style-property-accepted-p` |

两条关闭的路线不是工作没做完的偶然。Host 种类与样式属性位于布局引擎和层叠的中央，外部定义可能破坏整个框架依赖的不变式，所以它们由拥有该层的包修改来添加。五条开放路线覆盖了消费者不碰这两层就能构建的东西。

## 新增 Host 种类

<!-- index: Host 种类; 作者 tag -->

当一个界面需要现有种类表达不了其布局或交互的原语时，才值得新增 Host 种类——现有的是 `text`、`box`、`fragment`、`row`、`column`、`flex`、`grid` 与 `image`。因为种类必须参与样式接受、布局、命中测试与增量损坏，添加它先在 Ebox、后在 ETAF 里做工；本版本没有 `define-host` 式的注册宏。

步骤沿着分层走。在 Ebox 里选定作者 tag 并定义它的含义：接受哪些作者属性、怎样对待子节点、怎样布局与绘制、哪一部分参与交互。教会构造器与节点层接受这个 tag，并用有名字的错误拒绝错误形状。在 ETAF 里把 Host 种类加进 View 语言并映射到 Ebox tag，包括适用的语义与事件属性以及各自的校验。任何新的查询或修改都作为 ETAF 公共接口暴露，而不是让调用方够到节点。然后更新 Hosts 章、样式属性适用表与属性接受矩阵，并添加验收场景。

检查与任何 Host 相同：在真实窗口里挂载它，在几档视口下验证布局，有焦点、指针、拖拽与输入行为就逐一走一遍。`etaf-runtime-host-props-for` 必须报告已提交的语义属性，边界门禁必须通过。

## 新增样式属性

<!-- index: 样式属性; schema; 热字段 -->

当一个视觉概念没有现成属性、而它的值应当像其它属性一样参与层叠时，才值得新增样式属性。添加它是 Ebox 的包内工作；公共接口报告结果，而不是接受定义。

在 Ebox 里把属性加进样式 schema：规范名、别名、初值、是否继承、适用上下文、值校验器，以及它属于哪些简写。若属性影响几何，就在计算样式记录里填上对应的热字段，并标记让 flush 重算布局的脏位；只影响绘制的属性改用绘制位。schema 会注册给 ECSS，所以计算样式记录及其来源自动包含这个属性：此后的写入经规则与内联声明，读取经 `ecss-computed-style-value`、`ecss-computed-style-present-p` 与 `ecss-computed-style-property-fact`。`ebox-style-property-accepted-p` 是 Host 种类用来接受或拒绝它的接口。

最后，两种语言同步更新样式属性参考里的值语法、初值、适用、继承与绘制/几何影响，并为校验器、简写展开与可见效果添加场景。一个从不改变像素或几何事实的属性不该存在。

## 新增 Behavior

<!-- index: Behavior 扩展; 安装器 -->

Behavior 把语义属性与可选 setup 打包成一个可复用单元，用 `:use` 装到 Host 上。当同一组交互属性出现在多个 Host 上、你想要一份定义而不是多份拷贝时走这条路线。Behavior 是数据，不是 View 节点：它从不渲染，也从不引入容器。

用 `etaf-define-behavior` 定义构造器；它的体必须返回 `etaf-behavior-create` 规格。规格的属性并入 Host 的属性，保留的 `:install` 属性运行 setup 并返回清理函数：

```elisp
(etaf-define-behavior demo-hint (label)
  (etaf-behavior-create
   'demo-hint
   :help-echo label
   :install (lambda ()
              (push 'installed log)
              (lambda () (push 'cleaned log)))))
```

用 `(text :use (demo-hint "press me") "hello")` 安装它。安装器在 Behavior 装到已提交的 Host 上时运行，清理函数在它被移除或 Host 被卸载时运行，这正是这条路线对资源安全的原因。无效规格报 `etaf-behavior-error`。Behavior 里不要放应用策略：用哪个 Behavior、什么时候用属于应用，属性与清理属于 Behavior。

## 新增 UI 组件

<!-- index: UI 组件; 目录条目; 主题 token -->

新增 UI 组件是最常见的扩展：一个应用专用的控件，或组件目录里的新条目。用 `etaf-define-component`，并且恰好选一种前端：输出是编译结构时用 `:view`，普通 Elisp 更清楚时用 `:render`。实例状态放在 `:bindings` 或 `:setup` 创建的 ref 里；prop 是输入，`:validate` 在发布任何东西之前拒绝非法输入。

组件属于 etaf-ui 时还要遵守目录契约：统一的条目形状，先是 props 表（名字、类型、默认值、是否参与受控对或 `:bind`、含义），然后是 slot、报告的事件、键盘与焦点行为、无障碍元数据、它读取的主题 token、以及尺寸规则。新的主题 token 加进目录的默认主题，经 `etaf-theme-token` 读取。目录组件只用 ETAF 公共 API：绝不调用 Ebox 前缀的函数，工作区边界门禁会检查这一点。

开发中的扩展可以用 `etaf-component-redefine-run` 包住定义来重定义 Component，它会替换注册表条目并使编译产物失效；旧定义的已挂载实例会保留旧定义，直到被释放。新组件按目录各章的方式验收：一个能挂载的活示例、真实 GUI 下宽/常规/紧凑/矮四档视口的走查，以及两种语言的手册条目。

## 新增 Data 后端

<!-- index: Data 后端; source 能力 -->

Data 后端把存储或服务适配到 Data Source 协议。用 `etaf-data-source` 和描述它的能力创建 source。`:load` 必填：它接收查询、页与页大小，返回至少含 `:items` 的 plist，可选 `:total`、`:page`、`:page-size`。写入用可选的 `:mutate`；后端能报告提交确定性时用 `:mutate-v2`；能把一组操作原子应用时用 `:mutate-batch`。`:dispose` 在控制器停止时释放后端，`:item-key` 提供稳定的选择身份，`:provider` 在观察报告里给 source 命名。任何回调都可以返回 `etaf-async` 而不是值。

先不建控制器地检查加载路径：`etaf-data-source-load-page` 加载并归一化一页，准备好的 `:initial-result` 也源自它。然后把 source 交给 `etaf-data-controller`，由它拥有生命周期；一个 source 只保留一个拥有它的控制器。无法证明外部写入结果的后端报告 `external-unknown`，而不是猜；它也绝不暗示本地回滚。etaf-db 里随包发布的 SQLite 后端是参考实现，[Data Source 协议](data-sources.md)一章完整定义这套协议。

## 新增图片转换器

<!-- index: 图片转换器; 准备 -->

图片转换器把来源变成 Ebox 的图片字符面。它是一个接收来源、列数与行数的函数，返回恰好 ROWS 行、每行 COLUMNS 个 `▀` 字符的字符串，每个字符带 `face` plist 的 24 位前景与背景色。返回 nil、报错、或返回形状不对的字符串都表示拒收，于是列表里的下一个转换器接手。

转换器只在准备阶段被咨询。把它装到 `ebox-image-converters` 的前面，或为单次调用把列表传给 `ebox-image-prepare` 的 `:converters`。准备会解析来源、运行转换器并缓存结果；布局与缓冲区写入只复用已准备的内容，所以图片转换永远不会卡住一次 flush。用 `ebox-image-info` 与 `ebox-image-content` 检查结果；转换器行为变化时调用 `ebox-image-cache-clear`，避免复用旧的准备结果。转换器不得修改它的来源。

## 把 Ebox 的能力暴露到 ETAF

<!-- index: ETAF 适配器; 边界规则 -->

当应用或目录组件需要只有 Ebox 才有的能力——一次度量、一次保留更新、视口控制——该能力先暴露为 ETAF 接口，应用再使用这个接口。这是生态的边界规则，对框架扩展同样适用：Ebox 前缀的调用留在 ETAF 或 Ebox 自己的包内，例如 etaf-ui 的视口辅助。

扩展分五步。第一，确认没有现成的 ETAF 接口已经提供这个事实。第二，在 Ebox 里把它实现为公共接口，带自己的验收场景，包括它必须维持的不变式——例如准备工作不在布局期间发生。第三，加 ETAF 适配器：它在改变任何东西之前校验 Runtime 与 Host 引用，把保留编辑走正常提交，使一次调用产生一次发布与一个修订号，并且不保留 Ebox 事实的并行拷贝。第四，添加定义条目、两种语言同步更新受影响章节，并补上边界门禁运行的测试。第五，把调用方迁到新接口并移除直接走 Ebox 的路径。

保留内容与几何更新就是范本：`etaf-runtime-update-host-contents` 与 `etaf-runtime-update-host-geometries` 先校验每个目标、每次调用发布一次、修订号前进一次，这正是一个高频显示面需要应用拿到的契约。

## 改动怎样被验证

<!-- index: 公共测试; 验收清单; 有界失败输出 -->

受维护的测试通过包入口声明的接口行使可观察的输入、输出、错误、回滚与生命周期。它不测私有辅助、内部数据结构、源码文本、调用次数或已退役的行为；夹具与辅助函数遵守同样的规则，间接、反射或故障注入都不构成私有访问。当某个场景看起来需要私有符号时，正确的做法是把事实移进公共接口、或者改为断言可观察行为——绝不为了让测试留着而把符号升为公共 API。每个包在 `tests/acceptance.json` 里清点它维护的 Lisp 正确性场景，一条场景一个条目、附可观察的目的：`make test` 恰好跑这套公共套件，`make check` 再一起跑结构门禁、字节编译、全新入口绑定与源码签名校验。这里没有单独的内部套件，因为内部测试断言的是实现，而不是消费者看见的行为。

场景是 ERT 测试，无头运行。工作区运行器 `scripts/run-acceptance.py` 用一个 checkout 上的咨询锁把运行串行化：并发的运行以退出码 75 被拒绝，或者最多等待 `--wait SECONDS` 秒。失败的条件可能很大或带环，所以运行器用 `--print-length`（默认 6）、`--print-level`（默认 3）与硬上限 `--max-condition-bytes`（默认 8192）约束它的打印。两个习惯让单条断言保持可读：把返回大活对象的调用结果——Runtime、缓冲区、树——绑定到局部变量再对局部变量断言，因为 ERT 会捕获求值后的参数；打印框架内容时用 `buffer-substring-no-properties` 取文本，并绑定 `print-circle` 与打印上限，因为活的 Runtime 或回溯可能带循环闭包与文本属性，`%S` 会永远展开。写给 Emacs 加载的 Lisp 文件，包括临时探针，首行都要有 `;;; -*- lexical-binding: t; -*-`。

无头断言证明行为，不证明外观与延迟，所以可见或交互相关的改动要在真实图形 Emacs 会话里验证：按用户打开的方式打开受影响的示例，检查宽、常规、紧凑、矮四种视口档位，并在交互中途做一次缩扩。批量运行既不能证明渲染、也不能证明输入延迟。性能场景是这套验证的一部分而不是它的替代品：`scripts/performance.py` 在 batch 模式下跑注册场景来测 operation 与 CPU 成本，或在 GUI 模式下测真实渲染与输入计时；围绕它的规则——改动前先建立基线、最终结论用三组独立采样、只在安静的树上测量——见[性能工程](performance-engineering.md)。失败、缺失或不可比的性能门禁保持未验证，包括本来就存在的失败；测量期间检出发生变化的运行，无论数字如何都标为未验证。测量产生原始证据，原始证据留在版本控制之外；在打开具体失败日志之前先看紧凑结果。

框架在测试或示例运行期间报告警告时——组件校验、渲染器警告、字节编译或加载错误——那份报告就是发现，不是噪声：它要被追到拥有它的层、在那里修，绝不用 `ignore-errors`、更宽的 `condition-case`、抑制警告或排除测试来消音。同理，不为了把失败变绿而削弱检查或跳过测试；当某项检查过期时，把它更新到当前契约，同时保留它的行为覆盖。

手册也受同样的门禁。`make -C etaf-manual book-check` 校验章节结构、定义条目签名与 provider Commentary 逐字一致、文档化包与词表的覆盖、链接、正文的公共符号规则、段行纪律与两种语言的对齐；它的活示例验收会挂载两种语言的每个 `:run` 示例，所以求值或挂载失败的示例会让门禁失败。公共接口的变化因此在同一次交付里更新受影响的章节与两种语言，这正是手册始终描述当前代码、而不是更早版本快照的原因。

## 改动怎样交付

<!-- index: colocated 仓库; conventional commit; 快进 -->

每个仓库都是与 Git colocated 的 Jujutsu 仓库，各有一条已发布分支。Jujutsu 拥有工作副本：当前提交 `@` 就是工作副本，每条命令都会把文件快照进它，Git 处于分离 `HEAD` 属预期。用 `jj commit <paths> -m "…"` 封口一个提交，它把指名的路径放进一个已完成的 change 并开始一个空的 `@`；指名路径只会封住你自己的改动，所以提交永远不会顺手带走别人未完成的工作。一个工作副本只有一个写者：动手前先跑 `jj st`；当 `@` 里已有不是你做的改动时，只封自己的路径，若两边都改同一个文件先沟通。并行工作用独立的 `jj workspace add <dir>` 检出，绝不用 git worktree；已发布历史是必须尊重的例外：`immutable_heads()` 包含远端 bookmark，所以已发布的提交不会被无意重写。

一个提交是一个可解释、可独立评审与回退的改动——一个有内聚性的功能、修复、移动或文档更新，连同它的回归覆盖与文档——不是固定数量的文件或行。互不相关的改动要拆开，让每个提交都能用于二分。消息遵循 Conventional Commits：`type(scope): concrete imperative English summary`，标题最多 72 个字符；空行之后，正文解释问题与由此产生的行为或改动原因。`Validation:` 行列出实际运行过的命令与结果，或者说明某项检查为什么没跑。破坏性改动在标题里带 `!`，并在 footer 写 `BREAKING CHANGE:` 说明影响与迁移。

发布之前，发布范围里的每个提交都要检查，它产出的树也要检查：把每个提交的描述写到文件，用 `python3 scripts/check-commit-message.py` 检查；用 `python3 scripts/check-repository.py --staged` 校验 colocated Git 索引所镜像的封口树；运行 `jj log -r '(<range>) & (conflicts() | divergent() | description(exact:""))'`，它必须什么都不打印；确认 `@-..main@<remote>` 为空，于是发布是一次快进。每个仓库向 `origin`（`github.com/emacs-taf`）发布，并在同一检查点向 `aliyun` 镜像交付，`laycat` 保留为第二个镜像；发布的分支是 `workspace.json` 记录的 `branch`。Jujutsu 不根据 tracking 推导推送远端，所以远端与 bookmark 永远显式指名：`jj bookmark set main -r @-`，然后 `jj git push --remote aliyun -b main` 与 `jj git push --remote origin -b main`。provider 先于依赖它接口的 consumer 发布；未发布的提交从不强推：当远端有本地没有的提交时，把未发布提交 rebase 到远端之上并重跑检查。认证或连通性导致推不上去时，提交留在本地并如实报告交付失败。

在集成交付点，每个仓库已发布的 `main` 提交连同运行过的检查一起记录进 `workspace.json`，这正让一组修订号组合可复现；`python3 scripts/workspace.py status` 把仓库 bookmark 与这些记录的修订对比——绝不与工作副本对比——工作区的集成检查在编辑与提交都完成之后、在安静的树上运行。历史与恢复方面，`jj log -p <path>` 显示单个文件的历史，`jj file annotate <path>` 给一行定责，`jj bisect run --range <good>..<bad> -- <command>` 在独立 workspace 里对提交范围二分，因为二分会在工作副本上编辑；退出码 125 表示跳过无法测试的修订，而不是标它为坏。`jj undo` 反转上一次操作，`jj op log` 配合 `jj op restore <operation>` 把仓库恢复到更早的状态，`jj evolog -p -r <rev>` 显示单个 change 自身怎样被重写，这与文件的历史不同。

用户可见的变化按 Keep a Changelog 记进变更记录，归在某个发布标题或 `Unreleased` 下；手册与变更记录随代码同行：受影响的章节在同一次交付里更新两种语言，book 门禁作为包检查的一部分运行，版本头变化时更新手册中每一个同时点名包与版本的段落，因为 book 门禁会把那段与入口文件对比。

## 每次扩展都要做的事

<!-- index: 扩展清单 -->

无论走哪条路线，扩展在同样四件事都成立之前都不算完成。拥有该包的入口 Commentary 列出新的公共接口，因为那才是权威清单。手册为每个新公共接口有条目，受影响的章节两种语言同步更新，因为 book 门禁会检查覆盖、签名与翻译结构。改动在包的 `tests/acceptance.json` 里有一个通过公共接口行使新行为的验收场景，测试运行期间框架报告的任何诊断都不被忽略，可见或交互相关的改动也已经在真实窗口、在受支持的几档视口下走过一遍。
