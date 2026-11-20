# 浮动面板

面板是一个子 frame，在你正在工作的窗口之上承载一个 ETAF Runtime：一个时钟、一个播放器、一个计时器、一份搜索结果。面板彼此独立——各自拥有 frame、Runtime 与输入，可以同时开好几个，而且面板从不改变当前 buffer。可聚焦的面板能拿到键盘；点面板任意位置会把它提到其他面板之上。本章讲面板本体；整套应用作为面板注册见[面板应用](posframe-applications.md)，面板提供给 View 的 Theme plist 见[组件样式与主题](component-styles-and-themes.md)，可聚焦面板收到的输入见[焦点](focus.md)与[键盘](keyboard.md)，面板落位的绝对坐标见[定位、层与浮层](positioning-layers-and-overlays.md)。

## 面板选项

<!-- index: 面板选项; etaf-posframe-show 选项; :at; :stack; :width; :height; :title; :theme; :border; :key -->

`etaf-posframe-show`、`etaf-posframe-toggle` 与 `etaf-posframe-register-app` 接受同一套面板选项。下表是完整清单：不在表里的选项会在建 frame 之前就被 `etaf-posframe-error` 拒掉。

| 选项 | 取值 | 默认 | 含义 |
| --- | --- | --- | --- |
| `:at` | 落位 | `point` | 面板放在哪里 |
| `:stack` | `t`、`nil` | `nil` | 同锚点叠放时避开已开的面板 |
| `:width` | 列数、比例 | 56 | 内容列数 |
| `:height` | 行数、比例 | 30 | 内容行预算 |
| `:fill-height` | `t`、`nil` | `nil` | 保持行预算的高度 |
| `:resizable` | `t`、`nil`、方向列表 | `t` | 哪些边可以缩放 |
| `:title` | 字符串 | `nil` | 标题栏文字 |
| `:draggable` | `t`、`nil` | `nil` | 拖标题栏移动面板 |
| `:focusable` | `t`、`nil` | `nil` | 让面板拿键盘 |
| `:focus-on-open` | `t`、`nil` | 同 `:focusable` | 打开时选中面板 |
| `:auto-hide` | `nil`、`t`、秒数 | 随 `:focusable` | 用户离开后隐藏 |
| `:theme` | 模式、plist、ref | `auto` | 调色板 |
| `:border` | 边框 plist | `nil` | 边框宽度与状态颜色 |
| `:key` | 符号 | `nil` | 面板标识 |

每个选项在进入时就校验，所以错值在 frame 还不存在时就报出来，而不是建到一半才炸。下面几节给每组的取值与行为；后面 `etaf-posframe-show` 的条目只写函数契约，调色板见 `etaf-posframe-theme` 与各变量的条目。

### 落位与叠放

<!-- index: 面板锚点; 锚点名称; 字符格落位; 像素落位; 叠放面板 -->

`:at` 有五种写法，写法决定位置怎么算：

| 写法 | 例子 | 落点 |
| --- | --- | --- |
| 锚点符号 | `'frame-top-right` | 父 frame 或父窗口文本区里的一个具名位置。 |
| 锚点加偏移 | `'(point 0 -1)` | 锚点再按字符格偏移：先行（负值向上），后列（负值向左）。 |
| 字符格 | `'(cells 0 0)` | 父窗口文本区里从左上角数起的第 ROW 行、第 COL 列，从 0 开始。 |
| frame 像素 | `'(pixels 120 . 40)` | 父 frame 像素坐标的 X 与 Y。 |
| 函数 | 任意 Posframe poshandler | 收到 Posframe 的落位信息，返回 `(X . Y)`。 |

锚点共二十个：`point`、`point-top`，以及 `frame` 或 `window` 与九个位置的全部组合。

| 位置 | 在父 frame 内 | 在父窗口文本区内 |
| --- | --- | --- |
| 左上 | `frame-top-left` | `window-top-left` |
| 上中 | `frame-top-center` | `window-top-center` |
| 右上 | `frame-top-right` | `window-top-right` |
| 左中 | `frame-center-left` | `window-center-left` |
| 正中 | `frame-center` | `window-center` |
| 右中 | `frame-center-right` | `window-center-right` |
| 左下 | `frame-bottom-left` | `window-bottom-left` |
| 下中 | `frame-bottom-center` | `window-bottom-center` |
| 右下 | `frame-bottom-right` | `window-bottom-right` |

按锚点落位时面板与所贴的边留出余量，不会压在滚动条或窗口边框上：父 frame 内留一个字符格，窗口文本区内留半个字符格。贴右或贴下的锚点还会把面板自己的宽或高留在父 frame 之内，宽面板不会跑出屏幕。`point` 把面板放在 point 处向上长，point 之前的文字仍然看得见；`point-top` 放在 point 处向下长。

`:stack t` 读已有面板，把新面板贴着它们放，所以面板高度各不相同，叠起来也不会留空。顶部或居中的锚点下，新面板紧接在它碰到的最低一块下面；底部锚点下则紧接在最高一块上面；图形帧上两块之间留 6 像素，终端上留一格。只有第一列排不下时，才向左挪一列，始终不出父 frame。`:stack` 需要带锚点的 `:at`（锚点符号或锚点加偏移），因为字符格、像素对和 poshandler 都没有叠放方向；`:stack` 配上其他 `:at` 会报错。

### 面板尺寸

<!-- index: 面板宽度; 面板高度; 面板比例; 面板收高 -->

`:width` 是内容列数，`:height` 是内容行预算，边框、内边距与标题栏都加在它们之外。两者都接受正整数，或 `(fraction F)`，F 大于 0 且不超过 1，表示父 frame 宽或高的比例，结果夹在父 frame 之内。

frame 会收到渲染内容的高度，最多到 `:height` 预算，所以短的 View 得到矮面板，长的到预算就裁剪而不是长出屏幕。`:fill-height t` 让 frame 始终占满行预算，固定网格的应用（例如棋盘）需要它：剩余的行由表面画出来，而不是 frame 收窄把棋盘裁掉。用户从外部改过的 frame 会成为面板新的宽或高，View 按它重排，收高也不再跟用户的尺寸较劲。

尺寸用的是父 frame 的字符度量。内容比父 frame 宽的面板会被夹住，比例在每次显示时解析一次，之后改父 frame 大小是让面板重排，而不是重算比例。

| 取值 | 含义 |
| --- | --- |
| `30` | 三十个内容列或行。 |
| `(fraction 0.5)` | 父 frame 宽或高的一半，夹在 frame 之内。 |
| `(fraction 1)` | 整个父 frame。 |

### 缩放

<!-- index: 面板缩放; 可缩放面板; 面板改宽; 面板改高 -->

面板的 frame 可以被外部改尺寸：用户拖边、调用方 `set-frame-size`、平铺一步。面板接受的变化会成为它新的宽度与行预算，View 按新尺寸重排。`:resizable` 决定接受哪些变化。

| 取值 | 接受的变化 |
| --- | --- |
| `t`（默认） | 任意边。 |
| `nil` | 都不接受；frame 回到面板原来的尺寸。 |
| 列表 | 列表里那些边所在的轴：`left` 或 `right` 管宽度，`top` 或 `bottom` 管高度。 |

列表写的是边，作用却按轴算，因为子 frame 只报新的尺寸，不报指针拖的是哪条边：`'(left right)` 接受任何宽度变化、不接受高度变化，`'(bottom)` 接受高度变化、拒绝宽度。被拒的那个轴立刻还原，frame 不会留着面板不允许的尺寸；拖上边或左边时原点会跟着移动，所以位置也一起还原，面板不会因此挪位。

拖拽过程中 frame 显示的还是已有的画布，按新的边缘裁掉：每一行照旧占一行，不会被折进更窄的 frame；等面板再次贴合时 View 才按新尺寸重排。面板自己按内容收高不是外部缩放，照样生效：`:resizable nil` 的面板仍会缩到矮内容，`:fill-height` 仍守住行预算。高度变化只有成为新预算时才保留——比预算更高，或比内容需要更矮——否则面板本来就贴内容。

```elisp
(etaf-posframe-show (etaf-view (text "panel"))
                    :width 24 :height 8 :fill-height t
                    :resizable '(left right bottom))
```

### 标题栏与拖动

<!-- index: 面板标题; 面板拖动 -->

`:title` 是字符串，变成内容之上的标题栏：整行宽，底色是面板表面，下面一条细线。没有 `:title` 的面板完全没有 header line，因此也没有标题栏上的主题切换条，也不能拖动。`:draggable t` 把 Posframe 自带的拖动绑到标题栏上；它需要 `:title`，而只有 `:draggable` 没有标题不会报错，只是不起作用。

### 输入与寿命

<!-- index: 面板焦点; 面板键盘; 面板自动隐藏 -->

`:focusable t` 让面板拿键盘，它的 View 的 `:keys`、文本框与按钮才收得到输入。默认是 nil，也就是面板默认只是只读表面，由调用方决定要不要接键盘；无论哪种情况，点面板任意位置都会把它提到其他面板之上。`:focus-on-open` 决定打开那一刻是否选中面板，默认取 `:focusable` 的值，所以可聚焦的面板一开就能直接打字，写 nil 则要等用户点一下。

`:auto-hide` 管用户离开之后面板的寿命：

| 取值 | 行为 | 默认用于 |
| --- | --- | --- |
| `nil` | 一直留到被关闭、被计时器隐藏或父 buffer 消失。 | `:focusable` 的面板 |
| `t` | 下一条在面板之外执行的命令之前隐藏，预览随手一转就消失。 | 不可聚焦的面板 |
| 正数 | 开面板后这么多秒隐藏。 | 无 |

所以默认值跟着输入契约走：被动面板在用户去别处时消失，而拿着键盘的面板要留到被关闭，因为在用户手底下藏起来会丢掉已输入的内容。`etaf-posframe-hide-inactive` 是另一件事：Emacs 不是前台应用时隐藏所有面板，与 `:auto-hide` 无关。

### 主题与边框

<!-- index: 面板主题选项; 面板边框选项; 面板调色板选择 -->

`:theme` 接受五类取值：

| 取值 | 调色板 |
| --- | --- |
| `auto`（默认） | 从父 frame 的 default face 推导，跟随 Emacs 主题。 |
| `light` | 钉在亮色模式。与 frame 一致的钉住保留 frame 自己的表面；不一致时用包里中性的亮色基色。 |
| `dark` | 钉在暗色模式，规则同上：与 frame 一致就保留它的表面，否则用中性的暗色基色。 |
| Theme plist | 原样使用，不做推导。 |
| Theme ref 或 computed | 每次渲染时读取，持有调色板的宿主可以在面板活着时换掉它。 |

`:theme` 为 `auto`、`light` 或 `dark` 的面板带标题栏主题切换条，因为这三种正是它能在其间切换的模式。内容用 `etaf-surface-declare`（见[表面声明](component-styles-and-themes.md#表面声明)）声明了自己的表面时，调色板归内容所有，切换条也换成内容声明的模式。钉住的 `:theme` 一样会传到内容：面板在开面板那一刻把它切到钉住的模式，所以自带颜色的应用按调用方要的模式打开，而不是用它自己的默认。之后以内容的模式为准：标题栏切换条与内容自己的开关写同一个格子，两边重画的是同一个状态。

`:border` 用一个 plist 描述 frame 边框：

| 字段 | 取值 | 不给时 |
| --- | --- | --- |
| `:width` | 0 到 19 的整数像素 | 1 像素 |
| `:color` | 颜色字符串、`nil` | 主题的面板边框色 |
| `:focus` | 颜色字符串、`nil` | 强调色按聚焦强度混入表面 |
| `:hover` | 颜色字符串、`nil` | 强调色按悬停强度混入表面 |

写 `nil` 的那几种从主题推导：宽度取 `etaf-posframe-border-width`（默认 1），`:focus` 与 `:hover` 取 `etaf-posframe-border-focus-strength`（0.6）与 `etaf-posframe-border-hover-strength`（0.3），所以调用方可以只覆盖聚焦边框，另外两种继续跟随主题。未知字段、超出 0 到 19 的宽度、非字符串的颜色都报 `etaf-posframe-error`。终端把边框画在 frame 尺寸之外的一格里；宽度不管写多少都只占一格，颜色用终端自己的配色。宽度与三种状态颜色只对图形帧生效。

### 面板标识

<!-- index: 面板 key; 替换面板 -->

`:key` 是当前 buffer 内标识面板的符号。用已活着的 key 再显示一个 View 会替换那个面板——frame 被复用、View 重新挂载——而不同 key 的面板各自拥有 frame、Runtime 与位置。不给 `:key` 就是匿名面板，每次显示都新开一个。

## 打开、刷新与关闭

<!-- index: etaf-posframe-show; etaf-posframe-hide; etaf-posframe-toggle; etaf-posframe-refresh -->

#### Function: etaf-posframe-show (view &rest options)

把 VIEW 显示在一个浮动面板里并返回该面板。

**参数。** VIEW 是一个 View，或返回 View 的零参函数。OPTIONS 是[面板选项](#面板选项)里那张表的 plist；本条只写契约，不重复表格。

**语义。** 面板是一个 frame 加一份挂载好的 Runtime，所以里面的 View 与在 buffer 里完全一样：refs、组件、按键与保留更新都照旧，面板只额外提供 frame、标题栏与指针处理。每次开面板都重新挂载 View，并把面板的 Theme 与外观交给它，所以面板里的应用不用知道自己在一个面板里就跟着用户的调色板走。用已经活着的 `:key` 再显示会替换那个面板；不同的 key 各自拥有 frame、Runtime 与位置，两个计时器才能并排放着。

**返回。** 一个面板值，对调用方不透明；交给下面几个函数或 `etaf-posframe-hide` 使用。

**错误。** 选项未知、取值不在上表范围内、`:stack` 没有带锚点的 `:at`、或显示环境不支持子 frame 时报 `etaf-posframe-error`。显示失败会先卸载 View、删掉 frame，再把错误抛出去，所以调用方换成合法选项重试时是从干净状态开始。

**示例。**

```elisp
(etaf-posframe-show (etaf-view (text "25:00"))
                    :key 'timer :title "Timer" :width 24 :height 2
                    :at 'frame-top-right :stack t :draggable t)
```

#### Function: etaf-posframe-hide (&optional panel)

隐藏 PANEL，并释放它的 Runtime、计时器与 frame。

**语义。** PANEL 默认取当前 buffer 最新的面板，面板自己的按键就是这样调它的；其他面板不受影响。隐藏会释放这个面板持有的一切——Runtime、自动隐藏计时器与 frame——所以隐藏之后到再显示之前不占任何开销，再显示时是重新挂载 View 而不是恢复旧状态。重复调用安全，对已经隐藏的面板也安全。

**返回。** 隐藏了活面板时返回非 nil，否则返回 nil。

**参见。** `etaf-posframe-show`、`etaf-posframe-toggle`、`etaf-posframe-app`。

#### Function: etaf-posframe-toggle (view &rest options)

隐藏同一个 `:key` 的面板，或按 OPTIONS 显示 VIEW。

**语义。** 没有 `:key` 时针对当前 buffer 最新的面板。它接受 `etaf-posframe-show` 的全部选项，是「一个按键开关同一个面板、不碰其他面板」的入口。面板是重新挂载而不是复用，所以每次打开 View 都读当时应用的状态。

**返回。** 新面板；隐藏了面板时返回 nil。

**参见。** `etaf-posframe-show`、`etaf-posframe-hide`。

#### Function: etaf-posframe-refresh (&optional panel)

安排 PANEL 按它的 frame 宽度重排，并把 frame 收到渲染内容的高度。

**语义。** PANEL 默认取当前 buffer 的面板。从外部改过大小的 frame 会成为面板宽度，View 因此重排、标题栏按新的列数重画；收高推迟到当前事件与渲染之后，所以从按钮、计时器或主题回调里调用都安全。宿主 frame 尺寸变化时面板本来也会自动收高，只有内容高度变了却没有 Runtime 更新时才需要手动调一次。收高带退避：一秒内收到二十次就停下，等两秒再试，所以跟它较劲的条件不会把 CPU 跑满。

**返回。** PANEL 还活着时返回非 nil。

## 读取已打开的面板

<!-- index: etaf-posframe-panels; etaf-posframe-panel-frame; etaf-posframe-live-p -->

#### Function: etaf-posframe-panels ()

返回活着的面板，最新的在前。

**语义。** 返回的是副本，调用方可以边遍历边隐藏。顺序是最近使用顺序，`etaf-posframe-hide` 取默认面板、`etaf-posframe-cycle` 轮转都按它走，`:stack` 找要避开的邻居也读它。

**返回。** 面板值的列表。

#### Function: etaf-posframe-panel-frame (panel)

返回 PANEL 的子 frame；PANEL 不在了返回 nil。

**语义。** 要读或比较 frame 用它，而不是去翻内部结构，例如按某个面板的位置摆放另一个面板、记下 window id 用于截图，或检查哪个 frame 有焦点。

**返回。** 一个 frame 或 nil。

**参见。** `etaf-posframe-live-p`。

#### Function: etaf-posframe-live-p (panel)

只要 PANEL 的 frame 还在、Runtime 还挂着就返回非 nil。

**语义。** 面板值比面板活得久：面板隐藏之后再拿着它也是安全的，这个谓词回答「还有没有活的对象可谈」。`etaf-posframe-hide` 的返回就是这个问题的另一个侧面。

**返回。** 一个布尔值。

## 标题栏与指针

<!-- index: 面板标题栏; 面板主题切换; 面板悬停边框 -->

带 `:title` 的面板有整行宽的标题栏：一行高，底色是面板表面往前景轻抬一点的颜色，下面一条细线；`:theme` 是模式时，右侧还有主题切换条。标题栏会清掉主题自带的 `header-line` face，所以亮色主题不会给面板套一圈深色轮廓，即使在会反色 header line 的主题里，标题栏也保持面板自己的颜色。

面板自己的切换条是一行三个格子，每格是一个模式：

| 格子 | 模式 | 效果 |
| --- | --- | --- |
| `亮` | `light` | 把面板钉在亮色调色板。 |
| `随` | `auto` | 重新跟随 Emacs 主题。 |
| `暗` | `dark` | 把面板钉在暗色调色板。 |

当前模式那一格填上主题强调色，字色按强调色的亮度取黑或白；另外两格保持标题栏表面，悬停时略暗。点一下会让这个面板在它剩下的寿命里按选中的模式重画。`:theme` 仍然是调用方传入的值，所以这个选择是会话设置，从不写进配置，面板重开时又回到配置的模式。这个控件是 etaf-ui 的 `etaf-toggle-strip`，见[按钮与选择控件](ui-buttons-and-choice-controls.md)。

内容声明了自己的表面时，切换条改为按内容声明的模式表渲染，格子数与文字都由内容决定（微信读书因此是 `深`、`浅`、`纸` 三档），选中的是内容的当前模式，点一下写的就是内容与宿主共用的那一格模式。内容自己的快捷键写的也是同一格，所以两边任一处切换，内容、标题栏、frame 与边框一起重画，一个应用只有一个外观状态。

指针不会抢键盘。面板不打开 buffer 级的 `track-mouse`，因为那会让 Emacs 在指针每次移动时选中指针下的 frame，离开面板就会把键盘带走。悬停边框改由一个短计时器读指针：指针下的面板把边框画成强调色，只有点击才移动键盘。已经聚焦的面板保持聚焦边框，不再加悬停色，两种状态因此不会叠在一起；主题切换条上已选中的格子同理，不加悬停底色。

`:draggable` 打开后拖动标题栏就能移动面板；拖动由 Posframe 负责，应用不用写代码，面板位置也不会回报。

## 键盘

<!-- index: 面板按键; 面板焦点; 面板轮转 -->

面板只有在打开时给了 `:focusable` 才能拿键盘，也只有那时它的 View 的按键、文本框与按钮才收得到输入；无论哪种情况，点面板任意位置都会把它提到其他面板之上。拿到焦点之后，面板的按键来自 View，`etaf-posframe-panel-keys` 只额外加三个优先于它们的绑定，所以关闭面板从不指望应用记得去绑它。

#### Variable: etaf-posframe-panel-keys

可聚焦面板有焦点时始终生效的 keymap。

**语义。** 它把 `q`、`ESC` 与 `C-g` 绑成关闭面板，并只在这三个绑定上压过 View 自己的按键，所以应用可以随意使用其他键。View 的按键赢不了这三个，这正是面板在任何状态下（包括 View 自己的按键处理卡住时）都关得掉的原因。这个 map 在面板拿焦点时读取，调用方可以往里加绑定，只在这三个键上会被它盖住。

**参见。** `etaf-posframe-cycle`、`etaf-posframe-hide`。

#### Variable: etaf-posframe-hide-inactive

Emacs 不是前台应用时隐藏面板，默认 `t`。

**语义。** 子 frame 本身是一个窗口，所以会列出窗口的窗口管理器（例如 macOS 的调度中心）会把面板当成切换目标，点它会激活 Emacs 而不是身后的应用。前台是别的应用时隐藏面板就能让这份列表保持干净；Emacs 回到前台时面板再出现。写 nil 则保持可见，适合要贴着别的应用一直留在屏幕上的面板。这个变量与 `:auto-hide` 无关，后者管的是用户在 Emacs 里去了别处。文本终端上这个变量不起作用：终端 frame 不出现在窗口列表里，面板一直可见。

#### Variable: etaf-posframe-focus-follows-mouse

指针停在哪个面板上就把输入焦点给它，默认 `nil`。

**语义。** 只对接受键盘的面板生效。默认把键盘留在用户放下的地方，这也是悬停边框不需要开关的原因：指针下的面板把边框画成强调色、键盘不动，点击才移动它。设成 `t` 之后悬停本身就换键盘目标，适合以指针为主的用法，不适合以打字为主的用法。

**参见。** `etaf-posframe-show`、`etaf-posframe-panel-keys`。

### 在文本终端里操作面板

文本终端能把子 frame 画出来，却不给它键盘和鼠标：每个按键、每次点击都留在面板身后的 frame 上。所以终端里靠应用前缀映射操作面板，作用对象是当前选中的 frame 上的面板，没有就取最近打开的那个，而键盘留在普通 buffer 里。

前缀之后，方向键把面板移动 `etaf-posframe-move-step` 格，`=` 或 `+` 加宽，`-` 收窄，`>` 加高，`<` 收缩，`k` 再读一个键交给面板执行。移动按字符格算：图形 frame 按自己的字符宽高走，终端按自己的一格走。这里特意不用 Control 加方向键，因为 macOS 的窗口管理器在 Emacs 看到按键之前就切换桌面了。按键在第一次按下之后继续有效，所以一串移动只需按一次前缀，按住不动也会连续移动；按其他键结束这一串。面板停在父 frame 边缘，不会移到屏幕外。移动过的面板在后续刷新里保持新位置，改过尺寸的保持新宽度和行预算：新位置变成绝对锚点，新高度变成 `:fill-height` 的预算。

#### Function: etaf-posframe-move (direction &optional steps panel)

把 PANEL 沿 `direction` 移动 `steps` 格。

**语义。** `direction` 是 `left`、`right`、`up` 或 `down`，`steps` 默认取 `etaf-posframe-move-step`（3），`panel` 的默认值与前缀映射相同。一格就是一个字符格。位置不会越过父 frame 的左上角，面板的锚点变成它此刻的绝对位置，所以刷新不会把它放回去。交互调用时提示方向，不读方向键。

**错误。** 没有可用面板时报 `etaf-posframe-error`。

#### Function: etaf-posframe-resize (axis &optional steps panel)

把 PANEL 沿 `axis` 改变 `steps` 格尺寸。

**语义。** `axis` 是 `wider`、`narrower`、`taller` 或 `shorter`，`steps` 默认取 `etaf-posframe-resize-step`（1）。面板不会窄于四列、矮于两行。新宽度和行预算在 frame 改变之前先记下，所以 frame 尺寸变化触发的刷新会保持它们，内容按新宽度重排。交互调用时提示方向。

**错误。** 没有可用面板时报 `etaf-posframe-error`。

#### Function: etaf-posframe-send-key (&optional panel)

读一个键序列，在 PANEL 的 View 里执行。

**语义。** 按键执行时面板 buffer 是当前 buffer，所以 View 在宿主上声明的按键能在那里生效。需要键盘焦点落在某一行上的控件（例如用 Tab 走到的按钮）仍然需要图形 frame；因此终端面板适合键由宿主声明的 View。返回执行过的键序列。

**错误。** 没有可用面板时报 `etaf-posframe-error`。

#### Variable: etaf-posframe-move-step

`etaf-posframe-move` 没有给步数时移动的字符格数，默认 `3`。

**语义。** 一格就是一个字符格，所以图形 frame 按自己的字符宽高走，终端按自己的一格走。默认值让一次按键看得见效果，按住时又停得下来；前缀映射的方向键也用它。

#### Variable: etaf-posframe-resize-step

`etaf-posframe-resize` 没有给步数时改变的行列数，默认 `1`。

**语义。** 默认每次一格，窄面板才不会一下子冲出自己的 frame。想少按几次就调大；前缀映射的缩放键也用它。

**参见。** `etaf-posframe-app-prefix`、`etaf-posframe-panel-keys`。

## 外观与边框

<!-- index: 面板主题; 面板令牌; 面板边框; 边框强度 -->

面板给它的 View 提供一个从父 frame 的 default face 推导出来的 Theme，所以面板里的应用跟着用户的调色板走，而不是自带一套颜色。面板 frame 画的是面板表面，标题栏、边框与 View 读同一份调色板，这也是亮色面板放在暗色 frame 里仍然亮而可读的原因。内容用 `etaf-surface-declare` 声明了自己的表面时，面板改画内容的 Theme：frame、标题栏与边框都用那份调色板，面板不再从父 frame 推导第二份。填了强调色的地方，字色按强调色的亮度选，所以浅强调色的暗主题与深强调色的亮主题都能得到可读的标签。

#### Function: etaf-posframe-theme (&optional frame mode)

返回从 FRAME 的 default face 推导出来的 ETAF UI Theme plist。

**参数。** FRAME 默认取选中的 frame。MODE 为 `light` 或 `dark` 时把调色板钉在该模式，为 nil 时跟随 frame。与 frame 自己表面一致的钉住保留那份表面，所以「跟随主题」与「钉到 frame 自己的模式」之间来回切不会让面板变色；不一致的钉住则按被钉的极性推导。模式读的是 frame 的实际背景色，所以主题把 `background-mode` 留成过期值也照样读得对。

**语义。** 结果带着本包绘制所用的令牌表。`:ui-panel-bg` 是面板表面：暗色下调色板把 frame 背景按 `etaf-posframe-dark-shade` 往 `etaf-posframe-dark-surface` 沉，亮色下按 `etaf-posframe-surface-lift` 往黑沉。`:ui-accent` 是 frame 的 `link` 前景色，主题没给时落到一个固定蓝。其余令牌都从这三者派生，所以改了 frame 颜色的调用方得到的是一份自洽的调色板，而不是混色。

| 令牌 | 推导 |
| --- | --- |
| `:ui-mode` | `dark` 或 `light`：解析出的极性。 |
| `:ui-bg` | frame 的背景色；被钉的模式与 frame 不一致时用中性基色的背景。 |
| `:ui-fg` | frame 的前景色；同上情况用基色的前景。 |
| `:ui-border` | 面板表面往前景混 16%。 |
| `:ui-panel-bg` | frame 背景按上面的规则下沉后的颜色。 |
| `:ui-panel-fg` | 前景色。 |
| `:ui-panel-border` | 与 `:ui-border` 相同。 |
| `:ui-muted-fg` | 前景往表面混 42%。 |
| `:ui-accent` | `link` 前景；没有时亮色用 `#2F6FE4`、暗色用 `#6CB6FF`。 |
| `:ui-accent-fg` | 强调色上文字的黑或白，按强调色亮度取。 |
| `:ui-accent-soft-bg` | 表面往强调色混 12%。 |
| `:ui-disabled-fg` | 前景往表面混 60%。 |
| `:ui-disabled-bg` | 表面往边框混 12%。 |
| `:ui-disabled-border` | 边框色。 |
| `:ui-button-primary-fg` | 强调色上的字色。 |
| `:ui-button-primary-bg` | 强调色。 |
| `:ui-button-secondary-fg` | 前景往强调色混 35%。 |
| `:ui-button-secondary-bg` | 表面往强调色混 18%。 |
| `:ui-button-ghost-fg` | 前景色。 |
| `:ui-info-bg`、`:ui-info-fg`、`:ui-info-border` | 表面、前景与边框往 `#6CB6FF` 分别混 20%、55%、40%。 |
| `:ui-success-bg`、`:ui-success-fg`、`:ui-success-border` | 同样三处往 `#4FB477` 混 20%、50%、40%。 |
| `:ui-warning-bg`、`:ui-warning-fg`、`:ui-warning-border` | 同样三处往 `#E8B45C` 混 20%、55%、40%。 |
| `:ui-danger-bg`、`:ui-danger-fg`、`:ui-danger-border` | 同样三处往 `#FF7A7A` 混 20%、55%、40%。 |

**返回。** 带齐上述令牌的 Theme plist；调用方自己搭边界（例如第二个子 frame、或面板里的一块区域）时，可以把它交给组件的 `:setup` 里的 `etaf-theme-provide`。

**示例。**

```elisp
(let ((theme (etaf-posframe-theme nil 'dark)))
  (plist-get theme :ui-panel-bg))
```

#### Variable: etaf-posframe-dark-surface

暗色面板表面沉向的中性近黑，默认 `#101214`。

**语义。** 暗色应用画的是平铺的近黑表面，面板按 `etaf-posframe-dark-shade` 沉下去就留在同一族里，而不是把主题色抬成一张灰卡片。想让面板贴着某个应用的底色，就把它设成那个应用的背景色。

#### Variable: etaf-posframe-dark-shade

暗色面板表面往 `etaf-posframe-dark-surface` 沉多少，0 到 1，默认 0.5。

**语义。** 0 保留 frame 自己的暗背景，1 直接取中性近黑。一半既保留暗主题的色相，又跟面板身后的应用读成同一种表面。

#### Variable: etaf-posframe-surface-lift

亮色面板表面往黑沉多少，0 到 0.5，默认 0.03。

**语义。** 亮色面板留一点浅灰，好让它还读得出一层表面，而不是跟白色页面糊在一起。调高会让所有亮色面板更暗，设成 0 则面板与身后的白 buffer 分不开。

#### Variable: etaf-posframe-border-width

frame 边框宽度，0 到 19 像素，`:border` 没给 `:width` 时用它。

**语义。** 一像素、主题边框色的边是把面板与身后的 buffer 分开、让它读成浮层的那个元素。面板的 `:border` 选项可以逐面板覆盖它；写 0 会去掉 frame 边框，标题栏下的细线仍然保留。

#### Variable: etaf-posframe-border-focus-strength

聚焦边框显示多少主题强调色，0 到 1，默认 0.6。

**语义。** 边框是面板表面往主题的 `link` 色混：0 保持表面，1 直接画强调色。面板 `:border` 的 `:focus` 颜色会完全替代这个混合。用混色而不是直接画强调色，一像素的描边在两种调色板里都不会变成一圈饱和的框。

#### Variable: etaf-posframe-border-hover-strength

悬停边框显示多少主题强调色，0 到 1，默认 0.3。

**语义。** 悬停的面板没有拿到键盘，所以它提示强调色的力度要比聚焦时更弱。保持它低于 `etaf-posframe-border-focus-strength`，悬停是提示、点击才是落下，两者才不会混；面板 `:border` 的 `:hover` 颜色会替代这个混合。

## 尺寸与收高

<!-- index: etaf-posframe-default-width; etaf-posframe-default-max-height -->

#### Variable: etaf-posframe-default-width

没有 `:width` 时新面板的列数，默认 56。

**语义。** 这个值是内容列数，不是 frame 宽度：边框、内边距与标题栏都加在它之外。画在固定网格上的面板改传 `:width`，要占父 frame 一定比例的面板传 `(fraction F)`。

**参见。** `etaf-posframe-show`、`etaf-posframe-default-max-height`。

#### Variable: etaf-posframe-default-max-height

没有 `:height` 时新面板最多多少内容行，默认 30。

**语义。** 面板把 frame 收到渲染内容的高度，最多到这个预算，所以短的 View 得到矮面板。必须固定高度的面板（例如固定网格的棋盘）把 `:height` 与 `:fill-height` 一起给，剩下的由表面画出来。

**参见。** `etaf-posframe-show`、`etaf-posframe-default-width`。

## 错误与恢复

<!-- index: etaf-posframe-error; 面板失败 -->

#### Error: etaf-posframe-error

报非法的面板输入与不可用的能力。

**语义。** 每个选项都在 frame 存在之前校验，被拒的显示会先清理再报错：View 卸载、frame 删除。条件数据是一个列表，第一个元素是说明字符串，调用方可以直接拿去显示。

| 失败 | 什么时候报 |
| --- | --- |
| 选项未知 | plist 里有[面板选项](#面板选项)之外的键。 |
| 取值非法 | 开关不是 `t` 或 `nil`，尺寸不是正整数也不在 `(fraction F)` 范围内，`:auto-hide` 不是 `t`、`nil` 或正数秒，`:title` 不是字符串，`:key` 不是符号，或 `:theme` 不是模式、plist、ref、computed。 |
| `:at` 非法 | 取值既不是锚点、锚点加偏移，也不是 `(cells ROW COL)`、`(pixels X . Y)` 或函数。 |
| `:stack` 没有锚点 | `:stack` 非 nil 而 `:at` 是字符格、像素对或 poshandler。 |
| `:border` 非法 | 字段不在 `:width`、`:color`、`:focus`、`:hover` 之内，宽度超出 0 到 19，或颜色不是字符串。 |
| 应用注册不完整 | `etaf-posframe-register-app` 没有 `:create` 或没有 `:view`；注册里的面板选项在开面板时才校验，不在注册时。 |
| 显示环境不支持子 frame | Emacs 跑在不提供 `tty-child-frames` 的终端里。 |

**参见。** `etaf-posframe-show`、`etaf-posframe-register-app`、[标准错误](standard-errors.md)。
