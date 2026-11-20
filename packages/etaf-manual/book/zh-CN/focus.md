# 焦点

挂载树里的键盘焦点同一时刻只属于一个 Host，由用户的导航选择，而不是由光标位置决定。它活在挂载上，不在 buffer 文本里：Ebox 记录哪个节点聚焦并为它派生 `focus` 选择器状态，point 则跟随焦点服务于编辑与鼠标语义。本章描述焦点状态、Tab 顺序、焦点组及其位置记忆、限制导航的模态作用域、空间移动、point 与焦点的关系、ETAF 与 Ebox 两层接口，以及焦点变化钩子。[Host](hosts.md#无障碍与焦点)定义 `:tab-index`、`:disabled`、`:focus-group` 与 `:focus-scope` 属性本身；[Action、Behavior 与错误边界](actions-behaviors-and-error-boundaries.md)定义 `etaf-focusable`。

## 焦点属于挂载状态

<!-- index: 焦点; 可聚焦; 派生 focus 状态; 失效焦点 -->

焦点是挂载的一个字段，通过 Ebox 的焦点 API 设置与清除。节点在满足以下条件时可获得焦点：在挂载中存活、可见、未禁用、布局高度非零，并且至少拥有一格没有被 overlay 完全盖住的已绘制格。`:tab-index` 不属于这个判定：它给 Tab 导航排序，但显式 `ebox-focus` 可以聚焦负索引或没有索引的 Host，失去 tab index 的 Host 也保留显式焦点。

Ebox 从挂载的焦点节点派生 `focus` 选择器状态，组件样式与样式表因此能在正好聚焦的那个 Host 上匹配 `&:focus`，`:active` 与 `:focus` 可以独立设样式。焦点不是 buffer 文本位置：移动 point 不移动焦点，清除焦点也不移动 point。

当焦点节点不再可聚焦——被移除、隐藏或禁用——焦点被释放。`ebox-focused-node` 在下次读取时发现这一点，清空挂载的焦点字段并返回 nil，同时挂载记住该节点最后的矩形作为 *anchor*。下一次 Tab 或方向移动从 anchor 继续，而不是从第一个停靠点重新开始，因此在焦点下消失的控件不会把用户送回界面顶部。

## Tab 顺序

<!-- index: Tab 停靠点; Tab 顺序; 循环导航 -->

Tab 导航遍历当前模态作用域的 *Tab 停靠点*：`:tab-index` 是大于等于零的整数且可聚焦的节点。索引小者在前；索引相同保持树序，因此同一区域的控件连续访问，即使区域并排。作用域内的焦点组只占一个入口而不是它的成员，下一节描述。

#### Function: ebox-focus-first (&optional buffer-or-name)

聚焦 BUFFER-OR-NAME 的第一个 Tab 停靠点。

**参数。** BUFFER-OR-NAME 是已挂载的 Ebox buffer；默认为当前 buffer。

**语义。** 当前模态作用域里 tab 序的第一个停靠点获得焦点，不管当前焦点在哪，因此这是「表单开头」入口。point 移到该节点，其滚动祖先把它滚到可见。

**返回。** 获得焦点的节点。

**错误。** 作用域没有停靠点时报 `error→ user-error`，消息 `"No Ebox focus stop"`。

**示例。** `(ebox-focus-first)`

**参见。** `ebox-focus-next`、`ebox-focused-node`。

#### Function: ebox-focus-next (&optional count cycle buffer-or-name)

向前移动焦点 COUNT（默认 1）个 Tab 停靠点；CYCLE 在末尾回绕。

**参数。** COUNT 可以为负以向后移动。CYCLE 非 nil 时两端都回绕；否则越界报错。

**语义。** 移动从当前焦点开始。焦点因其节点不再可聚焦而丢失时，移动改为从 anchor 矩形继续；完全没有焦点时从头开始（负 COUNT 则从末尾）。焦点组算一个停靠点，因此一步 Tab 进入或离开整个组。

**返回。** 新获得焦点的节点。COUNT 为 0 且已有焦点时返回该焦点而不移动。

**错误。** 移动会越界且 CYCLE 为 nil 时报 `error→ user-error`，消息 `"No next Ebox focus stop"`（或 `"previous"`）；作用域为空时报 `"No Ebox focus stop"`。

**示例。** `(ebox-focus-next 1 t)`

**参见。** `ebox-focus-previous`、`ebox-focus-first`、`:tab-index`。

#### Function: ebox-focus-previous (&optional count cycle buffer-or-name)

向后移动焦点 COUNT（默认 1）个 Tab 停靠点；CYCLE 在开头回绕。

**参数。** COUNT 按向后计数，因此负 COUNT 向前移动。CYCLE 回绕。

**语义。** `ebox-focus-next` 的反向版本，anchor 回退与组折叠行为相同。

**返回。** 新获得焦点的节点。

**错误。** 移动会越界且 CYCLE 为 nil 时报 `error→ user-error`，消息 `"No previous Ebox focus stop"`；作用域为空时报 `"No Ebox focus stop"`。

**示例。** `(ebox-focus-previous 2 t)`

**参见。** `ebox-focus-next`、`etaf-focus-previous`。

#### Function: etaf-focus-next (&optional runtime)

聚焦已挂载 RUNTIME 的下一个可见 Host。

**参数。** RUNTIME 默认为活动 Runtime。

**语义。** `ebox-focus-next` 的 ETAF 包装，开启 cycle，因此类 Tab 导航永远不会在界面末尾停住。顺序就是上面描述的 Ebox tab 序；隐藏与禁用的 Host 被 Ebox 的可聚焦判定跳过。

**返回。** 获得焦点的 Ebox 节点。

**错误。** Runtime 未挂载时报 `error→ etaf-runtime-error`；没有停靠点时报 `error→ user-error`，消息 `"No Ebox focus stop"`。

**示例。** `(etaf-focus-next runtime)`

**参见。** `etaf-focus-previous`、`etaf-focus`。

#### Function: etaf-focus-previous (&optional runtime)

聚焦已挂载 RUNTIME 的上一个可见 Host。

**参数。** RUNTIME 默认为活动 Runtime。

**语义。** `etaf-focus-next` 的反向版本，同样循环。

**返回。** 获得焦点的 Ebox 节点。

**错误。** Runtime 未挂载时报 `error→ etaf-runtime-error`；没有停靠点时报 `error→ user-error`，消息 `"No Ebox focus stop"`。

**示例。** `(etaf-focus-previous runtime)`

**参见。** `etaf-focus-next`、`etaf-focus`。

## 焦点组与位置记忆

<!-- index: 焦点组; 组入口; 位置记忆 -->

带 `:focus-group`（`vertical`、`horizontal` 或 `grid`）的容器把它的可聚焦后代变成一个 Tab 停靠点。Tab 从一个选定的成员进入组、再以整个组为单位离开；之后方向键在成员之间移动。工具栏、列表或键盘因此不必每个条目花一次 Tab。

入口成员的选择顺序是：当前持有焦点的成员；本次挂载中该组最近聚焦过的成员；`aria-selected`、`aria-current` 或 `aria-checked` 属性为真的成员；tab 序里的第一个成员。记忆按挂载、按组保存，聚焦任意成员都会更新它，因此回到组里会落在用户离开的位置。

#### Function: ebox-focus-within (node &optional count cycle buffer-or-name)

在 NODE 内部的 Tab 停靠点之间移动焦点。

**参数。** COUNT 为 nil 时聚焦 NODE 内的第一个停靠点；整数相对当前焦点移动；0 查询成员资格。CYCLE 回绕。

**语义。** 没有 COUNT、或当前焦点在 NODE 之外时，选中子树里第一个停靠点（COUNT 为负则选最后一个）。当前焦点在 NODE 内时，整数 COUNT 在它内部的停靠点之间前后移动，并且只在 CYCLE 非 nil 时回绕。COUNT 为 0 不改变任何东西并返回当前焦点，调用者因此可以问焦点是否在子树里。NODE 自己在是停靠点时也参与自己的子树。这次移动不创建持久限制，也不安装任何绑定。

**返回。** 获得焦点的节点。

**错误。** NODE 不存活时报 `error→ user-error`，消息 `"Ebox focus root is not mounted"`；子树没有停靠点时报 `"No Ebox focus stop"`。

**示例。** `(ebox-focus-within sidebar nil t)` 聚焦侧栏里的第一个控件。

**参见。** `etaf-focus-within`、`ebox-focus-edge`、`:focus-group`。

#### Function: etaf-focus-within (runtime host-ref &optional count)

在 RUNTIME 中聚焦 HOST-REF 已提交子树内的一个停靠点。

**参数。** COUNT 为 nil 选第一个停靠点；整数带环绕移动；0 查询当前焦点是否在成员里。

**语义。** `ebox-focus-within` 的 ETAF 包装，开启 cycle。它用 Host 引用寻址子树，因此应用可以把导航命令限制在具名窗格内而不必知道 Ebox 节点。COUNT 为 0 是成员资格查询：焦点在子树里时返回当前聚焦 Host。根或停靠点缺失时报错，且不改变焦点与 point。

**返回。** 获得焦点的 Ebox 节点。

**错误。** Runtime 未挂载时报 `error→ etaf-runtime-error`；Host 未提交、不存活或子树没有停靠点时报 `error→ user-error`。

**示例。** `(etaf-focus-within runtime 'results 1)`

**参见。** `ebox-focus-within`、`etaf-focus`、`etaf-focused-host-ref`。

#### Function: ebox-focus-edge (last &optional buffer-or-name root)

聚焦焦点节点所在组的第一个成员，或 LAST 非 nil 时最后一个。

**参数。** LAST 非 nil 选最后一个成员；nil 选第一个。BUFFER-OR-NAME 选择已挂载缓冲区，默认为当前缓冲区。ROOT 可把候选停靠点与参与导航的焦点组限制在已挂载子树内；nil 使用当前模态作用域。

**语义。** 焦点节点在焦点组内时，组内 tab 序的第一个或最后一个成员获得焦点，Home 与 End 在工具栏或列表里就是这样；不在组内时，同样的选择作用于模态作用域的第一个或最后一个停靠点。焦点组在 ROOT 或当前模态作用域内查找，因此外层焦点组不能把导航带出显式子树。当前焦点位于 ROOT 外时，选择 ROOT 内第一个或最后一个合格停靠点。

**返回。** 获得焦点的节点。

**错误。** 没有停靠点时报 `error→ user-error`，消息 `"No Ebox focus stop"`；ROOT 不属于选中的存活挂载时报同类错误，消息 `"Ebox focus root is not mounted"`。

**示例。** `(ebox-focus-edge t)`

**参见。** `ebox-focus-within`、`ebox-focus-stops`、`:focus-group`。

## 模态作用域

<!-- index: 模态作用域; 焦点作用域; 焦点停靠点 -->

带 `:focus-scope modal` 的节点在可见期间把 Tab、方向导航与 `:keys` 限制在它内部。最内层可见的 modal 节点是当前焦点作用域；没有时作用域是挂载根。对话框或菜单因此能把键盘关在自己里面直到关闭，嵌套对话框也能从父级接管。

#### Function: ebox-focus-scope (&optional buffer-or-name)

返回 BUFFER-OR-NAME 最内层可见的模态焦点作用域。

**参数。** BUFFER-OR-NAME 是已挂载的 Ebox buffer；默认为当前 buffer。

**语义。** 作用域是 `:focus-scope` 为 `modal` 的最内层可见节点；没有这样的节点时返回挂载根。键分发与命令面板读它来留在打开的对话框里。隐藏的 modal 子树不是作用域，因此隐藏对话框会把导航交还给它后面那层。

**返回。** 作用域节点，或挂载根。

**错误。** buffer 没有挂载时报 `error→ user-error`。

**示例。** `(ebox-focus-scope)`

**参见。** `ebox-focus-stops`、`:focus-scope`。

#### Function: ebox-focus-stops (&optional buffer-or-name)

按 tab 序返回 BUFFER-OR-NAME 模态作用域里的每个焦点停靠点。

**参数。** BUFFER-OR-NAME 是已挂载的 Ebox buffer；默认为当前 buffer。

**语义。** 与 Tab 导航不同，这个清单会展开焦点组：每个可聚焦成员都出现，因为命令面板或帮助缓冲想逐个点名控件。顺序是作用域的原始 tab 序——索引在前，同索引按树序——调用者因此可以按 Tab 到达各组的顺序呈现控件。

**返回。** 节点列表。

**错误。** buffer 没有挂载时报 `error→ user-error`。

**示例。** `(mapcar #'ebox-node-id (ebox-focus-stops))`

**参见。** `ebox-focus-scope`、`ebox-focus-within`。

## 方向移动

<!-- index: 焦点方向; 空间导航; grid 焦点组 -->

方向键移动焦点而不是滚动：调用者向 Ebox 询问某个方向上的停靠点，只有那个方向什么都没有时，ETAF 层才去 step separator 或 slider、进入相邻区域或滚动视口。在焦点组内方向按组的朝向解释；在任何组之外或组边缘则变成几何搜索。

#### Function: ebox-focus-direction (direction &optional buffer-or-name root)

朝 DIRECTION（`up`、`down`、`left`、`right` 之一）移动焦点。

**参数。** ROOT 非 nil 时把每个候选停靠点限制在 ROOT 或其后代里，并且焦点组只有位于 ROOT 内才参与。

**语义。** `vertical` 焦点组用上/下在其成员间 step，`horizontal` 组用左/右，`grid` 组移动到该方向上几何最近的成员。组不处理的方向、组边缘、以及不在组内的停靠点都落到空间搜索：在当前节点矩形之外该方向上最近的停靠点，评分是沿轴距离加上两倍的垂直间隙再加一点中心偏移做平局判定。当那个停靠点属于另一个组时，焦点落在该组的入口而不是成员本身。完全没有焦点时，下与右选第一个停靠点，上与左选最后一个。受限搜索在会离开子树时返回 nil 而不是移动，调用者因此能检测边界。这里从不滚动窗口；ETAF 的方向命令只在无法移动时才滚动。

**返回。** 获得焦点的节点；该方向没有停靠点时返回 nil。

**错误。** 传其他方向时报 `error→ wrong-type-argument`，数据为 `(member up down left right)`；buffer 没有挂载时报 `error→ user-error`。

**示例。** `(ebox-focus-direction 'down)`

**参见。** `etaf-direction`、`ebox-focus-next`、`:focus-group`。

## point、焦点与可见性

<!-- index: point 与焦点; 焦点揭示; 聚焦显示悬停内容 -->

聚焦节点会把 point 移到该节点第一个画出的字符，并设置所有显示该 buffer 的窗口的 window point，但不选窗口；需要窗口的应用自己显示它。清除焦点不动 point。之后焦点与 point 保持独立：对话框持有焦点时 point 可以停在另一行，直到某个命令把 point 移出聚焦 Host，此时键层改用 point 处节点作答。发布移动文本时 point 不会被修复——Ebox 的行级跟踪会保留它，见[增量更新与发布](incremental-updates-and-publication.md#写-buffer)。

聚焦还会揭示节点：Ebox 以最小的距离滚动每一层包含它的滚动容器，让列表或可编辑表面随用户 Tab 而滚动。带 `:hover-content` 的焦点 Host 像指针停在它上面一样显示内容，焦点离开时恢复原文。两个效果都不持久：清除焦点不会滚回去。

## 两层接口

<!-- index: 焦点 API; Host 引用; 显式聚焦 -->

Ebox 拥有焦点节点以及上面的所有导航函数。ETAF 加上 Host 引用层，让应用代码用它在别处使用的同一个 `:ref` 聚焦与查询，并把目标缺失或非法时的失败翻译成事件错误词汇。

#### Function: ebox-focus (node &optional buffer-or-name)

聚焦 BUFFER-OR-NAME 中的 NODE，并把 point 移到它的第一个字符。

**参数。** NODE 为 nil 时清除焦点。BUFFER-OR-NAME 默认为当前 buffer。

**语义。** 可聚焦的 NODE 会被揭示、记为该组的记忆、标上派生的 `focus` 状态、显示其悬停内容并获得 point。挂载还把该节点的矩形记作 anchor，供节点以后消失时使用。传 nil 清除焦点，并且只在焦点真正变化时运行焦点变化钩子。

**返回。** NODE；清除时返回 nil。

**错误。** NODE 不存活、不可见、被禁用、没有已绘制格或完全被盖住时报 `error→ user-error`，消息 `"Ebox node cannot receive focus"`；buffer 没有挂载时报 `error→ user-error`。

**示例。** `(ebox-focus button "*Ebox Form*")`

**参见。** `ebox-focused-node`、`etaf-focus`、`ebox-focus-change-functions`。

#### Function: ebox-focused-node (&optional buffer-or-name)

返回 BUFFER-OR-NAME 的焦点节点，或 nil。

**参数。** BUFFER-OR-NAME 是已挂载的 Ebox buffer；默认为当前 buffer。

**语义。** 这是焦点在哪里的唯一事实来源。若记录的节点不再可聚焦，这次读取会清空挂载的焦点字段并返回 nil，因此被移除、隐藏或禁用的控件永远不会留下失效焦点。anchor 会留下来供下一次移动使用。

**返回。** 焦点节点，或 nil。

**错误。** 无；未挂载的 buffer 返回 nil。

**示例。** `(ebox-focused-node)`

**参见。** `ebox-focus`、`etaf-focused-host-ref`。

#### Function: etaf-focus (&optional runtime host-ref)

把焦点移到已挂载 RUNTIME 中的 HOST-REF，并把 point 移到它的位置。

**参数。** HOST-REF 是应用引用。不给它时选择 Runtime 的第一个合格 Tab 停靠点。

**语义。** 显式形式可以聚焦 tab index 为负或没有 tab index 的已提交 Host，因为 tab index 只给导航排序。隐式形式选择模态作用域的第一个 Tab 停靠点，没有停靠点时保持现有焦点不变。焦点跟随 Host 的生命周期：移除、隐藏与禁用都会释放它，而只改 tab index 不会动存活 Host 上的显式焦点。point 随目标移动，因此点击或直接的键命令能把光标落进聚焦 Host。

**返回。** 获得焦点的 Ebox 节点。

**错误。** 显式目标未提交或不可聚焦时报 `error→ etaf-event-error`；隐式形式找不到停靠点时报 `error→ user-error`；Runtime 未挂载时报 `error→ etaf-runtime-error`。

**示例。** `(etaf-focus runtime 'search-field)`

**参见。** `etaf-focused-host-ref`、`ebox-focus`、`etaf-focus-within`。

#### Function: etaf-focused-host-ref (&optional runtime)

返回已挂载 RUNTIME 当前聚焦的 Host 引用。

**参数。** RUNTIME 默认为活动 Runtime。

**语义。** Ebox 的焦点节点被映射回它的 Host 引用，应用因此可以把焦点与自己写的引用比较。直接调用 Ebox 的焦点操作与 ETAF API 观察的是同一状态；通过局部句柄寻址的 Host 返回该句柄。没有焦点或焦点失效时返回 nil，与 `ebox-focused-node` 的清空一致。

**返回。** Host 引用，或 nil。

**错误。** Runtime 未挂载时报 `error→ etaf-runtime-error`。

**示例。** `(etaf-focused-host-ref runtime)`

**参见。** `etaf-focus`、`ebox-focused-node`、`etaf-local-ref`。

## 焦点变化钩子

<!-- index: 焦点变化钩子; on-focus-enter -->

#### Hook: ebox-focus-change-functions

`ebox-focus` 移动焦点后在已挂载 buffer 里运行的 abnormal hook。

**参数。** 每个函数收到之前的焦点节点（或 nil）与新的焦点节点（清除焦点时为 nil）。

**语义。** 钩子在挂载的 buffer 里运行，每次焦点变化一次，焦点节点没变时不运行。它是所有对焦点作出反应的层的观察点，`:on-focus-enter` 就建在它上面：ETAF 计算上一个焦点与新焦点之间新进入的 Host，并逐个派发回调，最近优先。钩子在焦点操作内部运行，因此它看到的新焦点就是挂载当前的焦点。

**返回。** 不适用；钩子函数的返回值被忽略。

**错误。** 钩子函数里的错误从运行它的焦点操作传播。

**示例。** `(add-hook 'ebox-focus-change-functions (lambda (old new) (message "%S" (and new (ebox-node-id new)))) nil t)`

**参见。** `ebox-focus`、`:on-focus-enter`、[事件](events.md)。

## 错误与恢复

<!-- index: 焦点错误; 失效焦点恢复 -->

焦点失败分三类。无路可走的移动报 `user-error`——空作用域报 `"No Ebox focus stop"`，不循环时越界报 `"No next Ebox focus stop"` 或 `"No previous Ebox focus stop"`，focus-within 的根不存活报 `"Ebox focus root is not mounted"`。不可用的显式目标不同：`ebox-focus` 报 `"Ebox node cannot receive focus"`，`etaf-focus` 把未提交的 Host 引用翻译成 `etaf-event-error`，应用代码因此能捕获自己的寻址错误。方向值非法是类型错误：`wrong-type-argument`，数据为 `(member up down left right)`。

树变化的地方恢复是自动的。被移除、隐藏或禁用聚焦控件会在下次读取时释放焦点而不是留下悬空节点，下一次移动从丢失节点的矩形继续，导航因此留在用户原处附近。没有焦点是正常状态：`etaf-focused-host-ref` 与 `ebox-focused-node` 返回 nil，键层退回到 point。
