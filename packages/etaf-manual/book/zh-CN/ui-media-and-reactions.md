# 媒体与互动

两个组件覆盖媒体与轻量互动：一个是查看单张图片、单个视频或音频文件的模态查看器，一个是带可选 emoji 选择器的反应 chip 行。两者都受控——打开标志、媒体来源或反应条目归调用方所有——也都组合前面章节已定义的表面。[原生视频](native-video.md)定义查看器所驱动的视频来源与播放会话，[浮层](ui-overlays.md)定义模态表面与关闭规则，[UI 组件库总论](ui-overview.md)定义共同契约。

## 媒体查看器

<!-- index: etaf-media-viewer; modal viewer; transport bar; keyboard playback -->

#### Component: etaf-media-viewer (&key open kind src source-size title subtitle caption duration on-close on-previous on-next autoplay)

在应用之上的受控模态查看器里显示一个图片、视频或音频文件，且不离开同一个 buffer。

**参数。** OPEN 是值、ref 或 computed。KIND 是 `image`（默认）、`video` 或 `audio`。SRC 对 image 是 image Host 来源——文件或图像描述符，包括图标辅助构建的 SVG 描述符；对 video 是 `etaf-video` 来源；对 audio 是经 ffplay 播放的音频文件。SOURCE-SIZE 是媒体的像素 `(WIDTH . HEIGHT)`；没有它时查看器读取图片或探测一次视频。TITLE、SUBTITLE 与 CAPTION 是可选字符串：header 显示前两者，图片的 footer 与音频舞台显示 caption。DURATION（秒）给音频文件总时长。AUTOPLAY 默认 t。ON-CLOSE 必需；ON-PREVIOUS 与 ON-NEXT 是可选的浏览回调。

**语义。** 查看器坐在覆盖 root 画布第一个视口的固定暗色 scrim 上，使用独立于应用主题的自己的调色板，因此请把它挂进根为一行高窗口的应用，例如 `(vh 100)` 的 shell。媒体保持宽高比并适配实时视口、跟随窗口缩放：图片不放大超过自然尺寸，视频填满舞台。图片 footer 显示 CAPTION；视频与音频在 AUTOPLAY 时开始播放，并得到传输条：播放与暂停、前后十秒、已播与总时长、seek 条、播放倍速与声音——点击媒体切换播放。提供 ON-PREVIOUS 或 ON-NEXT 时查看器增加侧箭头、`p` 与 `n` 键以及双指滑动来浏览画廊；图片时方向键也浏览，视频时方向键 seek 五秒。打开期间查看器的键优先于应用键，其它可打印键不做任何事，关闭后焦点回到此前的控件。

**返回。** 一个 View。

**错误。** KIND 不是三者之一、DURATION 既不是 nil 也不是非负数、ON-CLOSE 不是函数、ON-PREVIOUS 或 ON-NEXT 既不是函数也不是 nil、SOURCE-SIZE 既不是 nil 也不是正的像素对、或 TITLE/SUBTITLE/CAPTION 既不是字符串也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-media-viewer :open viewer :kind 'image :src "photo.png"
                   :title "photo.png" :source-size '(640 . 480)
                   :on-close (lambda () (setf viewer nil)))
```

**参见。** `etaf-video`、`etaf-popover`。

## 互动条

<!-- index: etaf-reactions; reaction chip; emoji picker; chosen state -->

#### Component: etaf-reactions (&key items on-toggle choices add-label)

渲染一行受控的反应 chip，例如聊天消息下方的表情回应。

**参数。** ITEMS——值或 ref——是带唯一非 nil 标量 `:key`（符号、整数或字符串，即 ETAF View 键接受的标识）、非空字符串 `:label`（通常是 emoji）、可选自然数 `:count`（显示在标签后）与布尔 `:chosen` 的 plist。ON-TOGGLE 接收被按 chip 的键。CHOICES 是 `(KEY . LABEL)` 的 alist，添加尾部名为 ADD-LABEL（默认 `"Add reaction"`）的笑脸 chip，打开选择浮层。

**语义。** 选中的 chip 用 accent 前景画在 accent 浅色上，带 `chosen` 类与可访问的 `(chosen)` 后缀；选中与未选中的 chip 共享内边距与字重，所以切换永不移动邻居，只有 count 增位时 chip 变宽。选择浮层把选项每行六个、每格四列排布，行与行之间留一个空行，因此再宽的 emoji 也居中落在均匀网格里；选中一个会关闭浮层并以该键调用 ON-TOGGLE。整行不换行，所以请让 ITEMS 短到容器放得下。

**返回。** 一个 View。

**错误。** ITEMS 不是由唯一标量键、非空标签与自然数 count 构成的反应 plist 列表、CHOICES 不是由唯一键与非空字符串标签构成的 alist、ON-TOGGLE 不是函数、或 ADD-LABEL 不是非空字符串时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-reactions :items '((:key heart :label "❤" :count 3 :chosen t)
                         (:key laugh :label "😂"))
                :choices '((heart . "❤") (laugh . "😂") (party . "🎉"))
                :on-toggle #'toggle-reaction)
```

**参见。** `etaf-popover`、`etaf-ui-icon`。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的 prop，消息点名组件、属性、收到的值与期望，其中包括非法的媒体 kind、负数 duration 与形式非法的反应或选项列表。
- 查看器不拥有媒体状态：它从不决定何时关闭，每条关闭路径——Escape、`q`、关闭控件、外部按压——都请求 ON-CLOSE。缺失解码器或音频程序时降级为 image host 的占位或静音，而不是让挂载失败。
- 互动条是调用方 item 的纯呈现：按压只报告一个键，只有调用方的 ITEMS 变化时整行才重渲染，因此被忽略的切换让 chip 保持原样。
- 被拒绝的发布不会让两个组件保留焦点或播放状态：此前已提交的媒体帧或 chip 行保持可见。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[浮层](ui-overlays.md)。

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-reactions :items '((:key heart :label "❤" :count 3 :chosen t)
                            (:key laugh :label "😂"))
                   :on-toggle #'ignore)))
```
