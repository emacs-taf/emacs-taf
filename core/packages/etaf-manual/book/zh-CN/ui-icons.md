# 图标

图标是占据标准文本行、不打扰周围布局的小型非文字标记。目录从*注册表*绘制图标：一个集把 `play` 这样的符号名映射到字体字形或 SVG 内容，组件按显式集、默认集与内置回退依次解析名字，最后实在无解才把名字本身当文本显示。本章定义注册表及其生命周期、解析顺序、图标与切换图标两个组件、用于保留更新的文本变体、判断某个集是否适配标准行的度量查询，以及用来组合场景的 SVG 元素辅助。目录的共同契约见 [UI 组件库总论](ui-overview.md)，图标 Host 使用的盒子属性见 [Host](hosts.md)，组合出的场景由哪个图像 Host 渲染见[图片](images.md)。

## 注册表

<!-- index: icon set; icon glyph; SVG icon; fallback; registry order -->

图标集是注册表数据，不是新的元素类型。内置六个集：`nerd`、`fa`、`material`、`octicons` 与 `sys` 绘制字体字形，`svg` 绘制矢量路径。`etaf-ui-icon-sets` 按注册顺序返回它们，每个集有一份规格对象。

字体规格需要字体族名、相对标准行的字号比例，以及符号名到单字符的映射；字体缺失或字体没有该字形的集无法提供这个名字，解析会继续往下走。SVG 规格需要 viewbox，以及路径内容或零参绘制函数，另有一个默认内边距让图形不贴盒子边缘。两种集都可以为终端 frame 以及字体画不出的名字提供可打印 ASCII 回退。

注册是原子的，替换即版本更新：注册一个已存在的名字会整条替换它的规格，任何校验失败都不改变注册表，而成功变更会让缓存的字体、face 与图像失效，下一次渲染解析新数据。已挂载表面的值在下次渲染前保持有效；注册表变化本身从不重渲染已挂载组件。

## 解析一个名字

<!-- index: resolution order; default set; missing glyph; plain-text fallback -->

解析沿着一条固定的候选链：显式请求的集，然后是 `etaf-ui-icon-default-set`，然后是 `sys`，然后是 `svg`，最后是名字本身。在文本终端上，对 `svg` 集的请求先经过注册的 `tty` 集，因为终端根本画不出矢量图；该集没有覆盖的名字再回到请求的集和后面的候选链。字体集请求仍以请求的集为先，`tty` 排在它之后。候选只有在既包含该名字、又真能画出它时才算数：字体族缺失、或字体没有该字符的字体集会被跳过，因此只提供部分名字的集会落到下一个候选而不是失败。所有候选都不合格时，名字本身作为文本显示，控制字符与非 ASCII 字符会被转义，避免隐藏的名字破坏显示。

显式请求的集必须已注册；未知的集是用法错误而不是继续回退的理由，因为调用方明确要了它。默认集是偏好而不是覆盖：它在显式集之后参与，把未注册的名字设为默认会让每次解析都失败，即使显式集本身有效。

在支持 SVG 的图形 frame 上，字体字形也画成与矢量集相同的方形画布里的 SVG text，因此超出字体声明 ascent 与 descent 的 ink 不会被行裁剪。没有 SVG 时，字体集回退为夹紧过的具名 face 文本，两行图标把文本变体放在第一行，并保留第二行。

## 绘制尺寸与行

<!-- index: icon size; clamped size; two-row icon; image slice; min-width -->

图标默认保留一个标准行，请求两行时恰好保留两行。尺寸按比例缩放绘制盒，但被夹紧在保留的像素高度内，所以再大的缩放值也撑不大行。行永远来自标准行高，而不是字形自身的度量；声明度量超过行高的集仍然可以安全绘制，度量查询会如实报告未夹紧的声明不适配。

两行图标用同一张方形画布的两条切片；一行图标用整张画布。图标 Host 保持 `max-content` 宽、以字符列计的最小宽与隐藏溢出，并在每行居中绘制。最小宽避免窄字形——单个字符或小矢量——把点击目标缩到不可用。

只有像素级颜色会到达绘制：组件从颜色与 face 两个 prop 取前景和背景，忽略其余 face 属性，因为调用方的排版不能改变图标的行度量。矢量场景通过 `currentColor` 使用前景色，所以主题色能流进使用它的路径填充。

## 图标组件

<!-- index: etaf-ui-icon; pressable icon; accessible icon name -->

#### Component: etaf-ui-icon (&key name set size color face lines min-width help-echo on-press tab-index aria-label id class ref)

在一个或两个标准行里渲染一个语义图标。

**参数。** NAME 是命名图标的非空符号或字符串。SET 是显式请求的集；未知集是用法错误。SIZE 是缩放绘制的正数，被夹紧在保留的行内，默认 1.0。COLOR 是覆盖图标前景的像素颜色；FACE 是 face 名或 plist，只取其中的前景与背景，其余属性忽略。LINES 是 1 或 2，默认 1。MIN-WIDTH 是正整数个字符列（默认 2）。HELP-ECHO 是作为原生帮助绘制的字符串。ON-PRESS 是整个盒子的零参回调。TAB-INDEX 是可按压时图标的 Tab 序号，默认 0。ARIA-LABEL 是可访问名，默认依次取字符串 HELP-ECHO、NAME。ID、CLASS 与 REF 到达渲染出的 Host。

**语义。** 名字按[解析一个名字](#解析一个名字)所述解析，并按[绘制尺寸与行](#绘制尺寸与行)所述绘制。可按压图标带 `:on-press` 时是一个 Tab 停靠点；负 TAB-INDEX 让它仍可点击但不进 Tab 顺序，例如外层列表已经拥有键盘时。整个盒子都是按压目标，包括两行图标的第二行。省略帮助文本时它保持未设置，让外层控件自己的帮助仍然可见。

**返回。** 一个 View。

**错误。** SIZE 非正、LINES 不是 1 或 2、MIN-WIDTH 小于一个字符列、或 ON-PRESS 既不是函数也不是 nil 时，报 `error→ etaf-component-call-error`。NAME 既不是符号也不是非空字符串、或 SET 指向未注册的集时，报 `error→ user-error`。

**示例。**

```elisp
(etaf-ui-icon :name 'play :set 'svg :help-echo "Play"
              :on-press (lambda () (message "Playing")))
```

**参见。** `etaf-ui-icon-lines`、`etaf-ui-toggle-icon`、`etaf-ui-icon-metrics`。

#### Function: etaf-ui-icon (name &key set (size 1.0) color face (lines 1) (min-width 2) help-echo on-press tab-index aria-label id class ref)

从普通 Elisp 用位置参数 NAME 返回同一个带类型的图标 View。

**参数。** NAME 是第一个位置参数；关键字参数与组件形式相同。

**语义。** 把结果直接交给 `etaf-mount`，或在 `etaf-view` 里用组件的 `:name` 形式。渲染出的盒子、解析、绘制与错误与上面的组件条目完全一致。

**返回。** 一个 View。

**参见。** `etaf-ui-icon` 的组件条目。

## 文本变体

<!-- index: etaf-ui-icon-lines; retained icon text -->

#### Function: etaf-ui-icon-lines (name &key set (size 1.0) color face (lines 1))

返回一个或两个标准图标行的、带文本属性的自有字符串。

**参数。** NAME、SET、SIZE、COLOR 与 FACE 使用与 `etaf-ui-icon` 相同的解析与绘制。LINES 是 1 或 2，默认 1。

**语义。** 结果是 LINES 个字符串的列表。每一行都可以直接作为 Text 载荷：它携带图标所需的图像或 face 属性；两行结果把绘制或文本放在第一行，第二行放保留行的内容。请在组件的 `:bindings` 里解析一次，再由保留 Host 的文本表达式选择这些字符串，而不是叠加一个另行定位的图标。返回的字符串是彼此独立的副本，调用方改其中一个不影响其它字符串，也不影响共享的图像；共享的图像值不得修改。

**返回。** 按行顺序排列的 LINES 个带文本属性的字符串。

**错误。** SIZE 非正或 LINES 不是 1 或 2 时，报 `error→ etaf-component-call-error`。NAME 既不是符号也不是非空字符串、或 SET 指向未注册的集时，报 `error→ user-error`。

**示例。**

```elisp
(etaf-ui-icon-lines 'play :set 'svg :lines 2)
     ⇒ (">" " ")
```

**参见。** `etaf-ui-icon`、[响应式系统](reactivity.md)。

## 切换图标

<!-- index: toggle icon; retained text update; on-color -->

#### Component: etaf-ui-toggle-icon (&key value off on set size color on-color face lines min-width help-echo on-press tab-index aria-label id class ref)

通过保留 Host 文本在 OFF 与 ON 之间切换的单个图标。

**参数。** VALUE 是布尔值或响应式源。OFF 与 ON 命名两个变体。SET、SIZE、COLOR、FACE、LINES、MIN-WIDTH、HELP-ECHO、ON-PRESS、TAB-INDEX、ID、CLASS 与 REF 与 `etaf-ui-icon` 相同。ON-COLOR 覆盖 ON 变体的 COLOR，默认取 COLOR。ARIA-LABEL 默认依次取字符串 HELP-ECHO、名字对 `"OFF / ON"`。

**语义。** 两个变体在渲染时解析，之后每行的文本直接读取 VALUE，因此变化发布保留 Host 的文本更新，而不重渲染组件。当只有 ON-COLOR 不同时，OFF 与 ON 可以命名同一个图标，这让 shuffle 或 repeat 这类颜色状态走同一条保留更新路径。普通布尔值表示已定型的变体；要变化的值请传 ref 或 computed。整个盒子是 ON-PRESS 目标，与 `etaf-ui-icon` 完全相同。

**返回。** 一个 View。

**错误。** VALUE 既不是布尔值也不是响应式源，或任一共用 prop 越出 `etaf-ui-icon` 契约时，报 `error→ etaf-component-call-error`。名字无效或集未注册时报 `error→ user-error`。

**示例。**

```elisp
(etaf-ui-toggle-icon :value playing :off 'play :on 'pause :set 'svg)
```

**参见。** `etaf-ui-icon`、[响应式系统](reactivity.md)。

## 注册表接口

<!-- index: default set; icon set spec; icon names -->

#### Variable: etaf-ui-icon-default-set

注册的回退风格，初始为 `nerd`；在渲染前绑定或设置它。

**语义。** 解析先查显式集，然后才查这个变量。变更在下次渲染生效；已挂载的值保持有效，不会被隐式重渲染。值必须命名一个已注册的集，否则每次图标解析都会失败。

**参见。** `etaf-ui-icon-set-register`、[解析一个名字](#解析一个名字)。

#### Variable: etaf-ui-terminal-icon-set

文本终端上处理 SVG 请求时最先查询的图标集，初始为 `tty`。

**语义。** 终端画不出矢量图，所以对那个集的请求先经过这个集；它没有的名字再回到请求的集和后面的候选链。把它设成终端字体确实包含其字形的已注册字体集——装了 Nerd Font 时的 `nerd`——就能让终端保持同一套图标。字体集请求仍以请求的集为先，这个集排在第二。终端集没有覆盖的名字会继续回退，所以只提供部分名字是安全的。

**参见。** `etaf-ui-icon-default-set`、`etaf-ui-icon-set-register`、[解析一个名字](#解析一个名字)。

#### Function: etaf-ui-icon-set-register (name spec)

用图标集规格 SPEC 注册 NAME，替换此前的注册，并返回 NAME。

**参数。** NAME 是符号。字体集需要 SPEC 带 `:kind font`、字符串 `:family`、相对默认行的正浮点 `:height`，以及把符号映射到控制范围以上单字符的 `:glyphs` alist。SVG 集需要 `:kind svg`、宽高为正的四个数字 `:viewbox`，以及 `:paths`（符号到内容字符串）与/或 `:draw`（符号到零参函数），另可带默认为 2 像素的非负整数 `:inset`。两种集都可带可选的 `:fallback` alist，把名字映射到非空的可打印 ASCII 字符串。

**语义。** 注册在替换任何东西之前先完整校验 SPEC，因此无效规格不改变注册表；成功注册或替换会让缓存的字体、face 与图像全部失效，所以下次渲染能看到变更。把存储的规格视为不可变：要改就重新注册。同一份规格内的重名会被拒绝。

**返回。** NAME。

**错误。** 名字或规格形状无效（`"Invalid icon set name/specification: %S"`）、字体或 SVG 规格缺少必需成员（`"Invalid font icon set specification for %S"` 或 `"Invalid svg icon set specification for %S"`）、名字重复（`"Duplicate icon names in %S"`）、或回退值不是非空可打印 ASCII 字符串（`"Icon fallbacks must be nonempty printable ASCII strings"`）时报 `error→ user-error`。消息尽可能点名所在的集。

**示例。**

```elisp
(etaf-ui-icon-set-register
 'brand '(:kind svg :viewbox [0 0 16 16]
                :paths ((logo . "<path d='M2 8L8 2L14 8L8 14Z'/>"))
                :fallback ((logo . "L"))))
```

**参见。** `etaf-ui-icon-set-remove`、`etaf-ui-icon-sets`、`etaf-ui-icon-set-spec`。

#### Function: etaf-ui-icon-set-remove (name)

删除已注册的集 NAME，并让缓存的字体、face 与图像失效。

**语义。** 删除不存在的集无害。已渲染的值在下次渲染前保持有效，删除返回 nil。

**返回。** nil。

**参见。** `etaf-ui-icon-set-register`。

#### Function: etaf-ui-icon-sets ()

按注册顺序返回已注册的图标集名。

**语义。** 列表反映当前注册表；自定义集按它们被注册的顺序排在内置的 `nerd`、`fa`、`material`、`octicons`、`sys` 与 `svg` 之后。

**返回。** 集名符号的列表。

**参见。** `etaf-ui-icon-names`。

#### Function: etaf-ui-icon-set-spec (name)

返回 NAME 存储的不可变规格；未注册时返回 nil。

**语义。** 返回的是注册表自己的数据。不要修改它；要改就重新注册这个名字。

**返回。** 规格 plist，或 nil。

**参见。** `etaf-ui-icon-set-register`。

#### Function: etaf-ui-icon-names (&optional set)

返回 SET 自己的名字；SET 为 nil 时返回所有集的并集。

**语义。** 结果列出该集声明的名字——glyphs、paths 与 draw 合计——绝不通过回退查找凭空补名字；解析请用组件。SET 为 nil 时返回每个已注册集的并集，去重。

**返回。** 名字符号的列表。

**错误。** 非 nil 的 SET 未知时报 `error→ user-error`。

**示例。**

```elisp
(memq 'play (etaf-ui-icon-names 'svg))  ⇒ (play)
```

**参见。** `etaf-ui-icon-sets`。

## 度量

<!-- index: icon metrics; fit; missing font -->

#### Function: etaf-ui-icon-metrics (set &optional frame)

返回 SET 相对 FRAME 标准行的未夹紧度量。

**参数。** SET 是已注册的集名。FRAME 默认为当前选中的 frame。

**语义。** 返回的 plist 含 `:family`（声明的字体族；SVG 为 nil）、`:height`（声明的比例）、`:line-pixel-height`（*声明*需要的行像素）、`:line-height`（frame 的标准行）与 `:fit`（声明行不大于标准行时为非 nil）。字体度量包含周围默认字体的 ascent 与 descent，因为更高的字体可以通过基线的任一半撑大混合文本行。GUI 上字体缺失时 `:line-pixel-height` 与 `:fit` 为 nil。在 batch 或终端 frame 上，没有解析出的字体，度量按声明比例与标准行估算，不对字体可用性作任何断言。SVG 集报告行盒。

**返回。** 度量 plist。

**错误。** SET 未知时报 `error→ user-error`。

**参见。** [绘制尺寸与行](#绘制尺寸与行)、`etaf-ui-icon`。

## SVG 场景

<!-- index: SVG scene; SVG element; image descriptor; scene caching -->

SVG 场景辅助把场景组合成标记字符串，经 `etaf-ui-svg-image` 交给图像来源或图像 Host。每个元素辅助都校验几何与属性，对文本与字符串属性值做 XML 转义，以同一种方式格式化数字，并在属性值为 nil 时省略该属性。任何失败都在产出任何标记之前报 `etaf-ui-svg-error`，因此非法场景不会画出半成品。终端 frame 请保留文本回退；按状态键缓存组合好的场景，不要在每次重绘时重建文档。

#### Function: etaf-ui-svg-rect (x y width height &rest attributes)

返回位于 X/Y、宽高为正的矩形 SVG 标记。

**参数。** ATTRIBUTES 接受 `:rx`、`:ry`、`:transform`，以及公共绘制族 `:fill`、`:stroke`、`:stroke-width`、`:stroke-linecap`、`:stroke-linejoin`、`:stroke-dasharray` 与 `:opacity`。

**示例。**

```elisp
(etaf-ui-svg-rect 0 0 16 10 :rx 2 :fill "#F0E2C6")
     ⇒ "<rect x='0' y='0' width='16' height='10' rx='2' fill='#F0E2C6'/>"
```

**参见。** `etaf-ui-svg-image`、`etaf-ui-svg-error`。

#### Function: etaf-ui-svg-circle (cx cy radius &rest attributes)

返回圆心在 CX/CY、半径为正的圆 SVG 标记。

**参数。** ATTRIBUTES 接受 `:transform`，以及公共绘制族 `:fill`、`:stroke`、`:stroke-width`、`:stroke-linecap`、`:stroke-linejoin`、`:stroke-dasharray` 与 `:opacity`。

**参见。** `etaf-ui-svg-image`。

#### Function: etaf-ui-svg-line (x1 y1 x2 y2 &rest attributes)

返回从 X1/Y1 到 X2/Y2 的直线 SVG 标记。

**参数。** ATTRIBUTES 接受 `:stroke`、`:stroke-width`、`:stroke-linecap`、`:stroke-linejoin`、`:stroke-dasharray` 与 `:opacity`。

**参见。** `etaf-ui-svg-image`。

#### Function: etaf-ui-svg-path (d &rest attributes)

返回路径数据 D 的 SVG 标记；D 是非空字符串。

**参数。** ATTRIBUTES 接受 `:fill`、`:stroke`、`:stroke-width`、`:stroke-linecap`、`:stroke-linejoin`、`:stroke-dasharray` 与 `:opacity`。

**参见。** `etaf-ui-svg-image`。

#### Function: etaf-ui-svg-text (x y text &rest attributes)

返回锚定在 X/Y 的单行 TEXT 的 SVG 标记；其内容经过 XML 转义。

**参数。** ATTRIBUTES 接受 `:font-family`、`:font-size`、`:font-weight`、`:text-anchor`、`:dominant-baseline`、`:fill`、`:stroke`、`:stroke-width` 与 `:opacity`。

**参见。** `etaf-ui-svg-image`。

#### Function: etaf-ui-svg-group (children &rest attributes)

返回共享 ATTRIBUTES 的组 CHILDREN 的 SVG 标记。

**参数。** CHILDREN 是嵌套元素的标记串接。ATTRIBUTES 接受 `:transform`、`:fill`、`:stroke`、`:stroke-width`、`:stroke-linecap`、`:stroke-linejoin`、`:stroke-dasharray` 与 `:opacity`。

**参见。** `etaf-ui-svg-image`。

#### Function: etaf-ui-svg-image (body width height viewbox &optional preserve-aspect-ratio)

返回一个 `(image :type svg :data STRING)` 描述符，把场景 BODY 画进 WIDTH 乘 HEIGHT 的像素盒，并映射到 VIEWBOX。

**参数。** BODY 是用元素辅助组合出的标记。WIDTH 与 HEIGHT 是准备好的图像填充的像素盒；VIEWBOX 是映射到该盒的场景窗口 `(X Y WIDTH HEIGHT)`，尺寸为正。PRESERVE-ASPECT-RATIO 为 nil 时用 SVG 默认居中，为 `none` 时把完整场景缩放到盒；其它值都是错误。

**语义。** 描述符可交给图像来源与图像 Host，例如 tile grid 的 cell image。Ebox 每个显示行画一张图像，因此只有每个格子拥有自己的交互目标时才按格切片，被动图画请用整块行。

**返回。** 一个图像描述符。

**错误。** BODY 不是字符串、viewbox 不是尺寸为正的四个数字、宽或高非正、或宽高比参数既不是 nil 也不是 `none` 时报 `error→ etaf-ui-svg-error`。

**示例。**

```elisp
(etaf-ui-svg-image
 (concat (etaf-ui-svg-rect 0 0 16 10 :fill "#F0E2C6" :stroke "#A98956")
         (etaf-ui-svg-circle 8 5 3.6 :fill "#FFF8E7")
         (etaf-ui-svg-text 8 6.4 "车" :fill "#AD3830" :font-size 8
                           :text-anchor "middle"))
 48 30 '(0 0 16 10))
```

**参见。** `etaf-ui-svg-error`、[图片](images.md)。

#### Error: etaf-ui-svg-error

SVG 场景辅助收到的非法输入。

**语义。** 在产出任何标记之前抛出，消息点名元素、几何或属性以及收到的值。接受的属性键按元素而定；未知或重复的键、缺少值、类型错误的值、非正的几何、非法文本与非法宽高比参数都报这个条件。

**参见。** 上面的 SVG 元素条目。

## 错误与恢复

- 图标组件的无效 prop 经 `etaf-check-prop` 报 `error→ etaf-component-call-error`，消息点名组件、属性、收到的值与期望：SIZE 非正、LINES 不是 1 或 2、MIN-WIDTH 小于一个字符列、ON-PRESS 既不是函数也不是 nil、VALUE 既不是布尔值也不是响应式源。
- 图标名无效或集未注册时报 `error→ user-error`，因为注册表无法解析请求；消息点名名字或集。
- 场景构造报 `error→ etaf-ui-svg-error` 且不返回标记，因此调用方可以在整个场景组合外面捕获一个条件。
- 注册表失败是原子的：被拒绝的注册不改变此前的规格与已渲染值。成功变更在下次渲染生效，永不隐式重渲染已挂载组件。
- 字体或字形缺失不是错误：解析沿候选链回退，最后把名字当纯文本显示。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)。

```elisp :run
(etaf-view
 (row :item-gap '(ch 2) :cross-align 'center
   (etaf-ui-icon :name 'play :set 'svg :help-echo "Play")
   (etaf-ui-toggle-icon :value t :off 'play :on 'pause :set 'svg)
   (etaf-ui-icon :name 'heart :set 'svg :color "#B73951")
   (etaf-ui-icon :name 'play :set 'svg :lines 2)))
```
