# 组件样式与主题

<!-- index: 组件样式; Theme; 主题 token; 调色板; hover 样式 -->

Component 通过一份静态规则列表拥有自己的默认外观，并通过继承的 Theme 绘制。规则列表使用的声明语法与其他样式输入相同，`&` 把规则限定到 Component 自己的根。Theme 是一个 Context 值，提供 Host 默认值和具名 token；token 让静态规则读取当前 Theme，而不必变成内联动态属性。本章定义规则格式、运行时样式替换入口、状态与悬停样式、Theme 的提供与调色板解析、token 词表，以及 token 解析的时机。[样式系统总论](style-system.md)定义层叠，[值](values.md)定义值语法；规则声明的属性见 [Host](hosts.md)。

## 规则与根

<!-- index: :styles; 静态规则列表; 组件作用域; 规则优先级 -->

`etaf-define-component` 的 `:styles` 子句是一份静态、有序、无包装的规则列表：`((SELECTOR PROPERTY VALUE ...) ...)`。它的值是样式数据——字面的 `(1 2)` 或 `bold` 不需要 quote——规则在 Component 定义时按 Ebox schema 编译，因此非法的属性或值会让定义失败。

一个 Component 的规则围绕它的 View 形成一个作用域。`&` 与 `:scope` 匹配每一个 Component 根，Component 渲染 fragment 或 forest 时也包括全部根；普通选择器会被改写成根的严格后代，所以 `&.selected` 给根自身加样式，`.selected` 只给它拥有的后代加样式。父 Component 的规则不会进入嵌套 Component 的内部，经调用方 slot 提供的内容保留调用方的作用域。同一份规则列表里，后写的规则在平手时获胜。

规则以 author 来源进入 Ebox，与内联 Host 属性走同一套层叠：内联 normal 声明压过组件 normal 规则，important 规则可以覆盖内联 normal 值。Host 属性为 nil 时被省略，而不是作为声明下发。[选择器](selectors.md)定义选择器语言与状态模型。

## 运行时替换样式

<!-- index: 运行时样式替换; 样式表重载 -->

预览或创作工具可以在不重定义 Component 的前提下替换它的规则列表。

#### Function: etaf-component-set-styles (name styles)

用 STYLES 替换 Component NAME 的静态样式表单。

**参数。** NAME 是已注册的 Component 名。STYLES 使用与 `etaf-define-component` 相同的 `((SELECTOR PROPERTY VALUE ...) ...)` 契约。

**语义。** STYLES 立即按 Ebox schema 校验，与定义的 `:styles` 子句完全一样。成功后它成为该 Component 的规则列表；下一次挂载或渲染会降到新规则，已挂载的 Runtime 不会被隐式 flush，因此它们的当前绘制保持到下一次提交。替换对之后渲染的每个实例可见。

**返回。** STYLES。

**错误。** NAME 不是已注册 Component，或 STYLES 不是合法规则列表时 `error→ etaf-component-definition-error`；消息点名 Component 与被拒绝的部分。

**示例。**

```elisp
(etaf-component-set-styles
 'styled-card '(("&" :background-color "#1F2937")))
```

**参见。** [组件](components.md)一章的 `:styles` 子句。

## 状态样式与悬停

<!-- index: 状态选择器; selected 类; hover 样式 -->

状态样式就是选择器样式：`&.selected` 或 `&:disabled` 这样的规则匹配根的派生状态或作者状态，见[选择器](selectors.md)。组件通常携带一个作者状态类（`selected`、`disabled`、`active`）并由 prop 切换它，这样样式保持静态，状态留在保留 Host 上。

悬停是瞬态绘制，不是保留的视觉状态：Host 用 `:hover-style` 声明一个绘制属性 plist，指针位于节点上时由 Ebox 把这些声明合并到节点的计算样式上重绘，因此填充会保留 Host 的圆角与内边距，文字也保持对比度；渲染文本把同样的声明作为原生 mouse face 携带。`:hover-content` 能以同样方式替换一行文本。两者都是 Host 的语义属性，定义见 [Host](hosts.md)。`:hover-style` 的值可以包含延迟的 Theme token：ETAF 把它们与实例的其余样式一起解析，因为未解析的 token 是无效的 face 属性。

Theme 没有给出悬停色时，目录组件会自行派生。Button 与菜单行优先读取应用提供的 `:ui-button-primary-hover-bg`、`:ui-button-secondary-hover-bg`、`:ui-button-ghost-hover-bg` 或 `:ui-accent-soft-bg`；调用方给了 `:bgcolor` 的 Button 改由该底色派生悬停填充，自定义 chip 因此不会用静止色悬停。否则目录把深色底提亮、浅色底压暗，这样深色调色板下浅色文字依然清楚，不会从回退调色板里继承一层浅色。应用自己写的悬停样式遵循同一条规则：填充色从 Theme 读取或由 Theme 自身的颜色派生，并用指针在两种调色板下各查一遍。

```elisp :figure 组件规则读取 Theme：提供的 token 给标签上色，state class 把其中一个切到禁用色
(etaf-define-component demo-theme-states ()
  :setup (etaf-theme-provide '(:chip-bg "#0F766E" :chip-fg "#ECFDF5"))
  :styles (("& .chip" :background-color (etaf-theme-token :chip-bg "#334155")
                     :color (etaf-theme-token :chip-fg "#F8FAFC"))
           ("& .chip.muted" :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
                            :color (etaf-theme-token :ui-disabled-fg "#687386")))
  :view
  (row :item-gap '(ch 1)
       (box :class "chip" :padding '((lh 0) (ch 1)) (text "在线"))
       (box :class "chip muted" :padding '((lh 0) (ch 1)) (text "离线"))))
(etaf-view (demo-theme-states))
```

## 提供 Theme

<!-- index: Theme 提供; Host 默认值; UA 来源 -->

Theme 就是键为 `theme` 的普通 Context 值。它是一份属性 plist，混合两类条目：键名是样式属性的条目给子树中接受该属性的每个 Host 提供默认值，其他键是供 `etaf-theme-token` 读取的具名 token。

Theme 提供的 Host 默认值以 UA 来源进入 Ebox，因此普通作者声明——内联属性与组件规则——会覆盖它们，而 important 的 Theme 默认值仍能压过 important 的作者声明。Theme 可以是 ref 或 computed 源；与每个提供的 Context 值一样，它保持响应式，改动会重新发布默认值，而不会把它们变成内联属性。

#### Function: etaf-theme-provide (theme)

向当前 Component 子树提供 THEME 属性默认值。

**参数。** THEME 是 `(:color "#F4F6FB" :bgcolor "#202634")` 这样的属性 plist，每个键都是关键字。它也可以是一个 ref 或 computed，其值是这样的 plist。

**语义。** 该值作为 Context 键 `theme` 提供给当前 Component 及其后代，可见范围与生命周期遵循 [Context](context.md)。被接受的样式属性键成为 UA 来源的 Host 默认值，在到达 Ebox 之前就着同一份 Theme 解析；其他键保留为普通 token 值。响应式源会被跟踪，之后的写入重新发布子树。非法的 Theme 形状或非法的解析后默认值会被拒绝，而不是发布。

**返回。** 提供的值，与 `etaf-provide` 的返回一致。

**错误。** THEME 不是偶数长度 plist 时 `error→ etaf-context-error`，数据 `("Theme defaults must be keyword/value pairs: %S")`；某个键不是关键字时数据 `("Theme default must use a keyword: %S")`。

**参见。** `etaf-theme-resolve-palette`、`etaf-theme-token`，以及 [Host](hosts.md) 的 Host 默认值一节。

## 解析调色板

<!-- index: 调色板; light 模式; dark 模式; 颜色对 -->

同时提供明暗两种外观的应用维护一份语义角色调色板，并按显式模式解析它。调色板的值可以是普通颜色字符串（两种模式共用）、`(LIGHT . DARK)` 对、`(:light LIGHT :dark DARK)` plist 或 nil；结果是普通 Theme plist，可直接交给 `etaf-theme-provide`。

#### Function: etaf-theme-resolve-palette (palette mode)

按显式 MODE 解析语义 PALETTE token 规格。

**参数。** PALETTE 是键为 Theme 键的关键字 plist。每个值是颜色字符串、`(LIGHT . DARK)` 对、`(:light LIGHT :dark DARK)` plist 或 nil。MODE 是 `light` 或 `dark`。

**语义。** 每个条目按 MODE 解析：字符串保留，对或 plist 贡献对应的明或暗值，nil 保持 nil。结果包含相同的键，是普通 Theme 值，因此调用方可以提供它，之后再为另一模式重新解析。

**返回。** 解析出的 Theme plist。

**错误。** MODE 非法时 `error→ etaf-context-error`，数据 `("Theme palette mode must be light or dark: %S")`；调色板形状错误时 `("Theme palette must be a keyword plist: %S")`；键不是关键字时 `("Theme palette key must be a keyword: %S")`；值不属于四种合法形状时 `("Invalid ETAF palette color: %S")`。

**示例。**

```elisp
(etaf-theme-resolve-palette
 '(:color "black" :bgcolor ("#FFF" . "#111") :accent (:light "#2563EB" :dark "#60A5FA"))
 'dark)
     ⇒ (:color "black" :bgcolor "#111" :accent "#60A5FA")
```

#### Function: etaf-theme-current-mode ()

把当前 frame 的颜色模式返回为 `light` 或 `dark`。

**语义。** 模式从 frame 的 `background-mode` 参数读取：`dark` 映射为 `dark`，其他一切映射为 `light`。它只是解析调色板的默认参数——应用自己的明暗切换应把自身的模式传给 `etaf-theme-resolve-palette`，而不是去改 Emacs frame。它同时把调用方接到主题切换信号上：切换之后，读取它的 Theme computed 会重新推导，而不是沿用第一次读到的模式。

**返回。** 符号 `light` 或 `dark`。

## Theme token

<!-- index: 延迟 token; token 回退; token 变换; token 解析 -->

Theme token 是延迟数据。`etaf-theme-token` 返回一个小列表，指名一个 Theme 键并携带回退值；这个列表能留在 quoted 静态规则列表里，ETAF 在把声明降到 Ebox 时用 Theme 的值替换它。因为替换发生在降级边界，许多保留 Host 可以共用一份静态样式，而不必各自携带内联动态属性。

token 在包含它的声明被降级时解析：内联 Host 属性在 Host 提交时从继承的 Theme 解析；组件规则在该实例的规则快照按当前 Theme 构建时解析；Theme 提供的 Host 默认值在默认值计算时解析；嵌套在 `:hover-style` 里的 token 随实例样式解析。Theme 里没有该键时使用 token 的回退值；回退值本身若是 token 会先被解析；给出变换函数时，函数作用在最终值上。

#### Function: etaf-theme-token (key &optional default transform)

返回供静态组件样式使用的延迟 Theme token。

**参数。** KEY 是指名 Theme 条目的关键字。Theme 没有 KEY 的值时返回 DEFAULT；DEFAULT 可以是嵌套 token。TRANSFORM 非 nil 时是作用在解析结果上的纯函数。

**语义。** 结果是形如 `(etaf-theme-token KEY DEFAULT [TRANSFORM])` 的列表。它有意做成数据：可以直接放进 quoted 的 `((SELECTOR PROPERTY VALUE ...) ...)` 规则列表，也可以由内联属性表达式返回，`etaf-theme-token-p` 能识别它。包含它的声明被降级时 token 被替换成解析值，因此 Theme 变化是重新降级静态规则，而不是改写每个 Host。

**返回。** 延迟 token 列表。

**错误。** KEY 不是关键字时 `error→ etaf-context-error`，数据 `("Theme token keys must be keywords: %S")`；TRANSFORM 既非 nil 又不可调用时数据 `("Theme token transform must be callable: %S")`。

**参见。** `etaf-theme-provide`、`etaf-theme-token-p`。

#### Function: etaf-theme-token-p (value)

当 VALUE 是延迟的 ETAF Theme token 时返回非 nil。

**语义。** 值必须是 2–4 个元素的 proper list，第一个元素是符号 `etaf-theme-token`，第二个是关键字，可选的第四个是函数。普通 Theme plist 与颜色都不是 token。

**返回。** 是 token 时非 nil，否则 nil。

```elisp :run
(etaf-define-component demo-theme-chip ()
  :setup (etaf-theme-provide '(:chip-bg "#0F766E" :chip-fg "#ECFDF5"))
  :view (text "Online")
  :styles (("&" :background-color (etaf-theme-token :chip-bg "#334155")
               :color (etaf-theme-token :chip-fg "#F8FAFC"))))
(etaf-view (demo-theme-chip))
```

### 基础 token 词表

<!-- index: ui-fg; ui-bg; ui-border; ui-muted-fg; 状态色 -->

本节的 token 是官方组件目录读取的语义颜色表面。使用某个 token 的组件自带内置回退值，因此没有提供 Theme 时目录也能绘制；在 Theme 里提供该键会覆盖整棵子树的回退值。其余组件族 token 属于 [UI 组件库总论](ui-overview.md)；完整的 token 词表见[主题 token 表](theme-token-table.md)。

每个条目给出一个角色。Theme 可以把键设成消费声明接受的任何值；基础词表用的是颜色。

#### Token: :ui-fg

目录内容的默认前景。

**语义。** 官方组件用它绘制普通文字与字形，例如 Label 的默认与 strong 变体、Selection 行、Table 单元格和 Data 展示。提供该键的 Theme 值会替换回退色。

#### Token: :ui-bg

应用表面的默认背景。

**语义。** 用于反馈表面、Data 展示及其他应用级面板。它是 `:background-color` 的颜色。

#### Token: :ui-border

默认边框与分隔线颜色。

**语义。** 反馈组件用它画分隔线与面板轮廓；消费者可以通过自己的样式辅助把颜色变换成完整边框声明。

#### Token: :ui-muted-fg

次级文字的弱化前景。

**语义。** 用于提示、说明和应当退到 `:ui-fg` 之后的非活动标签。

#### Token: :ui-accent

强调与选中的强调色。

**语义。** 选择控件、媒体表面和桌面外壳用它表示选中状态。它是标记活动项的填充或文字颜色。

#### Token: :ui-accent-fg

与 `:ui-accent` 配对的前景。

**语义。** 指名强调色填充表面上的文字颜色，让 Theme 能同时保证强调填充与其前景的可读性。

#### Token: :ui-accent-soft-bg

柔和的强调底色。

**语义。** 用于比完整 `:ui-accent` 表面更轻的选中或次级填充，例如选中的桌面项背景。

#### Token: :ui-disabled-fg

禁用控件的前景。

**语义。** 控件不可操作时替代 `:ui-fg`；Button、Checkbox 与 Selection 都用它。

#### Token: :ui-disabled-bg

禁用控件的背景。

**语义。** 在压暗填充的同时保留禁用控件的占位，不改变邻项。

#### Token: :ui-disabled-border

禁用控件的边框色。

**语义。** 与 `:ui-disabled-bg` 一起用于带轮廓的控件。

#### Token: :ui-danger-fg

危险状态的前景。

**语义。** 用于破坏性或错误状态，包括 Label 的 danger 变体和反馈表面。

#### Token: :ui-danger-bg

危险状态的背景。

**语义。** 反馈表面中危险文字背后的底色。

#### Token: :ui-danger-border

危险状态的边框。

**语义。** 与 `:ui-danger-fg`、`:ui-danger-bg` 组成危险三件套。

#### Token: :ui-warning-fg

警告状态的前景。

**语义。** 用于反馈表面中的注意事项状态。

#### Token: :ui-warning-bg

警告状态的背景。

**语义。** 警告文字背后的底色。

#### Token: :ui-warning-border

警告状态的边框。

**语义。** 组成警告三件套。

#### Token: :ui-info-fg

信息状态的前景。

**语义。** 用于反馈表面中的中性通知与提示。

#### Token: :ui-info-bg

信息状态的背景。

**语义。** 信息文字背后的底色。

#### Token: :ui-info-border

信息状态的边框。

**语义。** 组成信息三件套。

#### Token: :ui-success-fg

成功状态的前景。

**语义。** 用于确认状态，包括 Label 的 success 变体和反馈表面。

#### Token: :ui-success-bg

成功状态的背景。

**语义。** 成功文字背后的底色。

#### Token: :ui-success-border

成功状态的边框。

**语义。** 组成成功三件套。

## 跟随 Emacs 当前主题

<!-- index: frame 背景模式; 主题切换 -->

由 frame 推导的 Theme 会在 Emacs 主题切换后重新推导：`etaf-theme-current-mode` 把调用方接到切换信号上，读取它的 Theme 或渲染在每次切换后重跑一次，且只在开关主题的多个步骤都结束后跑。钉住自身模式的 Theme 仍是应用数据，由应用决定何时重建。拥有多个表面的宿主可以显式提供它们的外观（见[外观继承](#外观继承)），并在重新解析 Theme 时更新它，下面的 Component 因此无需知道宿主就能跟随。提供的构件是 `etaf-theme-current-mode`（报告当前 frame 是明还是暗）与 `etaf-theme-resolve-palette`（按显式模式把一份调色板变成 Theme）。常见做法是把调色板放在应用数据里，在应用启动或自己的切换发生时按模式解析并提供结果；由于提供的 Theme 可以是 ref，重新提供新模式就能重新发布子树，而无需重渲染。

## 外观继承

<!-- index: 外观; 明暗表面; 面板外观 -->

宿主可以渲染外观与 frame 不同的表面，例如深色 Emacs frame 里的亮色面板。`etaf-appearance-provide` 把该外观提供给当前 Component 子树，`etaf-appearance` 读取最近一次提供的值；没有提供者时返回 frame 的模式。宿主可以提供 ref 或 computed，于是切换外观会重新发布子树，而无需重新渲染。

#### Function: etaf-appearance-mode (&optional override)

返回跟随宿主的 computed 外观模式。

**语义。** OVERRIDE 非 nil 时是持有 `light` 或 `dark` 的 ref，优先于宿主；应用自己的明暗切换就写它。computed 会跟踪宿主外观，读取它的 Component 在宿主切换时重渲染。

**返回。** 值为 `light` 或 `dark` 的 computed。

#### Function: etaf-appearance-provide (appearance)

把 APPEARANCE（`light` 或 `dark`）提供给当前 Component 子树。

**语义。** APPEARANCE 是 `light`、`dark`、ref 或 computed。非法值在提供之前以 `etaf-context-error` signal。该值作用于当前 Component 及其后代，直到更近的提供者替换它。

#### Function: etaf-appearance ()

返回从最近宿主继承的外观，或 frame 的模式。

**语义。** 提供的 ref 或 computed 经 `etaf-value` 读取，因此宿主切换外观时调用方会重渲染。没有提供者时，值来自 `etaf-theme-current-mode`。

**返回。** 符号 `light` 或 `dark`。

## 表面声明

<!-- index: 表面声明; 应用自有主题; 面板配色 -->

一个自带调色板和明暗开关的应用可以把这两样声明给承载它的宿主，而不是让宿主再猜一份。`etaf-surface-create` 造出声明槽，宿主在渲染内容之前用 `etaf-surface-provide` 把它放进 Context；内容在自己的 Component `:setup` 里用 `etaf-surface-host` 读到槽，再用 `etaf-surface-declare` 写下 Theme、模式格与模式表。宿主读 `etaf-surface-theme`、`etaf-surface-mode` 与 `etaf-surface-modes` 来画自己的 frame、标题栏和边框，并把模式表用作自己的切换。模式格是唯一的状态：内容自己的开关写它，宿主的切换也写它，于是内容与承载它的表面只有一个外观状态，而不是各存一份。没有宿主时 `etaf-surface-host` 返回 nil，内容照旧自己画自己。

#### Function: etaf-surface-create ()

返回一个空的表面声明，供宿主提供。

**语义。** 宿主在提供之前造一次，之后一直持有同一个对象：内容把它填进去，宿主在内容挂载之后读同一份。声明槽是普通数据，不进 Context；随 Context 走的是这个对象本身。

**返回。** 一个表面声明值，对调用方不透明；交给 `etaf-surface-provide` 和三个读取函数。

#### Function: etaf-surface-provide (surface)

把 SURFACE 提供给当前 Component 子树。

**语义。** SURFACE 来自 `etaf-surface-create`，其他值以 `etaf-context-error` signal。槽沿 Context 向下继承，内容用 `etaf-surface-host` 读到它；对象本身可变，所以宿主在挂载之后读到的是内容写下的值，而不是提供时的那一份副本。

**返回。** SURFACE。

#### Function: etaf-surface-host ()

返回最近宿主提供的表面声明，或 nil。

**语义。** 在内容 Component 的 `:setup` 里调用。普通 buffer 或没有提供槽的宿主返回 nil，应用据此只在被宿主框住时声明，独立使用时仍画自己的调色板。

**返回。** 表面声明，或 nil。

#### Function: etaf-surface-declare (surface &key theme mode modes)

在宿主 SURFACE 上声明内容自己的表面。

**语义。** THEME 是持有 Theme plist 的 ref 或 computed，MODE 是持有当前模式符号的 ref，MODES 是 `(MODE . LABEL)` 的有序 alist，LABEL 是字符串。三个关键字各自可省略，省略的字段保持原值，所以调色板和模式表可以分两次声明。宿主从 THEME 画 frame、标题栏和边框，把 MODES 用作标题栏的切换并写 MODE；内容读同一格，因此任何一侧的切换都同时重画两侧。渲染期间调用、非法值、不是声明槽的 SURFACE 都在写入之前 signal `etaf-context-error`。

**返回。** SURFACE。

#### Function: etaf-surface-theme (surface)

返回 SURFACE 的 Theme 来源（ref 或 computed），没有声明时为 nil。

**语义。** 宿主在内容挂载后经 `etaf-value` 读它并重画自己的表面；内容换掉这个来源时宿主跟着重画。

#### Function: etaf-surface-mode (surface)

返回 SURFACE 的模式 ref，没有声明时为 nil。

**语义。** 这是内容与宿主共用的那一格：内容自己的开关写它，宿主的切换也写它，读取它的 Component 和宿主随之重画。

#### Function: etaf-surface-modes (surface)

返回 SURFACE 的有序 `(MODE . LABEL)` alist，没有声明时为 nil。

**语义。** 宿主按这个顺序渲染自己的切换控件；值为 nil 表示内容没有切换，宿主也不画切换。

#### Function: etaf-ui-color-contrast (from to)

返回 FROM 与 TO 之间的 WCAG 对比度，从 1 到 21。

**参数。** 两个颜色都可以用 Emacs 认得的任何写法，`#RRGGBB` 或 `moccasin` 这样的名字。

**返回。** 一个 1 到 21 之间的比值。

**语义。** 有一边 Emacs 解析不出来时对比度无法测量，返回 0——它读作「没人验证过的颜色」，而不是「恰好没有对比」。检查主题或配色是否达标时用它，不要凭深浅肉眼判断。

**参见。** `etaf-ui-color-legible`、`etaf-theme-token`。

#### Function: etaf-ui-color-legible (color background &optional ratio)

返回在 BACKGROUND 上仍然好读的 COLOR，并保住它的色相。

**参数。** COLOR 是想用的颜色，BACKGROUND 是它要落在的表面；RATIO 是目标对比度，默认 4.5，即 WCAG AA 对正文的要求。

**返回。** 一个 `#RRGGBB` 颜色。

**语义。** 为一种页面写的语法色换到另一种页面上会消失：暗色主题给字符串的浅粉在白页上什么都看不见。COLOR 在浅表面上朝黑混、在深表面上朝白混，一小步一小步直到达到 RATIO；本来就达标的颜色原样返回。不是 `#RRGGBB` 写法的颜色也原样返回，因为它无法在这里混合。结果按 （COLOR BACKGROUND RATIO） 缓存，因为页面每次重绘都会重画代码块。

**参见。** `etaf-ui-color-contrast`、`etaf-theme-resolve-palette`。

## 规则文件

<!-- index: 规则文件; .ecss; 样式表重载 -->

写在组件定义之外的规则同样能成为组件样式。ECSS 规则文件被读成有序规则列表（读取接口由[规则文件](ecss-rule-files.md)一章定义），`etaf-component-set-styles` 接受这份列表，因此样式表文件、预览工具或热重载循环都能在不碰组件定义的情况下替换它的规则。`.ebox` 文件格式及其同伴规则属于 Ebox 部分；Component 自己的 `:styles` 子句仍是静态数据，不能自己读取文件。
