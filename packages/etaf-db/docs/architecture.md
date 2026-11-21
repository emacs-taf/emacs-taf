# ETAF DB Architecture

This document is the maintainer contract for the implemented database layer.  It
explains ownership, dependency direction, data flow and invariants.  User
recipes live in the [ETAF Reference Manual](https://etaf.top/sqlite-backend/);
the authoritative public API list is the Commentary of
[`../etaf-db.el`](../etaf-db.el).

## 1. Responsibility and boundary

`etaf-db` adapts a database to the ETAF Data Source contract.  SQLite is the
only implemented backend.  The package owns:

- table and column descriptors, including semantic IDs and physical SQL names;
- schema creation and in-place column reconciliation;
- short-lived connections, queries, pagination and mutations;
- transaction results, including the ambiguity of an unknown commit.

It does not own Data Controllers, reactive state, list caches or application
storage policy.  Those stay in ETAF core and in the application.  There is no
second controller, no ORM and no backend dispatch protocol: a non-database
integration implements the same `etaf-data-source` contract on its own.

```text
sqlite (Emacs built-in)
        ↓
   etaf-db source  →  etaf-data-source contract  →  etaf-data controller
                                                        ↓
                                                   application
```

`etaf-db` depends only on Emacs with SQLite support and on ETAF for the public
Data Source contract.  ETAF does not depend on `etaf-db`; an application that
does not use SQLite never loads it.

## 2. Descriptor model

A database is described by three plain records:

| Record | Facts |
| --- | --- |
| Column | semantic ID, physical SQL name, type, nullability, primary flag |
| Table | semantic ID, columns, primary key ID, column index |
| Database | file name, table |

Semantic IDs are what ETAF payloads and rows use; physical names are what SQL
receives.  Both are validated once when the descriptor is built, so no runtime
query can inject an identifier.  The primary key is a semantic column ID and is
required for `replace`, `update` and `delete`.

Rows returned to callers are plists keyed by the semantic IDs, not by SQL column
names.  A payload is filtered to the declared columns of its table; a value for
an undeclared column is not written.

## 3. Schema lifecycle

`etaf-sqlite-initialize` creates the table when it is absent and returns the
database.  When the table exists, columns the descriptor has gained are added
in place only if they are nullable.  A missing primary column, a changed type or
a declared non-nullable column that the table lacks signals
`etaf-sqlite-schema-error`.  The check runs before any write, so a mismatched
descriptor never leaves a half-migrated table.

## 4. Connections and transactions

Every read and every mutation opens a short-lived connection and closes it in an
`unwind-protect`, including on `throw` and quit.  No connection, statement or
cursor is retained between calls, so a source can be used from any buffer and a
crashed caller cannot pin a handle.

One mutation runs in one transaction.  A batch runs all its operations in one
transaction and returns one result per operation; a signaled operation rolls the
whole batch back.  When the transaction body fails, the rollback is attempted
and the original condition is re-signaled.  When the outcome cannot be known
(commit or rollback fails), the call signals `etaf-sqlite-commit-unknown` with
the failure phase instead of claiming success or failure.  A cleanup failure
after a committed mutation also reports the unknown outcome; a cleanup failure
after a failed body keeps the body's condition.

## 5. Source capabilities

The source accepts equality queries over declared columns and returns rows in a
stable order for pagination.  It exposes:

- `:item-key` as the primary key, so a Data Controller can reconcile items;
- `insert`, `replace`, `update`, `upsert` and `delete` mutations;
- `:mutate-batch` for an atomic list of operations;
- `:mutate-v2` when requested, which carries reconciliation tokens.

`upsert` inserts a row or updates the row with the same primary key.  `replace`
and `update` signal when the identity is missing, and `delete` requires it.
Mutation results report the operation, the affected row count and the identity
when applicable.

## 6. Invariants

- SQL identifiers come only from validated descriptors.
- Payloads write only declared columns; rows read only declared columns.
- Every call uses a fresh short-lived connection.
- Every mutation has one transaction; a batch is all-or-nothing.
- A commit whose outcome is unknown is reported as such, never as success.
- The package returns data and errors; it never mounts a View or holds reactive
  state.  Data Controllers and list caches remain in ETAF and the application.

## 7. Failure semantics

`etaf-sqlite-error` is the base condition.  `etaf-sqlite-schema-error` reports a
schema mismatch, `etaf-sqlite-unavailable` reports an Emacs without SQLite, and
`etaf-sqlite-commit-unknown` reports a transaction whose outcome could not be
determined.  Failed operations signal instead of returning partial data; the
caller decides whether to retry, reload or surface the error.
