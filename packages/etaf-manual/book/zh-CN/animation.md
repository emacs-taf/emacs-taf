# 动画

动画就是一个随时间移动的普通响应式 ref。应用照常写它的目标，就像写任何别的 ref；框架在一条共享时钟上采样显示值，并把每个样本经普通 ref 路径发布，所以绑定、损伤与缓冲区更新和应用自己写入时完全一样。`etaf-transition` 把目标变成一个目标变化时永不跳变的显示 ref，`etaf-animation-frames` 轮播固定序列，用于加载指示器、跑马灯和打字机效果。两者都归属于创建它们的 Scope，与所有其他运行中的动画共用一条时钟，并在没有任何动画运行时一起停止。本章定义这两种值源、完成回调、插值与缓动、时钟及其设置、停止与立即完成，以及一次运行被打断时会发生什么。[响应式系统](reactivity.md)定义底层的 ref、侦听器与 Scope；[Runtime](runtime.md) 定义发布样本的已挂载 Runtime。

## 随时间驱动的值

<!-- index: 动画; 共享时钟; transition; 帧序列 -->

动画持有一个值朝目标移动的 ref。时钟决定什么时候该采样；每个样本计算当前时刻的值，并经普通 ref 路径写出，所以已挂载的 Runtime 看到的是一次普通更新。每个 Emacs 进程只有一条时钟，并且只在至少有一个动画订阅时存在：第一次激活会启动一个一次性定时器，停止最后一个动画会取消它。一次采样在一个批处理里推进所有运行中的动画，顺序与它们加入时钟的顺序一致。

插值与计时是两件事：一次采样需要的是上一个值与目标之间的值。内建转换覆盖数字、颜色串和等长的列表或向量；下面的扩展变量覆盖其他形状。

transition 跟随一个响应式源；帧序列轮播固定列表。值有明确目标、应当平滑到达时用 transition——位置、尺寸、颜色、填充量；值选自固定集合时用帧序列——加载指示器、跑马灯、闪烁的灯、打字机逐字显现。

### transition 与帧序列

<!-- index: etaf-transition; etaf-animation-frames; duration; easing; interval; loop; 完成 -->

#### Function: etaf-transition (source &key (duration 0.2) (easing 'ease-out) name on-complete)

返回一个在 DURATION 秒内跟随响应式 SOURCE 的 ref。

**参数。** SOURCE 是 ref、计算值或零参函数，和 `etaf-watch` 完全一样。DURATION 是行进秒数，默认 0.2，可以为 0。EASING 是 `etaf-animation-easings` 里的名字或一个缓动函数。NAME 是返回 ref 在诊断中的标签。ON-COMPLETE 是每次运行到达 SOURCE 后要跑的零参函数。

**语义。** 返回的 ref 以 SOURCE 的当前值为初值，且一开始不运行。此后每次 SOURCE 变化都从当前显示的值开始一次运行，所以打断运行永不跳变。在需要跟随显示值的地方用 `etaf-value` 读它。动画归属于创建时活动的 Scope，例如 Component 的 `:bindings` 或 setup；没有这样的 Scope 时，用 `etaf-animation-stop` 停止它。把目标写成与显示值相等的值会停止运行，而不是开始一次。

**返回。** 显示值 ref。

**错误。** DURATION 不是非负数时 `error→ etaf-animation-error`，数据 `("Invalid duration" VALUE)`；EASING 既不是函数也不是 `etaf-animation-easings` 中的名字时 `error→ etaf-animation-error`，数据 `("Unknown easing" VALUE)`；ON-COMPLETE 既不是 nil 也不是函数时 `error→ wrong-type-argument`，数据 `(functionp VALUE)`。非法 SOURCE 报 `etaf-watch` 会报的错误。

**示例。** 一个可由控件写入的目标。

```elisp
(let* ((level (etaf-ref 0))
       (shown (etaf-transition level :duration 0.3 :easing 'linear)))
  (etaf-value shown))
;; ⇒ 0
```

**参见。** `etaf-animation-frames`、`etaf-animation-interpolate`、`etaf-animation-stop`。

#### Function: etaf-animation-frames (frames &key (interval 0.1) (loop t) name on-complete)

返回一个每 INTERVAL 秒循环经过 FRAMES 的 ref。

**参数。** FRAMES 是非空列表或向量，元素按顺序显示。INTERVAL 是每帧停留的秒数，默认 0.1。LOOP 为 nil 时停在最后一帧而不是从头再来，默认为 t。NAME 是返回 ref 在诊断中的标签。ON-COMPLETE 是 LOOP 为 nil 且到达最后一帧时要跑的零参函数。

**语义。** ref 从第一帧开始。某次采样显示哪一帧由序列启动以来的时间决定，所以迟到的采样会跳过若干帧，而不是逐帧重放。序列创建即运行；返回的 ref 和任何别的 ref 一样读取。Scope 归属与校验规则与 `etaf-transition` 相同。

**返回。** 显示值 ref。

**错误。** FRAMES 为 nil、空、字符串或其他非“非空列表或向量”的值时 `error→ etaf-animation-error`，数据 `("FRAMES must be a nonempty sequence" VALUE)`；INTERVAL 不是正数时 `error→ etaf-animation-error`，数据 `("Invalid frame interval" VALUE)`；ON-COMPLETE 既不是 nil 也不是函数时 `error→ wrong-type-argument`，数据 `(functionp VALUE)`。

**示例。**

```elisp
(etaf-value (etaf-animation-frames '("|" "/" "-" "\\") :interval 0.12))
;; ⇒ "|"
```

**参见。** `etaf-transition`、`etaf-animation-stop`、`etaf-animation-easings`。

#### Property: :on-complete

`etaf-transition` 与 `etaf-animation-frames` 的完成回调关键字。

**参数。** 一个零参函数；可选。

**语义。** transition 在一次运行到达目标后运行它；帧序列在 LOOP 为 nil 且到达最后一帧时运行它。回调排在让这次运行完成的那次样本发布之后，等待决的响应式工作都发布完再运行（[响应式系统](reactivity.md#批处理与-tick)）。每次完成的运行只运行一次，所以在回调里重定向自己的源——构造循环的惯用方式——会等上一次运行落地后再开始下一次。运行在完成前被停止时不运行；transition 因 DURATION 为 0 或 `etaf-animation-enabled` 为 nil 而直接落值时不运行；帧序列被停止或立即完成时也不运行。

**错误。** 构造时值既不是 nil 也不是函数时 `error→ wrong-type-argument`，数据 `(functionp VALUE)`。

**参见。** `etaf-transition`、`etaf-animation-frames`、`etaf-animation-finish`。

下面的示例挂载一个由一次 transition 随时间填满的量表。

```elisp :run
(etaf-define-component demo-animation-gauge ()
  "Fill a gauge that follows its target over time."
  :bindings ((level (etaf-ref 0))
             (shown (etaf-transition level :duration 0.5
                                     :easing 'ease-out :name 'gauge)))
  :setup (setf (etaf-value level) 1.0)
  :view
  (text (expr (format "level %.2f" (etaf-value shown)))))

(etaf-view (demo-animation-gauge))
```

### 插值与缓动

<!-- index: etaf-animation-interpolate; 插值; 缓动; 颜色插值 -->

#### Function: etaf-animation-interpolate (from to progress)

返回 FROM 与 TO 之间、PROGRESS 处的值。

**参数。** FROM 与 TO 是同类值。PROGRESS 是数字；0 返回 FROM，1 返回 TO。

**语义。** PROGRESS 大于等于 1 时原样返回 TO；负 PROGRESS 会向 FROM 之外外推。数字按算术转换，颜色串按 RGB 分量混合。等长的列表与向量逐元素、递归地转换，所以 `(lh 2)` 这样的长度值在数字内部移动；相等的非数字原地不动，而类型、符号或长度不匹配的一对返回 FROM。PROGRESS 小于 1 时先查 `etaf-animation-interpolators` 中匹配的一对。

**返回。** 转换后的值。

**错误。** PROGRESS 不是数字时 `error→ wrong-type-argument`，数据 `(number-or-marker-p VALUE)`。

**示例。**

```elisp
(etaf-animation-interpolate '(lh 1) '(lh 4) 0.5)
;; ⇒ (lh 2.5)
```

**参见。** `etaf-animation-easings`、`etaf-animation-interpolators`、`etaf-transition`。

#### Variable: etaf-animation-easings

把进度映射到缓动后进度的 `(NAME . FUNCTION)` alist。

**语义。** 默认名字是 `linear`、`ease`、`ease-in`、`ease-out` 与 `ease-in-out`，都满足 0 映射到 0、1 映射到 1。缓动把时长比例映射为距离比例，所以 `ease-out` 的一次运行早期走完大部分距离，接近目标时减速。`etaf-transition` 接受这个 alist 里的名字，或直接接受一个单参函数，所以应用可以不改 alist 就加入自己的曲线。

**参见。** `etaf-transition`、`etaf-animation-interpolate`。

#### Variable: etaf-animation-interpolators

优于内建插值、按顺序查询的 `((PREDICATE . FUNCTION) ...)` 转换表。

**语义。** 每个 PREDICATE 收 FROM 与 TO，决定自己这一对是否适用；第一对匹配者胜。FUNCTION 收 FROM、TO 与 PROGRESS，返回该进度处的值。变量在每次采样时读取，所以在创建动画前登记的项对它生效。这个钩子用于内建转换覆盖不了的形状，例如不应逐元素转换的应用记录或带单位的复合值。

**参见。** `etaf-animation-interpolate`。

### 共享时钟

<!-- index: etaf-animation-frame-rate; etaf-animation-speed; etaf-animation-paused; 采样; 帧率 -->

#### Variable: etaf-animation-frame-rate

运行中动画的显示时钟频率，单位是每秒帧数。

**语义。** 值是一个正数，默认 30。它是上限而非承诺：每次发布之后再过一整个周期才安排下一次采样，繁忙的 Emacs 会送出更少的样本。一条时钟服务所有运行中的动画，改动对正在跑的时钟生效。键盘输入不压制采样；流逝的时间照常推进，不补帧。Lisp 与重绘共用 Emacs 主线程，所以开销大的场景必须调低这个频率并限制每次采样做的工作。

**错误。** 值为非正数或非数字时，在需要安排下一次采样时 `error→ etaf-animation-error`，数据 `("etaf-animation-frame-rate must be a positive number" VALUE)`。值非法时创建动画会立刻把错误报给调用者；时钟运行时值变非法，会在报出一次定时器错误后停掉所有运行中的动画并丢弃时钟。

**参见。** `etaf-animation-speed`、`etaf-animation-paused`、`etaf-transition`。

#### Variable: etaf-animation-speed

动画速度倍数，正数；1.0 是正常速度。

**语义。** 共享时钟的时间按两次采样之间的挂钟时间乘以这个倍数前进，所以 2 让每个 transition 与帧序列快一倍，0.5 慢一半。改动从下一次采样生效，不移动运行的进度：跑到一半的运行动完后按新速率推进。

**错误。** 值为非正数或非数字时，在时钟读取它的地方 `error→ etaf-animation-error`，数据 `("etaf-animation-speed must be a positive number" VALUE)`；运行中改动会让所有运行中的动画停止、丢弃时钟，只报出一次定时器错误。

**参见。** `etaf-animation-frame-rate`、`etaf-animation-paused`。

#### Variable: etaf-animation-paused

非 nil 时共享时钟停止前进。

**语义。** 运行中的动画保持显示值与进度，并且保持订阅。清回 nil 会让它们从停住的地方精确恢复；暂停期间创建的运行会在时钟再次前进后从它自己的第一帧开始。暂停不是停止：它不结算运行、不运行完成回调，`etaf-animation-active-p` 也保持真。

**参见。** `etaf-animation-enabled`、`etaf-animation-speed`、`etaf-animation-active-p`。

### 停止、完成与开关

<!-- index: etaf-animation-stop; etaf-animation-finish; etaf-animation-active-p; etaf-animation-enabled -->

#### Function: etaf-animation-stop (source)

停止动画 SOURCE，并把值留在原地。

**参数。** SOURCE 是 `etaf-transition` 或 `etaf-animation-frames` 返回的 ref。

**语义。** 动画离开时钟并保留显示值；此后写入 transition 的目标不再让它动。停止一个已经停止的动画无害。动画仍然被记录，所以 `etaf-animation-finish` 和再次 `etaf-animation-stop` 仍然可用。

**返回。** 已停止的 SOURCE ref。

**错误。** SOURCE 不是 `etaf-transition` 或 `etaf-animation-frames` 创建的值时 `error→ etaf-animation-error`，数据 `("Not an animated source" VALUE)`。

**参见。** `etaf-animation-finish`、`etaf-animation-active-p`、`etaf-transition`。

#### Function: etaf-animation-finish (source)

立即应用最终值，停止动画 SOURCE。

**参数。** SOURCE 是 `etaf-transition` 或 `etaf-animation-frames` 返回的 ref。

**语义。** 运行中的 transition 写入当前目标并运行完成回调，与自然到达完全一样；不在运行的 transition 只是停止。帧序列保留当前显示的那一帧。无论哪种，动画随后离开时钟，之后再写目标也不影响它。

**返回。** 已完成的 SOURCE ref。

**错误。** SOURCE 不是 `etaf-transition` 或 `etaf-animation-frames` 创建的值时 `error→ etaf-animation-error`，数据 `("Not an animated source" VALUE)`。

**参见。** `etaf-animation-stop`、`etaf-animation-active-p`、`:on-complete`。

#### Function: etaf-animation-active-p (source)

SOURCE 的动画订阅着共享时钟时返回非 nil。

**参数。** SOURCE 可以是任何值。

**语义。** 两次运行之间的 transition 和已经落地的 transition 都不活动；帧序列在循环期间活动；时钟暂停时它的动画仍算活动。不是动画 ref 的值返回 nil 而不报错，因此这个判定对任意源都是安全的。

**返回。** 动画订阅着时钟时非 nil。

**参见。** `etaf-animation-stop`、`etaf-animation-finish`、`etaf-animation-paused`。

#### Variable: etaf-animation-enabled

动画是否随时间插值；默认为 t。

**语义。** 值为 nil 时，新建 transition 在下一次写入时直接应用目标而不开始运行，新建帧序列根本不启动。运行中的 transition 在下一次采样贴到目标并运行完成回调；运行中的帧序列保持当前帧。把变量设回 t 不会重启任何已停止的运行，所以它是时间驱动行为的全局开关，而不是第二种暂停。应用用它来响应「减少动态效果」偏好，同时保留所有动画的代码。

**参见。** `etaf-animation-paused`、`etaf-animation-stop`、`etaf-animation-active-p`。

## 归属与打断

<!-- index: Scope 归属; 打断; 卸载; 时钟寿命 -->

在 Component setup 或 `:bindings` 里创建动画时，它的停止操作登记到该 Component 的 Scope 上；卸载 Runtime 会释放 Scope，动画随之停止、值冻结。因此 Scope 拥有的动画不需要额外记账：应用写目标，组件离开时框架停止采样。在 Scope 之外创建的动画由调用方负责；`etaf-animation-stop` 释放它的侦听器，并在没有别的动画时让时钟一起消失。

打断是常态，不是错误。transition 运行期间目标改变时，运行从显示值重新开始一段全新的时长，所以值保持连续，只是方向改变。把目标写成与显示值相等的值会停止运行。在一次运行完成后、从完成回调里重定向，就得到一个既不跳变也无需调度记账的循环：每次运行报一次到达，回调开始下一次。

完成回调在让这次运行完成的那次样本发布之后运行，走框架的下一拍队列（[响应式系统](reactivity.md#批处理与-tick)），而不是在采样内部。因此它可以写 ref、重定向动画或更新应用状态，就像事件回调一样。采样中报出的错误会让该动画失活，其他动画继续运行；第一个这样的错误在样本批次之后重新掷出，而完成回调里的错误遵循下一拍的规则。

时钟因为空闲而便宜：最后一次停止与下一次激活之间没有定时器，每次采样也只做运行中的动画规定的工作。一个每次采样改一个文本值的帧序列和一个改一个尺寸的 transition，各自只花一次响应式发布；重绘大场景的采样更贵，这正是 `etaf-animation-frame-rate` 限制的对象。

## 示例剧场

<!-- index: etaf-animation-example-open; 示例剧场 -->

#### Function: etaf-animation-example-open ()

挂载动画示例剧场并返回它的缓冲区。

**语义。** 剧场在缓冲区里放二十个面板，覆盖帧序列、带回环重定向的 transition、重绘密集的色场和文本更新，另有一条控制栏用于暂停时钟、改速度与帧率，以及一个在全部动画运行时仍可用的原生输入便签。窗口变窄时，面板从四列回流到一列。同一时刻只有一个剧场拥有全局时钟控制；卸载会恢复 `etaf-animation-paused`、`etaf-animation-speed` 与 `etaf-animation-frame-rate` 之前的值。交互调用会显示缓冲区。请使用至少 28 列 × 12 行。

**返回。** 装着已挂载剧场的缓冲区。

**参见。** `etaf-animation-stop`、`etaf-animation-paused`、`etaf-animation-frame-rate`。

## 错误与恢复

<!-- index: etaf-animation-error; 非法动画设置; 定时器错误 -->

#### Error: etaf-animation-error

非法的 ETAF 动画操作。

**语义。** 这个条件报告非法的构造参数，以及对不是动画的值执行的操作。它的数据是列表，首元素说明问题，例如 `("Invalid duration" -1)`、`("Unknown easing" bogus)`、`("FRAMES must be a nonempty sequence" nil)`、`("Invalid frame interval" 0)`、`("Not an animated source" REF)`、`("etaf-animation-frame-rate must be a positive number" 0)` 与 `("etaf-animation-speed must be a positive number" 0)`。时钟在安排下一次采样时校验自己的设置，所以从不碰时钟设置的应用只会在构造时遇到这个条件；正在跑的时钟会停掉动画并只报一次定时器错误，而不是反复报错。恢复方式是恢复合法设置并开始一个新的动画。

**参见。** `etaf-transition`、`etaf-animation-frames`、`etaf-animation-stop`。

| 失败 | 会发生什么 |
| --- | --- |
| 某个构造参数非法 | 在创建任何 ref 之前报 `etaf-animation-error` 或 `wrong-type-argument` |
| 多个动画运行时某次采样报错 | 该动画停止，其余继续；批次之后重新掷出第一个错误 |
| 运行中的帧率或速度变非法 | 所有运行中的动画停止，时钟被丢弃，只报一次定时器错误 |
| transition 的目标一直不变 | ref 停在其当前值，没有定时器在跑 |
| Scope 在动画运行中被释放 | 动画停止并保留其值；之后再写目标什么也不发生 |
| 完成一个不在运行的 transition | 它停止；完成回调不运行 |
