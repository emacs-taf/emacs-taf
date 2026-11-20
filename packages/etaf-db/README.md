# ETAF DB

[中文](README.zh-CN.md)

`etaf-db` provides database backends for the ETAF framework. SQLite is the only
currently implemented backend. It adapts Emacs' built-in SQLite support to
`etaf-data-source`; ETAF core continues to own Data Controllers and reactive state.

## Installation and use

Requires Emacs 29.1 or later with SQLite support and ETAF 0.2.1 or later.
For a checkout, add the repository root and ETAF's dependency roots to `load-path`,
then use `(require 'etaf-db)`. Package archives include the root entry and `lisp/`.
[`etaf-db.el`](etaf-db.el) documents the supported API. SQLite-specific
constructors retain the `etaf-sqlite-*` prefix because their schema and storage
arguments describe that backend.

```elisp
(require 'etaf-db)

(let* ((table (etaf-sqlite-table
               'items
               (list (etaf-sqlite-column :id "id" :type 'integer :primary t)
                     (etaf-sqlite-column :name "name" :type 'text))
               :id))
       (database (etaf-sqlite-database "~/items.sqlite" table)))
  (etaf-sqlite-initialize database)
  (let ((controller (etaf-data-controller
                     (etaf-sqlite-source database) :auto-load t)))
    (unwind-protect
        (message "%S" (etaf-value (etaf-data-items controller)))
      (etaf-data-stop controller))))
```

The SQLite backend owns schema validation, short-lived connections, pagination,
queries and synchronous mutations. Its source uses the existing ETAF Data Source
contract. There is no separate database controller, ORM or backend dispatch protocol.
Non-database integrations can implement the same source contract independently.

See [the SQLite backend chapter](https://etaf.top/sqlite-backend/) of the ETAF Reference Manual for supported queries, writes and lifecycle,
including the optional `:mutate-v2 t` source capability.

## Development

Run `make setup-hooks` after cloning. `make structure-check` is the fast structure
and API boundary gate. `make check EMACS=/path/to/emacs` adds compilation,
entry validation and the public scenarios in [tests/acceptance.json](tests/acceptance.json).
`make test` runs those same correctness scenarios. GUI and performance acceptance
use the consuming examples' separate workflows.
