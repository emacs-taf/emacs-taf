# 选择器与菜单

目录用两种形态回答「从这些值里选一个」：一种是在布局里就地显示当前选择的*选择器*，另一种是打开临时动作表面的*菜单*。`etaf-select` 是选择器：短列表用 chips，较长列表用锚定下拉。`etaf-menu`、`etaf-dropdown-menu` 与 `etaf-context-menu` 是菜单：一个用原生补全，另两个打开 buffer 内的浮动表面。四者都是受控的——值、选项与反应都归调用方所有——也都经回调报告选中的键。[UI 组件库总论](ui-overview.md)定义受控契约，[按钮与选择控件](ui-buttons-and-choice-controls.md)定义它们组合的按钮与选中色调，[浮层](ui-overlays.md)定义它们打开的浮动表面，[文本输入](text-input.md)定义补全菜单所穿过的原生输入边界。

## 选项契约

<!-- index: option alist; item plist; unique values; disabled item -->

选择器接受*选项 alist*：每条把值映射到标签。值必须是唯一的标量（符号、数字或字符串），标签是唯一的非空字符串，当前值是 nil 或其中一个值——列表里没有的 nil 显示占位，而其它不在列表中的值是错误，因为调用方要求显示列表解释不了的东西。菜单接受*item plist 列表*，因为菜单项带的比标签多：唯一的非 nil `:key`、唯一的非空 `:label`，以及可选的 `:disabled`。键是回调收到的，标签是用户读到的。

文字菜单入口末尾使用共享图标库的展开箭头。它表示菜单，不是键盘绑定，也不进入控件的可访问名称。

禁用项保持可见，不能激活也不能被焦点到达。菜单里已经没有可用项、或回调缺失的控件会禁用自身触发件，而不是打开一个空表面：空列表是禁用的控件而不是错误，因为此刻没有动作可用的应用仍要渲染出连贯的工具栏。

## 选择器组件

<!-- index: etaf-select; chips; dropdown anchor; auto presentation -->

#### Component: etaf-select (&key value options label placeholder on-change disabled bind presentation hide-label width ref)

不离开展示层就从 OPTIONS 选择一个受控值。

**参数。** VALUE 是当前值、ref 或 computed。OPTIONS 是上面描述的 alist。LABEL 默认 `"Select"`，PLACEHOLDER 默认 `"—"`。ON-CHANGE 接收被接受的值；BIND 是替代 VALUE 与 ON-CHANGE 的可写 ref，契约同 `etaf-checkbox`。PRESENTATION 是 `chips`、`dropdown` 或 `auto`（默认）。HIDE-LABEL 为网格表单省略说明。WIDTH 是下拉浮层的宽度，默认 `(ch 28)`。REF 命名下拉锚点；显示 chips 时命名整个字段。

**语义。** chips 形态下每个选项是一个行内药丸，当前项用选中色调填充；`dropdown` 形态下一个锚点药丸显示当前标签和展开箭头 并打开选项 ghost 按钮组成的浮层；`auto` 在四项以内用 chips，超过则用下拉。Chips 与下拉选项在选中时保持内边距和字体不变，只改变 Theme 绘制颜色，不叠加悬停高亮。选择下拉项会关闭浮层并调用 ON-CHANGE 一次；Escape 关闭而不选择。下拉的打开状态与锚点属于保留实例，所以调用方不需要保存打开标志。选择永不打开 minibuffer。

**返回。** 一个 View。

**错误。** PRESENTATION 不是三者之一、OPTIONS 不是由唯一标量值与唯一非空字符串标签构成的 proper list、VALUE 既不是 nil 也不是列表中的值、LABEL 或 PLACEHOLDER 不是字符串、或回调既不是函数也不是 nil 时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-select :value 'medium :label "Size"
             :options '((small . "Small") (medium . "Medium") (large . "Large"))
             :on-change #'set-size)
```

**参见。** `etaf-menu`、`etaf-dropdown-menu`。

## 菜单组件

<!-- index: etaf-menu; native completion; action menu -->

#### Component: etaf-menu (&key label items on-select disabled)

渲染一个打开原生补全的按钮，用于执行动作。

**参数。** LABEL 默认 `"Actions"`，命名触发件。ITEMS 是上面描述的 item plist 列表。ON-SELECT 接收选中的键。

**语义。** 激活触发件会在可用项的标签上运行 Emacs 自己的补全；选择经列表校验后，其键传给 ON-SELECT 一次，焦点由原生输入边界恢复。空输入或 C-c C-k 取消且不回调。控件不拥有应用值，也没有额外的打开状态：当前 props 提供每次发布出来的菜单。DISABLED 非 nil、没有可用项、或缺少 ON-SELECT 时触发件禁用。与任何输入一样，还可以带加性的 `:on-press` 观察者。

**返回。** 一个 View。

**错误。** item 形式非法（不是带 `:key`、`:label` 与可选 `:disabled` 的 plist）、键或标签重复、标签为空、LABEL 不是字符串、或 ON-SELECT 不是函数时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-menu :label "Actions"
           :items '((:key save :label "Save") (:key quit :label "Quit"))
           :on-select #'run-action)
```

**参见。** `etaf-dropdown-menu`、`etaf-select`。

## 下拉菜单

<!-- index: etaf-dropdown-menu; icon trigger; anchored menu; menu item icon -->

#### Component: etaf-dropdown-menu (&key label items on-select disabled width icon placement)

渲染一个按钮与锚定的菜单项 Popover。

**参数。** LABEL 默认 `"Actions"`。WIDTH 默认 `(ch 28)`。ITEMS 遵循 `etaf-menu`，每项可带显示在标签之前的 `:icon`。ICON 非 nil 时触发件就是该图标，LABEL 作为它的帮助文本与可访问名。PLACEMENT 默认 `bottom-start`，遵循[浮层](ui-overlays.md)。

**语义。** 按压触发件打开浮层；选择可用项会关闭它并以该键调用 ON-SELECT 一次。带图标的项是全宽行，其指针与键盘行为来自与按钮相同的 Host 属性，并带 hover 色调；不带图标的项是 ghost 按钮。打开状态与唯一锚点属于保留的 Component，多个下拉因此可以并存而不共享标志，应用数据仍归调用方所有。键盘导航、焦点返回与关闭遵循 Popover 契约。

**返回。** 一个 View。

**错误。** 与 `etaf-menu` 相同的 item 与回调契约错误，或 LABEL 不是字符串时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-dropdown-menu :label "Actions" :icon 'more-vertical
                    :items '((:key share :label "Share" :icon 'send)
                             (:key delete :label "Delete" :icon 'close))
                    :on-select #'run-action)
```

**参见。** `etaf-popover`、`etaf-context-menu`。

## 上下文菜单

<!-- index: etaf-context-menu; compact trigger -->

#### Component: etaf-context-menu (&key label items on-select disabled width)

按 DropdownMenu 契约组合一个键盘与鼠标都可用的上下文动作触发件。

**参数。** LABEL 默认 `"More"`；WIDTH 默认 `(ch 30)`；ITEMS、ON-SELECT 与 DISABLED 与 `etaf-dropdown-menu` 相同。

**语义。** 组件是一层薄特化：触发件是普通 Ebox 按钮，键盘、鼠标与焦点行为与下拉触发件相同，菜单是同一个锚定浮层。应用把它放在动作所属的目标旁边——一行、一张卡片或一个面板——动作仍归调用方所有。

**返回。** 一个 View。

**错误。** 与 `etaf-dropdown-menu` 相同。

**示例。**

```elisp
(etaf-context-menu :items '((:key rename :label "Rename")
                            (:key delete :label "Delete"))
                   :on-select #'run-action)
```

**参见。** `etaf-dropdown-menu`。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的 prop，消息点名组件、属性、收到的值与期望：形式非法的选项表或 item 表、重复的值或键、不在选项中的值，以及非字符串的标签或占位。
- 选择总是先关闭再报告：从下拉里选择后，ON-SELECT 运行时它已经关闭，因此重渲染周围 View 的回调不会意外把它重新打开。
- 取消不是错误：不选择就关闭菜单、空补全输入或 C-c C-k 都只是不报告任何东西，禁用触发件根本无法激活。
- 选择器与菜单只拥有呈现状态；被拒绝或被取消的交互不触碰调用方的值。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[浮层](ui-overlays.md)。

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-select :value 'medium :label "Size"
                :options '((small . "Small") (medium . "Medium") (large . "Large"))
                :on-change #'ignore)
   (etaf-dropdown-menu :label "Actions"
                       :items '((:key save :label "Save") (:key quit :label "Quit"))
                       :on-select #'ignore)))
```
