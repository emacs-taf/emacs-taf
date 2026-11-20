# 标准错误

错误条件是公共 API 的一部分：调用框架的程序用它们区分坏输入、缺失的挂载或不可用的后端，并在不留下半成品状态的前提下恢复。本附录列出每个条件、它的父条件以及触发它的情境；链接的条目给出各条件携带的数据、消息以及失败后保留的状态。除 `ebox-input-cancelled` 外，全部条件都派生自 `error`；`ebox-input-cancelled` 派生自 `quit`，因此普通错误处理器不会截获被放弃的输入会话。

<!-- index: 错误条件; 条件层级; 恢复 -->

## ETAF

| 条件 | 父条件 | 触发时机 |
| --- | --- | --- |
| [`etaf-view-error`](views.md#error-etaf-view-error) | `error` | View 不合法时的基础条件；下面的 View 与组件条件都是它的子类。 |
| [`etaf-view-syntax-error`](views.md#error-etaf-view-syntax-error) | `etaf-view-error` | 结构形式不合法；在 `etaf-view` 展开期间、任何求值之前抛出。 |
| [`etaf-component-definition-error`](components.md#error-etaf-component-definition-error) | `etaf-view-error` | 组件定义非法，或组件 API 在其阶段之外被使用。 |
| [`etaf-component-call-error`](components.md#error-etaf-component-call-error) | `etaf-view-error` | 组件调用或它的某个输入非法。 |
| [`etaf-renderer-error`](views.md#error-etaf-renderer-error) | `error` | 规范化 View 无法显示，或需要已挂载的 Runtime 而不可得。 |
| [`etaf-reactive-error`](reactivity.md#error-etaf-reactive-error) | `error` | 响应式图拒绝了操作，例如在计算期间写入或响应式值非法。 |
| [`etaf-render-side-effect-error`](reactivity.md#error-etaf-render-side-effect-error) | `etaf-reactive-error` | 渲染期间尝试了会改变响应式图的操作；数据给出操作名。 |
| [`etaf-runtime-error`](runtime.md#error-etaf-runtime-error) | `error` | Runtime 操作无法完成：未挂载就使用、挂载选项畸形或保留更新失败。 |
| [`etaf-observer-error`](incremental-updates-and-publication.md#error-etaf-observer-error) | `error` | 观察者上下文状态以非法值构造或使用，例如不是函数的 sink。 |
| [`etaf-context-error`](context.md#error-etaf-context-error) | `error` | Context 操作格式错误，或必需依赖缺失。 |
| [`etaf-action-error`](actions-behaviors-and-error-boundaries.md#error-etaf-action-error) | `error` | Action 无法定义、登记或派发。 |
| [`etaf-behavior-error`](actions-behaviors-and-error-boundaries.md#error-etaf-behavior-error) | `error` | Behavior 规格、来源、安装函数或受控几何输入非法。 |
| [`etaf-event-error`](events.md#error-etaf-event-error) | `error` | 事件操作的上下文或目标非法。 |
| [`etaf-async-error`](async.md#error-etaf-async-error) | `etaf-reactive-error` | 异步适配器或超时无效。 |
| [`etaf-async-timeout`](async.md#error-etaf-async-timeout) | `etaf-async-error` | 异步等待超过其超时。 |
| [`etaf-async-cancelled`](async.md#error-etaf-async-cancelled) | `etaf-async-error` | 待决的异步工作被取消。 |
| [`etaf-resource-error`](resources.md#error-etaf-resource-error) | `etaf-reactive-error` | Resource 操作无效。 |
| [`etaf-data-error`](data-controllers.md#error-etaf-data-error) | `error` | Data 契约被违反：已有待决变更、批操作畸形、缺少能力或结果未提交。 |
| [`etaf-data-stopped-error`](data-controllers.md#error-etaf-data-stopped-error) | `etaf-data-error` | 对已停止的 Data Controller 执行了操作。 |
| [`etaf-animation-error`](animation.md#error-etaf-animation-error) | `error` | 动画操作无效。 |

## Ebox

| 条件 | 父条件 | 触发时机 |
| --- | --- | --- |
| [`ebox-error`](ebox-errors.md#error-ebox-error) | `error` | 公共入口收到无法使用的输入：未知 tag、畸形作者形式、非法属性表或坏的节点拓扑。 |
| [`ebox-size-error`](ebox-errors.md#error-ebox-size-error) | `error` | 尺寸值超出其定义域。 |
| [`ebox-style-schema-error`](style-implementation.md#error-ebox-style-schema-error) | `error` | 样式 schema 畸形。 |
| [`ebox-input-error`](text-input.md#error-ebox-input-error) | `ebox-error` | 输入会话操作无效。 |
| [`ebox-input-cancelled`](text-input.md#error-ebox-input-cancelled) | `quit` | 输入目标已不可用；父条件为 `quit`，因此普通 `error` 处理器不会捕获它。 |

## ECSS

| 条件 | 父条件 | 触发时机 |
| --- | --- | --- |
| [`ecss-error`](ecss-errors.md#error-ecss-error) | `error` | ECSS 操作被拒绝时的基础条件；下面五个都是它的子类。 |
| [`ecss-invalid-selector`](ecss-errors.md#error-ecss-invalid-selector) | `ecss-error` | 选择器语法或选择器 AST 非法。 |
| [`ecss-invalid-subject-adapter`](ecss-errors.md#error-ecss-invalid-subject-adapter) | `ecss-error` | 主体适配器建不出来。 |
| [`ecss-invalid-property-schema`](ecss-errors.md#error-ecss-invalid-property-schema) | `ecss-error` | 包或属性定义畸形，或组合无法形成。 |
| [`ecss-invalid-declaration`](ecss-errors.md#error-ecss-invalid-declaration) | `ecss-error` | 声明无法按写法使用。 |
| [`ecss-invalid-rule`](ecss-errors.md#error-ecss-invalid-rule) | `ecss-error` | 规则、来源、层或来源组合非法。 |

## EKP

| 条件 | 父条件 | 触发时机 |
| --- | --- | --- |
| [`ekp-hyphen-error`](ekp-hyphenation.md#error-ekp-hyphen-error) | `error` | 断字失败的基条件；下面两个是它的子类。 |
| [`ekp-hyphen-dictionary-not-found`](ekp-hyphenation.md#error-ekp-hyphen-dictionary-not-found) | `ekp-hyphen-error` | 找不到与请求语言匹配的字典。 |
| [`ekp-hyphen-unsupported-pattern`](ekp-hyphenation.md#error-ekp-hyphen-unsupported-pattern) | `ekp-hyphen-error` | 字典使用了本实现不支持的替换模式。 |
| [`ekp-backend-contract-error`](ekp-native-module.md#error-ekp-backend-contract-error) | `error` | 原生后端返回了畸形结果。 |

## ETAF UI

| 条件 | 父条件 | 触发时机 |
| --- | --- | --- |
| [`etaf-ui-svg-error`](ui-icons.md#error-etaf-ui-svg-error) | `error` | SVG 场景辅助收到的输入非法。 |
| [`etaf-ui-markdown-error`](ui-composite-components.md#error-etaf-ui-markdown-error) | `error` | markdown 操作被拒绝：解析时方言名未知，或渲染时缺少调色板、调色板键未知。 |

## ETAF DB

| 条件 | 父条件 | 触发时机 |
| --- | --- | --- |
| [`etaf-sqlite-error`](sqlite-backend.md#error-etaf-sqlite-error) | `error` | SQLite 操作被拒绝时的基础条件；下面三个是它的子类。 |
| [`etaf-sqlite-schema-error`](sqlite-backend.md#error-etaf-sqlite-schema-error) | `etaf-sqlite-error` | 描述符或已初始化的数据库与声明的 schema 不符。 |
| [`etaf-sqlite-unavailable`](sqlite-backend.md#error-etaf-sqlite-unavailable) | `etaf-sqlite-error` | 这个 Emacs 构建没有 SQLite 支持。 |
| [`etaf-sqlite-commit-unknown`](sqlite-backend.md#error-etaf-sqlite-commit-unknown) | `etaf-sqlite-error` | 变更的提交结果无法确定。 |

## ETAF Posframe

| Condition | Parent | 触发条件 |
| --- | --- | --- |
| [`etaf-posframe-error`](posframe-panels.md#error-etaf-posframe-error) | `error` | 面板选项、锚点、尺寸或 `:border` plist 非法，或 frame 不是图形 frame。 |

