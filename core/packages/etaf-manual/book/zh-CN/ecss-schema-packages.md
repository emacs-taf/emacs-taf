# schema 包与组合

ECSS 是通用层叠引擎，不是一套样式词表；本部分手册记录不经 Ebox、不经 ETAF 直接使用它的方式。选择器匹配、层叠顺序与值解析都是通用的；某个属性是否存在、值是什么意思，由使用方决定。宿主用一个或多个 *schema 包* 声明自己的词表，把一个面需要的包组合成一个 *schema 集合*；本部分此后的每个操作都接受这个集合。本章定义这两个对象：包怎样由属性定义构建、包怎样组合，以及组合出的集合上的查询返回什么。[值](values.md)记录 schema 校验的声明；[选择器](selectors.md)与[stylesheet、scope 与作者所有权](ecss-stylesheets-and-scopes.md)建立在同一个集合之上；[样式的实现](style-implementation.md)展示 Ebox 如何用同样的方式声明自己的属性词表。

## 模型

<!-- index: schema 包; schema 集合; 属性定义; 规范标识符; 别名; 组合 -->

ECSS 里的一个*属性*是名字含 `/` 的符号，例如 `demo/color` 或 `ebox/width`。斜杠标记一个带命名空间的规范标识符：引擎从不过问名字的含义，只要求每个属性有一个所有者、一种规范拼写。自定义属性（`--name`）在词表之外，完全不需要 schema，这一点[值](values.md)会讲。

*属性定义*是描述一个属性的数据。它是一个 plist；`:id` 与 `:impacts` 必填，其余可选。

| 键 | 含义 |
| --- | --- |
| `:id` | 规范标识符：名字含 `/` 的符号，且不以 `/` 开头或结尾。 |
| `:impacts` | 一个非空的唯一符号列表，命名该属性变化会影响什么。ECSS 记录这份列表供使用方读取，自己不解释它。 |
| `:initial` | 属性的初值。它在包创建时被归一化并校验一次。 |
| `:inherits` | 真值使该属性默认继承父级的值。 |
| `:normalizer` | 创建时作用于初值的函数；默认是 `identity`。 |
| `:validator` | 判断一个具体值是否可接受的函数；默认接受一切值。 |
| `:equality` | 判断该属性的两个值是否相等的函数；默认是 `equal`。 |
| `:shorthand` | 把该属性的一条声明展开成若干 longhand 声明的函数。 |
| `:aliases` | 备用名，唯一符号的列表。别名只在声明归一化期间存在。 |
| `:projections` | 唯一符号的列表，命名使用方从该属性派生的投影。ECSS 记录这份列表，不解释它。 |
| `:metadata` | 随 schema 保留、并由查找查询返回的任意使用方数据。 |

*schema 包*是一个所有者的不可变注册表：一个身份加一组属性定义，在包创建时校验并复制。*schema 集合*是一个面所用各包组合出的不可变整体。两者创建后都不能修改，也不存在进程级注册表：两个应用，或同一应用的两个面，可以在同一个 Emacs 进程里组合各自的词表，彼此看不见、也不会互相干扰。组合是显式的，因此一次计算看到哪份词表在调用点就可读，而不是由加载顺序累积决定。

别名只是声明边界上的便利。声明可以用别名指名属性，但归一化会在层叠之前把它解析成规范标识符，此后引擎只携带规范标识符。因此别名不能遮蔽或覆盖任何东西；它必须在规范标识符所在的同一命名空间里唯一。

## 定义包

`ecss-schema-package-create` 把一份定义列表变成一个包。校验严格而即时：一条畸形定义、一个重复标识符或一处别名冲突会拒绝整个调用，所以存在的包总是内部一致的。调用方的定义列表被复制而非保留，包创建之后不会再被重新校验。

#### Function: ecss-schema-package-create (package-id definitions)

从 DEFINITIONS 创建不可变的 PACKAGE-ID schema 注册表。

**参数。** PACKAGE-ID 是非 nil、非关键字符号，例如 `demo`。DEFINITIONS 是属性定义的 proper list；每条定义是一个 plist。

**语义。** 每条定义都被校验并复制。标识符必须是规范的；`:impacts` 必须是非空的唯一符号列表；`:aliases` 与 `:projections` 是可选的唯一符号列表；`:normalizer`、`:validator`、`:equality` 与 `:shorthand` 必须各是函数或 nil。定义不能含未知键、重复键，也不能以没有值的键结尾。初值在定义边界上被脱开，用该定义的 normalizer 与 validator 归一化、校验一次，结果被存起来；此后的计算复用这个存好的值，不再运行 normalizer。其余可变的使用方数据也在这个边界上脱开，函数则保持同一性。两条定义不能共享规范标识符，别名不能与同一包里的另一个标识符或别名冲突。零条定义创建空包，定义的顺序被保留。

**返回。** 新建的包。

**错误。** 身份不是非关键字符号时 `error→ ecss-invalid-property-schema`，数据 `(:package-id PACKAGE-ID)`；列表不是 proper list 时 `(:definitions DEFINITIONS)`；元素不是列表时 `(:definition DEFINITION)`；定义畸形时 `(:property ID DEFINITION)`；可调用字段不是函数时 `(:KEY VALUE)`；validator 拒绝初值时 `(:invalid-initial VALUE)`；标识符重复时 `(:duplicate-property ID)`；别名冲突时 `(:collision NAME KIND EXISTING-KIND)`。

**示例。**

```elisp
(ecss-schema-package-property-ids
 (ecss-schema-package-create
  'demo '((:id demo/color :initial "black" :impacts (paint))
          (:id demo/gap :initial 0 :impacts (geometry) :aliases (gap)))))
     ⇒ (demo/color demo/gap)
```

**参见。** `ecss-schema-package-id`、`ecss-schema-package-property-ids`、`ecss-schema-set-compose`。

#### Function: ecss-schema-package-id (package)

返回 PACKAGE 的不可变身份。

**语义。** 身份就是创建包时给出的符号。组合用它识别一个被重复提供的包。

**返回。** 包的身份符号。

**错误。** PACKAGE 不是包时 `error→ wrong-type-argument`，并指名包谓词与该值。

**参见。** `ecss-schema-package-create`、`ecss-schema-set-package-ids`。

#### Function: ecss-schema-package-property-ids (package)

返回 PACKAGE 拥有的规范属性标识符。

**语义。** 标识符按定义顺序返回，即创建时给出定义的顺序。返回的列表是新的：改动它不影响包。

**返回。** 规范标识符符号的列表，可以为空。

**错误。** PACKAGE 不是包时 `error→ wrong-type-argument`，并指名包谓词与该值。

**参见。** `ecss-schema-package-create`、`ecss-schema-set-property-ids`。

## 组合 schema 集合

一个面很少拥有它接受的全部属性。组合把若干所有者的包合成一个集合，此后的 `ecss-stylesheet-add-rule`、`ecss-expand-declarations` 与 `ecss-compute-style` 收到的 schema 参数就是它。组合是全有或全无：任何包与累积出的集合冲突，调用就报错，各输入包保持原样。

#### Function: ecss-schema-set-compose (&rest packages)

把不可变的 PACKAGES 组合成一个原子 schema 集合。

**参数。** PACKAGES 是零个或多个 schema 包。零个包产生空集合，它仍能回答每个查询。

**语义。** 包从左到右应用。同一个包只能出现一次；包与包之间，新包的规范标识符或别名不能与集合里已有的规范标识符或别名冲突，任一方向都不行。第一处冲突拒绝整次组合，并让每个输入包保持原样。组合出的集合保留各包拥有的同一批不可变 schema，而不是复制它们；只有查找索引是新建的。包的组合顺序、以及每个包内的定义顺序都被保留。

**返回。** 新的 schema 集合。

**错误。** 某个参数不是包时 `error→ wrong-type-argument`，并指名包谓词与该值；包重复时 `error→ ecss-invalid-property-schema`，数据 `(:duplicate-package PACKAGE-ID)`；标识符或别名冲突时数据 `(:collision NAME KIND EXISTING-KIND)`。

**示例。**

```elisp
(ecss-schema-set-property-ids
 (ecss-schema-set-compose
  (ecss-schema-package-create
   'demo '((:id demo/color :impacts (paint)) (:id demo/gap :impacts (geometry))))
  (ecss-schema-package-create
   'other '((:id other/size :impacts (geometry))))))
     ⇒ (demo/color demo/gap other/size)
```

**参见。** `ecss-schema-package-create`、`ecss-schema-set-canonical-id`、`ecss-schema-set-property`。

#### Function: ecss-schema-set-package-ids (schemas)

返回组合进 SCHEMAS 的包身份。

**语义。** 身份按传给 `ecss-schema-set-compose` 的顺序返回。返回的列表是新的。

**返回。** 包身份符号的列表，可以为空。

**错误。** SCHEMAS 不是 schema 集合时 `error→ wrong-type-argument`，并指名集合谓词与该值。

**参见。** `ecss-schema-set-compose`、`ecss-schema-set-property-ids`。

#### Function: ecss-schema-set-property-ids (schemas)

按注册顺序返回 SCHEMAS 中的属性标识符。

**语义。** 标识符逐个包返回，包内按定义顺序，因此顺序恰好是组合各包被创建与传入的顺序。返回的列表是新的。

**返回。** 规范标识符符号的列表，可以为空。

**错误。** SCHEMAS 不是 schema 集合时 `error→ wrong-type-argument`，并指名集合谓词与该值。

**参见。** `ecss-schema-package-property-ids`、`ecss-schema-set-compose`。

## 在 schema 集合中查找属性

查找查询把名字解析成标识符，并交出 schema 事实。它们是通过集合读取 schema 的唯一途径，各自返回脱开的数据：调用方可以改动收到的内容，而不影响集合或任何使用它的计算。

#### Function: ecss-schema-set-canonical-id (schemas name)

返回 NAME 在 SCHEMAS 中的规范属性标识符，未知则返回 nil。

**语义。** NAME 可以是规范标识符或精确别名。查找按同一性比较符号；它不折叠大小写、不把字符串强转成符号，也不接受只是看起来像标识符的名字。结果就是声明归一化与层叠使用的规范标识符，调用方用它回答一个名字指代哪个属性。

**返回。** 规范标识符符号；NAME 在集合里没有对应属性时返回 nil。

**错误。** SCHEMAS 不是 schema 集合时 `error→ wrong-type-argument`，并指名集合谓词与该值。

**示例。**

```elisp
(let ((schemas (ecss-schema-set-compose
                (ecss-schema-package-create
                 'demo '((:id demo/gap :impacts (geometry) :aliases (gap)))))))
  (list (ecss-schema-set-canonical-id schemas 'gap)
        (ecss-schema-set-canonical-id schemas 'demo/gap)
        (ecss-schema-set-canonical-id schemas 'nope)))
     ⇒ (demo/gap demo/gap nil)
```

**参见。** `ecss-schema-set-property`、`ecss-schema-set-property-metadata`、`ecss-expand-declarations`。

#### Function: ecss-schema-set-property (schemas id)

返回 SCHEMAS 中 ID 或别名的防御性属性 schema 副本。

**语义。** ID 可以是规范标识符或精确别名。返回的副本携带 schema 的事实——标识符、初值、继承标志、各函数、别名、impacts、projections 与元数据——其中每个可变部分都与集合脱开，函数保持同一性。因此改动副本不会扰动集合，两次查找返回相等的副本。自定义属性没有 schema，即使声明可以使用它们，这里也返回 nil。

**返回。** 属性 schema 副本；ID 在集合里没有对应属性时返回 nil。

**错误。** SCHEMAS 不是 schema 集合时 `error→ wrong-type-argument`，并指名集合谓词与该值。

**参见。** `ecss-schema-set-canonical-id`、`ecss-schema-set-property-metadata`。

#### Function: ecss-schema-set-property-metadata (schemas id)

返回 SCHEMAS 中 ID 的脱开元数据。

**语义。** ID 可以是规范标识符或精确别名。只有元数据被复制出来；需要其余 schema 事实的调用方用 `ecss-schema-set-property`。定义里没有元数据的属性返回 nil，未知名字也返回 nil。

**返回。** 属性的元数据，已脱开；否则 nil。

**错误。** SCHEMAS 不是 schema 集合时 `error→ wrong-type-argument`，并指名集合谓词与该值。

**参见。** `ecss-schema-set-property`。

## 语义细节

<!-- index: 即时校验; 冲突; 防御性副本; 注册顺序 -->

校验即时发生，且每条定义恰好一次。`ecss-schema-package-create` 是唯一检查定义的地方，组合只检查身份与别名索引，不重新检查 schema。一个包存在就说明它创建时合法、此后不能被改动，所以后续操作无需复查即可把它的视为稳定事实。

`:initial` 跨越边界两次。创建时，ECSS 先脱开调用方的对象，再对脱开后的副本运行 normalizer，然后校验结果并存下另一个脱开的副本。因此 normalizer 无法保留对调用方数据的引用，存下的初值也永不改变；回退到初值的计算使用这个存好的对象，这就是 normalizer 不会按计算样式反复运行的原因。

冲突是被拒绝，不是被消解。包内，规范标识符与全部别名构成一个命名空间：标识符重复、别名等于它自己或另一个标识符、别名等于另一个别名，都拒绝该包。包与包之间，组合拒绝重复的包，以及任一方向的规范/别名交叉冲突。不存在 last-wins 注册可供依赖，因此加载顺序无法悄悄改变一个名字指代哪个属性。需要两个同名包的应用应让它们拥有不同的所有者身份，因为冲突针对完整标识符，而不只是斜杠分隔的片段。

顺序在两处是契约的一部分。`ecss-schema-set-package-ids` 返回组合的参数顺序，`ecss-schema-set-property-ids` 按该顺序展平每个包内的定义顺序。计算样式的读取器按这个顺序遍历属性，因此稳定的顺序让同一个 schema 集合产出稳定的结果。

查找开销小且精确。集合保留两张哈希表，一张给规范标识符、一张给别名，所以 `ecss-schema-set-canonical-id` 及建立在它之上的查找是常数时间的符号查找，不解析、不处理大小写。返回数据的查询——标识符、schema 副本与元数据——只复制 schema 持有的少量值，从不复制整个包；因此只取一项事实的热路径也可以放心调用它们。

## 错误与恢复

<!-- index: 错误数据; 原子失败 -->

创建与组合从不发布部分结果。被拒绝的 `ecss-schema-package-create` 不返回包；被拒绝的 `ecss-schema-set-compose` 让每个参数包保持原样，调用方更早的集合也不受影响。恢复方式始终是修正有问题的值再调用一次——没有半成品状态需要撤销。

| 情形 | 信号 |
| --- | --- |
| 包身份是 nil、关键字、字符串或数字 | `error→ ecss-invalid-property-schema`，数据 `(:package-id VALUE)` |
| 定义参数不是 proper list | `error→ ecss-invalid-property-schema`，数据 `(:definitions VALUE)` |
| 某条定义不是列表 | `error→ ecss-invalid-property-schema`，数据 `(:definition VALUE)` |
| 标识符缺失、没有命名空间，或斜杠任一侧为空 | `error→ ecss-invalid-property-schema`，数据 `(:property ID DEFINITION)` |
| 选项键未知、重复或缺值 | `error→ ecss-invalid-property-schema`，数据 `(:property ID DEFINITION)` |
| `:impacts` 缺失、为空、含非符号或含重复 | `error→ ecss-invalid-property-schema`，数据 `(:property ID DEFINITION)` |
| `:aliases` 或 `:projections` 不是唯一符号列表 | `error→ ecss-invalid-property-schema`，数据 `(:property ID DEFINITION)` |
| 可调用字段既不是 nil 也不是函数 | `error→ ecss-invalid-property-schema`，数据 `(:KEY VALUE)` |
| validator 拒绝初值 | `error→ ecss-invalid-property-schema`，数据 `(:invalid-initial VALUE)` |
| 两条定义共享标识符 | `error→ ecss-invalid-property-schema`，数据 `(:duplicate-property ID)` |
| 别名与同一包的标识符或别名冲突 | `error→ ecss-invalid-property-schema`，数据 `(:collision NAME KIND EXISTING-KIND)` |
| 组合重复了同一个包 | `error→ ecss-invalid-property-schema`，数据 `(:duplicate-package PACKAGE-ID)` |
| 两个包的标识符或别名冲突 | `error→ ecss-invalid-property-schema`，数据 `(:collision NAME KIND EXISTING-KIND)` |
| 某参数不是包，或 SCHEMAS 不是集合 | `error→ wrong-type-argument`，并指名期望的谓词与该值 |

畸形的包不留下任何东西：定义只在整包通过校验之后才被复制，因此调用方的列表也保持原样。别名与元数据同理——它们只在整包被接受时才脱开。
