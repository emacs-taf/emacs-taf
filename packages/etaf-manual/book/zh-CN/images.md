# 图像

图像只有先经过准备才会到达屏幕。准备阶段读取来源、运行转换器或建立并解码 Emacs 图像描述符，返回一块不可变字符栅格。布局与写 buffer 复用栅格，不做来源 I/O 或启动子进程；绘制可从内存中已有的字节派生并缓存原生背景或亮度合成。本章描述准备步骤、应用可以扩展的转换器协议、图形 frame 与字符单元格回退之间的差异、让重复准备保持廉价的那份缓存,以及图形 adapter 所围绕的「一行一个字形」不变式。[文本](text.md)描述图像节点旁边的字符内容;[Hosts](hosts.md)中的 image Host 为应用包装这套模型,`ebox-node-set-image` 就地替换准备好的图像。

## 准备

<!-- index: 图像准备; prepared 值; 来源; adapter; inset -->

`ebox-image-prepare` 是图像模型唯一的 I/O 边界。它的 SOURCE 是本地文件名——展开后以 truename、大小、修改时间与 inode 构成缓存身份——或携带 `:file` 或 `:data` 的 Emacs 图像描述符。远程文件在读取前就被拒绝。COLUMNS 与 ROWS 是图像必须填满的字符区域，adapter 的选择决定先尝试哪条路径：`auto` 先试图形描述符，再试转换器列表，最后是单色占位；`text` 跳过图形路径；`placeholder` 两者都跳过。

#### Function: ebox-image-prepare (source columns rows &key (adapter 'auto) (frame (selected-frame)) inset (converters ebox-image-converters))

把 SOURCE 准备成一个 COLUMNS×ROWS 字符区域的图像。

**参数。** SOURCE 是本地文件或含 `:file` 或 `:data` 的 Emacs 图像描述符。COLUMNS 与 ROWS 是正整数。ADAPTER 是 `auto`、`text` 或 `placeholder`。FRAME 提供图形桌面所用的字体度量。CONVERTERS 遵守 `ebox-image-converters`。INSET 是 nil 或 `(TOP . BOTTOM)`，表示图形图像在它的行内上下各留空多少像素（每边不超过一行高）。

**语义。** 调用会读取并解码所有需要的内容，返回一个 detached 值；此后布局与写 buffer 不再接触来源。`auto` 下，图形 frame 且有可用的字体度量与图片类型时产出基于切片的描述符；否则按顺序尝试转换器；全部拒绝时产出单色占位栅格。图片缺失或损坏最终落到占位而不是报错。完全相同的准备由缓存回答。

**返回。** 供图像节点、`ebox-image-info` 与 `ebox-image-content` 使用的不透明可复用值。

**错误。** COLUMNS 或 ROWS 非正、ADAPTER 未知、INSET 畸形、转换器列表不是符号与函数对组成的 alist，或 SOURCE 既不是本地文件也不是合法描述符时，在读取任何内容之前报错。

**示例。** `(ebox-image-prepare "cover.png" 24 12 :adapter 'placeholder)` 返回一块 24×12 的点阵，供不依赖显示能力的布局使用。

**参见。** `ebox-image-info`、`ebox-image-content`、`ebox-image-cache-clear`。

## 转换器协议

<!-- index: 图像转换器; 半块字符; truecolor; 转换器协议 -->

转换器把一个来源变成 truecolor 半块字符栅格。它只在准备阶段被调用，且不得修改来源。内置列表先试 `chafa`——按请求尺寸索要 truecolor 的 `▀` 符号——再试 `ffmpeg`，后者把来源缩放到两倍行数，把每对 RGB 像素打包进一个单元格的前景与背景。两个程序都不是包依赖；都没安装或都拒绝时，准备落到占位。应用可以用自己的转换器扩展列表；抛错或返回畸形栅格的转换器会降级到下一个，所以实验性转换器不会破坏渲染。

#### Variable: ebox-image-converters

有序的 （NAME . FUNCTION） 图像转换器列表，只在准备阶段调用。

**语义。** FUNCTION 接收 SOURCE、COLUMNS 与 ROWS，返回 nil 表示拒绝，或返回恰好 ROWS 行、每行 COLUMNS 个 `▀` 字符的字符串，每个字符带 `face` plist，含形如 `#RRGGBB` 的 24-bit `:foreground` 与 `:background`，末尾无换行。其它任何结果（包括抛错）都表示拒绝。结果中只复制两个颜色；转换器无法把 display 规范、keymap 或节点所有权注入 prepared 值。转换器行为变化时改它的 NAME 或清空图像缓存，因为缓存键保存的是当时的整个列表。

**示例。** 返回合法 3×2 栅格的转换器被接受为 `(:adapter text :converter ok :columns 3 :rows 2)`；同一个列表前头放上字符错误的、颜色非 `#RRGGBB` 的、抛错的与返回 nil 的转换器之后，仍然落到能工作的那个。

**参见。** `ebox-image-prepare`。

## 图形、文本与占位 adapter

<!-- index: 图形 adapter; 文本 adapter; 占位; 透明 -->

在图形 frame 上，`graphics` adapter 建立一个 Emacs 图像描述符，缩放到 COLUMNS 乘 frame 字符宽、ROWS 乘行高的尺寸，在准备阶段就解码它——在块发布之前预热 Emacs 自己的图片缓存——并把每一行表示为一个空格字形，携带该描述符的一条水平切片。在单元格为 7×14 像素的 frame 上，4×2 的图片变成两个字形：第一个显示描述符 y 0 到 y 14 的像素，第二个显示 y 14 到 y 28。INSET 按请求的像素缩小切片高度并在行内抬起切片，图像因此保持行高，上下空出的位置显示盒背景；同一张图片用单像素 inset 时切片高 13 像素。

在终端里、或使用 `:adapter text` 时，同一次 prepare 产出字符栅格：每个单元格是一个 `▀` 半块字符，face 携带它所代表的源图两行像素的平均颜色。从布局的角度看栅格是纯文本——段落或图像节点把它当作若干列字符——终端因此得到一个可读但粗糙的呈现。占位 adapter 产出同样形状的栅格，字符为 `.` 且不带 face；图形与转换器都不可用时，布局或测试看到的就是它。

图形图像的透明像素显示所在盒子的背景，在绘制时合成。正因如此，同一张来源图放在带色行上不会露出 frame 色的角。带滤镜的浮层走共享的 [`:backdrop-filter`](style-properties.md#style-backdrop-filter) 图像路径，不会重新准备来源、用纯色覆盖代替图画或改变切片几何。

**示例。** 在单元格为 7×14 像素、ascent 79% 的 frame 上，准备一张 4×2 的 PNG 得到 `(:adapter graphics :converter nil :columns 4 :rows 2)`，两行各一个字形，第一行 display 为 `(slice 0 0 28 14)`，第二行为 `(slice 0 14 28 14)`——28 像素等于四格宽。没有图形 frame 时同一次调用的回退栅格每行四个字符。

## 缓存与信息查询

<!-- index: 图像缓存; prepared 值; 缓存淘汰 -->

准备结果按来源身份、尺寸、adapter、frame 度量、inset 与转换器列表缓存。缓存有界，超过 256 条时丢弃最久未用的条目，所以屏幕上图片很多时不会一次淘汰掉所有无关的准备结果。已生效的 prepared 值被淘汰后仍可继续使用——它是 detached 且不可变的——但同一来源的下一次准备会重建栅格。

亮度合成另用弱身份缓存，每个存活的图像或 display 最多保留八份近期变体。键包含亮度、原生前景、滤镜后的背景与 frame。首次变体建立内存 SVG 描述符，由原生 redisplay 解码；此后绘制在所有行切片之间共享该描述符。新来源、调色板或亮度使用各自的变体，恒等滤镜直接使用原描述符。缓存不持有输入回调或已挂载的树。

#### Function: ebox-image-content (prepared)

返回 PREPARED 的 owned 字符串，不做任何 I/O。

**参数。** PREPARED 是 `ebox-image-prepare` 返回的值。

**语义。** 返回的字符串是浅拷贝：字符与 face 是新的，而图形行的嵌套 display 描述符与切片值是共享的。行以换行分隔，因此图像节点的每行对应一条。不要修改嵌套的 display 值。

**返回。** 栅格字符串。

**错误。** 传入的不是准备结果时报错。

**参见。** `ebox-image-prepare`、`ebox-image-info`。

#### Function: ebox-image-info (prepared)

以新 plist 返回 PREPARED 的 adapter、converter、columns 与 rows。

**参数。** PREPARED 是 `ebox-image-prepare` 返回的值。

**语义。** plist 的键为 `:adapter`（`graphics`、`text` 或 `placeholder`）、`:converter`（产出文本栅格的转换器名，没有则为 nil）、`:columns` 与 `:rows`。值是新构造的，调用方可以保存或修改。

**返回。** 该 plist。

**错误。** 传入的不是准备结果时报错。

**参见。** `ebox-image-prepare`、`ebox-image-content`。

#### Function: ebox-image-cache-clear ()

释放缓存的准备结果与绘制合成，不影响已生效的图像。

**语义。** 清空缓存不会触碰任何已经被节点持有的 prepared 值或已绘制描述符，但相同参数的下一次 `ebox-image-prepare` 会重新准备，后续滤镜也会重建合成。安装或重新配置转换器之后、或字体与显示能力变化使缓存度量过时时调用它。

**返回。** 复位后的访问计数 0；调用方依赖的是清空这一效果。

**参见。** `ebox-image-converters`。

## 一行一个字形

<!-- index: 图像不变式; 一行一个字形; 图像节点 -->

图形 adapter 的核心不变式是：图像的一行就是一个字形。准备栅格的每一行是单个字符，其 display 规范携带整条宽度的切片，redisplay 因此一步画出整行；若设计成每格一个切片，每次重绘与滚动的成本都会乘以列数。这一不变式解释了为什么图形图像的行数永远恰好是 ROWS、横向尺寸永远是 COLUMNS 乘单元格宽，以及为什么 `:inset` 用更短的切片加位移实现，而不是增加像素或行数。

图像节点就按这些行布局：`ebox-node-create` 建立 `image` 节点、把 prepared 值放在 `:image` 属性下，得到的条目高度等于行数、宽度等于准备结果中最宽的行的像素宽。被拉伸的图像盒用背景填满多余的水平空间，栅格从不重排——改变容器尺寸不会重新准备图像。要就地更换图像，准备新值并调用 `ebox-node-set-image`；节点保留自己的位置，由 flush 重绘。

## 错误与恢复

<!-- index: 图像错误; 缺失图片; 转换器失败 -->

参数类错误——COLUMNS 或 ROWS 非正、adapter 未知、inset 畸形、转换器列表非法、来源为远程或不是文件——在准备阶段、任何 I/O 之前暴露，消息列在 `ebox-image-prepare` 的条目下。这些是编程错误，不是数据条件。

读不到、解码不了或转换不了的来源在设计上不是错误。图形路径退出、转换器退出、占位栅格顶上，布局永远不会因为图片缺失而失败；`ebox-image-info` 会告诉应用实际产出内容的是哪个 adapter，应用可以据此为占位显示另一条信息。安装新转换器后清空缓存才会对新的准备生效；基于同样的原因，行为变化了的转换器应当换个名字。
