# Component

*Component* 把 View 的一部分变成有输入、可复用的命名单元。定义一个 Component 就是登记一份配方；在 View 里调用它就会放置一个实例；每个实例在自己的生命周期里保存输入、Scope 和状态。本章定义定义宏及其子句、props 的默认值与校验、slot、`:view` 与 `:render` 两个前端、setup 与绑定、生命周期钩子、属性透传，以及两个错误条件。

Component 不是 Host：它自己不拥有 Ebox 节点。它的渲染结果是一个 View，可以是 nil、一个 Host，或由 fragment 组合的多个节点。Host 种类、属性和引用见 [Host](hosts.md)；View 语法、节点身份和编译器见 [View](views.md)；实例用来承载响应式状态的 Scope 归属见[响应式系统](reactivity.md#scope)。

<!-- index: Component; Component 实例; prop; slot; 属性透传; 生命周期钩子 -->

## 模型

### 调用、实例与身份

Component 调用与 Host 节点一样是 View 节点：`(demo-notice :severity "warning" title "Disk almost full" ...children...)`。名字在 View 构造时到注册表解析，关键字属性被分成组件声明的 props 和 Host 透传属性，子节点成为 slot 输入。

渲染一次调用会创建或更新一个*实例*。和解按组件和 `:key` 匹配实例（见 [View](views.md#身份)），所以实例在重新渲染中存活：它的输入单元、setup 里创建 ref 和侦听器的 Scope、绑定值和保留的子节点都属于它，不再被渲染时一起释放。

实例是它 setup 所创建东西的归属边界。`etaf-ref`、`etaf-computed`、`etaf-watch` 和 `etaf-local-ref` 都归实例的 Scope 所有，实例销毁时随之停止；这个生命周期由[响应式系统](reactivity.md#scope)定义。

### 定义契约

Component 定义是静态数据，在定义时校验并以名字存进注册表；调用点只求值。定义声明：

- 接受的 props，写作 `(&key NAME ...)`；
- 恰好一个渲染前端，`:view` 或 `:render`；
- 可选的 `:bindings`、`:validate`、`:setup` 和 `:styles`。

没有 `:setup` 的组件是无状态的，可以用 `etaf-render` 渲染；带 `:setup` 的组件需要已挂载的 Runtime，因为它的 Scope 必须有生命周期所有者，[View](views.md) 在讲 `etaf-render` 时说明了这一点。

```elisp :figure 一份组件定义，三个实例
(etaf-define-component demo-chip (&key label)
  :render
  (etaf-view
   (box :padding '((lh 0) (ch 2))
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
     (text :color (etaf-theme-token :ui-accent "#0969da") (expr label)))))

(etaf-view
 (row :item-gap '(ch 1)
   (demo-chip :label "调用 A")
   (demo-chip :label "调用 B")
   (demo-chip :label "调用 C")))
```

## 定义组件

#### Macro: etaf-define-component (name arguments &rest clauses)

按参数声明和子句定义名为 NAME 的组件并登记它。

**参数。**

- NAME 是普通非 nil 符号。它不能是 Host 名，也不能已被另一个定义登记；有意的替换走 `etaf-component-redefine-run`。
- ARGUMENTS 声明 props：`(&key NAME ...)`，每项是 NAME 或 `(NAME DEFAULT)`。prop 名是普通符号；`:key`、分支与列表指令 `:if`、`:else-if`、`:else`、`:for`，以及以 `&` 开头的名字都保留，会被拒绝。
- CLAUSES 是任意顺序的关键字/值对：`:bindings`、`:validate`、`:setup`、`:view`、`:render` 和 `:styles`。每个至多一次，且 `:view` 与 `:render` 必须恰好出现一个。

**语义。**

- `:bindings ((NAME INITIALIZER) ...)` 声明的命名值每个实例初始化一次，按序在 `:setup` 之前。绑定名必须是普通符号，且不得与其他绑定或 prop 重复。绑定值跨重新渲染稳定，`:setup`、两个前端和回调都可以直接读；用 `setq` 重绑词法名不会替换存下来的值。
- `:validate ORDINARY-ELISP` 在默认值解析之后运行，挂载时和每次输入更新各跑一次，早于任何绑定、setup 或渲染看到新输入。返回值被忽略；用 `etaf-check-prop` 或抛错来拒绝输入。它必须纯粹且可能重跑，不能使用实例绑定、state、slot 或生命周期。
- `:setup SETUP` 是普通 Elisp 函数体，不是 lambda。组件没有 `:bindings` 时，它的返回值就是实例的 state；有 `:bindings` 时返回值被忽略。它不得返回函数，也不得构造 View 结构：渲染由前端负责。
- `:view VIEW` 是未引用的 View 语法，随定义一起编译；`:render ORDINARY-ELISP` 是普通 Elisp，返回一个 View，通常经 `etaf-view`。两个前端都收到声明的 props 和当前 slots。`:view` 用 prop 名直接读；`:render` 用 `etaf-current-prop` 或 `etaf-prop` 得到的 source 读实时值。
- `:styles ((SELECTOR ATTRIBUTE ...) ...)` 声明组件的静态样式规则。子句本身属于[组件样式与主题](component-styles-and-themes.md)；语法在定义时校验。

**返回。** 组件名，即引用的符号，因此一个定义形式求值为 NAME。

**错误。** 以下都在定义展开或求值时报 `etaf-component-definition-error`，数据是一条消息字符串：props 未按 `(&key ...)` 声明，或某项不是 `NAME` 或 `(NAME DEFAULT)`；prop 名是关键字、nil、t 或以 `&` 开头；prop 重复或保留；绑定格式不对或重复；绑定与 prop 重复；子句重复或未知；同时给出 `:view` 和 `:render`，或两个都没给；`:setup` 写成 lambda 或构造 View 结构；`:styles` 形式非法。名字已被登记时改报 `etaf-component-call-error`，消息里点名该组件。

**示例。** 一条可关闭的通知：接收 `severity` 和 `title`，自己保存关闭状态，渲染一个状态框和 Dismiss 按钮。

```elisp :run
(etaf-define-component demo-notice (&key (severity "info") title)
  :bindings ((closed (etaf-ref nil)))
  :view
  (box :if (not (etaf-value closed))
       :role "status"
       (row
        (text :font-weight 'bold (expr title))
        (text (expr (format " (%s)" severity))))
       (text :role 'button :tab-index 0
             :aria-label (concat "Dismiss " title)
             :on-press (lambda () (etaf-set-value closed t))
             "Dismiss")))

(etaf-view (demo-notice :severity "warning" :title "Disk almost full"))
```

**参见。** `etaf-view`、`etaf-node`、[组件样式与主题](component-styles-and-themes.md)，以及本章其他条目。

### 子句一览

每个子句一段，并指到定义其行为的小节。

- **props** 在参数列表声明、调用点按关键字传入。[Props](#props) 定义默认值、校验与响应性。
- **`:bindings`** 每个实例在 setup 之前创建命名值。[Setup、绑定与 state](#setup绑定与-state)定义它们的生命周期。
- **`:setup`** 在实例自己的 Scope 里做每实例初始化；它可以注册生命周期钩子、创建响应式状态。[Setup、绑定与 state](#setup绑定与-state)与[生命周期钩子](#生命周期钩子)。
- **`:validate`** 在输入发布前检查值。[校验](#校验)。
- **`:view`** 与 **`:render`** 是两个前端。[`:view` 与 `:render` 两个前端](#view-与-render-两个前端)。
- **`:styles`** 声明静态样式规则。[组件样式与主题](component-styles-and-themes.md)。

### 注册与重定义

定义以确切的名字登记。从同一库重载完全相同的声明，包括 package.el 安装时在源码之后加载字节码，会保留原定义、它捕获的值和已挂载实例。这是幂等加载，而不是热替换：它不会重新初始化状态，也不会刷新从库的词法环境中捕获的值。改变声明、从另一库声明同名组件或普通求值中的重复定义仍会报错，因为静默替换会让已挂载实例和已编译 View 处于不一致状态。需要替换组件或刷新捕获值的写作工具会先销毁旧 Runtime，再在 `etaf-component-redefine-run` 里求值定义。

#### Function: etaf-component-redefine-run (function)

在允许有意重定义组件的前提下运行 FUNCTION。

**参数。** FUNCTION 是零参函数。其他值报 `wrong-type-argument`，数据 `(functionp FUNCTION)`。

**语义。** 调用期间，对已定义名字再次 `etaf-define-component` 会替换注册表条目而不是报错。组件的编译产物随之失效，[View](views.md) 讲述注册表换代时说明了这一点，因此下一次挂载或渲染用新定义。调用之外，除上述未改变声明的库重载外，重复定义仍是错误。旧定义的已挂载实例在 Runtime 销毁前继续使用旧定义，所以应在替换前后销毁旧 Runtime。

**返回。** FUNCTION 的返回值。

**错误。** FUNCTION 不是函数时 `error→ wrong-type-argument`。FUNCTION 内部的错误，包括与 Host 同名或新定义非法，会向外传播，注册表保持原样。

**示例。** 预览工具在销毁 Runtime 之后重新加载组件。

```elisp
(etaf-component-redefine-run
 (lambda () (load "notice-component" nil t)))
```

**参见。** [注册与重定义](#注册与重定义)与 [View](views.md)。

## Props

### 声明、传入与默认值

prop 在参数列表声明为 NAME 或 `(NAME DEFAULT)`，在调用点按关键字传入：`(demo-notice :severity "warning" :title "Disk almost full")`。调用可以传任何已声明的 prop；未声明的属性不会成为组件的业务 prop，而是透传属性，见[属性透传](#属性透传)。

View 里的 prop 值是普通表达式，和其他属性值一样延迟求值，因此从响应式源读出的 prop 会让组件的输入变成动态输入（[View](views.md#属性值)）。

默认值每个实例首次使用时解析：

- 只有调用没有提供该 prop 时才求值默认值。显式传入的 nil 是值而不是缺失，因此不会触发默认值。
- 默认值按声明顺序求值，后面的默认值可以读前面的 prop 值。
- 已解析的默认值由已挂载实例保留：仍省略该 prop 的更新复用该值，不再重新求值；新实例会重新求值。
- 默认值表达式必须能在发布被拒后安全重跑，且不得依赖实例绑定、state 或生命周期。

调用之后提供不同的值时，实例的 prop 单元变化，读过该 prop 的一切随之更新；值按[响应式系统](reactivity.md#相等性)的浅相等规则比较，相等则不更新。

### 校验

`:validate` 是定义的输入契约。它在默认值解析之后运行，挂载时和每次输入更新各跑一次，早于绑定、setup、渲染和新输入的发布。返回值被忽略，所以校验靠抛错来拒绝输入；`etaf-check-prop` 是标准做法。

该形式在词法作用域里拿到声明的 props，也可以用 `etaf-current-prop` 读；它带着组件名为诊断信息，并且必须纯粹，因为可能重跑。输入被拒绝时，实例已发布的 props 和回调保持不变；调用方自己的状态变更不回滚，见[响应式系统](reactivity.md#恢复)。

#### Function: etaf-check-prop (property value valid-p expected &optional component)

当 VALID-P 为 nil 时把 VALUE 报告为非法输入。

**参数。** PROPERTY 是指名输入的 keyword。VALUE 是收到的值。VALID-P 是普通 Elisp 谓词的结果，通常是 `(natnump count)` 或 `(stringp name)`。EXPECTED 是描述字符串，如 `"a nonnegative integer"`。COMPONENT 是输入所有者名字；在 `:validate` 形式里默认取正在校验的组件，校验之外调用的辅助函数必须显式给出。

**语义。** VALID-P 非 nil 时原样返回该值。否则报 `etaf-component-call-error`，消息点名组件、属性、收到的值和期望；大值在消息里缩写。函数不复制、不拥有任何东西，也不得修改值或产生副作用。

**返回。** VALUE。

**错误。** VALID-P 为 nil 时 `error→ etaf-component-call-error`。调用元数据本身非法时 —— 没有组件名、PROPERTY 不是 keyword 或 EXPECTED 不是字符串 —— `error→ etaf-component-definition-error`。

**示例。** `(etaf-check-prop :count count (natnump count) "a nonnegative integer")`

**参见。** [校验](#校验)。

### 随时间的 prop 读取

定义里直接用的 prop 词法名是绑定时的输入快照：在 `:setup` 和 `:bindings` 里它们是 setup 运行时拿到的值。两个访问器把输入随时间的值暴露出来。

#### Function: etaf-prop (name)

返回当前实例稳定、只读的响应式输入 NAME。

**参数。** NAME 是已声明的 prop 名或其 keyword。

**语义。** 在 setup 期调用它拿到该 prop 的响应式 source，然后在计算 getter、侦听器或 View 表达式里用 `etaf-value` 读取。实例内相同的名字返回同一个 source 对象，因此同一 prop 的两个侦听器共享一次读取；source 跟随之后每一次输入，不同于词法快照。名字不是已声明 prop，或不在 setup 期调用，都是错误。

**返回。** 一个只读响应式 source；`etaf-value` 读出来就是当前输入。

**错误。** 在组件 setup 之外调用，或 NAME 不是已声明 prop 时 `error→ etaf-component-definition-error`。

**示例。** 只对某个输入做出反应的侦听器。

```elisp
(etaf-define-component demo-search (&key (query ""))
  :bindings ((q (etaf-prop 'query)))
  :view (text (expr (format "Searching for %S" (etaf-value q)))))
```

**参见。** `etaf-current-prop` 与[响应式系统](reactivity.md)。

#### Function: etaf-current-prop (name)

在渲染期间返回组件输入 NAME 的当前值。

**参数。** NAME 是 prop 名或 keyword。

**语义。** 在 setup 或渲染期间调用，可以从 `:render` 函数体调用，也可以从渲染期间运行的普通 Elisp（例如 `:view` 调用的辅助函数）调用。渲染期间这次读取会被追踪：读过该 prop 的绑定在调用方提供不同值时更新。渲染期间直接用的 prop 词法名同样读实时值，因为前端把它绑到输入单元；`etaf-current-prop` 是普通 Elisp 读取它的方式。

**返回。** 当前输入值；名字未声明时为 nil。

**示例。** `(etaf-define-component demo-label (&key text) :render (etaf-view (text (etaf-current-prop 'text))))`

**参见。** `etaf-prop`。

## Slots

组件调用把内容作为普通子节点传进去（*默认 slot*），或者写成具名 slot 输入 `(slot :name NAME CHILD ...)`。组件内部用 `(slot)` 或 `(slot :name NAME FALLBACK ...)` 投影一个 slot；调用方什么都没提供时渲染 fallback 子节点。

slot 内容跟着调用方：它在调用方的 Context 里求值，保留调用方的样式归属，其中的表达式读调用方的响应式状态。组件决定内容出现在哪里，不决定内容是什么意思。从 slot 读出的值是不透明的；把它交给 View 子节点或包成 View 子节点，且不要保留到实例的 Runtime 之后。

#### Function: etaf-current-slot (name &optional fallback)

返回调用方为 slot NAME 提供的可组合子节点；没有提供时返回 FALLBACK。

**参数。** NAME 是 slot 名，通常是 `default`。FALLBACK 是 slot 为空时的返回值；传一个 View 子节点列表即可渲染 fallback。

**语义。** 在组件的 View 或渲染函数运行时调用。返回的子节点是调用方拥有的 typed View：把它们传入、追加或包成 View 子节点，每个值当作不透明处理。在 `:view` 形式里通常包成 `(expr (etaf-current-slot 'default))`，因为计算出来的子节点列表属于表达式位置。

**返回。** typed View 子节点列表；slot 没有输入时是 FALLBACK。

**错误。** 在组件渲染之外调用时 `error→ etaf-component-definition-error`。

**示例。** 带 header 和主体的面板。

```elisp
(etaf-define-component demo-panel ()
  :view (column
         (row (expr (etaf-current-slot 'header)))
         (box (expr (etaf-current-slot 'default)))))
```

**参见。** `etaf-current-slots`。

#### Function: etaf-current-slots ()

返回当前组件的整个 slot alist，值为不透明、可组合的子节点。

**语义。** 结果是 slot 名到子节点的 alist，值和 `etaf-current-slot` 返回的一样属于调用方；默认 slot 的键是 `default`。它是转发工具：包装组件可以把自己的 slots 交给它包装的组件，而不用逐个点名。归属与生命周期同 `etaf-current-slot`，且只允许在组件渲染期间调用。

**返回。** 新的 slot 名到 typed View 子节点列表的 alist。

**错误。** 在组件渲染之外调用时 `error→ etaf-component-definition-error`。

**示例。** `(etaf-define-component demo-shell () :view (expr (etaf-node 'box (list :class "shell") (append (etaf-current-slot 'default) nil))))` 把默认 slot 转发进一个带样式的 box。

**参见。** `etaf-current-slot`。

## `:view` 与 `:render` 两个前端

两个子句的差别在于 View 何时计算、prop 读取如何追踪；两者产出同一种 typed View。

- `:view` 用结构语言书写，随定义一次编译。实例首次渲染时求值一次，更新时再求值；但它用到的每个 prop 名都是该 prop 单元的追踪读取：只显示一个 prop 的绑定更新时无需重跑整个组件。View 里 Host 与组件形式不引用，prop 名可以直接使用，包括在 `expr` 里。
- `:render` 是普通 Elisp。它跑在一个保留的副作用里：先求值一次，之后它读过的任何源变化时再次求值。`:render` 函数体用 `etaf-current-prop`（追踪）或 `etaf-prop` 的 source 读 props，并必须返回用 `etaf-view` 或 `etaf-node` 构造的 View。

只是拼装 Host 的组件不需要运行期状态，通常用 `:view`；整个输出依赖普通 Lisp 里计算的值，或需要程序化构造节点时，用 `:render`。

### 多根与 nil

组件的渲染结果必须是 nil、字符串或一个 typed View。渲染 nil 合法，什么都不显示，实例保持存活。多根用 fragment 表达：fragment 的子节点并入所在布局，因此组件可以返回 header 和 body 而不增加容器。结果是一个 fragment 时，调用者传进来的 Host 属性是错误，因为没有单一根可以承载样式；调用方需要能传属性时，加一个包装 Host。

## Setup、绑定与 state

setup 是每实例初始化。它运行一次，在脱离渲染的 Scope 里，发生在输入校验之后、首次渲染之前；该 Scope 拥有那里创建的每个响应式对象和引用，并随实例销毁。有 `:bindings` 时绑定值在 setup 内按序创建；无论有没有绑定，定义的 `:setup` 在组件没有绑定时可以返回一个 state 值。

无状态组件 —— 没有 `:setup`、`:validate` 和状态 —— 可以用 `etaf-render` 渲染；带 setup 的组件需要已挂载的 Runtime，`etaf-render` 对它报 `etaf-renderer-error`，见 [View](views.md)。

#### Function: etaf-state ()

返回当前组件实例确切的 setup 结果。

**语义。** 在组件渲染期间调用。值就是 `:setup` 形式返回的东西，包括 nil；是否存在 setup 独立追踪，因此 nil 也是合法 state。使用 `:bindings` 的组件必须直接引用命名值，不要调用 `etaf-state`；没有 `:setup` 的组件没有 state 可返回。

**返回。** setup 的结果。

**错误。** 在组件渲染之外调用、当前组件没有声明 `:setup`、或当前组件使用 `:bindings` 时 `error→ etaf-component-definition-error`。

**示例。** 画布组件把进程存进 setup state。

```elisp
(etaf-define-component demo-canvas (&key (text ""))
  :setup (start-editor-process text)
  :view (text :ref 'surface (expr text)))
;; 渲染期间：
(process-status (etaf-state))
```

**参见。** [Setup、绑定与 state](#setup绑定与-state)与 `etaf-prop`。

## 生命周期钩子

三个钩子让组件在实例生命周期的边界行动。每个都在 setup 期注册，接收零参回调；在 setup 之外注册，或回调不是函数，都是错误。

- **mounted** 在实例首次发布之后运行：缓冲区输出已经存在，几何已提交。适合打开外部资源、订阅进程或读取初始尺寸。
- **updated** 在实例参与过的某次提交之后运行 —— 输入、slot 或渲染输出变了。新挂载的实例不跑它，输出没变的实例也不跑。
- **unmounted** 在实例销毁时运行：它不再出现在父节点里，或它所在的 Runtime 卸载时。适合释放 mounted 打开的东西；不过实例的 Scope 会自动释放它拥有的响应式对象。

钩子在渲染之外运行，可以写状态；它们的错误和别的发布工作一样被 Runtime 的排空收集。注册顺序保留，同一时刻内钩子按注册顺序运行。卸载 Runtime 会为当时仍活着的实例运行 unmounted 钩子。

#### Function: etaf-on-mounted (callback)

在当前组件首次发布后运行 CALLBACK。

**参数。** CALLBACK 是零参函数。

**语义。** 在当前组件的 setup 期注册；回调在发布该实例的那次提交之后运行，处于 Runtime 上下文且不在渲染期。宿主缓冲区此时已显示渲染输出。

**错误。** CALLBACK 不是函数时 `error→ wrong-type-argument`，数据 `(functionp CALLBACK)`；在组件 setup 之外调用时报错。

**示例。** `(etaf-on-mounted (lambda () (message "notice shown")))`

**参见。** `etaf-on-updated`、`etaf-on-unmounted`。

#### Function: etaf-on-updated (callback)

在当前组件参与一次更新之后运行 CALLBACK。

**参数。** CALLBACK 是零参函数，在 setup 期注册。

**语义。** 回调在某次提交改变了实例的输入、slot 或输出之后运行；新挂载的实例只跑 mounted 钩子，没有变化的实例什么都不跑。

**错误。** CALLBACK 不是函数时 `error→ wrong-type-argument`，数据 `(functionp CALLBACK)`；在组件 setup 之外调用时报错。

**示例。** `(etaf-on-updated (lambda () (etaf-scroll-into-view (etaf-current-runtime) 'selected)))` 在选中项变化后让选中行保持可见。

**参见。** `etaf-on-mounted`、`etaf-on-unmounted`。

#### Function: etaf-on-unmounted (callback)

在当前组件销毁时运行 CALLBACK。

**参数。** CALLBACK 是零参函数，在 setup 期注册。整个 Runtime 卸载时它也会运行。

**语义。** 回调在实例不再被渲染之后、处于 Runtime 上下文里运行一次。实例的 Scope 独立销毁，因此 Scope 拥有的清理 —— ref、侦听器、局部引用 —— 不需要钩子。

**错误。** CALLBACK 不是函数时 `error→ wrong-type-argument`，数据 `(functionp CALLBACK)`；在组件 setup 之外调用时报错。

**示例。** `(etaf-on-unmounted (lambda () (delete-process watch-process)))`

**参见。** `etaf-on-mounted`、`etaf-on-updated`。

## 属性透传

调用者可以给组件调用传 Host 属性，即使组件本身没有声明这样的 prop。这些*透传属性*应用到组件渲染结果的根上，因此一个可复用的 Button 能从使用者那里接收 `:disabled`、`:on-press` 或 `:class`：

- Host 根把它们按 [Host](hosts.md#值与冲突)的规则合并进自己的属性。
- 字符串根变成一个携带这些属性的 text Host。
- 组件调用根转发它们：内部组件已声明的 props 成为它的 props，其余成为它的透传属性。
- fragment 根、空结果和其他值无法接收属性，报 `etaf-component-call-error`。

合并规则就是 Host 规则：调用方的非 nil 样式值获胜；`:class` 与根的类取并集；事件回调串联，根的回调在前；`:disabled` 按 `or` 组合；`:role` 和标识类 `:aria-*` 属性归根所有，调用方给出不同的值报错；`:use` 列表拼接，`:keys` 合并。属性表达式在调用方上下文求值，因此可以读调用方的状态。根 Host 种类不接受的样式属性会被拒绝，消息点名组件、Host 种类和属性。

## 语义细节

### 实例记录

实例保存：身份（定义和调用的 `:key`）、每个已声明 prop 一个响应式单元加 prop 名表、当前调用及其解析后的 slots、为 setup 创建的 Scope、state 或绑定值、保留的渲染 View、props 动态时的输入副作用、已注册的生命周期钩子，以及 Runtime 用来发布和退役它的记账标志。Runtime 还把每个活实例放在一张表里供内省，见 [Runtime](runtime.md)。

### 初始化与更新

挂载或首次渲染一个调用按序初始化实例：创建实例与其 prop 单元；解析默认值、校验输入并写入变化的单元；创建 setup Scope 并运行 setup；渲染前端；把实例登记为新实例，让提交发布它并运行 mounted 钩子。有 setup 而没有 Runtime 的组件在前两步之后停下，报 `etaf-renderer-error`。

实例的更新始于父节点重新渲染、产出按身份匹配的新调用。新调用替换旧调用。prop 值不同时输入单元更新，读过它们的读者重跑；调用的 slots 变了时保留的 slot 内容更新；透传属性变了时渲染结果带上它们重新投影。前端随后按各自方式重新渲染：`:view` 实例重新求值编译好的 View，`:render` 实例只在副作用追踪到的读取变化时重跑。调用被移除时实例销毁并运行 unmounted 钩子。

### 代价

输入、slot 和输出都没变时组件没有代价：和解在每个调用处只做一次身份比较。某个输入变化时，代价是那个输入的读者 —— 绑定到某个 prop 的 Host 属性只更新那个 Host，而不是整个组件 —— 加上变化所要求的前端工作。读多个源的 `:render` 前端每次排空重跑一次，而不是每个源一次。跨更新保留实例，才让代价与变化量成正比而不是与组件大小成正比；[View](views.md#身份)的键控身份规则让保留成为可能。

## 错误与恢复

组件问题分成两类：定义问题是定义里的编程错误，输入问题是调用处的数据错误。

#### Error: etaf-component-definition-error

非法的组件定义，或组件 API 在其阶段之外被使用，消息是 "Invalid ETAF Component definition"。它是 `etaf-view-error` 的子类；数据是只有一条格式化消息字符串的列表。

| 消息 | 原因 |
| --- | --- |
| `"Component props must use (&key NAME ...), got %S"` | 参数声明不以 `&key` 开头 |
| `"Component props must be NAME or (NAME DEFAULT): %S"` | prop 项格式不对 |
| `"Component prop name must be an ordinary symbol: %S"` | prop 名是关键字、nil、t 或以 `&` 开头 |
| `"Duplicate Component prop: %S"` | 同一 prop 声明两次 |
| `"Component prop %S is reserved by the View grammar"` | prop 名与指令同名 |
| `"Component %S binding must be (NAME INITIALIZER): %S"` | 绑定格式不对 |
| `"Component %S binding %S duplicates a binding or prop"` | 绑定名冲突 |
| `"Component %S has duplicate :render"` 及其他子句的同款 | 子句给了两次 |
| `"Unknown Component definition keyword %S"` | 列表之外的子句 |
| `"Component %S must choose :view or :render, not both"` 与 `"Component %S requires exactly one of :view or :render"` | 前端子句不一致 |
| `"Component %S :setup cannot construct View structure"` | `:setup` 形式里出现 `etaf-view` 或 `etaf-node` |
| `"Component %S :setup cannot return a render function"` | `:setup` 写成 lambda |
| `"Input checks require a Component name, keyword property and expectation string"` | `etaf-check-prop` 元数据非法 |
| `"Component %S has no declared prop %S"` | `etaf-prop` 用了未声明的名字 |
| `"etaf-prop requires Component setup"` | `etaf-prop` 不在 setup 期 |
| `"Slots are available only during Component view/render"` | `etaf-current-slot` 或 `etaf-current-slots` 不在渲染期 |
| `"ETAF state is available only during Component view/render"`、`"Current Component does not declare :setup"`、`"Current Component uses :bindings; refer to its named values directly"` | `etaf-state` 用法错误 |

#### Error: etaf-component-call-error

非法的组件调用或输入，消息是 "Invalid ETAF Component call"。它是 `etaf-view-error` 的子类；数据是只有一条格式化消息字符串的列表。

| 消息 | 原因 |
| --- | --- |
| `"Unknown ETAF Host or Component: %S"` | 调用名既不是 Host 也不是组件 |
| `"Component %S is already registered"` | 在 `etaf-component-redefine-run` 之外重复定义 |
| `"Component %S conflicts with a core Host"` | 组件与 Host 种类同名 |
| `"Component %S property %S received %S; expected %s"` | 输入被 `:validate` 或 `etaf-check-prop` 拒绝 |
| `"Component %S must render nil, a string, or one typed View; got %S"` | 渲染结果不是 View |
| `"Component %S has multiple roots; Host attrs have no target"` | 对 fragment 结果透传属性 |
| `"Component %S cannot apply Host attrs to %S"` | 对不支持的结果透传属性 |
| `"Component %S root Host %S rejects attribute %S"` | 根 Host 种类不接受该透传样式 |
| `"Component %S root Host %S owns %S; conflicting fallthrough value %S"` | 调用方给归属语义属性冲突值 |
| `"Duplicate Component slot %S"` 与 `"Component default slot has both children and an explicit input"` | slot 输入冲突 |
| ``"Stateful Component requires `etaf-mount'"``（`etaf-renderer-error`） | 无 Runtime 渲染带 `:setup` 的组件 |

### 恢复

| 失败 | 留下什么 |
| --- | --- |
| 定义格式非法 | 注册表不变；失败的定义没有被登记 |
| 重复定义 | 已登记的定义保留；有意替换用 `etaf-component-redefine-run` |
| 输入被拒绝 | 实例保留之前发布的 props、回调和输出；调用方自己的状态变更保留，下一个合法输入正常更新 |
| 渲染或更新失败 | 已提交的缓冲区输出保留；工作在下一次排空或 flush 时重试，见[响应式系统](reactivity.md#恢复) |
| 实例被销毁 | 子节点、Scope、响应式对象和引用释放；之后再读它的输入会报错 |

定义错误是编程错误，必须在源码里修。输入错误是数据，属于调用处：实例以可控方式拒绝该值，保留上一次成功发布，输入恢复合法后立即恢复。
