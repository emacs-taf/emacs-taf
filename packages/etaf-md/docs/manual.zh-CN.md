# ETAF Markdown 预览手册

这本手册讲读者会用到的流程。支持的接口清单在根入口的 Commentary 里，本文只链接过去，
不重复写签名。

## 按键

| 按键 | 作用 |
| --- | --- |
| `n` / `p` | 跳到文档的下一个 / 上一个标题 |
| `C-c j` | 从补全列表里选一个标题 |
| `RET`、鼠标左键 | 激活光标下的链接或图片；播放、暂停视频 |
| `r` | 重新读取文件并重画 |
| `t` | 轮换配色（暗色、亮色、sepia） |
| `[` / `]` | 把最大阅读宽度收窄 / 加宽四列 |
| `?`、`C-c h` | 在页面内的帮助面板里查当前按键 |
| `q` | 卸载预览并杀掉它的 buffer |
| `C-s`、`C-v`、`M-v`、滚轮 | 原生的增量搜索与滚动 |

这个 buffer 就是普通的 Emacs buffer，所以 isearch、`occur`、分窗、`C-x C-s` 这类
buffer 操作和 `imenu` 都照常可用。`M-x imenu` 列出文档目录。帮助留在预览窗口里，
跟着预览的配色走。`/` 搜索；按 Escape 先退出搜索编辑，再关掉帮助。点面板外面也能关掉它，
并把阅读焦点还回去。

## 支持的 Markdown

解析器覆盖 CommonMark 的块与行内语法，外加预览需要的 GitHub 扩展：

- 标题：ATX（`#` 到 `######`）与 Setext（`===`、`---`），带稳定锚点，供目录和
  `#fragment` 链接使用。
- 段落：强调、加粗、删除线、行内代码、链接（行内、引用式、快捷式）、自动链接，还有
  原始行内 HTML（按字面显示）。
- 围栏代码块（带信息串，显示成语言标签）与缩进代码块；长行会折行，不把代码藏起来。
- 引用块、可嵌套的有序与无序列表、任务项（`- [x]`、`- [ ]`）。
- 管道表格，支持左对齐、居中、右对齐，画成完整的网格：外框、行列分隔线和表头横线。
- GitHub 提示块（`> [!NOTE]`、`[!TIP]`、`[!IMPORTANT]`、`[!WARNING]`、`[!CAUTION]`），
  带标题。
- 分隔线、字符引用、反斜杠转义和硬换行。
- 脚注：`[^label]` 引用显示成编号，定义收集在文末；激活引用会跳到对应定义。
- YAML front matter 从正文里去掉；其中 `title` 成为文档标题，author、date、version、
  license、status 渲染在页面顶部的标题区。

像 `:smile:` 这样的 emoji 短码会画成对应的字符。

除了 Markdown，文档还可以写容器：用 `:::name {attrs}` 包住一段 Markdown，
在拥有它们的容器里再用 `@tab` 标记一页。容器是文档的构件，提示块、卡片、
页签组、时间线、目录树、能高亮行列的表格都算。词汇表、属性和怎么加自己的
容器，见[扩展语法](extensions.zh-CN.md)。

`etaf-md-create` 用 `:flavor` 选方言：`gfm`（默认）打开 GitHub 扩展和 front
matter，`commonmark` 只按核心规范解析，也可以传一个特性 plist，例如
`(:tables t :task-lists nil)`，逐个开关扩展。

图片语法和 HTML 的 `<img>`、`<video>` 标签渲染成媒体卡。相对路径相对文档所在目录解析。
本地图片走 ETAF 的图片 Host；本地视频先显示一张海报（首帧，同样走图片 Host），按 `RET`
或点一下就把原生视频组件挂上去，就地播放。播放中再按一次切换播放与暂停，不用离开 Emacs。
`exec-path` 里没有 ffmpeg 时，卡片保留海报，按 `RET` 用系统默认播放器打开。远程图片显示
带标注的占位卡，激活它打开链接。文件丢失或读不出来时显示占位卡，不会报错。

## 配色与版面

`etaf-md-theme` 决定文档的颜色。默认的 `auto` 从当前 frame 自己的 face 里推：
页面用 Emacs 主题的背景色，次要文字跟 `shadow`，标题跟 `outline-1`，链接跟 `link`，
提示块跟 `success`、`warning`、`error`，面板底色（代码块、表头与斑马纹、分隔线）是
frame 背景朝前景混出来的浅色。因此预览跟当前 Emacs 主题一致，自己不画页面背景。想要
自带背景的独立页面时，固定的 `dark`、`light`、`sepia` 三套配色仍然可用：选了就画各自的
页面底色。`t` 在这三套之间轮换，`etaf-md-set-theme` 钉住其中一套，最终的颜色
以 `:ui-*` 主题令牌发布出去，预览里用到的共享 ETAF UI 组件跟着它们走。

阅读宽度有上限，并且在窗口里居中。会话里存的是上限；这一列伸展到窗口宽度，但不超过上限，
所以窄窗口就用满可用的列。这一列在正文之外两侧各留两格边距，文字不会顶在窗口边缘，
表格的边框也不会落进渲染器把最后一格铺满窗口余量的那一列。`[` 和 `]` 手动加减上限，
结果夹在 `etaf-md-width-min` 与 `etaf-md-width-max` 之间。窗口缩放走
渲染器的视口更新重新流排，不重建文档；预览只发布到一个 buffer，所以缩放不会重启会话。

能用的最窄窗口是「最小宽度加两侧边距」，约 44 列。比这更窄时，缩不下去的块（例如列里
必须整词保留的表格）在宽度处被裁掉，不会画到边距上；文字照常折行，版面保持原样。

## 跟随源文件

打开着的预览跟着它的源 buffer 走：每次改动都在下一帧重画文档，大约 16 ms 之后，所以
打字的人能边打边看到渲染变化。一串按键合并成每帧一次重画，保存或者外部写入走同一条路。
每个顶层块都发布成自己的 Component，用类型和源码文本当身份，所以一次重画只渲染变了的
那块，其余块的渲染结果、视频句柄和阅读位置都留着。插入或删除一个块会让它后面的块重画，
因为位置变了；在块里打字不会。

## 定制

四项设置覆盖支持的个人化；其余外观都由文档和 frame 决定。

| 设置 | 默认值 | 作用 |
| --- | --- | --- |
| `etaf-md-theme` | `auto` | 初始配色；`auto` 从 Emacs 主题的 face 推颜色，不画页面背景。 |
| `etaf-md-flavor` | `gfm` | `etaf-md-create` 没收到 `:flavor` 时用的方言。 |
| `etaf-md-width-min` | `40` | 最窄的阅读宽度，单位是字符格。 |
| `etaf-md-width-max` | `96` | 最宽的阅读宽度；窗口更宽时保持这个值并把这一列居中。 |

## 脚本与无界面使用

`etaf-md-create` 从文件或者一段文字建会话，不需要 buffer；`etaf-md-view`
返回可挂载的视图；`etaf-md-state` 报告一份分离的快照。从文字建出来的会话就是完整的
无界面预览，验收测试用的正是它：

```elisp
(let* ((session (etaf-md-create :text "# 笔记\n\n**加粗** 正文。\n"))
       (buffer (etaf-md-open session)))
  (etaf-md-locate session 0)
  (etaf-md-set-theme session 'sepia)
  (etaf-md-refresh session)
  (with-current-buffer buffer (etaf-md-close)))
```

`etaf-md-open` 接受文件路径或者会话，所以调用方可以渲染自己拼出来的文档。
`etaf-md-locate` 把光标移到目录里的第几项；`etaf-md-outline` 返回目录本身。

### 由上层应用接管链接与媒体

把 `etaf-md` 嵌进阅读器、网页视图或知识库应用时，往往不想把每次点击都直接丢给系统浏览器或默认播放器。给 `etaf-md-create` 传入 `:on-link` 和 `:on-media` 就能拦截这两类激活事件：

- `:on-link` 接收 `(url)`，适合做站内路由、自定义协议分流或记录浏览历史；
- `:on-media` 接收 `(kind path)`，其中 `kind` 为符号 `image` 或 `video`，`path` 是解析后的本地绝对路径或远程 URL，适合接入自定义灯箱看图或外部播放队列。

两个回调都按返回值决定后续动作：返回非 nil 表示应用已经处理完，不再触发默认行为；返回 nil 则原样回退到 `etaf-md` 内置的锚点跳转、打开文件/浏览器或内嵌视频播放。下面这段代码可以直接求值试跑：

```elisp
(let* ((session
        (etaf-md-create
         :text "站内文档见 [接口说明](app://docs/api)，外部页面走默认 [主页](https://example.org)。\n\n![示意图](diagram.png)\n"
         :on-link (lambda (url)
                    (when (string-prefix-p "app://" url)
                      (message "站内打开：%s" url)
                      t))
         :on-media (lambda (kind path)
                     (when (eq kind 'image)
                       (message "看图器预览 %s" path)
                       t))))
       (buffer (etaf-md-open session)))
  (with-current-buffer buffer (etaf-md-close)))
```

`scripts/etaf-md-gui-probe.el` 驱动一个活的 frame 做 GUI 验证：按指定的 frame 尺寸打开
文档，报告一行状态，发送真实按键，并检查版面不变量（没有超宽的行、有可交互的链接、有目录）。

## 排错

- **跳标题跳到了同一个词的别处。** 标题跳转是在行首找到渲染后的标题文字，按目录顺序找。
  文字相同的两个标题按顺序匹配；如果某个段落恰好也以同样的字在行首开头，可能先匹配到它。
- **图片显示成点阵或者彩色方块网格。** 当前 frame 对这个文件没有可用的图形支持，Ebox 退回
  了终端转换器；装上 ffmpeg 能让终端渲染好一些，或者换到图形 frame 里看。
- **视频用系统播放器打开，没在原地播。** `exec-path` 上没有 ffmpeg，卡片保留了海报回退。
- **播放完的视频按 `RET` 会从头再来。** 播完的视频没有暂停状态可恢复，下一次按下就是重播；
  在那之前画布上留着最后一帧，短片可能在下次按键之前就播完了。
- **换主题后共享组件没重画。** 预览只给自己的子树发布配色，外层的应用保持它自己的主题上下文。
