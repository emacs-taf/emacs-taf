# License

The framework packages are free software: you can redistribute and modify them under the GNU General Public License, version 3 or later. Every package entry carries the SPDX identifier `GPL-3.0-or-later`, and the packages that ship the license text provide it as `LICENSE` or `COPYING`. The manual and its reader are under the same license.

<!-- index: license; GPL; third-party data -->

## The packages

| Package | License | Where the terms are stated |
| --- | --- | --- |
| `ecss` | `GPL-3.0-or-later` | the entry's SPDX header and `LICENSE` |
| `ekp` | `GPL-3.0-or-later` | the entry's copyright notice and `COPYING` |
| `ebox` | `GPL-3.0-or-later` | the entry's SPDX header and `LICENSE` |
| `etaf` | `GPL-3.0-or-later` | the entry's SPDX header |
| `etaf-ui` | `GPL-3.0-or-later` | the entry's SPDX header |
| `etaf-db` | `GPL-3.0-or-later` | the entry's SPDX header |
| `etaf-manual` | `GPL-3.0-or-later` | the entry's SPDX header |

## Third-party resources

- **EKP hyphenation dictionaries.** The dictionaries bundled under `dictionaries/` are third-party data and are not covered solely by EKP's `COPYING`. `dictionaries/MANIFEST.tsv` and `dictionaries/LICENSES.md` record the origin, license evidence and checksum of every file, pinned to a LibreOffice dictionaries snapshot; one legacy file, `hyph_eu.dic`, retains its own checked-in notice. The Sanskrit file is not bundled because the pinned upstream data has no authoritative license statement for it.
- **Fonts and icons.** The catalog draws icons either from fonts installed on the user's system (the `nerd`, `fa`, `material`, `octicons` and `sys` sets) or from SVG bodies defined in `etaf-ui` source. No font files are bundled, so an installed font keeps its own license.
- **Colour emoji.** Ebox's macOS colour-emoji helper, `ebox/native/emoji/emoji-render.swift`, is compiled locally with `swiftc`; it is part of Ebox and distributed under the same license.

## The manual

The chapters below `book/` and their runnable examples are part of `etaf-manual` and covered by the same `GPL-3.0-or-later` terms as the package.
