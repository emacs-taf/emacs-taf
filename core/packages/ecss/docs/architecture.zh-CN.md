# ecss 架构

[English](architecture.md)

## 定位

`ecss` 是“规则如何赢、最终属性值是什么”的通用纯计算层。它把 consumer 提供的 property schemas、subjects、stylesheets、inline declarations 与 parent computed style 转换成 computed values、custom properties、active properties、specified properties、provenance 和 diagnostics。

```text
consumer schemas + subject adapter + stylesheet + parent style
                              │
                              ▼
       selector match → candidate collection → cascade winner
                              │
                              ▼
        CSS-wide/custom-property resolution → normalize/validate
                              │
                              ▼
    computed style + specified properties + provenance + diagnostics
```

`ecss` 不知道 computed values 最终如何显示。Ebox 将这些值用于 measurement、Box/Flex/Grid layout、painting 以及自身的保留式 Buffer 发布。其他调用者无需 Ebox 或任何 Buffer 即可使用 `ecss`。

## Package schema 与显式 surface

每个 owning package 一次创建不可变 `ecss-schema-package`；具体 surface 再用 `ecss-schema-set-compose` 原子组合所需 package。组合阶段统一拒绝重复 package、canonical/canonical、canonical/alias 与 alias/alias 冲突，不存在进程全局 mutable registry 或 last-wins 注册。两个应用因此可以在同一 Emacs 中组合不同 property vocabulary 而互不污染。

Alias 只属于声明归一化入口，进入 cascade 前消失；同一声明中 alias/canonical 重复或 shorthand 与其输出 longhand 冲突会立即失败。Schema set 同时保存 owner、impact 与 projection facts，computed style 直接引用该 set，不建立第二棵 computed tree。Package/schema set 不提供 mutator，公共查询返回 detached 数据。

Stylesheet 仍是每个调用者显式拥有的可变 authoring 对象。同一 stylesheet 中的 UA、user 与 author origin 分别维护 layer order；rule 添加是原子的，一次失败不会留下半添加 layer 或错误 source order。

## Subject 与 adapter

简单场景直接使用 `ecss-subject`。已有树模型通过 `ecss-subject-adapter-create` 提供 type、id、classes、attributes、states、parent 与 children callback，不需要把业务节点复制成 ECSS node。selector query 与 stylesheet 都调用同一个 parser、matcher 和 specificity 实现，因此不会出现“查询能匹配但样式规则不能匹配”的两套语义。

挂载作用域保存 stylesheet 与可选规则目标身份集合的快照。目标集合限定候选
声明收集，选择器关系仍来自挂载根以内的宿主 adapter 树。这让样式所有权独立
于物理父子关系，无需复制层叠算法，也不阻断继承。未指定集合时覆盖子树，空集合
没有目标；集合按身份查询，不复制宿主节点。
候选收集直接读取这些自有规则快照。防御性复制发生在公共查询与回调边界，
避免每计算一个 subject 都复制所有挂载作用域的完整规则。

## Cascade 顺序

候选值按 CSS 顺序比较：relevance/match、origin+importance、cascade layer、specificity、scope proximity、source order、declaration order。标准 origin level 是 UA normal、user normal、author normal、animation、author important、user important、UA important、transition。normal layer 后声明者优先且 unlayered 高于 layered；important layer 反向，inline author declaration 在 author origin 内保持最高优先级。

`revert` 删除当前整个 origin 后重新选择，不区分 normal 与 important；`revert-layer` 删除当前 origin 中的整个 layer 后重新选择。invalid-at-computed-value 不会退回较低候选，而是使用 inherited/initial fallback，并在 provenance 中记录 invalid winner。

## Value source 边界

ECSS 不自动调用属性里的 function，也不定义自己的 reactive/computed wrapper。调用者需要求值时，显式向 `ecss-compute-style` 传入 `:value-resolver`。resolver 接收 value、property、subject，ECSS 对每个被选中的 source 只调用一次，resolver 返回值不会被二次执行。resolver error 直接向外传播；由于 computation 是纯计算，不存在需要 ECSS 回滚的 Buffer 或 runtime state。

## Custom properties

Custom properties 使用 `--name` symbol，通过普通 cascade 选出 raw value，默认从 parent computed style 继承，再用 `ecss-var` 解析。引用可以嵌套在 list/vector 中；缺失值与 cycle 可使用引用处 fallback。cycle 不破坏整个 computed style，而产生 deterministic diagnostic，并把受影响 value 标记为 invalid-at-computed-value。

## 包边界

```text
ecss: selector / stylesheet / cascade / computed values
ebox: box semantics / measurement / flex-grid layout / painting / dirty ownership
      display bindings / text-property projection / retained publication / transactions
```

Ebox 依赖 `ecss`；`ecss` 可独立使用，不依赖 Ebox。`ecss` public API 不定义 Ebox node、display binding、mount、marker、patch 或 Buffer mutation。每个 consumer 自行负责渲染与发布行为。
