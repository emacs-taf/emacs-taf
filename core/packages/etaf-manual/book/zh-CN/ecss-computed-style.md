# 计算样式

计算样式是 ECSS 把关于一个主体所知的一切变成结果的地方：来自 schema 集合的属性词表、stylesheet 的规则、挂载的 scope 与内联声明、可选的父样式，以及这些值引用到的自定义属性。结果是一份不可变的*计算样式*，它用三组不同的标识符回答三个不同的问题；本章定义这个对象以及它的每个读取器。产生赢家的层叠比较见[样式系统总论](style-system.md)；stylesheet 与 scope 输入见[stylesheet、scope 与作者所有权](ecss-stylesheets-and-scopes.md)；声明值、自定义属性与 `var()` 引用见[值](values.md)。

## 模型

<!-- index: 计算样式; 计算值; 自定义属性; active 属性; specified 属性; 来源追溯; 诊断 -->

计算样式是值对象。它由 `ecss-compute-style` 一次算出、永不改变；每个读取器都返回脱开的数据，所以调用方可以随意改动收到的东西，而不影响该样式或任何由它算出的结果。它持有计算时用的 schema 集合、计算值、解析后的自定义属性、三组属性标识符、赢家事实、可选的来源追溯与诊断。它不拥有缓冲区、运行时不拥有任何全局状态。

三组标识符回答不同的问题，而它们的差异恰好在一条获胜声明最终无效时显现：

| 问题 | 读取器 | 含义 |
| --- | --- | --- |
| 每个属性取什么值？ | `ecss-computed-style-values` | 每个非简写属性，按 schema 顺序。 |
| 这个属性有获胜声明吗？ | `ecss-computed-style-specified-p` | 存在层叠赢家，无论它的值是否通过校验。 |
| 这个属性确实被供给吗？ | `ecss-computed-style-present-p` | 有效声明获胜，或该属性从 active 的父侧继承。 |

*值*可以来自声明、继承或 schema 初值，且每个非简写属性总是有一个。*specified* 属性有赢家；*active* 属性确实被供给。两者在三处分离：schema 拒绝其值的赢家是 specified 但不是 active，值回退到继承值或初值；schema 接受的显式 nil 既是 specified 也是 active；从 active 父侧继承的属性在子侧算 active 但没有赢家。

*自定义属性*是没有 schema 的值。它们继承、通过 `var()` 引用解析，并以名字/值 plist 出现在计算样式上；引用成环不会毁掉样式，而是记入诊断，受影响的引用回退。

*来源追溯*是可选的。带 `:provenance t` 时样式为每个属性保留赢家事实与最终值的来路；不带时只保留上面那些读取器需要的东西。*诊断*总是收集，因为它们描述的是无法解析的值，而不是额外的细节请求。

## 计算样式

`ecss-compute-style` 是入口。它的输入是 schema 集合、主体与样式来源；其余都是可选上下文。

#### Function: ecss-compute-style (schemas subject &key stylesheet rules declarations parent-style adapter provenance value-resolver scopes)

用 SCHEMAS 为 SUBJECT 计算确定性的样式。

**参数。** SCHEMAS 是组合好的 schema 集合。SUBJECT 是内建主体或调用方自己的节点，后者需要 ADAPTER 暴露它。STYLESHEET 是 stylesheet；RULES 是校好的规则列表，例如 `ecss-stylesheet-rules` 返回的那份。DECLARATIONS 是内联属性/值列表。PARENT-STYLE 是另一份计算样式或 values plist。PROVENANCE 要求赢家事实。VALUE-RESOLVER 是允许求值调用方值来源的函数。SCOPES 是挂载的 scope 列表。

**语义。** STYLESHEET 与 RULES 至多给一个；规则列表会先对 SCHEMAS 校验，包括每条规则的选择器、来源与声明。内联 DECLARATIONS 经 schema 集合展开，因此别名解析、简写变成长手 longhand；自定义属性不需要 schema。来自规则、scope 与声明的候选按层叠排序，随后每个非简写 schema 属性解析其获胜候选：替换自定义属性引用、应用 CSS 全局值与继承、运行 schema 的 normalizer 与 validator。无效值的赢家仍保留为 specified 并记录回退来源，但层叠不会重跑。给出 VALUE-RESOLVER 时，每个被考虑的候选调用它一次，收到值、规范属性与主体；它是调用方值来源被求值的唯一地方，返回值在通过校验后成为该值。可变值会与声明脱开，函数则保持同一，所以除非 resolver 返回别的东西，函数值会原样透过。`:parent-style` 为 values plist 时被当作一组裸父值：只有可继承属性会读它，也不从它获得自定义属性。

**返回。** 一份不可变的计算样式。

**错误。** SCHEMAS 不是 schema 集合时 `error→ wrong-type-argument` 并指名集合谓词；ADAPTER 不是适配器时指名适配器谓词。同时给出两个来源时报 `error→ ecss-invalid-rule`，数据 `(:stylesheet-and-rules)`；提供的规则校验失败时数据 `(:rule RULE)`。内联声明被 schema 拒绝时 `error→ ecss-invalid-declaration`。VALUE-RESOLVER 报出的错误原样传播。

**示例。**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :validator stringp
                           :impacts (paint))))))
       (subject (ecss-subject-create :type "button" :classes '("primary")))
       (sheet (ecss-stylesheet-create)))
  (ecss-stylesheet-add-rule sheet schemas ".primary" '(demo/color "red"))
  (ecss-computed-style-values
   (ecss-compute-style schemas subject :stylesheet sheet)))
     ⇒ (demo/color "red")
```

**参见。** `ecss-computed-style-values`、`ecss-computed-style-copy-with-values`、`ecss-stylesheet-add-rule`、`ecss-scope-create`。

## 值与自定义属性

`ecss-computed-style-values` 把整个结果作为 plist 交出，`ecss-computed-style-value` 读一个属性并可以给 fallback，`ecss-computed-style-custom-properties` 读解析后的自定义属性。三者都返回脱开的数据。

#### Function: ecss-computed-style-values (style)

返回计算样式 STYLE 的防御性 values plist。

**语义。** plist 为 schema 集合注册的每个非简写属性各有一条，按注册顺序，无论是否有人声明过它：没有候选的属性携带它的继承值或初值。简写永不出现——schema 展开已经把它们变成长手 longhand。继承值也是副本，所以返回的 plist 不与 STYLE 共享可变数据。

**返回。** 按 schema 顺序排列的属性/值 plist。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**示例。**

```elisp
(let ((style (ecss-compute-style
              (ecss-schema-set-compose
               (ecss-schema-package-create
                'demo '((:id demo/color :initial "black" :validator stringp
                         :impacts (paint))
                        (:id demo/gap :initial 0 :validator numberp
                         :impacts (geometry)))))
              (ecss-subject-create :type "button"))))
  (ecss-computed-style-values style))
     ⇒ (demo/color "black" demo/gap 0)
```

**参见。** `ecss-computed-style-value`、`ecss-computed-style-custom-properties`。

#### Function: ecss-computed-style-value (style property &optional fallback)

返回计算样式 STYLE 中的 PROPERTY，缺失时返回 FALLBACK。

**语义。** PROPERTY 可以是规范标识符或精确别名。有值的属性总会回答它的值——只有样式完全不携带该名字（例如未知属性或自定义属性）时才会用到 fallback。返回值已脱开，所以给其中的字符串或列表赋值不会改变样式。

**返回。** 计算值，或 FALLBACK。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**示例。**

```elisp
(let ((style (ecss-compute-style
              (ecss-schema-set-compose
               (ecss-schema-package-create
                'demo '((:id demo/color :initial "black" :validator stringp
                         :impacts (paint)))))
              (ecss-subject-create :type "button"))))
  (list (ecss-computed-style-value style 'demo/color)
        (ecss-computed-style-value style 'demo/unknown "fallback")))
     ⇒ ("black" "fallback")
```

**参见。** `ecss-computed-style-values`、`ecss-computed-style-property-fact`。

#### Function: ecss-computed-style-custom-properties (style)

返回计算样式 STYLE 的防御性自定义属性 plist。

**语义。** plist 包含每个可解析的自定义属性，按名字排序，包括从父样式继承的、以及没有任何声明引用过的那些。无法解析的自定义属性——成环，或引用缺失名字且没有 fallback——会被略去，同一次计算会记录诊断说明原因。

**返回。** 自定义属性/值 plist，可以为空。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**示例。**

```elisp
(ecss-computed-style-custom-properties
 (ecss-compute-style
  (ecss-schema-set-compose
   (ecss-schema-package-create
    'demo '((:id demo/color :initial "black" :validator stringp
             :impacts (paint)))))
  (ecss-subject-create :type "button")
  :declarations '( --accent "blue")))
     ⇒ (--accent "blue")
```

**参见。** `ecss-computed-style-diagnostics`、`ecss-var`。

## 供给：active 与 specified

一个属性是否被声明过、它的值是否被接受，是两个不同的事实，这四个读取器把它们分开报告。需要区分「这个值来自声明」与「这个值只是回退」的消费者依赖它们。

#### Function: ecss-computed-style-active-properties (style)

返回计算样式 STYLE 中主动供给的属性标识符。

**语义。** 声明获胜且值通过校验时属性是 active；属性可继承且父侧 active 时也是 active。schema 接受的显式 nil 与其它值一样 active；值未通过校验的赢家不是 active，尽管它是 specified。标识符按 schema 顺序返回。

**返回。** 属性标识符列表，可以为空。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**参见。** `ecss-computed-style-present-p`、`ecss-computed-style-specified-properties`。

#### Function: ecss-computed-style-present-p (style property)

PROPERTY 在计算样式 STYLE 中被主动供给时返回非 nil。

**语义。** 这是 active 集合的成员测试，回答「该属性是否确实被供给」而无需物化整个列表。PROPERTY 可以是规范标识符或精确别名；自定义属性没有 schema 条目，不算 active。返回值未指定具体内容，当布尔用即可。

**返回。** 属性 active 时非 nil，否则 nil。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**参见。** `ecss-computed-style-active-properties`、`ecss-computed-style-specified-p`。

#### Function: ecss-computed-style-specified-properties (style)

返回计算样式 STYLE 中有层叠赢家的属性标识符。

**语义。** 每个存在获胜声明的属性都会列出，无论值是否有效，因此这个集合回答「层叠决定了什么」，与 schema 接受什么无关。它与 active 集合一样按 schema 顺序。

**返回。** 属性标识符列表，可以为空。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**参见。** `ecss-computed-style-specified-p`、`ecss-computed-style-active-properties`。

#### Function: ecss-computed-style-specified-p (style property)

PROPERTY 在计算样式 STYLE 中有层叠赢家时返回非 nil。

**语义。** 这是 specified 集合的成员测试。与 `ecss-computed-style-present-p` 合起来，三种情况可以分开：既 specified 又 active 是有效声明；specified 但不 active 是回退了的无效赢家；两者皆非则值来自继承或初始状态。PROPERTY 可以是规范标识符或精确别名；返回值未指定具体内容。

**返回。** 属性有赢家时非 nil，否则 nil。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**示例。**

```elisp
(let* ((style (ecss-compute-style
               (ecss-schema-set-compose
                (ecss-schema-package-create
                 'demo '((:id demo/color :initial "black" :validator stringp
                          :impacts (paint))
                         (:id demo/payload :initial "none"
                          :validator (lambda (_value) t)
                          :impacts (paint)))))
               (ecss-subject-create :type "button")
               :declarations '(demo/color nil demo/payload nil))))
  (list (and (ecss-computed-style-specified-p style 'demo/color) t)
        (and (ecss-computed-style-present-p style 'demo/color) t)
        (ecss-computed-style-active-properties style)
        (ecss-computed-style-value style 'demo/color)))
     ⇒ (t nil (demo/payload) "black")
```

**参见。** `ecss-computed-style-present-p`、`ecss-computed-style-values`。

## 赢家事实

内部的赢家记录不是公共对象，但两个查询暴露消费者需要的东西：一个属性的完整 fact，以及若干属性中谁的优先级最高。

#### Function: ecss-computed-style-property-fact (style property)

返回计算样式 STYLE 中 PROPERTY 的一份不可变 fact，或 nil。

**语义。** fact 把规范属性、计算值、所属包身份、schema 的 impacts 与 projections、`(:provenance t)` 计算时的该属性来源追溯、以及 schema 元数据一并装进一个脱开的值。名字解析不到 schema 属性时——未知名字或自定义属性——返回 nil。

**返回。** 属性 fact，或 nil。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**示例。**

```elisp
(let* ((style (ecss-compute-style
               (ecss-schema-set-compose
                (ecss-schema-package-create
                 'demo '((:id demo/color :initial "black" :validator stringp
                          :impacts (paint) :projections (paint)
                          :metadata (:note "color")))))
               (ecss-subject-create :type "button"))))
  (list (and (ecss-computed-style-property-fact style 'demo/color) t)
        (ecss-computed-style-property-fact style 'demo/unknown)))
     ⇒ (t nil)
```

**参见。** `ecss-computed-style-value`、`ecss-computed-style-precedence-winner`。

#### Function: ecss-computed-style-precedence-winner (style properties)

返回 PROPERTIES 中在 STYLE 里优先级最高的已声明属性。

**语义。** PROPERTIES 是规范标识符或别名组成的列表。函数按精确的层叠顺序比较已记录的赢家，返回若只有这些属性参与时会胜出的那一个；没有赢家的属性被忽略，一个都没声明时返回 nil。它从不重跑层叠，也不要求样式是用 `:provenance t` 算的。

**返回。** 优先级最高的已声明属性的规范标识符，或 nil。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值；某个名字不在 schema 集合里时 `error→ ecss-invalid-declaration`，数据 `(:unknown-property PROPERTY)`。

**示例。**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :validator stringp
                           :impacts (paint))
                          (:id demo/size :initial 0 :validator numberp
                           :impacts (geometry))))))
       (subject (ecss-subject-create :type "button" :id "save" :classes '("target")))
       (sheet (ecss-stylesheet-create)))
  (ecss-stylesheet-add-rule sheet schemas ".target" '(demo/color "red"))
  (ecss-stylesheet-add-rule sheet schemas "#save" '(demo/size 5))
  (ecss-computed-style-precedence-winner
   (ecss-compute-style schemas subject :stylesheet sheet)
   '(demo/color demo/size)))
     ⇒ demo/size
```

**参见。** `ecss-computed-style-property-fact`、`ecss-computed-style-provenance`。

## 来源追溯与诊断

来源追溯是可选记录，说明每个属性如何得到它的值。诊断总是收集，描述计算无法解析的值。

#### Function: ecss-computed-style-provenance (style)

返回计算样式 STYLE 的防御性赢家来源追溯。

**语义。** plist 把每个属性映射到它的事实。由声明决定的属性报告来源、归一化选择器、来源、important 与 inline 状态、层、优先级、作用域距离、源顺序与声明顺序、值是否通过校验、值的来路，以及用过回退时的回退来源。没有赢家的属性报告裸的 `(:source initial :origin ua)` 或 `(:source inherit :origin inherit)`；继承的自定义属性报告 `(:source inherit)`。样式未带 `:provenance t`（默认）计算时返回 nil。

**返回。** 属性/plist 映射，或 nil。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**示例。**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :validator stringp
                           :impacts (paint))))))
       (subject (ecss-subject-create :type "button" :classes '("target")))
       (sheet (ecss-stylesheet-create)))
  (ecss-stylesheet-add-rule sheet schemas ".target" '(demo/color "red"))
  (plist-get
   (plist-get
    (ecss-computed-style-provenance
     (ecss-compute-style schemas subject :stylesheet sheet :provenance t))
    'demo/color)
   :valid))
     ⇒ t
```

**参见。** `ecss-computed-style-diagnostics`、`ecss-computed-style-property-fact`。

#### Function: ecss-computed-style-diagnostics (style)

返回计算样式 STYLE 的防御性诊断。

**语义。** 每条诊断是一个带 `:type` 与解释数据的 plist；当前类型是 `variable-cycle`，其 `:path` 列出环上的自定义属性。诊断会去重并按确定顺序排列，因此同样的输入产生同样的列表。成环不是错误：受影响的引用回退，该自定义属性从自定义属性 plist 中略去，诊断说明原因。

**返回。** 诊断 plist 的列表，可以为空。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**示例。**

```elisp
(ecss-computed-style-diagnostics
 (ecss-compute-style
  (ecss-schema-set-compose
   (ecss-schema-package-create
    'demo '((:id demo/color :initial "black" :validator stringp
             :impacts (paint)))))
  (ecss-subject-create :type "button")
  :declarations (list '--a (ecss-var '--b) '--b (ecss-var '--a))))
     ⇒ ((:type variable-cycle :path (--a --b --a)))
```

**参见。** `ecss-computed-style-custom-properties`、`ecss-computed-style-provenance`。

## 派生样式

#### Function: ecss-computed-style-copy-with-values (style values &key active-properties specified-properties)

返回用替换后的 VALUES 与可选元数据复制的 STYLE。

**语义。** 这是给已经证明选择器与层叠事实未变、只需要传播计算值增量的消费者用的窄变换。VALUES 整体替换 values plist，而不是合并进去；ACTIVE-PROPERTIES 与 SPECIFIED-PROPERTIES 给出时整体替换对应集合，省略时保留 STYLE 的。来源追溯与诊断原样保留。所有可变值在边界处复制，所以调用后改动 VALUES 不会改变副本。

**返回。** 新的计算样式。

**错误。** STYLE 不是计算样式时 `error→ wrong-type-argument`，并指名计算样式谓词与该值。

**示例。**

```elisp
(let ((style (ecss-compute-style
              (ecss-schema-set-compose
               (ecss-schema-package-create
                'demo '((:id demo/color :initial "black" :validator stringp
                         :impacts (paint))
                        (:id demo/gap :initial 0 :validator numberp
                         :impacts (geometry)))))
              (ecss-subject-create :type "button")
              :declarations '(demo/gap 3))))
  (list (ecss-computed-style-values
         (ecss-computed-style-copy-with-values style '(demo/color "copied")))
        (ecss-computed-style-active-properties
         (ecss-computed-style-copy-with-values style '(demo/color "copied")))))
     ⇒ ((demo/color "copied") (demo/gap))
```

**参见。** `ecss-compute-style`、`ecss-computed-style-p`。

#### Function: ecss-computed-style-p (x)

X 是计算样式时返回非 nil。

**语义。** 这个谓词是每个读取器使用的类型守卫，也是计算样式与 values plist 都可能被当作父样式传入时，消费者区分两者的手段。

**返回。** X 是计算样式时非 nil，否则 nil。

**错误。** 无。

**参见。** `ecss-compute-style`、`ecss-computed-style-values`。

## 语义细节

<!-- index: 无效赢家; 回退; 赢家排序; 边界复制 -->

三组标识符是接口的核心，它们的差异是有意为之。最高候选的值未通过校验时，赢家仍留在 specified 集合里——层叠决定了它，而重算也不会改变这个决定——但它退出 active 集合，值回退到继承值或初值。来源追溯把两个事实都记下：`:valid` 是 nil，`:fallback` 指明值的来路。想知道「声明了什么」的消费者查 specified 集合；想知道「现在生效的是什么」的查 active 集合。

值总是覆盖整份词表。schema 集合注册的每个非简写属性都有一条，即使无人提及它，因为初值与继承值也是答案的一部分。这让 values plist 成为可稳定遍历的形状：消费者按 schema 顺序走一遍就能找到它认识的每个属性，交给 `ecss-computed-style-precedence-winner` 的属性列表也在同一份词表里解析。

来源追溯可选，因为它花内存和分配：不带它时样式内部仍保留赢家记录（`ecss-computed-style-precedence-winner` 读的就是它），但不构建公共 fact plist。诊断不带可选性，因为它报告的是算不出值的计算；受影响的自定义属性被略去、引用回退，所以结果依然完整。

resolver 是唯一的求值钩子。ECSS 自己从不调用属性里存的函数；给出 `:value-resolver` 时，每个被考虑的候选调用它一次，值已脱开、规范属性与主体一并传入，它返回什么就在 schema 归一化与校验之前成为该值。这让构造与计算默认保持纯净，同时让宿主按自己的方式求值动态值。

每个公共读取器都复制。样式不可变，读取器返回新 plist 或列表，所以调用方可以排序、修改或保存收到的东西，而不必担心改变样式或其它消费者的视图。副本与 schema、主体边界一样是浅层脱开：嵌套的可变值被复制，函数保持同一性。

## 错误与恢复

<!-- index: 计算错误; 读取器错误 -->

计算要么拒绝整个输入，要么返回完整样式；没有部分结果。输入错误在任何值解析之前报出，resolver 的错误在调用点传播，调用方没有需要清理的样式。

| 情形 | 信号 |
| --- | --- |
| SCHEMAS 不是 schema 集合 | `error→ wrong-type-argument`，指名集合谓词与该值 |
| ADAPTER 既不是 nil 也不是适配器 | `error→ wrong-type-argument`，指名适配器谓词与该值 |
| 同时给出 `:stylesheet` 与 `:rules` | `error→ ecss-invalid-rule`，数据 `(:stylesheet-and-rules)` |
| `:rules` 中某条规则校验失败 | `error→ ecss-invalid-rule`，数据 `(:rule RULE)` |
| 内联声明点名未知属性或形状非法 | `error→ ecss-invalid-declaration`，带出错的属性 |
| VALUE-RESOLVER 报错 | 该错误原样传播 |
| 读取器或 `ecss-computed-style-copy-with-values` 收到非样式 | `error→ wrong-type-argument`，指名计算样式谓词与该值 |
| `ecss-computed-style-precedence-winner` 收到未知属性 | `error→ ecss-invalid-declaration`，数据 `(:unknown-property PROPERTY)` |
