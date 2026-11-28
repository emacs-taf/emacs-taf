# ETAF Balatro

ETAF Balatro is a Balatro-inspired text deck-building and scoring roguelike built completely in Emacs Lisp on ETAF and ETAF UI.

## Capabilities

- Pure-function deterministic poker hand evaluator and scoring cascade engine across 8 Antes (Small, Big and Boss Blinds with unique Boss modifiers) with reproducible integer seeds.
- Step-by-step scoring cascade choreography powered by `etaf-animation-timeline`, highlighting each scoring card, card enhancement (Bonus, Mult, Glass, Steel, Foil) and left-to-right Joker passive in turn, with `1× / 2× / 4×` speed selection and `SPC` instant skip via `etaf-animation-finish`.
- 14 distinct Jokers (including order-sensitive `+Mult` / `×Mult` scaling, `宏录制器` card retrigger and `垃圾回收器` discard growth), Planet hand-level upgrades, 6 targeted Tarot sculpting consumables (`u` / `U` applied directly to selected hand cards), a full 4×13 52-card Deck Matrix (`v`), and persistent lifetime records (`etaf-balatro-records-file`).
- Zero-prerequisite onboarding with an interactive 4-step beginner guide (`g`, auto-shown on first run) and a toggleable contextual in-game Coach ribbon (`G`) that inspects the live hand and Joker order.
- Automatic Emacs theme adaptation (`auto`, default) that derives calm 3-level surfaces and WCAG-legible semantic accents live from `load-theme`, plus manual `dark` / `light` overrides (`t`), physical 1-row card lift on selection, responsive wide/narrow/short layouts, hidden stray cursor and preserved Emacs mode-line.

## Prerequisites

- GNU Emacs 29.1 or newer
- `ecss`, `ebox`, `etaf`, and `etaf-ui` from [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) on `load-path`

## Installation

<!-- BEGIN:GENERATED:pkg-install-en:etaf-balatro -->
> `etaf-balatro` is currently incubating in the monorepo. Install from a source checkout of [`emacs-taf/emacs-taf`](https://github.com/emacs-taf/emacs-taf) (or [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) + this package):

```elisp
(dolist (pkg '("ecss" "ebox" "etaf" "etaf-ui"))
  (add-to-list 'load-path (expand-file-name pkg "/path/to/etaf/packages")))
(add-to-list 'load-path "/path/to/etaf-balatro")
(require 'etaf-balatro)
```
<!-- END:GENERATED:pkg-install-en:etaf-balatro -->

## Quick Start

```elisp
(require 'etaf-balatro)
(etaf-balatro-open 4821)
```

## Keybindings

- `1`–`8`: Select or deselect cards in hand during play (or jump to guide page 1–4); `1`–`4` buy items in the shop.
- `RET`: Play the selected hand, enter the next blind from the shop, step the beginner guide, or restart after a run ends.
- `d`: Discard selected cards and draw replacements; `s`: Toggle hand sorting between rank and suit.
- `SPC`: Immediately complete the active scoring animation, or cycle playback speed (`1× / 2× / 4×`).
- `,` / `.` (or `[` / `]`): Reorder the selected Joker left or right to place `+Mult` before `×Mult`.
- `u` / `U`: Use consumable slot 1 or 2 (Planets upgrade immediately; Tarots sculpt selected hand cards).
- `r`: Reroll shop (`$5`); `x`: Sell selected Joker; `n`: Next blind or next guide page.
- `g`: Open the 4-step beginner guide; `G`: Toggle contextual in-game Coach hints.
- `v`: Full 52-card Deck Matrix; `h`: Hand levels table; `t`: Cycle `auto` / `dark` / `light` theme; `N`: New run; `?`: Key help; `q`: Close.

## Documentation & Checks

The supported public API is documented in [etaf-balatro.el](etaf-balatro.el). Run `make check` inside `games/etaf-balatro` to verify repository structure, zero-warning byte compilation, acceptance tests and API declarations.
