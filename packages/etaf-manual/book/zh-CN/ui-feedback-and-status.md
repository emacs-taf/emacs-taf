# 反馈与状态

反馈组件承载简短而语义化的消息：label 陈述一个值，badge 或 tag 标记它，keycap 记录快捷键，进度条度量它，alert 或空状态解释它，skeleton 为它预留空间。它们都是表现式、无状态的——值、可见性与反应归应用所有——并共享同一套颜色词汇：语义 variant 选择组件绘制用的前景、背景与边框。[UI 组件库总论](ui-overview.md)定义目录的共同契约，[容器](ui-containers.md)定义这些组件通常所在的表面，[组件样式与主题](component-styles-and-themes.md)定义 variant 如何经主题 token 解析。

## 语义 variant

<!-- index: variant; status colors; neutral; feedback triple -->

variant 命名的是语义角色而不是颜色。状态 variant `success`、`warning`、`danger` 与 `info` 映射到 [组件样式与主题](component-styles-and-themes.md)中定义的 `:ui-success-*`、`:ui-warning-*`、`:ui-danger-*`、`:ui-info-*` 三件套；`neutral`（有默认值的地方的默认）映射到基础 `:ui-fg`、`:ui-bg`、`:ui-border`。绘制某个 variant 的组件从第一个键取前景、第二个取背景，需要画框或画线时从第三个取边框。

因为每个键都经延迟 token 解析，提供一次 Theme 就能重绘子树里所有带 variant 的组件而不重渲染。这些组件大多不拒绝未知 variant 符号：它们回退到中性三件套，并把符号并入组件的类名，让调用方自己的 variant 词汇也能通过静态规则使用。

## label 组件

<!-- index: etaf-label; label variant; text payload -->

#### Component: etaf-label (&key text variant)

用普通 Box 布局渲染语义 label 里的 TEXT。

**参数。** TEXT 是值、ref 或 computed：nil 渲染为空，字符串保留其文本属性，其它值用打印形式。VARIANT 是 `default`、`muted`、`danger`、`success`、`strong` 或 `heading`；`strong` 与 `heading` 用字重强调，同时保留继承的字号。调用传入颜色 prop 时会覆盖 variant 的颜色，与任何传给单根 Component 的 Host 属性一样。

**语义。** label 是普通 Box，其 Text 子节点从它继承排版与颜色，因此 `:width`、`:padding`、`:border`、`:wrap-mode` 这类布局属性作用于这个 Box：`:width 'stretch` 跟随包含宽，`:wrap-mode 'word` 用于成段文字。响应式的 TEXT 或视口变化会像任何其它文本一样经 Ebox 重排。未知 variant 符号保留默认前景，并成为 label 的第二个类名。

**返回。** 一个 View。

**示例。**

```elisp
(etaf-label :text "Disk almost full" :variant 'danger)
```

**参见。** `etaf-badge`、`:ui-fg`。

## 状态标记

<!-- index: badge; tag; keycap; removable tag -->

#### Component: etaf-badge (&key text variant)

用 neutral、success、warning、danger 或 info 样式渲染紧凑的语义状态文字。

**参数。** TEXT 是要显示的值，与 `etaf-label` 相同。VARIANT 默认为 `neutral`。

**语义。** badge 是 `max-content` 宽、左右各一列内边距、文字加粗的盒子，用 variant 的前景与背景绘制；它的 role 是 `status`，辅助工具因此把它读作状态标记而不是控件。它从不拉伸填满容器。

**返回。** 一个 View。

**示例。** `(etaf-badge :text "stale" :variant 'warning)`

**参见。** `etaf-tag`、`etaf-label`。

#### Component: etaf-tag (&key text variant closable on-close)

渲染紧凑的语义 tag；可选的关闭动作仍归调用方所有。

**参数。** TEXT 与 VARIANT 和 `etaf-badge` 相同。CLOSABLE 非 nil 时增加关闭控件。CLOSABLE 非 nil 时 ON-CLOSE 必需，且不收参数。

**语义。** 可关闭的 tag 显示一个 ghost `×` 按钮，可访问名是 `"Remove TEXT"`。按下它调用 ON-CLOSE；tag 不自己移除自己，由调用方决定它是否保留。关闭控件与 tag 共用 variant 的颜色，所以带标签的 tag 读作一个整体标记。

**返回。** 一个 View。

**错误。** CLOSABLE 非 nil 而 ON-CLOSE 不是函数时报 `error→ etaf-component-call-error`。

**示例。** `(etaf-tag :text "filter: open" :variant 'info :closable t :on-close #'clear-filter)`

#### Component: etaf-kbd (&key keys)

把键盘快捷键渲染为可访问的 keycap 组，接受非空字符串列表。

**参数。** KEYS 是非空字符串的非空列表；每个条目是一个键帽。

**语义。** 每个键是保持标准行高、带水平内边距的紧凑圆角边框盒。轻量填充与边线从继承的面板前景和背景色派生，在深浅 Theme 下都保持可读。整组是 `max-content` 宽的 row，键帽之间一列间隙；因此 `("C-c" "C-k")` 读作两个实体键。

**返回。** 一个 View。

**错误。** KEYS 为 nil、为空、或含有非非空字符串的值时报 `error→ etaf-component-call-error`。

**示例。** `(etaf-kbd :keys '("C-c" "C-k"))`

#### Component: etaf-keycap (&key text level label active disabled on-press aria-label help-echo variant)

把一枚键渲染成键帽；动作键与区域键是两种尺寸。

**参数。** TEXT 是非空字符串，键帽上写的那一个字或几个字。LEVEL 是 `action`（默认）或 `region`。LABEL 是可选的说明文字，画在键帽右边一列处。ACTIVE 只对区域键有意义，非 nil 时整格填 `:ui-accent`、字母用 `:ui-bg`。DISABLED 保留位置与轮廓，只把墨色降到 `:ui-disabled-fg`。ON-PRESS 是可选的零参数回调，给出后键帽成为可聚焦按钮。ARIA-LABEL 与 HELP-ECHO 透传给 Host。

**语义。** 动作键一行高、单像素细框、不填充，字母 10px；区域键是 20px 见方的方块、直角、字母加粗居中。两级尺寸本身就是「做事」与「去哪儿」的区别，不看颜色也能分开。键帽是行内控件，不抢行高：它比标准行矮，在行里垂直居中；整枚键帽 `flex-shrink 0`，所以同一行右侧的键帽不会被弹性空间挤扁。可用与禁用只改墨色，位置与宽度不变。

**返回。** 一个 View。

**错误。** TEXT 非非空字符串、LEVEL 不是两个关键字之一、LABEL 不是字符串、ON-PRESS 不是函数时报 `error→ etaf-component-call-error`。

**示例。** `(etaf-keycap :text "x" :label "完成" :on-press #'agenda-toggle)`、`(etaf-keycap :text "B" :level 'region :active t)`

#### Component: etaf-check-mark (&key state color glyph aria-label)

把一条任务的勾选状态画成方框。

**参数。** STATE 是 `empty`、`done`、`dropped`、`skipped` 之一，默认 `empty`。COLOR 覆盖方框与笔画的墨色，其余时候随上下文前景。GLYPH 是可选的两个字符的终端写法，覆盖该状态默认的汉字。ARIA-LABEL 缺省用该状态的汉字。

**语义。** 图形 frame 上四种状态画成同一尺寸的直角方框加路径：空框、勾、叉、一横；四种状态的方框与笔画尺寸完全一致，所以一列勾选框不会因为状态不同而错位。方框是路径而不是字符，任何缩放下都清晰，也不依赖字体是否含该字形。没有 SVG 的终端退成两个字符宽的汉字（待 / 完 / 弃 / 跳），语义照样可读。

**返回。** 一个 View。

**错误。** STATE 不在四个关键字里、GLYPH 不是非空字符串时报 `error→ etaf-component-call-error`。

**示例。** `(etaf-check-mark :state 'done)`、`(etaf-check-mark :state 'empty :glyph "未办" :color "#e06c75")`

## 进度

<!-- index: etaf-progress; determinate progress; track token; reactive value -->

#### Component: etaf-progress (&key value max label variant)

渲染确定型进度条。VALUE 与 MAX 是数字（或响应式），满足 0 <= VALUE <= MAX 且 MAX > 0。LABEL 可选。

**参数。** VALUE 是当前量，MAX 是总量；两者都接受普通数字或响应式值，并在每次渲染时读取。LABEL 是可选说明文字。VARIANT 从语义 variant 中选择填充色。

**语义。** 进度条是两行：第一行显示标签与四舍五入后的百分比，第二行是一个标准行，轨道用 `:ui-progress-track`，填充用 variant 的前景并按百分比占据宽度。响应式的 VALUE 或 MAX 会重渲染进度条并重写百分比；因为检查在每次渲染时运行，值变化期间也持续约束取值边界。

**返回。** 一个 View。

**错误。** MAX 非正、或 VALUE 不是零到 MAX 之间的数字时报 `error→ etaf-component-call-error`，消息点名属性与收到的值。

**示例。**

```elisp
(etaf-progress :value 25 :max 200 :label "Upload")
```

**参见。** `:ui-progress-track`、`etaf-skeleton`。

## 提醒与空状态

<!-- index: etaf-alert; dismissible alert; etaf-empty; empty state action -->

#### Component: etaf-alert (&key title message variant dismissible on-dismiss)

渲染语义样式的 alert。可关闭的 alert 调用 ON-DISMISS；调用方决定它的状态是否继续可见。

**参数。** TITLE 是可选字符串标题；MESSAGE 是正文，按词换行。VARIANT 默认为 `info`。DISMISSIBLE 非 nil 时增加 ghost `×` 控件；此时 ON-DISMISS 必需，且不收参数。

**语义。** alert 是带内边距的 flex 行，用 variant 的前景与背景，带 `alert` role。标题加粗，正文按词边界换行，所以长消息让 alert 纵向增高而不是横向变宽。关闭只调用 ON-DISMISS，自身不改变任何东西：调用方通过不再渲染它来隐藏。

**返回。** 一个 View。

**错误。** TITLE 既不是字符串也不是 nil、或 DISMISSIBLE 非 nil 而 ON-DISMISS 不是函数时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-alert :title "Heads up" :message "Three targets are stale"
            :variant 'warning :dismissible t :on-dismiss #'hide-alert)
```

#### Component: etaf-empty (&key title description action-label on-action)

渲染带可选动作回调的空状态。

**参数。** TITLE 默认为 `"Nothing here"`；DESCRIPTION 是可选辅助行；ACTION-LABEL 非 nil 时增加按钮；此时 ON-ACTION 必需且不收参数。

**语义。** 空状态是拉伸的 column，交叉轴居中，带内边距与各部件之间一行间隙：strong 标题、muted 描述、可选 primary 按钮。空状态有意保持静态——组件不判断何时为空，也不决定动作做什么。

**返回。** 一个 View。

**错误。** ACTION-LABEL 非 nil 而 ON-ACTION 不是函数时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-empty :title "No results" :description "Try another query"
            :action-label "Clear" :on-action #'clear-query)
```

```elisp :figure 徽标、告警与进度条
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 1)
   (row :item-gap '(ch 1)
     (etaf-badge :text "已完成" :variant 'success)
     (etaf-badge :text "注意" :variant 'warning))
   (etaf-alert :title "提示" :message "这是一条信息告警" :variant 'info)
   (etaf-progress :value 60 :max 100 :label "进度")))
```

## 度量

<!-- index: etaf-statistic; metric card -->

#### Component: etaf-statistic (&key label value trend)

用调用方拥有的展示值渲染紧凑的度量卡片。

**参数。** LABEL 是 muted 说明，VALUE 是强调的数字，TREND 是可选的成功色变化行。每个都接受值、ref 或 computed，与 `etaf-label` 一样。

**语义。** 结果是三行 column——muted label、heading value、success trend——自身没有表面，因为组件有意把容器间距与表面留给调用方。TREND 为 nil 时渲染一个空行。

**返回。** 一个 View。

**示例。**

```elisp
(etaf-statistic :label "Requests" :value "1,204" :trend "+12%")
```

## 占位

<!-- index: etaf-skeleton; loading placeholder; placeholder size -->

#### Component: etaf-skeleton (&key width height)

渲染中性加载占位，不拥有加载状态。

**参数。** WIDTH 默认为 `stretch`，HEIGHT 默认一个标准行；两者接受任何长度值。

**语义。** skeleton 是用 `:ui-progress-track` 填充的普通盒子，尺寸由 props 决定。它不含状态、不含定时器：应用决定何时把它换成真实内容；在此之前它恰好预留内容将占用的空间。

**返回。** 一个 View。

**示例。**

```elisp
(etaf-skeleton :width '(ch 24) :height '(lh 2))
```

**参见。** `etaf-progress`、`:ui-progress-track`。

## 轨道 token

<!-- index: ui-progress-track; progress track; placeholder fill -->

#### Token: :ui-progress-track

进度条轨道与占位块的背景。

**语义。** `etaf-progress` 用它绘制未填充的轨道，`etaf-skeleton` 用它填满整个盒子，所以加载条与它的占位读作同一种材质。进度条的填充改用 variant 的前景。读取该 token 的组件自带内置回退值，所以没有提供 Theme 时两者也能绘制。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告被违反的输入契约，消息点名组件、属性、收到的值与期望：要求关闭控件却没有关闭回调的 tag 或 alert、带动作标签却没有回调的空状态、为空或不是非空字符串列表的键帽表、以及非正或顺序不对的进度边界。
- 由 variant 驱动的组件不校验 variant；未知符号回退到中性三件套并加入类名。被检查的是值、标签与尺寸这些 prop 的输入契约。
- 没有需要回滚的东西，因为这些组件不拥有状态：被拒绝的调用让已挂载表面保持原样，组件也从未写入调用方自己的状态。
- 带响应式 VALUE 的进度条就地更新；若某次写入使边界非法，被拒绝的渲染让进度条保持上一次合法绘制。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)。

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-alert :title "Heads up" :message "Three targets are stale"
               :variant 'warning)
   (etaf-progress :value 2 :max 5 :label "Sync")
   (row :item-gap '(ch 1)
     (etaf-badge :text "stale" :variant 'warning)
     (etaf-tag :text "build"))))
```
