# Changelog

## Unreleased

### Added

- `M-x etaf-bili-create` and `etaf-bili-view` expose the client as an
  embeddable View: a desktop window or a floating panel mounts it, lays the card
  grid out for its own region, follows a settled resize and keeps the client's
  keys. The first mount loads the popular feed; unmounting keeps the library,
  selection and account for the next mount and makes pending replies inert.
- `M-x etaf-bili-login` paints the site's sign-in code in an
  `etaf-ui-qr-login` panel over the running client, which keeps its content and
  only dims; the header's account chip opens it and shows the signed-in name.
  `M-x etaf-bili-account` reports the account and `M-x etaf-bili-logout` signs
  out and clears the cookie jar. The account backend ships in
  `backends/bili/` and needs only Node.js.

### Removed

- The phone-number sign-in tab. Bilibili answers its SMS endpoint with a
  graphical captcha, so the method could never complete from a terminal.

### Changed

- Replace the full-width text list and permanent details sidebar with a
  responsive cover-card gallery composed from the ETAF UI catalog.
- Search edits inside a rounded SearchField; channel Tabs, native scrolling and
  a details Drawer make the main actions visible. Application keys now use
  ETAF's scope-aware declarations instead of an emulation-map override.
- Both themes use a padded header and footer; frame decoration and the user's
  theme stay unchanged. The minimum usable window is 64 columns by 28 lines.
- Loading uses Skeleton cards and a scoped indicator; selection has a short
  accent transition and respects the framework reduced-motion switch.

### Fixed

- Fit covers at their native aspect ratio, including fractional-row insets,
  instead of stretching images to a rounded character-cell rectangle.
- Use the published usable viewport width so empty full-width rows keep their
  application background instead of disappearing at redisplay.
- Treat empty results as successful, reject stale playback replies, and make
  pending callbacks inert after the buffer closes.

### Added

- Browsing: the popular feed loads on open, `1`/`2` switch between it and
  the all-category ranking, `g` refreshes, and the selection moves with
  `j`/`k`, `n`/`p` or the arrow keys with a mouse-click target per row.
- Search through the signed web API endpoint: `/` prompts for a keyword and
  replaces the list.  WBI signing (sorted parameters, `encodeURIComponent`
  encoding, MD5 over the query plus the permuted server key) is implemented
  in Lisp and covered by an acceptance test.
- A details Drawer showing the selected video's creator, duration, view count
  and BV number without permanently reserving sidebar space.
- Playback in the same buffer through ETAF's `etaf-media-viewer`: `RET`
  resolves the stream (metadata chain plus the Referer and User-Agent headers
  the CDN requires) and opens the viewer with its transport bar, sound,
  seeking and speed control; `n`/`p` inside the viewer move to the next or
  previous list entry and play it.
- Dark and light appearances over one four-step depth palette; `T` switches
  the running client.
- A cookie jar under `etaf-bili-state-directory`, seeded once per session
  with a homepage visit (`buvid3`), reused by every request.
- The session is drivable headless: `etaf-bili-session-create`,
  `etaf-bili-session-state` and the load/move/play actions take the session
  record directly, with a fake backend injectable through
  `etaf-bili-client-factory`.
