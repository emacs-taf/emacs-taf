# 更新记录

## Unreleased

### Added

- 非 nil 的 `:drag-edge` 让 Host 在已移动的拖拽停在窗口边缘带时收到 `edge`
  手势阶段。每个阶段给出贴住的边缘，只报告意图；视口与滚动归拖拽处理器所有，
  引擎的节奏由 `ebox-drag-edge-band` 与 `ebox-drag-edge-interval` 调整。

### Fixed

- 作用域按键命令改用带名字的符号，不再把匿名闭包放进 `this-command`。打印命令的
  post-command 钩子不会再展开整个已挂载 Runtime 的对象图；两个 box 的视图按一次键
  曾因此生成 4 MB 的字符串。

- `etaf-runtime-window-viewport` 在文本 frame 上返回字符格视口而不是 nil，
  显示面在终端上也能像图形 frame 一样按窗口居中并限制尺寸。

- 在同一个 Emacs 里安装、原生编译或重载包之后重新打开已挂载的应用，不再报
  `excessive-lisp-nesting`。响应式层可以在 Runtime 装好环境钩子之后再次求值，
  watcher、effect 与 computed 仍保留自己的组件环境。

- 纯文本 Emacs 构建编译可选图形调用时不再报告未声明函数。非法的保留 Host 内容
  会报告 `etaf-runtime-error`，不再因图像谓词缺失而报错，也不会部分更新批内内容。

- package.el 标准安装可从源码重载未改变的组件声明到字节码，不再触发重复注册错误。
  库重载保留实例状态和原定义捕获的值；改变声明或普通求值中的重复定义仍需显式重定义。

- 重排或观察操作使 point 偏移后，RET/return 激活仍跟随真实键盘焦点，
  不会误触偏移位置上的另一个控件。

### Added

- `etaf-display-metrics` 响应式报告挂载缓冲区的有效字符宽、行高与图像基线，
  包含文本缩放。原生图像提供者可重新切分条带而不重置应用状态。
- 新增 `etaf-animation-paused`：冻结共享时钟并让所有运行原地恢复；新增
  `etaf-animation-speed`：运行时缩放 transition 与帧序列的速度；
  `etaf-animation-frame-rate` 对下一次调度生效。一次性调度在每次发布后让出
  帧周期，不因键盘输入抑制采样，也不补跑积压帧。暂停或变速期间新建的动画
  与已有动画使用相同时间基准。
- 动画示例以二十个面板铺满 buffer，提供时钟控制、亮暗主题和支持空草稿、
  撤销的原生编辑区；GUI 窗口用极窄右 fringe 消除额外的截断列空隙。
- 新增 `etaf-transition`：返回一个随时间跟随响应式 target 的 ref，运行中改变
  target 会从当前显示值重新开始；新增 `etaf-animation-frames`：循环播放帧序列，
  适合 spinner、跑马灯和打字机效果。两者共用一个显示时钟
  （`etaf-animation-frame-rate`），通过普通 ref、Runtime commit 和 Ebox flush
  路径发布，随 Component Scope 停止，并受 `etaf-animation-enabled` 控制。
  `etaf-animation-stop`、`etaf-animation-finish` 与 `etaf-animation-active-p`
  用于控制和查询运行状态；`etaf-animation-interpolate`、
  `etaf-animation-interpolators` 与 `etaf-animation-easings` 负责值转换与曲线。
- 新增 `etaf-viewport`：读取 Component 子树所在区域的宽高；配合
  `etaf-viewport-region` 把内容包进嵌套 viewport 并向下发布已提交的盒尺寸，
  同一个应用无论放在 buffer、窗口还是窗格里都只读同一个响应式值。
- 在 Component setup 中创建的 watcher 与 effect 会在之后每次响应式重跑时回到该
  Component 的环境，`etaf-inject`、`etaf-current-runtime` 和 `etaf-viewport`
  在首次运行之后依然可用。
- Host 新增 `:keys`：焦点位于其内时生效的 `(KEY COMMAND [LABEL])` 作用域按键，
  KEY 可以是 `C-c C-u` 这样的按键序列，命令的运行方式与 keymap 绑定完全相同；
  `:focus-group` 让列表、工具栏或网格成为一个用方向键导航的 Tab 停靠点；
  `:focus-scope 'modal` 把按键和焦点限制在打开的对话框内；`:on-dismiss` 响应
  Escape 与 `C-g`；焦点移入 Host 时运行其 `:on-focus-enter`。
- `?` 打开 `etaf-palette`，按名称运行带标签的按键或按下任意可聚焦控件。
- `etaf-draggable`、`etaf-resizable` 及其受控变体用 `M-<方向键>` 移动、
  `M-S-<方向键>` 缩放；已聚焦的 separator 与 slider 用方向键步进；
  `etaf-drag-step` 让任何 `:on-drag` 都能由按键驱动。

- 新增 `etaf-list-cache`：给变化很慢的列表提供 stale-while-revalidate 策略。
  每个列表按 key 缓存并记录到达时间，应用先展示缓存、在后台与最新回复对比；
  `etaf-list-cache-next` 一次挑一个列表（最旧的过期项优先，其次是从未加载过的），
  交给会话挂载期间 arm 的定时器。刷新失败会退避，需要人介入的失败会暂停刷新，
  直到某次加载成功；可选的版本令牌让支持条件请求的后端不重绘也能刷新条目。

- 新增 `etaf-draggable` 与 `etaf-resizable` Behavior，将 Ebox 拖拽手势转换为调用方
  持有的响应式几何 ref，支持轴/边选择、边界、生命周期回调和逻辑单位位移转换。
- 新增受控变体，通过 `read`/`on-change` 适配聚合几何状态，不创建第二份持久几何存储。

### Changed

- Runtime 改用细粒度保留架构：`etaf-view` 编译为保留区段，Host 属性与文本读取
  成为逐绑定 effect，Ebox 节点保持挂载，提交只修补 buffer 的局部区域，不再重建
  整棵应用树。普通文本、样式和几何更新的延迟因此下降，Ebox 仍是 ETAF 内部的保留
  节点引擎。
- 迁移：用 `etaf-runtime-revision` 或 `etaf-runtime-flush` 的返回值代替代际 API，
  比较 revision 以确认一次更新已写入 buffer。
- 失败的绑定会丢弃整次更新：buffer、revision 和挂载回调保持上次提交的状态，已写入
  的 ref 保留新值。下一次写入或 `etaf-runtime-flush` 会重试被丢弃的工作，因此在
  修复失败之前，后续更新也会等待。

### 删除

- 包内手册 `docs/manual.md` 由 [ETAF 参考手册](https://etaf.top/zh-cn/introduction/) 取代，README、开发说明与架构文档改为链接手册；`docs/architecture.zh-CN.md` 仍是维护者契约。

### 修复

- 计算值（computed）现在和 watcher、effect 一样保留创建它的 Component 环境：
  之后每次响应式重跑都在同一环境里执行 getter。计算中读取的 `etaf-viewport`、
  注入的 Context 与当前 Runtime 在脱离渲染的刷新里不再落空，嵌入桌面窗口的
  应用也不会退回按整个挂载区排版。
- 动画编辑区和其中的文本共用一个点击归属；完整鼠标按下/松开后，删空和缩放后的
  草稿仍能继续输入，不再刚启动就退出编辑。
- 动画剧场打开即处于编辑状态，不用先点一下就能直接输入；TAB 或 ESC 离开编辑，
  点编辑区可重新进入。顶部轨道留一格余量，行尾不再画截断标记。
- 动画剧场的编辑区在窄窗、矮窗下仍可聚焦和输入；旧挂载残留的会话引用不再阻塞
  重新编辑（编辑文本不再包在普通 box 里，保留已提交的 Host 几何）。
- 动画剧场改为一到四列的响应式 Grid，窄窗口控制栏换行、内容纵向滚动；顶部动画条
  随视口铺满宽度，不再固定字符数。
- 动画剧场中的多行草稿超过编辑区高度时，不再挤掉编辑工具栏；新增多行输入、
  清空、撤销与相邻动画同时更新的公共回归和 GUI 性能场景。
- `:hover-style` plist 里嵌套的 Theme token 现在和其他 Host 样式值一样按
  当前提供的 Theme 解析，目录组件悬停时能正常着色，不再把未解析的 token
  泄漏进原生 mouse face。
- 当有活动的 minibuffer、补全弹窗或 echo area 消息占用显示窗口高度时，窗口
  尺寸结算不再把这段借用高度当成 resize 去重排已挂载的 Runtime。frame 自身
  尺寸变化仍会重排，借用的空间释放后由 `minibuffer-exit-hook` 对账补回。

## 迁移到 ETAF 0.2

ETAF 0.2.1 要求 Ebox 3.0.0。请先升级 Ebox，再升级 ETAF。
renderer bootstrap 现在强制要求 Ebox framework SPI v2；provider 缺失、格式错误
或不兼容时会 fail closed。

请删除所有 `etaf-render-port-selection-policy` 配置。v1 render port 及其 initial
publication 手工清理路径已经退役。Runtime mount 与 update 始终使用不可变的 SPI
v2 port，并保留配对 framework stage/rollback、同对象 report、observation replay、
revision 与 Host final marker 契约。

按依赖顺序从源码升级时，ETAF 使用 Ebox 的 `ebox-publication/v1` 与 SPI v3；
旧的 transaction provider 声明和兼容入口已经删除。
