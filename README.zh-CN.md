# Emacs TAF Monorepo

[English](README.md)

[![Repository structure](https://github.com/emacs-taf/emacs-taf/actions/workflows/structure.yml/badge.svg)](https://github.com/emacs-taf/emacs-taf/actions/workflows/structure.yml)
[![Package installation](https://github.com/emacs-taf/emacs-taf/actions/workflows/package-installation.yml/badge.svg)](https://github.com/emacs-taf/emacs-taf/actions/workflows/package-installation.yml)

[官网与参考手册](https://etaf.top/zh-cn/) · [包归档](https://etaf.top/packages/) · [预编译原生模块](https://etaf.top/native/) · [媒体图库](https://etaf.top/media/) · [许可证](LICENSE)

**Emacs TAF（ETAF）** 是面向 Emacs 的声明式文本应用框架，提供 CSS 风格选择器与层叠、盒模型 / Flex / Grid 布局、响应式组件与增量 buffer 渲染能力。

本仓库（`https://github.com/emacs-taf/emacs-taf`）是 **Emacs TAF 官方 Monorepo**，也是整个生态统一的源码、Pull Request 与 CI 入口。全部 33 个包按产品边界分为三层：`core/packages/`（15 个核心框架、通用扩展、安装器与参考手册包，整目录自动投影到 [emacs-taf/etaf](https://github.com/emacs-taf/etaf)）、`apps/`（16 个应用）与 `games/`（2 款游戏），已对外发布的应用与游戏各自自动投影到 `https://github.com/emacs-taf/<包名>`。

![Emacs 中的 ETAF 应用界面](https://etaf.top/media/site/shots/etaf-ncm.webp)

*运行在原生 Emacs buffer 中的 ETAF 应用，更多截图见 [etaf.top](https://etaf.top/zh-cn/) 与 [媒体图库](https://etaf.top/media/)。*

## 在已有 Emacs 中安装

需要 **Emacs 29.1 或更新版本**，无需 Git、Python、C 编译器，也不替换你现有的 Emacs 配置。执行一次以下代码，随后选择安装目标（默认打开 `etaf-ui` 组件画廊）：

```elisp
;;; -*- lexical-binding: t; -*-
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(call-interactively #'etaf-install)
```

核心入口与约定：

- **`M-x etaf-install`**：从 `https://etaf.top/packages/` 安装任意受支持的框架、扩展、应用或游戏；已安装的目标可离线重开。
- **`M-x etaf-install-manage`**：原生列表包管理面板，集中查看已安装 / 可用版本、运行时状态、需手工安装的外部 `System CLI` 与 Lisp 依赖（`i` 安装、`n` 原生模块、`u` 更新、`U` 全部更新、`d` 卸载、`RET` 打开、`?` 诊断、`g` 刷新、`l` 打开 `list-packages`、`q` 退出）。
- **预编译原生动态模块自动安装**：安装或更新目标时，按依赖闭包自动下载、校验 SHA-256 并热加载声明的原生模块（如 `etaf-md` 的 QuickJS Mermaid/MathJax 渲染器、`etaf` 的 `libmpv` 播放桥、`ekp` 的 C 排版引擎）到 `~/.cache/emacs-taf/native/`。设为 `(setq etaf-install-auto-native nil)` 可关闭，或通过 `M-x etaf-install-native`（管理界面按 `n`）手动管理。
- **能力诊断（`M-x etaf-install-doctor`）**：离线检查必需与可选能力，不改写配置。若缺少必需的外部 OS 命令，交互安装时自动弹出 `*ETAF Installation*` 引导页并给出当前系统包管理器的合并安装命令（`c` 复制、`r` 重检、`o` 打开）。外部服务账号与系统程序只检测、不代装（`etaf-telega` 需先安装 TDLib 并运行 `M-x telega-server-build`，确保 `telega-server` 在 `exec-path` 上）。
- **标准 `package.el` 生命周期**：依赖安装、本地字节编译、升级与卸载全部由 `package.el` 管理（`M-x list-packages` 照常可用）。卸载保留应用数据、登录态与缓存；安装失败仅回滚本次新增的包；升级已加载 Lisp 后请重启 Emacs，同一依赖不要混用源码检出与归档安装。

完整说明见[安装参考](https://etaf.top/zh-cn/introduction/#安装)。

## 本 Monorepo 包含的包

下列全部包都位于本仓库 `core/packages/`、`apps/` 或 `games/` 目录并登记在 [workspace.json](workspace.json) 中。

### 框架核心（`core/packages/` → [emacs-taf/etaf](https://github.com/emacs-taf/etaf)）

| 包名 | 职责 | 本 Monorepo 依赖 |
| --- | --- | --- |
| [ecss](core/packages/ecss) | 选择器与样式层叠引擎 | 无 |
| [ekp](core/packages/ekp) | Knuth–Plass 段落排版 | 无 |
| [ebox](core/packages/ebox) | Box 布局、渲染与增量发布 | ecss；可选 ekp |
| [etaf](core/packages/etaf) | 组件、响应式状态与应用运行时 | ebox |
| [etaf-ui](core/packages/etaf-ui) | 通用 UI 组件库与主题 token | etaf |
| [etaf-gamekit](core/packages/etaf-gamekit) | 游戏定义、独立实例、动作与后端适配器 | etaf |
| [etaf-posframe](core/packages/etaf-posframe) | 任意 ETAF View 的浮动子框面板 | etaf |
| [etaf-ext](core/packages/etaf-ext) | 通用扩展引擎、生命周期管理与宿主钩子 | etaf、etaf-ui、etaf-posframe |
| [etaf-db](core/packages/etaf-db) | ETAF 数据库后端（目前支持 SQLite） | etaf |
| [etaf-install](core/packages/etaf-install) | 官方 `package.el` 安装入口、能力诊断、预编译原生模块下载与包管理界面 | 无 |
| [etaf-manual](core/packages/etaf-manual) | 核心包中英双语《ETAF 参考手册》，对照公共接口校验并发布于 <https://etaf.top> | etaf、etaf-ui；门禁同时校验 ecss、ekp、ebox、etaf-db |

### 通用扩展（`core/packages/` → [emacs-taf/etaf](https://github.com/emacs-taf/etaf)）

构建在 [etaf-ext](core/packages/etaf-ext) 之上，为任意 ETAF 视图与应用提供通用增强能力：

| 扩展 | 职责 | 框架依赖 |
| --- | --- | --- |
| [etaf-hints](core/packages/etaf-hints) | 交互元素的快速键盘跳转提示 | etaf-ext、etaf、etaf-ui、ebox |
| [etaf-highlight](core/packages/etaf-highlight) | 跨 ETAF 视图的高亮与批注笔记 | etaf-ext、etaf、etaf-ui、ebox |
| [etaf-translate](core/packages/etaf-translate) | 面向 ETAF 视图的沉浸式双语对照翻译 | etaf-ext、etaf、etaf-ui、etaf-db、ebox |
| [etaf-export](core/packages/etaf-export) | 将 ETAF 渲染页面导出为矢量 SVG 与 PDF | etaf-ext、etaf、etaf-ui、ebox |

### 应用（`apps/`）

| 应用 | 职责 | 框架依赖 |
| --- | --- | --- |
| [etaf-desktop](https://github.com/emacs-taf/etaf-desktop) | 基于 ETAF 与 ETAF UI 的 Emacs 桌面窗口管理应用 | etaf、etaf-ui、ebox |
| [etaf-ncm](https://github.com/emacs-taf/etaf-ncm) | 网易云音乐播放器：曲库浏览、播放控制、歌词与队列 | etaf、etaf-ui、ebox |
| [etaf-weread](https://github.com/emacs-taf/etaf-weread) | 微信读书客户端：书架、笔记本、划线、书店搜索与统计 | etaf、etaf-ui、etaf-db、ebox |
| [etaf-md](https://github.com/emacs-taf/etaf-md) | 原生 Markdown 全语法渲染器：居中版心、完整网格表格、35+ `:::` 拓展容器、内置 QuickJS 零浏览器 Mermaid/MathJax 矢量图、双栏实时对照预览 | etaf、etaf-ui、ebox |
| [etaf-org](https://github.com/emacs-taf/etaf-org) | Org 阅读视图与活文档引擎：完整 Org 语法、可扩展节点与样式规则、活文档组件、Mermaid/KaTeX 渲染、独立大纲侧窗与 O(Δ) 双栏实时预览 | etaf、etaf-ui、ebox |
| [etaf-rss](https://github.com/emacs-taf/etaf-rss) | RSS 阅读器：订阅、分组、未读与收藏、阅读栏、搜索与 OPML（本地 JSON 或 Miniflux） | etaf、etaf-ui、ebox |
| [maillist](https://github.com/emacs-taf/maillist) | 邮件列表客户端：public-inbox 主题列表、未读与星标、固定顶栏阅读、本地状态与 smtpmail 回复 | etaf、etaf-ui、etaf-db、ebox |
| [etaf-reader](https://github.com/emacs-taf/etaf-reader) | 本地电子书阅读器：EPUB/TXT/Markdown/HTML/FB2/PDF 导入、翻页阅读、标注与进度 | etaf、etaf-ui、etaf-db、ebox |
| [etaf-pomodoro](https://github.com/emacs-taf/etaf-pomodoro) | 专注计时器（独立应用与浮动面板）：响应式倒计时、三种样式与跟随宿主调色板 | etaf、etaf-ui、ebox |
| [etaf-telega](https://github.com/emacs-taf/etaf-telega) | 基于 Telega TDLib 的 Telegram 客户端：会话、实时消息、就地编辑与消息操作 | etaf、etaf-ui、ebox |
| [etaf-video-player](https://github.com/emacs-taf/etaf-video-player) | 在 Emacs 内播放本地视频与流：图像帧、密度字符或真彩半块，带同步声音 | etaf、etaf-ui、ebox |
| [etaf-bili](https://github.com/emacs-taf/etaf-bili) | B 站客户端：热门、排行榜与搜索，支持 buffer 内直接播放 | etaf、etaf-ui、ebox |
| [etaf-youtube](https://github.com/emacs-taf/etaf-youtube) | YouTube 客户端：账号订阅流、搜索、频道、播放列表与画布内播放 | etaf、etaf-ui、etaf-db、ebox |
| [etaf-screensaver](https://github.com/emacs-taf/etaf-screensaver) | 空闲屏保：纯画布动画、输入唤回、组合播放与录制动画适配 | etaf、ebox |
| [etaf-web](apps/etaf-web) | 网页文章阅读器：将 HTML 编译为 `etaf-md` 中间语言并做本地缓存 | etaf-md、etaf、etaf-ui、ebox |
| [etaf-agenda](https://github.com/emacs-taf/etaf-agenda) | 个人日程与任务工作台：今日、日历（年 / 月 / 周）、清单、项目、习惯与月度回顾（SQLite） | etaf、etaf-ui、etaf-db、ebox |

> **归档状态**：`etaf-agenda`、`etaf-reader`、`etaf-rss`、`etaf-screensaver`、`etaf-web` 已在本 Monorepo 中通过验证，但尚未进入官方 ELPA 归档（`M-x etaf-install` 暂不列出）。

### 游戏（`games/`）

两款游戏均构建在 [etaf-gamekit](core/packages/etaf-gamekit) 之上，规则、呈现与素材保存在各自包目录：

| 游戏 | 说明 | 后端 |
| --- | --- | --- |
| [etaf-tanks](https://github.com/emacs-taf/etaf-tanks) | Iron Tide：原生竞技场的实时坦克对战 | Godot |
| [etaf-xiangqi](https://github.com/emacs-taf/etaf-xiangqi) | 楚河：中国象棋人机对战或同机双人对弈 | OpenSpiel |

开发时运行完整 `make -C core/packages/etaf-gamekit check` 前，先安装所选引擎后端或执行 `make -C core/packages/etaf-gamekit engine-all GAMEKIT_PYTHON=python3.11`。

## 独立仓库（不在本 Monorepo 中）

以下周边仓库基于已发布的 ETAF 框架包构建，保留各自的独立提交历史。

| 仓库 | 职责 |
| --- | --- |
| [etaf-pi](https://github.com/emacs-taf/etaf-pi) | 原生 Pi 代理客户端：流式对话、工具输出、会话恢复与多行输入 |
| [etaf-video-studio](https://github.com/emacs-taf/etaf-video-studio) | 录制、非破坏性剪辑并导出软件教程视频 |
| [etaf-browser](https://github.com/emacs-taf/etaf-browser) | 带地址栏与状态栏外壳的浏览器客户端，界面绘制在 ETAF 画布中 |
| [etaf-algo-lab](https://github.com/emacs-taf/etaf-algo-lab) | 在 Emacs 内观看、操控并比较算法运行 |
| [etaf-slides](https://github.com/emacs-taf/etaf-slides) | 将 Markdown 演示稿呈现为等比 16:9 幻灯片，带演讲者备注、总览与计时器 |
| [etaf-solitaire](https://github.com/emacs-taf/etaf-solitaire) | Verdant：K+ Klondike 纸牌，支持撤销与重做 |
| [etaf-salvage](https://github.com/emacs-taf/etaf-salvage) | Salvage Station：实时探索与回收 |
| [etaf-mario](https://github.com/emacs-taf/etaf-mario) | 超级马里奥：四关纯文本平台跳跃，字符精灵、道具与敌人 |

## Monorepo 结构与分层只读投影

```text
emacs-taf/
├── core/                     # 核心投影目录（→ emacs-taf/etaf）：README + packages/<15 个框架/扩展/手册包>
├── apps/                     # 16 个终端应用（已发布应用各自投影 → emacs-taf/<app>）
├── games/                    # 2 款游戏（各自投影 → emacs-taf/<game>）
├── scripts/                  # 共用构建、结构与 API 门禁、影响面分析（refscope）、发布与媒体托管脚本
├── docs/                     # Monorepo 工具手册、生态架构规范与键盘导航契约
├── tests/tools/              # 共享工具与安装器回归测试
├── workspace.json            # Monorepo 包注册表、路径、角色与投影声明（schema 3）
├── release-dependencies.json # 官方 ELPA 归档选包与随包运行资源清单
└── Makefile                  # 按依赖拓扑编排的统一验证入口
```

- **统一开发与 PR 入口**：横跨框架底包与上层应用的改动只需在 `emacs-taf/emacs-taf` 提交单个原子 PR。
- **分层自动只读投影**：
  - `core/` 自动投影到 **[emacs-taf/etaf](https://github.com/emacs-taf/etaf)**，对外提供一个包含 15 个核心框架、扩展、安装器与参考手册包的纯净核心仓库。
  - `apps/` 与 `games/` 下已对外发布的产品各自自动投影到独立仓库（`https://github.com/emacs-taf/<包名>`），投影仓统一关闭 PR 以防止历史分叉。
- **源码包管理器安装（`straight.el` / `elpaca`）**：优先使用官方 ELPA 源（`https://etaf.top/packages/`），也可直接从本 Monorepo 按 `:files ("core/packages/<pkg>/*")` 或 `:files ("apps/<app>/*")` 切片安装。

## 开发与贡献

外部贡献者只需普通 **Git**、**Python 3.10+** 与 **Emacs 29.1+** 即可本地验证并提 PR：

```sh
git clone https://github.com/emacs-taf/emacs-taf.git
cd emacs-taf
make setup-hooks              # 配置本地 Git pre-commit / commit-msg 钩子
```

常用命令：

| 命令 | 用途 |
| --- | --- |
| `make structure-check` | 检查仓库目录规范、`workspace.json` 一致性、媒体策略与跨包公共 API 边界 |
| `make -C core/packages/<包名> check` | 单独运行核心包的结构检查、字节编译、公开验收测试与 API 绑定检查 |
| `make -C apps/<应用名> check` | 单独运行应用校验（游戏为 `make -C games/<游戏名> check`） |
| `make plan-affected` | 预览当前改动在符号级波及的包（基于 `scripts/refscope.py`） |
| `make check-affected JOBS=4` | 按依赖顺序只编译测试受影响的单元 |
| `make order` | 查看全部包的可并行依赖分层 |
| `make check` | 按依赖顺序全量校验整个 Monorepo（发布前使用） |
| `make perf-list` / `make perf-check` | 列出或运行已注册的性能场景（详见 [docs/manual.zh-CN.md](docs/manual.zh-CN.md)） |
| `python3 scripts/media-publish.py publish --item <包名>:/path/shot.png` | 压缩并发布展示截图或录屏至 `https://etaf.top/media/`（展示媒体不进 Git） |

贡献约定：

- 每个包以根目录 `<包名>.el` 头部 Commentary 作为公共 API 唯一清单；消费方只加载提供方根入口，不直接引用其内部 `lisp/` 模块。
- 提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)（标题不超过 72 字符且包含 `Validation:` 行），可用 `python3 scripts/check-commit-message.py <文件>` 本地校验。
- 展示用图片与视频统一托管在 `https://etaf.top/media/`，不提交进 Git（Git 内仅允许 `tests/fixtures/` 存放 ≤ 100 KB 的离线单元测试输入）。
- 维护者工作流（`.github/workflows/project.yml` 自动投影、ELPA 归档发布与性能回归验证）见 [docs/manual.zh-CN.md](docs/manual.zh-CN.md)。

## 文档索引

- **ETAF 参考手册**：<https://etaf.top/zh-cn/>（[简体中文](https://etaf.top/zh-cn/introduction/) · [English](https://etaf.top/introduction/)）
- **Monorepo 开发工具与发布手册**：[docs/manual.zh-CN.md](docs/manual.zh-CN.md) · [docs/manual.md](docs/manual.md)
- **生态架构与开发规范**：[docs/architecture.zh-CN.md](docs/architecture.zh-CN.md)
- **区域导航与键盘交互契约**：[docs/keyboard-navigation.zh-CN.md](docs/keyboard-navigation.zh-CN.md)
- **变更记录**：[CHANGELOG.md](CHANGELOG.md)

## 许可证

采用 GNU General Public License v3.0 或更新版本开源，详见 [LICENSE](LICENSE)。
