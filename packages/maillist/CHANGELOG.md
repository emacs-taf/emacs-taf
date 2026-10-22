# Changelog

All notable user-visible changes to maillist are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Read a public-inbox archive as a mail client: date-grouped thread list,
  unread and starred scopes, remote search, and a reader that keeps the
  thread header fixed while the body scrolls inside its own box.

- Read and starred marks plus thread bodies are stored in one SQLite file, so
  a restart shows the list before the archive answers.

- Long threads open with their newest messages and grow on demand (`e`), so a
  thousand-message thread stays responsive.

- Reply (`r`) and new post (`c`) open in `message-mode` with `In-Reply-To`
  and `References`, sending through smtpmail with an application password
  stored by `M-x maillist-mail-configure` in auth-source.

- The pane divider can be dragged to resize the thread list, and the layout
  collapses to one column below `maillist-narrow-width`.

- Every thread's sender fills in after a sync: the index names none, so the
  client reads one raw message per unknown sender, three at a time, and stores
  the name.  Rows waiting for a name show `…`.

- A thread whose fetch fails reports the error in the reader header instead of
  showing an empty conversation, and never replaces a cached body with nothing.

- The search field takes the space its query needs instead of wrapping a long
  address onto a second line, and an empty search result says so.

- Sync state, errors and search feedback appear as a floating notice at the
  top right and leave on their own, so a message never moves the list or the
  reader.

- Opening a thread larger than `maillist-fast-open-threshold` shows its newest
  mail from the small search feed at once, then replaces it with the whole
  conversation; a 72-message thread shows content in 0.4s instead of 3.2s.

- When the archive merges a thread into an older discussion (a reply with a
  broken References header), the reader keeps the conversation the index
  named: it shows the subject's messages and says the archive merged the
  thread, instead of a thousand old mails under the new subject.

- The thread list keeps one column grid: a buried sub-thread no longer shifts
  its author, count, time and subject by two cells.

- Colour now follows roles instead of decorating: authors stay neutral (ink
  when unread, muted when read), the list's unread subjects take the theme's
  link colour softened toward the surface, a reply names the person it
  answers in the theme's warm colour, and diff lines keep their green/red
  pair.  Backgrounds stay reserved for state and reading aids: the selected
  row, quoted and patch bands, and the floating notice.

### Fixed

- A refresh no longer shortens the list.  The archive's index page names only
  recent threads, so its rows now merge into the stored list instead of
  replacing it: a thread the page no longer lists keeps its row, its author and
  its marks.  Before, threads older than the first page vanished from the list
  until the next restart.

- Opening a thread marks it read only once its body is on screen.  An archive
  that never answered, or a row only passed through with `j`/`k`, keeps the
  thread unread; before, selecting the row marked it read before the fetch.

- A displayed search result can no longer become the stored fact of a thread.
  The search row's date, count and subject are no longer written back to the
  archive cache while a query is active.

- A buried reply no longer climbs above the message it answers after a
  restart.  The thread table now keeps the archive's depth, and a reply sorts
  after its parent when both carry one timestamp.

- A thread document the archive will not serve no longer leaves the reader on
  a loading placeholder and then a bare error.  The client shows the newest
  message it can reach from the archive's search feed, says the thread data is
  incomplete, and reports only when even that message is unavailable.

- A cache file written by an incompatible earlier version is moved aside and
  rebuilt at startup, with a notice naming the backup file, instead of leaving
  the client with no persistence.  `threads`, `messages` and the new `marks`
  table are created together.

- An archive answer that carries no thread row is no longer taken as an empty
  list.  Such an answer is fetched once more; if it stays unanswered the sync
  fails with a notice and the client keeps the list and the stored rows it
  already has.  Before, an empty body after a dropped connection wiped the
  visible list and then failed to save it.

### Changed

- The thread cache is kept per archive.  Rows stored before this change are
tagged with the first list opened, and rows of another list never appear in
the current one.

- Read and starred marks now live in their own `marks` table, written only when
  the reader changes them.  A refresh rewrites the archive cache and cannot
  lose them.  The first start after upgrading reads old files with the new
  schema, so previously read threads show as unread once.
