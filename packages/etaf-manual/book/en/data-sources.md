# Data Sources

A Data Source is the storage-facing half of the data layer: one value that describes how to read and write records. It is deliberately passive — a plist of callbacks, not a reactive object and not a running request. The [Data Controllers](data-controllers.md) chapter defines the reactive owner that calls a source, keeps its items, status and selection, and publishes changes. This chapter defines the protocol and its capabilities, how to build and adapt a source, the standalone page loader and the in-memory source. [Asynchronous Model](async.md) defines the adapter a callback may return instead of a value.

## The source protocol

<!-- index: Data Source; capability; :load; :mutate; :mutate-batch; :item-key; :dispose; :provider -->

A Data source is an ordinary value carrying callbacks. Nothing runs until its owning Controller calls a capability, so constructing a source has no effect and reading its capabilities starts no work.

| Capability | Receives | Returns |
| --- | --- | --- |
| `:load` | QUERY, PAGE, PAGE-SIZE | a plist with at least `:items`, optionally `:total`, `:page` and `:page-size` |
| `:mutate` | OPERATION, PAYLOAD | the operation result; a normal return means the write is committed |
| `:mutate-v2` | OPERATION, PAYLOAD | a tagged outcome carrying `:certainty` and, for a committed write, `:result` |
| `:mutate-batch` | a list of `(OPERATION PAYLOAD)` pairs | one result per pair; a transactional backend applies the whole list atomically |
| `:item-key` | one item | the item's stable selection identity |
| `:dispose` | — | runs when the owning Controller stops, so the source can release external resources |

Only `:load` is required; every other capability is optional, and a Controller uses what the source has. `:provider` names the source in observation reports and defaults to `data`.

Load and mutation callbacks may return an `etaf-async` adapter instead of a value: the Controller starts it and resolves with the ordinary result ([Asynchronous Model](async.md)). A v1 mutation return means committed; a v2 outcome states its own certainty; a rejection, cancellation or timeout always leaves the certainty of an external write unknown, and reconciliation — not rollback — handles it (the [Reconciliation](reconciliation.md) chapter).

A source holds no state of its own and has exactly one owning Controller. The Controller owns disposal: stopping it runs `:dispose` once.

## Creating a source

<!-- index: etaf-data-source; capability validation -->

#### Function: etaf-data-source (&rest capabilities)

Create a Data source from callable CAPABILITIES.

**Arguments.** CAPABILITIES is a plist. `:load` is required and must be a function; `:mutate`, `:mutate-v2`, `:mutate-batch`, `:dispose` and `:item-key` are optional functions; `:provider` is an optional non-keyword symbol; `:name` is optional metadata.

**Semantics.** The callbacks capture the storage; the source itself only carries them. `:load` is called with QUERY, PAGE and PAGE-SIZE and returns the page. `:mutate` and `:mutate-v2` are called with OPERATION and PAYLOAD. `:mutate-batch` is called with a list of `(OPERATION PAYLOAD)` pairs and returns one result per pair. `:item-key` is called with one item. `:dispose` runs when the owning Controller stops. Any of these callbacks may return an `etaf-async` adapter. The values are validated once, here, so a non-function capability, a missing `:load` or a `:provider` that is not a non-keyword symbol is rejected before any data is touched.

**Returns.** The Data source.

**Errors.** `error→ wrong-type-argument` with data `(functionp VALUE)` when `:load` is missing or not a function, or when another capability is present and not a function; `error→ wrong-type-argument` with data `(symbolp PROVIDER)` when `:provider` is not a non-keyword symbol.

**Example.** `(etaf-data-source :load (lambda (query page page-size) (list :items (list query page page-size))) :provider 'demo)` builds a source whose page echoes its arguments.

**See also.** `etaf-data-source-capabilities`, `etaf-data-memory-source`.

## Capabilities and composition

<!-- index: etaf-data-source-capabilities; adapter; source ownership -->

#### Function: etaf-data-source-capabilities (source)

Return a fresh plist of SOURCE's supported capabilities for composition.

**Arguments.** SOURCE is a Data source.

**Semantics.** The returned plist contains only the entries SOURCE actually has, among `:load`, `:mutate`, `:mutate-v2`, `:mutate-batch`, `:dispose`, `:item-key`, `:provider` and `:name`. Callback and metadata values are the same objects, so a snapshot preserves the storage; replacing entries in the snapshot leaves SOURCE unchanged. Build an adapter by changing entries in the snapshot and passing the result to `etaf-data-source`: wrap `:load` in an asynchronous adapter, add `:mutate-v2` certainty, attach `:dispose`. Reading capabilities starts no work and transfers no ownership: the adapted source shares the same storage, and the underlying source must not be given to a second Controller.

**Returns.** A fresh capability plist.

**Errors.** `error→ wrong-type-argument` when SOURCE is not a Data source.

**Example.**

```elisp
(let* ((source (etaf-data-memory-source '((:id 1)) :id-key :id))
       (capabilities (etaf-data-source-capabilities source)))
  (list (eq (plist-get capabilities :load) (plist-get source :load))
        (plist-get capabilities :provider)))
;; ⇒ (t memory)
```

**See also.** `etaf-data-source`, `etaf-data-memory-source`.

## Loading a page without a Controller

<!-- index: etaf-data-source-load-page; page contract; normalization -->

#### Function: etaf-data-source-load-page (source &optional query page page-size)

Load and normalize one SOURCE page without creating a Controller.

**Arguments.** SOURCE is a Data source. QUERY is passed to `:load` unchanged. PAGE and PAGE-SIZE default to 1 and 20 and are clamped to at least 1.

**Semantics.** Calls `:load` once and normalizes the page: the result must be a plist that contains `:items`. The helper is the way to read initial data, to seed a Controller with `:initial-result`, or to test a source without reactive machinery. No reactive state is created and no observer is notified by the load itself. Only synchronous sources are supported here: an `etaf-async` return signals without starting the adapter, because only a Controller can own asynchronous work.

**Returns.** The normalized page plist.

**Errors.** `error→ etaf-async-error` with data `("Asynchronous sources require a Data Controller")` when `:load` returns an adapter; an error with message `"ETAF Data source load must return a plist: VALUE"` when the callback returns a non-plist; an error with message `"ETAF Data source load result lacks :items"` when the plist has no `:items`.

**See also.** `etaf-data-source`, `etaf-async`.

## The in-memory source

<!-- index: etaf-data-memory-source; in-memory records; query; mutation -->

#### Function: etaf-data-memory-source (items &key id-key name)

Create an in-memory Data source over ITEMS.

**Arguments.** ITEMS is the initial list of records; it is copied, so later changes to the caller's list do not reach the source. ID-KEY names the field that identifies a record for mutations and selection. NAME labels the source.

**Semantics.** The source keeps its records and serves them from its `:load`: it filters by QUERY, slices PAGE and PAGE-SIZE, and always returns `:items`, `:total`, `:page` and `:page-size`. Its provider is `memory`. Records are usually plists, but alists and hash tables work too, and a query reads fields through the record's own kind.

| Query | Selects |
| --- | --- |
| nil | every record |
| a function | records for which it returns non-nil, called with the record |
| a string | records whose printed form contains it, case-insensitively |
| a plist | records whose value for every keyword key equals the queried value |
| an alist | records whose value for every key equals the queried value |
| any other value | records `equal` to it |

The mutations the source supports are:

| Operation | Payload | Effect |
| --- | --- | --- |
| `insert` | one record | appends it |
| `replace`, `update` | one record | replaces the record with the same identity, or signals |
| `delete` | an identity | removes the record with that identity |
| `reset` | a list of records | replaces the whole list |

The identity of a record is its ID-KEY field, or the record itself when ID-KEY is nil; the source exposes it through `:item-key` so a Controller can compare selection identities.

**Returns.** The Data source.

**Errors.** An error with message `"No memory source record for id ID"` when `replace` or `update` finds no matching record; an error with message `"Unsupported memory source mutation: OPERATION"` for another operation; the record list is unchanged when either signals.

**Example.** The helper and the memory source compose into a complete read path: a case-insensitive query picks the records and the page arguments select part of the filtered list.

```elisp :run
(etaf-define-component demo-memory-page ()
  :bindings ((page (etaf-data-source-load-page
                    (etaf-data-memory-source
                     '((:name "Ada") (:name "Grace") (:name "Alan"))
                     :id-key :name)
                    "a" 1 2)))
  :view (column
          (text (expr (format "Total: %s" (plist-get page :total))))
          (text :for (item (plist-get page :items))
                :key (plist-get item :name)
                (expr (format "Row: %s" (plist-get item :name))))))
(etaf-view (demo-memory-page))
```

**See also.** `etaf-data-source`, `etaf-data-source-load-page`.

## Disposal and ownership

<!-- index: source ownership; :dispose; adapter -->

Each source has one owning Controller, and stopping that Controller runs the source's `:dispose` once. It is the only release hook, and the in-memory source has nothing to release and defines none. An adapted source shares the storage of the source it was composed from, so its ownership must stay single: give the underlying source to one Controller, and let an adapter that wraps it be that owner.

## Errors and recovery

| Invalid input | What happens |
| --- | --- |
| `:load` missing or not a function, or another capability not a function | `wrong-type-argument` from `etaf-data-source`; nothing was stored |
| `:provider` that is not a non-keyword symbol | `wrong-type-argument` from `etaf-data-source`; nothing was stored |
| A page that is not a plist, or a plist without `:items` | An error from `etaf-data-source-load-page`; the caller keeps its previous data |
| An asynchronous `:load` passed to `etaf-data-source-load-page` | `etaf-async-error`; the adapter did not start |
| A memory-source `replace` or `update` with no matching identity | An error; the record list is unchanged |
| An unknown memory-source operation | An error; the record list is unchanged |
