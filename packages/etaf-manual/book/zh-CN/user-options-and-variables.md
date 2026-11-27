# 用户选项与变量

全部有记录的变量，按定义它们的章分组。每行链接到条目，条目给出取值、默认值与作用域。缓冲区局部变量在每个缓冲区里可以有不同值；进程级变量处处生效。

<!-- index: 变量; 用户选项; 参数 -->

## 图像

| 变量 | 用途 |
| --- | --- |
| [`ebox-image-converters`](images.md#variable-ebox-image-converters) | 有序的 （NAME . FUNCTION） 图像转换器列表，只在准备阶段调用。 |

## 视口

| 变量 | 用途 |
| --- | --- |
| [`ebox-viewport-settle-delay`](viewport.md#variable-ebox-viewport-settle-delay) | 最后一次尺寸变化后 Ebox 重排前所需的静默秒数。 |
| [`ebox-viewport-width`](viewport.md#variable-ebox-viewport-width) | 挂载外渲染时的视口像素宽，或 nil。 |
| [`ebox-viewport-height`](viewport.md#variable-ebox-viewport-height) | 挂载外渲染时的视口行高，或 nil。 |

## 滚动

| 变量 | 用途 |
| --- | --- |
| [`ebox-scroll-step`](scrolling.md#variable-ebox-scroll-step) | 一次滚轮步进或 `ebox-scroll-down` 滚动的行数。 |
| [`ebox-swipe-distance`](scrolling.md#variable-ebox-swipe-distance) | 手势在被认定为一划之前走过的水平像素数。 |
| [`ebox-swipe-quiet`](scrolling.md#variable-ebox-swipe-quiet) | 结束一次滑动所需的无水平滚轮事件秒数；方向改变也立即结束。 |

## 拖拽

| 变量 | 用途 |
| --- | --- |
| [`ebox-drag-edge-band`](dragging-and-gestures.md#variable-ebox-drag-edge-band) | 拖拽报告边缘意图时，距窗口边缘的行数与列数。 |
| [`ebox-drag-edge-interval`](dragging-and-gestures.md#variable-ebox-drag-edge-interval) | 拖拽停在或越过边缘带期间，两次 `edge` 手势之间的秒数。 |

## 键盘

| 变量 | 用途 |
| --- | --- |
| [`etaf-direction-scheme`](keyboard.md#variable-etaf-direction-scheme) | 键层的方向方案：`arrows`（默认）或 `vim`。 |
| [`etaf-help-view-function`](keyboard.md#variable-etaf-help-view-function) | 可选的 buffer 内模态帮助呈现器；nil 使用核心呈现。 |
| [`ebox-buffer-mode-map`](keyboard.md#variable-ebox-buffer-mode-map) | 已挂载 Ebox buffer 的键表：滚动、焦点导航与激活。 |

## 文本输入

| 变量 | 用途 |
| --- | --- |
| [`ebox-input-edit-commands`](text-input.md#variable-ebox-input-edit-commands) | 会话 `:keymap` 绑定它们时编辑会话值的命令。 |
| [`etaf-cursor-follows-input-modality`](text-input.md#variable-etaf-cursor-follows-input-modality) | 已挂载画布是否在指针按压后隐藏光标。 |
| [`ebox-allow-text-selection`](text-input.md#variable-ebox-allow-text-selection) | 已挂载画布是否允许 Emacs 原生 mark 与指针文本选择。 |

## 动画

| 变量 | 用途 |
| --- | --- |
| [`etaf-animation-easings`](animation.md#variable-etaf-animation-easings) | 把进度映射到缓动后进度的 `(NAME . FUNCTION)` alist。 |
| [`etaf-animation-interpolators`](animation.md#variable-etaf-animation-interpolators) | 优于内建插值、按顺序查询的 `((PREDICATE . FUNCTION) ...)` 转换表。 |
| [`etaf-animation-color-space`](animation.md#variable-etaf-animation-color-space) | `etaf-animation-interpolate` 混合颜色使用的色彩空间：`rgb`（默认）或 `oklab`。 |
| [`etaf-animation-spring-presets`](animation.md#variable-etaf-animation-spring-presets) | 供 `etaf-spring` 使用的 `(NAME . PLIST)` 弹簧参数预设表。 |
| [`etaf-animation-frame-rate`](animation.md#variable-etaf-animation-frame-rate) | 运行中动画的显示时钟频率，单位是每秒帧数。 |
| [`etaf-animation-speed`](animation.md#variable-etaf-animation-speed) | 动画速度倍数，正数；1.0 是正常速度。 |
| [`etaf-animation-paused`](animation.md#variable-etaf-animation-paused) | 非 nil 时共享时钟停止前进。 |
| [`etaf-animation-pause-hidden`](animation.md#variable-etaf-animation-pause-hidden) | 非 nil 时，无可见窗口的 Runtime 缓冲区动画自动挂起。 |
| [`etaf-animation-enabled`](animation.md#variable-etaf-animation-enabled) | 动画是否随时间插值；默认为 t。 |

## 原生视频

| 变量 | 用途 |
| --- | --- |
| [`etaf-video-audio`](native-video.md#variable-etaf-video-audio) | 新视频是否默认播放来源的音轨。 |
| [`etaf-video-audio-volume`](native-video.md#variable-etaf-video-audio-volume) | 新视频的默认音量，0 到 100。 |
| [`etaf-video-density-ramp`](native-video.md#variable-etaf-video-density-ramp) | `ascii` 渲染模式下每个视频像素所用的字符。 |
| [`etaf-video-display-fps`](native-video.md#variable-etaf-video-display-fps) | 新视频播放的显示定时器频率，单位是每秒帧数。 |
| [`etaf-video-render-backend`](native-video.md#variable-etaf-video-render-backend) | 视频帧的渲染后端：`image`、`canvas` 或 `auto`。 |
| [`etaf-video-engine`](native-video.md#variable-etaf-video-engine) | `etaf-video` 的播放引擎：`auto`、`mpv` 或 `ffmpeg`。 |
| [`etaf-video-mpv-library`](native-video.md#variable-etaf-video-mpv-library) | 可选的 `libmpv` 共享库显式路径。 |
| [`etaf-video-ffmpeg-program`](native-video.md#variable-etaf-video-ffmpeg-program) | 用于解码视频的 ffmpeg 可执行文件的名字或绝对路径。 |
| [`etaf-video-ffplay-program`](native-video.md#variable-etaf-video-ffplay-program) | 用于音频的 ffplay 可执行文件的名字或绝对路径。 |
| [`etaf-video-ffprobe-program`](native-video.md#variable-etaf-video-ffprobe-program) | 用于元数据的 ffprobe 可执行文件的名字或绝对路径。 |

## 浮层

| 变量 | 用途 |
| --- | --- |
| [`etaf-ui-modal-host-function`](ui-overlays.md#variable-etaf-ui-modal-host-function) | 可选的居中模态子 frame 宿主回调；加载 `etaf-posframe` 时自动安装。 |
| [`etaf-ui-modal-use-child-frame`](ui-overlays.md#variable-etaf-ui-modal-use-child-frame) | 图形显示下居中的 `etaf-dialog` 是否投射到真实浮动子 frame；默认 nil（buffer 内渲染）。 |

## 图标

| 变量 | 用途 |
| --- | --- |
| [`etaf-ui-icon-default-set`](ui-icons.md#variable-etaf-ui-icon-default-set) | 注册的回退风格，初始为 `nerd`；在渲染前绑定或设置它。 |
| [`etaf-ui-terminal-icon-set`](ui-icons.md#variable-etaf-ui-terminal-icon-set) | 文本终端上处理 SVG 请求时最先查询的集，初始为 `tty`；设成终端字体画得出的字体集。 |

## Markdown

| 变量 | 用途 |
| --- | --- |
| [`etaf-ui-markdown-flavor`](ui-composite-components.md#variable-etaf-ui-markdown-flavor) | `etaf-ui-markdown-parse` 的默认 markdown 方言。 |
| [`etaf-ui-markdown-flavors`](ui-composite-components.md#variable-etaf-ui-markdown-flavors) | 具名方言及其启用的扩展开关。 |
| [`etaf-ui-markdown-block-extensions`](ui-composite-components.md#variable-etaf-ui-markdown-block-extensions) | 解析器新增的块级语法，按识别器列出。 |
| [`etaf-ui-markdown-inline-extensions`](ui-composite-components.md#variable-etaf-ui-markdown-inline-extensions) | 解析器新增的行内语法，按触发字符与识别器列出。 |
| [`etaf-ui-markdown-emoji`](ui-composite-components.md#variable-etaf-ui-markdown-emoji) | 渲染器绘制的表情短代码表。 |
| [`etaf-ui-markdown-subscript-table`](ui-composite-components.md#variable-etaf-ui-markdown-subscript-table) | `~subscript~` 可用的字符映射。 |
| [`etaf-ui-markdown-superscript-table`](ui-composite-components.md#variable-etaf-ui-markdown-superscript-table) | `^superscript^` 可用的字符映射。 |
| [`etaf-ui-markdown-code-renderers`](ui-composite-components.md#variable-etaf-ui-markdown-code-renderers) | 按围栏语言登记的渲染器表。 |
| [`etaf-ui-markdown-highlight-languages`](ui-composite-components.md#variable-etaf-ui-markdown-highlight-languages) | 用 Emacs 模式着色围栏代码的语言表。 |
| [`etaf-ui-markdown-gfm-features`](ui-composite-components.md#variable-etaf-ui-markdown-gfm-features) | GitHub Flavored Markdown 启用的特性 plist。 |

## 参数参考

| 变量 | 用途 |
| --- | --- |
| [`ekp-alignment`](ekp-parameters.md#variable-ekp-alignment) | 段落对齐模式。 |
| [`ekp-first-line-indent`](ekp-parameters.md#variable-ekp-first-line-indent) | 首行缩进：像素值，或 t 表示段落字体的 2 em。 |
| [`ekp-parshape`](ekp-parameters.md#variable-ekp-parshape) | 逐行布局，由 `(INDENT . WIDTH)` cons 单元组成的序列。 |
| [`ekp-line-penalty`](ekp-parameters.md#variable-ekp-line-penalty) | 每个断行的罚分。越高行数越少。默认 10。 |
| [`ekp-hyphen-penalty`](ekp-parameters.md#variable-ekp-hyphen-penalty) | 连字符断点的罚分。越高越避免断字。默认 50。 |
| [`ekp-adjacent-fitness-penalty`](ekp-parameters.md#variable-ekp-adjacent-fitness-penalty) | 相邻行紧密度相差超过一级时的罚分。 |
| [`ekp-consecutive-hyphen-penalty`](ekp-parameters.md#variable-ekp-consecutive-hyphen-penalty) | 连续连字符行的基础罚分倍数。 |
| [`ekp-last-line-min-ratio`](ekp-parameters.md#variable-ekp-last-line-min-ratio) | 最后一行的最低填充比（0.0–1.0）。 |
| [`ekp-last-line-short-penalty`](ekp-parameters.md#variable-ekp-last-line-short-penalty) | 欠满最后一行的罚分倍数。 |
| [`ekp-looseness`](ekp-parameters.md#variable-ekp-looseness) | 目标行数偏移：0=最优，+1=更松（更多行），−1=更紧。 |
| [`ekp-ragged-stretch-pixel`](ekp-parameters.md#variable-ekp-ragged-stretch-pixel) | 非 justify 对齐下每行的行尾弹性（像素）。 |
| [`ekp-default-cws-stretch-pixel`](ekp-parameters.md#variable-ekp-default-cws-stretch-pixel) | CJK 字符之间空白可拉伸的最大像素。 |
| [`ekp-kinsoku-profile`](ekp-parameters.md#variable-ekp-kinsoku-profile) | 编译段落断点许可时使用的禁则方案。 |
| [`ekp-cjk-no-line-start-extra`](ekp-parameters.md#variable-ekp-cjk-no-line-start-extra) | 不得起行的自定义/日文 CJK 字符。 |
| [`ekp-cjk-no-line-end-extra`](ekp-parameters.md#variable-ekp-cjk-no-line-end-extra) | 不得收尾的自定义 CJK 字符。 |
| [`ekp-protrusion`](ekp-parameters.md#variable-ekp-protrusion) | 非 nil 时启用右缘字符悬挂（标点悬挂）。 |
| [`ekp-protrusion-ratios`](ekp-parameters.md#variable-ekp-protrusion-ratios) | 类别 → 允许悬挂的字形宽度比例的 alist。 |
| [`ekp-number-unit-suffixes`](ekp-parameters.md#variable-ekp-number-unit-suffixes) | 紧凑「数字＋单位」分类器识别的精确后缀。 |
| [`ekp-break-policy`](ekp-parameters.md#variable-ekp-break-policy) | 控制区域断行策略的文本属性。 |
| [`ekp-inline-code-policy`](ekp-parameters.md#variable-ekp-inline-code-policy) | 自动行内代码区间的默认断行策略。 |
| [`ekp-token-break-policies`](ekp-parameters.md#variable-ekp-token-break-policies) | 有界自动 token 分类器的断行策略。 |
| [`ekp-overlong-token-policy`](ekp-parameters.md#variable-ekp-overlong-token-policy) | 宽过行宽的普通非 CJK token 的策略。 |
| [`ekp-hyphenation`](ekp-parameters.md#variable-ekp-hyphenation) | 全局自由断字策略。 |
| [`ekp-latin-lang`](ekp-parameters.md#variable-ekp-latin-lang) | 断字的语言代码（例如 "en_US"、"de_DE"）。 |
| [`ekp-buffer-measure`](ekp-parameters.md#variable-ekp-buffer-measure) | 自动排版与默认手动排版使用的宽度。 |
| [`ekp-buffer-margin-pixel`](ekp-parameters.md#variable-ekp-buffer-margin-pixel) | 窗口正文宽度内预留的像素。 |
| [`ekp-buffer-skip-faces`](ekp-parameters.md#variable-ekp-buffer-skip-faces) | 所在段落保持逐字的脸。 |
| [`ekp-buffer-inline-faces`](ekp-parameters.md#variable-ekp-buffer-inline-faces) | 精确区间使用 `ekp-inline-code-policy` 的脸。 |
| [`ekp-buffer-skip-predicate`](ekp-parameters.md#variable-ekp-buffer-skip-predicate) | 以段落字符串为参数、判定其应保持逐字的函数。 |
| [`ekp-buffer-mode-policy-alist`](ekp-parameters.md#variable-ekp-buffer-mode-policy-alist) | 自动排版与手动排版查询的模式 profile。 |
| [`ekp-auto-justify-lazy-threshold`](ekp-parameters.md#variable-ekp-auto-justify-lazy-threshold) | 超过该缓冲区大小后整缓冲区重排改为可见优先。 |
| [`ekp-auto-justify-paragraph-limit`](ekp-parameters.md#variable-ekp-auto-justify-paragraph-limit) | 自动规划的最大硬段落字符数。 |
| [`ekp-auto-justify-resize-delay`](ekp-parameters.md#variable-ekp-auto-justify-resize-delay) | 窗口大小重排的防抖秒数。 |
| [`ekp-auto-justify-tick-budget`](ekp-parameters.md#variable-ekp-auto-justify-tick-budget) | 一个懒重排 tick 允许的工作秒数。 |
| [`ekp-auto-justify-native-append`](ekp-parameters.md#variable-ekp-auto-justify-native-append) | 自动活动追加的 DP 使用已加载的原生模块。 |
| [`ekp-para-cache-limit`](ekp-parameters.md#variable-ekp-para-cache-limit) | 缓存段落的最大数量。 |
| [`ekp-use-c-module`](ekp-parameters.md#variable-ekp-use-c-module) | 非 nil 时用 C 动态模块计算 DP（若可用）。 |

## 面板

| Variable | Purpose |
| --- | --- |
| [`etaf-posframe-panel-keys`](posframe-panels.md#variable-etaf-posframe-panel-keys) | 可聚焦面板拿着焦点时始终生效的 keymap；在 `q`、`ESC` 与 `C-g` 上关闭面板。 |
| [`etaf-posframe-hide-inactive`](posframe-panels.md#variable-etaf-posframe-hide-inactive) | Emacs 不是当前活动应用时隐藏面板。 |
| [`etaf-posframe-focus-follows-mouse`](posframe-panels.md#variable-etaf-posframe-focus-follows-mouse) | 指针停在面板上时把输入焦点移过去。 |
| [`etaf-posframe-border-width`](posframe-panels.md#variable-etaf-posframe-border-width) | `:border` 没给宽度时的 frame 边框像素数。 |
| [`etaf-posframe-dark-surface`](posframe-panels.md#variable-etaf-posframe-dark-surface) | 暗色面板表面沉向的中性近黑。 |
| [`etaf-posframe-dark-shade`](posframe-panels.md#variable-etaf-posframe-dark-shade) | 暗色面板表面往那个近黑沉多少。 |
| [`etaf-posframe-surface-lift`](posframe-panels.md#variable-etaf-posframe-surface-lift) | 亮色面板表面往黑沉多少。 |
| [`etaf-posframe-border-focus-strength`](posframe-panels.md#variable-etaf-posframe-border-focus-strength) | 聚焦边框里主题强调色占的比重。 |
| [`etaf-posframe-border-hover-strength`](posframe-panels.md#variable-etaf-posframe-border-hover-strength) | 悬停边框里主题强调色占的比重。 |
| [`etaf-posframe-default-width`](posframe-panels.md#variable-etaf-posframe-default-width) | 没有 `:width` 时新面板的内容列数。 |
| [`etaf-posframe-default-max-height`](posframe-panels.md#variable-etaf-posframe-default-max-height) | 没有 `:height` 时新面板的最大内容行数。 |
| [`etaf-posframe-move-step`](posframe-panels.md#variable-etaf-posframe-move-step) | `etaf-posframe-move` 没给步数时移动的字符格数。 |
| [`etaf-posframe-resize-step`](posframe-panels.md#variable-etaf-posframe-resize-step) | `etaf-posframe-resize` 没给步数时改变的行列数。 |
| [`etaf-posframe-apps`](posframe-applications.md#variable-etaf-posframe-apps) | 已注册应用，按注册顺序排列的 `(ID . PLIST)` 记录。 |
| [`etaf-posframe-app-map`](posframe-applications.md#variable-etaf-posframe-app-map) | 每个注册快捷键一个绑定的 keymap。 |
| [`etaf-posframe-app-repeat-delay`](posframe-applications.md#variable-etaf-posframe-app-repeat-delay) | 忽略重复应用开关的秒数。 |

## 性能工程

| 变量 | 用途 |
| --- | --- |
| [`etaf-performance-max-records`](performance-engineering.md#variable-etaf-performance-max-records) | Maximum completed operations retained by the recorder. |

## 说明

- EKP 的参数可以来自三个地方。缓冲区局部值优先于匹配的 mode profile，后者优先于全局变量；每个参数的条目说明它如何读取。
- 有些变量在子系统每次运行时读取，改动从下一次按键或下一帧生效；另一些在新视频、新动画或新会话开始时被捕获。条目会说明是哪一种。
- `ebox-buffer-mode-map` 保存按键表，`ebox-input-edit-commands` 保存命令列表；其余行保存数据值。
