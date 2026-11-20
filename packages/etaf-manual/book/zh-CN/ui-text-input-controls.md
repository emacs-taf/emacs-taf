# 文本输入控件

目录在就地编辑文本：字段在用户激活之前只是普通渲染内容，激活会在字段的值文本上打开原生 Emacs 编辑会话，因此键入、输入法、point、选区、undo 与 kill ring 的行为都和普通 buffer 一样，而字段保持自己的边框、内边距与换行。不会创建额外的 frame、窗口或每字段表面。本章定义文本字段、搜索药丸与数字步进器，以及打开和结束编辑的会话函数。[文本输入](text-input.md)定义这些组件所驱动的原生会话机制，[UI 组件库总论](ui-overview.md)定义受控契约，[组件样式与主题](component-styles-and-themes.md)定义 token。

## 就地原生编辑

<!-- index: edit session; activation; controlled text; submission -->

激活之前，字段是静态文本、占位与边框；值由普通渲染路径绘制。激活在那个值上开始一个会话：会话在其存续期间拥有光标、选区与 undo 历史，每次变化都经 `:on-change` 以完整文本报告给应用。字段本身留在布局里——内边距、边框与换行都不移动——也不涉及 minibuffer、子 frame 或独立窗口。

值仍归调用方所有。`:value` 加 `:on-change` 构成受控对，或经 `:bind` 传可写 ref 替代两者；应用决定提交的文本意味着什么。离开会话有三种不同含义：提交把会话文本保留为值并汇报给 `:on-submit`；离开（blur）把文本保留为值但不调用任何提交回调；取消经变更回调恢复激活时捕获的值，并把被放弃的文本汇报给 `:on-cancel`。进程范围内同时只有一个字段在编辑；开始另一个字段前会先离开前一个并保留其文本。

编辑时有几个键会离开字段，使键盘在完整应用里仍然可用：TAB 与 backtab 离开并移动应用焦点，Escape 离开并保留文本与 Host 焦点，方向键移动光标，在文本边界处按该方向离开。字段是单行且 `:submit-on-return` 未另行指定时，Return 提交；多行则插入换行。Shift+Return 与 C-j 总是插入换行，C-c C-c 与 Ctrl+Return 提交，C-c C-k 取消。`:keymap` prop 增加在应用 buffer 里运行的字段局部绑定；试图重绑框架保留键的 keymap 会被拒绝，而不是被悄悄忽略。

## 文本字段

<!-- index: etaf-text-input; outlined field; text area; placeholder -->

#### Component: etaf-text-input (&key value bind on-change label placeholder rows width variant disabled read-only submit-on-return on-submit on-cancel on-focus completion-functions keymap hide-label ref)

在应用布局内直接编辑文本。

**参数。** VALUE 是受控字符串，或 BIND 一个替代 VALUE 与 ON-CHANGE 的可写 ref。LABEL 是说明与可访问名，默认 `"Text"`；HIDE-LABEL 为网格表单省略说明。PLACEHOLDER（默认 `""`）在值为空时显示，永不成为内容。ROWS（默认 1）设置最少可见行数，因此一个组件同时覆盖单行输入与文本区；字段随更长的值增长。WIDTH 是 Ebox 长度，默认 `stretch`。VARIANT 是 `outlined`（默认）或 `plain`。DISABLED 与 READ-ONLY 移除编辑；READ-ONLY 仍可聚焦。SUBMIT-ON-RETURN 覆盖单行的默认值。ON-SUBMIT 与 ON-CANCEL 接收会话文本；ON-FOCUS 在会话开始时运行一次。COMPLETION-FUNCTIONS 为会话配置 CAPF，KEYMAP 增加字段局部绑定。REF 命名字段 Host。

**语义。** `outlined` 画出带细边框的面板，编辑时边框转为强调色，且不移动任何格子；`plain` 只画文本，用于已经在有样式表面里的输入框。值为空时占位绘制在光标之后，所以键入会替换它。激活经 `etaf-text-input-begin` 开始会话；在字段上按压或点击会开始，在外部按压会离开并保留文本。原生编辑只作用于值本身：不打开 minibuffer，编辑期间其他发布照常进行。单行字段按 Return 提交，多行字段则插入换行。

**返回。** 一个 View。

**错误。** ROWS 不是正整数、LABEL 或 PLACEHOLDER 不是字符串、VARIANT 既不是 `outlined` 也不是 `plain`、WIDTH 不是 Ebox 长度、某个回调既不是函数也不是 nil、COMPLETION-FUNCTIONS 不是函数列表、解析出的值既不是字符串也不是 nil、或 KEYMAP 不是 keymap 或绑定了框架保留键（消息点名该键）时报 `error→ etaf-component-call-error`。

**示例。**

```elisp
(etaf-text-input :value "" :label "Name" :placeholder "Ada Lovelace"
                 :on-submit (lambda (text) (setq name text)))
```

**参见。** `etaf-text-input-begin`、`etaf-search-field`、[文本输入](text-input.md)。

## 会话函数

<!-- index: etaf-text-input-begin; etaf-text-input-end; submission semantics -->

#### Function: etaf-text-input-begin (runtime ref)

在 RUNTIME 中开始编辑已挂载的文本输入 REF 并返回它；REF 未知、禁用、只读或已在编辑时返回 nil。

**语义。** 激活通常从字段自己的事件回调里调用它；直接调用可以聚焦输入框或打开网格单元进行编辑。开始另一个字段前会先离开前一个并保留其文本。编辑期间其他发布照常进行。

**返回。** 文本输入，或 nil。

**示例。** `(etaf-text-input-begin runtime 'composer)`

**参见。** `etaf-text-input-end`、`etaf-text-input-active-p`。

#### Function: etaf-text-input-end (&optional how)

结束当前活动的文本输入并返回它的用户文本；没有活动输入时返回 nil。

**参数。** HOW 为 nil 时提交：文本保留为值，`:on-submit` 收到它。HOW 为 `blur` 时离开字段并保留文本，不调用回调。其它 HOW 取消：经变更回调恢复激活时捕获的值，`:on-cancel` 收到被放弃的文本。

**语义。** 即使回调抛错，会话也已释放；随后错误继续传播。buffer 已死或回调失败同样释放会话，所以字段绝不会因为收尾失败而留在编辑状态。

**返回。** 会话文本，或 nil。

**示例。** `(etaf-text-input-end 'blur)`

#### Function: etaf-text-input-active-p (&optional runtime)

返回 RUNTIME 中正在编辑的文本输入，或 nil。RUNTIME 默认取活动字段的 Runtime，因此从任何 buffer 都可以查询。

**返回。** 活动的文本输入，或 nil。

**参见。** `etaf-text-input-begin`。

## 搜索框

<!-- index: etaf-search-field; search pill; clear button; live query -->

#### Component: etaf-search-field (&key value bind on-change placeholder width icon on-focus on-submit on-cancel on-clear keymap ref)

渲染圆角药丸搜索框，经 `etaf-text-input` 编辑受控查询，因此 ON-CHANGE 能看到每一次击键。

**参数。** VALUE/ON-CHANGE 或可写 BIND 提供查询。PLACEHOLDER 默认 `"Search"`。WIDTH 默认 `stretch`。ICON 非 nil 时在文本前加放大镜。使用清除控件时调用 ON-CLEAR。ON-FOCUS、ON-SUBMIT、ON-CANCEL 与 KEYMAP 与 `etaf-text-input` 相同。REF 命名输入，供 `etaf-text-input-begin` 使用。

**语义。** 药丸高 3 行，绘制表面在文字上下各留半行。查询非空时尾部有清除控件：它离开会话、清空查询、调用 ON-CLEAR 并重新开始编辑。在药丸上任意位置按压都会开始编辑。药丸用 `:ui-search-bg` 与 `:ui-search-fg` token 绘制，放大镜用 muted 色。

**返回。** 一个 View。

**错误。** PLACEHOLDER 不是字符串、或 ON-CLEAR 既不是函数也不是 nil 时报 `error→ etaf-component-call-error`；其余遵循内部文本输入自己的契约。

**示例。**

```elisp
(etaf-search-field :value "" :icon t :on-clear #'reset-search)
```

**参见。** `etaf-text-input`、`:ui-search-bg`。

## 数字输入

<!-- index: etaf-number-input; stepper; draft value; bounded integer -->

#### Component: etaf-number-input (&key value label on-change disabled min max bind hide-label ref)

渲染受控步进 NumberInput：muted LABEL、− 步进器、值药丸与 + 步进器。

**参数。** VALUE 是整数或 nil。LABEL 是字符串或 nil，默认 `"Value"`。MIN 与 MAX 是数字或 nil，满足 `min <= max`。BIND 替代 VALUE 与 ON-CHANGE。HIDE-LABEL 去掉说明。REF 命名文本字段。

**语义。** 步进器把值改变一并在边界处禁用；值本身由文本字段就地编辑，因此键入只接受完整且在范围内的整数，空字段表示无值。中间文本保持为草稿：清空文本不清空值，越界输入不写入，提交非法内容报可读错误且不改变值。提交空字段报告 nil。

**返回。** 一个 View。

**错误。** LABEL 既不是字符串也不是 nil、MIN 或 MAX 既不是数字也不是 nil、MIN 大于 MAX、非 nil BIND 与显式 VALUE 或 ON-CHANGE 同时出现、或解析出的值既不是整数也不是 nil 时报 `error→ etaf-component-call-error`。提交的文本不是范围内整数时报 `user-error`，消息点名标签与边界。

**示例。**

```elisp
(etaf-number-input :value 3 :min 0 :max 10 :label "Count")
```

**参见。** `etaf-text-input`、`etaf-slider`。

## 描边输入框 token

这些 token 只作用于 `etaf-text-input` 的 outlined 变体。响应式 Theme 更新保留的输入框而不结束原生编辑；焦点只改变预留边框的颜色，不改变尺寸。plain 变体保持零内边距且没有自己的背景或边框。

#### Token: :ui-input-padding

描边输入框的内边距，使用 `:padding` 的值语法，回退为 `((lh 0) (ch 1))`。

**语义。** 例如 `((lh 1) (ch 2))` 在值周围留出标准行内边距，保持文字的字体度量。

#### Token: :ui-input-radius

描边输入框的圆角半径，使用 `:border-radius` 的值语法，回退为 `(px 0)`。

**语义。** 圆角边框支持范围与 padding 要求见[样式属性](style-properties.md#style-border-radius)。

#### Token: :ui-input-bg

描边输入框的背景颜色。

**语义。** 未提供时读取当前 Theme 的 `:ui-panel-bg`，包括其内置回退值；因此只提供暗色面板配色仍能使输入框保持暗色。

#### Token: :ui-input-border

描边输入框空闲时的单像素边框颜色。

**语义。** 使用十六进制颜色字符串。未提供时读取当前 Theme 的 `:ui-panel-border`。编辑时改读 `:ui-accent`，两种状态都预留单像素边框。

## 搜索 token

<!-- index: ui-search-bg; ui-search-fg; search pill paint -->

#### Token: :ui-search-bg

搜索框药丸的填充。

**语义。** 读取它的搜索框自带内置回退值，所以没有提供 Theme 时药丸也能绘制；`etaf-text-input` 从不读它，因为放在调用方表面里的字段保留那个表面。

#### Token: :ui-search-fg

搜索框内文字的前景。

**语义。** 由药丸的 flex 框架绘制，因此占位与编辑文本都继承它；放大镜与清除控件改用 `:ui-muted-fg`。

## 错误与恢复

- `error→ etaf-component-call-error` 经 `etaf-check-prop` 报告每一条被拒绝的 prop，消息点名组件、属性、收到的值与期望，其中包括绑定框架保留键的 keymap。
- 数字输入区分草稿与错误：尚不构成完整整数的文本只是不写入，而提交非法值报 `user-error` 并保持值不变。
- 提交或取消回调出错仍会释放会话，字段不会卡在编辑状态；随后回调的错误向调用方传播。
- 卸载仍开着会话的字段会离开（blur），把用户文本保留为草稿而不是提交。

**参见。** [UI 组件库总论](ui-overview.md#错误与恢复)、[文本输入](text-input.md)。

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-text-input :value "" :label "Name" :placeholder "Ada Lovelace")
   (etaf-search-field :value "query" :icon t)
   (etaf-number-input :value 3 :min 0 :max 10 :label "Count")))
```
