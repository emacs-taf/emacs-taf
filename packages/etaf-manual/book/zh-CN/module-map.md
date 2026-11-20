# 模块地图

本部分讲已文档化的各包如何实现、如何扩展，用概念与公共接口说明。本章是它的地图：每个包有哪些源码模块、每个模块负责什么、依赖朝哪个方向指。本章不定义自己的接口——它点名实现前文所定义接口的文件。

## 包的组成

<!-- index: 入口文件; 模块; load-path; 内部 feature -->

每个包在仓库根有一个入口文件，以包名命名：`etaf.el`、`ebox.el`、`ecss.el`、`ekp.el`、`etaf-ui.el`、`etaf-db.el`。入口把包的 `lisp/` 目录加进 `load-path`，按固定顺序加载实现模块，并持有权威的 Commentary。程序把仓库根加进 `load-path` 并 require 入口；它从不 require `lisp/` 下的文件。[生态与分层](ecosystem-and-layers.md#公共接口)一节给出这条规则及其推论：入口 Commentary 没有列出的 feature 与符号都是内部的，即使名字里没有双减号。

`lisp/` 下的模块是私有实现文件。本章描述它们负责什么，而不是它们里面有什么：它们的符号、数据结构与内部函数都在手册之外，表里也不给出任何调用方式。模块名可能在任何一次发布中变化，因此包以外的任何东西都不该依赖这种划分。

表这样读。*模块*是仓库里的文件路径。*职责*是该模块所拥有的那类工作。*依赖*列出该文件直接加载的模块，限于已文档化的各包；Emacs 自带库与被间接加载的模块不重复列出。依赖朝下指：模块可以加载更低的层，或本层内更靠底层的一个模块，绝不加载更高的层。每个包的 `docs/architecture.md` 从维护者视角更详细地解释各自划分的理由。

## ECSS 的模块

<!-- index: ecss-selector.el; ecss-cascade.el; ecss-file.el -->

| 模块 | 职责 | 依赖 |
| --- | --- | --- |
| `lisp/ecss-selector.el` | 选择器的解析、匹配与特异性 | — |
| `lisp/ecss-cascade.el` | 样式 schema、层叠与计算值 | `lisp/ecss-selector.el` |
| `lisp/ecss-file.el` | 把 `.ecss` 规则文件读成层叠所消费的结构 | `lisp/ecss-cascade.el` |

选择器模块是这个包的底：它对样式与规则一无所知。层叠模块用它匹配规则，并拥有 schema、来源与值的计算。文件模块是它上面的读取器：把源码文本变成规则并交给层叠。这是所有包里最小的一套模块，也是其余每个包所依赖的那一层。

## Ebox 的模块

<!-- index: ebox-size.el; ebox-measure.el; ebox-style.el; ebox-node.el; ebox-image.el; ebox-layout.el; ebox-flex.el; ebox-buffer.el; ebox-interaction.el; ebox-viewport.el; ebox-file.el -->

| 模块 | 职责 | 依赖 |
| --- | --- | --- |
| `lisp/ebox-size.el` | `(unit number)` 长度与尺寸函数的校验和解析 | — |
| `lisp/ebox-measure.el` | 像素度量、文本单元切分、显示空格与显示孪生 | — |
| `lisp/ebox-style.el` | 样式 schema、别名、校验器、简写展开与 ECSS scope | `lisp/ebox-size.el`、ECSS |
| `lisp/ebox-node.el` | 保留节点记录、作者属性、选择器适配器与计算样式 | `lisp/ebox-measure.el`、`lisp/ebox-size.el`、`lisp/ebox-style.el`、ECSS |
| `lisp/ebox-image.el` | 图片准备、转换器协议与光栅缓存 | `lisp/ebox-measure.el` |
| `lisp/ebox-layout.el` | 文本、box、row、column 与定位布局、行合成与编辑规划 | `lisp/ebox-node.el`、`lisp/ebox-image.el` |
| `lisp/ebox-flex.el` | flex 与 grid 算法 | `lisp/ebox-node.el`、`lisp/ebox-size.el`、`lisp/ebox-layout.el` |
| `lisp/ebox-buffer.el` | 挂载、脏队列、flush 编排、缓冲区写入与几何查询 | `lisp/ebox-node.el`、`lisp/ebox-layout.el`、`lisp/ebox-flex.el` |
| `lisp/ebox-interaction.el` | 键位表、焦点、激活、拖拽、输入会话与滚动 | `lisp/ebox-node.el`、`lisp/ebox-layout.el`、`lisp/ebox-buffer.el` |
| `lisp/ebox-viewport.el` | 窗口尺寸事件的桥与静息后的 refit 调度 | `lisp/ebox-buffer.el` |
| `lisp/ebox-file.el` | `.ebox` 源码读取、companion 加载与预览 | `lisp/ebox-node.el` |

表最上方的两个纯模块——尺寸与度量——不知道节点、挂载或缓冲区。节点依赖它们与样式；布局依赖节点与图片；挂载层依赖节点与布局。交互位于已挂载缓冲区之上，视口桥又在挂载层之上，只请求 refit。有一处有意的软环值得说明：布局模块用前向声明调用 flex 与 grid 算法，入口先加载布局模块再加载 flex 模块，于是庞大的布局核心不必加载它所分派的 flex 与 grid 细节。

## ETAF 的模块

<!-- index: etaf-view.el; etaf-runtime.el; etaf-reactive.el; etaf-component.el -->

ETAF 的模块集最大。核心是作者模型；Runtime 是把模型接到 Ebox 的枢纽；其余模块是架在 Runtime 之上的能力。

| 模块 | 职责 | 依赖 |
| --- | --- | --- |
| `lisp/etaf-view.el` | Host 与 Component 共用的结构 View 语言 | Ebox |
| `lisp/etaf-compiler.el` | 把受支持的结构拓扑编译成内嵌蓝图 | `lisp/etaf-view.el` |
| `lisp/etaf-reactive.el` | 响应式图：ref、computed、effect 与 Scope | — |
| `lisp/etaf-component.el` | 组件定义、实例、bindings 与 setup | `lisp/etaf-view.el`、`lisp/etaf-compiler.el`、`lisp/etaf-reactive.el`、ECSS |
| `lisp/etaf-context.el` | 继承式的 provide/inject 环境 | `lisp/etaf-reactive.el` |
| `lisp/etaf-behavior.el` | 可复用的 Behavior 包：语义属性与 setup | `lisp/etaf-reactive.el` |
| `lisp/etaf-controlled-behavior.el` | 给应用所拥有的几何用的受控 Behavior 变体 | `lisp/etaf-behavior.el` |
| `lisp/etaf-observer.el` | 作用域限于一次动态操作的观察口 | — |
| `lisp/etaf-runtime.el` | 挂载、保留段树、提交与 Host 映射 | `lisp/etaf-view.el`、`lisp/etaf-component.el`、`lisp/etaf-reactive.el`、`lisp/etaf-behavior.el`、`lisp/etaf-context.el`、`lisp/etaf-observer.el`、Ebox |
| `lisp/etaf-app.el` | 应用缓冲区：画布、主题 face、适配与单次关闭 | `lisp/etaf-runtime.el`、`lisp/etaf-reactive.el`、Ebox |
| `lisp/etaf-events.el` | 进入 Host 回调的 Runtime 事件入口 | `lisp/etaf-runtime.el`、`lisp/etaf-reactive.el`、Ebox |
| `lisp/etaf-actions.el` | 命名 Action 与其派发 | `lisp/etaf-runtime.el`、`lisp/etaf-reactive.el` |
| `lisp/etaf-keys.el` | Host 键位表、帮助与提示键 | `lisp/etaf-runtime.el`、`lisp/etaf-events.el`、`lisp/etaf-regions.el`、`lisp/etaf-reactive.el`、Ebox |
| `lisp/etaf-regions.el` | region 声明与 region 导航 | `lisp/etaf-runtime.el`、`lisp/etaf-events.el`、Ebox |
| `lisp/etaf-viewport.el` | 嵌套视口 region 与静息后的 refit | `lisp/etaf-runtime.el`、`lisp/etaf-component.el`、`lisp/etaf-events.el` |
| `lisp/etaf-async.el` | Resource 与 Data 共用的异步操作 | `lisp/etaf-reactive.el` |
| `lisp/etaf-process.el` | 为命令行后端运行到结束的子进程 | — |
| `lisp/etaf-resource.el` | 已加载的 Resource 值与清理 | `lisp/etaf-async.el`、`lisp/etaf-observer.el`、`lisp/etaf-reactive.el` |
| `lisp/etaf-data.el` | 架在显式 source 能力之上的响应式数据控制器 | `lisp/etaf-async.el`、`lisp/etaf-observer.el`、`lisp/etaf-reactive.el` |
| `lisp/etaf-list-cache.el` | stale-while-revalidate 列表缓存 | — |
| `lisp/etaf-animation.el` | 为过渡与动画提供的时间驱动 ref | `lisp/etaf-reactive.el` |
| `lisp/etaf-performance.el` | 可选的性能记录器 | `lisp/etaf-runtime.el` |
| `lisp/etaf-video-source.el` | 视频源归一化、探测与帧过滤 | — |
| `lisp/etaf-video-audio.el` | 播放会话的音频侧车 | `lisp/etaf-video-source.el` |
| `lisp/etaf-video-session.el` | 播放会话：帧生产者、侧车与定时器 | `lisp/etaf-video-source.el`、`lisp/etaf-video-audio.el` |
| `lisp/etaf-video-component.el` | `etaf-video` Component | `lisp/etaf-video-source.el`、`lisp/etaf-video-session.el`、`lisp/etaf-video-audio.el`、`lisp/etaf-component.el`、`lisp/etaf-reactive.el`、`lisp/etaf-runtime.el` |

每个能力模块都 require Runtime，而 Runtime 不 require 其中任何一个，这正是 Action、键位、region、视口 region 与性能记录器是可选的层、而不是核心一部分的原因。视频四个模块自成一个小栈：源、音频侧车、会话，最后是 Component。入口把它们全部加载，因此 require `etaf` 就加载整个框架。

## EKP 的模块

<!-- index: ekp-layout.el; ekp-buffer.el; ekp-hyphen.el; ekp-utils.el -->

| 模块 | 职责 | 依赖 |
| --- | --- | --- |
| `lisp/ekp-utils.el` | 字体处理、度量辅助与原生模块的构建和加载 | — |
| `lisp/ekp-hyphen.el` | Liang 断字模式与字典 | — |
| `lisp/ekp-layout.el` | box、glue 与 penalty 模型、断点搜索、布局与渲染 | `lisp/ekp-utils.el`、`lisp/ekp-hyphen.el` |
| `lisp/ekp-buffer.el` | region 与 buffer 的交互式排版以及 auto 模式 | `lisp/ekp-layout.el` |

EKP 独立于其它包：它的两个底模块是纯的，布局模块是它们唯一的用户。buffer 模块是交互的把手：region 与 buffer 命令、次模式、受保护区域与诊断都在那里。[实现](ekp-implementation.md)一章讲这些模块实现的流水线。

## 组件目录与存储包

<!-- index: etaf-ui; etaf-db; 组件族 -->

组件目录按组件族划分。多数族构建在 basic 模块上，basic 拥有最简控件与共享的样式约定；icon、input、selection、surface、table 与 navigation 各族架在它上面，advanced、media 与 reactions 模块再组合这些族。存储包只有一个模块，注册一个 Data 后端。

| 模块 | 职责 | 依赖 |
| --- | --- | --- |
| `lisp/etaf-ui-style.el` | 共享样式辅助与主题 token 的默认值 | ETAF |
| `lisp/etaf-ui-svg.el` | icon 族使用的 SVG 解析辅助 | — |
| `lisp/etaf-ui-basic.el` | `etaf-label`、`etaf-button`、`etaf-checkbox` 与 `etaf-panel` | `lisp/etaf-ui-style.el` |
| `lisp/etaf-ui-icon.el` | `etaf-ui-icon` 与图标集 | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-feedback.el` | badge、divider、progress、alert、statistic、empty、skeleton、card、avatar、timeline、tag 与 kbd | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-selection.el` | radio、switch、segmented、slider 与 range | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-input.el` | menu、select 与 number input | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-field.el` | text input 与 search field | `lisp/etaf-ui-basic.el`、`lisp/etaf-ui-icon.el`、`lisp/etaf-ui-input.el` |
| `lisp/etaf-ui-editor.el` | 内嵌原生编辑器的辅助 | — |
| `lisp/etaf-ui-surface.el` | popover、dialog、tooltip、toast、dropdown menu、context menu 与 drawer | `lisp/etaf-ui-feedback.el`、`lisp/etaf-ui-icon.el`、`lisp/etaf-ui-input.el`、Ebox |
| `lisp/etaf-ui-navigation.el` | tabs、accordion、breadcrumb 与 steps | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-table.el` | table 与 list | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-data.el` | data grid 与 pagination | `lisp/etaf-ui-table.el` |
| `lisp/etaf-ui-advanced.el` | date picker、tree、calendar 与 command palette | `lisp/etaf-ui-input.el`、`lisp/etaf-ui-navigation.el`、`lisp/etaf-ui-surface.el`、`lisp/etaf-ui-table.el` |
| `lisp/etaf-ui-media.el` | media viewer | `lisp/etaf-ui-icon.el`、`lisp/etaf-ui-selection.el`、`lisp/etaf-ui-surface.el` |
| `lisp/etaf-ui-reactions.el` | reactions | `lisp/etaf-ui-icon.el`、`lisp/etaf-ui-surface.el` |
| `lisp/etaf-ui-desktop.el` | taskbar、workspace bar、launcher、switcher、splitter 与 pane resizer | `lisp/etaf-ui-basic.el`、`lisp/etaf-ui-style.el`、`lisp/etaf-ui-surface.el` |
| `lisp/etaf-ui-window.el` | window chrome、window controls 与 resizable panel | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-tile-grid.el` | tile grid | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-text-grid.el` | text grid | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-ui-playing-card.el` | playing card | `lisp/etaf-ui-basic.el` |
| `lisp/etaf-sqlite-store.el` | SQLite Data 源 | ETAF、Emacs 的 `sqlite` 支持 |

目录里需要引擎度量事实的三处辅助——给 surface 或 field 定尺寸用的视口大小、field 必须转发的输入命令、selection 辅助比较用的像素宽——都从 Ebox 公共的视口与度量接口读该事实，而不是复制度量。其余所有目录依赖都指向 ETAF。

## 让这张图保持准确

<!-- index: 模块地图; 架构文档 -->

这张图是描述性的。受支持的接口仍然是各入口文件 Commentary 里的那些，[公共接口](ecosystem-and-layers.md#公共接口)一节定义了这对消费者意味着什么。当一个包新增、拆分、合并或移动模块时，同一次交付要更新本章与该包的 `docs/architecture.md`，因为两者从不同读者的角度描述同一份划分：本章是生态全局的一瞥，包文档是单个包的理由。
