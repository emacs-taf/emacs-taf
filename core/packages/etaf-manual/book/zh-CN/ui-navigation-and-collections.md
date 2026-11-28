# 导航与集合

目录的导航组件让用户在应用里保持方向感：tabs 在视图间切换，breadcrumb 显示回去的路径，steps 显示流程进度，accordion 与 tree 披露嵌套内容。list 呈现可选择的集合，pagination 条驱动 Data Controller 的分页。它们都组合普通按钮与流式布局，把状态放在调用方拥有的值或 ref 里，也不建立第二套焦点或事件系统：键盘行为就是目录的基线，选中项只改变绘制颜色，内边距与字体保持不变，也不用会让整行位移的前缀。受控契约见 [UI 组件库总论](ui-overview.md)，按钮与选中色调见[按钮与选择控件](ui-buttons-and-choice-controls.md)，分页跟随的控制器见[数据控制器](data-controllers.md)，焦点组见[键盘](keyboard.md)。

## item 与状态

<!-- index: navigation items; item key; selected state; caller-owned state -->

导航组件共用一种 item 形状：带唯一非 nil `:key`、非空字符串 `:label` 的 plist，可选的附加项——标量 `:count` 显示在标签旁，符号 `:ref` 让调用方直接寻址那个控件，tree 还有嵌套的 `:children`。list 组件用同样的思路，配 `:title` 与可选 `:description`；tree 的 item 可以携带同样形状的子项。校验对唯一性很严格：重复的键或标签会被拒绝，因为只收到键的回调必须无歧义。

状态归调用方所有。tabs 接收活动键，accordion 接收打开的键列表，tree 接收展开的键列表，pagination 接收 controller；每个组件都通过回调报告下一个状态，而不是自己保存。选择与展开用选中色调绘制——活动 tab、打开的分节、当前步骤——所以状态移动时文本自身宽度不会变化，一排 tab 也不会在指针下跳动。每个集合是一个水平或垂直焦点组，方向键在其中移动，Tab 则离开它。

## tabs、breadcrumb 与 steps

<!-- index: etaf-tabs; etaf-breadcrumb; etaf-steps -->

#### Component: etaf-tabs (&key items active on-change variant framed)

从唯一标量键与标签渲染受控 tabs。

**参数。** ITEMS 是上面描述的 item 列表；item 可带标量 `:count` 与符号 `:ref`。ACTIVE 是选中的键，必须在 ITEMS 中；可以是值或 ref。ON-CHANGE 接收选中的键，必需。VARIANT 是 tab 条的类变体，默认 `underline`。

**语义。** 每个 tab 是 ghost 按钮，选中态使用 secondary 的 Theme 颜色，几何与字体保持不变；计数以 muted 颜色渲染在标签之后，因此 tab 可以显示它含有多少条目。tab 条是水平焦点组，role 为 `tablist`，选中的 tab 带 `:aria-selected`。item 提供 `:ref` 时它命名对应的按钮，调用方可以直接聚焦它。

**返回。** 一个 View。

**错误。** ITEMS 不是键与标签唯一的 item 列表、ACTIVE 不是 ITEMS 中的键、或 ON-CHANGE 不是函数时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-tabs :active tab :on-change #'select-tab
           :items '((:key all :label "All" :count 12) (:key open :label "Open")))
```

**参见。** `etaf-steps`、`etaf-accordion`。

#### Component: etaf-breadcrumb (&key items on-select)

从字符串 ITEMS 渲染导航路径；ON-SELECT 接收从零开始的索引。

**参数。** ITEMS 是非空字符串列表。ON-SELECT 可选；为 nil 时路径是纯文本。

**语义。** 有回调时每个条目是 ghost 按钮，最后一个带 `:aria-current`；条目之间是 muted 的 `/` 标签。路径是水平焦点组，方向键沿路径移动，而不是让 Tab 逐条走过每个面包屑。

**返回。** 一个 View。

**错误。** ITEMS 为空或不是字符串 proper list、或 ON-SELECT 既不是函数也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。** `(etaf-breadcrumb :items '("Home" "Docs" "API") :on-select #'go-to)`

#### Component: etaf-steps (&key items current on-change)

渲染有序步骤按钮。ITEMS 含 `:key` 与 `:label`；CURRENT 与回调由调用方控制。

**参数。** CURRENT 是 ITEMS 中的键，可以是值或 ref。ON-CHANGE 可选，接收选中的键。

**语义。** 每个步骤是显示 `"N  LABEL"` 的按钮，步骤之间是 muted 的 `→`；当前项使用 ghost 按钮的选中色调，内边距与字体保持不变。窗口窄时整行换行，因此长流程重排而不是溢出；它是一个水平焦点组，换行后的各行之间留一行间隙。

**返回。** 一个 View。

**错误。** ITEMS 形式非法、CURRENT 不是 ITEMS 中的键、或 ON-CHANGE 既不是函数也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-steps :current 'account :on-change #'goto-step
            :items '((:key account :label "Account") (:key billing :label "Billing")))
```

```elisp :figure 面包屑与 tabs
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 1)
   (etaf-breadcrumb :items '("手册" "样式" "选择器"))
   (etaf-tabs :items '((:key overview :label "概览")
                       (:key details :label "细节"))
              :active 'overview
              :on-change #'ignore)))
```

## 披露与集合

<!-- index: etaf-accordion; etaf-tree; etaf-list -->

#### Component: etaf-accordion (&key items open on-toggle multiple)

渲染受控的披露分节。item 含 `:key`、`:label` 与字符串或零参函数 `:content`。OPEN 是展开键的列表。

**参数。** OPEN 是 ITEMS 中出现的键的列表。ON-TOGGLE 接收下一个打开的键列表，必需。MULTIPLE（默认 t）允许多个分节同时打开。

**语义。** 每个分节是 ghost 按钮，打开时显示向下的展开图标，关闭时显示向右的图标，随后是它的内容。可访问名称始终等于 item 标签，展开状态通过 `:aria-expanded` 表达。MULTIPLE 为 nil 时下一个列表至多含一个键；OPEN 会按 item 键与单开规则校验，所以调用方无法让组件停在自相矛盾的状态。

**返回。** 一个 View。

**错误。** ITEMS 形式非法、OPEN 不是 item 键的列表（或 MULTIPLE 为 nil 时含多个键）、某个 `:content` 既不是字符串也不是函数、MULTIPLE 不是布尔量、或 ON-TOGGLE 不是函数时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-accordion :open open :on-toggle (lambda (next) (setq open next)) :multiple nil
                :items '((:key a :label "Details" :content "Body")))
```

#### Component: etaf-tree (&key items expanded on-toggle on-select)

渲染嵌套 item，展开键与选择回调归调用方所有。

**参数。** ITEMS 是非空 tree item 列表；每项可带同形状的 `:children`。EXPANDED 是打开的键列表，可以是值或 ref。ON-TOGGLE 接收一个键或下一个展开列表；ON-SELECT 接收一个键。两个回调都可以为 nil。

**语义。** tree 把可见项摊平成行：每层缩进两个空格，分支前显示向下或向右的展开图标。分支行带 `:aria-expanded`，按压切换；叶子行按压选择。Right 打开、Left 关闭聚焦的分支，经方向通道就地生效，因此键盘可以走遍层级而不激活行。展开的分支用选中色调，整棵树是一个垂直焦点组。

**返回。** 一个 View。

**错误。** ITEMS 为空或形式非法、EXPANDED 不是 proper list、或某个回调既不是函数也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-tree :expanded expanded :on-toggle #'toggle-node :on-select #'open-file
           :items '((:key src :label "src"
                          :children ((:key main :label "main.el")))))
```

**参见。** `etaf-list`。

#### Component: etaf-list (&key items on-select checkbox selected)

渲染可选择列表。ITEMS 含 `:key`、`:title` 与可选 `:description`；选择报告给 ON-SELECT。

**参数。** 键唯一，标题是非空字符串；空列表允许。ON-SELECT 可选；List 不创建选择状态。

**语义。** 每行是一个拉伸的 ghost 按钮，标签是标题，描述在下一行。列表是垂直焦点组，方向键在行间移动，每行保留完整的目录按钮行为——指针、帮助文本、激活，以及经由所组合按钮的禁用支持。

**返回。** 一个 View。

**错误。** ITEMS 不是由唯一键、非空字符串标题与可选字符串描述构成的 item proper list、或 ON-SELECT 既不是函数也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-list :on-select #'open-item
           :items '((:key a :title "Alpha" :description "first")
                    (:key b :title "Beta")))
```

## 分页

<!-- index: etaf-pagination; controller pager; page summary -->

#### Component: etaf-pagination (&key controller previous-ref next-ref previous-label next-label class color bgcolor border padding aria-label)

渲染受控分页条，其回调跟随已提交的 CONTROLLER。

**参数。** CONTROLLER 是[数据控制器](data-controllers.md)；为 nil 时分页条显示安全的空状态（第 1 页共 1 页、无条目）。PREVIOUS-REF 与 NEXT-REF 命名两个按钮。PREVIOUS-LABEL 与 NEXT-LABEL 覆盖完整的按钮标题。CLASS、COLOR、BGCOLOR、BORDER 与 PADDING 覆盖表面，ARIA-LABEL 默认 `"Pagination"`。

**语义。** 分页条读取 controller 的页码、每页条数、总数与状态。它在边界处、以及加载或刷新进行时禁用相应按钮；按压按钮经 `etaf-data-previous-page` 与 `etaf-data-next-page` 前进或后退 controller。中央上方显示 `"Page X / Y"`，下方显示 `"A–B of T"`（当前显示条目的范围），用 `:ui-pagination-muted-fg` 绘制。整条是 `navigation` role 下的可换行 row，窄窗口里重排而不是裁剪。

**返回。** 一个 View。

**错误。** 分页条组合普通按钮；除了它转发的标签与引用，没有额外校验的 prop。

**示例。**

```elisp
(etaf-pagination :controller controller :previous-ref 'prev :next-ref 'next)
```

**参见。** `etaf-data-next-page`、`:ui-pagination-muted-fg`。

## 分页 token

<!-- index: ui-pagination-muted-fg; page summary color -->

#### Token: :ui-pagination-muted-fg

分页摘要行的颜色。

**语义。** `"A–B of T"` 范围用这个颜色，而页码计数保持默认前景，因此精确范围读作辅助细节。分页条自带内置回退值，所以没有提供 Theme 时也能绘制。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的输入，消息点名组件、属性、收到的值与期望：重复的键或标签、不在 item 中的活动或当前键、键不属于 item 的打开列表、非法的分节内容，以及必需回调位置的非函数值。
- 选择从不修改调用方的值：回调接收下一个键或键列表，由应用保存；被拒绝或被忽略的变化让组件继续显示先前状态。
- tree 的 Right/Left 在聚焦行不是分支、或所请求动作不会带来变化时返回 `release`，方向键因此落回外层布局而不是被吞掉。
- 没有 controller 的分页条不是错误：它渲染空状态并让按钮保持禁用。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[数据控制器](data-controllers.md)。

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-tabs :active 'all :on-change #'ignore
              :items '((:key all :label "All" :count 12) (:key open :label "Open")))
   (etaf-list :on-select #'ignore
              :items '((:key a :title "Alpha" :description "first")
                       (:key b :title "Beta")))))
```
