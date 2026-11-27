# ETAF Markdown 预览手册

这本手册讲读者会用到的流程。支持的接口清单在根入口的 Commentary 里，本文只链接过去，不重复写签名。

## 入口与按键

在任意 Markdown 缓冲区里运行 `M-x etaf-md-open`，直接在当前窗口全宽打开阅读视图（免弹窗、不分屏；加前缀 `C-u` 或在其他缓冲区里运行则弹出文件选择）。需要边写边看时，在源文档里运行 `M-x etaf-md-preview` 开关右侧实时对照分屏，或在预览内按 `v` 就地切换。全局自动加载的 `M-x` 入口仅保留这两个命令；下表所有操作均是绑定到预览缓冲区的交互命令（通过 `completion-predicate` 限定在预览缓冲区内补全，同时支持快捷键与 `M-x` / `M-X` 调用，按 `?` 随时搜索）。

| 按键 | 作用 |
| --- | --- |
| `n` / `p` | 跳到文档的下一个 / 上一个标题（跳转前自动压栈 mark） |
| `j` | 从补全列表里选一个标题（跳转前自动压栈 mark） |
| `T` | 开关缓冲区内可拖拽调宽的 ETAF 目录侧栏（默认左侧，由 `etaf-md-toc-side` / `etaf-md-toc-width` 配置） |
| `e` / `o` | 从预览当前位置反向跳回源文档对应行 |
| `v` | 在单窗全宽阅读与「左源码 + 右预览」双栏对照间切换 |
| `f` | 开关按比例同步的源窗口滚动跟随 |
| `RET`、鼠标左键 | 激活光标下的链接或图片；播放、暂停视频 |
| `g` / `r` | 重新读取文件并重画 |
| `t` | 轮换配色（暗色、亮色、sepia、随主题 `auto`） |
| `[` / `]` | 把最大阅读宽度收窄 / 加宽四列 |
| `K` / `S` | 就地预览光标处链接或符号 / 全局显隐遮罩 |
| `?` | 在页面内的帮助面板里查当前按键 |
| `q` | 关闭预览（单窗切回原缓冲区；分屏仅回收预览窗格） |
| `C-s`、`C-v`、`M-v`、滚轮 | 原生的增量搜索与滚动 |

默认全部使用单键，绝不覆盖用户的 `C-c`、`C-t`、`C-x` 等全局前缀键。可通过自定义变量 `etaf-md-keys` 调整或清空按键，或在预览缓冲区内直接通过 `M-x` / `M-X` 调用任意预览交互命令。

这个 buffer 就是普通的 Emacs buffer，所以 isearch、`occur`、分窗、`C-x C-s` 这类 buffer 操作和 `imenu` 都照常可用。`M-x imenu` 列出文档目录。帮助留在预览窗口里，跟着预览的配色走。`/` 搜索；按 Escape 先退出搜索编辑，再关掉帮助。点面板外面也能关掉它，并把阅读焦点还回去。

## 支持的 Markdown

解析器覆盖 CommonMark 的块与行内语法，外加预览需要的 GitHub 扩展：

- 标题：ATX（`#` 到 `######`）与 Setext（`===`、`---`），带稳定锚点，供目录和 `#fragment` 链接使用。
- 段落：强调、加粗、删除线、行内代码、链接（行内、引用式、快捷式）、自动链接，还有原始行内 HTML（按字面显示）。
- 围栏代码块（带信息串，显示成语言标签）与缩进代码块；长行会折行，不把代码藏起来。
- 引用块、可嵌套的有序与无序列表、任务项（`- [x]`、`- [ ]`）。
- 管道表格，支持左对齐、居中、右对齐，画成完整的网格：外框、行列分隔线和表头横线。
- GitHub 提示块（`> [!NOTE]`、`[!TIP]`、`[!IMPORTANT]`、`[!WARNING]`、`[!CAUTION]`），带标题。
- 分隔线、字符引用、反斜杠转义和硬换行。
- 脚注：`[^label]` 引用显示成编号，定义收集在文末；激活引用会跳到文末对应定义（跳转前压栈 mark），激活定义末尾的 `↩` 可跳回原引用处。
- YAML front matter 从正文里去掉；其中 `title` 成为文档标题，author、date、version、license、status 渲染在页面顶部的标题区。

像 `:smile:` 这样的 emoji 短码会画成对应的字符。

除了 Markdown，文档还可以写容器：用 `:::name {attrs}` 包住一段 Markdown，在拥有它们的容器里再用 `@tab` 标记一页。容器是文档的构件，提示块、卡片、页签组、时间线、目录树、能高亮行列的表格都算。词汇表、属性和怎么加自己的容器，见[扩展语法](extensions.zh-CN.md)。

`etaf-md-create` 用 `:flavor` 选方言：`etaf`（默认）打开 GFM 加上 ETAF 扩展与 front matter，`gfm` 打开 GitHub 扩展与 front matter，`commonmark` 只按核心规范解析，也可以传一个特性 plist，例如 `(:tables t :task-lists nil)`，逐个开关扩展。

图片语法和 HTML 的 `<img>`、`<video>` 标签渲染成媒体卡。相对路径相对文档所在目录解析（`file://` URI 同样按本地文件解析）。本地图片走 ETAF 的图片 Host；本地视频先显示一张海报（首帧，同样走图片 Host），按 `RET` 或点一下就把原生视频组件挂上去，就地播放。播放中再按一次切换播放与暂停，不用离开 Emacs。`exec-path` 里没有 ffmpeg 时，卡片保留海报，按 `RET` 用系统默认播放器打开。当 `etaf-md-remote-images` 为非 nil（默认）时，远程 HTTP(S) 图片会在预览挂载后异步拉取到有上限的本地磁盘缓存（`etaf-md-cache-max-bytes`）并就地刷成实图；拉取前或关闭该选项时显示带标注的占位卡，激活它打开链接。文件丢失或读不出来时显示占位卡，不会报错。

## 配色与版面

`etaf-md-theme` 决定文档的颜色。默认的 `auto` 从当前 frame 自己的 face 里推：页面用 Emacs 主题的背景色，次要文字跟 `shadow`，标题跟 `outline-1`，链接跟 `link`，提示块跟 `success`、`warning`、`error`，面板底色（代码块、表头与斑马纹、分隔线）是 frame 背景朝前景混出来的浅色。因此预览跟当前 Emacs 主题一致，自己不画页面背景。想要自带背景的独立页面时，固定的 `dark`、`light`、`sepia` 三套配色仍然可用：选了就画各自的页面底色。`t` 在 `dark`、`light`、`sepia` 与 `auto` 之间轮换，`etaf-md-set-theme` 钉住其中一套，最终的颜色以 `:ui-*` 主题令牌发布出去，预览里用到的共享 ETAF UI 组件跟着它们走。

阅读宽度有上限，并且在窗口里居中。会话里存的是上限；这一列伸展到窗口宽度，但不超过上限，所以窄窗口就用满可用的列。这一列在正文之外两侧各留两格边距，文字不会顶在窗口边缘，表格的边框也不会落进渲染器把最后一格铺满窗口余量的那一列。`[` 和 `]` 手动加减上限，结果夹在 `etaf-md-width-min` 与 `etaf-md-width-max` 之间。窗口缩放走渲染器的视口更新重新流排，不重建文档；预览只发布到一个 buffer，所以缩放不会重启会话。

能用的最窄窗口是「最小宽度加两侧边距」，约 44 列。比这更窄时，缩不下去的块（例如列里必须整词保留的表格）在宽度处被裁掉，不会画到边距上；文字照常折行，版面保持原样。

## 跟随源文件

打开着的预览跟着它的源 buffer 走（真实路径与符号链接都会自动匹配）：改动按 16 ms 帧节拍合并，并在检测到仍有键盘输入等待时主动让出（最多延后 60 ms），连续快打也不卡顿。每个顶层块拥有稳定的槽位与独立的响应式单元，空行折进 `:margin-bottom`，增量片段解析只重排受影响的局部区间——哪怕改第 0 块、顶部插空行、拆段落，或正在输入未闭合的代码围栏（闭合或保存时自动按完整 CommonMark 结算），其余块都保留各自的组件实例、容器交互状态（如 `:::tabs`、`:::details`）、视频句柄与阅读位置。

`M-x etaf-md-open` 默认在当前窗口单窗全宽打开阅读视图，不擅自分屏；按 `q` 切回原缓冲区而不破坏窗口布局。需要边写边看时，在 Markdown 源文档里运行 `M-x etaf-md-preview`（或在预览里按 `v`）即可在源窗口右侧非破坏性地分屏打开实时预览（不关闭其他已有窗格），自动开启按比例同步的滚动跟随并对齐到当前源码行，光标留在源文档；再次执行 `M-x etaf-md-preview` 或在预览按 `q` 即可关闭预览并仅回收它拆出的窗口。`f` 可随时开关滚动跟随（同时覆盖键盘移动与鼠标/触控板滚轮），`e` / `o`（`etaf-md-goto-source`）可从预览直接跳回源文档对应行。

## 定制

十二项设置覆盖外观、工作区安全门禁与磁盘缓存；其余版面细节都由文档和 frame 决定。

| 设置 | 默认值 | 作用 |
| --- | --- | --- |
| `etaf-md-theme` | `auto` | 初始配色；`auto` 从 Emacs 主题的 face 推颜色，不画页面背景。 |
| `etaf-md-flavor` | `nil`（`etaf`） | `etaf-md-create` 没收到 `:flavor` 时用的方言（`etaf`、`gfm`、`commonmark` 或特性 plist）。 |
| `etaf-md-width-min` | `40` | 最窄的阅读宽度，单位是字符格。 |
| `etaf-md-width-max` | `96` | 最宽的阅读宽度；窗口更宽时保持这个值并把这一列居中。 |
| `etaf-md-typeset` | `t` | 通过预编译 QuickJS 原生模块（`M-x etaf-install-native`，借鉴 [LuciusChen/pele.el](https://github.com/LuciusChen/pele.el)），将 `mermaid` 围栏与 `$$` 显示公式渲染为 SVG 图片。 |
| `etaf-md-node-directory` | `~/.emacs.d/etaf-md-nodes` | 存放自定义 `:::` 容器节点 `.el` 定义文件的目录。 |
| `etaf-md-allow-local-read` | `t` | 是否允许只读活文档组件（`include`、`code-ref`、`project-tree`、`git-log`、`git-diff`）在工作区根内读盘。 |
| `etaf-md-allow-actions` | `ask` | 控制可执行 `run` 块策略：`ask` 执行前确认、`t` 直接运行、`nil` 彻底禁用。 |
| `etaf-md-interactive-checkbox` | `t` | 点击或在 GFM 任务复选框上按 `RET` 时，将 `[ ]` / `[x]` 写回源文件。 |
| `etaf-md-media-lightbox` | `auto` | 本地图片激活后是否使用页内灯箱查看（`auto` 图形端启用、`t` 总是启用、`nil` 交给系统打开）。 |
| `etaf-md-remote-images` | `t` | 非 nil 时在挂载的预览中异步下载并缓存远程 HTTP(S) 图片；无界面 `etaf-md-create` 永不发起网络请求。 |
| `etaf-md-cache-max-bytes` | 100 MiB | 图表、二维码与远程图片磁盘缓存的软上限，超限时在空闲时按 LRU 淘汰最久未用的文件。 |

## 脚本与无界面使用

`etaf-md-create` 从文件或者一段文字建会话，不需要 buffer；`etaf-md-view` 返回可挂载的视图；`etaf-md-state` 报告一份分离的快照。从文字建出来的会话就是完整的无界面预览，验收测试用的正是它：

```elisp
(let* ((session (etaf-md-create :text "# 笔记\n\n**加粗** 正文。\n"))
       (buffer (etaf-md-open session)))
  (etaf-md-locate session 0)
  (etaf-md-set-theme session 'sepia)
  (etaf-md-refresh session)
  (with-current-buffer buffer (etaf-md-close)))
```

`etaf-md-open` 接受文件路径或者会话，所以调用方可以渲染自己拼出来的文档。`etaf-md-locate` 把光标移到目录里的第几项；`etaf-md-outline` 返回目录本身。

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

`scripts/etaf-md-gui-probe.el` 驱动一个活的 frame 做 GUI 验证：按指定的 frame 尺寸打开文档，报告一行状态，发送真实按键，并检查版面不变量（没有超宽的行、有可交互的链接、有目录）。

## 排错

- **跳标题跳到了同一个词的别处。** 标题跳转是在行首找到渲染后的标题文字，按目录顺序找。文字相同的两个标题按顺序匹配；如果某个段落恰好也以同样的字在行首开头，可能先匹配到它。
- **图片显示成点阵或者彩色方块网格。** 当前 frame 对这个文件没有可用的图形支持，Ebox 退回了终端转换器；装上 ffmpeg 能让终端渲染好一些，或者换到图形 frame 里看。
- **视频用系统播放器打开，没在原地播。** `exec-path` 上没有 ffmpeg，卡片保留了海报回退。
- **播放完的视频按 `RET` 会从头再来。** 播完的视频没有暂停状态可恢复，下一次按下就是重播；在那之前画布上留着最后一帧，短片可能在下次按键之前就播完了。
- **换主题后共享组件没重画。** 预览只给自己的子树发布配色，外层的应用保持它自己的主题上下文。
- **Mermaid 图表或 `$$` 公式仍显示源码。** 运行 `M-x etaf-install-doctor`（或求值 `(etaf-md-doctor)`）查看 `typeset-native` 是否就绪。执行 `M-x etaf-install-native`（选择 `etaf-md`，或在 `M-x etaf-install-manage` 中按 `n`）即可一键下载校验预编译 QuickJS + Pele + MathJax 原生渲染模块到 `~/.cache/emacs-taf/native/` 并即时生效（无需浏览器、Node.js 或本地编译器，架构借鉴 [LuciusChen/pele.el](https://github.com/LuciusChen/pele.el)）；源码检出开发者仍可用 `make native-build` 本地编译。
