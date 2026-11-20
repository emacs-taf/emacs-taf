# 原生视频

视频就是一个普通的 Component，它的画布显示实时帧，而不是由应用重新渲染的文本。画布有固定的字符格尺寸，它背后的播放会话拥有帧生产者和可选的音频旁路，每个呈现的帧只经 retained 内容路由更新画布 Host——所以奔跑中的视频从不支付一次完整的应用渲染。帧来自本地文件、HTTP 或 HTTPS 流、内置测试图或一次探测好的元数据 plist；音频默认关闭，除非明确要求；解码器、元数据探测器和音频播放器都是外部程序，可以按变量替换。本章定义画布 Component、源元数据、播放 handle、会话上报的回调、渲染模式及其呈现规则、音频旁路，以及外部程序缺失时会发生什么。[Runtime](runtime.md) 定义每帧使用的 retained Host 内容更新；[安装与加载](installation-and-loading.md) 列出可选程序与各自缺失时的降级。

## 视频画布

<!-- index: etaf-video; 视频画布; 渲染模式; autoplay; handle; 设备像素比 -->

`etaf-video` Component 把一个视频源渲染进固定 `COLUMNS` × `ROWS` 格画布。挂载的 Component 会启动一个播放会话：会话把源解码成帧，只保留最新的完整帧给显示定时器，并把每个呈现的帧交给画布。画布是周围布局里的普通 box；放置属性直接声明在画布节点上，未发布的空间被隐藏而非重排，所以视频在普通兄弟节点旁边保持自己的固有字符格尺寸。

`mode` 决定一帧如何变成画布文本。`image` 每帧显示一张缩放后的 JPEG 图片，要求缓冲区显示在图形帧里；其他环境退回 `ascii`，所以为一种环境写好的布局在另一种环境仍能渲染。`ascii` 把每个像素映射成一个密度阶梯字符，`color` 每个 `▀` 半块字符显示两个全彩像素。各模式下画布文本的行数相同，应用界面才能放在视频下方。

#### Component: etaf-video (&key src (columns 100) (rows 30) (mode 'image) (ramp etaf-video-density-ramp) (audio etaf-video-audio) (volume etaf-video-audio-volume) (speed 1) (autoplay t) handle device-pixel-ratio display-fps position left top z-index)

在固定 COLUMNS × ROWS 画布里渲染一个实时视频源。

**参数。** SRC 为 nil 时用内置 demo，也可以是本地文件名、HTTP 或 HTTPS URL 或源 plist（见 `etaf-video-source-info`）。COLUMNS 与 ROWS 是画布的字符格尺寸，默认 100 与 30。MODE 是 `image`、`ascii` 或 `color`。RAMP 是 `ascii` 的密度阶梯，默认取 `etaf-video-density-ramp`。AUDIO、VOLUME 与 SPEED 配置播放，默认分别取 `etaf-video-audio`、`etaf-video-audio-volume` 与 1。AUTOPLAY 在 Component 挂载时开始播放；为 nil 时先显示第一帧并暂停。DISPLAY-FPS 是 nil 或正整数，默认取 `etaf-video-display-fps`。DEVICE-PIXEL-RATIO 是 nil 或正数，默认取显示器的缩放因子。HANDLE 是一个符号，把已挂载的视频注册给 `etaf-video-play` 一族函数。POSITION、LEFT、TOP 与 Z-INDEX 放置画布。

**语义。** 挂载创建播放会话、注册 HANDLE，并开始播放或呈现第一帧。SRC、COLUMNS、ROWS、MODE、RAMP、DEVICE-PIXEL-RATIO 或 DISPLAY-FPS 变化会重建会话：新 SRC 从头开始，其余在当前位置重建，暂停的会话保持暂停。已经结束且处于暂停显示的视频会从结束前一帧重建，所以改变尺寸能按新尺寸重画最后一幅画面。AUDIO、VOLUME 与 SPEED 都可以是 ref 或计算值；改它们会在运行中的会话里就地调整而不重建画布，身份可以保持不变，同时由共享控件更新值。每个呈现的帧直接更新画布 Host 的内容；新帧提交后旧帧图片被释放。卸载会停止生产者与音频旁路、释放帧缓存并注销 HANDLE。

**返回。** 一个 View。

**错误。** 属性超出约定时报 `etaf-component-call-error`，点名该属性与期望值；受检的九个属性是 COLUMNS、ROWS、MODE、RAMP、VOLUME、SPEED、HANDLE、DISPLAY-FPS 与 DEVICE-PIXEL-RATIO。HANDLE 已被另一个视频挂载时报 `user-error`，消息 `"An etaf-video is already mounted for handle %s"`。SRC 不可用时报 `etaf-video-source-info` 所述的 `user-error`，且在任何解码器启动之前。解码器缺失时报 `user-error`，消息 `"ffmpeg is not available: %s"`。播放中画布更新失败时会话被销毁、失败写进 `*Messages*`；最后一幅画面留在画布上。

**示例。** 一个暂停的、适合终端的画布。

```elisp
(etaf-video :src nil :mode 'ascii :columns 40 :rows 12
            :handle 'player :autoplay nil)
```

**参见。** `etaf-video-source-info`、`etaf-video-play`、`etaf-video-state`。

## 源与元数据

<!-- index: etaf-video-source-info; 源类型; 探测默认值; 规范化元数据 -->

源描述一次后即按值使用：探测返回的 plist 可直接交给 Component，所以挂载前读取尺寸或时长的应用不会探测两次。视频与音频可以是两个独立的 HTTP(S) 流，请求头与代理也由同一份源描述携带。

#### Function: etaf-video-source-info (source)

返回 SOURCE 规范化后的播放元数据 plist。

**参数。** SOURCE 为 nil 时是内置 demo，也可以是本地文件名、HTTP 或 HTTPS URL 字符串，或带 `:file`、`:url` 或 `:demo` 的 plist。本地文件名可以以 `~` 开头或相对 `default-directory`，探测前会先经 `expand-file-name` 展开。`:url` 源可以再用 `:audio-url` 指定独立音频流，并用 `:headers`（alist、hash table 或一条 `Name: value` 字符串）与 `:proxy` 携带网络选项。已经带 `:kind` 的 plist 被当作权威元数据，也就是本函数返回的那种结果。

**语义。** 结果的键有 `:kind`（`file`、`url` 或 `demo`）、`:file`、`:url`、`:target`（ffmpeg 打开的视频流）、`:audio-url`、`:audio-target`（音频旁路打开的流，缺省回退到 `:target`）、`:headers`、`:proxy`、`:width`、`:height`、`:duration`、`:fps`（源帧率）与 `:audio`（源是否报告有音轨；存在 `:audio-url` 即视为有音频）。只探测视频流，音频 URL 不探测，探测同样带上 `:headers` 与 `:proxy`。探测程序缺失时保留文档默认值——640 × 360、每秒 25 帧、无时长、无音频。demo 不需要任何程序，报告 640 × 360、每秒 30 帧、30 秒。权威 plist 原样复制，所以它缺失的键保持 nil，而不会被默认值补上，但 `:audio-target` 与由 `:audio-url` 推出的 `:audio` 除外。每次调用都会探测；结果可以之后再传回来，而不再探测。

**返回。** 元数据 plist。

**错误。** `:kind` 不是三个合法值时 `error→ user-error`，消息 `"Unsupported etaf-video source kind: %S"`；值不是字符串、源 plist 或 nil 时 `error→ user-error`，消息 `"Unsupported etaf-video source: %S"`；文件缺失或不可读时 `error→ user-error`，消息 `"Video file is not readable: %S"`；`:url` 条目不是 HTTP 或 HTTPS URL 时 `error→ user-error`，消息 `"Video URL must be http or https: %S"`；`:audio-url` 不是时消息 `"Video audio URL must be http or https: %S"`；`:proxy` 不是时消息 `"Video proxy must be an http or https URL: %S"`；头条目格式非法时报 `"Video header line is malformed: %S"`、`"Video headers must be name and value strings: %S"` 或 `"Video header names and values must not contain control characters: %S"`。既不是 HTTP 或 HTTPS URL 也不是可读文件的裸字符串按文件名处理，报文件错误。

**示例。**

```elisp
(etaf-video-source-info nil)
;; ⇒ (:kind demo :file nil :url nil :target nil :audio-url nil
;;    :audio-target nil :headers nil :proxy nil :width 640 :height 360
;;    :duration 30 :fps 30 :audio nil)
```

视频与音频分离、需要请求头与代理的源：

```elisp
(etaf-video-source-info
 '(:url "https://media.example/video.m4s"
   :audio-url "https://media.example/audio.m4s"
   :headers '(("User-Agent" . "MyApp/1.0"))
   :proxy "http://127.0.0.1:7890"))
```

**参见。** `etaf-video`、`etaf-video-state`、`etaf-video-seek`。

## 播放控制

<!-- index: etaf-video-play; etaf-video-pause; etaf-video-toggle-playback; etaf-video-step; etaf-video-seek; etaf-video-set-speed; etaf-video-state; :on-state -->

控制函数通过 Component 注册的 HANDLE 寻址已挂载的视频。视频是一个带小状态机的播放会话：生产者可能在运行或已释放，可能有待处理的手动步进，源可能已经结束。每个控制都立刻动作；除了帧呈现本身，什么都不等下一次显示拍；新状态都通过 `etaf-video-state` 读取，状态变化则由 `:on-state` 回调上报。

#### Function: etaf-video-play (handle)

开始或恢复 HANDLE 标识的已挂载视频。

**参数。** HANDLE 是某个已挂载 `etaf-video` 注册的符号。

**语义。** 播放会启动生产者和音频旁路（如果会话配置为播放音频）。恢复会把生产者重启在最后呈现的位置，所以绝不会为了追墙钟而快进。待处理的手动步进被取消，因为播放优先。

**返回。** 该 handle。

**错误。** 非符号时 `error→ user-error`，消息 `"Video handle must be a symbol: %S"`；没有已挂载视频拥有 HANDLE 时 `error→ user-error`，消息 `"No mounted etaf-video for handle %S"`。

**参见。** `etaf-video-pause`、`etaf-video-toggle-playback`、`etaf-video-state`。

#### Function: etaf-video-pause (handle)

暂停 HANDLE 标识的已挂载视频。

**参数。** HANDLE 是注册的符号。

**语义。** 生产者与音频旁路被释放；最后一幅画面留在画布上，`etaf-video-state` 继续报告它到达的位置。暂停的视频在下一次步进、定位或恢复播放之前不呈现任何东西。

**返回。** 该 handle。

**错误。** 与 `etaf-video-play` 相同的 handle 错误。

**参见。** `etaf-video-play`、`etaf-video-step`、`etaf-video-seek`。

#### Function: etaf-video-toggle-playback (handle)

在播放与暂停之间切换 HANDLE 标识的已挂载视频。

**参数。** HANDLE 是注册的符号。

**语义。** 播放中的视频暂停，暂停的视频播放。已经结束的视频从头重启，所以这个函数是单个播放按钮的常用绑定。

**返回。** 该 handle。

**错误。** 与 `etaf-video-play` 相同的 handle 错误。

**参见。** `etaf-video-play`、`etaf-video-state`。

#### Function: etaf-video-step (handle)

暂停 HANDLE 标识的已挂载视频，再呈现一帧。

**参数。** HANDLE 是注册的符号。

**语义。** 播放中的视频先被暂停。会话随后为恰好一帧启动生产者，呈现它，再释放生产者。故意关闭生产者不算视频结束：`etaf-video-state` 仍报告 `:ended` 为 nil。

**返回。** 该 handle。

**错误。** 与 `etaf-video-play` 相同的 handle 错误。

**参见。** `etaf-video-pause`、`etaf-video-seek`、`etaf-video-state`。

#### Function: etaf-video-seek (handle seconds)

把 HANDLE 标识的已挂载视频移到 SECONDS。

**参数。** HANDLE 是注册的符号；SECONDS 是秒数位置，已知源时长时会被截断到该时长之内。

**语义。** 播放中的视频在新位置重启生产者并从那里继续；暂停的视频呈现新位置的那一帧并保持暂停。进度条或拖动定位就是靠它移动视频。

**返回。** 该 handle。

**错误。** 与 `etaf-video-play` 相同的 handle 错误。

**参见。** `etaf-video-step`、`etaf-video-state`、`etaf-video-source-info`。

#### Function: etaf-video-set-speed (handle speed)

设置 HANDLE 标识的已挂载视频的播放速率。

**参数。** HANDLE 是注册的符号；SPEED 是正数，1 表示源速率。

**语义。** 播放中的视频在同一位置以新的读取速率重启生产者，所以改速率不丢位置；暂停的视频为该值留到下次播放使用。这个值同时也是 Component 的 SPEED 输入。

**返回。** 该 handle。

**错误。** SPEED 非正数或非数字时 `error→ user-error`，消息 `"Playback speed must be a positive number: %S"`；另有与 `etaf-video-play` 相同的 handle 错误。

**参见。** `etaf-video-state`、`etaf-video`。

#### Function: etaf-video-state (handle)

把 HANDLE 标识的已挂载视频作为 detached plist 返回。

**参数。** HANDLE 是注册的符号。

**语义。** plist 描述调用时的会话：`:handle`、`:mode`（`image` 退回后的有效渲染模式）、`:source`（文件名、URL 字符串或符号 `demo`）、`:playing`、`:position`（秒；seek 基准加按源帧率收到的帧数，截断到时长）、`:duration`、`:speed`、`:format`（生产者的帧格式：`gray`、`rgb24` 或 `mjpeg`）、`:width` 与 `:height`（生产者像素）、`:display-fps`、`:source-fps`、`:received`、`:presented`、`:dropped`、`:audio` 与 `:ended`。返回后结果不再指向会话，可以安全保存与比较。`:audio` 报告会话的音频设置；没有音轨的源即使它为真也保持静音。

**返回。** detached 状态 plist。

**错误。** 与 `etaf-video-play` 相同的 handle 错误。

**参见。** `etaf-video-play`、`etaf-video-seek`、`etaf-video-toggle-playback`。

#### Property: :on-state

视频播放会话的状态回调。

**参数。** 一个单参函数，参数是会话；可选。

**语义。** 会话在每次状态变化之后调用它：播放开始、暂停、步进、定位或改变速率、音量、音频，以及源结束时。它跑在状态更新之后，所以回调读到的是新状态。原生 Component 用它让呈现与音频保持一致；需要同样通知的应用按自己的节奏读 `etaf-video-state`。

**参见。** `etaf-video-state`、`etaf-video-play`、`:on-frame`。

## 音频

<!-- index: etaf-video-audio; etaf-video-audio-volume; etaf-video-set-volume; etaf-video-set-audio; 音频旁路 -->

音频经独立的播放器进程——*旁路*——播放，所以画面解码与声音播放互不牵制。源用 `:audio-url` 描述独立音频流时，旁路打开该流；否则打开视频源本身。旁路使用与视频解码器相同的 `:headers` 与 `:proxy`，因此鉴权源的画面与声音共用同一份权限描述。一个会话至多拥有一个旁路；它随播放启动，随暂停、定位、变速或卸载释放。没有音轨的源、内置 demo 和缺失的播放器都保持静音，且不报错。

#### Variable: etaf-video-audio

新视频是否默认播放来源的音轨。

**语义。** 变量默认 nil，即视频保持静音，除非明确要求声音；`etaf-video` Component 的 AUDIO 输入逐实例覆盖它，可以是 ref 或计算值。这个设置是请求而非保证：没有音轨的源保持静音。

**参见。** `etaf-video-audio-volume`、`etaf-video-set-audio`、`etaf-video`。

#### Variable: etaf-video-audio-volume

新视频的默认音量，0 到 100。

**语义。** 变量默认 100，是 Component VOLUME 输入的默认值，后者逐实例覆盖它。音量变化作用于运行中的旁路，不重启画面。

**参见。** `etaf-video-audio`、`etaf-video-set-volume`。

#### Function: etaf-video-set-volume (handle volume)

设置 HANDLE 标识的已挂载视频的音频音量。

**参数。** HANDLE 是注册的符号；VOLUME 从 0 到 100。

**语义。** 播放中的视频在同一位置以新音量重启音频旁路；暂停的视频为该值留到下次播放使用。没有音轨的源不受影响。

**返回。** 该 handle。

**错误。** 值超出范围时 `error→ user-error`，消息 `"Audio volume must be between 0 and 100: %S"`；另有与 `etaf-video-play` 相同的 handle 错误。

**参见。** `etaf-video-set-audio`、`etaf-video-audio-volume`、`etaf-video-state`。

#### Function: etaf-video-set-audio (handle audio)

打开或关闭 HANDLE 标识的已挂载视频的音频旁路。

**参数。** HANDLE 是注册的符号；AUDIO 非 nil 打开声音，nil 关闭。

**语义。** 打开会在视频播放时启动旁路；关闭会停止它。没有音轨的源无论标志如何都保持静音，`etaf-video-state` 仍报告请求的设置。

**返回。** 该 handle。

**错误。** 与 `etaf-video-play` 相同的 handle 错误。

**参见。** `etaf-video-set-volume`、`etaf-video-audio`、`etaf-video-state`。

## 呈现

<!-- index: :on-frame; etaf-video-density-ramp; etaf-video-display-fps; 丢帧; 密度阶梯 -->

生产者、显示定时器与画布构成一条流水线：生产者按解码器交付的速度填帧，会话只保留最新的完整帧，显示定时器每个周期呈现一帧。帧到得比显示速率快时，多余的帧被丢弃并计数，绝不排队；画布每次拍显示当时可得的最新画面。呈现失败不会悄悄中断会话的生产者：会话被销毁，失败写进 `*Messages*`，最后一幅画面留在原地。

#### Property: :on-frame

视频播放会话的帧回调。

**参数。** 一个双参函数，参数是帧与会话；可选。

**语义。** 会话在显示拍领取到帧后，为每个呈现的帧调用它一次。帧是生产者的字节：`gray` 格式每像素一个灰度字节，`rgb24` 每像素三个 RGB 字节，`mjpeg` 则是一张完整 JPEG 图片。原生 Component 安装把帧映射进画布的回调；这个回调定义了解码与显示之间的交接，到达它的帧就是生产者当时最新的完整帧。

**参见。** `etaf-video-display-fps`、`etaf-video-density-ramp`、`:on-state`。

#### Variable: etaf-video-density-ramp

`ascii` 渲染模式下每个视频像素所用的字符。

**语义。** 字符串从左到右把暗度映射到密度，必须非空且单行，默认 `" .:-=+*#%@"`。每个灰度字节选择最接近其暗度的字符，所以两个字符的阶梯产生硬阈值，十个字符产生十个层次。变量是之后挂载视频的默认值；已挂载的画布保留挂载时捕获的阶梯，除非 Component 调用带新值重新求值，而逐实例 RAMP 输入覆盖变量。

**错误。** 值为空或含换行时 `error→ user-error`，消息 `"Video density ramp must be a nonempty single-line string: %S"`。

**参见。** `etaf-video`、`etaf-video-display-fps`。

#### Variable: etaf-video-display-fps

新视频播放的显示定时器频率，单位是每秒帧数。

**语义。** 值默认 30，封顶呈现帧率，小于 1 时被提到 1。它不节流生产者：解码器按播放速率的要求运行，显示拍之间到达的帧被覆盖。较低的值以流畅度换取更少的发布与更轻的主线程每拍工作。Component 的 DISPLAY-FPS 输入逐实例覆盖变量，且必须是正整数。

**参见。** `etaf-video`、`:on-frame`、`etaf-video-set-speed`。

#### Variable: etaf-video-render-backend

视频帧到达屏幕所用的渲染后端。

**语义。** 值默认 `image`：每帧发布一张缩放后的 JPEG，经保留的 Host 内容写入画布，任何能显示图像的 Emacs 都能用。`canvas` 把 BGRA 帧读进一张 Emacs canvas 图像，只刷新它的像素缓冲，不再逐帧编码、解码或发布内容；它要求 Emacs 具备 `canvas` 图像类型（Emacs 32，或打了 canvas 补丁的 31）以及编译好的 `native/etaf-video-canvas` 模块。`auto` 在两者都满足时选 `canvas`，否则选 `image`。能力不满足时本变量不会导致失败：缺图像类型、模块加载失败或画布不在图形 frame 里，都静默回退 `image`。`ascii` 与 `color` 模式不受影响。

**性能。** canvas 缓冲保持在逻辑分辨率：macOS 的 NS 后端在每次刷新时逐像素上传，设备分辨率的缓冲会让每帧成本翻四倍而画布上没有可见收益。

**参见。** `etaf-video`、`etaf-video-display-fps`。

## 外部程序

<!-- index: etaf-video-ffmpeg-program; etaf-video-ffplay-program; etaf-video-ffprobe-program; 可选依赖 -->

三个变量命名视频播放使用的外部程序。每个都接受在搜索路径上解析的可执行名或绝对路径，所以项目可以钉住版本或指向包装脚本。[安装与加载](installation-and-loading.md) 列出每个程序缺失时造成的降级。

#### Variable: etaf-video-ffmpeg-program

用于解码视频的 ffmpeg 可执行文件的名字或绝对路径。

**语义。** 变量默认 `"ffmpeg"`。包装脚本可以追加解码参数；框架在程序名之后追加输入、缩放滤镜与输出格式。没有可用程序时，开始播放会在任何进程存在之前报 `user-error`。

**错误。** 找不到或无法启动该程序时 `error→ user-error`，消息 `"ffmpeg is not available: %s"`。

**参见。** `etaf-video-ffprobe-program`、`etaf-video-ffplay-program`、`etaf-video-play`。

#### Variable: etaf-video-ffplay-program

用于音频的 ffplay 可执行文件的名字或绝对路径。

**语义。** 变量默认 `"ffplay"`，是 ffmpeg 安装的一部分。没有可用程序时视频无声播放，且不报错，因为音频只是旁路，从不阻塞画面。

**参见。** `etaf-video-audio`、`etaf-video-ffmpeg-program`。

#### Variable: etaf-video-ffprobe-program

用于元数据的 ffprobe 可执行文件的名字或绝对路径。

**语义。** 变量默认 `"ffprobe"`。没有可用程序时 `etaf-video-source-info` 保留文档默认值而不是失败，所以视频仍会挂载，并以画布自身的尺寸为准。

**参见。** `etaf-video-source-info`、`etaf-video-ffmpeg-program`。

## 错误与恢复

<!-- index: 视频失败; 可选依赖降级 -->

视频播放可能在四处失败：读取源、校验 Component 调用、寻址 handle，以及运行外部程序。它们都不是独立定义的条件；框架把它们报成 `user-error` 或 `etaf-component-call-error`，解码器失败则写在消息缓冲区里，而不是抛出。

| 失败 | 会发生什么 |
| --- | --- |
| Component 属性超出约定 | 调用时报 `etaf-component-call-error`，点名属性与期望值；什么都不挂载 |
| SRC 不支持、不可读，协议不是 HTTP(S)，或 `:audio-url`、`:proxy`、`:headers` 非法 | 在任何解码器启动之前报 `user-error` |
| handle 没有对应已挂载视频或不是符号 | 每个控制函数都报 `user-error` |
| 同一个 handle 被挂载两次 | `user-error`；第二个视频不挂载 |
| ffmpeg 缺失或无法启动 | 在任何进程存在之前报 `user-error`；什么都不播放 |
| ffprobe 缺失 | `etaf-video-source-info` 返回文档默认元数据 |
| ffplay 缺失 | 视频无声播放；不报错 |
| 上一帧未被领取时新帧到达 | 上一帧被丢弃并计入 `:dropped` |
| 播放中画布更新失败 | 会话被销毁，失败写进 `*Messages*`，最后一幅画面留下 |
| 播放中卸载视频 | 生产者、音频旁路、handle 注册与帧缓存全部释放 |
