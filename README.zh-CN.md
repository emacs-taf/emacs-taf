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
清单中的提交是本次目录整理的源代码基线，不是已认证的发布版本组合。
`python3 scripts/workspace.py status` 可以查看版本差异，不会切换仓库。

克隆后运行 `make setup-hooks`，启用所有仓库的暂存区检查。
规范工具需要 Python 3.10+ 和 Git；各包的验证还需要合适版本的 Emacs。
可通过 `make check EMACS=/path/to/emacs` 指定可执行文件。

- `make structure-check`：检查目录、文档命名、引用、构建路径和共享规范是否漂移。
- `make check`：先验证规范检查器，再按依赖顺序运行各仓库公共验收。
- `make compile`、`make test`、`make clean`：调用各仓库自己的入口。
- `make sync-policy`：同步规范、检查器、提交钩子和 CI 配置。

完整规则见 [AGENTS.md](AGENTS.md)。修改规范时改工作区源文件，再同步到所有仓库。
源码放在包根目录；测试、示例、基准、工具和原生实现分别放在
`tests/`、`examples/`、`benchmarks/`、`scripts/` 和 `native/`。

## 文档边界

README 只负责入门和导航。完整用法及跨模块接口契约放入 `docs/manual.md`；
当前内部职责与依赖方向放入 `docs/architecture.md`；版本变化与迁移说明放入
`CHANGELOG.md`。后三类按需创建，不凑模板。中文译本统一使用 `.zh-CN.md`。
同一契约只在提供方维护一份，消费方链接过去。许可证及上游来源声明必须保留。

这是一套结合 [Diátaxis](https://diataxis.fr/)、
[README 指引](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
和 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 的项目约定，并非通用文件名标准。

## 持续约束

提交钩子检查实际暂存内容，CI 配置在 push 和 pull request 时运行同一个检查器。
本地钩子可以被绕过；远端管理员需要启用 Actions，并将结构检查设为合并必需条件。
本次本地整理不修改远端权限或分支规则。自动检查负责机械一致性，公共接口的正确性
仍由行为测试和代码审查保证。
