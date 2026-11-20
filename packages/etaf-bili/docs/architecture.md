# ETAF Bili architecture

## Ownership

| Module | Responsibility |
| --- | --- |
| `etaf-bili-service` | Bilibili API and cookie protocol, WBI signing, bounded curl requests and atomic cover downloads |
| `etaf-bili-model` | Library, selection, request identities and status refs; headless actions |
| `etaf-bili-views` | Pure grid geometry and catalog composition: Card, SearchField, Tabs, Badge, Skeleton and metadata |
| `etaf-bili-theme` | Two palettes and the catalog theme-token projection |
| `etaf-bili-app` | Buffer lifecycle, viewport synchronization, visible-cover scheduling and modal composition |

The native Image Host owns image preparation and drawing; the application
only supplies the local source, cell bounds and fractional-row inset.
MediaViewer owns playback controls and the native video Component owns
stream decoding. Applications never call Ebox internals.

## Publication and layout

The shell is a normal-flow column: one spacing row, a three-row header, one
spacing row, a three-row navigation band, the gallery and a three-row footer.
The footer includes a padding row above and below its controls. There is no
overdraw allowance, off-canvas filler stripe or frame-wide background change.

The authoritative usable width comes from `etaf-runtime-window-viewport`
(or the committed canvas viewport in batch), not raw `window-body-width`.
A full-line display space exceeding the canvas's usable width can disappear
at redisplay, exposing the user's frame background. The initial mount is
conservative and immediately adopts the first measured viewport.

Grid columns follow available width; card dimensions also respect available
height. The content measure is capped, with one to four columns. A native
scroll Host owns the sole scroll offset. Its `:on-scroll` callback projects
the observed row into a virtual window, with neighboring rows overscanned;
leading and trailing spacers preserve the full scroll extent. Scrolling
within a row reuses the native cached lines. Keyboard selection uses the
public scroll API, then focuses the card after its publication commits.
Images are not forced to the rounded cell aspect:
the source ratio determines image width and exact pixel height, and `:inset`
accounts for the last partial row. Rendering reads cached image dimensions;
file access and network work stay outside the View.

## Catalog and animation

The gallery composes catalog Cards rather than painting a wide text list.
SearchField owns editing and its query draft; Tabs own channel selection;
Drawer and MediaViewer own modal input; Alert and Empty own failure feedback.
Application keys are declared once through ETAF `:keys`; there is no competing
emulation keymap to swallow modal or input keys.

Each mounted card reads the shared selection through a computed boolean and
owns a short `etaf-transition` for its accent fill, quantized to eight steps. A pending-operation
component owns an `etaf-animation-frames` source. Scopes release both on
unmount, and the framework's reduced-motion switch applies. Motion never
adds a delay before a network request or controls media time.

## Requests and covers

List and playback requests have separate generation tokens. Newer requests
invalidate older replies; disposed sessions cannot publish or reopen a viewer.
An explicit `:ok nil` is an empty success, not an error. Duplicate video IDs
are normalized before rendering keyed siblings.

A session prepares stable cover refs before publishing the library. Only the
visible virtual window enters the cover queue, capped at three concurrent transfers.
Files are installed atomically after successful curl completion; failed
partial files are deleted. A cover failure retains a placeholder and does
not prevent playback. Closing the application cancels its cover processes.

The per-request curl deadline bounds remote operations. Both process streams
are drained with zero-timeout reads before settlement; stderr's pipe sentinel
cannot insert process-status prose into the backend diagnostic.

## Validation

Public acceptance covers model races, empty success, mounted catalog targets,
native input, continuous scrolling, modal dismissal, frame preservation and the cover
transport using an offline curl fixture. The GUI adapter separately checks
real covers and viewport geometry and produces screenshots for visual review.
The appearance workload is registered with the workspace performance driver;
measurements, rather than UI composition alone, determine latency claims.
