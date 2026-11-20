# 主体与适配器

选择器匹配的是*主体*（subject）：一个带类型、ID、类、属性、状态与树中位置的节点。[选择器](selectors.md)定义读取这些事实的语言；本章定义承载它们的对象。提供主体有两种方式。简单调用方用 `ecss-subject-create` 建立主体、用 `ecss-subject-set-children` 连接它们；已经拥有自己节点类型的宿主用 `ecss-subject-adapter-create` 做适配，树仍归宿主所有，ECSS 通过七个回调读取它。每个选择器查询与[样式表接口](ecss-stylesheets-and-scopes.md)都接受这两种形式：要么一个内建主体，要么一个宿主节点加它的适配器。

## 模型

<!-- index: 主体; subject 字段; 树链接; 适配器; 宿主节点; 边界复制 -->

主体携带七个事实，匹配器不读其它东西。类型与 ID 标识它，类与状态是 token 列表，属性是 alist，父与子把它放进一棵树。这七个事实就是[选择器](selectors.md)定义的那七个；这里关心的是每个事实从哪里来。每个主体恰好有一个所有者：内建主体拥有创建时给它的值，适配器把值留在宿主节点上。

内建主体是一条可变记录。`ecss-subject-create` 用关键字参数填充它并脱开调用方的数据，访问器再把字段读回来。父与子字段是「只设一次」的例外：程序运行期间树链接会变化，而改变它们的接口是 `ecss-subject-set-children`。主体的身份就是对象本身，因此树关系与 scope 成员资格都按同一性而不是字段来比较主体。

适配器描述如何读取宿主自己的节点。它持有七个回调，自身不含数据：

| 回调 | 返回 |
| --- | --- |
| `type` | 节点的类型，与类型选择器比较。 |
| `id` | 节点的 ID，或 nil。 |
| `classes` | 类 token 的列表。 |
| `attributes` | 属性 alist。 |
| `states` | 状态 token 的列表。 |
| `parent` | 节点的父，根节点返回 nil。 |
| `children` | 节点有序的子列表。 |

引擎只通过父与子回调遍历宿主树，所以宿主保留自己的表示法：它从不复制节点、不把节点包成主体，也不必改自己的类型。代价是匹配时读到的每个事实都是一次回调调用，而且在一次匹配或查询运行期间，回调必须对同一位置持续返回同一批对象。

## 建立主体

`ecss-subject-create` 是为愿意用 ECSS 自己的主体类型建树的人提供的构造器。它用关键字接收七个事实并返回一个主体；一次调用里同时给出 children 与 parent，就能直接建出一棵树。

#### Function: ecss-subject-create (&key type id classes attributes states parent children)

创建一个通用 subject。

**参数。** TYPE 与 ID 标识主体，可以是任意值。CLASSES 与 STATES 是 token 列表，ATTRIBUTES 是 alist。PARENT 是已有主体或 nil。CHILDREN 是已有主体的列表，或 nil。

**语义。** 五个数据字段会用深拷贝脱开调用方的对象，因此之后原地修改传入的字符串与列表都不会改变该主体。链接在数据之后建立：先把该主体的 CHILDREN 原样设好，再在 PARENT 非 nil 时把它追加到 PARENT 当前的 children 末尾。两个链接参数不必一致——传 PARENT 才让新主体从树上可达，传 CHILDREN 才给它一棵子树。除此之外不做校验：CLASSES 与 STATES 期望是 token 列表、ATTRIBUTES 期望是 alist，但 ECSS 照存传入值，只在匹配时才解释它们。

**返回。** 新建的主体。

**错误。** PARENT 既不是 nil 也不是主体，或 CHILDREN 的某个元素不是主体时 `error→ wrong-type-argument`，数据指名主体谓词与出错的值。

**示例。**

```elisp
(let* ((label (ecss-subject-create :type "span" :classes '("label")))
       (button (ecss-subject-create :type "button" :id "save"
                                    :children (list label))))
  (list (and (ecss-selector-match-p "button > span.label" label) t)
        (eq (ecss-subject-parent label) button)))
     ⇒ (t t)
```

**参见。** `ecss-subject-set-children`、`ecss-subject-adapter-create`、`ecss-selector-match-p`。

## 读取主体

每个字段都有一个访问器。访问器读取主体存下的字段；它们不是 setter，也不限于某一个字段，因此内建主体默认适配器的回调正是它们。读一个字段只花一次槽位访问，这就是内建主体匹配起来便宜的原因。

#### Function: ecss-subject-type (x)

返回主体 X 的类型字段。

**语义。** 该值是 `ecss-subject-create` 存下的值，创建时已与调用方的原对象脱开。匹配器用 `equal` 把它与类型选择器比较，所以字符串或符号都可用。

**返回。** 存下的类型，或 nil。

**错误。** X 不是主体时 `error→ wrong-type-argument`，数据指名主体类型与 X。

**参见。** `ecss-subject-id`、`ecss-subject-create`。

#### Function: ecss-subject-id (x)

返回主体 X 的 ID 字段。

**语义。** 该值与 `#id` 选择器用 `equal` 比较。属性选择器不读这个字段——普通主体的 ID 不会自动成为 `id` 属性——所以需要 `[id=…]` 的调用方要把 ID 加进属性 alist，需要两者都有的适配器则让两个回调各自返回。

**返回。** 存下的 ID，或 nil。

**错误。** X 不是主体时 `error→ wrong-type-argument`，数据指名主体类型与 X。

**参见。** `ecss-subject-type`、`ecss-subject-attributes`。

#### Function: ecss-subject-classes (x)

返回主体 X 的类 token 列表。

**语义。** 类选择器在其名字是该列表成员时匹配。访问器返回主体自己的列表而非副本，其它数据访问器也是如此；请把它当作只读，需要改元数据时新建主体。

**返回。** 存下的类 token 列表，或 nil。

**错误。** X 不是主体时 `error→ wrong-type-argument`，数据指名主体类型与 X。

**参见。** `ecss-subject-states`、`ecss-subject-attributes`。

#### Function: ecss-subject-attributes (x)

返回主体 X 的属性 alist。

**语义。** 属性选择器读这份 alist，伪类 `:lang` 与 `:dir` 也通过它查找可继承的 `lang` 与 `dir` 条目。这份列表是主体自己的；请当作只读。

**返回。** 存下的属性 alist，或 nil。

**错误。** X 不是主体时 `error→ wrong-type-argument`，数据指名主体类型与 X。

**参见。** `ecss-subject-id`、`ecss-subject-classes`。

#### Function: ecss-subject-states (x)

返回主体 X 的状态 token 列表。

**语义。** 状态伪类在其 token 是该列表成员时匹配。动态计算状态的宿主会在主体对象之外更新状态，或经适配器暴露它们；内建列表是作者特意记录的固定集合。

**返回。** 存下的状态 token 列表，或 nil。

**错误。** X 不是主体时 `error→ wrong-type-argument`，数据指名主体类型与 X。

**参见。** `ecss-subject-classes`、`ecss-subject-parent`。

#### Function: ecss-subject-parent (x)

返回主体 X 的父，或 nil。

**语义。** 该字段由 `ecss-subject-create` 与 `ecss-subject-set-children` 维护。从未被链接的主体、父替换过 children 的主体都没有父；detached 树的顶层主体也没有，这正是 `:root` 伪类所测的。

**返回。** 父主体，或 nil。

**错误。** X 不是主体时 `error→ wrong-type-argument`，数据指名主体类型与 X。

**参见。** `ecss-subject-children`、`ecss-subject-set-children`。

#### Function: ecss-subject-children (x)

返回主体 X 的子列表。

**语义。** 列表按传入顺序保存，是主体自己的列表而非副本；位置伪类与组合子就按这个顺序读取。请把它当作只读，改树用 `ecss-subject-set-children`。

**返回。** 存下的子主体列表，或 nil。

**错误。** X 不是主体时 `error→ wrong-type-argument`，数据指名主体类型与 X。

**参见。** `ecss-subject-parent`、`ecss-subject-set-children`。

## 连接主体

树链接是整体替换，不是原地编辑。`ecss-subject-set-children` 接收完整的新子列表，脱开旧的子、挂上新的子，因此把一个主体移到另一个父下只需一次调用，中间不会留下失效的链接。

#### Function: ecss-subject-set-children (subject children)

替换 SUBJECT 的 CHILDREN 并维护它们的父级链接。

**参数。** SUBJECT 是主体。CHILDREN 是主体的列表；空列表或 nil 清空子节点。

**语义。** 调用先清除当前每个父为 SUBJECT 的子节点的父链接，再存下 CHILDREN 的副本，并对每个新子节点先把它从旧父的子列表里摘除，再把它的父指向 SUBJECT。新旧列表可以任意重叠：用不同顺序再调一次、或传入一个本来另有父的子节点都能正常工作，并让每个子节点恰好只有一条父链接。主体当前 children 之外的既有父链接不归这个函数管，所以改访问器返回的列表仍能破坏树；受支持的路径是这个函数。它也不做环检测，调用方有责任让结果保持为一棵树。

**返回。** SUBJECT。

**错误。** SUBJECT 不是主体，或 CHILDREN 的某个元素不是主体时 `error→ wrong-type-argument`，数据指名主体谓词与出错的值。

**示例。**

```elisp
(let* ((row (ecss-subject-create :type "row"))
       (first (ecss-subject-create :type "cell"))
       (second (ecss-subject-create :type "cell" :parent row)))
  (ecss-subject-set-children row (list first second))
  (list (mapcar #'ecss-subject-type (ecss-subject-children row))
        (eq (ecss-subject-parent second) row)))
     ⇒ (("cell" "cell") t)
```

**参见。** `ecss-subject-create`、`ecss-subject-children`、`ecss-subject-parent`。

## 适配宿主树

已有自己节点类型的宿主完全不建主体。它按字段写七个回调，在需要主体的地方把适配器与自己的节点一起传入。节点类型仍是宿主的私有细节，选择器引擎需要什么事实就向适配器要，包括它用来遍历的父与子链接。

#### Function: ecss-subject-adapter-create (&key type id classes attributes states parent children)

用给定的回调创建 subject 适配器。

**参数。** TYPE、ID、CLASSES、ATTRIBUTES、STATES、PARENT 与 CHILDREN 各接受一个调用方自己的主体并返回命名字段。七个回调全部必填。

**语义。** 七个回调按传入原样存下；创建适配器不会调用其中任何一个，也不复制任何节点。每个回调收到的是宿主自己的对象——调用方作为主体传入的同一对象——结果被直接使用；因此列表类字段的回调必须返回列表，父与子回调必须返回宿主自己的父与子对象，基于同一性的遍历才能工作。一次匹配、查询或计算期间回调可能被调用任意多次，而且每次使用都会重新调用；适配器不持有缓存，ECSS 也不按适配器缓存任何东西。这样的操作进行中，宿主不应改动树以致回调返回值改变。

**返回。** 新适配器。

**错误。** 任一回调不是函数时 `error→ ecss-invalid-subject-adapter`，数据是七个回调值组成的列表；省略的关键字是 nil，而 nil 不是函数，所以缺回调的适配器永远建不出来。回调内部报出的错误原样传播给匹配或查询的调用方。

**示例。**

```elisp
(let* ((adapter (ecss-subject-adapter-create
                 :type (lambda (node) (car node))
                 :id (lambda (node) (cadr node))
                 :classes (lambda (node) (caddr node))
                 :attributes (lambda (node) (nth 3 node))
                 :states (lambda (node) (nth 4 node))
                 :parent (lambda (node) (nth 5 node))
                 :children (lambda (node) (nth 6 node))))
       (root (list "div" "panel" '("app") nil nil nil nil))
       (child (list "span" nil '("label") nil nil root nil)))
  (setcar (nthcdr 6 root) (list child))
  (list (and (ecss-selector-match-p "div.app > span.label" child adapter) t)
        (and (ecss-selector-match-p "div:has(span)" root adapter) t)))
     ⇒ (t t)
```

**参见。** `ecss-subject-create`、`ecss-selector-match-p`。

## 语义细节

<!-- index: 链接维护; 同一性; 回调开销; 快照 -->

创建与连接回答的是不同问题。`ecss-subject-create` 回答「这个主体有哪些字段」，并快照数据字段，使主体从存在那一刻起就稳定。`ecss-subject-set-children` 回答「这个主体位于树的哪里」，它是唯一重写链接的接口；返回列表的访问器是存下状态的只读视图，不是 setter。

链接规则是对称的。一个子节点只能有一个父，两个方向描述同一条边：函数每挂上一个子节点都会先把它从旧父摘除，每脱开一个旧的子节点都会清掉它的父。一次调用内部的顺序是固定的——先清旧链接、再挂新链接——所以用重叠的列表替换 children 是安全的。同一个子节点可以在同一子列表中出现两次，函数不会拒绝；它同样不检测环，因此把某个主体自己的后代传进来会造出一个环，之后遍历会一直跟着它走。

匹配开销取决于主体类型。内建主体每个事实只需一次槽位读取，树遍历走的是已在内存里的 Lisp 列表。适配器每个事实、每个遍历步都要付一次宿主回调，因此回调便宜的宿主开销相当，实时计算字段的宿主则要为每次读取付账。两种形式都不复制树：内建构造器只复制调用方的字段值，适配器则什么都不复制。

当某个事实必须匹配特定对象时，同一性很重要。树链接与 scope 成员资格用 `eq` 比较主体，所以在每次调用都重建包装对象的适配器会让父与兄弟关系失效，即使字段看着都对。宿主应当返回它树里实际持有的那个对象。

## 错误与恢复

<!-- index: 主体类型错误; 适配器错误 -->

被拒绝的调用不留下部分状态：构造失败不返回主体，链接更新失败什么都不改，回调列表不合法不产生适配器。恢复方式是修正参数再调一次。

| 情形 | 信号 |
| --- | --- |
| PARENT 既不是 nil 也不是主体 | `error→ wrong-type-argument`，数据指名主体谓词与该值 |
| `ecss-subject-create` 或 `ecss-subject-set-children` 的 CHILDREN 中有非主体元素 | `error→ wrong-type-argument`，数据指名主体谓词与该值列表 |
| `ecss-subject-set-children` 收到非主体的 SUBJECT | `error→ wrong-type-argument`，数据指名主体谓词与该值 |
| 访问器被用于非主体 | `error→ wrong-type-argument`，数据指名主体类型与该值 |
| 某个字段值的形状不适配读取它的选择器 | 匹配直接失败，或由读取该字段的代码报类型错误；创建不校验字段形状 |
| 适配器回调缺失或不是函数 | `error→ ecss-invalid-subject-adapter`，数据是七个回调值的列表 |
| 适配器回调内部报错 | 该错误原样从匹配、查询或计算传播出来 |
