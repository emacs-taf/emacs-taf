# SQLite 后端

ETAF DB 把 Data Source 记录存进 SQLite。它的构造函数显式描述存储——带语义身份与物理 SQL 名的列、一张表、一个数据库文件——`etaf-sqlite-source` 把这份描述接到 Data Source 契约上，让 Data Controller 不写 SQL 就能读写。每次操作打开一条短连接，变更在事务里运行，可选的 v2 能力报告提交确定度。本章定义描述符、初始化与升级、source 与错误条件。[Data Source](data-sources.md)定义 source 实现的契约；[Data Controller](data-controllers.md)与[和解](reconciliation.md)定义消费者与确定度信封。[安装、加载与构建](installation-and-loading.md)讲 Emacs 自身的构建依赖。

## 存储模型

<!-- index: SQLite; 语义列; 物理名; 主键; 短连接 -->

数据库描述分三层：column 声明语义 ID、物理 SQL 名、类型与可空性；table 声明它的 ID、列与可选语义主键；database 把文件路径与 table 连起来。语义 ID 是应用看到的一切的键——加载的行、查询字段、变更载荷与 source 的 `:item-key`——物理名只存在于生成的 SQL 里。物理名在声明列时校验一次然后被引号包裹；它绝不来自运行时查询，因此值永远不会变成 SQL 文本。

列类型是 `integer`、`real`、`text`、`blob` 或 `any` 之一。table 的主键让表可写并给选择提供身份：`insert`、`replace`、`update`、`upsert` 与 `delete` 都需要它，没有主键的表拒绝变更。描述数据库不产生 I/O；只有初始化与 source 的操作会碰文件。每次操作打开一条连接、运行、关闭，因此长驻应用不会持有过期的句柄，Controller 仍是响应式状态与生命周期的所有者。

## 声明存储

<!-- index: etaf-sqlite-column; etaf-sqlite-table; etaf-sqlite-database -->

#### Function: etaf-sqlite-column (id sql-name &key (type 'any) nullable primary)

声明一个带语义 ID 与物理 SQL-NAME 的 SQLite 列。

**参数。** ID 是稳定的标量——符号、字符串或整数——作为该字段在行、查询与载荷里的键。SQL-NAME 是物理列名，匹配 `[A-Za-z_][A-Za-z0-9_]*` 的字符串。TYPE 是 `integer`、`real`、`text`、`blob` 或 `any`（默认）之一。NULLABLE 允许 SQL NULL。PRIMARY 把该列标为表的 SQL 主键；让同一个 ID 也作为 table 的 PRIMARY-KEY，source 才知道身份。

**语义。** 所有声明在这里一次性校验：不可用的 ID、不安全的 SQL-NAME 或不支持的类型，在碰任何文件之前就抛出。列值就是校验过的描述；它还没有进入任何表。

**返回。** 列描述。

**错误。** ID 不是稳定标量、SQL-NAME 不是安全标识符、或 TYPE 不是五种之一时 `error→ etaf-sqlite-schema-error`，消息点明违规处。

**示例。** `(etaf-sqlite-column :id "id" :type 'integer :primary t)` 声明一个语义键为 `:id` 的整数身份列。

**参见。** `etaf-sqlite-table`、`etaf-sqlite-database`。

#### Function: etaf-sqlite-table (id columns &optional primary-key)

用 COLUMNS 与可选 PRIMARY-KEY 语义 ID 声明表 ID。

**参数。** ID 是命名表的符号或字符串；它会成为物理表名。COLUMNS 是非空的列描述列表。PRIMARY-KEY 是身份列的语义 ID。

**语义。** 声明一次性校验整组：列 ID 与物理名必须各自唯一，物理名按大小写不敏感比较。PRIMARY-KEY 必须指向某一列；它把该列标为主键且非空，并成为 source 用于变更与选择的身份。没有主键的表可读但不可写。

**返回。** 表描述。

**错误。** ID 不是符号或字符串、COLUMNS 为空或含非法列、语义 ID 或物理名重复、或 PRIMARY-KEY 指不到已声明列时 `error→ etaf-sqlite-schema-error`。

**示例。** `(etaf-sqlite-table 'notes (list (etaf-sqlite-column :id "id" :type 'integer :primary t) (etaf-sqlite-column :title "title" :type 'text)) :id)` 声明一张可写表。

**参见。** `etaf-sqlite-column`、`etaf-sqlite-source`。

#### Function: etaf-sqlite-database (file table)

用带类型的 TABLE 元数据描述 SQLite FILE。

**参数。** FILE 是数据库文件的非空路径。TABLE 是表描述。

**语义。** 路径被展开成绝对名；不创建文件或目录，也不打开连接。该描述就是 `etaf-sqlite-initialize` 为其创建存储、`etaf-sqlite-source` 为其服务的那个值。

**返回。** 数据库描述。

**错误。** FILE 不是非空字符串、或 TABLE 不是表描述时 `error→ etaf-sqlite-schema-error`。

## 初始化数据库

<!-- index: etaf-sqlite-initialize; schema 升级; nullable 列迁移 -->

#### Function: etaf-sqlite-initialize (database)

在 DATABASE 的表不存在时创建它，并返回 DATABASE。

**参数。** DATABASE 是数据库描述。

**语义。** 初始化打开一条短连接（需要时创建文件所在目录），以声明的列、类型、主键与可空性运行 `CREATE TABLE IF NOT EXISTS`。表已存在时，它把描述与现实 schema 对齐：描述新获得的列只要可空就用 `ALTER TABLE` 原地添加，旧行读回 SQL NULL。缺失的主键列或声明为非空的列无法安全添加，改为抛出，让应用刻意迁移，而不是对着半匹配的表运行。初始化幂等，可以在每次启动时调用。

**返回。** DATABASE。

**错误。** 既有表缺主键或缺声明的非空列时 `error→ etaf-sqlite-schema-error`，消息点名列与迁移提示；当前 Emacs 没有 SQLite 支持时 `error→ etaf-sqlite-unavailable`。

**参见。** `etaf-sqlite-database`、`etaf-sqlite-source`。

## SQLite Data Source

<!-- index: etaf-sqlite-source; 查询; 变更; upsert; 事务; 提交确定度 -->

#### Function: etaf-sqlite-source (database &key mutate-v2)

返回由 DATABASE 支撑的 `etaf-data-source`。

**参数。** DATABASE 是数据库描述。MUTATE-V2 非 nil 时追加可选的 `:mutate-v2` 能力。

**语义。** 返回的 source 提供 `:load`、`:mutate` 与 `:mutate-batch`；表声明了主键时，把主键作为 `:item-key` 选择身份；provider 名为 `sqlite`。加载接受以语义列 ID 表示的等值 plist 或 alist 查询，为 `:total` 统计匹配行数，按页施加 `LIMIT` 与 `OFFSET`，有主键时按其排序，并把每行转成以语义 ID 为键的 plist。既不是 plist 也不是 alist、或点名表里没有的列的查询抛出 `etaf-sqlite-error`；生成的 SQL 只点名已声明的列，值一律绑定，绝不拼接。

变更操作是 `insert`、`replace`、`update`、`upsert` 与 `delete`。`insert` 写入载荷中出现的字段；`replace` 与 `update` 需要主键与至少一个字段，没有匹配行时抛出；`upsert` 插入该行或更新主键相同的既有行，是让存储与记录对齐的自然方式；`delete` 接受身份值，或含主键的载荷，没有匹配行时不抛出。变更结果携带操作、受影响行数，以及 `insert` 与 `upsert` 的身份。变更需要表的主键。

`:mutate-batch` 在一个事务里应用 `(OPERATION PAYLOAD)` 对列表并按序返回结果：某个操作抛出会让整批回滚并重新抛出，因此不会提交半批。启用 `:mutate-v2` 时，每次变更额外返回提交确定度：`committed` 加不透明 reconciliation token；body 失败且回滚成功时 `rolled-back`；提交、回滚或关闭连接让结果不确定时 `external-unknown`，此时原条件在 `:error`。每次操作使用自己的短连接；Controller 仍拥有响应式状态、发布与生命周期。

**返回。** 可供 `etaf-data-controller` 使用的 Data source。

**错误。** DATABASE 不是数据库描述时 `error→ wrong-type-argument`；查询或载荷错形、查询列未知、操作不支持、或 `replace`/`update` 没有匹配行时 `error→ etaf-sqlite-error`；表没有主键却尝试变更时 `error→ etaf-sqlite-schema-error`；Emacs 没有 SQLite 支持时 `error→ etaf-sqlite-unavailable`；批量或 v2 变更的提交结果未知时 `error→ etaf-sqlite-commit-unknown`。

**示例。** `(etaf-sqlite-source (etaf-sqlite-database "/tmp/notes.sqlite" table))` 是 controller 读写的 source；`(etaf-data-source-load-page source '(:done 0) 1 20)` 读取一页过滤结果。

**参见。** `etaf-sqlite-database`、`etaf-data-controller`、`etaf-sqlite-commit-unknown`。

## 错误与恢复

<!-- index: etaf-sqlite-error; etaf-sqlite-schema-error; etaf-sqlite-unavailable; etaf-sqlite-commit-unknown -->

#### Error: etaf-sqlite-error

消息为 "Invalid ETAF SQLite operation"。

**语义。** 表示操作无法执行：查询不是 plist 或 alist、查询字段表里没有声明、不支持的操作、载荷缺主键或没有任何字段、或 `replace`/`update` 没有匹配行。用 `condition-case` 捕获；抛出它的调用不返回值。它是下面三个更具体条件的父条件。

**恢复。** 失败的读不碰数据。失败的变更被它的事务回滚，表保留先前的行；修正查询或载荷后重跑。

**参见。** `etaf-sqlite-source`、`etaf-sqlite-schema-error`、`etaf-sqlite-commit-unknown`。

#### Error: etaf-sqlite-schema-error

消息为 "Invalid ETAF SQLite schema"。父条件为 `etaf-sqlite-error`。

**语义。** 表示描述非法——不可用的列 ID、不安全的物理名、不支持的类型、重复的 ID 或名、未知主键——或既有表与描述不符，例如初始化期间。声明被拒时不会创建或改动任何东西，半匹配的表也从不被默默接受。

**恢复。** 修正声明，或刻意迁移既有表：新增的可空列由初始化添加，而缺失的主键或非空列需要显式迁移后描述才成立。

**参见。** `etaf-sqlite-column`、`etaf-sqlite-table`、`etaf-sqlite-initialize`。

#### Error: etaf-sqlite-unavailable

消息为 "SQLite is unavailable"。父条件为 `etaf-sqlite-error`。

**语义。** 表示当前 Emacs 构建时没有 SQLite 支持，而某次操作需要连接。描述列、表与数据库不做这项检查，因为它不碰文件。

**恢复。** 使用带 SQLite 支持的 Emacs。包的构建说明描述原生依赖（[安装、加载与构建](installation-and-loading.md)）。

**参见。** `etaf-sqlite-initialize`、`etaf-sqlite-source`。

#### Error: etaf-sqlite-commit-unknown

消息为 "SQLite commit outcome is unknown"。父条件为 `etaf-sqlite-error`。

**语义。** 表示事务的提交、回滚或连接关闭让结果不确定，后端无法说明写入是否生效。数据包含失败阶段与底层条件。用 `condition-case` 捕获；抛出它的调用不返回值。

**恢复。** 不要假设回滚：把表读回来，让和解收敛页面。已提交但刷新失败的写可以按读取重试，而不是按写重放。

**参见。** `etaf-sqlite-source`、[和解](reconciliation.md)。

| 失败 | 还会剩下什么 |
| --- | --- |
| 声明非法 | `etaf-sqlite-schema-error`；不创建也不改动任何东西 |
| 初始化发现缺主键或缺非空列 | `etaf-sqlite-schema-error`；表保持原样 |
| 查询点名未知列，或不是 plist/alist | `etaf-sqlite-error`；不运行 SQL |
| 变更载荷缺所需字段 | `etaf-sqlite-error`；事务回滚 |
| `replace` 或 `update` 没有匹配行 | `etaf-sqlite-error`；事务回滚 |
| 批量中某个操作抛出 | 整批回滚；条件重新抛出 |
| 提交、回滚或关闭结果不确定 | `etaf-sqlite-commit-unknown`；调用方把表读回来而不是假设 |
| Emacs 没有 SQLite | `etaf-sqlite-unavailable`；不碰任何文件 |
