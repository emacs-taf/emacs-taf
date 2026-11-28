# Context

*Context* 是 ETAF 唯一一种有意做成「可继承」的依赖环境。它依附于组件实例，不依附 View 节点，也不是全局变量：一个组件提供值，它下面的组件直接读取，不必让每个组件用 prop 层层传递。本章定义两个函数、决定「组件能看到什么」的祖先规则、响应式的上下文值，以及错误条件。

Context 是「整棵子树共享配置」的机制：面板给它的后代提供 locale、tone、controller 或数据源；[组件](components.md)读的 Theme 默认值就是以 `theme` 为键的 Context 值，[组件样式与主题](component-styles-and-themes.md)会讲到。与 prop 不同，Context 值不是组件调用的一部分；与全局变量不同，它的作用范围就是提供它的那棵子树。

<!-- index: Context; 提供; 读取; 继承的依赖; 祖先作用域 -->

## 模型

### 祖先链

每个带 `:setup` 的组件拥有一个*上下文帧*：一张键到值的小表，其父帧是渲染它的那个组件的帧。没有 `:setup` 的组件没有自己的帧，在渲染它的组件的帧里求值。于是已挂载 View 从树根到正在求值的组件形成一条帧链；`etaf-render` 有同样的根。

`etaf-provide` 写入正在求值的组件的帧。`etaf-inject` 从该帧开始沿链上溯，直到找到该键，所以最近的提供者胜出。值的提供与读取都不复制：帧里放的就是提供者给出的那个对象。

### 提供者用来做什么

提供者适合「整棵子树共享、又不该由某次组件调用作为 prop 携带」的值：

- 某块内嵌区域的配置，例如面板的 tone 或 locale；
- 多个后代都读的 controller 或数据源；
- 后代要订阅的真相来源，以响应式值的形式提供。

可见范围按组件祖先关系算，不按节点出现在屏幕上的位置算。这个区别对 slot 尤其重要：调用方传进组件的内容用调用方的 Context 渲染，组件自己的 `View` 用组件的 Context 渲染，[可见范围](#可见范围)一节说明。

## 提供与读取

#### Function: etaf-provide (key value)

在当前子树下用稳定的 Context KEY 提供 VALUE。

**参数。** KEY 是稳定符号：普通、非 nil、非 `t`、非 keyword 的符号；keyword、nil、t、字符串或其它对象都会 `etaf-context-error`。VALUE 是任意对象，原样保存，包括 nil。

**语义。** 调用把 VALUE 写进正在求值的组件的上下文帧。该值对它自己的求值以及渲染在它下面的每个后代组件可见；子树之外的组件——包括兄弟组件和调用方提供的 slot 内容——不受影响。在同一帧里再次提供同一 KEY 会替换该值。调用不通知任何读取者：它改变的是之后 `etaf-inject` 能找到什么，而不是已经渲染出的东西；要跟随应用状态的值应以响应式源的形式提供，见[响应式的上下文值](#响应式的上下文值)。提供的 nil 和别的值一样，会阻止查找继续上溯到外层提供者。

**返回。** VALUE。

**错误。** KEY 不是稳定符号时 `error→ etaf-context-error`，消息为 `"Context keys must be stable symbols: %S"`。在组件求值之外——顶层、生命周期钩子或事件回调里——调用抛出普通 `error`，消息为 `"ETAF provide requires Component setup or render context"`。纯渲染期调用会 `error→ etaf-render-side-effect-error`，数据为 `(provide-context)`，与[响应式系统](reactivity.md#渲染不产生副作用)对渲染期副作用的规定一致。

**示例。** 面板提供它各 badge 读取的 tone。

```elisp
(etaf-provide 'tone "danger")
```

**参见。** `etaf-inject`、[可见范围](#可见范围)，以及[组件样式与主题](component-styles-and-themes.md)关于 `theme` 键的说明。

#### Function: etaf-inject (key &optional default (required-p nil required-p-supplied-p))

返回 KEY 最近的已提供值。

**参数。** KEY 是稳定符号，校验同 `etaf-provide`。链上都没有该 KEY 时返回 DEFAULT。REQUIRED-P 是显式的：非 nil 且确实传入时，缺失改为报错。第三个参数显式存在，是为了把「已提供的 nil」与「缺失」区分开：已提供的 nil 会被找到并返回，缺失的键在 REQUIRED-P 下才报错。

**语义。** 查找从当前帧开始沿组件祖先链上溯，最近的提供者胜出。找到的 nil 作为 nil 返回，不会被 DEFAULT 取代。只要组件正在求值，读取就可用——setup、`:bindings`、两个渲染前端，以及 setup 期间创建的副作用或侦听器（它们后续运行时保留自己的求值环境）。生命周期钩子和事件回调在该求值之外运行，那里的查找走不到任何帧、返回 DEFAULT；需要的东西应在 setup 期间先取好（值或源）。

**返回。** 最近提供的值；键缺失时返回 DEFAULT。

**错误。** KEY 不是稳定符号时 `error→ etaf-context-error`，消息为 `"Context keys must be stable symbols: %S"`；REQUIRED-P 非 nil 且整条链都没有该键时，消息为 `"Missing ETAF Context dependency: %S"`。查找失败不改变任何东西。

**示例。** 字段标签回退到默认货币。

```elisp
(etaf-inject 'currency "USD")
```

**参见。** `etaf-provide` 与[可见范围](#可见范围)。

## 可见范围

<!-- index: 最近的提供者; slot 上下文; 子树作用域 -->

Context 跟着组件树走。三条规则覆盖所有情况：

- 后代组件看得到该值；提供者的兄弟或子树之外的组件看不到。
- 同一键最近的提供者胜出；内层提供者遮蔽它下方的外层值。
- 调用方提供的 slot 内容保留调用方的 Context；`slot` 的 fallback 在组件自己的 Context 里渲染。

面板给自己那组 badge 设置 tone，用到前两条规则。

```elisp :run
(etaf-define-component demo-tone-badge (&key label)
  :bindings ((tone (etaf-inject 'tone "neutral")))
  :view (box :role "status"
             (expr (format "%s — %s" label tone))))

(etaf-define-component demo-tone-panel ()
  :setup (etaf-provide 'tone "danger")
  :view (column (demo-tone-badge :label "Disk almost full")
                (demo-tone-badge :label "Backup stale")))

(etaf-view (demo-tone-panel))
```

badge 从祖先链读到 tone；放在面板旁边、或作为 slot 内容传进面板的 badge 读到的是默认值。这正是 slot 规则的意义：调用方传进来的内容始终处在调用方的配置之下，无论组件把它放在哪里。想让自己提供的值覆盖调用方内容，组件无法两全；要么自己渲染那份内容，要么让调用方去提供该值。

setup 期间创建的侦听器和副作用保留创建它们的帧，因此之后的响应式运行仍能继续读取。生命周期钩子和事件回调不同：它们在 setup 期间注册，却在组件求值之外运行，应在 setup 运行时就把需要的值或源取好。

## 响应式的上下文值

<!-- index: 响应式上下文值; 提供的源 -->

Context 本身不是响应式源。`etaf-provide` 与 `etaf-inject` 都不记录依赖，重新提供一个普通值也不会让读取者重新渲染。要让子树跟随应用状态，就提供*源*——ref 或计算值——并在使用处用 `etaf-value` 读取：

```elisp
(etaf-define-component demo-locale (&key locale)
  :setup (etaf-provide 'locale locale)
  :view (column (slot)))

(etaf-define-component demo-label (&key text)
  :bindings ((locale (etaf-inject 'locale (etaf-ref "en"))))
  :view (text (expr (format "%s (%s)" text (etaf-value locale)))))
```

改变被提供的 ref 会让每个读过它的读取者重新渲染，与任何其它源一样。反过来——在侦听器或副作用里重新提供一个新普通值——之后的查找能看到，但不会通知任何人，所以无法更新已经渲染出的内容。

## 语义细节

### 帧与生命周期

一个帧属于一个组件实例，和它同寿：setup 期间提供的值经历子树的每次更新仍然有效，之后创建的组件也看得到。提供它的实例被释放时帧随之消失，此后创建的后代不再找到该值。值按引用保存；Context 既不复制也不冻结它们。

### 代价

一次读取是对访问到的每个帧做一次哈希表查找，代价与组件链深度成比例，与已提供值的数量无关。一次提供是一次哈希表写入。帧是普通对象，随实例一起释放；没有会增长的全局注册表。

## 错误与恢复

#### Error: etaf-context-error

消息为 "Invalid ETAF Context operation"。Context 操作格式错误，或必需依赖缺失时抛出。用 `condition-case` 捕获；失败的调用不返回值。父条件是 `error`，数据是含一个格式化消息字符串的列表。

| 消息 | 起因 |
| --- | --- |
| `"Context keys must be stable symbols: %S"` | `etaf-provide` 或 `etaf-inject` 的 KEY 是 keyword、nil、t、字符串或其它非符号对象 |
| `"Missing ETAF Context dependency: %S"` | `etaf-inject` 的 REQUIRED-P 非 nil，而该键整条链上都不存在 |

[组件样式与主题](component-styles-and-themes.md)里的 Theme 函数用同一个条件做输入校验；它们的消息由那一章列出。

**参见。** `etaf-render-side-effect-error` 见[响应式系统](reactivity.md#错误与恢复)；setup、bindings 与生命周期见[组件](components.md)。

### 恢复

| 失败 | 留下什么 |
| --- | --- |
| KEY 非法 | 没有提供或查找任何东西；已有 Context 不变 |
| REQUIRED-P 下键缺失 | 调用报错、不返回值；已有 Context 不变 |
| 在组件求值之外读取 | 返回 DEFAULT，REQUIRED-P 设置时则报错；什么也不变 |
| 纯渲染期提供 | Runtime 像处理任何渲染期失败一样丢弃这份工作，见[响应式系统](reactivity.md#恢复) |
| 普通值已与应用状态不一致 | 读取者保留已渲染输出，直到 View 再次渲染；要跟随状态请提供源而不是普通值 |

Context 失败是提供方或读取方组件的编程错误；它不会破坏别的子树，因为一个帧只装自己的条目。

**参见。** `etaf-provide`、`etaf-inject` 与[响应式系统](reactivity.md#已挂载的-runtime)。
