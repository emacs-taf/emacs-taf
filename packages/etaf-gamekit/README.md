# etaf-gamekit

A framework for building games with native ETAF interfaces. A game project owns
its rules, assets, presentation and launch command. GameKit provides game
definitions, independent running instances, state publication, actions,
lifecycle management and backend adapters.

The core depends on ETAF. It contains no game application and does not load the
game applications or etaf-ui. Applications choose their own catalog components.

Included adapters connect games to **Godot**, **boardgame.io** and **OpenSpiel**.
A game's definition selects its backend; applications start a game definition:

```elisp
(require 'etaf-gamekit)

(etaf-gamekit-define-game my-poker
  :title "My Poker"
  :backend 'openspiel
  :options '(:game "kuhn_poker" :player 0 :seed 42)
  :view (lambda (instance)
          (etaf-view
           (text (expr (or (etaf-gamekit-view instance :information_state)
                           "Starting game…"))))))

(let ((instance (etaf-gamekit-start my-poker)))
  (display-buffer (etaf-gamekit-buffer instance)))
```

Requires Emacs 29.1+ and ETAF with its dependencies on `load-path`. Install the
backend used by your game from the package itself, which writes only under
`~/.cache/emacs-taf/game-engines`:

| Backend | Installation | Runtime |
| --- | --- | --- |
| Godot | `M-x etaf-gamekit-install-godot` | Pinned Godot 4.7.2; macOS or Linux x86-64/arm64 |
| OpenSpiel | `M-x etaf-gamekit-install-openspiel` | Pinned OpenSpiel 2.0.2; Python 3.11+ |
| boardgame.io | `make engine-boardgame-io` | Node.js 18+; pinned boardgame.io 0.50.2 |

A source checkout can run the same setup with `make engine` and
`make engine-openspiel`.

The [manual](docs/manual.md) explains how to create a separate game project,
configure a backend, compose a frontend, manage instances and add an adapter.
The [package entry](etaf-gamekit.el) is the supported API inventory;
[architecture](docs/architecture.md) explains responsibilities and engine choices.

Game applications are independently maintained as sibling checkouts in the
[workspace](https://github.com/emacs-taf/emacs-taf). For example, `etaf-solitaire` uses OpenSpiel and `etaf-salvage` uses Godot; each
owns its entry, interface, rules configuration, resources and checks. Install
and launch a game through its own package, not through a framework launcher.

For framework development, install all three backends with
`make engine-all GAMEKIT_PYTHON=python3.11`, then run `make check`.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE).
