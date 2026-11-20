# ebox repository instructions

The enclosing workspace `AGENTS.md` (`../AGENTS.md`) carries the shared
engineering, documentation, validation and Jujutsu rules; read it first. This
file adds only what is specific to this repository.

## Node bounds

`ebox-node-bounds` reports a box's range including its padding, border and
trailing line break; only a text leaf's bounds come down to the cells that
carry characters, so take the text leaf whenever positions must line up
character by character.
