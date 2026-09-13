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
| etaf-db | SQLite 适配器；Lisp 包名为 `etaf-sqlite` |
| ebox-playground | Ebox 布局示例 |
| etaf-playground | 应用集成示例 |

## 开始开发

按 `workspace.json` 中的地址克隆各仓库，保持同级目录与名称。
清单记录一起通过 `make check` 的子仓库提交，是集成检查点，不是发布认证。
提交推送后，才能从清单中的远端地址获取这组版本。
`python3 scripts/workspace.py status` 可以查看版本差异，不会切换仓库。

克隆后运行 `make setup-hooks`，启用所有仓库的暂存区检查和提交信息检查。
规范工具需要 Python 3.10+ 和 Git；各包的验证还需要合适版本的 Emacs。
可通过 `make check EMACS=/path/to/emacs` 指定可执行文件。

- `make structure-check`：检查目录、文档命名、引用、构建路径和共享规范是否漂移。
- `make check`：先验证规范检查器，再按依赖顺序运行各仓库公共验收。
- `make compile`、`make test`、`make clean`：调用各仓库自己的入口。
- `make sync-policy`：同步规范、检查器、提交钩子和 CI 配置。

完整规则见 [AGENTS.md](AGENTS.md)。修改规范时改工作区源文件，再同步到所有仓库。
多文件包的源码放 `lisp/`，单文件包可保留根目录入口；测试、示例、基准、工具和原生实现分别放在
`tests/`、`examples/`、`benchmarks/`、`scripts/` 和 `native/`。
按职责组织：正确性测试及辅助代码放 `tests/`，工具测试放 `tests/tools/`，
数据放 `tests/fixtures/`，验收清单放 `tests/acceptance.json`。
性能工作负载与专用测量程序放 `benchmarks/`，通用运行及发布工具放 `scripts/`。
不按语言或扩展名限制这些目录；目录按需创建，原生子项目遵循自身生态约定。

## 文档边界

README 只负责入门和导航。完整用法及跨模块接口契约放入 `docs/manual.md`；
当前内部职责与依赖方向放入 `docs/architecture.md`；版本变化与迁移说明放入
`CHANGELOG.md`。后三类按需创建，不凑模板。中文译本统一使用 `.zh-CN.md`。
同一契约只在提供方维护一份，消费方链接过去。许可证及上游来源声明必须保留。

这是一套结合 [Diátaxis](https://diataxis.fr/)、
[README 指引](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
和 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 的项目约定，并非通用文件名标准。

## Git 工作流

每完成一个验证通过、能够独立说明和回退的修改点就及时提交；相关代码、测试与接口
文档放在同一次提交。消息遵循 [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)，
使用具体标题、解释正文和 `Validation:` 验证结果。提交粒度参考
[Git 官方工作流](https://git-scm.com/docs/gitworkflows)；标题最多 72 字符和验证字段是本项目附加要求。
完整粒度、破坏性变更与历史保留规则见 [AGENTS.md](AGENTS.md)。

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
本次本地整理不修改远端权限或分支规则。自动检查负责机械一致性，公共接口的正确性
仍由行为测试和代码审查保证。
