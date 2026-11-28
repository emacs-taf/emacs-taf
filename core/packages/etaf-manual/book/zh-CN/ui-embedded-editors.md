# 内嵌原生编辑

`etaf-ui` 还为渲染表面之外的应用自有 buffer 提供一种编辑行为：原生 pane 聊天客户端这类集成复用与目录文本字段相同的 mode 与回调，而 buffer、窗口摆放、草稿与传输都归应用所有。本章定义这份共享行为——minor mode、它的配置、取值查询与 tick 守卫的替换——因为它属于公共接口，尽管它不挂载任何 View。[文本输入](text-input.md)定义布局内的编辑会话，[文本输入控件](ui-text-input-controls.md)定义驱动它的组件，[View](views.md)解释应用自有 buffer 为何能与渲染内容并存。

## 这份行为拥有什么

<!-- index: embedded editor; native pane; empty hint; observer -->

这份行为有意保持很小。它拥有一个空文本提示与一个编辑观察者；它从不拥有窗口、布局、应用草稿、传输确认或任何已渲染的 Ebox 表面，也不为每个键入字符安排渲染。启用 mode 保留 buffer 的文本、主模式、键绑定、undo 历史、point、mark、补全配置与 modified 状态——它在它们旁边增加行为，不替换编辑栈。

空文本提示是 buffer 开头处的一个 overlay，其 after-string 只在文本为空时绘制占位；它不属于文本、选区或 undo 历史，所以读取值或复制 buffer 永远不会包含它。观察者在文本被接受地改变后收到 buffer，且不会收到预热的文本副本：应用只在需要时读取值。观察者错误在编辑之后传播到原生命令，已接受的文本保持可用；观察者不得编辑它正在观察的同一个 buffer。

替换是为异步结果写的。应用同时捕获它期待被取代的文本与 buffer 的字符修改 tick；异步操作完成后带着那个 tick 调用替换，而期间文本已变化的 buffer——包括改动后又被撤销回同一字符串的情况——会让调用返回 nil，而不是覆盖用户更新的编辑。相同的值被接受且不触碰选区、undo 或 modified 状态，变化的值是一次可撤销的替换。

## editor mode

<!-- index: etaf-ui-editor-mode; minor mode; cleanup -->

#### Function: etaf-ui-editor-mode (&optional arg)

在调用方拥有的 UI buffer 中启用或禁用原生编辑行为。

**参数。** ARG 是普通的 minor mode 参数：nil 切换，正数启用，非正数禁用。

**语义。** 启用保留文本、主模式键位、undo、选区与 CAPF。它拥有空提示与编辑观察，不拥有窗口布局或传输：不打开 minibuffer，也不为每个字符安排渲染。禁用只移除它的 overlay 与钩子，绝不动文本。更改主模式或杀死 buffer 也会清理这份行为，所以被释放的 buffer 不会留下观察者。该 mode 的 lighter 为 nil。

**返回。** mode 的新状态，与任何 minor mode 的返回一致。

**示例。**

```elisp
(with-current-buffer (get-buffer-create "*Embedded editor*")
  (text-mode)
  (etaf-ui-editor-mode 1)
  (etaf-ui-editor-configure :placeholder "Write here"))
```

**参见。** `etaf-ui-editor-configure`、`etaf-ui-editor-value`。

## 配置这份行为

<!-- index: etaf-ui-editor-configure; placeholder; change observer -->

#### Function: etaf-ui-editor-configure (&key (placeholder nil placeholder-p) (placeholder-face nil face-p) (on-change nil callback-p))

配置当前编辑器的提示字符串、face 与编辑观察者。

**参数。** PLACEHOLDER 是去掉文本属性后复制的字符串；PLACEHOLDER-FACE 是 face 名或 plist（默认 `shadow`）；ON-CHANGE 是 nil 或接收已编辑 buffer 的函数。传入的关键字替换对应设置，省略的保留当前值；显式 nil 的 ON-CHANGE 解除观察者。PLACEHOLDER 不接受显式 nil，因为提示始终是字符串。

**语义。** 先启用 `etaf-ui-editor-mode`。配置从不改变文本，也从不调用 ON-CHANGE。观察者收到的是 buffer 而不是复制的值，且不得编辑该 buffer：用 `etaf-ui-editor-value` 读文本。观察者错误在编辑之后传播，不擦除草稿。

**返回。** 未指定。

**错误。** 当前 buffer 已死或 mode 未启用时报 `error→ user-error`，消息为 `"Expected a live buffer with etaf-ui-editor-mode enabled"`；占位不是字符串、face 既不是 nil、face 也不是 proper list、或观察者既不是 nil 也不是函数时报 `"Invalid editor placeholder, face or change observer"`。

**示例。**

```elisp
(etaf-ui-editor-configure :placeholder "Write here"
                          :on-change (lambda (editor)
                                       (message "%d characters"
                                                (length (etaf-ui-editor-value editor)))))
```

**参见。** `etaf-ui-editor-value`、`etaf-ui-editor-replace`。

## 读取与替换值

<!-- index: etaf-ui-editor-value; etaf-ui-editor-replace; modification tick -->

#### Function: etaf-ui-editor-value (&optional buffer)

返回 detached、去属性、已 widen 的文本值，不改变编辑状态。

**参数。** BUFFER 默认为当前 buffer，且必须启用编辑行为。

**语义。** 返回的字符串是去掉文本属性的整个 buffer 文本，不受 narrowing 影响。查询不改变任何东西：point、mark、narrowing、modified 状态与 undo 历史都保持原样，返回的字符串归调用方所有。

**返回。** 编辑器文本的一个新字符串。

**错误。** BUFFER 已死或未启用该 mode 时报 `error→ user-error`，消息为 `"Expected a live buffer with etaf-ui-editor-mode enabled"`。

**示例。** `(etaf-ui-editor-value editor)`

**参见。** `etaf-ui-editor-replace`。

#### Function: etaf-ui-editor-replace (buffer text &optional expected-tick)

替换原生编辑器文本，尽量保留 marker，并构成一次可撤销的替换。

**参数。** BUFFER 必须启用编辑行为。TEXT 是替换字符串；EXPECTED-TICK 非 nil 时与 buffer 的 `buffer-chars-modified-tick` 比较。

**语义。** 接受替换时返回 t，包括相同文本。EXPECTED-TICK 非 nil 且与当前 tick 不同时，不做任何改变并返回 nil；改动之后再撤销也会让此前的 tick 过期，因此迟到的异步结果永不覆盖更新的编辑。相同的值不改变任何东西也不发通知。变化的值是一次可撤销的替换，尽量保留原生 marker；其它原生变更钩子照常运行，而这份行为在替换后通知 ON-CHANGE 一次。它从不决定异步结果是否允许替换，也从不拥有草稿：那由应用决定。

**返回。** 接受时返回 t，tick 过期时返回 nil。

**错误。** TEXT 不是字符串或 EXPECTED-TICK 不是整数时报 `error→ user-error`，消息为 `"Expected string text and an optional integer modification tick"`；BUFFER 已死或未启用该 mode 时报 `"Expected a live buffer with etaf-ui-editor-mode enabled"`；从 ON-CHANGE 内重入调用时报 `"Cannot replace editor text from its change observer"`。非法输入与过期 buffer 在任何改变之前报出。

**示例。**

```elisp
(let ((tick (buffer-chars-modified-tick)))
  (send-message (etaf-ui-editor-value buffer))
  (etaf-ui-editor-replace buffer "" tick))
```

**参见。** `etaf-ui-editor-value`、`etaf-ui-editor-configure`。

## 语义细节

<!-- index: replacement internals; read-only buffer; reentrancy guard -->

一次替换是一次编辑，而不是一串可见操作：该行为用 undo 边界圈住它并原子地施加，所以变化的值是一个撤销步骤，组内失败也不会留下半份新文本。替换显式允许 read-only buffer——镜像已发送消息的集成可能写进被锁定的 buffer——而普通原生键入仍遵守 `buffer-read-only`。

该行为自己的通知是双向设防的：替换施加新文本期间它抑制变更通知，编辑落定后只运行观察者一次。因为观察者不得替换同一个编辑器，把编辑镜像回 buffer 的回调必须在通知之外做，通常放在应用自己的命令循环里。空提示在每次被接受的变更后刷新，所以用户清空文本时它会重新出现，键入第一个字符时消失。

## 错误与恢复

- `error→ user-error` 覆盖这份行为的用法错误，各条目已逐条列出；消息点名被违反的期望。过期的 tick 返回 nil 而不是报错，因为迟到的异步结果是普通的竞态而不是编程错误。
- 观察者错误传播到原生命令，但绝不擦除已接受的文本：用户键入的草稿已经在 buffer 里，应用可以自行决定如何恢复。
- 重新配置或禁用这份行为从不编辑文本；禁用、更改主模式或杀死 buffer 都会移除 overlay、钩子与观察者，所以被释放的 buffer 不会再回调应用。
- 被拒绝的替换让一切保持原样——文本、选区、undo 历史、modified 状态——所以调用方可以用新的 tick 重试，无需修复状态。

**参见。** [文本输入](text-input.md)、[UI 组件库总论](ui-overview.md#错误与恢复)。
