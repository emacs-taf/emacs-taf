# 增量宿主

增量宿主重用工作：一次更新之后，它想保留不可能改变的匹配与计算事实，而不是全部重算。复用一个主体的结果之前，关键问题是产生它的那条选择器只读该主体自身的事实，还是也依赖祖先、兄弟或位置——这些可能已被更新移动。本章定义回答这个问题的唯一接口。它是分类，不是缓存：ECSS 告诉宿主哪些选择器可以按局部推理，复用决策与所喂的缓存都归宿主。[增量更新与发布](incremental-updates-and-publication.md)描述 Ebox 内部如何使用这种分类，[选择器](selectors.md)定义被分类的选择器语言。

## 模型

<!-- index: 选择器局部性; subject 自身事实; 依赖树的选择器; scope root 稳定性 -->

决定一条选择器是否匹配某个主体时不需要该主体之外的任何事实，它就是*对主体局部*的。类型、ID、类、属性与状态是主体自身的事实；只用它们的复合选择器，例如 `button#save.primary[role=submit]:active`，是局部的。每个分支都局部的逻辑组合也是局部的：`:is(.a, #b)`、`:not(.disabled)`，以及局部分支组成的选择器列表。

凡是读取树中位置的东西都不局部。后代、子、相邻与通用兄弟组合子会触及其它节点，`:has()` 会看一个相对目标，结构与位置伪类——`:first-child`、`:empty`、`:root`、`:nth-child(2)`、`:nth-last-of-type(odd)` 及其亲属——依赖主体的兄弟或父。包含任何这类部分的选择器都不局部，即使其余部分没错：局部性是整条选择器的性质，不是它第一个复合段的性质。

`&` 与 `:scope` 是特例，因为它们指向 scope root 而不是某个固定关系。默认它们不局部，因为主体是否匹配取决于 root 在哪里。若宿主已单独证明主体相对同一 scope root 的关系未变，可以把这份证明作为可选的第二个参数传入，锚点即视为局部事实。证明归调用方：函数记录假设，不验证它。

局部性不是复用的全部条件。局部选择器仍然不说明它所属规则是不是当前 scope 的成员、层叠的其它输入是否变了、继承值是否动了、主体自己的本地元数据是否过期。宿主在复用计算样式之前要检查这些；这个接口只是把「是否依赖树」这一问题从清单上移除。

## 分类一条选择器

#### Function: ecss-selector-subject-local-p (selector &optional scope-root-stable-p)

返回 SELECTOR 是否只依赖被匹配的主体。

**参数。** SELECTOR 是选择器字符串或已解析的 AST。SCOPE-ROOT-STABLE-P 非 nil 时表示调用方已证明被匹配主体相对同一 scope root 的关系未变。

**语义。** 选择器先被归一化并校验，再按每个部分的种类分类。类型、ID、类、属性与状态选择器是局部的；功能状态伪类也是局部的，除非它是位置伪类，所以 `:lang(en)`、`:dir(ltr)` 与宿主定义的 `:my-state(on)` 尽管参数看着像结构，实际只读主体。逻辑组合（`:is`、`:where`、`:not`，以及复合段或列表下降成的内部形式）当每个分支都局部时才是局部。组合子、`:has()` 与结构、位置伪类不局部。scope 锚点 `&` 与 `:scope` 只在给了 SCOPE-ROOT-STABLE-P 时局部。本检查不需要主体、不做匹配：它只对选择器分类。

**返回。** 在给定假设下选择器对主体局部时非 nil，否则 nil。

**错误。** SELECTOR 无法解析或不是合法选择器 AST 时 `error→ ecss-invalid-selector`，包括语言不支持的伪元素。

**示例。**

```elisp
(list (and (ecss-selector-subject-local-p ".card:hover") t)
      (and (ecss-selector-subject-local-p "section > .card") t)
      (and (ecss-selector-subject-local-p "&:hover" t) t)
      (and (ecss-selector-subject-local-p "& > .card" t) t))
     ⇒ (t nil t nil)
```

**参见。** `ecss-selector-parse`、`ecss-selector-match-p`、`ecss-scope-create`。

## 语义细节

<!-- index: 分类开销; 稳定性证明; 逻辑分支 -->

接口分两层，因为稳定性是只有调用方能知道的事实。不给 flag 时，提到 `&` 或 `:scope` 的选择器按依赖树处理，因为匹配它取决于 scope root 相对主体的位置。给 flag 后，调用方承诺这个关系没有变；锚点随即与类、属性同属一类，`&.active` 这类选择器变成局部。承诺很窄：它只覆盖主体与同一 root 的关系，不覆盖成员资格、当前挂载的规则，也不覆盖继承值。

功能伪类按它读什么分类，而不按语法。位置形式——`:nth-child`、`:nth-last-child`、`:nth-of-type`、`:nth-last-of-type`，包括带 `of` 过滤的——数兄弟，不局部。其它功能伪类是对主体自身的状态或元数据查询：`:lang(en)` 读一个可继承属性，但匹配仍只依赖主体自己的属性链，`:my-state(on)` 这样的未知伪类是宿主提供的状态 token。两者都局部，这正是宿主可以定义自定义状态伪类而不会损失局部性的原因。

局部性沿逻辑形式向下合成，不沿其它任何东西向上合成。选择器列表、`:is()`、`:where()`、`:not()` 与单个复合段的合取，只有全部分支局部时才局部；一个非局部分支使整条选择器不局部，外层包裹无法把依赖树的选择器重新变回局部。分类是选择器的纯函数，因此宿主可以分类一次，把答案与已编译的选择器或规则存在一起。

## 错误与恢复

<!-- index: 分类错误 -->

调用不读主体、不改变任何东西，对每条合法选择器都返回布尔；唯一的失败是非法选择器，它在分类开始之前被拒绝。

| 情形 | 信号 |
| --- | --- |
| SELECTOR 无法解析，或 AST 校验不通过 | `error→ ecss-invalid-selector`，带解析器数据或出错 AST |
| SELECTOR 使用语言不支持的伪元素 | `error→ ecss-invalid-selector`，数据 `(:pseudo-elements-unsupported)` |
