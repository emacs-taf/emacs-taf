# stylesheet、scope 与作者所有权

schema 集合决定有哪些属性；*stylesheet* 决定它们对哪些主体取什么值。stylesheet 是 ECSS 明确拥有、可变的一面：宿主构建一份，按自己想要的顺序加入规则，声明层叠层，也可以清空或重建它。把一个 stylesheet 挂载成 *scope*，是这些规则到达主体树的方式，而挂载边界就是作者所有权的分界：scope 持有快照、一份可选的可作用主体集合，再无其它。本章定义这些书写对象与挂载。[样式系统总论](style-system.md)把来源、important 与层叠层讲成层叠概念；计算样式的章以这里定义的 stylesheet 与 scope 为输入。

## 模型

<!-- index: stylesheet; 规则; 来源; 层叠层; 挂载的 scope; 作者所有权 -->

一份 stylesheet 拥有三样东西：有序的规则列表、每个来源各一份的层顺序，以及给已加入规则编号的计数器。它没有任何全局成分。两份 stylesheet 彼此不可见；想共享规则的程序把同一份 stylesheet 传给需要它的地方，而不是在进程级表里注册什么。

*规则*是加入一个选择器与一组声明后产生的一份事实：规范化为 AST 的选择器、展开成规范 longhand 的声明、所属来源、所在层、可选的 scope 选择器，以及它在 stylesheet 内的源顺序。规则通过 `ecss-rule-selector` 与 `ecss-rule-scope` 读回；加入、修改或删除规则都在 stylesheet 上做，而不是编辑规则对象。

*来源*是五种层叠来源之一：`ua`、`user`、`author`、`animation` 与 `transition`。多数代码加入 author 规则，`author` 也是默认值。每个来源各有自己的层顺序，因此为 author 规则声明层永远不会扰动 user 或 UA 规则。

*层*在某个来源内部给规则排序。层在声明时、或第一次被某条规则使用时进入该来源的顺序，此后位置固定：后来的声明只能追加新层，永远不能重排已有的层。不属于任何层的规则在层顺序之外，这对层叠有影响，[样式系统总论](style-system.md)有述。

*scope* 把一个 stylesheet 的快照挂载在某个根主体上。scope 持有这份快照、一份可选的可作用主体身份集合，以及一个可选的父 scope 关联。它不拥有主体树、也不复制它：主体与适配器树仍归宿主所有，[主体与适配器](ecss-subjects-and-adapters.md)有述。

## 编写 stylesheet

`ecss-stylesheet-create` 建立空 stylesheet，`ecss-stylesheet-add-rule` 往里追加规则。追加是原子且带校验的：选择器先归一化、声明先经 schema 集合展开、来源先校验，规则才进入 stylesheet。

#### Function: ecss-stylesheet-create ()

创建一个空且独立的 stylesheet。

**语义。** 新 stylesheet 没有规则、任何来源都没有已声明的层，源顺序计数器也从零开始。独立性是重点：对象的一切都活在值里，所以一份 stylesheet 可以在一处构建、交给一个或多个挂载使用，而互不影响。

**返回。** 新的 stylesheet。

**错误。** 无。

**示例。**

```elisp
(ecss-stylesheet-rules (ecss-stylesheet-create))
     ⇒ nil
```

**参见。** `ecss-stylesheet-add-rule`、`ecss-scope-create`。

#### Function: ecss-stylesheet-add-rule (stylesheet schemas selector declarations &key (origin 'author) layer scope)

用 SCHEMAS 把 SELECTOR 与 DECLARATIONS 加入 STYLESHEET。

**参数。** STYLESHEET 是 stylesheet。SCHEMAS 是组合好的 schema 集合。SELECTOR 是选择器字符串或 AST。DECLARATIONS 是属性/值偶数列，属性是规范 ID 或别名。ORIGIN 是五种层叠来源之一，默认 `author`。LAYER 是规则所属的层叠层，nil 表示不在任何层。SCOPE 是可选的限制选择器，把规则限制在匹配它的主体或祖先上。

**语义。** 调用先经选择器引擎归一化 SELECTOR 与 SCOPE、校验 ORIGIN、把 DECLARATIONS 经 SCHEMAS 展开，因此别名会解析成规范 ID、简写会变成规范 longhand，规则才存在。随后规则被追加到 sheet，并编号为当前源顺序加一。LAYER 非 nil 且该来源还不认识它时，层在这里被追加到该来源的顺序末尾；这正是「首次使用等同于声明」。任何失败都发生在追加之前，所以被拒绝的调用既不加入规则也不声明层。返回的规则是脱开的副本；stylesheet 保留自己的那一份。

**返回。** 所加规则的副本。

**错误。** STYLESHEET 不是 stylesheet 时报 `error→ wrong-type-argument` 并指名 stylesheet 谓词，SCHEMAS 不是 schema 集合时指名集合谓词；选择器或 scope 解析失败报 `error→ ecss-invalid-selector`；来源未知报 `error→ ecss-invalid-rule`，数据 `(:origin ORIGIN)`；声明被 schema 拒绝（例如未知属性）报 `error→ ecss-invalid-declaration`。

**示例。**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :impacts (paint))))))
       (sheet (ecss-stylesheet-create)))
  (list (ecss-rule-selector
         (ecss-stylesheet-add-rule sheet schemas "p" '(demo/color "red")))
        (ecss-stylesheet-layers sheet)))
     ⇒ ((:type "p") nil)
```

**参见。** `ecss-stylesheet-rules`、`ecss-stylesheet-declare-layers`、`ecss-scope-create`。

#### Function: ecss-stylesheet-rules (stylesheet)

返回 STYLESHEET 的防御性规则副本。

**语义。** 规则按加入顺序返回，每条都是独立副本，选择器、声明、层与 scope 都已脱开。改动返回的规则或列表都不会改变 stylesheet，之后再查又是新的副本。

**返回。** 规则副本的列表，可以为空。

**错误。** STYLESHEET 不是 stylesheet 时 `error→ wrong-type-argument`，并指名 stylesheet 谓词与该值。

**参见。** `ecss-stylesheet-add-rule`、`ecss-rule-selector`。

## 读取规则

`ecss-stylesheet-add-rule` 或 `ecss-stylesheet-rules` 交出的规则通过访问器暴露选择器事实。声明、来源、层与源顺序属于层叠内部；调用方用这两个访问器检视规则作用于什么，要改规则就去改 stylesheet。

#### Function: ecss-rule-selector (x)

返回规则 X 的归一化选择器。

**语义。** 该值就是选择器引擎匹配用的同一棵选择器 AST，可以再传给 `ecss-selector-match-p`，也可以与 `ecss-selector-parse` 的结果比较。从字符串加入的规则这里报告的是解析后的形式，不是原字符串。

**返回。** 规则的选择器 AST。

**错误。** X 不是规则时 `error→ wrong-type-argument`，并指名规则类型与 X。

**示例。**

```elisp
(ecss-rule-selector
 (ecss-stylesheet-add-rule (ecss-stylesheet-create)
                           (ecss-schema-set-compose
                            (ecss-schema-package-create
                             'demo '((:id demo/color :impacts (paint)))))
                           "div > .x" '(demo/color "v") :scope ".outer"))
     ⇒ (:child (:type "div") (:class "x"))
```

**参见。** `ecss-rule-scope`、`ecss-stylesheet-rules`。

#### Function: ecss-rule-scope (x)

返回规则 X 的 scope 选择器，或 nil。

**语义。** 带 `:scope` 加入的规则携带这个归一化的选择器，把它限制在匹配的主体或祖先上；未加该选项的规则返回 nil。规则的 scope 与 `ecss-scope-create` 挂载的 scope 是两套机制：前者是写进规则的条件，后者是发布规则的挂载。

**返回。** 规则的 scope 选择器 AST，或 nil。

**错误。** X 不是规则时 `error→ wrong-type-argument`，并指名规则类型与 X。

**参见。** `ecss-rule-selector`、`ecss-stylesheet-add-rule`。

## 层

层是声明出来的，不是创建出来的。`ecss-stylesheet-declare-layers` 预先声明某个来源的层顺序；用尚未声明的 `:layer` 加规则时，该层在首次使用时被追加。两种操作都只追加；生效顺序由 `ecss-stylesheet-layers` 报告。

#### Function: ecss-stylesheet-declare-layers (stylesheet layers &optional origin)

为 ORIGIN 把未见过的 LAYERS 追加到 STYLESHEET 并返回其顺序。

**参数。** STYLESHEET 是 stylesheet。LAYERS 是非 nil 层值的 proper list；重复声明同一层是允许的，只加一次。ORIGIN 默认 `author`。

**语义。** LAYERS 中该来源还不认识的每一层都会按参数顺序追加到它的顺序末尾。函数返回调用后的完整顺序，而不只是新加的层，因此调用方可以立即检视生效顺序。已有层永远不会重排，这正是预声明的意义：一次写清完整顺序，后来的规则就能依赖其中任一位置。

**返回。** 调用后该来源层顺序的全新副本。

**错误。** STYLESHEET 不是 stylesheet 时 `error→ wrong-type-argument` 并指名 stylesheet 谓词；LAYERS 不是列表或含 nil 时 `error→ ecss-invalid-rule`，数据 `(:layers LAYERS)`；来源未知时数据 `(:origin ORIGIN)`。

**示例。**

```elisp
(let ((sheet (ecss-stylesheet-create)))
  (list (ecss-stylesheet-declare-layers sheet '(base components))
        (ecss-stylesheet-declare-layers sheet '(components extra))
        (ecss-stylesheet-layers sheet)))
     ⇒ ((base components) (base components extra) (base components extra))
```

**参见。** `ecss-stylesheet-layers`、`ecss-stylesheet-add-rule`。

#### Function: ecss-stylesheet-layers (stylesheet &optional origin)

按声明顺序返回 STYLESHEET 中 ORIGIN 的层。

**语义。** 结果是该来源生效顺序的脱开副本：先声明过的层，再按进入顺序排首次使用的层。各来源彼此独立，所以同一份 stylesheet 对每个有规则或声明的来源报告不同顺序。ORIGIN 默认 `author`。

**返回。** 按顺序排列的层值列表，可以为空。

**错误。** STYLESHEET 不是 stylesheet 时 `error→ wrong-type-argument` 并指名 stylesheet 谓词；来源未知时 `error→ ecss-invalid-rule`，数据 `(:origin ORIGIN)`。

**参见。** `ecss-stylesheet-declare-layers`、`ecss-stylesheet-clear`。

## 清空 stylesheet

#### Function: ecss-stylesheet-clear (stylesheet)

移除 STYLESHEET 中的所有规则与层。

**语义。** 调用清空规则列表、忘掉每个来源的层顺序并把源顺序计数器归零，返回同一份 stylesheet 以便链式调用。它是重建路径：热重载循环可以清空 sheet 再填一批新规则，而已经快照了旧内容的挂载会保留自己的快照，直到建立新 scope。

**返回。** STYLESHEET。

**错误。** STYLESHEET 不是 stylesheet 时 `error→ wrong-type-argument`，并指名 stylesheet 谓词与该值。

**示例。**

```elisp
(let ((sheet (ecss-stylesheet-create)))
  (ecss-stylesheet-declare-layers sheet '(base))
  (ecss-stylesheet-add-rule sheet
                            (ecss-schema-set-compose
                             (ecss-schema-package-create
                              'demo '((:id demo/color :impacts (paint)))))
                            "p" '(demo/color "red") :layer 'base)
  (ecss-stylesheet-clear sheet)
  (list (ecss-stylesheet-rules sheet)
        (ecss-stylesheet-layers sheet)))
     ⇒ (nil nil)
```

**参见。** `ecss-stylesheet-create`、`ecss-scope-create`。

## 挂载 scope

scope 把一份 stylesheet 发布到一棵主体树。`ecss-scope-create` 接收树的根与 stylesheet，快照 stylesheet，并记录这份 sheet 的规则可以作用于哪些主体。快照正是书写与所有权分离的地方：挂载之后改动 stylesheet 不会改变 scope，宿主采用新规则的方式是建立新 scope。

#### Function: ecss-scope-create (root stylesheet &key parent (subjects t))

在 ROOT 挂载 STYLESHEET 的快照，可带 PARENT scope。

**参数。** ROOT 是该 scope 的 `&` 指向的非 nil 主体或宿主节点。STYLESHEET 是 stylesheet。PARENT 是可选关联的 scope。SUBJECTS 为 `t` 时目标不受限，为身份列表时只允许这些主体，为 nil 时一个都不选。

**语义。** stylesheet 在挂载边界被冻结：它的规则、各来源层顺序与源顺序被复制进 scope，此后对源 stylesheet 调用 `ecss-stylesheet-add-rule`、`ecss-stylesheet-declare-layers` 或 `ecss-stylesheet-clear` 只影响后来的挂载。挂载规则里的普通选择器分支指向 ROOT 的严格后代，`&` 与 `:scope` 指向 ROOT 本身；其余遍历与继承语义就是选择器引擎的语义。SUBJECTS 限制哪些主体可以接收该 scope 的规则声明：身份用 `eq` 比较并快照，列入的主体必须仍在 ROOT 树内才可能命中，成员资格也从不限制结构遍历或继承值。`t` 与空列表不同：`t` 是所有后代，nil 是一个都不选。PARENT 只是关联——它记录一份 scope 从属于另一份，并不自动加入或排除主体，所以要把每个生效的 scope 都传给使用它们的计算。

**返回。** 新 scope。

**错误。** ROOT 为 nil 或 STYLESHEET 不是 stylesheet 时 `error→ wrong-type-argument`，数据指名构造函数与 ROOT、STYLESHEET 两个参数；PARENT 既不是 nil 也不是 scope 时数据指名 scope 谓词与 PARENT；SUBJECTS 既不是 `t` 也不是 proper list 时数据指名 list 谓词与 SUBJECTS。

**示例。**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :impacts (paint))))))
       (source (ecss-stylesheet-create))
       (root (ecss-subject-create :type "div"))
       (scope (ecss-scope-create root source)))
  (ecss-stylesheet-add-rule source schemas ".target" '(demo/color "after-mount"))
  (list (length (ecss-stylesheet-rules source))
        (length (ecss-stylesheet-rules (ecss-scope-stylesheet scope)))))
     ⇒ (1 0)
```

**参见。** `ecss-scope-stylesheet`、`ecss-stylesheet-create`、`ecss-subject-create`。

#### Function: ecss-scope-stylesheet (x)

返回 scope X 挂载的快照。

**语义。** 访问器返回该 scope 自己的快照 stylesheet，每次调用都是同一对象；scope 匹配规则时读的就是它，因此通过这个对象加规则或声明层会改变该 scope 生效的内容。请按只读对待：改变挂载的受支持方式是构建好 stylesheet 再建一个新 scope。快照与源 stylesheet 已脱开，所以编辑源永远不会改变已有 scope。

**返回。** 该 scope 的快照 stylesheet。

**错误。** X 不是 scope 时 `error→ wrong-type-argument`，并指名 scope 类型与 X。

**示例。**

```elisp
(let* ((source (ecss-stylesheet-create))
       (scope (ecss-scope-create (ecss-subject-create :type "div") source)))
  (eq (ecss-scope-stylesheet scope)
      (ecss-scope-stylesheet scope)))
     ⇒ t
```

**参见。** `ecss-scope-create`、`ecss-stylesheet-rules`。

## 语义细节

<!-- index: 源顺序; 挂载快照; 成员资格; 来源独立 -->

规则加入只有一种次序。校验、归一化与声明展开都发生在规则被追加之前，所以调用方永远看不到只加了一半的规则，报错也不会留下已声明的层。在一份 stylesheet 内部，源顺序就是加入顺序，从一开始编号；跨 stylesheet 的先后由计算决定，各 sheet 的编号按 scope 传入的顺序展平。

层顺序只追加，且按来源各一份。在任何规则之前声明的层，按声明位置进入该来源的顺序；首次被规则使用的层，在那一刻进入。已有层永不移动，所以预先声明完整顺序的 sheet 无论规则随后怎样到来，层秩都是确定的；什么都不声明的 sheet 也能通过 `ecss-stylesheet-layers` 查到顺序。

挂载是值的边界。scope 读到的一切在创建时冻结：规则、各来源层顺序、成员身份。这正是预览、运行中的应用与热重载循环能各自持有一份书写中 stylesheet 的视图的原因。代价是采用新规则就要建新 scope；从 scope 计算样式的宿主应当重建 scope，而不是改旧的。

快照在关键的层面是浅的：规则作为值复制，选择器与声明随之脱开，但 scope 匹配的主体身份是宿主自己的对象，按 `eq` 比较。这条身份规则是成员列表无需复制树就能工作的原因，也是列入 ROOT 之外的主体仍然无法命中的原因：树中位置决定可达性，列表只收窄目标。

## 错误与恢复

<!-- index: 规则校验; 原子加入; scope 错误 -->

每次拒绝都发生在任何状态改变之前。失败的规则加入让 stylesheet 的规则、层与源顺序完全保持原样；失败的 scope 创建不返回 scope；失败的查询什么都不改。恢复方式是修正出错的值再调一次。

| 情形 | 信号 |
| --- | --- |
| 接受 stylesheet 的操作收到非 stylesheet | `error→ wrong-type-argument`，指名 stylesheet 谓词与该值 |
| SCHEMAS 不是 schema 集合 | `error→ wrong-type-argument`，指名集合谓词与该值 |
| SELECTOR 或 SCOPE 无法解析 | `error→ ecss-invalid-selector`，带解析器数据 |
| DECLARATIONS 含未知属性或非法声明 | `error→ ecss-invalid-declaration`，带出错的属性 |
| ORIGIN 不是 `ua`、`user`、`author`、`animation` 或 `transition` | `error→ ecss-invalid-rule`，数据 `(:origin ORIGIN)` |
| LAYERS 不是列表，或含 nil | `error→ ecss-invalid-rule`，数据 `(:layers LAYERS)` |
| `ecss-scope-create` 的 ROOT 为 nil，或 STYLESHEET 不是 stylesheet | `error→ wrong-type-argument`，指名构造函数与两个参数 |
| PARENT 既不是 nil 也不是 scope | `error→ wrong-type-argument`，指名 scope 谓词与该值 |
| SUBJECTS 既不是 `t` 也不是 proper list | `error→ wrong-type-argument`，指名 list 谓词与该值 |
| 规则访问器收到非规则，或 scope 访问器收到非 scope | `error→ wrong-type-argument`，指名期望类型与该值 |
