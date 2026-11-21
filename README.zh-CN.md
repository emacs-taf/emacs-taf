# Emacs TAF 工作区

[English](README.md)

本仓库管理 Emacs TAF 生态的统一规范和本地构建入口：框架包、应用与游戏。每个包是同一份 Jujutsu 检出里 `packages/` 下的一个目录，登记在 `workspace.json`；各自仍作为独立仓库发布，有自己的版本号、公共接口与行为验证。

## 开发

所有包在同一份检出里，所以一次改动可以横跨框架层和用它的应用。发布时按包投影出去，每个仓库保持普通单包仓库的形状，仍然通过 package.el 安装。

```sh
make check                # 按依赖顺序验证整份检出，发布前用
make plan-affected        # 预览本次改动影响的单元
make check-affected       # 只验本次改动够得着的单元（支持 JOBS=4）
make order                # 查看可并行的依赖分层
make -C packages/etaf-ui check
```

每个已发布仓库都带着 `pre-mono` 标签，记录统一检出之前的历史；早于那次变更的克隆需要重新获取，不能直接 pull。

## 在已有 Emacs 中安装

使用 Emacs 29.1 或更新版本。以下代码只需执行一次，然后选择目标，默认打开组件画廊：

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

以后运行 `M-x etaf-install` 即可；已安装的目标可以离线重开。用 `M-x etaf-install-manage` 查看已安装/可用版本、更新、卸载或打开目标并查看 doctor；`M-x list-packages` 仍是高级包菜单。依赖安装、本地字节编译、更新和卸载均由 package.el 管理，不需要 Git、Python、系统编译器或 Pi，也不替换现有 Emacs 配置。

安装入口按框架、应用与游戏分组：框架含 `etaf-install`、组件画廊（`etaf-ui`）、`etaf`、`ebox`、`ecss`、`ekp`、`etaf-db`、`etaf-gamekit`、`etaf-posframe`；应用含 `etaf-manual`、`etaf-md`、`etaf-org-preview`、`etaf-video-player`、`etaf-desktop`、`etaf-telega`、`etaf-weread`、`etaf-ncm`、`etaf-pomodoro`、`maillist`；游戏含 `etaf-xiangqi`、`etaf-tanks`。每个条目在打开前报告缺少什么。SQLite 需要 Emacs 本身具备 SQLite 支持；`M-x etaf-install-doctor` 只检查必需和可选能力，不执行安装。外部服务账号与媒体程序只检测、不代装；应用自己的后端随包发布。Telega 的 `telega`
Emacs 包会自动安装，但原生 `telega-server` 不会：先安装 TDLib，再运行
`M-x telega-server-build`（或按 Telega README 手工构建），把 `telega-server`
放进 `exec-path`。安装消息、`M-x etaf-install-doctor` 和
`M-x etaf-install-manage` 里的 `?` 都会显示这条提示。

支持的目标用 `M-x etaf-install-manage` 更新或卸载；高级或第三方包用 `M-x list-packages`。更新后重启 Emacs；卸载只删包文件，应用数据、登录与缓存保留，共享依赖不删。安装失败时只清理本次新增的包，报告清理失败并保留旧安装；由于已加载的部分 Lisp 无法回滚，重试前需要重启。同一依赖不要混用源码检出和包安装。详见[安装参考](https://etaf.top/zh-cn/introduction/#安装)。下面的源码检出说明面向开发者。

## 仓库

框架包与工作区工具都在本检出中：

| 仓库 | 职责 | 本工作区依赖 |
| --- | --- | --- |
| [ecss](https://github.com/emacs-taf/ecss) | 选择器与样式层叠 | 无 |
| [ekp](https://github.com/emacs-taf/ekp) | Knuth–Plass 段落排版 | 无 |
| [ebox](https://github.com/emacs-taf/ebox) | Box 布局、渲染与增量发布 | ecss；可选 ekp |
| [etaf](https://github.com/emacs-taf/etaf) | 组件、状态与应用运行时 | ebox |
| [etaf-ui](https://github.com/emacs-taf/etaf-ui) | 通用 UI 组件 | etaf |
| [etaf-gamekit](https://github.com/emacs-taf/etaf-gamekit) | 游戏定义、独立运行实例、动作与后端适配器 | etaf |
| [etaf-posframe](https://github.com/emacs-taf/etaf-posframe) | 任意 ETAF View 的浮动子框面板 | etaf |
| [etaf-db](https://github.com/emacs-taf/etaf-db) | ETAF 数据库后端；目前支持 SQLite | etaf |
| [etaf-manual](https://github.com/emacs-taf/etaf-manual) | 核心包的《ETAF 参考手册》，中英双语，对照公共接口检查；发布于 <https://etaf.top> | etaf、etaf-ui；门禁还读取 ecss、ekp、ebox 和 etaf-db |

[etaf-gamekit](https://github.com/emacs-taf/etaf-gamekit) 提供游戏定义，
以及 Godot、boardgame.io、OpenSpiel 共用的动作、观察结果和
实例生命周期。游戏应用拥有规则与呈现，与框架包同级，不属于框架核心；
核心不依赖它们的组件。
运行游戏只需安装所选后端；开发时先运行
`make -C packages/etaf-gamekit engine-all GAMEKIT_PYTHON=python3.11`，再运行完整的
`make -C packages/etaf-gamekit check`。独立游戏项目和适配器接入说明见包内 README 和手册。

## 应用

应用与游戏是构建在框架之上的两类程序，都位于本检出 `packages/` 目录下，发布时各自投影为独立仓库。

每个应用都是登记在 `workspace.json` 里的 `packages/` 子目录，表里列出它使用的框架包：

| 应用 | 职责 | 框架依赖 |
| --- | --- | --- |
| [etaf-desktop](https://github.com/emacs-taf/etaf-desktop) | 基于 ETAF 与 ETAF UI 的 Emacs 桌面窗口管理应用 | etaf、etaf-ui、ebox |
| [etaf-ncm](https://github.com/emacs-taf/etaf-ncm) | 网易云音乐播放器：曲库浏览、播放控制、歌词与队列 | etaf、etaf-ui、ebox |
| [etaf-weread](https://github.com/emacs-taf/etaf-weread) | 微信读书客户端：书架、笔记本、划线、书店搜索与统计 | etaf、etaf-ui、etaf-db、ebox |
| [etaf-md](https://github.com/emacs-taf/etaf-md) | Markdown 阅读视图：居中版心、标题、表格、提示块、代码与媒体卡片 | etaf、etaf-ui、ebox |
| [etaf-org-preview](https://github.com/emacs-taf/etaf-org-preview) | Org 阅读视图：结构折叠、标题关键字与计划、列表、表格、代码、提示块、脚注与目录 | etaf、etaf-ui、ebox |
| [etaf-rss](https://github.com/emacs-taf/etaf-rss) | RSS 阅读器：订阅、分组、未读与收藏、阅读栏、搜索与 OPML，可读本地存储或 Miniflux 服务器 | etaf、etaf-ui、ebox |
| [maillist](https://github.com/emacs-taf/maillist) | 邮件列表客户端：public-inbox 主题列表、未读与星标、固定顶栏阅读、本地状态与 smtpmail 回复 | etaf、etaf-ui、etaf-db、ebox |
| [etaf-reader](https://github.com/emacs-taf/etaf-reader) | 本地电子书阅读器：EPUB/TXT/Markdown/HTML/FB2/PDF 导入、翻页阅读、标注与进度 | etaf、etaf-ui、etaf-db、ebox |
| [etaf-pomodoro](https://github.com/emacs-taf/etaf-pomodoro) | 专注计时器（独立应用与浮动面板）：响应式倒计时、三种样式与跟随宿主调色板 | etaf、etaf-ui、ebox |
| [etaf-telega](https://github.com/emacs-taf/etaf-telega) | 基于 Telega TDLib 的 Telegram 客户端：会话、实时消息、就地编辑与消息操作 | etaf、etaf-ui、ebox |
| [etaf-video-player](https://github.com/emacs-taf/etaf-video-player) | 在 Emacs 里播放本地视频与流：图像帧、密度字符或真彩半块，带声音 | etaf、etaf-ui、ebox |
| [etaf-bili](https://github.com/emacs-taf/etaf-bili) | B 站客户端：热门、排行榜与搜索，可在 buffer 内直接播放 | etaf、etaf-ui、ebox |
| [etaf-screensaver](https://github.com/emacs-taf/etaf-screensaver) | 空闲屏保：纯画布动画、输入唤回、组合播放与适配的外部录制动画 | etaf、ebox |
| [etaf-web](https://github.com/emacs-taf/etaf-web) | 网页文章阅读器：将 HTML 编译为 `etaf-md` 中间语言并做本地缓存，由 `etaf-md` 渲染进 Emacs buffer | etaf-md、etaf、etaf-ui、ebox |

`etaf-bili`、`etaf-reader`、`etaf-rss`、`etaf-screensaver`、`etaf-web` 已在本检出中开发并通过检查，但还没有进入包归档；`M-x etaf-install` 不会列出它们。

### 游戏

游戏应用同样位于 `packages/` 目录下。两款游戏都基于 [etaf-gamekit](https://github.com/emacs-taf/etaf-gamekit)
提供游戏定义、独立运行实例、动作与后端适配器，规则、呈现和资源保存在各自的包目录：

| 游戏 | 说明 | 后端 |
| --- | --- | --- |
| [etaf-tanks](https://github.com/emacs-taf/etaf-tanks) | Iron Tide：原生竞技场的实时坦克对战 | Godot |
| [etaf-xiangqi](https://github.com/emacs-taf/etaf-xiangqi) | 楚河：中国象棋人机对战或同机双人对弈 | OpenSpiel |

## 不在本检出中的仓库

以下仓库基于本框架构建，但不在本检出中：它们保留各自的历史与检查，通过已发布的包使用框架。以后可以用 `python3 scripts/add-package.py` 加入。

| 仓库 | 职责 |
| --- | --- |
| [ebox-playground](https://github.com/emacs-taf/ebox-playground) | Ebox 布局示例 |
| [etaf-playground](https://github.com/emacs-taf/etaf-playground) | ETAF/UI 集成示例与验收入口 |
| [etaf-pi](https://github.com/emacs-taf/etaf-pi) | 原生 Pi 代理客户端：流式对话、工具输出、会话恢复与多行输入 |
| [etaf-video-studio](https://github.com/emacs-taf/etaf-video-studio) | 通过 video-project 技能录制、剪辑并发布软件教程：录屏、非破坏性剪辑、后台预览/导出与两步发布 |
| [etaf-youtube](https://github.com/emacs-taf/etaf-youtube) | YouTube 客户端：账号订阅流、搜索、频道、播放列表与画布内播放 |
| [etaf-browser](https://github.com/emacs-taf/etaf-browser) | 带地址栏与状态栏外壳的浏览器客户端，界面画在 ETAF 画布里 |
| [etaf-algo-lab](https://github.com/emacs-taf/etaf-algo-lab) | 在 Emacs 里观看、操控并比较算法运行 |
| [etaf-slides](https://github.com/emacs-taf/etaf-slides) | 将 Markdown 演示稿呈现为幻灯片：等比 16:9 舞台、演讲者备注、幻灯片总览与计时器 |
| [etaf-solitaire](https://github.com/emacs-taf/etaf-solitaire) | Verdant：K+ Klondike 纸牌，支持撤销与重做 |
| [etaf-salvage](https://github.com/emacs-taf/etaf-salvage) | Salvage Station：实时探索与回收 |
| [etaf-mario](https://github.com/emacs-taf/etaf-mario) | 超级马里奥：四关纯文本平台跳跃，字符精灵、道具与敌人 |

## 开始开发

跨包开发前先读[生态架构与开发规范](docs/architecture.zh-CN.md)。它统一记录各包职责、
样式与交互语义、ETAF 组件与 API 易用性、异步资源与错误恢复、当前差距、迁移顺序和
公共行为验收条件，并明确区分开发目标与当前实现。

`workspace.json` 登记的所有包都直接位于本 `jjosh` 单仓检出的 `packages/` 目录下，
不需要单独克隆同级仓库，也不要在 `packages/` 内嵌套 `.git` 或 `.jj`。
规范工具需要 Python 3.10+ 和 `jjosh`；各包的验证还需要合适版本的 Emacs，
可通过 `make check EMACS=/path/to/emacs` 指定可执行文件。
运行 `make setup-hooks` 可在 Git 检出中配置钩子，或在 `jjosh` 检出中打印对应的检查指引。

在当前检出中保护已推送的历史：

```sh
jjosh config set --repo 'revset-aliases."immutable_heads()"' \
  'builtin_immutable_heads() | remote_bookmarks()'
```

- `make structure-check`：检查根目录、`packages/` 下所有包、`workspace.json` 注册一致性与跨包公共 API 边界。
- `make check`：运行结构与 API 门禁、按依赖顺序编译、执行工具回归测试与全部包的公共验收。
- `make plan-affected` / `make check-affected [JOBS=4]`：通过 `scripts/refscope.py` 做符号级变更影响分析，仅按依赖顺序验证受影响单元（支持按层并行）。
- `make order`：输出所有包的可并行依赖分层。
- `make perf-list`：列出已注册的通用性能场景；
  `make perf-check PERF_ARGS='--mode gui --scenario gallery.selection.mouse --diagnose'`
  通过现有原生 Emacs 分开采集延迟、阶段、CPU 和分配数据。
  使用 `--baseline /path/result.json` 比较基线，详见[测评流程与场景接口](docs/manual.zh-CN.md)。
- `make compile`、`make test`、`make clean`：按依赖顺序调用各包自己的入口。
- `python3 scripts/add-package.py`：在 `packages/` 与 `workspace.json` 中登记新包。
- `python3 scripts/publish-packages.py [--dry-run] [--package NAME]`：将共享树中的包按目录投影推送到各自独立远端。

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
本地写操作使用 `jjosh`（不要在 `jjosh` 检出中混用普通 `jj`）。`jjosh` 不运行 Git 钩子，
推送前用 `python3 scripts/check-commit-message.py <文件>` 检查提交信息，并用
`make structure-check` 检查整棵树。

每个包通过 `python3 scripts/publish-packages.py` 按目录投影发布到各自独立的远端
（公开主仓 `origin` 位于 `github.com/emacs-taf`，以及维护者在 AGENTS.md 中记录的镜像远端）。
构建发布归档前先运行 `jjosh git export`。检出本身（包括安装器和不属于任何包的共享工具）
在每次交付后推到仓库级的私有 `aliyun` 远端。不强制覆盖历史，不隐式推送其他分支或标签，
并报告每次推送结果。
钩子检查目录与消息格式，修改范围、描述准确性和验证充分性仍需开发者负责。

## 持续约束

提交钩子检查实际暂存内容；jj 提交不会触发钩子，推送前需手动运行同一检查。
CI 配置在 push 和 pull request 时运行同一个检查器。
本地钩子可以被绕过；远端管理员需要启用 Actions，并将结构检查设为合并必需条件。
远端权限和分支保护在各托管服务上管理。自动检查负责机械一致性，公共接口的正确性
仍由行为测试和代码审查保证。
