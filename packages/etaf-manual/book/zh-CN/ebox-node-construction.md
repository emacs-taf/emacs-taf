# 节点构造

Ebox 可以单独使用：程序建立一棵保留节点树，把它挂载进缓冲区，然后就地修改节点，全程不需要 ETAF、View 或 Component。本部分手册记录这种独立用法。树在这里诞生——`ebox-build` 把紧凑的作者表单变成节点，`ebox-node-create` 用 Lisp 逐个构造节点，`ebox-node-copy` 从节点当前输入复制一棵子树。[挂载与生命周期](ebox-mount-lifecycle.md)一章把这里建好的树挂进缓冲区，[树查询](ebox-tree-queries.md)一章把它读回来；[`.ebox` 文件与预览](ebox-files-and-preview.md)一章从文件读取树，[错误条件](ebox-errors.md)一章汇总 API 会报出的条件。[渲染模型](rendering-model.md)描述把建好的树变成文本的布局与绘制，[样式属性](style-properties.md)定义节点可以携带的样式属性。

## 模型

<!-- index: 保留节点; 节点 tag; 作者属性; detached 节点; 文本节点; 选择器身份 -->

节点是一条保留、可变的记录。它有一个 tag、一份作者属性、零个或多个子节点，以及布局与绘制从这些内容派生出的状态。tag 决定节点是什么：`text` 是显示字符串的叶子，`image` 是显示 prepared 图像的叶子，`box`、`row`、`column`、`flex` 与 `grid` 是拥有子节点、并按[盒与常规流](boxes-and-normal-flow.md)及其后各章描述的方式排列它们的容器。容器拥有子节点；文本节点没有子节点，而出现在子节点位置的字符串会变成一个文本节点。

新树是 detached 的：没有节点有父节点，也没有树有挂载。detached 的树可以被渲染、检视或复制；当它被插入某个父节点或被挂载时，才进入受管状态。一个节点至多只能有一个父节点，所以同一棵子树不能出现在两处——要在第二个位置使用同样的当前内容，靠的就是 `ebox-node-copy`。

作者属性是程序提供的值，其余一切都是派生的。作者属性分三组。样式属性是[样式属性](style-properties.md)为该节点 tag 定义的全部属性，longhand 或简写皆可，外加 `--` 自定义属性；不属于该 tag 域内的属性会在构造时被拒。元信息属性承载身份与结构：

| 元信息属性 | 值与作用 |
| --- | --- |
| `:id` | 供 `#id` 选择器匹配的字符串或符号。 |
| `:key` | 供 `[key=NAME]` 选择器匹配的 token。 |
| `:class` | 类名或类名列表，供 `.name` 选择器匹配。 |
| `:attributes` | 额外的 `[NAME=VALUE]` 选择器属性 alist；符号值会转成其名字。 |
| `:states` | 供 `:state` 选择器匹配的作者选择器状态，符号或字符串；`disabled`、`focus` 与 `active` 是派生状态，不能由作者写入。 |
| `:ecss` | 内联样式规则，语法是[选择器](selectors.md)与[值](values.md)使用的 `(SELECTOR PROPERTY VALUE ...)` 形式。 |
| `:ecss-file` | 一个文件，其规则被读取并当作写在 `:ecss` 里那样安装。 |
| `:ecss-scopes` | 该节点从属的 scope；由 `ebox-style-scope-create` 创建。 |
| `:ecss-scope-roots` | 以该节点为根的 scope。 |
| `:defaults` | 节点的默认声明，以用户代理来源参与层叠。 |
| `:image` | 图像叶子显示的 prepared 图像。 |
| `:data` | 应用希望随节点保留的任意值。 |

交互属性声明节点会响应什么。Ebox 读取 `:help-echo`、`:pointer`、`:hover-style`、`:hover-content`、`:drag-lock-modifier` 与 `:hover-group` 做指针反馈，读取 `:keymap` 做按键绑定，读取 `:tab-index`、`:disabled`、`:focus-group` 与 `:focus-scope` 做焦点，读取 `:swipe` 与 `:scroll` 做手势与滚动；交互部分在实现各行为的章里逐一讲解。私有属性 `:content`、`:layout`、`:display` 与 `:ebox-type` 属于 Ebox 内部：写它们的程序会得到报错，而不是悄悄扰乱布局。

## 用作者表单构建

作者表单是普通 Lisp 数据——头元素是 tag 的列表。`ebox-build` 深度优先地走完它，返回这些节点构成的 detached 树。`.ebox` 文件与字面量树用的就是这种形状；整棵树一次就知道时，优先用它。

#### Function: ebox-build (form)

从作者表单 FORM 构建一棵 detached 节点树。

**参数。** FORM 是字符串、已有节点，或形如 `(TAG PROPERTY VALUE ... CHILD ...)` 的列表，TAG 取 `text`、`box`、`row`、`column`、`flex` 与 `grid` 之一。

**语义。** 每个表单是一个节点。条目从左到右读取：`:width` 这类关键字或 `--` 自定义属性开启一个属性并取下一项作为值；其余条目都是子节点，递归构建。表单里被引用的值会脱一层引号，所以 `:class '(a b)` 与 `:class (a b)` 都命名两个类，字符串子节点则变成文本节点。`text` 表单必须恰好携带一个字符串子节点；`:ecss` 与 `:ecss-file` 只在 Box 表单上被接受，在那里为节点及其子树安装规则。字符串、或已经建好的节点会作为树本身返回，构建器因此可以拼接子树。这里不挂载、不布局：结果是普通的 detached 树，交给下一章。

**返回。** 构建出的树的根节点；FORM 已是节点时返回 FORM 本身。

**错误。** FORM 既不是字符串、节点，也不是良构列表时 `error→ ebox-error` 并附描述——未知 tag、属性缺值、`text` 表单的载荷不是恰好一个字符串、或文本表单上写了 `:ecss`。

**示例。**

```elisp
(let ((ebox-viewport-width 40))
  (ebox-render '(column :width (ch 10)
                        (text "Inbox")
                        (row :item-gap (ch 1) (box "open") (box "done")))))
     ⇒ "Inbox \nopen done "
```

**参见。** `ebox-node-create`、`ebox-text-create`、`ebox-render`。

## 程序化构建

`ebox-node-create` 用程序已经持有的值构造一个节点。树形是算出来的而非写出来的——循环生成行、程序保留引用的节点——或需要作者表单覆盖不到的 `image` tag 节点时，用它。

#### Function: ebox-node-create (tag &optional props children)

用作者属性 PROPS 与子节点 CHILDREN 创建 TAG 的 detached 节点。

**参数。** TAG 是 `box`、`row`、`column`、`flex`、`grid`、`text` 与 `image` 之一。PROPS 是作者属性 plist 或 nil。CHILDREN 是节点或字符串的列表；字符串会变成文本节点。

**语义。** PROPS 按模型的三组拆分：样式属性按 TAG 校验并只编译一次，元信息属性设置节点的身份与 scope，交互属性配置行为。CHILDREN 按序挂上；每个子节点必须 detached，容器的第一个子节点挂上时，容器即成为该子节点的父节点。这样创建的文本节点在 `ebox-node-set-text` 赋予载荷之前不带内容，字符串子节点则一步到位。图像节点的内在尺寸来自它的 prepared 图像，不接受样式属性；把 `ebox-image-prepare` 返回的值作为 `:image` 传入。这里同样不挂载、不布局。

**返回。** 新的 detached 节点。

**错误。** TAG 未知、PROPS 不是偶数长度 plist、样式属性不被 TAG 接受、写了私有属性、交互值超出其域、子节点已有父节点时 `error→ ebox-error`；子节点既不是节点也不是字符串时是类型错误。

**示例。**

```elisp
(let ((column (ebox-node-create 'column nil '("first" "second"))))
  (mapcar #'ebox-node-text-p (ebox-node-children column)))
     ⇒ (t t)
```

**参见。** `ebox-build`、`ebox-text-create`、`ebox-node-copy`。

```elisp :figure 一个 box 带一个 text 子节点
(etaf-view
 (column :width '(ch 40) :item-gap '(lh 0)
   (box :padding '((lh 0) (ch 1))
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
     (text :color (etaf-theme-token :ui-accent "#0969da") "box  :padding 1"))
   (box :padding '((lh 0) (ch 4))
     (box :padding '((lh 0) (ch 1))
          :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
       (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "text  子节点")))))
```

## 复制节点

#### Function: ebox-node-copy (node)

从 NODE 的当前输入返回一棵 detached 深拷贝。

**语义。** 拷贝从 NODE 现在持有的内容重建：当前文本或 prepared 图像、当前作者属性、子节点，递归进行。它与 NODE 不共享任何可变结构，所以之后改动其中一棵不会出现在另一棵里。节点至多只能有一个父节点，因此要在第二个位置使用同样的当前内容就靠拷贝；挂载中子树的一份拷贝是 detached 的，可以作为快照渲染。拷贝保留构造器接受的一切——身份、状态、scope、交互属性，以及图像节点的 prepared 图像本身。

**返回。** 新的 detached 节点。

**错误。** 无；NODE 假定为节点。

**示例。**

```elisp
(let* ((node (ebox-build "before"))
       (copy (ebox-node-copy node)))
  (ebox-node-set-text node "after")
  (ebox-render copy))
     ⇒ "before"
```

**参见。** `ebox-node-create`、`ebox-node-set-props`、`ebox-node-set-text`。

## 条目之间的关系

两个构建器产出同样的节点，差别只在输入风格。`ebox-build` 是数据的入口——`.ebox` 文件、字面量树、从别处收到的表单——它的递归把字符串变成文本节点。`ebox-node-create` 是代码手工组装节点的入口，`ebox-text-create` 是它针对文本的简写。无论从哪边开始，程序之后都可以用 `ebox-node-insert` 长树、用 `ebox-node-put` 或 `ebox-node-set-props` 改属性、移动或移除节点，这些都在[增量更新与发布](incremental-updates-and-publication.md)里。

`ebox-node-copy` 补上剩下两个缺口。它是把同一份内容放到两个父节点下的唯一途径，也是程序不再想改动的子树在原树继续变化时得以保全的方式。拷贝挂载中的子树并渲染拷贝，是独立使用 Ebox 时的快照路线。

## 语义细节

<!-- index: 构造代价; 声明缓存; 用户代理来源 -->

构造是离线的。不碰缓冲区、不排挂载、不查询视口，所以树可以在任何地方建——批处理里、定时器里、缓冲区存在之前。布局从第一次渲染或挂载才开始，因此只有布局才能决定的大小错误——例如按包含块解析的百分比——比属性名与语法错误晚出现，后者构造时就报。

属性校验有缓存。每个不同的 `(tag . style-plist)` 对只编译一次规范声明，之后复用；相等的内联 `:ecss` 规则列表共享同一个编译好的 scope；程序构建许多相似行时只有第一行付出代价。计算样式本身在布局时导出，所以构造不计算颜色或尺寸。

`ebox-node-copy` 的代价等于重建子树：每个节点一个节点，各节点的属性走同一套缓存重新编译。少量节点时很便宜，很多节点时与子树规模成正比；它从不共享树的可变部分——这正是它能安全充当快照的原因。

有两个顺序值得记住。在作者表单里，条目严格从左到右分类为属性与子节点，所以出现在子节点位置的 keyword 会吞掉下一项作为它的值；被引用的值只脱一层引号，需要列表值的表单可以直接写列表，也可以引用一次。表单先是数据，然后才是树：读者提供什么，构建器就看到什么。

## 错误与恢复

构造从不发布半成品树。一次调用要么返回完整的 detached 节点，要么报错；退出路上已经建好的节点被丢弃，树本身不受影响，所以程序修好表单或属性重试即可，不需要清理缓冲区。

| 情形 | 报出 |
| --- | --- |
| FORM 不是字符串、节点或列表，或 tag 未知 | `error→ ebox-error`，并附出错值 |
| 属性缺少值 | `error→ ebox-error "Missing value for"` |
| `text` 表单没有字符串载荷，或有多个子节点 | `error→ ebox-error "Ebox text requires exactly one string payload"` |
| 文本表单上写了 `:ecss` 或 `:ecss-file` | `error→ ebox-error "Ebox :ecss requires a Box form"` |
| PROPS 不是偶数长度 plist | `error→ ebox-error "Properties must be an even plist"` |
| 作者写了私有属性 | `error→ ebox-error "Private Ebox property"` |
| 样式属性不在 tag 域内 | `error→ ebox-error` 并点名 tag 与被拒属性 |
| 交互值超出其域 | `error→ ebox-error` 并点名选项与它要求的形状 |
| 子节点已有父节点 | `error→ ebox-error "Ebox node already has a parent"` |
| 文本节点被给予子节点 | `error→ ebox-error "Ebox text nodes cannot contain children"` |
| 子节点既不是节点也不是字符串 | 类型错误，点名构造器 |
