# Storage Strategy

The data layer gives an application four places to keep state, and choosing well is mostly a question of lifetime and ownership. This closing chapter of the part compares them, shows how the pieces compose — keys, queries, pagination, refresh, failure — and lists what to do at migration and disposal. It defines no new interface: every mechanism it names is defined in the chapters it links.

## Four places for application state

<!-- index: storage choice; application state; persistence -->

| Where | Lifetime | Source of truth | Fits |
| --- | --- | --- | --- |
| Component refs and Context ([Reactivity](reactivity.md#refs), [Context](context.md)) | The instance's Scope | The application itself | Screen state: expansion, input, temporary selection |
| A Resource ([Resource](resources.md)) | One Scope, such as a Component | An external loader | One asynchronous value: configuration, the current user, a snapshot |
| An in-memory Data Source with a Controller ([Data Sources](data-sources.md#the-in-memory-source), [Data Controllers](data-controllers.md)) | The Controller's Scope | The application process, lost on exit | Session lists: search results, a local index |
| A SQLite Source with a Controller ([SQLite Backend](sqlite-backend.md#the-sqlite-data-source)) | The database file | The database, through committed transactions | Data that must persist, be queried or respect constraints |

Four questions choose between them: how long the value must live, who owns it, whether it must survive a restart, and whether it must be queried, counted or paged rather than merely displayed.

## Choosing by lifetime and ownership

<!-- index: Component state; Runtime state; source ownership -->

State that only one Component instance uses and that should die with it belongs in its refs and `:bindings`; their lifecycle is the instance's Scope ([Components](components.md#setup-bindings-and-state)). State several parts of one mounted tree share belongs somewhere the Runtime owns, so it is disposed with the tree rather than kept alive by a closure ([Runtime](runtime.md)). A value produced outside the application — and therefore possibly asynchronous — belongs in a Resource, whose status, value and error are the single reader's whole state ([Resource](resources.md#the-resource-model)). A list the application itself owns for the session belongs in an in-memory source and a Controller; when the same list must survive a restart or be queried by the database, replace the source with the SQLite one and keep the Controller code unchanged ([SQLite Backend](sqlite-backend.md#the-sqlite-data-source)).

A cache is never the truth by design: it is a display shortcut whose policy decides when to compare an old copy with a fresh reply ([List Cache](list-cache.md#the-cache-model)). Keep the backend's answer authoritative and let the cache only shorten the time before something is on screen.

Ownership must stay single. One Controller owns one source and runs its `:dispose`; an adapter built from `etaf-data-source-capabilities` shares the storage of the source it was composed from, so do not hand the underlying source to a second Controller ([Data Sources](data-sources.md#capabilities-and-composition)). When the owner goes away — an unmounted Component, a stopped session — the Controller stops with it and the source releases what it held.

## Keys, queries and pagination

<!-- index: identity; item key; query; pagination -->

Every record a user can select needs a stable identity: `:id-key` on an in-memory source, the primary key of a SQLite table, exposed to the Controller as `:item-key` ([Data Controllers](data-controllers.md#selection)). Selection stores identities, not list positions, so selecting a row and then loading another page does not point at the wrong item; `etaf-data-selected-item` only finds an identity on the current page, which is deliberate — a selection may outlive the page it was made on.

Queries express equality only, and their shape decides what a source can do: the in-memory source accepts a predicate, a search string, a plist, an alist, an exact value or nil, while the SQLite source translates plist and alist equality into bound `WHERE` clauses ([Data Sources](data-sources.md#the-in-memory-source), [SQLite Backend](sqlite-backend.md#the-sqlite-data-source)). Anything more selective than equality belongs in a custom source capability or in code that runs after the load. Pagination is Controller state: query, page and page size live in refs, `:auto-load` reloads when any of them changes, and without it the application calls `etaf-data-load` explicitly ([Data Controllers](data-controllers.md#queries-and-pagination)). The source decides what a page means, so the cache, the page size and the total come from the same reply.

## Refresh and uncertainty

<!-- index: keep-value; auto-load; background revalidation; certainty -->

A refresh should not blank the screen. With `:keep-value` a Resource keeps its last successful value while a reload runs, and publishes the replacement only when it arrives; without it the value is cleared immediately ([Resource](resources.md#loading-and-reloading)). A Controller always retains its accepted items through a refresh, an error and a cancellation ([Data Controllers](data-controllers.md#the-controller-model)). A slow list that is requested often can be shown from a cache at once and compared in the background; the cache's interval, grace, backoff and stop codes keep that revalidation polite ([List Cache](list-cache.md#choosing-the-next-refresh)).

Writes are the part that cannot be refreshed into certainty. A v1 source that returns normally is committed and reconciled by one reload; a v2 source states its certainty; a rejection, cancellation or timeout leaves the outcome unknown, and the only safe recovery is to read again, never to replay the write ([Reconciliation](reconciliation.md#uncertain-external-results)). A committed write whose refresh failed is retried as a read through `etaf-data-retry-reconciliation`; a rolled-back or unknown write is not retried by the framework at all.

## Migration and disposal

<!-- index: schema migration; disposal; ownership transfer -->

Persistent storage changes over time. A descriptor that gains a nullable column is migrated in place when `etaf-sqlite-initialize` runs; a missing primary or non-nullable column signals so the application performs an explicit migration instead of running against a half-matching table ([SQLite Backend](sqlite-backend.md#initializing-the-database)). Disposal is the mirror image of construction: `etaf-data-stop` ends a Controller's Scope, cancels its pending work and runs the source's `:dispose`; a Resource is disposed with its owner or explicitly; a list cache is disarmed when its session ends. Disposing a source while a Controller still reads it is a bug in ownership, not in the data layer.

## Errors and recovery

| Situation | What to do |
| --- | --- |
| A write signals or reports `rolled-back` | The store is unchanged; fix and rerun the write |
| A write's outcome is `external-unknown` | Do not replay it; read the data back and let reconciliation settle the page |
| A committed write's refresh failed | Retry reconciliation, which reloads without replaying the write |
| A schema no longer matches the file | Run an explicit migration; initialization adds only nullable columns |
| A background refresh fails repeatedly | The cache backs off, or pauses for a human on a stop code |
| The owner Scope is disposed | The Controller stops and the source is disposed; do not reuse either |
