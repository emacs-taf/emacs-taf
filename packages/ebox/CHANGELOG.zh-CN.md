# 变更日志

Ebox 的重要变化记录在这里。

## 未发布

### 修复

- 挂载缓冲区重绘后恢复窗口起点时始终对齐到行首（列 0），不再延续行中列偏移，避免截断行丢失首行前置留白（如容器左内边距）。

### 变更

- `:font-size` 改成相对正文的比例，不再是像素字号。样式里写 `1.42` 就是标题、`0.85` 就是说明文字，Ebox 用当前默认字体换算成 face 高度。旧的像素字号假设 96 DPI，每次使用都要换算一遍，同一份文档在两种平台上就长得不一样，每个应用也都留着一份换算。

### 新增

- `ebox-keymap-create` 接受 `:drag-edge`：已经移动过的拖拽停在窗口边缘带时，按节奏收到 `edge` 阶段，`:edges` 给出贴住的边缘。跟踪器只报告意图，滚动由回调负责。`ebox-drag-edge-band` 与 `ebox-drag-edge-interval` 控制边缘带与节奏，手势协议记录在入口 Commentary 中。

### 修复

- 放大字号的 face 里，中文和拉丁一样高。face 的行盒原先只量拉丁 `"0"`，标题里的中文字体被当成超高的回退字形，整段被压回正文字号。行盒现在按 face 量正文所用的中西文字体，与默认 face 同一套判据。

- 被压缩的字形从自己的字号缩。`height` display 因子是相对默认 face 的倍数，标题只要轻微压一下就掉到正文字号；现在这个因子带上 face 自己的高度。

- 指针 hover 在自己所在的 frame 内跟随指针。守卫原先拿相对整个显示器的指针位置去减窗口报告的绝对边缘，但子 frame 可能相对父 frame 摆放，而它报告的绝对边缘不含那段原点；挂载的面板因此高亮指针下面几行（常见是三行），移动时还会在这几行和指针所指行之间来回闪烁。

- 中文等 CJK 文字不再被缩小。行高原先只按拉丁字体量，行框更高的中文字体会被当成回退字形缩到 0.8 倍，中文因此比拉丁文字小，换行也更挤。现在行高取 face 的正文字体（拉丁与中日韩）中最大的一个，每一行都正好一行高，所以中文字体更高时行变高，字不变小。

- 行高占位符改到行首，不再放在行末。只含较矮字形的行仍按行高显示；行宽顶到窗口右边界时占位符也不会在截断边界丢掉。buffer 文本在每行开头带这个载体，复制时会带上它。

- 指针 hover 不再在挂载 buffer 里设置 `track-mouse`。画出的 `help-echo` 探针负责进入时的绘制，随后一个短的指针守卫跟着指针，直到没有反馈可画再恢复；指针移到别的窗口上不会在这里执行命令，全局的点击波纹钩子不会每次移动都画波纹。探针同时保留每段原有的帮助内容。

- 拖拽中按 Escape 以 `quit` 取消，并且这次 Escape 被消费。此前它会被退回命令循环，仍按住的按钮随后释放，把两件事拼成未定义的 `ESC <drag-mouse-1>` 序列并响铃。

- 终端 frame 用盒线字符绘制边框：左右边框是细线而不是整格色条，空白的上/下边框行画成同宽的 `┌──┐` / `└──┘` 框；有内容的行仍用装饰线。

- 终端只有一个字号，提高字号的节点改用粗体渲染，子节点按字重继承；根节点改变字号属于应用的全局选择，不加粗。

- 原生 hover 面先复述节点自己的绘制，再叠加 `:hover-style`，所以「只给一个填充色」的 hover 样式不会丢掉标签的墨色、字重与装饰。指针压在节点上时 Emacs 用 `mouse-face` **替代**文本的 `face`，只按 hover 声明造面会让文字回落到 frame 默认前景，深色填充上出现读不清的黑字。

- Emacs 29 和 30 的文本测量使用继承缓冲区显示设置的独立工作缓冲区；字体缩放与默认文本属性仍生效，不依赖 Emacs 31 才提供的测量参数。

- 纯文本 Emacs 构建不再因可选原生图像、字体调用而出现未声明函数警告；未挂载 Ebox 的缓冲区上的滚轮事件使用已加载的标准鼠标滚轮库处理。

- 遮罩更新只过滤实际显示的背景片段，在同一个独立副本上赋予覆盖层的输入身份，减少模态搜索和编辑过程中的临时分配，不改变颜色与命中隔离。
- 支持 SVG 的图形 frame 上，遮罩现在会压暗 PNG、JPEG 和 SVG，包括使用原生 `currentColor` 的图标。缓存的内存合成保留透明度、切片、行内留白和应用调色板，不重新读取来源或执行外部转换；其它原生格式保持可见，但不改变图像像素。
- 同一个浮层移除后重新挂到相同坐标，也会正确重绘，不再遗留未遮挡的背景。
- 一次局部更新同时移动多行并改变页面高度时，不再留下被腾空的旧行。原先每个改动节点按它现在所在的行记录，编辑却仍作用在旧页面上：关掉一块高的折叠再打开另一块，被移动那一行的旧标题就留在下一块下面。这类更新改为整页重写，只改一个节点时仍走行级编辑。

### 新增

- `ebox-focus-edge` 接受可选子树根，把 Home/End 式焦点移动及参与的焦点组限制在调用方指定的边界内。

- 键盘焦点支持复合控件：`:focus-group`（`vertical`、`horizontal` 或 `grid`）使容器成为一个 Tab 停靠点，进入时落在选中或上次聚焦的成员上，并用方向键在内部移动；`:focus-scope modal` 把导航限制在打开的对话框内；`ebox-focus-direction` 移到某方向上最近的停靠点；`ebox-focus-scope` 和 `ebox-focus-stops` 公开当前作用域；`ebox-focus-change-functions` 报告每次焦点移动。

- 图形 frame 上的盒子背景支持 `:border-radius`；块方向 padding 接受行高的分数，例如 `(lh 0.5)`，背景会覆盖该行的相应部分，而每行仍保持一个行高。
- `ebox-image-prepare` 接受 `:inset (TOP . BOTTOM)`，在图形图像上方和下方留出几像素空白，而不改变图像占用的行。
- 在 macOS 上，彩色 emoji 显示为整行高度的图像，由一个用 `swiftc` 编译的辅助程序渲染，并缓存在 `user-emacs-directory` 下的 `ebox-emoji/` 中。
- 软换行不再让闭合标点出现在行首，也不再让开启标点出现在行尾。
- `ebox-input-begin` 接受 `:on-change`、`:on-leave`、`:keymap` 与 `:local-variables`；`ebox-input-edit-commands` 列出 keymap 中会编辑值的命令。
- 样式 `:scroll-anchor end` 让滚动容器在内容变化时固定在最后一行，直到用户滚离，适用于日志和聊天视图。
- `ebox-node-scroll-into-view` 滚动外层滚动容器，使节点可见。
- 交互属性 `:swipe` 在节点上每次水平双指触控板手势时收到一次 `left` 或 `right` 调用，惯性滚动会被吸收。
- 交互属性 `:scroll` 在滚动改变滚动容器的行偏移时收到新的行偏移，便于列表在边缘加载更多行。
- `ebox-node-scroll-into-view` 接受可选的 `start` 或 `end` 对齐方式。
- `ebox-viewport-measure` 在 buffer 挂载之前返回其挂载将占用的 viewport。
- `ebox-viewport-change-functions` 在已挂载 buffer 的 viewport 尺寸变化且新布局稳定后，以该 buffer 运行。
- `make native` 会字节编译 Ebox，并把 native code 存入用户的 `eln-cache`，Emacs 会加载它来代替字节码。

### 变更

- **BREAKING：** Ebox 现在暴露可变 retained-node engine。使用 `ebox-build`、`ebox-node-create` 或 `ebox-text-create` 构建 root；使用 `ebox-mount` 挂载；然后通过节点 mutation 函数更新已有树。flush 会对 dirty paths 重新计算样式、重新布局和重绘，并且只重写变化的 buffer 行或行内片段。
- 当编译后的 `.ebox` 伴随文件的字节码比 `.el` 源文件新时，`ebox-file-load-companion` 会加载它；已编辑的源文件仍直接加载。
- 输入会话不再让已绘制文本变为可写，也不再推迟挂载的 flush。它在隐藏 buffer 中用原生命令、undo 和输入法编辑节点的值，同时节点保留其 padding、边框和换行，并随值增长。在节点内单击、拖动、双击和三击都会编辑该值，输入法的预编辑文本会在节点内换行，而不会溢出节点。
- 没有锚点的 `:layer root` 绝对定位盒子改为依据 root 的 border box 而非 content box 确定位置和尺寸，因此全尺寸的遮罩或查看器会覆盖 root 的 padding。

### 删除

- 包内手册 `docs/manual.md` 由 [ETAF 参考手册](https://etaf.top/zh-cn/ebox-node-construction/) 取代，README 与包入口 Commentary 改为链接手册；`docs/architecture.md` 仍是维护者契约。

- **BREAKING：** 删除上一代 engine 的 canonical inputs、source builders、surfaces、publications、transactions、prepared update/geometry API、generation/candidate 模型、layer module、native Rust layout module、framework SPI 与 render-burst 接口。迁移高层调用方时，改为保留 Ebox 节点引用而不是外部 handle：旧的完整 input replacement 对应构建或复制 retained root 并挂载；旧的 source-builder child update 对应 `ebox-node-insert`、`ebox-node-remove`、`ebox-node-move` 或 `ebox-node-replace-children`；旧的 content/property/selector update 对应 `ebox-node-set-text`、`ebox-node-set-image`、`ebox-node-set-props`、`ebox-node-put`、`ebox-node-set-states` 或 `ebox-node-restyle`；旧的显式 update grouping 对应 `ebox-with-batch`。

### 修复

- 空白恒等滤镜热区的边缘穿过文字时保留完整字形，不再把部分字形替换为空格。原生文字输入按整个字形归属，图像与空白仍精确到像素切片。

- 指针悬停改为按节点自身的计算样式重绘整个节点，不再只画一条矩形文本带：悬停的控件保留 `:border-radius`，并覆盖全部内边距行；指针离开后在同样的行上恢复静止样式。

- 叠放布局中超宽子项的绘制先裁剪到父级内容宽，再参与浮层合成。移动或调整重叠窗口时，隐藏内容不再撑宽画布、挤偏相邻窗口或造成图像横条错位；子项的固有尺寸保持不变。
- 原生整行图像与已有图像切片都支持部分遮挡裁剪，并保留基线修饰。窗口只盖住图像行的一部分时，未被遮挡的其余部分不再整行消失。

- Buffer 文本缩放后 mounted tree 保持对齐：缩放稳定后清空共享字形缓存并整棵重新布局，滚轮缩放已挂载应用不再按上一档度量把行切开。

- 从按钮开始原生输入时，启动手势的鼠标松开不再被误判为离开文本区、立即结束会话；字段内嵌控件除非显式结束编辑，否则保留会话，后续点击外部仍正常触发离开回调。

- 挂载期间禁用 Emacs 原生续行，避免对已排版行二次折行、在右侧留下续行列色条；卸载时恢复 buffer 原有的折行设置。
- 固定高度 flex 容器中的文字增减不再误插或误删外部 buffer 行；多行原生输入、清空和撤销保留后续内容，包括独立更新的动画页脚。

- 双指横向手势反向时立即开始并触发下一次滑动，连续左右划每一下都能生效，不必等惯性滚动结束。
- 被宿主裁剪的交互 overlay 在空白行以及在裁剪边缘被截断的 padding 上保留其 keymap、指针和帮助信息，因此在这些位置的点击能到达它。
- 图形图像的透明像素显示承载它的盒子背景，而不是 frame 背景，因此圆形头像能融入高亮行。
- 在图形 frame 上，回退字体比行更高的字形（例如彩色 emoji、符号、数学字母和其他回退文字）会缩放以适应其所在行。每行保持一个行高，因此旁边的图像切片（例如头像）保持衔接。
- 在输入会话之外，于已挂载 canvas 中按下可打印按键不再向应用 buffer 插入文本。
- 节点的边界包含其自身绝对定位子节点下的单元格，例如范围控件的填充部分。
- 对 padding 或 gap 单元格调用 `ebox-node-at` 时返回拥有该单元格的最内层盒子，而不是 root。
- 对滚动容器内的空白或 padding 单元格调用 `ebox-node-at` 时返回该单元格下的最内层盒子，而不是滚动容器。
- 图形图像每行只绘制一个切片字形，而不是每个单元格一个，因此滚动和重绘包含大量图像的视图不再卡顿；在盒子或 overlay 边缘被截断的图像行保留其可见部分。
- 滚过滚动容器末尾时，不再滚动已经显示整个 buffer 的窗口，因此固定的页眉和页脚保持原位。
- `ebox-buffer-mode` 在已挂载 buffer 中关闭 `show-paren-mode`，并在该模式禁用时恢复，因此绘制的文本不会显示括号匹配或不匹配高亮。
- 比拉伸后盒子更窄的图像会在其旁边绘制盒子背景，因此较宽气泡中的照片不会留下未绘制的空隙。
- 在没有右侧 fringe 的窗口中，已挂载 viewport 在截断列之前结束，因此全宽行不再显示 Emacs 的 `$` 字形。
- 已挂载 buffer 显示在另一尺寸的窗口中时，即使没有任何窗口缩放，也会重新适配该窗口。
- 宽于其盒子的内容在盒子边缘被截断，因此同一行中后续兄弟节点保持原有列位置，不再向右偏移。
- 内容填充原本为空的已挂载 buffer 时，point 和窗口起始位置保持在顶部，因此应用打开时不再滚动到 buffer 末尾。
- 已挂载 buffer 的默认背景跟随 root 的背景色，因此最后一行下方的不完整行以及布局文本之外的其他空间与应用表面一致；卸载时会移除该重映射。
