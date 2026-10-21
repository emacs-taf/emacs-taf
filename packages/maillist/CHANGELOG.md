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
