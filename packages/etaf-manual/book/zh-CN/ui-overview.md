# UI 组件库总论

`etaf-ui` 是 ETAF 文本应用的官方可复用组件目录。它不引入新的框架概念：每个组件都是普通 Component，渲染结果是 Host 组成的 View，经同一套层叠着色、读取同一个 Theme、由同一交互层驱动。目录带来的是一批具名、可键盘操作、契约统一的控件，应用因此可以直接组合出完整界面，不必每次都重造按钮、列表、对话框和网格。本章定义这套共同契约：输入归谁所有、条目怎么写、每个组件承诺哪些键盘行为、组件如何留在标准行高内、怎样读取主题 token，以及定义该用 `:view` 还是 `:render`。随后各章分别展开每一族：[图标](ui-icons.md)、[容器](ui-containers.md)、[反馈与状态](ui-feedback-and-status.md)、[按钮与选择控件](ui-buttons-and-choice-controls.md)、[文本输入控件](ui-text-input-controls.md)、[内嵌原生编辑](ui-embedded-editors.md)、[选择器与菜单](ui-pickers-and-menus.md)、[浮层](ui-overlays.md)、[导航与集合](ui-navigation-and-collections.md)、[数据展示](ui-data-display.md)、[组合组件](ui-composite-components.md)、[面板与窗口](ui-panels-and-windows.md)、[桌面导航与平铺](ui-desktop-navigation-and-tiling.md)、[媒体与互动](ui-media-and-reactions.md)、[格子与字符表面](ui-grids-and-character-surfaces.md)，最后是 [Gallery 与验收面](ui-gallery-and-acceptance.md)。[Component](components.md)定义 Component 模型本身，[组件样式与主题](component-styles-and-themes.md)定义规则列表与 token 机制，[键盘](keyboard.md)定义每个组件所依赖的键盘层。

## 受控组件

<!-- index: controlled input; bind; caller-owned state; reported callback -->

目录里每个交互组件都是*受控*控件：应用拥有值，组件只负责渲染并报告用户做了什么。默认接口是一对 prop——值 prop（如 `:value` 或 `:checked`）加回调 prop（如 `:on-change`、`:on-press`、`:on-select` 或 `:on-toggle`）。回调收到候选的新值或选中的键，由应用决定是否保存、怎么保存。组件从不写应用数据，也不保存它的第二份副本。

对于声明了 `:bind` 的组件，它是值/回调对的另一种写法：调用方传入一个已存在的可写 ref。绑定控件从这个 ref 读当前值，把候选更新写回它；之后对同一 ref 的写入会更新所有已挂载的控件和所有其他读者。因为 ref 属于调用方，`:bind` 与显式值/回调对互斥：非 nil 的 bind 再传值或回调（包括显式 nil）会被拒绝。卸载只释放控件自己的处理器与订阅，不销毁也不清空调用方的 ref；发布被拒绝时保留此前的绑定目标。[响应式系统](reactivity.md)定义写入规则的一般形式。

只有真正局部的呈现状态属于组件。下拉菜单拥有自己的打开标志和锚点，因为它们只对那个保留实例有意义；而 `etaf-popover` 的 `:open` 仍是受控的，由应用决定浮层何时可见。值、选择、展开集合、窗口几何和媒体播放始终归调用方所有；目录的回调只是*请求*变更，命名也遵循这个含义——`:on-close` 请求关闭，自己不关闭。

每个 prop 分别声明是否接受普通值、ref 或 computed，不要从相似名称推断响应式源支持：例如 Calendar 的 `:value` 是整数日号，而 Range 的 `:value` 接受响应式源。在响应式 View 中传 `(etaf-value ref)` 则提供当前普通值并订阅该 View。支持 ref/computed 的 prop 保留源身份；组件在渲染边界或保留 Host 绑定中消费它，具体见对应条目和 [Component](components.md)。

## 组件、Host 与实例

目录组件不是 Host：它不拥有自己的 Ebox 节点。渲染结果是 View——nil、一个 Host，或由 fragment 分组的多个 Host——而组件实例是会跨重渲染存活的单位，按 Component 与 `:key` 匹配。实例保留自己的输入、初始化期间创建的 ref 与绑定所属的 Scope，以及保留子节点，直到它不再被渲染或其 Runtime 被卸载。

这个分工决定了组件运行需要什么。只组装 Host 与语义内容的组件是无状态的，既能被 `etaf-render` 渲染也能挂载。声明初始化、绑定或保留状态的组件需要已挂载的 Runtime，因为它的 Scope 必须有生命周期所有者；不给挂载直接渲染会报 `etaf-renderer-error`。目录组件和其他 Component 一样遵守这条规则，其文档会标明哪些需要活着的 Runtime——例如文本输入的编辑会话，或模式存于保留属性的窗口。

Host 身份、slot 与属性透传都是普通 Component 规则：目录组件读取自己的 props，投影调用方的默认 slot 与具名 slot，并渲染调用方给的内容，所以传给组件调用的 `:class`、`:ref` 或 `:id` 会到达代表它的那个 Host。目录不会给根额外包容器，因此产生 fragment 的组件直接汇入外层布局。

## 组件条目怎么读

目录条目以签名和用途开头。“参数”说明输入、默认值和回调实参，“语义”说明状态归属、slot、焦点、事件与尺寸，并按需提供错误和示例。包根入口的 Commentary 是受支持 API 的唯一清单，每个 Component 记录包含简明的 Parameters 参数说明。[Gallery](ui-gallery-and-acceptance.md) 在交互样例旁显示同一条记录，不另行维护 API 清单。本手册拥有详细语义及跨组件解释。

组件参数与公共 Host 属性透传是两回事。布局、绘制、身份和可访问性属性遵循 [Component](components.md) 与 [Host](hosts.md)；将属性传给组件根，并不意味着它会传给每个内部控件。单位也是契约的一部分：`(px N)` 是像素长度，`(ch N)` 是字符宽度长度，`(lh N)` 是标准文本行；手势位移是像素对，不是新的比例或几何。

prop 就是普通 Component prop，[Component](components.md) 的调用规则原样适用：调用处的关键字参数、缺失时才解析的默认值、显式 nil 与省略的区别，以及 prop 越出契约时的已定义错误。无效输入在检查契约的位置报出——校验期或渲染期——消息包含组件与属性名，因此失败可以追溯到引起它的调用。

## 键盘与焦点

目录里每个组件都能通过 ETAF 的键盘层操作；不能键盘激活的组件不会被目录接受。基线承诺是每个控件一个 Tab 停靠点：Tab 能到达交互控件，方向键以及 `C-n`、`C-p`、`C-b`、`C-f` 在复合控件内部移动。集合类控件——tabs、segmented 与 radio 选择器、桌面 bars、window controls、表格、列表、树、日历、breadcrumbs、steps 与 tile grids——表现为一个 Tab 停靠点，进入点是选中项或焦点项，所以长列表不会淹没 Tab 顺序。模态表面——对话框、抽屉、浮层、菜单与媒体查看器——建立键盘作用域：作用域内的键属于该表面自己，Escape 请求关闭，关闭后焦点回到打开它的控件。`?` 打开只读键帮助，列出当前作用域内的键。[焦点](focus.md)定义 Tab 顺序、组进入与模态作用域，[键盘](keyboard.md)定义 `:keys`、方向处理与帮助。

组件自己的按键行为是条目的一部分：增加了哪些键、它们做什么、保留了哪些键。不能绑定某个键的组件在校验期报告，而不是悄悄丢掉绑定。

## 行高与尺寸

目录的默认尺寸是一个标准行。label、button、checkbox、badge、tag、keycap 或图标恰好占一个文本行；行尾留白用不撑行的行单位表达，因此把组件堆进 column 会得到可预测的网格，不会多出意外空行。形状更大的组件会写明：搜索框是三行的 pill，文字上下各留半行；文本输入的可见高度跟随 `:rows` 下限；图标默认恰好一行，`:lines 2` 时恰好两行，尺寸被夹在这些行内，所以再大的字形也不会顶开布局。内在尺寸保持内在：视口变化时 tile grid 的格子和扑克牌保持设定的格尺寸，重排发生在外层布局里，而不是拉伸控件。

这条规则对定位内容尤其重要。窗口、可调整面板以及任何把文本放进画布的组件都共享画布的行高，Ebox 在发布前就拒绝解析行高超过它的字体；更大的 CSS 字号不会让画布变大。[盒与常规流](boxes-and-normal-flow.md)定义行与标准行从何而来，面板与窗口章详述画布契约。

## 主题 token

目录组件通过主题 token 着色，而不是写死颜色。token 命名一个语义角色——表面、弱化前景、强调填充、状态色、表格选中——组件在声明被下降（lower）的那一刻读取它，所以提供一次 Theme 就能通过重新下降静态规则与保留属性，让子树里的每个组件换装，而不重渲染树。[组件样式与主题](component-styles-and-themes.md)定义 token 的解析、提供方式与基础词表；目录各章定义自己那一族的 token，[主题 token 表](theme-token-table.md)列出完整词表。

组件总是为自己读取的每个 token 提供内置回退值，因此没有任何 Theme 时目录也能运行且视觉自洽；在子树里提供某个键就会覆盖回退值。回退值就是目录的默认亮色外观。桌面 shell 还会读取自己的 shell token，因此窗口管理器可以独立地把 shell 及其选择器调暗或换色，而保留对话框的清晰。token 按声明解析，所以在保留 Host 属性或静态规则里读取的 token 固定的是*主题值*而非颜色：切换所提供的 Theme 会让同一批已挂载组件重绘。

### 应用调色板

应用通常只有几种自己的颜色（表面、正文、凸起的面板、边框、弱化文字和强调色），并希望每个目录组件都跟着它们走。`etaf-ui-theme-tokens` 把这样一份调色板映射到目录的颜色 token 上，应用只需提供一个 Theme，而不必逐个列出 `:ui-*` 键。

#### Function: etaf-ui-theme-tokens (palette)

返回应用调色板 PALETTE 对应的目录 Theme token。

**参数。** PALETTE 是 `#RRGGBB` 颜色角色组成的 plist。`:bg`（应用表面）和 `:fg`（正文）必填。可选角色有 `:panel`（凸起表面，默认 `:bg`）、`:track`（进度条与范围条的轨道，默认 `:panel`）、`:border`（线条）、`:muted`（次要文字）、`:dim`（禁用文字，默认 `:muted`）、`:accent`（默认 `:fg`）、`:accent-fg`（强调色上的文字，默认白色）、`:accent-soft`（选中与色调填充），以及状态角色 `:success`、`:warning`、`:danger` 和 `:info`（默认 `:accent`），每个状态角色都有 `-bg` 与 `-border` 变体。

**语义。** 省略的角色会被推导：`:border` 把正文色以 18% 混入表面，`:muted` 把表面色以 35% 混入正文，`:accent-soft` 把强调色以 16% 混入表面，状态的 `-bg` 把状态色以 12%、`-border` 以 35% 混入表面，默认状态色按 `:bg` 是亮是暗选取。随后每个角色填充所有以它为名的 token：`:panel` 成为面板、shell、选择器、窗口标题栏与禁用状态的背景，`:border` 成为所有边框与分隔线，`:accent` 成为主按钮、范围填充与表格选中文字，其余依此类推。结果只含颜色；间距与圆角 token 保持目录默认值。

**返回。** 一个新的 `:ui-*` 键 Theme plist，可以追加在应用自己的 Theme 键之后交给 `etaf-theme-provide`。同一个键取第一个值，所以放在结果之前的 token 会覆盖它。

**错误。** PALETTE 不是 plist、包含上面列表之外的角色、某个值不是字符串，或缺少 `:bg` 或 `:fg` 时，发出 `wrong-type-argument`。

```elisp
(etaf-theme-provide
 (append '(:ui-shell-bg "#0B1220")
         (etaf-ui-theme-tokens '(:bg "#101925" :fg "#E5EDF7" :panel "#182332"
                                 :border "#2B3A4E" :accent "#356BB2"))))
```

### 派生状态色

应用要从自己的调色板派生出悬停底色、选中底色或表面层级时，需要的是一套 `#RRGGBB` 上的算术，而不是第二份调色板。

#### Function: etaf-ui-color-mix (from to amount)

返回从 FROM 向 TO 混合 AMOUNT 之后的颜色。

**参数。** FROM 与 TO 是 `#RRGGBB` 颜色，AMOUNT 是 0 到 1 之间的比例：0 得 FROM，1 得 TO。

**语义。** 三个通道各自插值再取整，结果与直接混合的观感一致。其他写法的颜色（命名颜色、`#RGB` 简写、`unspecified-bg`）原样返回，这样用命名颜色的主题仍然可用，而不是报错。

**返回。** 一个 `#RRGGBB` 字符串；两个颜色中有一个不是这种写法时返回 FROM 本身。

**错误。** 无。AMOUNT 不是数字时由算术报 `wrong-type-argument`。

```elisp
;; 悬停底色：表面颜色里混入 10% 的正文颜色。
(etaf-ui-color-mix "#FAFAFA" "#383A42" 0.10)  ; => "#E9E9E9"
```

目录组件用这个函数自己派生状态层级，而不向调用方索取一个悬停色，因此深色主题和浅色主题都得到一层标签仍然清楚可读的底色。目录自己的兜底值就是参照：悬停底色混 8%，未被选中的胶囊混 12%，禁用态混 4%。

## `:view` 与 `:render` 怎么选

`etaf-define-component` 的两个作者前端对目录组件都是普通选择，条目的内容描述行为，不描述用了哪一个。正如 [Component](components.md) 所定义，`:view` 是与定义一同编译的结构语言：它用到的每个 prop 名都是一次被追踪的读取，因此只组装 Host 与语义内容的组件应当用它，局部更新可以只重绘一个绑定，不必重跑整个渲染。`:render` 是在保留 effect 里求值的普通 Elisp；当输出依赖在 Lisp 里读取的 computed 值、必须程序化构建节点、或必须先对普通数据分支再决定结构时使用它。两者收到同样的 props、slot 与 Scope，也都能把静态规则与 Host 属性混用。

给目录新组件作者的实际规则：先用 `:view`；只有因为上述原因才把组件改成 `:render`，不要因为 View 大或 props 多就改。

## 错误与恢复

- prop 越出契约时报 `error→ etaf-component-call-error`，消息含组件名、属性、收到的值与期望，由 `etaf-check-prop` 抛出。校验期与渲染期都用这个条件，调用方不必区分组件在哪个时刻检查输入。
- 被拒绝的输入不会发布：已挂载实例保留此前成功发布的 props 与回调，绑定控件保留此前的绑定目标。它不会撤销调用方已经写入的业务 ref，因为那次写入属于应用。
- 定义写坏是另一类失败：组件定义展开或求值时抛 `error→ etaf-component-definition-error`；在有意重定义路径之外注册重名组件报 `error→ etaf-component-call-error`。
- 有状态的组件没有已挂载 Runtime 就渲染时报 `error→ etaf-renderer-error`，与所有 Component 一样。目录条目会说明何时适用。
- 依赖外部程序的组件把缺失报告为带程序名的 `user-error`，而不是组件输入错误，因为调用本身是合法的。

**参见。** [Component](components.md)、[组件样式与主题](component-styles-and-themes.md)、[Host](hosts.md)、[键盘](keyboard.md)与[文本输入](text-input.md)。
