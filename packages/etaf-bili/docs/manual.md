# ETAF Bili manual

## Discover and search

Run `M-x etaf-bili-open`. The popular feed loads asynchronously into a cover
card gallery. Click the channel tabs or press `1`/`2` for popular videos and
the ranking. `/` starts editing the rounded search field in the page; text,
Chinese input, undo and selection use the catalog's native editing session.
Return submits. Escape keeps the draft without running a search.

Each card shows a proportionally fitted cover, duration, title, creator, view
count and publication date. Wide windows show more columns; shorter windows
use a smaller cover area. The main grid has a maximum reading width rather
than stretching every card across the frame. The minimum usable content area
is 64 columns by 28 lines. Below it the interface clips deliberately.

The wheel or trackpad scrolls continuously through the loaded results; there
are no page controls. Arrow keys move through the grid and `n`/`p` move
sequentially, scrolling the selected card into view when necessary.
`j`/`k` are sequential shortcuts only under the default direction scheme;
with ETAF's Vim direction scheme they retain direction semantics.

The details action (`i`) opens a Drawer. Escape closes it and restores focus.
The metadata does not occupy a permanently empty sidebar. `?` lists the
actual declared bindings and `M-g` selects the search, channel or video region.

## Loading and motion

The first request shows geometry-matched Skeleton cards. A scoped frame
animation marks pending work; selecting another card animates its accent
fill for 160 ms. Neither waits before sending a request. Animations belong
to Component scopes and stop when the component disappears or the app closes.
Set `etaf-animation-enabled` to nil for reduced motion.

A failed request shows an Alert and retry action; an empty successful search
shows an Empty component, not the previous results. Late list or playback
responses cannot replace a newer request. Closing the buffer makes outstanding
callbacks inert and releases its cover transfers and animation scopes.

Only visible card rows and a small overscan window are mounted and request
covers, with at most three concurrent transfers. The image CDN download is capped at 2 MiB per file and atomically
installed under `etaf-bili-state-directory/covers/`. Failed images show a
placeholder without blocking video playback. Native image dimensions are read
once outside rendering. Each cover is contained at its original aspect ratio;
partial image rows use the Image Host's inset instead of distorting the image.

## Playback

Press Return on a card or activate its play button. The service first resolves
video metadata and then a progressive stream, with the Referer and User-Agent
headers required by the CDN. The catalog MediaViewer opens in the same buffer.
Space plays/pauses, arrows seek, `m` toggles sound, `.` cycles speed, and `n`/`p`
resolve the adjacent video. Escape or `q` closes the viewer, not the library.

The server controls availability, quality and URL expiry. This client does not
implement account libraries, comments, danmaku or paid-content access. Reopen
playback to resolve an expired stream. No permanent stream URL is saved.

## Signing in

The header's account chip reads 「登录」 while nobody is signed in and shows the
signed-in name afterwards. Activating it, or `M-x etaf-bili-login`, paints the
site's sign-in code inside an `etaf-ui-qr-login` panel mounted with the client:
the library stays visible, dims once and keeps its scroll position, and the
covered controls stay blocked until the panel closes. Escape, the header `x`
and the panel's cancel button dismiss it and stop polling.

Confirm the scan in the Bilibili app; the panel then closes, the account chip
updates and the current feed reloads with the new permissions. A code expires
after `etaf-bili-login-timeout` seconds (180 by default) and the panel reports
it; press the chip again for a fresh code. Polling follows
`etaf-bili-login-poll-interval`.

Only the code method is offered. Bilibili answers its SMS endpoint with a
graphical captcha that a terminal cannot answer, so a phone-number tab could
never complete. `M-x etaf-bili-account` reports which account the stored cookies
belong to, and `M-x etaf-bili-logout` asks for confirmation, clears them and
returns the chip to 「登录」.

Requests go through `backends/bili/bili.mjs`, which reads and writes the same
`cookies.txt` the HTTP client uses. `etaf-bili-backend-command` replaces that
command prefix; the public suite injects a stand-in script through it.

## Integration

The root Commentary documents session and client interfaces. A client may be a
function accepting `(REQUEST CALLBACK)`, returning `(:ok DATA)` or
`(:error MESSAGE :hint HINT)` through the callback. Tests use that injection
point without touching the network. A `:cover` request returns a local image
path; a fake client may return an error to exercise placeholders.

Session actions are asynchronous; consume a result in its callback rather
than assuming a load has completed in the next form:

```elisp
(let ((client (etaf-bili-make-client)))
  (etaf-bili-client-call
   client '(:op :search :keyword "Emacs 配置")
   (lambda (reply)
     (message "%s" (if (plist-member reply :ok)
                       (format "%d results" (length (plist-get reply :ok)))
                     (plist-get reply :error))))))
```

`etaf-bili-session-state` returns detached data for a session. Search signing
uses the server's WBI keys and URI-component encoding; the session's cookie
jar is maintained under `etaf-bili-state-directory`. Neither cookies nor
signed stream URLs belong in a repository or diagnostic transcript.

## GUI verification

Use a dedicated graphical Emacs with the full user configuration. Keep the
native title bar and foreground focus untouched. After compiling the package,
load ETAF's maintained verification engine and this app's scenario adapter:

```elisp
(load "/path/to/etaf/scripts/emacs-gui-verifier.el")
(load "/path/to/etaf-bili/scripts/etaf-bili-gui-scenarios.el")
(etaf-bili-gui-run "/tmp/bili-gui-evidence")
```

The adapter drives actual catalog targets and native text input, verifies cover
aspect ratios, drives a wheel event and keyboard reveal, searches and ranks
real videos, opens and closes details, and
captures both themes at ordinary, compact, wide and short sizes. Review the
captures separately from the assertions. Playback and pointer feedback need
their real-data pass too; batch acceptance does not certify those properties.

The workspace performance driver accepts
`--scenario-file etaf-bili/benchmarks/performance-scenarios.el
--scenario bili.appearance --load-path etaf-bili` with `--mode batch`
or `--mode gui --server NAME`. Use `--scenario bili.scroll` for continuous
scrolling across virtual rows in a hundred-video offline library. Keep sources
quiet during measurement and use
three independent sets for a final latency claim.

## Hosting the client

`etaf-bili-create` returns a headless session and `etaf-bili-view` returns its
View, so a host that already owns a buffer mounts the client instead of calling
`etaf-bili-open`. Creation sends no request; the first mount loads the popular
feed.

The View lays out for the region it is mounted into, not for the whole frame:
columns, card size and the visible row window come from the mounted Runtime's
committed viewport, and a settled resize re-lays the grid out at the new width.
A host narrower than the 64 by 28 minimum keeps that minimum layout and clips
deliberately.

Mounting adopts the host buffer. The client records the buffer and its change
callback there, so the declared keys, the inline search, `M-x etaf-bili-next`
and the other session commands find the mounted session; a desktop window and a
panel each keep their own session, selection and playback. The palette is
declared on the host's surface when the host provides one, so the panel border
and title bar paint from the same theme as the gallery; the client buffer of
`etaf-bili-open` keeps remapping its own default face instead.

Unmounting stops cover transfers, backend requests and sign-in polling but keeps
the library, selection and account, and pending replies are made inert. Mounting
the same session again therefore resumes where it was and does not fetch the
feed a second time, which is what a `:keep-alive` panel needs. `etaf-bili-close`
remains the way to end the standalone client.
