# 数据展示

目录用四种形态呈现数据：表格呈现列与行，数据网格把表格裹在活的 Data Controller 上，头像代表一个人或实体，时间线呈现事件序列，日历呈现一个月。表格家族是表现式的：它不拥有加载、数据库、分页或选择状态，由调用方提供行以及可选受控交互。头像、时间线与日历是普通的展示组件。受控契约见 [UI 组件库总论](ui-overview.md)，网格跟随的控制器见[数据控制器](data-controllers.md)，token 见[组件样式与主题](component-styles-and-themes.md)，表格铺放格子的轨道见 [Grid 布局](grid-layout.md)。

## 表格与行

<!-- index: table columns; row shapes; cell function; fixed width; keyed identity -->

表格由列与行定义。每列带唯一非 nil `:key`、可选表头 `:label`、可选 `:width`——整数表示字符容量，`(fr N)` 按正权重分享剩余宽——以及可选 `:cell` 函数，接收一行并返回普通 View 内容。没有 `:cell` 时，列的 key 从行里读字段，行可以是带关键字键的 plist、alist 或 hash table。

行保留应用对象的身份：稳定的 `:row-key` 函数为调和器命名每一行，因此返回组件里的 cell 状态能跨插入、重排与替换存活，替换行也仍会更新它捕获的回调。交互可选且受控：有 `:on-row-press` 回调时行成为带 Tab 序号与按压回调的按钮，`:row-ref` 在应用需要时提供调用方地址，`:row-selected-p` 用选中前景与背景绘制行。表格自身从不保存选择或页码。

固定正字符宽的列走快速路径：每个表头与每行是一个补齐的文本 Host，让每行保持单行且宽度精确。其它列共享 grid 布局，所以分数列可以随视口重排，而固定列保持各自容量。

## 表格组件

<!-- index: etaf-table; presentational table -->

#### Component: etaf-table (&key columns rows row-key row-ref on-row-press row-selected-p)

把普通 ROWS 渲染为表现式表格。

**参数。** COLUMNS 是上面描述的列列表。ROWS 是支持形状之一的行列表；`:row-key` 是必需的单参函数，返回行的稳定身份。`:row-ref` 是可选的单参函数，为每行返回非 nil 的调用方地址；`:on-row-press` 在该行被激活时收到行；`:row-selected-p` 决定每行的选中绘制。交互与选择是受控输入；表格不拥有应用或 Data Controller 状态。

**语义。** 表头在 `:ui-table-border` 细线下方渲染列标签；每个正文行画同样的细线并渲染各列格子。固定字符宽产出每行一个补齐的文本 Host，其它宽度走 grid；自定义 cell 函数在消费位置运行，其组件输出保留自己的 Context、样式、状态与生命周期。表体是一个垂直焦点组，方向键在可交互行之间移动。没有 `:on-row-press` 回调的表格是纯表现式的，不增加焦点目标。

**返回。** 一个 View。

**错误。** 报点名列、行或键的普通 `error`：重复的列 key、不是函数的 `:cell`、不是函数的 row key、或权重非正的 `(fr N)` 宽度。非法宽度被 grid 拒绝时还会以 Ebox 的 `error→ ebox-error` 出现。

**示例。**

```elisp
(etaf-table :columns '((:key :name :label "Name" :width 10)
                       (:key :size :label "Size" :width 6))
            :rows '(((:name . "main.el") (:size . "12K")))
            :row-key (lambda (row) (cdr (assq :name row)))
            :on-row-press #'open-file)
```

**参见。** `etaf-data-grid`、`etaf-list`。

## 数据网格

<!-- index: etaf-data-grid; controller states; status labels -->

#### Component: etaf-data-grid (&key controller columns row-key on-row-press row-ref row-selected-p loading-label error-label empty-label)

通过公共 Component DSL 渲染 DATA CONTROLLER 状态。

**参数。** CONTROLLER 是[数据控制器](data-controllers.md)。COLUMNS、ROW-KEY、ROW-REF、ON-ROW-PRESS 与 ROW-SELECTED-P 遵循 `etaf-table`，其中 ROW-SELECTED-P 可以与 controller 自己的选择组合。LOADING-LABEL、ERROR-LABEL 与 EMPTY-LABEL 覆盖状态文本。

**语义。** 网格显示 controller 的 idle、loading、refreshing、cancelled、error 与 empty 状态。行上方显示状态标签：refreshing 用 LOADING-LABEL（`"Refreshing..."`），取消用 ERROR-LABEL（`"Loading cancelled."`），单纯的 loading 也用同一个 LOADING-LABEL。正文在条目出现后显示行，否则显示状态标签——idle 为 `"Not loaded."`、空成功为 `"No data."` 或 EMPTY-LABEL、失败为错误文本。错误与取消文本用 `:ui-data-grid-error-fg` 绘制。accepted rows 在待决或失败操作期间保持可交互；网格保留每行的键身份与自定义 cell 状态，footer slot 在正文下方组合。

**返回。** 一个 View。

**错误。** `etaf-table` 的列、row-key 与选择契约；controller 自己的错误从其加载路径传播。

**示例。**

```elisp
(etaf-data-grid :controller controller
                :columns '((:key :name :label "Name"))
                :row-key (lambda (row) (plist-get row :id))
                :empty-label "No records")
```

**参见。** `etaf-table`、`:ui-data-grid-error-fg`。

## 头像组件

<!-- index: etaf-avatar; initials; round photo; background color -->

#### Component: etaf-avatar (&key name initials src size variant lines background shape)

渲染带语义颜色与可访问名的紧凑头像。

**参数。** NAME 是可访问名与首字母的默认来源。INITIALS 覆盖推导出的首字母。SRC 是可选照片：本地图片文件或 Emacs 图像描述符。SIZE 是宽度，默认 `(ch 5)`；圆形头像也接受整数列数。LINES 是以文本行为单位的正整数高度，默认 3。VARIANT 选择语义色对。BACKGROUND 用该底色的白字替代 VARIANT，用于按人上色。SHAPE 是 `circle`（默认）或 `square`。

**语义。** 没有 INITIALS 时取 NAME 前两字符并大写；NAME 与 INITIALS 都没有时显示 `?`。有 SVG 的图形 frame 上，圆形头像把照片裁剪成圆盘，没有可读照片时把首字母画在彩色圆盘上；`square` 与文本 frame 用首字母盒子，文本落在其高度的上中线上。圆形图像按来源与格子尺寸缓存，因此调用方应传 `equal` 稳定的来源。整个盒子带 `img` role，并用 NAME 作为可访问标签。

**返回。** 一个 View。

**错误。** SHAPE 既不是 `circle` 也不是 `square` 时报 `error→ etaf-component-call-error`；LINES 非正时抛原生 `wrong-type-argument (natnump)`。

**示例。**

```elisp
(etaf-avatar :name "Ada Lovelace" :size '(ch 3) :lines 2 :variant 'success)
```

## 时间线组件

<!-- index: etaf-timeline; event stream; status badge -->

#### Component: etaf-timeline (&key items)

渲染含 `:title`、`:content` 与 `:status` 的按时间排列的 item plist。

**参数。** ITEMS 是非空 item plist 列表。`:status` 是作为 badge 显示的可选字符串，默认 `"Update"`；`:title` 与 `:content` 是两行文本。

**语义。** 每个条目是一行：info badge 承载状态，旁边一列是 strong 标题压在 muted 内容之上，因此一次发布、提交或评论读作纵向序列里的一个事件。列表是表现式的，不拥有时间顺序、过滤或分页。

**返回。** 一个 View。

**错误。** ITEMS 不是非空 item plist 列表时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-timeline :items '((:status "v1.2" :title "Release" :content "Shipped")
                        (:title "Commit" :content "Fixed the parser")))
```

## 日历组件

<!-- index: etaf-calendar; month grid; selected day -->

#### Component: etaf-calendar (&key month value on-change label)

渲染受控的月网格；MONTH 是 `(YEAR MONTH)`，ON-CHANGE 收到 `(YEAR MONTH DAY)`。

**参数。** MONTH 是 `(YEAR MONTH)` 列表，月从 1 到 12，默认 `(2026 1)`，不是当前月份；应显式传入所需月份。VALUE 是选中的整数日号或 nil（默认），不是完整日期或 ref。ON-CHANGE 可选，默认 nil，接收一个 `(YEAR MONTH DAY)` 列表；调用方取其日号更新 VALUE，也可单独更新 MONTH。LABEL 默认 `"Calendar"`，在表头里位于月份名之前。

**语义。** 网格以 muted 标签显示周一到周日，并把当月每一天渲染为两位宽按钮；选中的天用 ghost 按钮的选中色调并带 `:aria-selected`。星期标题、日期按钮与前导空格都占四个字符宽度，每个日期始终位于对应的星期下，选择变化不会改变列位置或字体。日历是一个 `grid` role 的焦点组，方向键在日期间移动，按钮保留可访问的日期标签。组件不拥有月份导航：由调用方修改 MONTH 与 VALUE。

**返回。** 一个 View。

**错误。** MONTH 不是月份合法的 `(YEAR MONTH)` 列表、VALUE 既不是整数也不是 nil、或 ON-CHANGE 既不是函数也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-calendar :month '(2026 1) :value 15
               :on-change (lambda (date) (setq selected date)))
```

## 数据展示 token

<!-- index: ui-table-border; ui-table-selected-fg; ui-data-grid-error-fg -->

#### Token: :ui-table-border

表头与每个表格行下方的细线。

**语义。** 表格、数据网格的表头与行，以及其它基于行的表面共享它，因此无论格子由哪个组件产出，表格都读作同一张网格。

#### Token: :ui-table-selected-fg

选中表格行的前景。

#### Token: :ui-table-selected-bg

选中表格行的背景。

**语义。** 与 `:ui-table-selected-fg` 一起构成行在 `:row-selected-p` 或数据网格的选择生效时使用的选中对。

#### Token: :ui-data-grid-error-fg

数据网格失败或取消时的文本颜色。

**语义。** 行上方的状态标签与正文的错误标签都用它绘制，而信息性状态保持 muted；读取它的组件自带内置回退值。

#### Component: etaf-braille-chart (&key values width height min max label ref)

把 VALUES 画成盲文折线图，宽 WIDTH 格、高 HEIGHT 格。

**参数。** VALUES 是数值序列；WIDTH 默认 40，HEIGHT 默认 6；MIN 与 MAX 固定刻度，不给时用序列自己的范围；LABEL 是图表上方的标题；REF 让调用方按名字寻址。

**返回。** 一个 ETAF Component。

**语义。** 每个字符格子内含 2×4 的点阵，所以图表在垂直方向的分辨率是行数的四倍。序列没有经过的点保持空白，正是它让线看起来细。它不画坐标轴，刻度由 MIN 与 MAX 定义，读数是相对形状而不是精确数值。

**参见。** `etaf-table`、`etaf-timeline`。

## 错误与恢复

- 表格家族把契约错误报告为点名列、行或键的普通 `error`——重复的列 key、非函数的 cell 或 row key、错误的分数权重——因为它们是调用方数据里的编写错误而不是响应式输入；Ebox 拒绝布局值时，数据网格还会透出 Ebox 自己的 `ebox-error`。
- 选择与交互是受控的：被拒绝或被忽略的按压不改变表格里的任何东西，调用方的行对象也从不被修改。
- 刷新失败或被取消时数据网格保留屏幕上已接受的行，因此一次短暂的后端错误不会清空视图；只有状态文本改变。
- 日历与头像不拥有状态：非法输入让调用失败，并让已挂载实例保持原样。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[数据控制器](data-controllers.md)。

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-table :columns '((:key :name :label "Name" :width 10)
                          (:key :size :label "Size" :width 6))
               :rows '(((:name . "main.el") (:size . "12K"))
                       ((:name . "util.el") (:size . "4K")))
               :row-key (lambda (row) (cdr (assq :name row)))
               :on-row-press #'ignore)
   (etaf-avatar :name "Ada Lovelace" :size '(ch 3) :lines 2)))
```
