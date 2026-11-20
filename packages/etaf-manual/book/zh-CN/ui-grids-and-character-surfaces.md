# 格子与字符表面

三个目录组件为应用提供固定几何的字符表面：格子网格把坐标回调投影到格子里，文本网格由独立保留的定宽文本行组成，扑克牌的内在尺寸永不被拉伸去填满视口。它们拥有布局与激活，从不拥有调用方的棋盘、棋盘状态、定时器或游戏规则，尺寸也始终保持调用方声明的值，即使窗口变化。[图片](images.md)定义格子使用的图像 Host，[UI 组件库总论](ui-overview.md)定义共同契约，[Grid 布局](grid-layout.md)定义底层轨道模型。

## 格子网格

<!-- index: etaf-tile-grid; coordinate callbacks; fixed cells; cell image -->

#### Component: etaf-tile-grid (&key rows columns cell-width cell-height cell-background cell-color cell-text cell-label cell-image cell-ref on-cell-press on-cell-focus)

渲染 ROWS 乘 COLUMNS 个带稳定坐标身份的固定格子。

**参数。** ROWS 与 COLUMNS 是正整数；CELL-WIDTH（字符列，默认 2）与 CELL-HEIGHT（文本行，默认 1）是正整数，视口变化时保持固定。回调接收从零开始的行与列：CELL-BACKGROUND 返回颜色或 nil；CELL-COLOR 提供前景（nil 继承）；两者都可以返回延迟 Theme token。CELL-TEXT 返回适配 CELL-WIDTH 的单行（默认一个空格）。CELL-IMAGE 返回本地文件路径、Emacs 图像描述符（包括生成的 SVG）或 nil——图像经 image Host 填满固定格子，nil 改用 CELL-TEXT，来源解码失败用 image Host 的占位。CELL-LABEL 返回可访问名与帮助文本（默认 `"Cell r,c"`）。CELL-REF 为每格返回不同的 Host 引用；省略时引用为实例本地。ON-CELL-PRESS 处理键盘与鼠标激活，没有它时格子只读；ON-CELL-FOCUS 在焦点进入格子时报告坐标。

**语义。** 网格拥有布局与激活，不拥有棋盘状态或定时器：它在回调里读取调用方的 ref，未变的格子因此保留内容，也从不维护第二份选择。有按压回调时每个格子都是 `grid` 焦点组里带 Tab 序号的 `button`；没有时格子是惰性的。格子裁剪隐藏溢出并居中内容，焦点描边标记聚焦的格子。

**返回。** 一个 View。

**错误。** ROWS、COLUMNS、CELL-WIDTH 或 CELL-HEIGHT 不是正整数、或某个坐标回调既不是函数也不是 nil 时报 `error→ etaf-component-call-error`。CELL-TEXT 或 CELL-LABEL 不是适配格宽的单独一行时也在渲染期报错。

**示例。**

```elisp
(etaf-tile-grid :rows 8 :columns 12 :cell-width 2 :cell-height 1
                :cell-text (lambda (_r _c) ".")
                :on-cell-press (lambda (row column) (select-cell row column)))
```

**参见。** `etaf-text-grid`、[图片](images.md)。

## 文本网格

<!-- index: etaf-text-grid; fixed-width rows; monospace surface; scrolling text grid; large row counts -->

#### Component: etaf-text-grid (&key rows columns row-text row-ref label height ref on-scroll)

显示 ROWS 个固定文本行，每行 COLUMNS 个字符列宽。

**参数。** ROWS 与 COLUMNS 是正整数。ROW-TEXT 是必需回调，接收从零开始的行号；它返回显示宽度不超过 COLUMNS 的单行字符串，短行用空格补齐。ROW-REF 可选，为每行返回不同的 Text Host 引用以做保留内容更新——那些更新同样必须适配并补齐到 COLUMNS，且与回调状态保持同步。LABEL 命名这个只读表面（默认 `"Text grid"`）。HEIGHT 是正整数或 nil（默认），表示表面在滚动视口中显示的行数。REF 命名表面 Host，供 `etaf-scroll-to`、`etaf-scroll-by` 与 `etaf-scroll-offset` 使用；省略时网格使用实例内部引用。ON-SCROLL 是 nil 或函数，视口移动后以第一个可见行调用。

**语义。** 每行保留稳定身份与自己的保留边界，因此一行文本变化只重绘一行而不是整个表面。组件没有焦点目标、输入处理、定时器或终端转义解释；它是等宽展示，宽字符按 Emacs 显示宽度占位。拥有更细粒度身份的调用方用这种逐行保留来替代一个大文本宿主。

没有 HEIGHT 时构建并显示每一行。有 HEIGHT 时表面是 HEIGHT 行的滚动 Host，只构建视口附近的行；两个占位块代表上方与下方的行，所以内容保持完整高度，而挂载、滚动与重绘视口的开销与 ROWS 无关。ROW-TEXT 只为已构建的行运行，它读取的 ref 变化也只重绘这些行。视口离开已构建范围时，网格重建视口周围的行，仍在范围内的带键行保留。滚轮、滚动键以及对 REF 调用 `etaf-scroll-to`/`etaf-scroll-by` 移动视口；`etaf-scroll-offset` 与 ON-SCROLL 报告第一个可见行，`etaf-scroll-to` 越过末尾时停在最后一个完整视口。改变 ROWS 会重建范围：超出新末尾的视口移到最后几行。要横向滚动列，把首列放在 ROW-TEXT 读取的 ref 中；改变它会重绘可见行。

**返回。** 一个 View。

**错误。** ROWS 或 COLUMNS 不是正整数、ROW-TEXT 不是函数、ROW-REF 既不是函数也不是 nil、LABEL 不是字符串、HEIGHT 既不是 nil 也不是正整数、或 ON-SCROLL 既不是 nil 也不是函数时报 `error→ etaf-component-call-error`。渲染期行内容不是字符串、含换行、回车或制表符、或宽于 COLUMNS 时报同一条件并点名 ROW-TEXT。

**示例。**

```elisp
(etaf-text-grid :rows 24 :columns 80 :row-text (lambda (row) (buffer-line row)))
```

一个在 30 行视口中滚动、并报告第一个可见行的长日志：

```elisp
(etaf-text-grid :rows 1000000 :columns 80 :height 30 :ref 'log
                :row-text (lambda (row) (format "%7d  entry" row))
                :on-scroll (lambda (row) (message "Row %d" row)))
```

**参见。** `etaf-tile-grid`。

## 扑克牌

<!-- index: etaf-playing-card; card face; pile placeholder; intrinsic size -->

#### Component: etaf-playing-card (&key rank suit face-down empty selected disabled on-press label ref columns lines)

把受控的扑克牌或空牌堆占位呈现为单一激活目标。

**参数。** RANK 是最多三列的单行字符串；SUIT 是 `spades`、`hearts`、`clubs`、`diamonds` 或 nil。FACE-DOWN 隐藏点数与花色，包括生成的可访问名。EMPTY 呈现空牌堆占位。SELECTED 只改变绘制而不改变几何。COLUMNS 默认 9、最小 7，LINES 默认 5、最小 1；一行只露出叠牌中的牌角。这些内在尺寸从不拉伸填满视口。ON-PRESS 不收参数；省略或禁用的牌不可交互。LABEL 覆盖可访问名与帮助，因此调用方不得把隐藏信息写在那里。

**语义。** 牌是一个以格为单位定尺寸的居中按钮：左上角是点数与花色符号，中央是花色标记（背面时画 `◇`），超过三行高时右下角再出现一个角标。颜色来自扑克牌 token——默认底是暖象牙色，花色墨色黑或红，背面用蓝色，空堆用弱化占位色，选中用琥珀底色，悬停有反馈——因此游戏可以通过自己的 Theme 给整张牌桌换装。悬停保留全部文字并覆盖整张牌的绘制区域；牌背和空牌堆从自身底色派生轻微变化，不套用正面的悬停底色；选中的牌不再叠加悬停色。选择、叠放、移动与规则归调用方所有，也不需要任何游戏后端。

**返回。** 一个 View。

**错误。** RANK 既不是 nil 也不是最多三列的单行字符串、SUIT 不是四种花色之一或 nil、COLUMNS 小于 7、或 LINES 小于 1 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-playing-card :rank "A" :suit 'hearts :on-press #'play-card)
```

## 扑克牌 token

<!-- index: ui-playing-card-bg; ui-playing-card-red; ui-playing-card-back-bg -->

#### Token: :ui-playing-card-bg

普通牌的牌面底色。

#### Token: :ui-playing-card-black

黑桃或梅花牌的墨色。

#### Token: :ui-playing-card-red

红桃或方块牌的墨色。

#### Token: :ui-playing-card-back-bg

背面牌的背景。

#### Token: :ui-playing-card-back-fg

背面牌的前景。

**语义。** 这一对绘制盖住的牌；背面牌绝不通过绘制、文本或可访问名泄漏点数与花色。

#### Token: :ui-playing-card-empty-bg

空牌堆占位的背景。

#### Token: :ui-playing-card-empty-fg

空牌堆占位符号的颜色。

#### Token: :ui-playing-card-selected-bg

选中牌的背景。

#### Token: :ui-playing-card-hover-bg

可交互牌的悬停浅色。

**语义。** 选中与悬停都只是绘制——牌的几何与牌堆的布局从不移动——没有提供 Theme 时每个 token 都回退到目录的内置调色板。

## 单元格表格

<!-- index: etaf-sheet; etaf-cell-line; 电子表格; 单元格网格; 列宽; 行高; 选区; 单元格编辑 -->

#### Function: etaf-cell-line (cells &key (stripe 'px) border-color rule rule-color leading-edge)

返回一行单元格的带样式文本。

**参数。** CELLS 是单元格 plist 的列表。`:width` 是内容宽度（字符数，必需）；`:text` 是单元格的单行文本；`:align` 是 `left`（默认）、`right` 或 `center`；`:face` 是叠加在文本上的 face 或 face plist；`:edge` 是该单元格之后分隔线的颜色。STRIPE 为 `px`（默认）或 `glyph`：一像素宽的空格加背景，或无法绘制像素的终端上的框线字符。BORDER-COLOR 是没有 `:edge` 的单元格使用的分隔线颜色。给定 RULE 时整行带 RULE-COLOR 颜色的底线，LEADING-EDGE 在第一个单元格之前再加一条该颜色的分隔线。

**语义。** 每个单元格左右各留一个空格，在宽度内对齐，超宽文本被截断。单元格之间用 Ebox 盒子侧边框那样的竖线分隔，行尾用盒子的下划线收尾。因此选区填充能到达竖线、两格之间不会出现半格缝隙，而一行单元格只花一个文本 Host，而不是每格两个 Host。画笔自身没有状态、滚动和交互：由上层决定显示哪些单元格、每格写什么。

**返回。** 带属性的字符串。`etaf-cell-line-width` 返回它的字符宽度。

**错误。** 单元格列表不是正规列表、宽度不是非负整数、文本不是字符串或含换行、回车、制表符，或对齐方式不是 `left`、`right`、`center` 时，在绘制之前报错。

**示例。**

```elisp
(etaf-cell-line (list (list :width 8 :text "Item 1")
                      (list :width 5 :text "38" :align 'right))
                :border-color "#687386" :rule t :rule-color "#687386")
```

#### Function: etaf-cell-line-width (cells)

返回一行 CELLS 的字符宽度，含分隔线。

**参数。** CELLS 与 `etaf-cell-line` 绘制的单元格列表相同。

**语义。** 计数包含每格的左右留白和每格之后的一条分隔线，便于上层在绘制前确定 Host 尺寸。

**返回。** 一个整数。

**错误。** 与 `etaf-cell-line` 相同的单元格校验。

#### Component: etaf-sheet (&key rows columns widths heights version cell-text cell-face cell-align header row-head cursor region height editing cell-edit-text colors on-commit on-edit-cancel on-resize-column on-resize-row keys label ref)

把调用方拥有的单元格网格显示为可滚动的表格。

**参数。** ROWS 与 COLUMNS 是表格尺寸。WIDTHS 是各列内容宽度的向量（字符数），或保存它的响应式来源。CELL-TEXT 以行、列调用并返回该格单行文本；CELL-FACE 返回叠加在该格文本上的 face；CELL-ALIGN 返回 `left`（默认）、`right` 或 `center`。HEIGHTS 是行到额外行数的 eql 哈希，用于少数超过一行的行；VERSION 是调用方在改变单元格文本后递增的可写 ref。CURSOR 是活动单元格 `(ROW . COL)` 的可写 ref，REGION 是选区另一角的可写 ref，HEIGHT 是可见主体的行数。HEADER 与 ROW-HEAD 绘制列字母和行号：`t` 使用内置命名，函数按索引返回名称，nil 表示不画。EDITING 是正在编辑的单元格的可写 ref；CELL-EDIT-TEXT 提供编辑起始文本（默认 CELL-TEXT），ON-COMMIT 在提交后收到 `(ROW COL TEXT)`，ON-EDIT-CANCEL 收到被放弃的文本。ON-RESIZE-COLUMN 在拖动列头后收到 `(COLUMN WIDTH)`，ON-RESIZE-ROW 在拖动行号后收到 `(ROW LINES)`。COLORS 覆盖绘制用的颜色 plist，KEYS 在表格自带按键之前追加 `(KEY COMMAND LABEL)`，LABEL 命名网格，REF 命名表格 Host。

**语义。** 表格拥有视口：构建哪些行列、滚动位置和指针落在哪一格。它不拥有单元格，所以公式、格式、撤销和持久化都留在调用方的模型里；画出的每格都来自 CELL-TEXT，每次改动都经回调返回。每个可见行用 `etaf-cell-line` 构建一个文本 Host，因此挂载、滚动和重绘的成本跟随视口而非表格规模；只有被编辑的那一格成为独立 Host，即表格聚焦的 `etaf-text-input`。方向键移动光标，Shift 加方向键扩展选区，F2 与 RET 开始编辑，横向滚轮滚动列。提供对应回调时，拖动列头改变列宽，拖动行号改变行高。颜色取目录调色板（`:ui-table-border`、`:ui-table-selected-bg`、`:ui-table-selected-fg`、`:ui-panel-bg`、`:ui-muted-fg`、`:ui-accent`），深色框架使用表格自带的深色配色，COLORS 可覆盖两者。文本终端用框线字符代替一像素竖线。

**返回。** 一个 View。

**错误。** ROWS、COLUMNS 或 HEIGHT 不是正整数，WIDTHS 既不是向量也不是响应式来源，CELL-TEXT 不是函数，CELL-ALIGN、CELL-FACE、ON-EDIT-CANCEL、ON-RESIZE-COLUMN 或 ON-RESIZE-ROW 既不是 nil 也不是函数，HEIGHTS 既不是 nil 也不是哈希表，CURSOR 不是可写 ref，REGION 或 EDITING 既不是 nil 也不是可写 ref，ON-COMMIT 不是函数，HEADER 或 ROW-HEAD 不是 nil、`t` 或函数，KEYS 或 COLORS 不是列表时，报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-sheet :rows 1000 :columns 6 :widths widths :height 20
            :cursor cursor :region region :editing editing
            :cell-text read-cell :cell-align (lambda (row col) 'right)
            :header t :row-head t :ref 'orders
            :on-commit write-cell
            :on-resize-column (lambda (col width) (setf (aref widths col) width)))
```

#### Function: etaf-sheet-begin-edit (runtime ref editing cell)

在已挂载 RUNTIME 的表格 REF 中开始编辑 CELL。

**参数。** EDITING 是表格作为 `:editing` 接收的可写 ref；REF 是表格稳定的 `:ref`，因为编辑器 Host 以 REF 的 `-editor` 伴生名寻址。CELL 是要编辑的单元格。

**语义。** 设置 EDITING 并启动字段的原生编辑会话。应在命令或按键处理函数中调用，且不在响应式批次内，这样编辑行先发布、字段再取得焦点。这就是 Excel 的「直接打字替换单元格」所需的入口。

**返回。** 字段的引用；表格或编辑器未挂载时为 nil。

**参见。** `etaf-sheet-reveal`、`etaf-sheet-scroll`。

#### Function: etaf-sheet-reveal (runtime &optional ref)

滚动已挂载 RUNTIME 的表格 REF，使光标单元格可见。

**参数。** REF 默认 `etaf-sheet`。

**语义。** 表格自己的按键与指针拖动已经会揭示光标；在应用代码里移动 `:cursor` 之后调用它，例如「跳转到单元格」命令或恢复会话。

**返回。** 分发结果。

#### Function: etaf-sheet-cell-at (runtime ref x y)

返回已挂载 RUNTIME 的表格 REF 中像素 X、Y 处的单元格 `(ROW . COL)`。

**参数。** X 与 Y 是窗口像素，与指针手势报告的值相同。REF 指定表格。

**语义。** 位置落在表格边框区域或表格之外时返回 nil，应用据此区分「按在单元格上」与「按在旁边的边框上」，用于右键菜单、提示或拖放目标。表格自身的按压使用同一套映射，GUI 检查脚本 `scripts/etaf-ui-sheet-gui.el` 会在已挂载的表格上验证它。

**返回。** 行列组成的 cons，或 nil。

#### Function: etaf-sheet-scroll (runtime &optional ref lines)

把已挂载 RUNTIME 的表格 REF 滚动 LINES 行，负数向上。

**参数。** REF 默认 `etaf-sheet`。LINES 默认一页，即表格可见主体高度。

**语义。** 滚动只移动视口，所以翻页的应用同时移动 `:cursor` ref 并揭示它。用于翻页键或没有滚动条的「跳到某行」；表格的指针滚轮与方向键不需要它。

**返回。** 分发结果。


## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的输入：非正的尺寸、不是函数的回调、不是适配列宽的单独一行的行内容、过宽的点数、未知花色以及窄于七列的牌。
- 网格不拥有可回滚的状态：被拒绝的回调结果让渲染失败，此前发布的格子或行留在屏幕上。
- 无法解码的格子图像走 image Host 的占位路径而不是让网格失败；nil 图像直接回退到格子文本。
- 扑克牌是纯呈现：按压只报告给调用方，被忽略的按压让牌保持原样。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[图片](images.md)。

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-tile-grid :rows 2 :columns 4 :cell-width 3 :cell-height 1
                   :cell-text (lambda (row column) (format "%d%d" row column))
                   :on-cell-press #'ignore)
   (etaf-playing-card :rank "A" :suit 'hearts :on-press #'ignore)))
```
