# 响应式系统

响应式系统保存应用状态，并让由状态派生的一切保持最新：计算值、侦听器、副作用，以及已挂载 Runtime 的输出。它属于 ETAF 层，随 `(require 'etaf)` 加载。核心本身不依赖 View 和 Runtime，因此应用代码、组件和每个已挂载的 Runtime 共用同一张图。

[组件](components.md)和 [Runtime](runtime.md) 两章都建立在本章定义的归属规则与时序规则之上，请先读本章。

<!-- index: 响应式图; 状态; 依赖追踪 -->

## 模型

### 源与观察者

*源*（source）保存一个值，分两种：

- *ref*：可写单元，由 `etaf-ref` 创建；
- *计算值*（computed）：由函数派生的只读值，由 `etaf-computed` 创建。

*观察者*（observer）依赖源。计算值既是源也是观察者。其余观察者都是*副作用*（effect）：它读过的源变化后，系统会再次运行它。`etaf-watch` 创建的侦听器、`etaf-watch-effect` 创建的副作用、每个 `etaf-selector` 内部的侦听器，以及已挂载 Runtime 的渲染绑定，都是副作用。

*Scope* 拥有计算值、副作用、子 Scope 和清理函数，并统一释放它们。ref 是普通值：没有 Scope 拥有它，不可达后由垃圾回收释放。

### 依赖追踪

<!-- index: 追踪; 依赖 -->

观察者运行期间，每次 `etaf-value` 调用都会记下一条边：从被读的源指向这个观察者。这些边就是观察者的*依赖*。

- 每次运行都会替换上一次的依赖集合。最近一次运行没读到的源不再是依赖，所以条件分支里的读取只订阅实际走到的分支。
- 一次运行里多次读同一个源，只记一条边。
- 运行中途报错时，观察者保留原有依赖，并加上报错前读过的源；之后这两部分里任何一个变化，都会让它再次运行。
- 不在观察者运行期间的读取不追踪。侦听器回调、清理函数，以及 `etaf-update-value` 读取旧值的那一步，即使发生在观察者内部也不追踪。

### 推送与拉取

<!-- index: 推拉模型; dirty 状态; check 状态 -->

每个观察者处于三种状态之一：

| 状态 | 含义 |
| --- | --- |
| clean | 与全部依赖一致。 |
| check | 它直接或间接依赖的某个计算值可能已变。 |
| dirty | 已知某个依赖变了。 |

写入时*推送*：ref 的直接观察者变为 dirty，只经由计算值间接依赖它的观察者变为 check。离开 clean 状态的副作用进入所属阶段的队列。推送期间不做任何求值。

排队的副作用在运行前*拉取*。处于 check 的副作用先按依赖顺序把每个计算值依赖刷新到最新；如果没有一个真正改变了值，它直接回到 clean，不运行。处于 dirty 的副作用照常运行。

计算值是惰性的：只有被读取时才求值。没人读的计算值一直保持 dirty，输入变化多少次都没有开销。

由此得到两条保证。其一，计算值的新结果与旧结果相等时，传播就此停止，它的观察者不会运行。其二，副作用永远看不到更新到一半的图：一次排空之前的所有写入都已生效，副作用读取计算值之前，计算值已经刷新。

### 阶段

<!-- index: 阶段; pre 阶段; render 阶段; post 阶段 -->

排队的副作用分三个阶段运行：

| 阶段 | 副作用 | 与缓冲区输出的关系 |
| --- | --- | --- |
| pre | 以 `:flush 'pre`（默认）创建的侦听器和副作用 | 在已挂载 Runtime 写缓冲区之前 |
| render | Runtime 的渲染绑定：动态 View 属性、`expr` 子节点、带 key 的列表、组件输入 | 产生下一版输出 |
| post | 以 `:flush 'post` 创建的侦听器和副作用 | 在已挂载 Runtime 写完缓冲区之后 |

同一阶段内，副作用按创建顺序运行。

### 排空

<!-- index: 排空; 投递 -->

*排空*（drain）指运行排队的副作用，直到图稳定下来。批处理之外的写入，在写入函数返回之前就会排空。批处理之内，副作用要等最外层批处理结束。事件回调和 Action 处理函数本身就运行在批处理里，所以它们里面的多次写入，会在回调返回时一起投递。

一次排空反复执行下面几步，直到每一步都没有活可干：

1. 运行 pre 队列。
2. 运行 render 队列。
3. 提交：输出有变化的每个已挂载 Runtime 各写一次缓冲区。
4. 运行 post 队列。

每做完一步都从第 1 步重新开始，所以 post 侦听器写了 ref，会引出新一轮 pre、render 和提交。图稳定后，运行 `etaf-next-tick` 排队的函数。

```elisp :figure ref 喂给 computed，再喂给 effect
(etaf-view
 (row :item-gap '(ch 2)
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "ref"))
   (text :color (etaf-theme-token :ui-muted-fg "#526174") "→")
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
        (text :color (etaf-theme-token :ui-accent "#0969da") "computed"))
   (text :color (etaf-theme-token :ui-muted-fg "#526174") "→")
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa") (text "effect"))))
```

## Ref

ref 是可写的*浅*响应式单元。用 `etaf-value` 读取会被追踪；用 `etaf-set-value`、`setf` 或 `etaf-update-value` 写入时，新值与旧值不同才通知观察者。

组件里有两个名字相近的函数，它们都不是响应式源。`etaf-local-ref` 返回一个 Host 引用，用于 `:ref` 以及 Host 的查询、焦点和事件函数；`etaf-state` 返回组件 setup 的结果。调用它们本身不记录依赖。

#### Function: etaf-ref (initial-value &key test name)

创建一个保存 INITIAL-VALUE 的可写响应式单元并返回。

**参数。** INITIAL-VALUE 可以是任意 Lisp 值，原样保存，不复制。TEST 非 nil 时是一个函数，以 `(TEST OLD NEW)` 调用，返回非 nil 表示这次写入没有改变值；它取代[相等性](#相等性)中的默认判定。NAME 用于在错误数据和诊断中标识这个 ref。

**语义。** 创建 ref 不被追踪，也不登记到任何 Scope。

**返回。** 一个 ref 记录，`etaf-ref-p` 对它返回非 nil。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(create-ref)`。TEST 非 nil 又不是函数时 `error→ wrong-type-argument`，数据为 `(functionp TEST)`。

**示例。**

```elisp
(let ((count (etaf-ref 0 :name 'count)))
  (etaf-ref-p count))
;; ⇒ t
```

#### Function: etaf-ref-p (x)

X 是 `etaf-ref` 创建的 ref 时返回非 nil。计算值不是 ref：`(etaf-ref-p (etaf-computed #'ignore))` 为 nil。

#### Function: etaf-value (source)

返回响应式源 SOURCE 的当前值，并追踪这次读取。

**参数。** SOURCE 是 ref 或计算值。

**语义。** 对 ref，返回它保存的值。对计算值，先把它刷新到最新（见[计算值](#计算值)），再返回结果。有观察者正在运行时，这次读取成为它的依赖。

`etaf-value` 是广义变量：`(setf (etaf-value SOURCE) VALUE)` 展开为 `(etaf-set-value SOURCE VALUE)`，所以 `cl-incf`、`cl-decf` 和 `push` 都能直接用在 ref 上。`push` 会构造新的 cons，因此总会触发通知。

**错误。** SOURCE 既不是 ref 也不是计算值时 `error→ wrong-type-argument`，数据为 `(etaf-reactive-source-p SOURCE)`。计算值 getter 的错误原样传给调用者。

#### Function: etaf-set-value (source new-value)

把 NEW-VALUE 存进 ref SOURCE，并返回 NEW-VALUE。

**语义。**

1. 如果 ref 的 test（或默认相等性）判定旧值与 NEW-VALUE 相同，什么都不发生。即使 NEW-VALUE 是另一个对象，ref 也继续保存旧对象，不通知任何观察者。
2. 否则 ref 保存 NEW-VALUE，并向观察者推送变化。在批处理之外，排空在 `etaf-set-value` 返回之前完成；在批处理之内，新值立即可读，观察者等到最外层批处理结束。

**返回。** 两种情况都返回 NEW-VALUE。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(write NAME)`，NAME 是 ref 的名字。SOURCE 是计算值时 `error→ etaf-reactive-error`，数据为 `("Reactive value is read-only" NAME)`，NAME 是计算值的名字；SOURCE 根本不是响应式值时，第二个元素是它的 `type-of`。排空中的错误在写入完成之后传出，ref 保留 NEW-VALUE。

#### Function: etaf-update-value (source function &rest arguments)

把 ref SOURCE 的值替换为 `(apply FUNCTION OLD ARGUMENTS)` 并返回替换值，OLD 是它的当前值。

**语义。** 先做写入检查：渲染期间，或 SOURCE 不是 ref 时，在 FUNCTION 运行之前就报错。之后 FUNCTION 恰好运行一次。OLD 的读取不追踪。FUNCTION 必须返回新值，不能修改 OLD，也不能有外部副作用；这里不会自动复制。结果经 `etaf-set-value` 写入，相等性、通知和批处理规则与它相同。

**返回。** 替换值。

**错误。** `etaf-set-value` 的各项错误，在 FUNCTION 运行之前报出。FUNCTION 不是函数时 `error→ wrong-type-argument`，数据为 `(functionp FUNCTION)`。FUNCTION 报错时 ref 不变，错误原样传出。写入成功而之后的排空失败时，ref 保留替换值。

**示例。**

```elisp
(let ((task (etaf-ref '(:title "Draft" :done nil))))
  (etaf-update-value
   task (lambda (old done) (plist-put (copy-sequence old) :done done)) t)
  (etaf-value task))
;; ⇒ (:title "Draft" :done t)
```

### 相等性

<!-- index: 相等性; 浅相等; 同一性 -->

ref、计算值和侦听器给了 TEST 函数时用它判断值是否变化，否则用默认相等性：

| 值 | 比较方式 |
| --- | --- |
| cons（列表）、向量、记录、哈希表、函数 | 同一性（`eq`） |
| 缓冲区、marker、窗口、frame、overlay、进程 | 同一性（`eq`） |
| 其余一切：数字、字符串、符号等 | `equal` |

由此可知：

- 用 `setcar`、`aset`、`puthash` 或破坏性的 `plist-put` 原地修改对象，不会通知任何观察者。要存一个新对象。
- 存入新构造的列表总会通知，哪怕元素与旧列表相同。
- 存入 `equal` 的字符串或数字不起作用。
- `:test #'equal` 让 ref 或计算值把结构相等的列表视为未变。

```elisp
(let* ((items (etaf-ref (list 1 2)))
       (runs 0)
       (stop (etaf-watch-effect
              (lambda () (etaf-value items) (setq runs (1+ runs))))))
  (setcar (etaf-value items) 9)          ; 原地修改：察觉不到
  (etaf-set-value items (list 9 2))      ; 新对象：再次运行
  (funcall stop)
  runs)
;; ⇒ 2
```

## 计算值

<!-- index: 计算值; 派生状态; 惰性 -->

计算值用 getter 函数从其他源派生出一个值。它只读、惰性求值，并带缓存。

#### Function: etaf-computed (getter &key test name)

创建一个由无参函数 GETTER 派生的计算值并返回。此时 getter 还不运行。

**参数。** GETTER 计算这个值；它用 `etaf-value` 读过的每个源都成为依赖。TEST 非 nil 时以 `(TEST OLD NEW)` 调用，返回非 nil 表示新结果视为未变。NAME 用于在错误数据和诊断中标识这个计算值。

**语义。**

- 第一次 `etaf-value` 调用对 GETTER 求值并缓存结果。
- 之后的读取返回缓存值，直到某个依赖变化。依赖变化后计算值变为 dirty，下次读取时重新求值。
- 新结果在 TEST 或默认相等性下与旧结果相同时，计算值的观察者不会再次运行。
- 有活动 Scope 时，由它拥有这个计算值；活动 Scope 已停止时创建的计算值没有归属。所属 Scope 停止后，计算值释放全部依赖，之后每次读取都不追踪地重新对 GETTER 求值，不再缓存。
- 把 GETTER 当作渲染代码对待：只读源、返回值。不要在里面写 ref，也不要创建响应式对象。它在渲染期间被求值时，这些操作会报 `etaf-render-side-effect-error`。
- 已挂载的使用方在全部响应式输入都判定未变时，保留已发布的输出。在组件 setup 或其他 Runtime 操作期间创建的计算值，之后每次运行都在那次操作的环境里执行 GETTER，所以第一次运行之后 `etaf-inject`、`etaf-current-runtime` 和 `etaf-viewport` 仍然可用；见[创建环境](#创建环境)。

**返回。** 一个计算值记录，`etaf-computed-p` 对它返回非 nil。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(create-computed)`。参数不是函数时 `error→ wrong-type-argument`，数据为 `(functionp GETTER)` 或 `(functionp TEST)`。读取时 GETTER 报错，错误传给读取者；计算值保留上一次的值，仍为 dirty，下次读取时再求值。GETTER 直接或经由其他计算值读到自己时 `error→ etaf-reactive-error`，数据为 `("Recursive computed evaluation" NAME)`。

**示例。**

```elisp
(let* ((count (etaf-ref 2))
       (double (etaf-computed (lambda () (* 2 (etaf-value count))))))
  (list (etaf-value double)
        (progn (etaf-set-value count 5) (etaf-value double))))
;; ⇒ (4 10)
```

#### Function: etaf-computed-p (x)

X 是 `etaf-computed` 创建的计算值时返回非 nil。

## 侦听器与副作用

副作用现在运行一次，之后在它读过的源变化时再次运行。ETAF 提供两种形式。`etaf-watch` 观察一个值，把新值和旧值交给回调，回调本身不追踪；`etaf-watch-effect` 运行一个函数，函数里的每次读取都被追踪。

#### Function: etaf-watch (source callback &key immediate (flush 'pre) test name)

侦听 SOURCE，在它的值变化时以 `(CALLBACK NEW OLD)` 调用 CALLBACK。返回一个停止该侦听器的无参函数。

**参数。**

- SOURCE 是 ref、计算值或无参函数。函数在追踪下求值，因此可以组合多个源：`(lambda () (list (etaf-value x) (etaf-value y)))`。
- CALLBACK 接收新值和上一个值。
- IMMEDIATE 非 nil 时，初始值也调用一次 CALLBACK，此时 OLD 为 nil。
- FLUSH 选择阶段：`pre`（默认）或 `post`。
- TEST 非 nil 时以 `(TEST OLD NEW)` 调用。默认值：SOURCE 是带 test 的 ref 或计算值时用它自己的 test，否则用默认相等性。
- NAME 用于在诊断中标识这个侦听器。

**语义。**

1. `etaf-watch` 立即对 SOURCE 求值，记下依赖和初始值。没有 IMMEDIATE 时，此时不调用 CALLBACK。
2. 依赖变化后，侦听器在所属阶段重新对 SOURCE 求值。值与记下的相同时，到此为止。
3. 否则侦听器记下新值，运行上一次回调返回的清理函数（如果有），再不追踪地调用 CALLBACK。
4. CALLBACK 返回函数时，这个函数就是本次调用的清理函数，在下一次回调之前和侦听器停止时运行。

侦听器先记下新值，再调用 CALLBACK。CALLBACK 报错时，同一个值不会再投递一次。

有活动 Scope 时，由它拥有这个侦听器。在组件 setup 或其他 Runtime 操作期间创建的侦听器，之后每次运行都在该组件的环境里调用 CALLBACK，见[创建环境](#创建环境)。

**返回。** 停止函数。调用它会释放依赖、把侦听器移出所属 Scope，并运行待执行的清理函数。再次调用不起作用。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(watch)`。CALLBACK 不是函数时 `error→ wrong-type-argument`，数据为 `(functionp CALLBACK)`。`error→ etaf-reactive-error`，数据为 `("Watch source must be reactive or callable" SOURCE)` 或 `("Invalid watcher flush" FLUSH)`。活动 Scope 已停止时 `error→ etaf-reactive-error`，数据为 `("Inactive Scope" SCOPE)`。

**示例。**

```elisp
(let* ((count (etaf-ref 0))
       seen
       (stop (etaf-watch count (lambda (new old) (push (cons old new) seen)))))
  (etaf-set-value count 1)
  (etaf-set-value count 1)               ; 值相同：不调用
  (etaf-set-value count 2)
  (funcall stop)
  (nreverse seen))
;; ⇒ ((0 . 1) (1 . 2))
```

#### Function: etaf-watch-effect (function &key (flush 'pre) name)

现在运行无参函数 FUNCTION，之后它读过的任何源变化时再次运行。返回一个停止该副作用的无参函数。

**参数。** FUNCTION 每次运行都被追踪。FLUSH 是 `pre`（默认）或 `post`，与 `etaf-watch` 相同。NAME 用于在诊断中标识这个副作用。

**语义。** 从第二次运行起，每次运行之前先不追踪地调用上一次运行返回的清理函数（如果有）。FUNCTION 返回函数时，这个函数成为本次运行的清理函数；副作用停止时也会调用它。`etaf-watch` 的 Scope 规则和创建环境规则同样适用。

副作用运行期间，它已依赖的某个源发生变化（例如 FUNCTION 自己写了它），副作用会在同一次排空中再运行一次。依赖在一次运行结束时才登记，所以第一次运行中的写入不会引起重跑。每次运行都向自己读的源写入不同值的副作用，永远不会稳定。

**返回。** 停止函数，与 `etaf-watch` 相同。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(watch-effect)`。FUNCTION 不是函数时 `error→ wrong-type-argument`，数据为 `(functionp FUNCTION)`。FLUSH 无效或活动 Scope 已停止时 `error→ etaf-reactive-error`，与 `etaf-watch` 相同。第一次运行的错误从 `etaf-watch-effect` 传出；副作用仍然登记着，依赖为报错前读过的源。

### 清理函数

<!-- index: 清理函数 -->

侦听器回调或副作用函数返回的清理函数，用来释放这次调用占用的资源：定时器、进程、缓冲区局部钩子。每个清理函数最多运行一次：在下一次调用之前，或在侦听器、副作用停止时，以先到者为准。停止所属 Scope 会停止副作用，最后一个清理函数在那时运行。

### 创建环境

<!-- index: 创建环境; 组件环境 -->

在组件 setup 或其他 Runtime 操作期间创建的侦听器、副作用和计算值，会捕获这次操作的环境：组件实例、它的 Context 和它的 Runtime（计算值用这个环境执行 GETTER）。之后每次运行都以生命周期操作的身份重新进入这个环境，所以第一次运行之后 `etaf-inject`、`etaf-current-runtime` 和 `etaf-viewport` 仍然可用，回调也不会被当作渲染。在任何 Runtime 操作之外创建的响应式回调，运行在排空时的动态环境里。

```elisp :run
(etaf-define-component demo-reactivity-lab ()
  :bindings ((n (etaf-ref 2))
             (factor (etaf-ref 3))
             (runs (etaf-ref 0))
             (log (etaf-ref nil)))
  :setup
  (let ((total (etaf-computed (lambda () (* (etaf-value n) (etaf-value factor)))
                              :name 'demo-total)))
    (etaf-watch-effect
     (lambda ()
       (let ((line (format "n=%d × %d = %d" (etaf-value n)
                           (etaf-value factor) (etaf-value total))))
         (etaf-set-value runs (1+ (etaf-value runs)))
         (etaf-set-value log (append (etaf-value log) (list line)))))))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (row :item-gap '(ch 2)
               (etaf-number-input :label "n" :value 2 :min 0 :max 9
                                  :on-change (lambda (v) (etaf-set-value n v)))
               (etaf-number-input :label "倍数" :value 3 :min 1 :max 4
                                  :on-change (lambda (v) (etaf-set-value factor v))))
          (text (expr (format "结算次数：%d" (etaf-value runs))))
          (text :color (etaf-theme-token :ui-muted-fg "#526174") (expr (format "最近一次：%s"
                                               (or (car (last (etaf-value log))) "—"))))))
(etaf-view (demo-reactivity-lab))
```

## 选择器

<!-- index: 选择器; 选中 -->

选择器为大量 key 回答「这个 key 是不是被选中的那个」，并且只通知答案变了的 key。

#### Function: etaf-selector (source &key (test 'equal) name)

返回一个单参数函数：参数 KEY 在 TEST 下等于响应式源 SOURCE 的值时，它返回非 nil。

**参数。** SOURCE 是 ref 或计算值。TEST 是哈希表的 test：`eq`、`eql` 或 `equal`。NAME 用于在诊断中标识选择器的侦听器和单元。

**语义。** 每个 KEY 有自己的响应式单元。调用选择器的读取者只依赖它所问那个 KEY 的单元。SOURCE 从 A 变为 B 时，选择器在一次批处理里更新 A 和 B 的单元，只有这两个 key 的读取者再次运行。因此一个高亮选中行的长列表，选中项移动时只重新渲染两行，而不是每一行。

在组件 setup 或 `:bindings` 中创建选择器，这样组件的 Scope 拥有它的侦听器。在需要随之更新的 View 属性或渲染里调用选择器，例如 `:background-color (if (funcall selected id) 'highlight 'default)`。

单元在第一次使用时创建。单元数超过阈值（初始为 256）时，选择器丢弃没有观察者使用的单元，并把阈值设为 256 与剩余单元数两倍中的较大者。

**返回。** 一个单参数函数。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(selector)`。TEST 是其他值时 `error→ wrong-type-argument`，数据为 `((member eq eql equal) TEST)`；SOURCE 不是响应式源时，数据为 `(etaf-reactive-source-p SOURCE)`。

**示例。** 加粗的行跟随选中的 key；按下某一行就把选中项移过去。

```elisp :run
(etaf-define-component demo-selection ()
  :bindings ((current (etaf-ref 'beta))
             (current-p (etaf-selector current)))
  :view
  (column
   (text :for (id '(alpha beta gamma)) :key id
         :role 'button :tab-index 0
         :font-weight (if (funcall current-p id) 'bold 'normal)
         :on-press (lambda () (etaf-set-value current id))
         (expr (symbol-name id)))))
(etaf-view (demo-selection))
```

## 批处理与 tick

<!-- index: 批处理; next tick -->

批处理把多次写入合成一组，让观察者一起看到。`etaf-next-tick` 把工作推迟到待处理写入的输出发布之后。

#### Macro: etaf-batch (&rest body)

把 BODY 作为一次响应式批处理求值，返回最后一个形式的值；BODY 为空时返回 nil。它等价于 `(etaf-call-with-batch (lambda () BODY...))`，语义和错误与 `etaf-call-with-batch` 相同。

#### Function: etaf-call-with-batch (function)

把无参函数 FUNCTION 作为一次响应式批处理调用，待处理的响应式工作完成后返回它的结果。

**语义。**

- FUNCTION 内的 ref 写入立即生效，立即可读。已有观察者的副作用和 Runtime 更新，要等最外层批处理结束。
- 嵌套批处理并入最外层。事件回调和 Action 处理函数已经运行在批处理里，在其中再显式开批处理没有作用。
- 最外层批处理结束时执行排空，`etaf-call-with-batch` 在排空之后返回，包括 `etaf-next-tick` 的函数。
- 批处理不提供回滚。FUNCTION 失败时写入照样保留，也没有跨 Runtime 的原子发布；每个 Runtime 的提交遵循它自己的失败约定。
- 批处理是同步的，要在 Emacs 主事件循环里使用。之后才运行的定时器、进程过滤器等异步回调不属于这次批处理，需要自己开批处理。

**返回。** FUNCTION 的结果。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(batch)`。FUNCTION 不是函数时 `error→ wrong-type-argument`，数据为 `(functionp FUNCTION)`。FUNCTION 报错或被 quit 中断时，待处理工作照样排空，排空中的错误被丢弃，然后重新抛出原来的条件。FUNCTION 正常返回而排空失败时，抛出排空中的第一个错误。

**示例。**

```elisp
(let* ((x (etaf-ref 0))
       (y (etaf-ref 0))
       observed
       (stop (etaf-watch (lambda () (list (etaf-value x) (etaf-value y)))
                         (lambda (new _old) (push new observed)))))
  (etaf-batch
    (etaf-set-value x 3)
    (etaf-set-value y 4))
  (funcall stop)
  observed)
;; ⇒ ((3 4))     ; 只投递一次，绝不会出现 (3 0)
```

#### Function: etaf-next-tick (function)

待处理的响应式工作发布之后调用无参函数 FUNCTION，返回 nil。

**语义。** 在批处理、事件回调或副作用里，FUNCTION 进入队列。它在最外层批处理排空、每个已挂载 Runtime 都写完缓冲区之后运行，所以前面写入新建的 Host 已经有了位置和滚动范围。回调刚加了一行、要滚动到它或聚焦它时用这个函数。在批处理之外没有待处理的工作，FUNCTION 立即运行。

队列中的函数按入队顺序运行。它们运行期间新入队的函数并入同一轮。前面的排空失败时，它们照样运行。

**返回。** nil。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(next-tick)`。FUNCTION 不是函数时 `error→ wrong-type-argument`，数据为 `(functionp FUNCTION)`。队列中的函数报错时，其余函数照样运行，之后抛出其中第一个错误。排空和队列中的函数都失败时，抛出的是队列函数的错误。

## Scope

<!-- index: Scope; 归属; 释放 -->

Scope 是响应式归属的单位。*活动 Scope* 拥有它活动期间创建的对象：

| 创建方式 | 活动 Scope 拥有的对象 |
| --- | --- |
| `etaf-computed` | 计算值 |
| `etaf-watch`、`etaf-watch-effect`、`etaf-selector` | 副作用，或选择器内部的侦听器 |
| 不带 `:detached` 的 `etaf-effect-scope` | 子 Scope |
| `etaf-on-scope-dispose` | 清理函数 |
| `etaf-ref` | 无：ref 没有归属 |

每个组件实例都有一个 Scope。它的 `:bindings` 和 setup 在这个 Scope 活动时运行，卸载实例时 Scope 停止。组件之外的代码用 `etaf-effect-scope` 创建 Scope，用 `etaf-scope-run` 进入它，用 `etaf-scope-stop` 停止它。

#### Function: etaf-effect-scope (&key detached name)

创建一个 Scope 并返回。

**参数。** DETACHED 非 nil 时，创建的 Scope 没有父级。NAME 用于在诊断中标识这个 Scope。

**语义。** 不带 DETACHED 时，当前活动 Scope（如果有）成为父级。父级停止时会停止它的子 Scope。没有父级的 Scope（无论是 detached，还是创建时没有活动 Scope）必须由创建者用 `etaf-scope-stop` 停止；只在某个形式的执行期间存在的 Scope，放在 `unwind-protect` 里停止。

**返回。** 一个新的活动 Scope。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(create-scope)`。活动 Scope 已停止时 `error→ etaf-reactive-error`，数据为 `("Inactive parent Scope" PARENT)`。

#### Function: etaf-scope-run (scope function)

以 SCOPE 为活动 Scope 调用无参函数 FUNCTION，返回它的值。FUNCTION 创建的、可由 Scope 拥有的一切都归 SCOPE。

**错误。** SCOPE 不是 Scope 或已停止时 `error→ etaf-reactive-error`，数据为 `("Cannot enter an inactive Scope")`。FUNCTION 的错误原样传出；SCOPE 保持活动，保留 FUNCTION 报错前创建的对象。

#### Function: etaf-scope-stop (scope)

释放 SCOPE，返回释放过程中收集到的条件。

**语义。** 停止按以下顺序进行：

1. 把 SCOPE 标为非活动。此后不能再进入它，它也不再接受新的副作用、计算值、子 Scope 或清理函数。
2. 递归停止子 Scope。
3. 停止拥有的副作用（运行它们待执行的清理函数），再停止拥有的计算值。
4. 按登记的逆序运行清理函数。
5. 把 SCOPE 从父级中移除。

第 2 到第 4 步中的错误或 quit 不会中断释放：它被记录下来，剩余工作继续进行。

**返回。** 一个列表，每次失败对应一个条件 `(SYMBOL . DATA)`；全部顺利停止时为 nil。不要依赖列表的顺序。停止已停止的 Scope，或停止一个不是 Scope 的值，返回 nil。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(stop-scope)`。释放过程中的失败作为返回值交回，不抛出。

#### Function: etaf-on-scope-dispose (function)

登记无参函数 FUNCTION，在活动 Scope 停止时运行，返回 FUNCTION。

**语义。** 清理函数只运行一次，在 Scope 的子 Scope 和副作用停止之后，按登记的逆序运行。清理函数的错误由 `etaf-scope-stop` 收集，不妨碍其他清理函数运行。

**错误。** 渲染期间 `error→ etaf-render-side-effect-error`，数据为 `(register-scope-cleanup)`。FUNCTION 不是函数时 `error→ wrong-type-argument`，数据为 `(functionp FUNCTION)`。没有活动 Scope 或活动 Scope 已停止时 `error→ etaf-reactive-error`，数据为 `("Cleanup registration requires an active Scope")`。

**示例。**

```elisp
(let ((scope (etaf-effect-scope :detached t))
      (count (etaf-ref 0))
      log)
  (unwind-protect
      (etaf-scope-run
       scope
       (lambda ()
         (etaf-watch-effect (lambda () (push (etaf-value count) log)))
         (etaf-on-scope-dispose (lambda () (push 'released log)))
         (etaf-set-value count 1)))
    (etaf-scope-stop scope))
  (etaf-set-value count 2)               ; 副作用已停止
  (nreverse log))
;; ⇒ (0 1 released)
```

## 语义细节

### 一次写入的完整路径

应用代码在批处理之外写 ref 时：

1. ref 保存新值。新值与旧值相等时，路径到此结束。
2. 直接观察者变为 dirty，经由计算值间接依赖它的观察者变为 check。离开 clean 状态的副作用进入队列。
3. 开始排空。pre 副作用按创建顺序运行；处于 check 的副作用先刷新它的计算值输入，没有一个变化就跳过。
4. render 副作用以同样方式运行，产生 Runtime 输出。
5. 输出有变化的每个已挂载 Runtime 提交一次，写一次缓冲区。
6. post 副作用运行。
7. 只要第 3 到第 6 步中任何一步还有活，就重复它们。
8. `etaf-next-tick` 的函数运行。
9. 第 3 到第 6 步收集到的第一个错误被重新抛出；没有错误时写入返回。

在批处理之内，第 1、2 步在每次写入时发生，第 3 到第 9 步在最外层批处理结束时发生一次。

### 渲染不产生副作用

<!-- index: 渲染; 副作用 -->

*渲染*指对 View 内容求值：动态 Host 属性、`expr` 子节点、`:render` 主体，以及它们读取的计算值。渲染可以读取源，但不能改变图。渲染期间，下列操作会报 `etaf-render-side-effect-error`：

| 操作 | 条件数据 |
| --- | --- |
| `etaf-ref` | `(create-ref)` |
| `etaf-computed` | `(create-computed)` |
| `etaf-watch` | `(watch)` |
| `etaf-watch-effect` | `(watch-effect)` |
| `etaf-selector` | `(selector)` |
| `etaf-effect-scope` | `(create-scope)` |
| `etaf-on-scope-dispose` | `(register-scope-cleanup)` |
| `etaf-scope-stop` | `(stop-scope)` |
| `etaf-call-with-batch`、`etaf-batch` | `(batch)` |
| `etaf-next-tick` | `(next-tick)` |
| `etaf-set-value`、`setf`、`etaf-update-value` | `(write NAME)` |

事件回调、生命周期回调，以及 setup 期间创建的副作用的后续运行，都不算渲染，可以写入。在 `:bindings` 或 setup 里创建响应式对象，在回调里写入它们。

### 已挂载的 Runtime

<!-- index: Runtime 提交; 发布 -->

已挂载的 Runtime 参与每一次排空：

- 它的渲染绑定是 render 阶段的副作用。计算值输入全都判定未变的绑定会被跳过，输出不会重新发布。
- render 阶段和 post 阶段之间，输出有变化的每个 Runtime 提交一次。整个排空运行在一次 Ebox 批处理里，所以每次提交只写一次缓冲区。
- post 侦听器看到的是已经写好的缓冲区。
- pre 或 render 副作用失败时，Runtime 回滚正在进行的提交，保留上一次提交的输出。已经运行过的副作用被保留下来，在下一次有活的排空或显式调用 `etaf-runtime-flush` 时再次运行。应用的 ref 保留已写入的值。因此持续的失败会让屏幕停在上一次提交的输出，直到原因被修复。

### 框架发布的源

<!-- index: 框架发布的源; 视口; 动画 -->

有几个框架函数返回响应式源，读取它们的渲染、计算值或副作用会像其他观察者一样重新运行。每个函数在它所属的子系统中详细描述。

| 函数 | 源 |
| --- | --- |
| `etaf-prop` | 组件的一个输入，作为只读源；在计算值的 getter 和侦听器中用 `etaf-value` 读取 |
| `etaf-runtime-viewport` | 已挂载 Runtime 的画布视口，形如 `(WIDTH . HEIGHT)`；视口变化后读取者重新运行，包括窗口尺寸变化后的自动重排 |
| `etaf-viewport-region` | 一个组件，把自己提交后的盒发布为其下所有组件的视口 |
| `etaf-transition`、`etaf-animation-frames` | 由[动画时钟](animation.md)写入的 ref；每一拍是一个批处理，所以每个 Runtime 最多提交一次 |
| `etaf-data-status`、`etaf-data-mutation-outcome` | Data Controller 的状态 ref 和变更结果 |

有两个相关函数不是响应式的。`etaf-runtime-revision` 返回一个整数，每次改变了缓冲区的提交使它加一；比较两次读到的修订号，就能确认某个变化已经发布。`etaf-host-ref-size` 查询提交后的几何尺寸；它不发布任何东西，也不适合逐帧轮询。

`etaf-runtime-update-host-content`、`etaf-runtime-update-host-contents`、`etaf-runtime-update-host-geometry` 和 `etaf-runtime-update-host-geometries` 修改一个或多个 Host，只写一次缓冲区，不经过依赖图。View 仍然是权威：下一次常规发布必须渲染出相同的内容，否则 Host 会按 View 的渲染结果校正回来。

### 异步代码

批处理只覆盖它的函数同步执行的那段时间。定时器、进程过滤器或 sentinel 在之后运行，处在任何批处理之外：除非它自己开批处理，否则其中的写入会立即排空。这类回调里的多次相关写入，应放进同一个 `etaf-batch`。

### 代价

- 读取是常数时间，加上刷新过期计算值的开销。
- 写入的代价与它触及的观察者数成正比。计算值只在刚变为过期时向外传递变化，所以已经过期的计算值会吸收后续写入。
- 一次运行读取的源和顺序与上次相同时，不改动任何订阅。
- 对一个阶段的队列排序的代价是 O(n log n)，n 为排队的副作用数；只有一个副作用的队列不排序。

## 错误与恢复

#### Error: etaf-reactive-error

响应式图拒绝了一个操作。用 `condition-case` 捕获它；抛出它的调用没有返回值。数据的第一个元素是一条消息字符串：

| 消息 | 由谁抛出 |
| --- | --- |
| `"Reactive value is read-only"` | 写入计算值或非响应式值 |
| `"Recursive computed evaluation"` | 读到自身的计算值 |
| `"Watch source must be reactive or callable"` | SOURCE 无效的 `etaf-watch` |
| `"Invalid watcher flush"` | 无法识别的 FLUSH |
| `"Inactive Scope"` | 活动 Scope 已停止时创建副作用 |
| `"Inactive parent Scope"` | 在已停止的 Scope 下调用 `etaf-effect-scope` |
| `"Cannot enter an inactive Scope"` | 对已停止的 Scope 调用 `etaf-scope-run` |
| `"Cleanup registration requires an active Scope"` | 没有活动 Scope 时调用 `etaf-on-scope-dispose` |

#### Error: etaf-render-side-effect-error

渲染期间尝试了会改变响应式图的操作。数据是操作名，列在[渲染不产生副作用](#渲染不产生副作用)中。它的父条件是 `etaf-reactive-error`，所以 `etaf-reactive-error` 的处理器也能捕获它。

### 恢复

| 失败 | 留下的状态 |
| --- | --- |
| 计算值的 getter 报错 | 保留上一次的缓存值；计算值仍为 dirty，下次读取时重试 |
| 侦听器回调报错 | 侦听器保持活动，已记下新值；错误在排空后抛出 |
| 副作用函数报错 | 副作用保持活动，依赖为旧依赖加上新读到的源 |
| 排空中 pre 或 render 副作用失败 | 已挂载的 Runtime 保持上一次提交：缓冲区和 `etaf-runtime-revision` 都不变。ref 保留写入的值，侦听器（包括 post 侦听器）照样收到这些值，所以 post 侦听器不能假定缓冲区已经显示它们。失败的工作在下一次排空或 `etaf-runtime-flush` 时重试，故障未消除时会再次报错 |
| 批处理的主体报错 | 所有写入保留；待处理工作照样排空；抛出主体的条件 |
| `etaf-scope-stop` 期间清理函数报错 | 释放继续进行；条件出现在返回的列表里 |
| `etaf-next-tick` 队列中的函数报错 | 其余队列函数照样运行；抛出第一个错误 |

排空失败后副作用仍在运行：一个副作用失败不会让同一阶段的其他副作用停下。一次排空中的所有错误都被收集起来，排空结束时抛出第一个。
