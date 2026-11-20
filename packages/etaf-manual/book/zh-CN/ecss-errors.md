# 错误条件

ECSS 是纯计算库，这也决定了它的错误契约：调用要么返回值，要么报错，不留下半改的缓冲区或全局状态。它报出的条件是公共 API 的一部分，构成一个单根基的家族，因此调用方用一个 handler 就能抓住 ECSS 拒绝的一切。本章汇集这些条件，说明哪一层抛哪一个、解释失败原因的数据长什么样，以及各自的恢复方式。各章分别记录自己条目的错误；本章讲这些条目背后的家族。[值](values.md)与[选择器](selectors.md)定义被检查的语法，[stylesheet、scope 与作者所有权](ecss-stylesheets-and-scopes.md)与[计算样式](ecss-computed-style.md)定义被拒的对象，[规则文件](ecss-rule-files.md)描述这个家族之外的 `user-error` 与读取条件。

## 错误层级

<!-- index: 错误条件; 条件层级; 错误数据 -->

`ecss-error` 派生自 `error`，是「ECSS 操作被拒绝」的条件：调用方要求了输入无法支撑的事。五个条件从它派生，各自对应词表的一层。

| 条件 | 父条件 | 触发于 |
| --- | --- | --- |
| `ecss-error` | `error` | 公共 ECSS 操作拒绝了输入 |
| `ecss-invalid-selector` | `ecss-error` | 选择器文本或 AST 畸形或不受支持 |
| `ecss-invalid-subject-adapter` | `ecss-error` | 适配器回调缺失或不是函数 |
| `ecss-invalid-property-schema` | `ecss-error` | 包或属性定义畸形，或组合发生冲突 |
| `ecss-invalid-declaration` | `ecss-error` | 声明点名未知属性、破坏语法或留下冲突 |
| `ecss-invalid-rule` | `ecss-error` | 规则、来源、层或来源组合非法 |

另外两类失败在这个家族之外。*类型*错误是普通的 `wrong-type-argument`，数据指名期望的谓词与值，例如把非 stylesheet 传给需要 stylesheet 的地方；它不是 ECSS 条件，因为它说明调用方用错了对象种类，而不是操作拒绝了一个类型正确的对象。*规则文件*的语法问题经 `user-error` 报出，源码问题经 Lisp 读取条件 `end-of-file` 与 `invalid-read-syntax` 报出，[规则文件](ecss-rule-files.md)有述。因此 `ecss-error` 的 handler 能抓住每个 ECSS 层的拒绝，但抓不到参数类型错误或文件语法错误。

## 条件

#### Error: ecss-error

ECSS 操作被拒绝时的基条件。

**语义。** 入口给出的输入无法使用时抛出该条件。它的数据是列表，首元素是描述；条件自身的消息是 "ECSS error"，`error-message-string` 把两者拼起来，形如 `ECSS error: "…"`。家族里的每个条件都继承这个形状，因此 handler 可以用同一种方式报告它们。

**恢复。** 被拒绝的调用什么都没应用：ECSS 没有需要回滚的部分状态。修正输入再调一次即可。

**示例。**

```elisp
(condition-case err
    (signal 'ecss-error '("example failure"))
  (ecss-error (error-message-string err)))
     ⇒ "ECSS error: \"example failure\""
```

**参见。** `ecss-invalid-selector`、`ecss-invalid-property-schema`、`ecss-invalid-rule`。

#### Error: ecss-invalid-selector

选择器语法或选择器 AST 非法。

**语义。** 解析器、归一化器、匹配器与局部性分类器都在做任何匹配之前抛出该条件。数据指出问题所在：解析失败携带关键字与位置，如 `(:expected-compound 3)`、`(:unclosed-string)`、`(:unclosed-comment)`、`(:attribute-flag FLAG)`、`(:invalid-nth-of ARGUMENT)`、`(:unterminated-relative)` 或 `(:pseudo-elements-unsupported)`；结构 AST 校验失败携带出错的 AST，如 `(:unknown value)`；完全读不出的选择器字符串携带该字符串。stylesheet 或规则列表里的畸形选择器也在这里浮出，因为这些路径都经同一个解析器归一化。

**恢复。** 修正选择器文本或 AST。stylesheet 没有多出规则，没有尝试匹配，也没有创建 scope。

**参见。** `ecss-selector-parse`、`ecss-selector-normalize`、`ecss-invalid-rule`。

#### Error: ecss-invalid-subject-adapter

主体适配器建不出来。

**语义。** `ecss-subject-adapter-create` 要求 type、id、classes、attributes、states、parent 与 children 七个回调都是函数。数据是收到的七个回调值组成的列表，因此调用方能看出哪个位置缺失或不对。省略的关键字是 nil，而 nil 不是函数，所以残缺的适配器永远不会被创建。

**恢复。** 补全七个回调再建一次。调用成功之前不存在适配器，宿主树也没有被动过。

**参见。** `ecss-subject-adapter-create`、`ecss-compute-style`。

#### Error: ecss-invalid-property-schema

包或属性定义畸形，或组合无法形成。

**语义。** `ecss-schema-package-create` 与 `ecss-schema-set-compose` 对每种结构问题都抛该条件：包身份不对是 `(:package-id VALUE)`；列表畸形是 `(:definitions VALUE)` 与 `(:definition VALUE)`；定义破坏标识符、选项、impacts、aliases 或 projections 语法是 `(:property ID DEFINITION)`；可调用字段不是函数是 `(:KEY VALUE)`；validator 拒绝初值是 `(:invalid-initial VALUE)`；标识符重复是 `(:duplicate-property ID)`；包内或跨包名字冲突是 `(:collision NAME KIND EXISTING-KIND)`；同一个包被传两次是 `(:duplicate-package PACKAGE-ID)`。

**恢复。** 修正定义，或去掉冲突的包，再创建或组合一次。被拒绝的调用什么都没存，每个输入包也保持原样。

**参见。** `ecss-schema-package-create`、`ecss-schema-set-compose`。

#### Error: ecss-invalid-declaration

声明无法按写法使用。

**语义。** 声明处理会以多种形状抛出该条件。未知属性是 `(:unknown-property NAME)`；声明列表不是属性/值偶数列是 `(:declarations VALUE)`；同一个声明来源直接或经简写两次产生同一规范 longhand 是 `(:duplicate-property PROPERTY :first-source FIRST :second-source SECOND)`；简写展开畸形是 `(:shorthand SHORTHAND DECLARATIONS)` 或 `(:nested-shorthand SHORTHAND PROPERTY)`；未知 CSS 全局种类是 `(:wide-value KIND)`；变量引用的名字不是自定义属性是 `(:custom-property NAME)`。`ecss-compute-style` 的内联声明、声明展开与合并、`ecss-wide-value` 与 `ecss-var` 都抛同一条件，因此调用方可以在一处处理所有声明问题。

**恢复。** 修正属性名、值列表或冲突的声明。展开与合并是纯的，计算在拒绝输入时不存任何东西。

**参见。** `ecss-expand-declarations`、`ecss-merge-declarations`、`ecss-wide-value`、`ecss-var`。

#### Error: ecss-invalid-rule

规则、来源、层或来源组合非法。

**语义。** 规则层在规则无法被接受时抛出该条件：未知层叠来源是 `(:origin ORIGIN)`；层列表含 nil 或不是列表是 `(:layers LAYERS)`；作为规则传入的对象不是规则是 `(:rule RULE)`；规则列表经 `ecss-compute-style` 回放时，快照内部事实不一致是 `(:source-order RULE)`、`(:declarations RULE)` 或 `(:shorthand-snapshot PROPERTY)`。同时给 stylesheet 与规则列表是 `(:stylesheet-and-rules)`。规则内部的选择器问题报为 `ecss-invalid-selector`，因为那段语法归解析器所有。

**恢复。** 修正规则或选项再试。加入规则是原子的：被拒绝的加入让规则列表、各层顺序与源顺序计数器保持原样，被拒绝的计算不产生样式。

**参见。** `ecss-stylesheet-add-rule`、`ecss-stylesheet-declare-layers`、`ecss-compute-style`。

## 错误来自哪里

<!-- index: 触发矩阵; 层归属 -->

每一层拥有一个条件，因此条件名可以快速说明问题出在哪。下表列出常见触发点；中列条目所在章记录完整契约。

| 触发点 | 条件 | 抛出者 |
| --- | --- | --- |
| 语法拒绝的选择器文本或 AST | `ecss-invalid-selector` | `ecss-selector-parse`、`ecss-selector-normalize`、`ecss-selector-match-p`、`ecss-selector-subject-local-p`、规则中的选择器 |
| 适配器不足七个函数 | `ecss-invalid-subject-adapter` | `ecss-subject-adapter-create` |
| 包身份、定义、冲突或重复有问题 | `ecss-invalid-property-schema` | `ecss-schema-package-create`、`ecss-schema-set-compose` |
| 未知属性、畸变列表、规范重复、坏 wide 值或变量名 | `ecss-invalid-declaration` | `ecss-expand-declarations`、`ecss-merge-declarations`、`ecss-wide-value`、`ecss-var`、内联声明 |
| 坏来源、坏层列表、规则列表里的非规则、同时给两个来源 | `ecss-invalid-rule` | `ecss-stylesheet-add-rule`、`ecss-stylesheet-declare-layers`、`ecss-compute-style` |
| 参数对象种类不对 | `wrong-type-argument` | 每个带类型的入口，指名期望谓词 |
| 规则文件语法与文件问题 | `user-error`、`end-of-file`、`invalid-read-syntax` | `ecss-validate-rules`、`ecss-read-rules`、`ecss-file-read` |

## 恢复

<!-- index: 恢复; 原子性 -->

恢复遵循归属规则。选择器被拒就修选择器；包或组合被拒就修定义；声明被拒就修声明；规则被拒就修规则或选项。因为每个这样的调用都先校验后存储，被拒绝的调用什么都不改——不会多出半条规则，不会有半组合的 schema 集合，也不会有需要丢弃的计算样式。想区分非法输入与类型错误的 handler 用 `ecss-error` 抓前者、`wrong-type-argument` 抓后者；想报告一切的 handler 抓 `error`，它同时覆盖两者，也覆盖文件读取器的条件。
