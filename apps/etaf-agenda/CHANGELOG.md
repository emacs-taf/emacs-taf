# Changelog

All notable user-visible changes are recorded here.  The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- Responsive three-tier layout (wide ≥126, medium 88–125, narrow <88) and short-viewport adaptation (≤25 rows) with live window fitting.
- Live topbar search (`/` / `etaf-agenda-search`), scope filter picker (`f`), soft-delete undo stack (`u` / `etaf-agenda-undo-last`), recurring task spawning on completion, and container creation commands (`etaf-agenda-add-area`, `etaf-agenda-add-project`, `etaf-agenda-add-stage`).
- Interactive right-rail entry inspector (`RET`) supporting kind, status, priority, schedule, time range, deadline, estimate, recurrence, area, project/stage, tags, editable notes body and localized audit log history.
- Calendar Year view (floating 4×3 / 3×4 / 2×6 mini-month grid with annual totals, active-day summary, heat legend and `今` badge), Month view and 7-day Week view (`w` cycles Year / Month / Week), with complete selected-day events and tasks in the right rail and in-place capture (`a`) across all pages.
- Strict 1:1 square tiles (`etaf-ui-icon` `tile-filled` / `tile-outline`) for the 21-day habit matrix, Today right rail and 4-level monthly review heatmap.

### Changed

- Replaced uppercase region-jump letters and digit row hijacking with ETAF's native `:region` (`M-g`, `Tab`, arrow keys) and clean conflict-free shortcuts (`1`–`6` always switch views; `?` opens the native help modal).
- Redesigned visual hierarchy with dynamic theme-derived tonal surfaces, WCAG AA contrast floors across light themes (including warm-yellow `:info` hue guard), calm accents, crisp 1px hairlines, zero-jitter 4-sided calendar selection borders (via shared-edge ownership and reserved borders), anchored headers and equal-width period steppers (`上年/本年/下年`, `上月/本月/下月`, `上周/本周/下周`).
- Extended natural-language capture grammar with `+project`, `~estimate`, `截止:`, `重复:`, `- ` note and `? ` question shorthands while preserving compound Chinese titles.
- Loaded previous, current and next month instance buckets together so cross-month habits, calendar weeks and streaks stay accurate.

### Fixed

- Area selection in the sidebar now filters Today and List views consistently.
- Completing overdue, List and Project tasks persists real completion state and updates Project progress accurately.
- Migrating (`m`) handles overdue, normal and already-migrated rows idempotently without SQLite `UNIQUE` constraint errors.
- Inline editing (`e`) mounts and focuses cleanly, and topbar `?` opens the native help modal.
- Theme switches (`load-theme`) dynamically refresh both semantic colours and provided `etaf-ui` tokens in place.
