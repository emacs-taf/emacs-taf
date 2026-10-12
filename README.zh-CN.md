# Emacs TAF 工作区

[English](README.md)

本仓库管理 Emacs TAF 生态的统一规范和本地构建入口：框架包、应用工作区与各个应用；各仓库保留自己的 Git 历史、公共接口和发布流程。

## 仓库

框架包与工作区工具都在本检出中：

| 仓库 | 职责 | 本工作区依赖 |
| --- | --- | --- |
| [ecss](https://forgejo.vhkd.top/emacs-taf/ecss) | 选择器与样式层叠 | 无 |
| [ekp](https://forgejo.vhkd.top/emacs-taf/ekp) | Knuth–Plass 段落排版 | 无 |
| [ebox](https://forgejo.vhkd.top/emacs-taf/ebox) | Box 布局、渲染与增量发布 | ecss；可选 ekp |
| [etaf](https://forgejo.vhkd.top/emacs-taf/etaf) | 组件、状态与应用运行时 | ebox |
| [etaf-ui](https://forgejo.vhkd.top/emacs-taf/etaf-ui) | 通用 UI 组件 | etaf |
| [etaf-gamekit](https://forgejo.vhkd.top/emacs-taf/etaf-gamekit) | 游戏定义、独立运行实例、动作与后端适配器 | etaf |
| [etaf-db](https://forgejo.vhkd.top/emacs-taf/etaf-db) | ETAF 数据库后端；目前支持 SQLite | etaf |
| [etaf-apps](https://forgejo.vhkd.top/emacs-taf/etaf-apps) | 应用工作区：各应用的集成检查点与共享工具 | etaf、etaf-ui、etaf-db |
| [etaf-games](https://forgejo.vhkd.top/emacs-taf/etaf-games) | 游戏应用工作区：共同开发契约与集成命令 | etaf、etaf-ui；游戏使用 etaf-gamekit |
| [ebox-playground](https://forgejo.vhkd.top/emacs-taf/ebox-playground) | Ebox 布局示例 | ebox |
| [etaf-playground](https://forgejo.vhkd.top/emacs-taf/etaf-playground) | ETAF/UI 集成示例与验收入口 | etaf、etaf-ui、etaf-db、etaf-desktop |
| [etaf-manual](https://forgejo.vhkd.top/emacs-taf/etaf-manual) | 核心包的《ETAF 参考手册》，中英双语，对照公共接口检查；发布于 <https://etaf.top> | etaf、etaf-ui；门禁还读取 ecss、ekp、ebox 和 etaf-db |

[etaf-gamekit](https://forgejo.vhkd.top/emacs-taf/etaf-gamekit) 提供游戏定义，
以及 Godot、boardgame.io、OpenSpiel 共用的动作、观察结果和
实例生命周期。游戏应用拥有规则与呈现，位于
[etaf-games](https://forgejo.vhkd.top/emacs-taf/etaf-games) 工作区，不属于框架核心；
核心不依赖它们的组件。
运行游戏只需安装所选后端；开发时先运行
`make -C etaf-gamekit engine-all GAMEKIT_PYTHON=python3.11`，再运行完整的
`make -C etaf-gamekit check`。独立游戏项目和适配器接入说明见包内 README 和手册。

## 应用

每个应用都是独立仓库，有各自的历史和检查。
[etaf-desktop](https://forgejo.vhkd.top/emacs-taf/etaf-desktop) 在本工作区开发，其余在 [etaf-apps](https://forgejo.vhkd.top/emacs-taf/etaf-apps) 工作区，其 README 维护依赖清单：

| 应用 | 职责 |
| --- | --- |
| [etaf-desktop](https://forgejo.vhkd.top/emacs-taf/etaf-desktop) | 基于 ETAF 与 ETAF UI 的 Emacs 桌面窗口管理应用 |
| [etaf-ncm](https://forgejo.vhkd.top/emacs-taf/etaf-ncm) | 网易云音乐播放器：曲库浏览、播放控制、歌词与队列 |
| [etaf-weread](https://forgejo.vhkd.top/emacs-taf/etaf-weread) | 微信读书客户端：书架、笔记本、划线、书店搜索与统计 |
| [etaf-md-preview](https://forgejo.vhkd.top/emacs-taf/etaf-md-preview) | Markdown 阅读视图：居中版心、标题、表格、提示块、代码与媒体卡片 |
| [etaf-rss](https://forgejo.vhkd.top/emacs-taf/etaf-rss) | RSS 阅读器：订阅、分组、未读与收藏、阅读栏、搜索与 OPML |
| [etaf-reader](https://forgejo.vhkd.top/emacs-taf/etaf-reader) | 本地电子书阅读器：EPUB/TXT/Markdown/HTML/FB2/PDF 导入、翻页阅读、标注与进度 |
| [etaf-pi](https://forgejo.vhkd.top/emacs-taf/etaf-pi) | 原生 Pi 代理客户端：流式对话、工具输出、会话恢复与多行输入 |
| [etaf-telega](https://forgejo.vhkd.top/emacs-taf/etaf-telega) | 基于 Telega TDLib 的 Telegram 客户端：会话、实时消息、就地编辑与消息操作 |
| [etaf-ascii-video](https://forgejo.vhkd.top/emacs-taf/etaf-ascii-video) | 在 Emacs buffer 里用纯字符播放视频与 HTTP(S) 流 |
| [etaf-video-player](https://forgejo.vhkd.top/emacs-taf/etaf-video-player) | 在 Emacs 里以清晰图像帧加声音播放本地视频与流 |
| [etaf-algo-lab](https://forgejo.vhkd.top/emacs-taf/etaf-algo-lab) | 在 Emacs 里观看、操控并比较算法运行 |

游戏应用是独立的仓库，位于 [etaf-games](https://forgejo.vhkd.top/emacs-taf/etaf-games) 工作区，
其 README 维护依赖清单与共同验收契约。

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

本地历史在 Git 之上用 [Jujutsu](https://docs.jj-vcs.dev/latest/) 管理。在根目录和每个克隆中运行
`jj git init --colocate`，再保护已推送的历史：

```sh
jj config set --repo 'revset-aliases."immutable_heads()"' \
  'builtin_immutable_heads() | remote_bookmarks()'
```

- `make structure-check`：检查目录、文档命名、引用、构建路径和共享工具是否漂移。
- `make check`：先验证规范检查器，再按依赖顺序运行各仓库公共验收。
- `make perf-list`：列出已注册的通用性能场景；
  `make perf-check PERF_ARGS='--mode gui --scenario gallery.review.mouse --diagnose'`
  通过现有原生 Emacs 分开采集延迟、阶段、CPU 和分配数据。
  使用 `--baseline /path/result.json` 比较基线，详见[测评流程与场景接口](docs/manual.zh-CN.md)。
- `make compile`、`make test`、`make clean`：调用各仓库自己的入口。
- `make sync-policy`：分发在工作区维护的共享检查器、提交钩子、格式和 CI 配置。
  在根仓库提交这些文件后，`python3 scripts/workspace.py seal-sync [--dry-run]` 在各仓库只提交这些副本，
  并列出发布该仓库时会一并带出的其他未发布提交。

多文件包的源码放 `lisp/`，单文件包可保留根目录入口；测试、示例、基准、工具和原生实现分别放在
`tests/`、`examples/`、`benchmarks/`、`scripts/` 和 `native/`。
按职责组织：正确性测试及辅助代码放 `tests/`，工具测试放 `tests/tools/`，
数据放 `tests/fixtures/`，验收清单放 `tests/acceptance.json`。
性能工作负载与专用测量程序放 `benchmarks/`，通用运行及发布工具放 `scripts/`。
不按语言或扩展名限制这些目录；目录按需创建，原生子项目遵循自身生态约定。

## 快速批量回归

`make verify-baseline` 保存功能与性能基线；修改后运行
`make verify BASELINE=/path/result.json`，自动保留日志和原始样本，并比较 p95/max。
通过 `scripts/performance.py` 比较，增加超过 2 ms 即失败，各注册场景的绝对预算
仍独立生效。验证先编译工作区，再测量 Playground 注册负载；性能失败后仍运行
`make check`。默认每场景一组 5 次预热、30 次采样，结果标为 `screened`，仅代表筛查；
三组对比使用 `make verify-repeatability BASELINE=/path/result.json`，
对应基线通过 `scripts/verify.py --record-baseline --repeatability` 生成。
普通 `make verify` 沿用基线的采样组数。
终端只输出简短结果与 Git 外的证据目录。实际 GUI 渲染、输入和安装认证仍需
各自的验收流程，批量通过不能替代它们。

## 文档边界

README 只负责入门和导航。完整用法及跨模块接口契约放入 `docs/manual.md`；
当前内部职责与依赖方向放入 `docs/architecture.md`；版本变化与迁移说明放入
`CHANGELOG.md`。后三类按需创建，不凑模板。中文译本统一使用 `.zh-CN.md`。
工作区架构文档同时维护已确定的跨包开发目标和迁移边界。
[区域导航与键盘交互方案](docs/keyboard-navigation.zh-CN.md)独立维护区域、编辑状态和键位规则，其他文档引用该契约。
这些契约直接在原文维护，不另建重复的计划或决策记录。
同一契约只在提供方维护一份，消费方链接过去。许可证及上游来源声明必须保留。

这是一套结合 [Diátaxis](https://diataxis.fr/)、
[README 指引](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
和 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 的项目约定，并非通用文件名标准。

## 版本控制工作流

每完成一个验证通过、能够独立说明和回退的修改点就及时提交；相关代码、测试与接口
文档放在同一次提交。消息遵循 [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)，
使用具体标题、解释正文和 `Validation:` 验证结果。提交粒度参考
[Git 官方工作流](https://git-scm.com/docs/gitworkflows)；标题最多 72 字符和验证字段是本项目附加要求。
本地写操作使用 jj，Git 只读。jj 不运行 Git 钩子，推送前用
`python3 scripts/check-commit-message.py <文件>` 检查每条提交信息，并用
`python3 scripts/check-repository.py --staged` 检查已封口的改动。

每个模块统一使用两个远端：`laycat` 指向 `gitea.gklazycat.heiyu.space`，
`aliyun` 指向 `forgejo.vhkd.top`。每完成一组验证通过的提交，先 fetch 并检查 aliyun，
再用 `jj git push --remote aliyun -b <分支>` 将 `workspace.json` 记录的分支推送到 aliyun 的同名分支。自动交付以 aliyun 成功为准；laycat 保留配置，
由用户手动维护和交付。这是用户已授权的默认规则，无需重复确认。
不强制覆盖历史，不隐式推送其他分支或标签。
`origin` 预留给未来的 GitHub，目前不配置。克隆时使用 `git clone -o laycat`，
再添加对应的 `aliyun` 远端。报告 aliyun 的推送结果；根工作区使用与各模块相同的
`aliyun` 和 `laycat` 远端。
钩子检查目录与消息格式，修改范围、描述准确性和验证充分性仍需开发者负责。

## 持续约束

提交钩子检查实际暂存内容；jj 提交不会触发钩子，推送前需手动运行同一检查。
CI 配置在 push 和 pull request 时运行同一个检查器。
本地钩子可以被绕过；远端管理员需要启用 Actions，并将结构检查设为合并必需条件。
远端权限和分支保护在各托管服务上管理。自动检查负责机械一致性，公共接口的正确性
仍由行为测试和代码审查保证。
