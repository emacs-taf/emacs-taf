# etaf-telega

Emacs 里的 Telegram 客户端：界面用 [ETAF](https://github.com/emacs-taf/etaf) 渲染，
账号、会话与 TDLib 数据库仍由 [Telega](https://github.com/zevlg/telega.el) 持有。
不是 Telega 前端的补丁，也不是终端 Telegram 的包装。

## 能力

- 单 buffer 单页应用：会话列表（顶部过滤器标签：全部 / 重要 / 在线 / 群组 / 频道 / 归档；
  `[` / `]` 或点击、滑动切换）与对话页在同一个
  buffer 里切换，`RET` 进入、`q` 返回，触控板横向双指滑动同样可以返回或切换标签；数据来自
  Telega 的 TDLib 事件。
- 布局与按键沿用 Telega 的根 buffer 和对话 buffer，老用户无需重新学习；Telega 自己的
  会话 / 消息命令（置顶、删除、转发、反应、复制链接……）直接作用在光标处的对象上。
- 现代化外观：宽窗口是 Telegram 式的多栏布局（会话列表右缘可拖动调整宽度），窄窗口是
  Telega 式的单栏；固定在顶部的应用栏与过滤标签，圆形头像，圆角消息气泡；按发送者配色；
  图片 / 视频缩略图 / 贴纸内联显示，日期分隔与引用回复（点击引用可跳到原消息）；暗色 /
  亮色 / 跟随 Emacs 主题三套
  配色。切换标签、选中消息都不会改变行高或宽度，界面不抖动。
- 列表顶部是菜单与圆角搜索框：搜索时可按私聊 / 群组 / 频道筛选，未输入时显示常用联系人
  和最近打开的结果。对话顶部显示标题与成员数，右侧是消息搜索、信息栏开关和更多菜单；
  信息栏（资料、共享媒体、链接）默认隐藏。
- 图片、视频、语音和音频在当前 buffer 的浮层查看器里打开：先显示预览并报告下载进度，
  下载完成后显示原图、播放视频或播放声音（播放 / 暂停、拖动进度、快进快退）；`n` / `p` 翻看
  相邻的媒体，`q` 或点击浮层外关闭。其他附件（文件、贴纸）交给 Telega 打开。
- 表情回应显示在消息下方，点击即可切换；末尾的 `🙂 +` 弹出表情选择网格，按键 `+` 为光标处
  消息添加回应。频道消息与官方客户端一致，不显示头像，全部居左。
- 布局随窗口宽度自适应，没有固定宽度。
- 打开对话停在最新消息与输入框；翻到顶部或 `M-<` 加载更早的历史；新消息、编辑、删除和
  媒体下载完成时保持当前视图。
- 底部多行输入框固定在对话页底部，翻看历史时始终可见；在界面内原地编辑
  （`etaf-text-input`）：输入法、选区、撤销都是原生能力；发送在收到回执后才清空草稿，
  失败时文本保留。消息区的可打印按键不会写入文字。发送前可切换静默、关闭链接预览、
  Markdown 解析与定时发送，选项显示为输入框上方的可点击标签，发送后自动复位。输入框
  左侧的回形针菜单按所选类型发送图片、视频、语音或文件，`C-c C-a` 则按扩展名定类型，
  两者都用草稿作说明；上传进度显示在标题栏，`C-c C-u` 取消。不能发言的频道
  （非管理员的广播频道）不显示输入框，改为提示原因；发送失败保留草稿并显示
  错误，不会留下卡住的上传状态。草稿按会话保存在 Telegram 里，切换会话或
  重新打开都能续写。
- 关闭客户端只停止观察，不注销账号、不删除数据。

## 要求

- Emacs 29.1 或更新版本。
- 核心框架包：`etaf`、`etaf-ui`、`ebox`、`ecss`（通过 `M-x etaf-install` 自动安装，或克隆 [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) 使用其 `packages/` 目录）。
- 真实使用时还需要 `telega` 包与服务端（`telega-server` + TDLib）。安装器会安装
  `telega` 包，但不会编译原生 `telega-server`：先安装 TDLib，再运行
  `M-x telega-server-build`（或按 Telega README 手工构建），把 `telega-server`
  放进 `exec-path`。`M-x etaf-install-doctor` 与 `M-x etaf-install-manage` 的
  `?` 会显示同样的提示。测试与离线演示不需要 Telega：
  `etaf-telega-backend-create-function` 换成假后端即可。

## 安装与运行

<!-- BEGIN:GENERATED:pkg-install-zh:etaf-telega -->
### 通过 ETAF 包归档安装（推荐）

```elisp
(require 'package)
(add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'etaf-install)
(etaf-install-ensure '(etaf-telega))
```

或运行 `M-x etaf-install` 并在菜单中选择 `etaf-telega`。

### 从源码检出安装

全部核心框架包位于 [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf)：

```sh
git clone https://github.com/emacs-taf/etaf.git
git clone https://github.com/emacs-taf/etaf-telega.git
```

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/etaf-telega")
(require 'etaf-telega)
```
<!-- END:GENERATED:pkg-install-zh:etaf-telega -->

使用源码检出时还需将 `telega` 加入 `load-path`，然后运行 `M-x etaf-telega-open`。

`etaf-telega-open` 不会显示 Telega 自己的 buffer，也不会重新登录；它复用
Telega 的 server 与账号数据。首次触达真实账号前先看
[Telega 的环境说明](#真实账号的边界)。

## 嵌入面板或桌面

`etaf-telega-open` 只是其中一种宿主。已经有自己窗口的调用方直接挂同一个 View：

```elisp
(require 'etaf-telega)
(let ((buffer (get-buffer-create "*Telegram*")))
  (etaf-mount buffer (etaf-telega-view (etaf-telega-create)))
  buffer)
```

View 按它所在的区域排版：窗口够宽时是会话列表加对话页，窄窗口自动变成 Telega
式的单栏；桌面窗口和浮动面板各自按自己的宽度重排。挂载时客户端接管这个 buffer，
`etaf-telega-info`、各条命令与按键都作用于这次挂载的会话；窗口关闭或面板收起时
后端停止观察，模型保留会话状态，再次挂载接着用。调色板切换只让这个 View 重画，
不会重新挂载宿主的 buffer。

挂进 `etaf-posframe` 的浮动面板时，客户端把调色板、模式格和 `亮` / `随` / `暗`
三档标签声明给面板：面板标题栏的切换和 `T` 写同一个状态，点 `亮` 后连消息区一起
重画，不会只换掉面板边框和标题栏。

## 按键

按键作用于光标所在的窗格：会话列表、对话页或对话信息栏。打开或离开会话时光标随之进入对应窗格；分栏布局下把光标移到另一个窗格即切换过去。`Tab` / `S-Tab` 和方向键可以走到每个按钮、标签和菜单，`RET` 或空格按下，`Esc` 关闭弹出层。

导航时按 `?`（或点标题栏的 ⓘ 按钮、菜单里的“键盘快捷键”），在当前应用 buffer
内打开只读帮助，不拆 Emacs 窗口。内容来自当前位置实际生效的绑定；`/` 搜索，
Escape 先退出搜索编辑、再关闭帮助，点击框外遮罩也会关闭并恢复焦点。宽窗双栏、
窄窗单栏滚动，跟随深浅主题。查看帮助不会执行条目；要按名字执行命令，用
`M-x etaf-palette` 打开独立的命令面板。

会话列表：

| 按键 | 作用 |
|---|---|
| `n` / `p` | 下一个 / 上一个会话 |
| `j` | 按名字跳会话（已知会话与联系人） |
| `C-c g u` | 跳到下一个未读会话 |
| `[` / `]` | 上一个 / 下一个过滤器标签 |
| `RET` | 打开光标处的会话 |
| `i` `a` `o` `r` `d` `P` `^` `M` `A` `L` `DEL` | Telega 的会话命令：资料、加成员、操作菜单、已读切换、删除、置顶、静音、归档、离开 |
| `/` 或 `s` | 搜索会话；`RET` 打开第一个结果，`Esc` 退出搜索 |
| `J` / `N` | Telega 的通过链接加入、新建会话 |
| `T` | 切换暗色 / 亮色主题 |
| `?` | 只读快捷键帮助（标题栏的 ⓘ 同） |
| `q` / `Q` | 隐藏 / 关闭客户端 |

对话页：

| 按键 | 作用 |
|---|---|
| `n` / `p` | 选中下一条 / 上一条消息；越过最新一条回到输入框 |
| `>` / `M->` | 跳到最新消息 |
| `M-<` | 加载更早的历史 |
| `C-c g q` / `C-c g p` / `C-c g d` | 跳到被引消息 / 置顶消息 / 指定日期（也可点击引用） |
| `C-c g u` / `C-c g m` / `C-c g o` | 下一条未读 / 提及 / 自己发送的消息 |
| `RET` | 在查看器里打开光标处消息的图片 / 视频 / 语音 / 音频，其他位置开始输入 |
| `+` | 为光标处的消息添加或取消表情回应 |
| 查看器 `n` / `p` / `q` | 下一个 / 上一个媒体、关闭查看器 |
| `i` | 进入底部输入框 |
| `j` | 按名字跳到另一个会话 |
| `r` / `e` | 回复 / 编辑光标处的消息 |
| `c` `d` `f` `l` `s` `t` `!` `^` `*` `T` `=` `B` `R` `o` `I` | Telega 的消息命令：复制、删除、转发、链接、保存、翻译、反应、置顶、收藏、话题、编辑记录、封禁、重发、操作菜单、详情 |
| `g` | 重新载入最新历史 |
| `/` | 在已载入的消息里搜索 |
| `C-c i` | 显示 / 隐藏对话信息栏 |
| `?` | 只读快捷键帮助（标题栏的 ⓘ 同） |
| `q` / `Q` | 返回会话列表 / 关闭客户端 |
| 输入框 `RET` | 发送；`S-RET` / `C-j` 换行 |
| 输入框 `M-p` / `M-n` | 上一条 / 下一条已发送文本 |
| 输入框 `C-c C-s` / `C-c C-l` / `C-c C-m` | 静默发送 / 关闭链接预览 / 按 Markdown 解析 |
| 输入框 `C-c C-t` | 定时发送（留空取消） |
| 输入框 `C-c C-d` | 放弃草稿 |
| `C-c C-a` / `C-c C-u` | 发送附件（按扩展名定类型）/ 取消正在上传的文件 |
| 输入框左侧回形针 | 按所选类型发送图片 / 视频 / 语音 / 文件（与 `C-c C-a` 同样用草稿作说明） |
| 输入框 `@` / `#` | 输入时自动弹出成员 / 标签补全，`C-n` / `C-p` 选，`RET` / `C-c C-j` 插入 |
| 输入框 `C-c C-e` / `C-c C-p` | 表情选择器 / 贴纸选择器（`RET` 插入或发送） |
| 输入框 `Esc`、`C-c C-k` | 离开输入框并保留草稿；回复或编辑时取消并还原原草稿 |

## 开发

```sh
make check     # 结构 + 字节编译 + 验收场景
make test      # 只跑验收场景
make clean
```

验收场景全部走假后端，不连网络、不需要 Telega。真实账号验证必须显式指定
隔离的数据目录，并先停掉其他占用该目录的 TDLib 实例。

界面改动必须真实 GUI 验收；清单与做法见 `pi-skill etaf-app-dev guide verify`。

## 真实账号的边界

- TDLib 同一数据目录只允许一个实例拥有。客户端关闭不等于注销。
- 升级或迁移前停服并备份完整目录（含 WAL），不要拿唯一的生产登录库做实验。
- 本仓库不复制消息数据库；界面所需的状态只在内存里投影。
- 独立 GUI 实例共享同一数据目录时，收尾要先关上一个实例，再开下一个（两个 TDLib 同时在线有损坏风险）。

真机验收时踩过的 Telega/TDLib 事实（不要再当作 bug 重查）：

- **发附件**：`sendMessage` 的回调返回的是本地消息（id 与最终消息不同），而 Telega 只在**确认后**
  才触发 `telega-chat-post-message-hook`。回调里上报 `:sent` 会让每条附件显示两遍；正确做法是回调只记录
  上传（供取消用），确认从钩子里按文件名匹配后上报。
- **语音**：`inputMessageVoiceNote` 的 `:voice_note` 必须是 `inputVoiceNote{voice_note,duration,waveform}`
  对象，不能直接放 `inputFileLocal`——后者让 TDLib 回 `400 InputFile is not specified`，界面上表现为
  永远停在「正在上传」；`duration` 要为正（本仓库用 ffprobe 取，取不到就回退 1 秒）。
- **置顶**：TDLib 只发 `updateMessageIsPinned`，本版 Telega 不更新会话缓存里的 `pinned_message_id`，
  所以会话内新置顶后要经 `searchMessagesFilterPinned` 现查，不能信缓存。
- **已读**：打开会话会把加载的那一页标为已读（`telega--viewMessages`），手动标为未读的会话
  （`unread_count>0` 但读边界已在最新）用 `C-c g u` 会正确地报「没有未读」。
- **清理测试数据**：媒体消息没有文本，服务端搜索按文本找会漏；按「日期 = 今天且 outgoing」的媒体
  消息删除（或按模型里的 `:file :name` 匹配）才能清干净。
