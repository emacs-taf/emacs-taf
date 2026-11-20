# 树查询

树建成、挂载好之后，程序通过查询把它读回来：谁是根、某个节点有哪些子节点、某个 box 在哪里、某个节点画出了哪些字符、某个缓冲区位置属于哪个节点。大多数查询是纯树导航，对 detached 树与挂载中的树同样可用；位置与区间查询需要布局，缓冲区区间还需要活着的挂载。本章记录全部查询。[节点构造](ebox-node-construction.md)建出节点，[挂载与生命周期](ebox-mount-lifecycle.md)把它们挂起来；[渲染模型](rendering-model.md)定义几何查询所报告的坐标系，[增量更新与发布](incremental-updates-and-publication.md)解释这些值何时变化。

## 树模型

<!-- index: 节点树; 父与子; 文档序; 缓冲区位置; 边框盒 -->

节点在树中的位置由它的父节点与它在该父节点子序中的位置决定。根没有父节点，其它每个节点恰好有一个；文档序就是深度优先、从左到右的遍历顺序。节点知道自己的根、父节点、经父节点知道的兄弟、以及按序的子节点；查询从不改动树，返回的列表是调用者拥有的新副本。

这里有两套坐标系。几何是布局的坐标系：横向像素、纵向 root 行，相对根的边框盒；它只对已布局的节点存在——已挂载，或用 `ebox-render` 渲染过（见[挂载与生命周期](ebox-mount-lifecycle.md)）。缓冲区位置是 Emacs 的坐标系：挂载文本中的字符位置，取决于定位内容的宽度，因此属于某一个具体的挂载。从未布局的节点对几何查询回答 nil；不在活挂载里的节点对缓冲区区间与命中测试回答 nil；只走树的查询——父、子、次序、祖先——两者都不需要。

## 树结构

#### Function: ebox-node-root (node)

返回 NODE 所在树的根。

**语义。** 查询沿父链上溯到顶，所以对 detached 节点返回节点自身。与 `ebox-node-parent` 一起，它让从任意节点（例如 `ebox-node-at` 找到的节点）出发的查询能到达拥有它的整棵树。

**返回。** 根节点。

**错误。** 无。

**参见。** `ebox-node-parent`、`ebox-node-buffer`。

#### Function: ebox-node-buffer (node)

返回显示 NODE 的缓冲区，或 nil。

**语义。** 查询问 NODE 的根由哪个挂载喂给，若该挂载仍活着则返回它的缓冲区。detached 树、渲染过但从未挂载的树、以及挂载释放之后都返回 nil。它回答「这个节点现在在哪里」，供只拿到节点、没拿到缓冲区的代码使用。

**返回。** 缓冲区，或 nil。

**错误。** 无。

**参见。** `ebox-node-root`、`ebox-buffer-mount`。

#### Function: ebox-node-parent (node)

返回 NODE 的父节点；根或 detached 节点返回 nil。

**语义。** 父链是树遍历与祖先测试所走的路。被从树上摘下的节点重新报告 nil，之后到达它的查询把它当作根。

**返回。** 父节点，或 nil。

**错误。** 无。

**参见。** `ebox-node-root`、`ebox-node-children`、`ebox-node-index`。

#### Function: ebox-node-children (node)

返回 NODE 的子节点，新列表。

**语义。** 列表是副本：往里加、从里删、或改动其单元都不影响树。叶子——文本节点或空容器——返回 nil。顺序是文档序，因此结果与布局和绘制使用的顺序一致。

**返回。** 子节点列表。

**错误。** 无。

**参见。** `ebox-node-child`、`ebox-node-child-count`、`ebox-node-walk`。

#### Function: ebox-node-child (node index)

返回 NODE 在 INDEX 处的子节点；INDEX 越界时返回 nil。

**语义。** INDEX 从零开始；负索引与等于或超过子节点数的索引都返回 nil。它是直接到达已知位置的办法，例如手写表单的第二个子节点。

**返回。** 子节点，或 nil。

**错误。** 无。

**参见。** `ebox-node-children`、`ebox-node-child-count`。

#### Function: ebox-node-child-count (node)

返回 NODE 的子节点数。

**语义。** 叶子回答 0。计数直接读保留序列，所以只关心数量时比取 `ebox-node-children` 的长度便宜。

**返回。** 子节点数。

**错误。** 无。

**参见。** `ebox-node-children`、`ebox-node-child`。

#### Function: ebox-node-index (node)

返回 NODE 在其父节点子序中的位置；根返回 0。

**语义。** 索引从零开始，并随结构变化跟随节点：`ebox-node-move` 之后报告新位置，被摘下之后重新报告 0。对已经拿到手的节点，它是 `ebox-node-child` 的逆查询。

**返回。** 索引；根或 detached 节点为 0。

**错误。** 无。

**参见。** `ebox-node-child`、`ebox-node-move`。

#### Function: ebox-node-ancestor-p (ancestor node)

ANCESTOR 是 NODE 本身或它的祖先之一时返回非 nil。

**语义。** 测试包含节点自身，所以「这个 box 是否在那个 panel 里」这类问题中，panel 等于节点本身也算在里面。它从 NODE 沿父链上走，是 overlay 命中测试所做的事在树层面的对应物。

**返回。** 关系成立时非 nil。

**错误。** 无。

**参见。** `ebox-node-parent`、`ebox-node-root`。

#### Function: ebox-node-text-p (node)

NODE 是文本节点时返回非 nil。

**语义。** 测试针对节点的 tag，不需要布局。它把携带可见字符串的叶子与容器、图像节点区分开，也是遍历给访问过的节点贴标签的方式。

**返回。** 文本节点时非 nil。

**错误。** 无。

**参见。** `ebox-node-walk`、`ebox-node-children`。

#### Function: ebox-node-walk (node function)

按文档序对 NODE 及其后代调用 FUNCTION。

**语义。** 遍历是前序的：每个节点先于它的子节点被访问，某个节点的整棵子树先于它的下一个兄弟。FUNCTION 每次调用收到一个节点，返回值被忽略。遍历从 NODE 开始而不是从根开始，所以它访问的是一棵子树；由于按树递归，其深度跟随树的嵌套深度。它是通用的「访问一切」查询——收集 tag、数文本节点、对子树施加测试。

**返回。** nil。

**错误。** 遍历本身不报错；FUNCTION 中的错误原样传播。

**参见。** `ebox-node-children`、`ebox-node-text-p`。

## 几何

#### Function: ebox-node-geometry (node)

把 NODE 的边框盒返回为 plist `(:x :y :width :height)`。

**语义。** plist 按布局坐标报告边框盒：`:x` 与 `:width` 是像素，`:y` 与 `:height` 是 root 行。节点被布局之后它才可用，而布局发生在渲染或挂载时；在那之前、以及从未布局过的树，回答 nil。文本节点作为自己的布局项布局时报告几何，例如 `row` 或 `column` 的直接子节点；行布局由所属 `box` 的匿名段落拥有的文本节点没有自己的边框盒，回答 nil，它画出的区间改由 `ebox-node-bounds` 报告。这些值是对当前布局的快照：改变布局的修改会在下次 flush 时反映出来。

**返回。** plist；NODE 未布局，或文本节点由匿名段落承载时为 nil。

**错误。** 无。

**示例。**

```elisp
(let* ((root (ebox-build '(column :width (px 40)
                                  (box :height (lh 1) "head")
                                  (box :height (lh 2) "body"))))
       (first (ebox-node-child root 0))
       (second (ebox-node-child root 1)))
  (let ((ebox-viewport-width 40))
    (ebox-render root))
  (list (ebox-node-geometry first)
        (ebox-node-geometry second)))
     ⇒ ((:x 0 :y 0 :width 40 :height 1) (:x 0 :y 1 :width 40 :height 2))
```

**参见。** `ebox-node-root-line`、`ebox-node-bounds`。

#### Function: ebox-node-root-line (node)

返回 NODE 边框盒顶部的 root 行；未布局时返回 nil。

**语义。** 这是只取纵向位置，值与 `ebox-node-geometry` 的 `:y` 相同，只是不构造 plist。用它按纵向位置排序节点，或判断两个节点是否从同一行开始。与几何一样，未布局的节点，以及行布局由匿名段落承载的文本节点，回答 nil。

**返回。** root 行号整数，或 nil。

**错误。** 无。

**示例。**

```elisp
(let* ((ebox-viewport-width 40)
       (root (ebox-build '(column :width (px 40)
                                  (box :height (lh 1) "head")
                                  (box :height (lh 2) "body"))))
       (second (ebox-node-child root 1)))
  (ebox-render root)
  (ebox-node-root-line second))
     ⇒ 1
```

**参见。** `ebox-node-geometry`。

## 绘制区间

#### Function: ebox-node-bounds (node &optional all-lines)

返回 NODE 第一条绘制行的缓冲区位置 `(START . END)`。

**参数。** NODE 是 box 或文本节点。ALL-LINES 非 nil 时，END 改为 NODE 最后一条绘制行的行尾。

**语义。** 查询需要活着的挂载：detached 节点、或挂载已释放的节点没有缓冲区位置，回答 nil。文本节点的区间是它第一段被绘制的字符；box 的区间是它第一条边框盒行，从 overlay 未覆盖的第一个单元格到该行上的右缘——可能包含可见字形之后的空白填充。带 ALL-LINES 时，区间覆盖多行 box 的每一条绘制行。第一条行被 overlay 完全盖住的 box 回答 nil，流内 `:visibility hidden` 的 box 仍报告它的空白槽位，隐藏或未放置的 absolute box 没有区间。这些位置对当前文本有效；之后的 flush 会移动它们，所以要在更新后仍可靠的代码存节点、不存位置。

**返回。** `(START . END)` 点对；NODE 在活挂载中不拥有任何单元格时为 nil。

**错误。** 无。

**示例。**

```elisp
(let ((ebox-viewport-width 40))
  (let* ((buffer (ebox-render-to-buffer
                  "*panel*" '(column :width (px 40)
                                     (box :height (lh 1) "head")
                                     (box :height (lh 2) "body long"))))
         (first (ebox-node-child (ebox-buffer-root buffer) 0))
         (text (ebox-node-child first 0)))
    (list (ebox-node-bounds first) (ebox-node-bounds text)
          (ebox-node-bounds first t))))
     ⇒ ((1 . 6) (1 . 5) (1 . 6))
```

**参见。** `ebox-node-position`、`ebox-node-at`、`ebox-node-geometry`。

#### Function: ebox-node-position (node)

返回 NODE 第一个被绘制字符的缓冲区位置，或 nil。

**语义。** 该值就是 `ebox-node-bounds` 的 CAR，因此继承那条查询的全部规则：只在活挂载里存在、指向节点绘制的第一个单元格、文本变化时随之移动。

**返回。** 缓冲区位置，或 nil。

**错误。** 无。

**示例。**

```elisp
(let ((ebox-viewport-width 40))
  (let* ((buffer (ebox-render-to-buffer
                  "*panel*" '(column :width (px 40)
                                     (box :height (lh 1) "head")
                                     (box :height (lh 2) "body long"))))
         (first (ebox-node-child (ebox-buffer-root buffer) 0)))
    (ebox-node-position first)))
     ⇒ 1
```

**参见。** `ebox-node-bounds`、`ebox-node-at`。

#### Function: ebox-node-at (&optional position buffer-or-name)

返回在 BUFFER-OR-NAME 中 POSITION 处被绘制的最内层节点。

**参数。** POSITION 缺省为 point；BUFFER-OR-NAME 缺省为当前缓冲区。

**语义。** 查询把缓冲区位置变回用户以为自己点到的那个节点。文本节点内的位置解析到该文本节点；box 内空白单元格——内边距、槽位、填充——上的位置解析到覆盖它的最内层 box，按绘制顺序进行，因此 overlay 压过被它盖住的东西。它是命中测试背后的判定，也是 `ebox-node-bounds` 的对应物：bounds 把节点变成位置，它把位置变回节点。缓冲区必须持有挂载中的树，答案是当前布局的快照。

**返回。** POSITION 处的最内层节点，或可得的最佳匹配；无物覆盖时为 nil。

**错误。** 缓冲区内的位置无错误；没有挂载的缓冲区返回 nil。

**示例。**

```elisp
(let ((ebox-viewport-width 40))
  (let* ((buffer (ebox-render-to-buffer
                  "*panel*" '(box :height (lh 1) "head")))
         (root (ebox-buffer-root buffer))
         (text (ebox-node-child root 0)))
    (eq (ebox-node-at 2 buffer) text)))
     ⇒ t
```

**参见。** `ebox-node-bounds`、`ebox-node-position`、`ebox-node-text-p`。

## 条目之间的关系

结构查询把任意节点变成程序需要的、关于它位置的事实：它属于哪个根（`ebox-node-root`）、哪个缓冲区在显示它（`ebox-node-buffer`）、父、子、索引与祖先、是否是文本、以及遍历它的子树的走法。它们是纯树读取——不布局、不挂载、不改动——而新鲜子节点列表意味着调用者可以在树变化时继续持有结果。

几何查询为 box 补上布局事实，区间查询把这些事实接到缓冲区上。`ebox-node-geometry` 与 `ebox-node-root-line` 报告 box 在哪里；`ebox-node-bounds` 报告它画了哪些字符，`ebox-node-position` 报告区间的起点，`ebox-node-at` 从位置走回节点。合起来它们支撑常见任务：找到 point 下的 box、把具名节点滚进视野、高亮某一行的文本，或检查一次修改确实移动了它该移动的东西。

## 语义细节

<!-- index: 查询代价; 位置过期; 命中测试 -->

树查询便宜且少分配：父与索引是常数时间，子节点访问穿过保留序列、除请求的节点外不多复制，`ebox-node-walk` 是唯一触碰整棵子树每个节点的查询。它的递归使用 Lisp 栈，所以深度是树的深度。

几何与区间是快照。几何反映最近一次布局；改变它的修改在下次 flush 生效，在那之前读到的是旧值。缓冲区区间与命中测试反映当前文本，而每次更新都可能移动位置：布局挪动行、绘制重写行，某个原本指向节点首字符的位置可能指到别处或指不到任何东西。持有节点、更新后重新查询 bounds 的代码是稳的；跨更新缓存位置的代码不是。

box 区间与文本区间有意不同。文本节点的区间恰好是它画出的字符，止于最后一个字形。box 的第一行区间到达它的右缘，在被拉伸的 box 上会包含空白填充，可能在可见内容之后很远才结束；目标若是「这一行的字符」，查文本节点，或用 box 的 `all-lines`。overlay 规则跟随绘制：被更高 overlay 完全盖住的 box 不拥有可见单元格、也不报告 bounds；而流内隐藏的 box 仍拥有它的空白槽位并报告它。

## 错误与恢复

查询本身不报错；它们对自己无法描述的状态回答 nil。nil 答案意味着以下之一：没有父节点（根）、没有子节点（叶子）、越界（索引）、未布局（几何、root-line）、不在活挂载中（buffer、bounds、position、at）。在本该给节点的地方传 nil 或非节点是类型错误，不是 `ebox-error`，所以调用者应当检查自己持有的节点。

恢复办法是重新读。几何为 nil 时，渲染或挂载这棵树，或等把它布局出来的那次 flush。预期可见的节点 bounds 为 nil 时，检查是否有 overlay 盖住它，或挂载是否已经释放。结构或文本更新之后，重新询问查询，而不是复用存下的位置——节点是稳定的句柄，数字不是。
