# Runtime

*Runtime* 是一个活着的 ETAF 应用：挂载进一个 Emacs 缓冲区的 View，连同让它输出保持最新的保留树、绑定到它的响应式图、它的已提交修订号，以及它的各组件实例的生命周期。本章讲挂载与卸载、如何找到拥有某个缓冲区的 Runtime、提交与修订号如何运作、高频 Host 内容与几何的保留更新边界、内省接口、transient space 检查，以及 Runtime 层的错误条件。

Runtime 建立在 [View](views.md)、[组件](components.md)和[响应式系统](reactivity.md)之上：`etaf-mount` 发布一个归一化的 View，Runtime 拥有让它保持最新的渲染绑定，每次提交是响应式系统定义的排空中的一步。Host 种类、属性与引用属于 [Host](hosts.md)。

<!-- index: Runtime; 挂载; 卸载; 提交; 修订号; 保留更新; 内省 -->

## 模型

### Runtime 与它的缓冲区

一个 Runtime 恰好属于一个缓冲区。`etaf-mount` 创建它、把第一个 View 发布进缓冲区，并把它登记为该缓冲区的 Runtime；向同一个缓冲区再次挂载会先释放前一个 Runtime，所以一个缓冲区不会有两个。杀掉缓冲区会卸载 Runtime。

挂载期间，Runtime 拥有 View 放进缓冲区的一切：保留树与每个 Host 的 Ebox 节点、活着的组件实例及其 Scope、已登记的 Host 引用及其保留属性的引用，以及 [Host](hosts.md) 为 `:keys` 描述的缓冲区局部按键处理。除向同一缓冲区挂载新 View 之外，释放它的方式是 `etaf-unmount` 和杀掉缓冲区。

找到已挂载 Runtime 有三种方式：从动态上下文（`etaf-current-runtime`）、从缓冲区（`etaf-runtime-for-buffer`），或保存挂载时返回的对象。已卸载的 Runtime 不再被查找函数返回，但对象本身仍然应答访问器。

### 输出、提交与修订号

View 是描述，Runtime 保存输出。View 的静态部分构建一次，每个动态部分成为一个副作用，绑定到它更新的那一块树。对应用状态的写入把读过它的副作用排进队列；排空按阶段顺序运行它们，在 render 与 post 之间，输出有变化的每个 Runtime 提交：缓冲区写一次、已提交修订号前进、本次提交的生命周期钩子运行。确切的阶段、队列与失败规则属于[响应式系统](reactivity.md#排空)。

于是 Runtime 有一个*已提交修订号*：一个整数，每发生一次改变了缓冲区的提交就 +1。应用代码用它来观察某次发布已经到达缓冲区（例如在显式 flush 之后），而不是把它当作树上的句柄。

## 挂载与卸载

#### Function: etaf-mount (buffer-or-name view &optional options)

把归一化的 VIEW 挂载进 BUFFER-OR-NAME，并返回它的缓冲区。

**参数。**

- BUFFER-OR-NAME 是缓冲区或缓冲区名。缓冲区不存在时会被创建；Runtime 不显示它。
- VIEW 是 [View](views.md) 定义的归一化 View，或返回 View 的零参函数。函数带追踪求值，所以读了响应式源的 View 函数会在该源变化时重新渲染。
- OPTIONS 是 plist。支持的键有 `:viewport-width`（像素）与 `:viewport-height`（行），首次发布会直接使用它们而不立刻重新布局；`:observer`，一个在首次渲染前安装的单参报告 sink；以及 `:text-selection`，一个布尔值（`t` 或 `nil`），在挂载期间允许画布上的 Emacs 原生 mark 与指针文本选择。维度为 nil 时跟随所在窗口。视口细节属于[视口](viewport.md)章；报告格式属于[增量更新与发布](incremental-updates-and-publication.md)。

**语义。** BUFFER-OR-NAME 里已挂载的 Runtime 会被先卸载，所以新 View 取代旧应用。首次发布是一次被观测的操作：View 被降级并渲染、整个缓冲区写一次、已提交修订号变为 1。登记 Runtime 的同时安装它的按键处理与 `kill-buffer-hook`，所以杀掉缓冲区会卸载它。首次发布失败时，新 Runtime 被释放、条件向外传播，缓冲区存活且没有 Runtime。

**返回。** BUFFER-OR-NAME，一个活着的缓冲区。

**错误。** OPTIONS 不是 proper plist、含有上面四个之外的键、`:viewport-width` 或 `:viewport-height` 既不是 nil 也不是正数、`:observer` 既不是 nil 也不是函数、或 `:text-selection` 不是布尔值（`nil` 或 `t`）时，`error→ etaf-runtime-error`，数据给出消息与出错的值或键。View 自身的问题原样传播它的条件，例如 `etaf-view-error`、`etaf-view-syntax-error`、`etaf-component-call-error` 或 `etaf-renderer-error`，缓冲区不留下 Runtime。渲染期间调用会 `error→ etaf-render-side-effect-error`，数据为 `(mount-runtime)`。

**示例。** 已经知道布局上下文的无头宿主可省掉首次重新布局。

```elisp
(etaf-mount "*tasks*"
            view
            '(:viewport-width 1200 :viewport-height 48))
```

**参见。** `etaf-unmount`、[查找 Runtime](#查找-runtime) 与[视口](viewport.md)章。

### 原生应用窗口

原生文本应用拥有它打开所在的窗口。`etaf-app-open` 不理会用户的 `display-buffer` 规则，把缓冲区显示在选中窗口里，这些规则因此无法把 frame 拆成侧栏；这个生命周期见[应用](applications.md)一章。根 View 顶部留一行空白：把它算进页面与行数预算的 chrome，短窗口时少渲染内容行而不是裁掉第一行。顶部这一行是应用的约定，不是 `etaf-mount` 的选项。

#### Function: etaf-unmount (&optional runtime)

卸载 RUNTIME，默认取活动 Runtime 或 `current-buffer` 的 Runtime。

**参数。** RUNTIME 是 Runtime；传入其它类型的值会 `wrong-type-argument`。省略或 nil 时先取正在调用的 Runtime，再取 `(current-buffer)` 的 Runtime。必须有已挂载的 Runtime：一个都没有时调用 `etaf-runtime-error`。

**语义。** 卸载是挂载的反向操作：保留树及其 Ebox 节点被释放，组件被释放、它们的 unmounted 钩子运行，缓冲区局部按键处理与 Ebox 挂载被移除，Runtime 与它的缓冲区脱钩，因此 `etaf-runtime-for-buffer` 不再返回它、`etaf-runtime-mounted-p` 返回 nil。缓冲区本身存活并保留最后一次发布的文本；Runtime 对象也存活、仍然应答访问器，但不能再被更新或 flush。杀掉缓冲区会不经过显式调用直接卸载 Runtime。

**返回。** RUNTIME。

**错误。** RUNTIME、活动 Runtime 与当前缓冲区的 Runtime 全都已卸载或不存在时，`error→ etaf-runtime-error`，消息为 `"ETAF runtime is not mounted"`。渲染期间调用会 `error→ etaf-render-side-effect-error`，数据为 `(unmount-runtime)`。

**示例。** 释放当前缓冲区的应用。

```elisp
(etaf-unmount (etaf-runtime-for-buffer "*tasks*"))
```

**参见。** `etaf-mount`、`etaf-runtime-for-buffer` 与 `etaf-runtime-mounted-p`。

## 查找 Runtime

这四个函数定位一次操作该用的 Runtime：回调内部的动态上下文、回调外部的缓冲区，以及两个回答「Runtime 对象是否仍挂载」的访问器。

#### Function: etaf-current-runtime ()

返回拥有当前 setup、生命周期钩子或事件回调的 Runtime；在 Runtime 操作之外返回 nil。

**语义。** 在组件 setup、生命周期钩子、事件回调和已挂载 View 的渲染绑定里，调用返回这些绑定所属的 Runtime。在这类操作之外（包括 `etaf-render` 内部）返回 nil。需要挂载缓冲区的生命周期代码必须用 `(etaf-runtime-buffer (etaf-current-runtime))`：`current-buffer` 是调用者的缓冲区，当 `etaf-mount` 收到的是名字时不保证是挂载目标。

**返回。** 一个已挂载 Runtime，或 nil。

**示例。** 生命周期钩子为 Runtime 自己的缓冲区打开资源。

```elisp
(etaf-on-mounted
 (lambda ()
   (let ((buffer (etaf-runtime-buffer (etaf-current-runtime))))
     (with-current-buffer buffer (open-resource)))))
```

**参见。** `etaf-runtime-buffer` 与[组件](components.md#生命周期钩子)。

#### Function: etaf-runtime-for-buffer (buffer-or-name)

返回挂载在 BUFFER-OR-NAME 里的活 Runtime，没有则返回 nil。

**参数。** BUFFER-OR-NAME 是缓冲区或缓冲区名，与 `get-buffer` 相同。

**语义。** 查找只到已挂载的 Runtime。没有对应缓冲区的名字、已杀掉的缓冲区、Runtime 已卸载的缓冲区都得到 nil。

**返回。** 已挂载 Runtime，或 nil。

#### Function: etaf-runtime-buffer (x)

访问 Runtime 对象 X 的槽 "buffer"。

**参数。** X 是 Runtime 对象。其它值 `wrong-type-argument`，数据为 `(etaf-runtime X)`。

**语义。** 访问器返回 Runtime 发布所在的缓冲区，无论 Runtime 是否仍挂载，所以对正在卸载的 Runtime 调用是安全的。

**返回。** 该缓冲区。

#### Function: etaf-runtime-mounted-p (x)

访问 Runtime 对象 X 的槽 "mounted-p"。

**参数。** X 是 Runtime 对象。其它值 `wrong-type-argument`，数据为 `(etaf-runtime X)`。

**语义。** Runtime 挂载期间值非 nil，`etaf-unmount` 之后或缓冲区被杀之后为 nil。向同一缓冲区挂载新 View 会得到新 Runtime；旧对象不会再变为已挂载。

**返回。** 挂载期间非 nil，否则 nil。

## 提交与修订号

#### Function: etaf-runtime-flush (&optional runtime)

结算已挂载 RUNTIME 的待处理响应式工作，并返回它的修订号。

**参数。** RUNTIME 是已挂载 Runtime；nil 或省略时取活动 Runtime，回退到当前缓冲区的 Runtime。

**语义。** 不在批处理、排空和渲染求值中时，调用立刻运行待处理的响应式工作（包括上一次失败更新留下的暂停副作用），并返回由此产生的提交之后的修订号。在 `etaf-call-with-batch` 或运行中的提交里，待处理工作仍推迟到那个边界，调用返回当前修订号而不排空。flush 是同步调用者保证自己的写入已到达缓冲区的显式方式。

**返回。** Runtime 的已提交修订号，一个整数。

**错误。** 解析不出已挂载 Runtime 时 `error→ etaf-runtime-error`，消息为 `"ETAF runtime is not mounted"`。flush 所运行的那次排空的错误在排空之后传播，如[响应式系统](reactivity.md#恢复)所述；持续失败会在每次 flush 时再次报告。

**示例。** 基准测试写入状态，在读取缓冲区之前等待发布。

```elisp
(let ((runtime (etaf-runtime-for-buffer buffer)))
  (etaf-set-value tasks new-tasks)
  (etaf-runtime-flush runtime))
```

**参见。** `etaf-runtime-revision` 与[原子提交](#原子提交)。

#### Function: etaf-runtime-revision (runtime)

返回 RUNTIME 的已提交修订号：每发生一次改变了它缓冲区的提交就 +1 的整数（普通响应式工作、Host 内容或几何更新，以及改变了布局的 `etaf-runtime-refit` 或 `etaf-refit` 调用）。测试与基准测试比较修订号来观察某次变化已经发布。

**参数。** RUNTIME 是 Runtime 对象。其它值 `wrong-type-argument`，数据为 `(etaf-runtime RUNTIME)`。

**语义。** 修订号在 Runtime 的生命期内单调，只在改变了缓冲区的提交上前进。所有观察者都比较不变的写入不会让它前进；被回滚的失败更新不会让它前进；开着的批处理里排队的工作在批处理提交前不会让它前进。访问器不排空，也不要求 Runtime 已挂载：卸载后它继续回答最后一次提交的值。

**返回。** 已提交修订号，整数。

**参见。** `etaf-runtime-flush` 与[响应式系统](reactivity.md#已挂载的-runtime)。

### 原子提交

一次提交对一次排空的工作是全有或全无。排空跑在一个事务里，事务为它开始时已存在的状态记录每一次改动的撤销日志：保留段与 Host、组件实例、已写入的响应式单元值，以及 Ebox 节点的属性与文本。事务创建的对象不入日志；提交被放弃时它们被释放。被替换但已提交的资源的清理等到事务提交。

pre 或 render 副作用失败时，Runtime 丢弃整份未提交的工作：缓冲区保留上一次成功提交的输出，修订号不前进，应用自己的 ref 保留已写入的值。运行过的副作用被留下并暂停：下一次有工作的排空，或下一次 `etaf-runtime-flush`，会再次运行它们。post 阶段的失败不丢弃提交——缓冲区已经写好、修订号已经前进——错误在排空末尾与其它错误一起传播。这是[响应式系统](reactivity.md#恢复)所述的恢复契约在 Runtime 一侧的体现。

由于日志只覆盖改动过的部分，一次提交的代价与事务触碰的状态成比例，而不是与 View 的大小成比例。

## 保留 Host 更新

已挂载 Runtime 可以直接更新某个被寻址 Host 的已发布内容或几何，不经过响应式图。这是调用方自己拥有、以高频重新发布的值（视频帧、图表数据、实时测量）的显示边界：值绕过组件 props 与普通发布路径，一次 Ebox 发布更新一个或几个 Host。

#### Function: etaf-runtime-update-host-content (runtime host-ref content)

在已挂载 RUNTIME 里用 CONTENT 替换 HOST-REF 已发布的内容。

**参数。** RUNTIME 是已挂载 Runtime。HOST-REF 是 Text Host 的已提交 Host 引用，例如 `text` Host 的 `:ref`。CONTENT 是字符串，作为 Host 的文本发布；或是 `create-image` 返回的 image 对象，作为一个 image cell 发布，按图像自身大小显示。没有原生图像支持的 Emacs 构建只接受字符串；被拒绝的值仍会在任何内容或修订号变化之前报告 `error→ etaf-runtime-error`。

**语义。** 更新只替换被寻址的 Host，并通过 Ebox 发布一次，所以受控状态只变了一个值的调用方可以跳过普通的 ETAF 发布。字符串保留调用方自有的显示属性（包括 image slice）；用逐帧图像维持一个固定尺寸 Host 的调用方每次更新传新的 image 对象。View 仍是权威：更新改变的是 Host 已发布的内容，不是 View 或渲染它的组件，所以保留值必须与 View 渲染的内容一致，[保留内容的和解](#保留内容的和解)一节说明这一点。更换媒体请用 Text Host；Box Host 的内容是它的子结构，本调用拒绝它。

**返回。** 提交后返回 t。

**错误。** RUNTIME 未挂载、HOST-REF 不是已提交 Host（消息 `"Unknown committed Host"`）、CONTENT 既不是字符串也不是 image 对象（`"Invalid Host content updates"`）、被寻址 Host 的保留节点不能持有内容（例如 Box，消息 `"Host cannot hold content"`）时，在发生任何改动之前 `error→ etaf-runtime-error`。

**示例。** 视频帧放在自己的 Host 上，每解出一帧更新一次。

```elisp
(etaf-runtime-update-host-content runtime 'video-frame frame-image)
```

**参见。** `etaf-runtime-update-host-contents`、`etaf-runtime-update-host-geometry` 与[文本](text.md)关于显示属性的说明。

#### Function: etaf-runtime-update-host-contents (runtime updates)

在一次保留 Ebox 发布里替换多个 HOST-REF 的内容。

**参数。** RUNTIME 是已挂载 Runtime。UPDATES 是 proper alist，键是已提交 Host 引用，值是替换字符串或 image 对象，内容契约与 `etaf-runtime-update-host-content` 相同。

**语义。** 所有目标在第一次替换之前校验，所以同时维持几个小内容（文本与帧一起）的调用方每次变化只发布一次，而不是每个节点一次。一次调用是一次发布，修订号前进一次。

**返回。** 提交后返回 t。

**错误。** RUNTIME 未挂载、UPDATES 不是期望形状的 proper alist（`"Invalid Host content updates"`）、某个键不是已提交 Host（消息 `"Unknown committed Host"`）、某个值既不是字符串也不是 image（`"Invalid Host content updates"`）时，在发生任何改动之前 `error→ etaf-runtime-error`。节点不能持有内容的目标会 `"Host cannot hold content"`；由于所有目标在第一次替换之前都已解析，此时批里其它 Host 尚未改变。

**示例。** 一起变化的状态行与预览。

```elisp
(etaf-runtime-update-host-contents
 runtime
 '((status . "connected") (preview . thumbnail)))
```

**参见。** `etaf-runtime-update-host-content`。

#### Function: etaf-runtime-update-host-geometry (runtime host-ref &rest geometry)

设置已挂载 RUNTIME 里 HOST-REF 的位置、尺寸或图层属性。

**参数。** RUNTIME 是已挂载 Runtime。HOST-REF 是已提交 Host 引用。GEOMETRY 是样式属性 plist，例如 `:left`、`:top`、`:width`、`:height` 和 `:z-index`。

**语义。** 只重新布局该 Host 的重排边界并重写它变化的缓冲区区域，更新通过 Ebox 发布一次。这是对调用方已更新的受控状态的显示投影：它不改变组件 props，也不实现窗口策略。与内容一样，View 仍是权威，保留值必须与 View 将要渲染的内容一致。

**返回。** 提交后返回 t。

**错误。** RUNTIME 未挂载、HOST-REF 不是已提交 Host（`"Unknown committed Host"`）、Ebox 拒绝某个属性或值（消息 `"Host geometry update rejected"`，数据给出受影响的引用与底层条件）时，`error→ etaf-runtime-error`。被拒的值不会为那次更新发布新布局，但会留在 Host 上；[恢复](#恢复)一节说明这对后续更新意味着什么。

**示例。** 把拖拽中的面板吸附到它的已提交位置。

```elisp
(etaf-runtime-update-host-geometry runtime 'panel :left '(px 40) :top '(px 0))
```

**参见。** `etaf-runtime-update-host-geometries` 与[样式属性参考](style-properties.md)中可接受的值。

#### Function: etaf-runtime-update-host-geometries (runtime updates)

在一次保留 Ebox 发布里应用多组 HOST-REF/GEOMETRY。

**参数。** RUNTIME 是已挂载 Runtime。UPDATES 是 proper alist，键是已提交 Host 引用，值是几何 plist，属性契约与 `etaf-runtime-update-host-geometry` 相同。

**语义。** 所有被引用的 Host 在批处理开始前解析，接受的更新作为一次缓冲区写入发布，所以移动多个相关 Host 的调用方只付一次发布。一次调用让修订号前进一次。

**返回。** 提交后返回 t。

**错误。** RUNTIME 未挂载、UPDATES 不是引用/plist 对的 proper alist（`"Invalid Host geometry updates"`）、某个键不是已提交 Host（消息 `"Unknown committed Host"`，在任何 Host 变化之前报出）、Ebox 拒绝某个属性或值（消息 `"Host geometry update rejected"`，给出受影响的引用与底层条件）时，`error→ etaf-runtime-error`。批处理中途被拒的值不会回滚它之前已应用的条目；[恢复](#恢复)一节说明该保留值与修订号。

**示例。** 一起移动调色板与它的浮层。

```elisp
(etaf-runtime-update-host-geometries
 runtime
 '((palette . (:top (px 2) :left (px 4)))
   (overlay . (:z-index 10))))
```

**参见。** `etaf-runtime-update-host-geometry`。

### 保留内容的和解

保留更新是显示值，不是应用状态。响应式图、组件 props 与 View 都不变；只有被寻址 Host 的已发布内容或几何与 View 将渲染的不同。调用方的契约是让它们保持一致：View 再次发布该 Host 时，View 是权威。

Host 之后重新渲染出不同的文本或几何时，View 的值替换保留值；重新运行但没有改变输出的 View 表达式会让保留内容留在原地。所以保留更新适合 View 自己并不派生的值——帧、测量、控制器拥有的位置；同时把这些值喂给 View 的调用方应预期 View 的下一次变化会胜出。

## 内省

已挂载 Runtime 可以报告它的已提交贡献：哪些 Host 带事件处理函数、它们提交了哪些声明属性、它们如何嵌套、哪些组件实例还活着。这些读取的都是已提交状态；没有一个会发布、重新布局或排空。

Host 查询看到的是至少带一个非空语义属性（例如 `:ref`、`:role` 或 `:keys`）的 Host——也就是按引用登记的那些 Host。只有样式的 Host 不登记、不出现。

#### Function: etaf-runtime-handler-entries (runtime)

返回 RUNTIME 的已提交处理函数贡献条目。

**参数。** RUNTIME 是 Runtime 对象。

**语义。** 结果按树序列出提交了至少一个事件处理函数的 Host，每条把 Host 引用与它的处理函数配对为 `(KIND . FUNCTION)` 对，按属性顺序。`:on-*` 值全为 nil 的 Host 不提交处理函数、不出现。这个列表描述已提交的贡献，不是订阅：它在下一次改变处理函数的提交时才变化。

**返回。** `(REF (KIND . FUNCTION) ...)` 条目的列表。

**示例。** 诊断列出哪些 Host 提交了 drag 处理函数。

```elisp
(let ((entry (assq 'canvas (etaf-runtime-handler-entries runtime))))
  (alist-get 'drag (cdr entry)))
```

**参见。** [事件](events.md)与 Behavior 章。

#### Function: etaf-runtime-host-props-entries (runtime)

返回 RUNTIME 的已提交 Host 贡献条目。

**参数。** RUNTIME 是 Runtime 对象。

**语义。** 结果按树序把每个已登记 Host 引用与它的已提交语义属性配对。属性 plist 是副本、Theme 已解析，形式与 `etaf-runtime-host-props-for` 返回的一致，所以调用方可以一次遍历取得整个应用 Host 贡献的快照。

**返回。** `(REF . PROPS)` 条目的列表。

**示例。** 为缺陷报告导出已提交的 Host 树。

```elisp
(etaf-runtime-host-props-entries runtime)
     ⇒ ((shell :ref shell :role application)
        (title :ref title :role heading :font-weight bold))
```

**参见。** `etaf-runtime-host-props-for`。

#### Function: etaf-runtime-host-props-for (runtime host-ref)

返回 RUNTIME 中 HOST-REF 的已提交语义 Host 属性。

**参数。** RUNTIME 是 Runtime 对象。HOST-REF 是一个引用。

**语义。** 每次调用的 plist 主干都是新的，内含值保持 identity，对调用方只读。属性是 Host 已提交的那些，Theme token 已解析为值；之后的几何发布不会替换这份副本里的字段，因为保留几何更新写入 Host 的已发布节点，不写这份记录。未知引用、没有语义属性的 Host、已卸载的 Runtime 都得到 nil。

**返回。** 属性 plist，或 nil。

**示例。** 某个命令检查指针所指 Host 是否 disabled。

```elisp
(plist-get (etaf-runtime-host-props-for runtime host-ref) :disabled)
```

**参见。** `etaf-runtime-host-props-entries` 与 [Host](hosts.md#语义属性)。

#### Function: etaf-runtime-host-ancestries (runtime host-refs)

返回 RUNTIME 中 HOST-REFS 的已提交语义世系。

**参数。** RUNTIME 是 Runtime 对象。HOST-REFS 是引用列表；未知的会被跳过。

**语义。** 结果是哈希表，把每个找到的引用映射到它的世系列表 `(REF PARENT-REF ... ROOT-REF)`，从最近到根、以已登记 Host 链的根结尾。调用方用它做重叠命中测试：查找沿保留的 Host 父链走，所以处在 slot 或组件投影里的引用报告的是它实际提交所在的 Host 链。

**返回。** 引用到世系列表的哈希表；缺失的引用不在表里。

**示例。** 一次命中测试询问一个 Host 是否包住另一个。

```elisp
(let ((table (etaf-runtime-host-ancestries runtime (list outer inner))))
  (memq outer (gethash inner table)))
```

**参见。** [Host](hosts.md#host-引用)。

#### Function: etaf-host-ref-row-spans (runtime host-ref)

返回 RUNTIME 中 HOST-REF 已提交的 Ebox `(ROW BEG END)` 行跨度列表。

**参数。** RUNTIME 是已挂载 Runtime 对象。HOST-REF 是已提交的 Host 引用。

**语义。** 查找 HOST-REF 对应的保留 Ebox 节点并返回其已提交的行跨度列表；当 HOST-REF 不存在或尚未布局时返回 nil。`etaf-media` 等原生浮层消费者通过该接口测量可见行与遮挡状态，而不必接触 Runtime 内部槽位。

**返回。** `(ROW BEG END)` 条目列表，或 nil。

#### Function: etaf-runtime-overlay-active-p (&optional runtime)

当 RUNTIME 当前存在活动根 surface 或命名根浮层时返回非 nil。

**参数。** RUNTIME 默认为当前已挂载 Runtime。

**语义。** 当 RUNTIME 当前承载模态 surface 或任意命名根浮层时返回 `t`，否则返回 nil。原生浮层可据此在模态或浮层盖住画布时隐藏或避让硬件表面。

**返回。** `t` 或 nil。

#### Function: etaf-runtime-instances (x)

访问 Runtime 对象 X 的槽 "instances"。

**参数。** X 是 Runtime 对象。其它值 `wrong-type-argument`，数据为 `(etaf-runtime X)`。

**语义。** 这张表把每个活着的组件实例的身份映射到它的实例记录，属于 Runtime 供内省：调用方可以计数存活实例或查找某一个；实例被释放时就从表里移除，所以已卸载 Runtime 的表是空的。记录对调用方不透明；用它们比较或计数，不要当作组件内部的来源。

**返回。** 实例身份到实例记录的哈希表。

**示例。** 一个测试断言和解复用了两个实例。

```elisp
(let ((runtime (etaf-runtime-for-buffer buffer)))
  (hash-table-count (etaf-runtime-instances runtime)))
     ⇒ 2
```

**参见。** [组件](components.md#实例记录)。

## Transient space

#### Function: etaf-transient-space-borrowed-p (window committed-rows)

返回非 nil 表示 transient UI 从 WINDOW 借走了行。

**参数。** WINDOW 是活窗口。COMMITTED-ROWS 是 WINDOW 的调用方上次排版用的 body 高度，整数。

**语义。** minibuffer 与回显区静息时各占一个 body 行；其中一个更高时——活动的补全会话、折行的 prompt 或消息——多出的行从显示窗口借用，显示窗口随之缩小。当且仅当 WINDOW 活着、COMMITTED-ROWS 是整数、WINDOW 的 body 比 COMMITTED-ROWS 矮、且 frame 的 minibuffer window 高于一行时，调用返回非 nil。按 COMMITTED-ROWS 排版的调用方此时可以保持那份布局，而不按被借走的高度重算。变大、承诺值为 nil、没有 minibuffer、窗口变矮但没有 transient UI 都是真实几何，返回 nil，调用方跟随窗口。

**返回。** transient UI 借走 WINDOW 的行时非 nil，否则 nil。

**示例。** 在尺寸变化处理函数里把应用布局状态拟合到窗口，让补全弹窗不缩小应用。

```elisp
(add-hook 'window-size-change-functions
          (lambda (frame)
            (dolist (window (window-list frame))
              (unless (etaf-transient-space-borrowed-p window layout-rows)
                (fit-layout-to-window window)))))
```

**参见。** [视口](viewport.md)章与[滚动](scrolling.md)章：框架自己的 canvas 对同样的借用保持其已提交视口。

## 语义细节

### 保留树

已挂载的 View 是一棵保留树，View 里每个能独立变化的部分都是一个带副作用的段。除根之外有八种段：

| 段 | 保留什么 |
| --- | --- |
| Host | 一个 Ebox 节点及其已提交属性；唯一拥有自己节点的段 |
| fragment | 一组按组发布的兄弟节点 |
| expression | 由表达式计算的属性或文本值；它读过的源变化时重新求值 |
| branch | 条件已选中的分支；切换分支时按身份打补丁子节点 |
| list | 带 key 的列表；行保留节点并移动，保留的 key 更新它的行 |
| row | 带 key 列表中的一项，item 绑定给它的子树 |
| component | 一个组件实例及其输入单元、Scope 与保留输出 |
| slot | 投影进组件 View 的调用方内容，用调用方的 Context 与样式渲染 |

段的各种类与和解规则在 [View](views.md) 里随语法定义；这张表把它们命名出来，好让下面对提交的说明能指称整棵树。

### 一次提交，逐步

缓冲区输出有变化的每个 Runtime，在 render 与 post 阶段之间发生一次提交：

1. 保留段同步出树：顶层节点（单个根节点，或包裹多个根的 column）变化时挂载进 Ebox 挂载。
2. 脏 Ebox 子树在一个批里 flush：重算样式、布局损坏区域，缓冲区区域只重写一次。
3. 已提交修订号 +1，刷新 sticky Host 镜像与行区间（保留 Host 更新与 refit 同样刷新，卸载时清除）。
4. 提交的生命周期钩子在渲染之外运行：mounted 给本次提交中出现的实例，updated 给参与本次提交的实例，unmounted 给被释放的实例。每个钩子运行时 `etaf-current-runtime` 绑定到该 Runtime、渲染关闭，所以钩子可以写状态；钩子错误和别的发布工作一样由排空收集。

排空随后继续 post 阶段；post 阶段写了状态就从头再来，如[响应式系统](reactivity.md#排空)所述。第 2 步之前失败的提交整体回滚，[原子提交](#原子提交)一节说明。

### 代价

- 只移动节点的提交只付损坏区域的布局与绘制；Ebox 保留节点，缓冲区写入是一个批。
- 一次保留内容或几何更新只付一次 Ebox 发布和一次修订号前进，与 View 大小无关。
- 内省函数遍历保留 Host 树或实例表；它们分配新列表或 plist，不发布任何东西。用于诊断与测试，不要逐帧调用。
- 回滚只付失败事务触碰过的状态，而不是整个 View。

## Runtime 扩展与呈现附着

页面翻译等核心扩展通过这组接口观察 Runtime 生命周期、只读查询已提交的 Host 树（无需接触内部段或 Ebox 节点），并以命名归属挂载呈现层，使译文或装饰在应用响应式更新后保持完好、并在 Host 卸载时自动释放。

#### Hook: etaf-runtime-mount-functions

在 `etaf-mount` 完成首次发布之后以单参数 RUNTIME 运行的钩子。

**语义。** 每个观察函数在 `etaf-current-runtime` 绑定到 RUNTIME 且关闭渲染状态时运行，时机位于 `:observer` 安装之后。单个观察函数的错误被隔离，不会中止挂载或影响后续观察函数。

**参见。** `etaf-runtime-after-commit-functions` 与 `etaf-runtime-unmount-functions`。

#### Hook: etaf-runtime-after-commit-functions

已挂载 Runtime 提交了一次应用变更之后以单参数 RUNTIME 运行的钩子。

**语义。** 在 Ebox 完成 flush、已提交修订号前进且组件生命周期钩子执行完毕后运行。首次挂载与纯呈现层 flush 不会触发该钩子，因此更新呈现层的扩展不会造成递归循环。单个观察函数的错误被隔离。

**参见。** `etaf-runtime-mount-functions` 与 `etaf-runtime-set-host-presentations`。

#### Hook: etaf-runtime-after-flush-functions

在 RUNTIME 缓冲区发生非呈现层 Ebox flush 之后以单参数 RUNTIME 运行的钩子。

**语义。** 在 `:overflow scroll` 容器滚动偏移更新、视口 refit 或应用提交写完缓冲区之后运行，让视口优先翻译器等扩展无需直接依赖 Ebox 就能感知容器内部滚动。纯呈现层 flush 不会触发该钩子。单个观察函数的错误被隔离。

**参见。** `etaf-runtime-host-geometries` 与 `etaf-runtime-after-commit-functions`。

#### Hook: etaf-runtime-unmount-functions

已挂载 Runtime 开始卸载时以单参数 RUNTIME 运行的钩子。

**语义。** 在保留树、Host 索引表与缓冲区绑定释放之前运行，便于扩展及时取消异步任务并回收会话状态。单个观察函数的错误被隔离。

**参见。** `etaf-unmount` 与 `etaf-runtime-mount-functions`。

#### Function: etaf-runtime-host-tree (&optional runtime)

把已挂载 RUNTIME 的应用 Host 树以只读数据返回。

**参数。** RUNTIME 默认取活动 Runtime 或当前缓冲区的 Runtime。

**语义。** 仅遍历应用根节点，排除临时 surface 与附着呈现伴生段。每个节点是包含 `:id`（稳定整型 Host ID）、`:ref`、`:tag`、`:text`（应用的权威文本，始终不受呈现层覆盖影响）、`:props`（纯数据语义与样式属性，存在可用点击回调时附带 `:has-on-press`）、`:geometry`（`(:x :y :width :height)` 或 nil）和 `:children` 的 plist。

**返回。** 按文档顺序排列的顶层 Host 节点 plist 列表。

**错误。** RUNTIME 未挂载时抛出 `error→ etaf-runtime-error`。

**参见。** `etaf-runtime-host-geometries`、`etaf-runtime-trigger-host-press` 与 `etaf-runtime-set-host-presentations`。

#### Function: etaf-runtime-host-geometries (runtime host-ids)

返回已挂载 RUNTIME 中整型 HOST-IDS 的实时几何与裁剪可见性。

**参数。** RUNTIME 是已挂载 Runtime；HOST-IDS 是来自 `etaf-runtime-host-tree` 的整型 Host ID 列表。未知或尚未布局的 ID 会被跳过。

**语义。** 无需重走整棵树即可查询每个 Host 当前已布局的边框盒。每条记录为 `(HOST-ID . PLIST)`，含像素单位的 `:x` 与 `:width`、已扣除全部外层 `:overflow scroll` 滚动偏移的根行号 `:y` 与 `:height`、与显示窗口求交后的有效垂直裁剪区间 `:clip-top`/`:clip-bottom`（无裁剪边界时为 nil），以及表示 Host 是否与该区间相交的 `:visible-p`。

**返回。** 按 HOST-IDS 顺序排列的 `(HOST-ID . PLIST)` 关联列表。

**错误。** RUNTIME 未挂载或 HOST-IDS 不是 proper list 时抛出 `error→ etaf-runtime-error`。

**参见。** `etaf-runtime-host-tree` 与 `etaf-runtime-after-flush-functions`。

#### Function: etaf-runtime-trigger-host-press (runtime host-id)

在 RUNTIME 中向已提交整型 HOST-ID 派发一次可用的 `press' 事件。

**参数。** RUNTIME 是已挂载 Runtime；HOST-ID 是来自 `etaf-runtime-host-tree` 的整型 `:id`。

**语义。** 当 HOST-ID 仍存活且带有未禁用的 `:on-press' 回调时，经由 RUNTIME 常规事件批派发 `press'，让翻译或装饰后的控件无需暴露闭包即可触发原 Host 交互。

**返回。** 成功派发返回非 nil，HOST-ID 不存在或无可用点击回调时返回 nil。

**错误。** RUNTIME 未挂载或 HOST-ID 不是整数时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-set-host-presentation (runtime host-id key spec)

为 RUNTIME 中整型 HOST-ID 挂载或更新归属于 KEY 的呈现规格 SPEC。

**参数。** RUNTIME 是已挂载 Runtime；HOST-ID 是来自 `etaf-runtime-host-tree` 的整数；KEY 是非 nil 符号；SPEC 为 nil（清除该 KEY）或含 `:mode`（`decorate`、`override`、`companion-inside`、`companion-after` 或 `companion-beside`）、可选整型 `:priority`（默认 `50`，越小越先渲染）及对应载荷的 plist：`decorate` 接收 `:spans`（`((START . END) . FACE)` 或 `((START . END) :face FACE)` 列表）与/或 `:face`；`override` 接收文本 Host 的 `:text` 或容器 Host 的 `:view`；伴生模式接收继承该 Host 的 Context 与 Theme 的归一化 `:view`。

**语义。** 委托给 `etaf-runtime-set-host-presentations` 处理单个目标。同一 Host 的呈现桶支持多归属方共存：`decorate` 层可无损叠加在权威文本之上，多个伴生层按 `:priority` 升序排列，多个 `override` 层按 `:priority` 堆叠并在顶层撤销时自动回落。

**返回。** HOST-ID 存活且已更新返回非 nil，不存在返回 nil。

**错误。** RUNTIME 未挂载或 KEY/SPEC 非法时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-set-host-presentations (runtime key updates)

在已挂载 RUNTIME 中以一次原子 flush 应用归属于 KEY 的 `(HOST-ID . SPEC)` 呈现更新列表 UPDATES。

**参数。** RUNTIME 是已挂载 Runtime；KEY 是非 nil 符号；UPDATES 是 `(HOST-ID . SPEC)` 组成的 proper list，校验规则同 `etaf-runtime-set-host-presentation`。

**语义。** 所有变更在一次 Ebox 批中生效并递增 `etaf-runtime-revision`，不触发 `etaf-runtime-after-commit-functions`。未知或已卸载的 HOST-ID 会被跳过。同 KEY 同 `:mode` 的重复更新会就地修补伴生段；`decorate` 可与同 KEY 或其它 KEY 的伴生层共存并在应用更新文本后自动保留；容器 `override` 将原应用子节点暂存离屏容器以保留后续响应式修改；伴生模式在和解与重排中维持原布局槽位，并随 Host 卸载自动释放。

**返回。** 实际更新的 Host 数量。

**错误。** RUNTIME 未挂载或 KEY/UPDATES/SPEC 非法时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-clear-presentations (runtime &optional key)

在一次 Ebox flush 中移除已挂载 RUNTIME 的呈现附着并还原原始 Host。

**参数。** RUNTIME 是已挂载 Runtime；可选 KEY 仅清除该符号归属的呈现层，为 nil 时清除全部。

**语义。** 仅释放 KEY 归属的呈现段而不干扰同 Host 上的其余共存归属方，在单个批里于全部归属方移除后还原原 Ebox 节点与权威文本并递增修订号，不触发 `etaf-runtime-after-commit-functions`。

**返回。** 还原的 Host 数量。

**错误。** RUNTIME 未挂载或 KEY 非符号时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

## 扩展、元数据、覆盖层与快捷键层

扩展引擎与外部覆盖工具通过四组可组合原语接入任意已挂载的 Runtime：声明式 Runtime 元数据、命名根级覆盖层、语义 Host 操作与文本偏移命中查询，以及严格位于应用快捷键之下的按优先级排序的扩展快捷键层。

#### Hook: etaf-runtime-meta-change-functions

已挂载 Runtime 的解析后元数据快照变化时以 `(RUNTIME META)` 调用的 abnormal hook。

**语义。** 在调用 `etaf-runtime-set-meta` 或 `:meta` 中任意响应式来源（`etaf-ref`、`etaf-computed` 或零参函数）产出新快照后触发。每个监听函数彼此错误隔离。

#### Hook: etaf-runtime-focus-change-functions

已挂载 Runtime 中逻辑 Host 焦点移动时以 `(RUNTIME PREV-HOST-ID NEXT-HOST-ID)` 调用的 abnormal hook。

**语义。** 焦点在已提交 Host 间切换（或进入/离开焦点，缺失端传 nil）后触发。每个监听函数彼此错误隔离，扩展异常不会破坏键盘导航。

#### Function: etaf-runtime-meta (&optional runtime)

返回已挂载 RUNTIME 解析后元数据 plist 的独立只读副本。

**参数。** RUNTIME 默认取活动 Runtime 或当前缓冲区的 Runtime。

**语义。** 返回通过 `etaf-mount`、`etaf-app-open` 或 `etaf-runtime-set-meta` 提供的 `:meta` 最新快照，常见字段包括 `:app`、`:kind`、`:uri` 与 `:title`；未设置时返回 nil。

**返回。** 独立 plist，或 nil。

**错误。** RUNTIME 未挂载时抛出 `error→ etaf-runtime-error`。

#### Function: etaf-runtime-set-meta (runtime meta)

用 META 替换已挂载 RUNTIME 的元数据声明并返回解析后的快照。

**参数。** RUNTIME 是已挂载 Runtime；META 为 nil 或合法关键字 plist，其值可为静态数据、`etaf-ref`、`etaf-computed` 或零参函数。

**语义。** 释放旧的元数据监听 Scope，若含响应式来源则在新 Scope 中求值并监听变化，每次解析快照变化时通知 `etaf-runtime-meta-change-functions`。

**返回。** 独立解析后的元数据 plist，或 nil。

**错误。** RUNTIME 未挂载或 META 非合法 plist 时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-focus-host (runtime host-id)

将已挂载 RUNTIME 的逻辑键盘焦点移动到整型 HOST-ID。

**参数。** RUNTIME 是已挂载 Runtime；HOST-ID 是来自 `etaf-runtime-host-tree` 的整型 `:id`。

**语义。** 定位已提交 Host 段并在其存活、可聚焦且未禁用时把 Ebox 焦点移到对应节点；焦点变化时触发 `etaf-runtime-focus-change-functions`。

**返回。** 焦点成功移动返回非 nil；HOST-ID 不存在、被禁用或不可聚焦时返回 nil。

**错误。** RUNTIME 未挂载或 HOST-ID 不是整数时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-scroll-host-into-view (runtime host-id &optional align)

滚动 RUNTIME 中外层 `:overflow scroll`/`auto` 容器及显示窗口，使整型 HOST-ID 滚入可视区域。

**参数。** RUNTIME 是已挂载 Runtime；HOST-ID 是整型 `:id`；可选 ALIGN 为 `nearest`（默认）、`top` 或 `center`。

**语义。** 从最内层祖先滚动容器逐级向外调整滚动偏移（并同步显示该缓冲区的活窗口），使 HOST-ID 按 ALIGN 策略进入视野。

**返回。** HOST-ID 存活且已布局返回非 nil，不存在返回 nil。

**错误。** RUNTIME 未挂载、HOST-ID 不是整数或 ALIGN 非法时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-host-text-offset-at (runtime &optional position)

返回已挂载 RUNTIME 中 POSITION 处文本 Host 的字符偏移与活动选区信息，无命中时返回 nil。

**参数。** RUNTIME 是已挂载 Runtime；POSITION 默认为 RUNTIME 缓冲区中的 point。

**语义。** 解析覆盖 POSITION 的最内层已提交文本 Host，并将缓冲区位置映射回该 Host 权威 `:text` 中的字符偏移；若同一文本 Host 上存在激活选区，则一并返回 `:region-start` 与 `:region-end`。

**返回。** 形如 `(:host-id INT :offset INT :text STR :region-start INT-OR-NIL :region-end INT-OR-NIL)` 的 plist，未命中文本 Host 时返回 nil。

**错误。** RUNTIME 未挂载时抛出 `error→ etaf-runtime-error`。

#### Function: etaf-runtime-set-overlay (runtime key view &optional origin)

在已挂载 RUNTIME 中挂载、更新或清除归属于 KEY 的命名根级覆盖层 VIEW。

**参数。** RUNTIME 是已挂载 Runtime；KEY 是标识归属方的非 nil 符号；VIEW 为归一化 View（通常为 `:layer 'root :position 'absolute` 的 `box` 或由其组成的 `fragment`）或 nil（清除 KEY）；可选 ORIGIN 为已提交 Host 引用，指定 VIEW 继承的 Context 与 Theme（默认取根段）。

**语义。** 不同 KEY 的覆盖层互不干扰地共存于应用布局之上；更新既有 KEY 会就地修补其覆盖段。覆盖层变更在呈现层保护内执行，不触发 `etaf-runtime-after-commit-functions` 或 `etaf-runtime-after-flush-functions`，也不会污染 `etaf-runtime-host-tree` 或 `etaf-runtime-inspect-tree`。

**返回。** 发生变更返回非 nil，清除不存在的 KEY 返回 nil。

**错误。** RUNTIME 未挂载或 KEY 不是非 nil 符号时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-clear-overlay (runtime &optional key)

从已挂载 RUNTIME 移除归属于 KEY 的命名根级覆盖层（KEY 为 nil 时移除全部）。

**参数。** RUNTIME 是已挂载 Runtime；可选 KEY 是归属方符号，nil 表示全部。

**语义。** 在单次 Ebox 批中释放匹配的覆盖段，不触发应用提交钩子。

**返回。** 实际移除的覆盖层数量。

**错误。** RUNTIME 未挂载或 KEY 非符号时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-set-key-layer (runtime key entries &optional label priority)

在已挂载 RUNTIME 上注册或替换归属于 KEY 的扩展快捷键层。

**参数。** RUNTIME 是已挂载 Runtime；KEY 是非 nil 符号；ENTRIES 为 `(KEY-SEQ COMMAND LABEL)` 三元组列表（传 nil 则移除该层）；可选 LABEL 为帮助面板中的来源名称；可选 PRIORITY 为整型优先级（默认 `50`，越小越先匹配）。

**语义。** 扩展快捷键层严格在 Host `:keys` 与框架默认键（`Tab`、`ESC`、`?`、`M-g` 与方向键）之后解析；尝试绑定框架保留键会抛出 `etaf-renderer-error`。未被遮蔽的有效绑定会自动出现在 `etaf-help-data` 的 `:kind 'extension` 分组中。

**返回。** 更新成功返回非 nil。

**错误。** RUNTIME 未挂载或 KEY/PRIORITY 非法时抛出 `error→ etaf-runtime-error`；条目格式非法或绑定保留键时抛出 `error→ etaf-renderer-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

#### Function: etaf-runtime-clear-key-layer (runtime &optional key)

从已挂载 RUNTIME 移除归属于 KEY 的扩展快捷键层（KEY 为 nil 时清除全部）。

**参数。** RUNTIME 是已挂载 Runtime；可选 KEY 是符号，nil 表示清除全部扩展层。

**语义。** 立即移除匹配的快捷键层，后续按键派发与 `etaf-help-data` 同步生效。

**返回。** 移除的快捷键层数量。

**错误。** RUNTIME 未挂载或 KEY 非符号时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

## Runtime 内省

开发者工具通过按需只读查询与一个受控响应式绑定写口检视已挂载的 Runtime，既不改动缓存，也不直接触碰 Ebox。

#### Function: etaf-runtime-list ()

按挂载身份升序返回当前全部存活的已挂载 ETAF Runtime 列表。

**语义。** 遍历挂载表，过滤底层缓冲区仍存活的已挂载 Runtime 并按挂载顺序返回。

**返回。** 存活的 Runtime 对象组成的新列表。

**错误。** 无。

**参见。** `etaf-runtime-for-buffer`、`etaf-runtime-inspect-tree`。

#### Function: etaf-runtime-inspect-tree (&optional runtime)

以只读数据返回已挂载 RUNTIME 的统一组件与 Host 树。

**参数。** RUNTIME 默认取活动 Runtime 或当前缓冲区的 Runtime。

**语义。** 遍历已提交保留段树，排除临时 surface 与附着呈现伴生段。组件节点携带 `:kind`（`component`）、`:id`、`:name`、`:key`、`:source-file`、`:render-count`、`:props-summary`、`:root-host-ids` 与 `:children`；Host 节点携带 `:kind`（`host`）、`:id`、`:tag`、`:ref`、`:dom-id`、`:classes`、`:text-preview`、`:presentations`、`:geometry`、`:focusable-p`、`:focused-p`、`:disabled-p`、`:has-press-p` 与 `:children`。

**返回。** 按文档顺序排列的顶层节点 plist 列表。

**错误。** RUNTIME 未挂载时抛出 `error→ etaf-runtime-error`。

**参见。** `etaf-runtime-host-tree`、`etaf-runtime-inspect-host`、`etaf-runtime-inspect-component`。

#### Function: etaf-runtime-host-id-at (runtime &optional position)

返回已挂载 RUNTIME 中 POSITION 处的 `(INNERMOST-HOST-ID ... ROOT-HOST-ID)` 列表，无覆盖时返回 nil。

**参数。** RUNTIME 是已挂载 Runtime；POSITION 默认为 RUNTIME 缓冲区中的 point。

**语义。** 将 POSITION 处绘制的 Ebox 节点反查到已提交应用 Host 祖先链；若命中呈现伴生段，则自动回退到其归属应用 Host。

**返回。** 从最内层到根的整型 Host ID 列表；POSITION 未被任何 Host 覆盖时返回 nil。

**错误。** RUNTIME 未挂载时抛出 `error→ etaf-runtime-error`。

**参见。** `etaf-host-ref-at`、`etaf-runtime-inspect-host`。

#### Function: etaf-runtime-inspect-host (runtime host-id)

返回已挂载 RUNTIME 中整型 HOST-ID 的详细只读检视快照，不存在时返回 nil。

**参数。** RUNTIME 是已挂载 Runtime；HOST-ID 是来自 `etaf-runtime-inspect-tree` 或 `etaf-runtime-host-id-at` 的整型 `:id`。

**语义。** 在不改动缓冲区和缓存的前提下汇总盒模型度量、归属到对应组件的按需 ECSS 层叠来源、逐行精确绘制区间、裁剪可见性、脱敏 props、behavior、呈现附着与焦点标记。

**返回。** HOST-ID 的独立快照 plist，HOST-ID 不存在时返回 nil。

**错误。** RUNTIME 未挂载或 HOST-ID 不是整数时抛出 `error→ etaf-runtime-error`。

**参见。** `etaf-runtime-inspect-tree`、`etaf-runtime-inspect-component`。

#### Function: etaf-runtime-inspect-component (runtime instance-id)

返回已挂载 RUNTIME 中整型组件实例 INSTANCE-ID 的详细只读快照，不存在时返回 nil。

**参数。** RUNTIME 是已挂载 Runtime；INSTANCE-ID 是 `etaf-runtime-inspect-tree` 中 `:kind component` 节点的整型 `:id`。

**语义。** 报告组件名、key、源码文件、定义符号、根 Host ID 列表、渲染次数、props、命名绑定（区分 `ref`、`computed`、`resource`、`data-controller` 与普通值，并给出版本号、订阅与依赖摘要及可编辑标记）、继承的 Context 项与解析后的局部引用。

**返回。** INSTANCE-ID 的独立快照 plist，INSTANCE-ID 不存在或已销毁时返回 nil。

**错误。** RUNTIME 未挂载或 INSTANCE-ID 不是整数时抛出 `error→ etaf-runtime-error`。

**参见。** `etaf-runtime-set-component-binding`、`etaf-runtime-inspect-tree`。

#### Function: etaf-runtime-set-component-binding (runtime instance-id binding-name new-value)

向已挂载 RUNTIME 中组件实例 INSTANCE-ID 的可写 `etaf-ref` 绑定 BINDING-NAME 写入 NEW-VALUE。

**参数。** RUNTIME 是已挂载 Runtime；INSTANCE-ID 是存活的整型组件实例 ID；BINDING-NAME 是已声明的 `:bindings` 符号；NEW-VALUE 是待写入的新值。

**语义。** 定位声明的绑定，在其持有可写 `etaf-ref` 时经由 `etaf-set-value` 写入并走常规响应式提交路径；非 ref 绑定（例如 `etaf-computed`）会被拒绝且不改动状态。

**返回。** 成功返回 t。

**错误。** RUNTIME 未挂载、INSTANCE-ID 或 BINDING-NAME 未知、或绑定不是可写 `etaf-ref` 时抛出 `error→ etaf-runtime-error`；渲染期间调用抛出 `error→ etaf-render-side-effect-error`。

**参见。** `etaf-runtime-inspect-component`、`etaf-set-value`。

#### Function: etaf-runtime-inspect-focus (runtime)

返回已挂载 RUNTIME 的独立焦点、区域与有效键位作用域诊断快照。

**参数。** RUNTIME 是已挂载 Runtime。

**语义。** 汇总当前焦点 Host ID 与引用、原生输入会话状态、当前 `etaf-direction-scheme`、带 tab-index 与 focus-group 元数据的有序焦点停靠点列表、已声明区域及有效 `etaf-help-data` 快照。

**返回。** 包含 `:focused-host-id`、`:focused-host-ref`、`:input-active-p`、`:direction-scheme`、`:stops`、`:regions` 与 `:help` 的独立 plist。

**错误。** RUNTIME 未挂载时抛出 `error→ etaf-runtime-error`。

**参见。** `etaf-focused-host-ref`、`etaf-help-data`。

#### Function: etaf-runtime-commit-summary (runtime)

返回已挂载 RUNTIME 最近一次提交的轻量摘要 plist。

**参数。** RUNTIME 是已挂载 Runtime。

**语义。** 以常数时间直接读取 Runtime 的修订号、最近一次实例变化计数（`:new-instances`、`:updated-instances`、`:retired-instances`）及最近一次 `etaf-runtime-update-report`，不遍历节点树。

**返回。** 包含 `:rev`、`:new-instances`、`:updated-instances`、`:retired-instances` 与 `:update-report` 的独立 plist。

**错误。** RUNTIME 未挂载时抛出 `error→ etaf-runtime-error`。

**参见。** `etaf-runtime-update-report`、`etaf-runtime-after-commit-functions`。

## 错误与恢复

#### Error: etaf-runtime-error

ETAF runtime 错误。

**语义。** Runtime 操作无法完成时抛出该条件：解析不出 Runtime、挂载选项格式错误，或保留更新在发布之前或发布期间失败。用 `condition-case` 捕获；失败的调用不返回值。数据是列表；第一个元素通常是消息字符串，有些消息把出错的值、引用或底层条件放在后面的元素里。

| 消息 | 起因 |
| --- | --- |
| `"ETAF runtime is not mounted"` | flush、保留更新或其它操作需要已挂载 Runtime |
| `"Mount options must be a plist"` | OPTIONS 不是 proper plist |
| `"Unknown mount option"` | `:viewport-width`、`:viewport-height`、`:observer` 之外的选项键 |
| `"Invalid :viewport-width"`、`"Invalid :viewport-height"` | 维度既不是 nil 也不是正数 |
| `"Invalid :observer"` | observer 既不是 nil 也不是函数 |
| `"Unknown committed Host"` | 保留更新命名了不是已提交 Host 的引用 |
| `"Host cannot hold content"` | 内容更新寻址的 Host 节点不是文本节点，例如 Box |
| `"Invalid Host content updates"` | UPDATES 不是「引用对字符串/image」条目的 proper alist |
| `"Invalid Host geometry updates"` | UPDATES 不是「引用对 plist」条目的 proper alist |
| `"Host geometry update rejected"` | Ebox 拒绝了某个几何属性或值；数据给出受影响的引用与底层条件 |

**参见。** 响应式系统的[错误与恢复](reactivity.md#错误与恢复)、View 章的 `etaf-renderer-error`，以及[原子提交](#原子提交)关于失败提交留下什么。

### 恢复

| 失败 | 留下什么 |
| --- | --- |
| 首次发布失败的挂载 | 缓冲区存在、内容是原来的、没有 Runtime；条件向外传播 |
| 对已卸载 Runtime 调 `etaf-unmount` | 调用报错；缓冲区和已释放的 Runtime 不变 |
| 有失败副作用的 flush | 缓冲区保留上一次提交，修订号不前进；失败的工作保持暂停，flush 或下一次排空再次报告该条件 |
| 提交中 pre 或 render 副作用失败 | 整份未提交工作回滚：上一次提交的输出、同样的修订号、保留已写入值的 ref；工作在下一次排空或 flush 重试 |
| post 副作用失败 | 提交保留：缓冲区显示新输出，修订号已前进；条件在排空末尾传播 |
| 被拒的内容更新 | 什么都不变：目标与值在第一次替换之前校验，已提交缓冲区保留其内容 |
| 被拒的几何值 | 调用报错，被拒属性不发布新布局，但被拒值留在 Host 上，所以该 Host 的后续几何更新会持续失败，直到 View 重新渲染它 |
| View 并不渲染的保留值 | 保留值留到 View 为该 Host 渲染出不同文本或几何为止；让 View 与保留值保持一致 |
| 对已卸载 Runtime 的保留更新 | 调用报错；已释放的 Runtime 与缓冲区内容不变 |

Runtime 不保存一份 View 来还原：View 是权威，保留值已漂移的 Host，恢复路线永远是重新发布 View——改变 Host 读的状态，或重新挂载应用。

**参见。** `etaf-mount`、`etaf-runtime-flush` 与 `etaf-runtime-update-host-geometry`。
