# View

*View* 描述一个 ETAF 应用要显示的内容。它用一种小型结构语言书写，由 `etaf-view` 规范化，再由渲染器降为 Ebox 节点：组件返回 View，`etaf-mount` 发布一个 View，`etaf-render` 则在没有 Runtime 的情况下降下一个 View。本章定义这门语言、规范化后的值、View 内表达式在什么时候求值，以及从 Lisp 构造 View 的函数。

View 是描述，不是活对象：它本身不拥有状态，也不拥有缓冲区文本。它的动态部分读取响应式源，这些读取何时引起再次求值由[响应式系统](reactivity.md)定义。有哪些 Host 种类、各接受哪些属性，属于 [Host 章](hosts.md)；组件、props 和 slot 属于 [Component 章](components.md)。

<!-- index: View; 结构形式; View 值; expr; 键控列表; fragment -->

## 模型

### 结构形式

View 的每个节点——Host 或组件调用——都写成一个形式：

```elisp
(NAME :PROPERTY VALUE ... CHILD ...)
```

NAME 是 Host 符号（如 `text`、`column`），或用 `etaf-define-component` 定义的组件名。属性是关键字/值对，必须排在第一个子节点之前；子节点紧随其后，是节点的内容。属性值就是普通的 Elisp 形式，不是引用的数据语言，因此 `(text :font-weight (if alert 'bold 'normal) "Hi")` 是合法节点。

```elisp :figure 一个 column、一个标题盒与一行两个盒子
(etaf-view
 (column :width '(ch 40) :item-gap '(lh 0)
   (box :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
        :padding '((lh 0) (ch 2))
     (text :color (etaf-theme-token :ui-accent "#0969da")
           :font-weight 'bold "标题"))
   (row
    (box :width '(ch 20)
         :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
         :padding '((lh 1) (ch 1))
      (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "左子节点"))
    (box :width '(ch 20)
         :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
         :padding '((lh 1) (ch 1))
      (text :color (etaf-theme-token :ui-disabled-fg "#687386") "右子节点")))))
```

### View 值

写下一个 View 形式会得到一个*规范化 View*：属于一个小型类型集合的某个值。

| 值 | 产生自 |
| --- | --- |
| nil | nil 形式，或返回 nil 的 `expr` |
| 一个 text View | 子节点位置的字符串，或 `text` Host 内的 `expr` |
| 一个 Host 节点 | `box`、`row` 等 Host 的调用 |
| 一个组件调用 | 已注册组件的调用 |
| 一个表达式区域 | `expr`、条件分支或键控列表 |
| 一个 slot 请求 | 组件内的 `slot` 形式 |

只有这些值才是 View。形状相同但未被构造的普通列表，比如 `('text "Hi")`，只是数据，不会渲染；所以由 Lisp 计算出来的 View 必须用 `etaf-view` 或 `etaf-node` 构造，放进子节点位置时还要包成 `(expr ...)`。

### View 什么时候求值

有三个时刻值得区分：

- **编译。** `etaf-view` 在某个调用点首次展开时，其形式被编译成一份可复用的蓝图：字面量部分成为静态骨架，属性、`expr` 形式、分支条件、列表来源、key 和 slot 成为延迟程序。
- **实例化。** 求值编译后的调用点会构造出 View 值。字面量子树取自共享缓存；动态部分成为稍后求值的 thunk。
- **渲染。** 渲染器遍历 View 值：Host 节点绑定自己的属性，组件调用创建或更新实例，表达式区域求值自己的函数，条件分支选中一个臂，键控列表对其行做和解，fragment 被摊平。动态属性值、条件、列表来源和 `expr` 结果只在这里运行。

因此，写出或读取一个 View 值绝不会运行应用表达式。这些表达式做的每次响应式读取，都由运行它们的绑定追踪，见[响应式系统](reactivity.md)。

## `etaf-view` 宏

#### Macro: etaf-view (form &optional _environment)

从结构形式 FORM 构造一个规范化 ETAF View。

**参数。** FORM 是上面语法中的、不加引用的结构形式。ENVIRONMENT 会被接受并忽略；Emacs 主动展开顶层形式时会传入宏环境。不要给 FORM 加引用：被引用的形式属于放错位置的 Elisp 表达式，会被拒绝。

**语义。**

- 形式按调用点编译一次，之后每次求值都复用。嵌套形式编译在同一份蓝图中，所以一个调用点产出一个编译单元。
- 字面量属性和子节点只物化一次，在多次求值之间共享；其余表达式一律推迟到渲染期。
- 名字在 View 构造时解析：注册为组件的符号可以出现在任何允许 Host 的位置，得到的调用遵循组件规则。
- 手写节点、以及必须返回 View 的普通 Elisp 代码，都用 `etaf-view` 构造。

**返回。** 一个规范化 View 值：nil、text View、Host 节点、组件调用、表达式区域或 slot 请求。

**错误。** 结构不合法时，在展开期 `error→ etaf-view-syntax-error`，例如属性出现在子节点之后、属性缺值、属性重复、`expr` 含不止一个形式、`text` 节点没有恰好一个载荷，或分支、`for` 形式不完整。求值结果不合法时，在 View 构造期间 `error→ etaf-component-call-error`，例如未知名字、非关键字的属性名，或代码构造的 View 里属性重复。

**示例。**

```elisp
(etaf-view (text :font-weight 'bold "Hi"))
;; ⇒ 一个 text View ; display
```

**参见。** `etaf-node`、`etaf-render`，以及 [Host](hosts.md)、[组件](components.md)和 [Runtime](runtime.md) 三章。

### 属性值

属性值是普通 Elisp 表达式，其求值推迟到渲染期；它不是引用式字面量语言。

- 字面量——nil、t、数、字符串、字符、关键字或带引用的形式——存进编译单元并共享，不会再次求值。
- 其他表达式成为 thunk，在所属节点渲染时运行，运行处在调用点的词法环境中。thunk 可以读词法变量、组件 props 和响应式源。
- 读响应式源的 thunk 会让该源成为所得绑定的一条依赖。之后的写入只运行读过该源的绑定，而不是整个 View。
- 裸符号按变量查找，所以符号值必须加引用：写 `'bold`，不要写 `bold`。
- 同一个属性不得出现两次，属性名必须是关键字。在结构语言里这两者都是语法错误；在 Lisp 里构造属性列表时它们是调用错误。

### 子节点位置

子节点位置接受这些形式：

| 形式 | 含义 |
| --- | --- |
| nil | 什么都不放；该位置不产出节点 |
| 字符串 | 一个 text View |
| 嵌套形式 | 一个 Host 节点或组件调用 |
| `(expr FORM)` | FORM 在渲染期算出的 View 结果 |
| `(slot ...)` | 提供给组件默认 slot 或具名 slot 的调用方内容 |

普通 Elisp 表达式不是子节点：`(column (format "n=%d" n))` 会被拒绝，必须写成 `(column (expr (format "n=%d" n)))`。这条规则让结构与计算的分界保持明确，编译器也才能把其余子节点都当作结构处理。

结构子节点位置上的 `expr` 值可以是 nil、字符串、一个有类型的 View，或由这些值组成的真列表；嵌套列表会被摊平。其他值（比如数字）在渲染期抛出 `etaf-renderer-error`。

两类节点对子节点还有额外限制：`text` Host 恰好接受一个载荷，`image` Host 完全不接受子节点。

### expr

#### Syntax: expr (expr FORM)

求值一个普通 Elisp 形式，并用它的 View 结果替换该形式。

**参数。** FORM 恰好是一个普通 Elisp 形式。它可以读词法变量和组件 props、调用函数、读取响应式源。它不得产生副作用：渲染期写 ref 或创建响应式对象会抛出 `etaf-render-side-effect-error`，见[响应式系统](reactivity.md#渲染不产生副作用)。

**语义。** 该形式成为一个带自身绑定的、被保留的表达式区域。区域首次渲染时求值 FORM；FORM 读过的任何源变化后再次求值，且只修补这个区域。在 `text` Host 内，结果必须能解析成文本，所以可以接受字符串、表示空串的 nil，或由若干字符串组成的真列表（按序拼接）；其他值抛出 `etaf-renderer-error`。

**返回。** FORM 的值。在结构位置，该值必须是 View，或由 View 组成的真序列，见[子节点位置](#子节点位置)。

**错误。** 形式不含恰好一个表达式时 `error→ etaf-view-syntax-error`。结果无法在所在位置显示时 `error→ etaf-renderer-error`，例如结构位置上出现数字，或 `text` Host 的载荷不是字符串。

**示例。**

```elisp
(etaf-view (column (text (expr (format "%d items" (etaf-value count))))))
```

**参见。** [响应式系统](reactivity.md)，其中定义了追踪以及区域运行的各阶段。

### 条件分支

#### Syntax: :if (:if CONDITION)

用 `:if`、`:else-if` 和 `:else` 在一组兄弟节点之间选择。

**参数。** CONDITION 是渲染期求值的普通 Elisp 表达式。一条分支链的首节点带 `:if`；其后的兄弟节点带 `:else-if` 及各自条件，或带 `:else` 且值为字面量 t。一条链最多一个 `:else`，且必须排在最后。

**语义。** 条件按顺序求值，直到某个为真，只有那个臂会被建立；命中臂之后的条件不再求值。没有命中且没有 `:else` 时，该位置什么都不显示。条件是被追踪的读取，所以变化会重新选臂。

换臂时，区域按身份对子节点做修补：新臂中与上一臂某节点身份相同的节点被原地更新并保留既有状态；上一臂的其余节点被释放。因此，两个臂是同一个组件的调用时，除非 key 将其分开，否则它们共享同一个实例。

**错误。** 出现以下情况时 `error→ etaf-view-syntax-error`：一个节点带多于一个分支指令；一个节点同时带分支和 `:for`；`:else` 不是字面量 t；`:else-if` 排在 `:else` 之后；一条链带多于一个 `:else`；或 `:else-if`、`:else` 节点前面没有 `:if`。

**示例。**

```elisp
(etaf-view (column (text :if online "Online")
                   (text :else t "Offline")))
```

### 键控列表

#### Syntax: :for (:for (ITEM ITEMS) :key KEY)

为列表中每个元素渲染一行，并在更新之间按 KEY 保留行。

**参数。**

- 带 `:for` 的节点每个元素重复一次。`(ITEM ITEMS)` 把 ITEM（一个普通符号）绑定在该节点的属性和子节点里。
- ITEMS 是普通 Elisp 表达式，其值必须是真列表。
- 同一个节点上必须给出 `:key`。它是普通 Elisp 表达式，求值时绑定 ITEM；其值标识该行，必须是非 nil 的符号、整数或字符串。

**语义。**

- 列表区域在渲染期求值 ITEMS，并按带 `:for` 的节点为每个元素建立一行。区域和行遵循普通和解：key 与保留行相同的行被复用，新 key 建立新行，消失的 key 释放其行。
- 保留 key 下的新元素若是另一个对象，会通过该行的元素绑定交给它，于是行的属性、`expr` 形式和组件状态就地更新到新元素，而不是重建。key 相等即可，元素不必是同一个对象。
- key 在列表内必须唯一。重复 key 抛出 `etaf-runtime-error`，消息为 `"Keyed Range keys must be unique"`，并保持此前已提交的行不变。
- 只在任一端追加或删除元素的改动，代价是那一端每个未变行一次比较，加上建立或释放的行，而不是遍历整张列表。

**错误。** 缺 `:key`、绑定不是 `(ITEM ITEMS)` 及普通符号、ITEM 与组件 prop 冲突，或分支与 `:for` 共用节点时 `error→ etaf-view-syntax-error`。ITEMS 求值结果不是真列表时 `error→ etaf-component-call-error`。key 重复时 `error→ etaf-runtime-error`。

**示例。**

```elisp
(etaf-view (column (text :for (name names) :key name
                         (expr (symbol-name name)))))
```

### fragment

#### Syntax: fragment (fragment CHILD ...)

把若干子节点归为一组，但不向布局添加节点。

**参数。** CHILD 形式遵循普通子节点规则。fragment 接受 `:key` 和编译器指令 `:if`、`:else-if`、`:else`、`:for`；它没有 Ebox 节点，所以其他 Host 属性没有落点。

**语义。** 渲染器按顺序把 fragment 的子节点插入外层布局，因此 fragment 不会在父子之间加入任何东西，也不需要样式。组件的渲染结果是 fragment 时，其内容就留在父布局中——组件返回多个根节点正是靠这一点。

fragment 的身份由 `:key` 决定；没有 `:key` 时由编译它的调用点决定。写在两个调用点上的两个 fragment，即使形式相同也彼此不同；同一个调用点重复求值则保持身份。

**错误。** 没有 fragment 特有的错误。它的子节点和指令按普通节点检查。

**示例。**

```elisp
(etaf-view (column (fragment (text "a") (text "b")) (text "c")))
```

## 用 Lisp 构造 View

#### Function: etaf-node (tag props children &optional named-slots)

用已经求值好的普通 Elisp 值构造一个有类型的 View 节点。

**参数。**

- TAG 是精确的 Host 或组件符号。不做别名或回退解析。
- PROPS 是关键字 plist，长度必须为偶数，键不得重复。编译器指令 `:if`、`:else-if`、`:else`、`:for` 属于结构语言，会被拒绝。
- CHILDREN 是由有类型子节点组成的真列表：nil、字符串、早先构造好的 View 值、表达式区域和 slot 请求。
- NAMED-SLOTS 仅组件可用，是把稳定的非关键字符号映射到子节点列表的 alist。Host 会拒绝它。

**语义。** `etaf-node` 是结构形式在代码模式下的对应物：它对已经求值好的值施加同一套校验，这正是渲染函数或程序化构造器需要的。`:key` 属性也在这里校验。对组件来说，CHILDREN 成为其默认 slot，NAMED-SLOTS 成为具名 slot；调用方属性被划分成组件声明的 props 和它的 Host 属性。

**返回。** 一个有类型的 View 值，可直接交给 `etaf-mount`，也可作为另一个 View 的子节点。

**错误。** 出现以下情况时 `error→ etaf-component-call-error`：TAG 不是符号；属性列表不合法或键重复；出现指令属性；子节点不合法；key 不合法；给 Host 传具名 slot；或 TAG 未知。

**示例。**

```elisp
(etaf-node 'row nil (list (etaf-node 'text nil (list "left"))
                          "right"))
```

**参见。** `etaf-view`，它从结构形式构造同样的值。

#### Function: etaf-render (view)

把一个规范化 VIEW 降到一份规范、独立的 Ebox 根节点，不需要 Runtime。

**参数。** VIEW 是规范化 View 值，由 `etaf-view` 或 `etaf-node` 返回。

**语义。**

- 整个 View 只求值一次，处于渲染阶段：渲染期写响应式源会抛出 `etaf-render-side-effect-error`。
- Host 的 class 和 id、非 nil 的 `:role`，以及显式给出的 `:aria-*` 属性，都会到达 Ebox 的选择器主体。`:selector-attributes` 和 `:selector-state` 属于适配器事实，不能作为 View 属性给出。
- 不带 `:setup` 的组件可用。带 `:setup` 的组件需要已挂载的 Runtime，因为它的 Scope 必须有生命周期所有者；`etaf-render` 遇到它会抛出 `etaf-renderer-error`。

**返回。** 一个独立的 Ebox 根节点。View 产出多个节点时，它们被包进一个 column 根节点。

**错误。** View 无法显示时 `error→ etaf-renderer-error`：未解析的子节点值、不是文本的 text 载荷、`image` Host 带子节点、兄弟 key 重复，或有状态组件。渲染期写响应式源时 `error→ etaf-render-side-effect-error`。

**示例。**

```elisp
(etaf-render (etaf-view (text "Hi")))
;; ⇒ 一个 Ebox text 节点 ; display
```

**参见。** `etaf-mount` 以及 [Runtime](runtime.md)，其中讲挂载和生命周期。

## 语义细节

### 编译与复用

一个结构形式按调用点编译一次，成为*蓝图*：一棵由字面量节点和属性值构成的树，外加一张延迟程序表，装着必须在渲染期运行的一切——属性 thunk、`expr` 求值体、分支条件、列表来源与 key 表达式，以及 slot 请求。求值调用点就是把蓝图实例化。

- 某个子树的所有属性和子节点都是字面量时，它是静态的。静态子树只物化一次，并在进程内缓存，缓存键是编译后的形式、它在形式中的位置，以及组件注册表代数。重复求值同一个调用点，或求值另一个形式相等的调用点，会复用这些值而不是重建。
- 定义或重定义组件会开启新的注册表代数并丢弃静态缓存，因此被重定义的组件不会由过期蓝图提供。重新加载组件的创作工具应先销毁其 Runtime，[组件章](components.md)有说明。
- 只要有一个非字面量值，其所在子树就是动态的：每次求值都重新构造，而带延迟属性的 Host 会得到一个被保留的绑定，在该绑定读过的源变化时重跑。
- 未加载编译器时，`etaf-view` 退化为等价的直接展开。两条路径接受相同的形式、产出相同的 View 值；回退路径是为单独加载 `etaf-view` 的情况存在的。

### 身份

父子节点在两次渲染之间靠身份键匹配。

| 子节点 | 身份 |
| --- | --- |
| Host 节点 | 其标签与 `:key` |
| 组件调用 | 其组件与 `:key` |
| fragment | 其 `:key`，或它的调用点 |
| `expr`、分支、键控列表 | 其调用点 |

显式 `:key` 必须是非 nil 的符号、整数或字符串；字符串 key 在构造 View 时被复制。同一个父节点下，显式 key 必须唯一；重复会抛出 `etaf-renderer-error`。`:for` 列表的各行按 [键控列表](#键控列表)所述的 key 值匹配。

key 保留的是实例而不是输入，所以 View 要显示的响应式值应当放在显示它的属性或 `expr` 里读取。把值嵌进结构的 View 每次变化都会产出新结构，这虽然正确，却会重建本可由键控读取就地更新的部分。

### 代价

- 全静态子树每次求值只花一次缓存查找；其节点和值被共享。
- 动态 Host 的代价是求值自己的属性 thunk，并修补自己的节点和绑定，与其他部分无关。
- 分支按顺序求值条件直到首个命中，只物化一个臂。
- 键控列表只和解发生变化的中段：两端未变的行各比较一次即可跳过，保留的 key 通过元素绑定更新自己的行。

## 错误与恢复

View 语言抛出三个条件，构成一个层级：`etaf-view-syntax-error` 和 `etaf-component-call-error` 都是 `etaf-view-error` 的子条件。

#### Error: etaf-view-error

View 不合法时的基础条件，消息为 "Invalid ETAF View"。它没有自己的抛出点：结构问题抛 `etaf-view-syntax-error`，值问题抛 `etaf-component-call-error`，所以为 `etaf-view-error` 写一个处理器就能捕获两者。其数据是抛出时传给 signal 的参数列表，通常是一个格式化后的消息字符串。

#### Error: etaf-view-syntax-error

结构形式不合法。条件在 `etaf-view` 展开期间抛出，因此出错的调用点不会被求值，也不会构造出 View 值。数据是只含一个消息字符串的列表。

| 消息 | 触发原因 |
| --- | --- |
| `"Attributes must precede children; found %S after a child"` | 属性出现在第一个子节点之后 |
| `"Missing value for View property %S"` | 属性没有值 |
| `"Duplicate View property %S"` | 同一个属性出现两次 |
| `"Expr accepts exactly one form: (expr FORM)"` | `expr` 含零个或多个形式 |
| `"Text requires exactly one string or expr payload"` | `text` Host 的载荷不是恰好一个 |
| `":for requires an explicit :key"` | 键控列表缺 `:key` |
| `":for must be (ITEM ITEMS): %S"` | 列表绑定形式不合法 |
| `":else requires literal t"` | `:else` 的值不是字面量 t |
| `"A View node accepts one branch directive"` | 一个节点上出现多个 `:if`、`:else-if`、`:else` |
| `"Branch directives cannot share a node with :for"` | 同一节点既有分支又有 `:for` |
| `"Orphan branch arm: %S"` | `:else-if` 或 `:else` 前面没有 `:if` |
| `"Elisp expression %S must be inside (expr FORM)"` | 子节点位置出现未包装的函数调用或特殊形式 |
| `"View children must be strings, nil, View forms, or expr results: %S"` | 子节点不是合法的子节点形式 |

#### Error: etaf-renderer-error

规范化 View 无法显示，或需要已挂载的 Runtime 而不可得。数据是只含一个消息字符串的列表。

| 消息 | 触发原因 |
| --- | --- |
| `"Unresolved View item: %S"` | `expr` 产出的值不是 View，例如数字 |
| `"Text payload must resolve to one string"` | text 载荷不是字符串、nil 或字符串列表 |
| `"Image Host takes no children"` | 给 `image` Host 传了子节点 |
| `"View has duplicate sibling key: %S"` | 两个兄弟节点带相同的 `:key` |
| ``"Stateful Component requires `etaf-mount'"`` | `etaf-render` 遇到带 `:setup` 的组件 |
| `"Expected text, image, box, row, column, flex, or grid Host; received %S"` | 节点以渲染器无法建立的名字到达渲染器 |

### 恢复

| 失败 | 保留了什么 |
| --- | --- |
| `etaf-view` 在展开期拒绝一个形式 | 什么都没构造；该调用点不求值 |
| 无法由已求值的值构造 View | 不返回 View 值；已发布的 Runtime 不受影响 |
| `etaf-render` 失败 | 不返回节点，也不触碰任何缓冲区 |
| 已挂载 Runtime 的某次更新失败 | 已提交的缓冲区保持不变；失败的工作在下次排空或 `etaf-runtime-flush` 时重试，见[响应式系统](reactivity.md#恢复) |

形式不合法是编程错误，不是输入错误：应用无法在出错处恢复，应在源码里修正。来自数据的渲染期错误才是应用可以处理的一类，它们保留上一次已提交的输出。
