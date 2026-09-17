# Emacs TAF 工作区

[English](README.md)

本仓库管理 9 个独立仓库的统一规范和本地构建入口；各包保留自己的 Git 历史、公共接口和发布流程。

| 仓库 | 职责 |
| --- | --- |
| ecss | 选择器与样式层叠 |
| tp | 文本属性、保留式 surface 与事务 |
| ekp | Knuth–Plass 段落排版 |
| ebox | Box 布局、渲染与增量发布；依赖 ecss、tp，可选 ekp |
| etaf | 组件、状态与应用运行时；依赖 ebox、tp |
| etaf-ui | 通用 UI 组件 |
| etaf-db | ETAF 数据库后端；目前支持 SQLite |
| ebox-playground | Ebox 布局示例 |
| etaf-playground | 应用集成示例 |

## 开始开发

跨仓库开发前先读[生态架构与开发规范](docs/architecture.zh-CN.md)。它统一记录各包职责、
样式与交互语义、ETAF 组件与 API 易用性、异步资源与错误恢复、当前差距、迁移顺序和
公共行为验收条件，并明确区分开发目标与当前实现。

按 `workspace.json` 中的地址克隆各仓库，保持同级目录与名称。
清单记录一起通过 `make check` 的子仓库提交，是集成检查点，不是发布认证。
提交推送后，才能从清单中的远端地址获取这组版本。
`python3 scripts/workspace.py status` 可以查看版本差异，不会切换仓库。

克隆后运行 `make setup-hooks`，启用所有仓库的暂存区检查和提交信息检查。
规范工具需要 Python 3.10+ 和 Git；各包的验证还需要合适版本的 Emacs。
可通过 `make check EMACS=/path/to/emacs` 指定可执行文件。

- `make structure-check`：检查目录、文档命名、引用、构建路径和共享工具是否漂移。
- `make check`：先验证规范检查器，再按依赖顺序运行各仓库公共验收。
- `make perf-list`：列出已注册的通用性能场景；
  `make perf-check PERF_ARGS='--mode gui --scenario gallery.review.mouse --diagnose'`
  通过现有原生 Emacs 分开采集延迟、阶段、CPU 和分配数据。
  使用 `--baseline /path/result.json` 比较基线，详见[测评流程与场景接口](docs/manual.zh-CN.md)。
- `make compile`、`make test`、`make clean`：调用各仓库自己的入口。
- `make sync-policy`：分发在工作区维护的共享检查器、提交钩子、格式和 CI 配置。

多文件包的源码放 `lisp/`，单文件包可保留根目录入口；测试、示例、基准、工具和原生实现分别放在
`tests/`、`examples/`、`benchmarks/`、`scripts/` 和 `native/`。
按职责组织：正确性测试及辅助代码放 `tests/`，工具测试放 `tests/tools/`，
数据放 `tests/fixtures/`，验收清单放 `tests/acceptance.json`。
性能工作负载与专用测量程序放 `benchmarks/`，通用运行及发布工具放 `scripts/`。
不按语言或扩展名限制这些目录；目录按需创建，原生子项目遵循自身生态约定。

## 快速批量回归

`make verify-baseline` 保存功能与性能基线；修改后运行
`make verify BASELINE=/path/result.json`，自动保留日志和原始样本，并比较 p95/max。
增加超过 2 ms 即失败，既有 50 ms 绝对门槛仍独立生效。默认每场景 5 次预热、
30 次采样；三组对比使用 `make verify-repeatability BASELINE=/path/result.json`，
对应基线通过 `scripts/verify.py --record-baseline --repeatability` 生成。
终端只输出简短结果与 Git 外的证据目录。实际 GUI 渲染、输入和安装认证仍需
各自的验收流程，批量通过不能替代它们。

## 文档边界

README 只负责入门和导航。完整用法及跨模块接口契约放入 `docs/manual.md`；
当前内部职责与依赖方向放入 `docs/architecture.md`；版本变化与迁移说明放入
`CHANGELOG.md`。后三类按需创建，不凑模板。中文译本统一使用 `.zh-CN.md`。
工作区架构文档同时维护已确定的跨包开发目标和迁移边界，直接更新原文，不另建计划或决策记录。
同一契约只在提供方维护一份，消费方链接过去。许可证及上游来源声明必须保留。

这是一套结合 [Diátaxis](https://diataxis.fr/)、
[README 指引](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
和 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 的项目约定，并非通用文件名标准。

## Git 工作流

每完成一个验证通过、能够独立说明和回退的修改点就及时提交；相关代码、测试与接口
文档放在同一次提交。消息遵循 [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)，
使用具体标题、解释正文和 `Validation:` 验证结果。提交粒度参考
[Git 官方工作流](https://git-scm.com/docs/gitworkflows)；标题最多 72 字符和验证字段是本项目附加要求。

每个模块统一使用两个远端：`laycat` 指向 `gitea.gklazycat.heiyu.space`，
`aliyun` 指向 `gitea.vhkd.top`。每完成一组验证通过的提交，先 fetch 并检查两端分叉，
再将当前分支推送到两个远端的同名分支。只推送 upstream 不算完成。
这是用户已授权的默认规则，无需重复确认。不强制覆盖历史，不隐式推送其他分支或标签。
`origin` 预留给未来的 GitHub，目前不配置。克隆时使用 `git clone -o laycat`，
再添加对应的 `aliyun` 远端。逐个报告远端的推送结果；根工作区未配置远端，暂时只保留本地提交。
钩子检查目录与消息格式，修改范围、描述准确性和验证充分性仍需开发者负责。

## 持续约束

提交钩子检查实际暂存内容，CI 配置在 push 和 pull request 时运行同一个检查器。
本地钩子可以被绕过；远端管理员需要启用 Actions，并将结构检查设为合并必需条件。
远端权限和分支保护在各托管服务上管理。自动检查负责机械一致性，公共接口的正确性
仍由行为测试和代码审查保证。
