# Changelog

## Unreleased

### Removed

- The package manual `docs/manual.md` is replaced by [the SQLite backend chapter](https://etaf.top/sqlite-backend/) of the ETAF Reference Manual, which the README and the package Commentary link.

### Added

- The SQLite source exposes an atomic `:mutate-batch' capability: one
  transaction for a whole `(OPERATION PAYLOAD)` list, one result per operation,
  and a full rollback when an operation signals.  `etaf-data-mutate-many'
  consumes it and reconciles the Controller once for the batch.
- `etaf-sqlite-initialize` reconciles an existing table with its descriptor:
  missing nullable columns are added in place, while a missing primary or
  declared non-nullable column signals `etaf-sqlite-schema-error' so schema
  evolution cannot silently run against a half-matching table.

### Changed

- The package entry is now `etaf-db`, matching the repository and its role as
  ETAF's database backend package. SQLite is the only implemented backend.
  Replace `(require 'etaf-sqlite)` with `(require 'etaf-db)` and use `etaf-db`
  in package dependencies and installation recipes. SQLite-specific
  `etaf-sqlite-*` constructors and errors keep their existing contracts.
  The old `etaf-sqlite.el` entry is removed; no compatibility loader is provided.
