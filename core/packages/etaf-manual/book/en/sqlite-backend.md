# SQLite Backend

ETAF DB stores Data Source records in SQLite. Its constructors describe the storage explicitly — columns with semantic identities and physical SQL names, one table, one database file — and `etaf-sqlite-source` adapts that description to the Data Source contract, so a Data Controller can read and write it without writing SQL. Every operation opens a short-lived connection, mutations run in transactions, and the optional v2 capability reports commit certainty. This chapter defines the descriptors, initialization and upgrade, the source, and the error conditions. [Data Sources](data-sources.md) defines the contract the source implements; [Data Controllers](data-controllers.md) and [Reconciliation](reconciliation.md) define the consumers and the certainty envelope. [Installation, Loading and Building](installation-and-loading.md) covers the build-time requirements of Emacs itself.

## The storage model

<!-- index: SQLite; semantic column; physical name; primary key; short connection -->

A database description is three layers: a column declares a semantic ID, a physical SQL name, a type and its nullability; a table declares its ID, its columns and the optional semantic primary key; a database joins a file path with a table. The semantic IDs are the keys of everything the application sees — loaded rows, query fields, mutation payloads and the source's `:item-key` — while the physical names exist only inside the generated SQL. A physical name is validated once when the column is declared and then quoted; it never comes from a runtime query, so a value can never become SQL text.

A column type is one of `integer`, `real`, `text`, `blob` or `any`. The table's primary key is what makes a table writable and gives selection its identity: `insert`, `replace`, `update`, `upsert` and `delete` require it, and a table without one rejects mutations. Declaring a database performs no I/O; only initialization and the source's operations touch the file. Each operation opens a connection, runs, and closes it, so a long-lived application never holds a stale handle and a controller remains the owner of reactive state and lifecycle.

## Declaring storage

<!-- index: etaf-sqlite-column; etaf-sqlite-table; etaf-sqlite-database -->

#### Function: etaf-sqlite-column (id sql-name &key (type 'any) nullable primary)

Declare a SQLite column with semantic ID and physical SQL-NAME.

**Arguments.** ID is a stable scalar — a symbol, string or integer — used as the field's key in rows, queries and payloads. SQL-NAME is the physical column name, a string matching `[A-Za-z_][A-Za-z0-9_]*`. TYPE is one of `integer`, `real`, `text`, `blob` or `any` (the default). NULLABLE allows SQL NULL values. PRIMARY marks the column as the table's SQL primary key; name the same ID as the table's PRIMARY-KEY so the source knows the identity.

**Semantics.** All declarations are validated here, once: an unusable ID, an unsafe SQL-NAME or an unsupported TYPE signals before any file is touched. The column value is the validated description; it is not yet part of a table.

**Returns.** The column description.

**Errors.** `error→ etaf-sqlite-schema-error` with a message naming the violation when ID is not a stable scalar, SQL-NAME is not a safe identifier, or TYPE is not one of the five types.

**Example.** `(etaf-sqlite-column :id "id" :type 'integer :primary t)` declares an integer identity column whose semantic key is `:id`.

**See also.** `etaf-sqlite-table`, `etaf-sqlite-database`.

#### Function: etaf-sqlite-table (id columns &optional primary-key)

Declare table ID from COLUMNS and optional PRIMARY-KEY semantic ID.

**Arguments.** ID is a symbol or string naming the table; it becomes the physical table name. COLUMNS is a non-empty list of column descriptions. PRIMARY-KEY is the semantic ID of the identity column.

**Semantics.** The declaration validates the whole set at once: column IDs and physical names must each be unique, with physical names compared case-insensitively. PRIMARY-KEY must name one of the columns; it marks that column primary and non-null and becomes the identity the source uses for mutations and selection. Without a primary key the table is readable but not writable.

**Returns.** The table description.

**Errors.** `error→ etaf-sqlite-schema-error` when ID is not a symbol or string, COLUMNS is empty or contains an invalid column, a semantic ID or physical name repeats, or PRIMARY-KEY names no declared column.

**Example.** `(etaf-sqlite-table 'notes (list (etaf-sqlite-column :id "id" :type 'integer :primary t) (etaf-sqlite-column :title "title" :type 'text)) :id)` declares a writable table.

**See also.** `etaf-sqlite-column`, `etaf-sqlite-source`.

#### Function: etaf-sqlite-database (file table)

Describe SQLite FILE using typed TABLE metadata.

**Arguments.** FILE is the nonempty path of the database file. TABLE is a table description.

**Semantics.** The path is expanded to an absolute name; no file or directory is created and no connection is opened. The description is the value `etaf-sqlite-initialize` creates the storage for and `etaf-sqlite-source` serves.

**Returns.** The database description.

**Errors.** `error→ etaf-sqlite-schema-error` when FILE is not a nonempty string or TABLE is not a table description.

## Initializing the database

<!-- index: etaf-sqlite-initialize; schema upgrade; nullable column migration -->

#### Function: etaf-sqlite-initialize (database)

Create DATABASE's table if it does not exist and return DATABASE.

**Arguments.** DATABASE is a database description.

**Semantics.** Initialization opens a short-lived connection, creating the file's directory when needed, and runs `CREATE TABLE IF NOT EXISTS` with the declared columns, types, primary key and nullability. When the table already exists it reconciles the descriptor against the physical schema: a column the descriptor has gained is added in place with `ALTER TABLE` as long as it is nullable, so old rows read back with SQL NULL. A missing primary column or a missing declared non-nullable column cannot be added safely and signals instead, so the application migrates deliberately rather than running against a half-matching table. Initialization is idempotent and may be called on every start.

**Returns.** DATABASE.

**Errors.** `error→ etaf-sqlite-schema-error` when an existing table lacks its primary or a declared non-nullable column, with a message naming the column and the migration hint; `error→ etaf-sqlite-unavailable` when the running Emacs has no SQLite support.

**See also.** `etaf-sqlite-database`, `etaf-sqlite-source`.

## The SQLite Data source

<!-- index: etaf-sqlite-source; query; mutation; upsert; transaction; commit certainty -->

#### Function: etaf-sqlite-source (database &key mutate-v2)

Return an `etaf-data-source` backed by DATABASE.

**Arguments.** DATABASE is a database description. MUTATE-V2 non-nil adds the opt-in `:mutate-v2` capability.

**Semantics.** The returned source exposes `:load`, `:mutate` and `:mutate-batch`, its primary key as the `:item-key` selection identity when the table declares one, and the provider name `sqlite`. Loading accepts equality queries as a plist or alist over semantic column IDs, counts the matching rows for `:total`, applies `LIMIT` and `OFFSET` for the page, orders by the primary key when there is one, and converts each row to a plist keyed by the semantic IDs. A query that is neither a plist nor an alist, or that names a column the table does not have, signals `etaf-sqlite-error`; the generated SQL only ever names declared columns, and values are bound, never interpolated.

The mutations are `insert`, `replace`, `update`, `upsert` and `delete`. `insert` writes the payload's present fields; `replace` and `update` require the primary key and at least one field and signal when no row matches; `upsert` inserts the row or updates the existing one with the same primary key, which is the natural way to make the store match a record; `delete` takes the identity value or a payload containing the primary key and does not signal when no row matches. A mutation result carries the operation, the affected row count, and the identity for `insert` and `upsert`. Mutations require the table's primary key.

`:mutate-batch` applies a list of `(OPERATION PAYLOAD)` pairs in one transaction and returns their results in order: a signaled operation rolls the whole batch back and is re-signaled, so no partial batch is committed. When `:mutate-v2` is enabled, each mutation additionally returns commit certainty: `committed` with an opaque reconciliation token, `rolled-back` when the body failed and the rollback succeeded, and `external-unknown` when a commit, rollback or connection close leaves the outcome undetermined — in which case the original condition is in `:error`. Every operation uses its own short connection; the controller still owns reactive state, publication and lifecycle.

**Returns.** A Data source ready for `etaf-data-controller`.

**Errors.** `error→ wrong-type-argument` when DATABASE is not a database description; `error→ etaf-sqlite-error` for a malformed query or payload, an unknown query column, an unsupported operation, or a `replace`/`update` with no matching row; `error→ etaf-sqlite-schema-error` when the table has no primary key and a mutation is attempted; `error→ etaf-sqlite-unavailable` when Emacs has no SQLite support; `error→ etaf-sqlite-commit-unknown` when a batch's or v2 mutation's commit outcome is unknown.

**Example.** `(etaf-sqlite-source (etaf-sqlite-database "/tmp/notes.sqlite" table))` is the source a controller reads and writes; `(etaf-data-source-load-page source '(:done 0) 1 20)` reads one filtered page.

**See also.** `etaf-sqlite-database`, `etaf-data-controller`, `etaf-sqlite-commit-unknown`.

## Errors and recovery

<!-- index: etaf-sqlite-error; etaf-sqlite-schema-error; etaf-sqlite-unavailable; etaf-sqlite-commit-unknown -->

#### Error: etaf-sqlite-error

Invalid ETAF SQLite operation.

**Semantics.** Signals that an operation cannot be carried out: a query that is not a plist or alist, a query field the table does not declare, an unsupported mutation operation, a payload without the primary key or without any field, or a `replace`/`update` that matched no row. Catch it with `condition-case`; failed calls do not return a value. It is the parent of the three more specific conditions below.

**Recovery.** A failed read leaves the data untouched. A failed mutation is rolled back by its transaction, so the table keeps its previous rows; fix the query or payload and run it again.

**See also.** `etaf-sqlite-source`, `etaf-sqlite-schema-error`, `etaf-sqlite-commit-unknown`.

#### Error: etaf-sqlite-schema-error

Invalid ETAF SQLite schema. Its parent condition is `etaf-sqlite-error`.

**Semantics.** Signals that a description is invalid — an unusable column ID, an unsafe physical name, an unsupported type, a duplicate ID or name, an unknown primary key — or that an existing table does not match the descriptor, as during initialization. Nothing is created or altered when a declaration is rejected, and a half-matching table is never silently accepted.

**Recovery.** Fix the declaration, or migrate the existing table deliberately: a gained nullable column is added by initialization, while a missing primary or non-nullable column needs an explicit migration before the descriptor fits.

**See also.** `etaf-sqlite-column`, `etaf-sqlite-table`, `etaf-sqlite-initialize`.

#### Error: etaf-sqlite-unavailable

SQLite is unavailable. Its parent condition is `etaf-sqlite-error`.

**Semantics.** Signals when the running Emacs was built without SQLite support and an operation needs a connection. Describing columns, tables and databases performs no such check, because it touches no file.

**Recovery.** Use an Emacs with SQLite support. The package's build instructions describe the native requirements ([Installation, Loading and Building](installation-and-loading.md)).

**See also.** `etaf-sqlite-initialize`, `etaf-sqlite-source`.

#### Error: etaf-sqlite-commit-unknown

SQLite commit outcome is unknown. Its parent condition is `etaf-sqlite-error`.

**Semantics.** Signals when a transaction's commit, its rollback or the closing of its connection left the outcome undetermined, so the backend cannot say whether the write took effect. The data includes the failure phase and the underlying condition. Catch it with `condition-case`; failed calls do not return a value.

**Recovery.** Do not assume a rollback: read the table back, and let reconciliation settle the page. A committed write whose refresh failed can be retried as a read, not as a write.

**See also.** `etaf-sqlite-source`, [Reconciliation](reconciliation.md).

| Failure | What remains |
| --- | --- |
| A declaration is invalid | `etaf-sqlite-schema-error`; nothing is created or altered |
| Initialization finds a missing primary or non-nullable column | `etaf-sqlite-schema-error`; the table is left as it was |
| A query names an unknown column or is not a plist/alist | `etaf-sqlite-error`; no SQL runs |
| A mutation payload lacks the required fields | `etaf-sqlite-error`; the transaction rolls back |
| `replace` or `update` matches no row | `etaf-sqlite-error`; the transaction rolls back |
| A batch operation signals | The whole batch rolls back; the condition is re-signaled |
| A commit, rollback or close is uncertain | `etaf-sqlite-commit-unknown`; the caller reads the table back instead of assuming |
| Emacs lacks SQLite | `etaf-sqlite-unavailable`; no file is touched |
