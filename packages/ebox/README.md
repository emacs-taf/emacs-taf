# Ebox

[中文](README.zh-CN.md)

Ebox is a retained text-layout engine for Emacs buffers.  It builds mutable
node trees of text, box, row, column, flex, grid and image nodes, computes
ECSS-backed styles, lays them out in pixel-aware horizontal geometry and
line-based vertical geometry, and writes the result into an Emacs buffer.  Once
mounted, callers mutate the same tree; Ebox tracks dirty nodes and rewrites only
the buffer lines and line parts that changed.

Use Ebox directly when a package needs low-level layout and buffer rendering.
Use the sibling ETAF package when an application also needs components,
reactive state or application lifecycle services.

## Capabilities

- Build retained trees with `ebox-node-create`, `ebox-text-create` or the
  author DSL consumed by `ebox-build`.
- Mount a root in a buffer with `ebox-mount` or render detached output with
  `ebox-render`.
- Update nodes in place with text, property, state and child-list mutations;
  `ebox-with-batch` coalesces many mutations into one flush.
- Style nodes with inline properties and ECSS scopes, then query mounted trees
  with selectors.
- Compose rows, columns, flex and grid containers; measure text and prepared
  character-grid images.
- Provide native Emacs interaction through text properties: keymaps, help,
  pointer shapes, hover content, focus, activation, scrolling and input
  sessions.
- Refit mounted buffers when their viewport changes and observe each flush with
  update reports.

## Prerequisites

| Dependency | Required for |
| --- | --- |
| Emacs 29.1 or newer | All Ebox use. |
| ECSS 0.1.0 or newer | Style schema, selectors, cascade and scopes. |
| Optional `chafa` or `ffmpeg` executables | Text-mode image conversion before falling back to placeholders. |

Ebox has no native module.  Image preparation may also use Emacs graphical
image support when it is available.

## Installation from a source checkout

Add ECSS and Ebox source roots to `load-path`, then require the package entry:

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/ebox")
(require 'ebox)
```

For interactive speed, run `make native` in the checkout after each update.
It byte-compiles Ebox and stores native code in your `eln-cache`, which Emacs
loads in place of the bytecode without further configuration, even when JIT
native compilation is disabled.  A source file edited later runs as bytecode
until the next `make native`.

Checkout users require only `ebox`; implementation files under `lisp/` are
private.  The authoritative API inventory is the Commentary in
[`ebox.el`](ebox.el), and workflows are in the [ETAF Reference Manual](https://etaf.top/ebox-node-construction/).

## Minimal working example

The following example was verified with
`python3 scripts/elisp.py run -p ebox` from the workspace root.

```elisp
(require 'ebox)

(let* ((root
        (ebox-build
         '(column :padding ((lh 1) (ch 2))
                  :border ((px 1) solid "#8A93A6")
                  (text :color "#263244" "Hello Ebox")
                  (row :item-gap (ch 1)
                       (box "Left")
                       (box "Right")))))
       (buffer (ebox-render-to-buffer "*Ebox Example*" root
                                      :width 480 :height 12)))
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))
```

`ebox-render-to-buffer` mounts the retained root.  Later calls such as
`ebox-node-set-text`, `ebox-node-set-props` and `ebox-node-insert` mutate that
same tree and flush the affected buffer lines.

## Documentation

- [Reference manual](https://etaf.top/ebox-node-construction/): the Ebox chapters of the ETAF Reference Manual.
- [Architecture](docs/architecture.md): implemented modules, data flow and
  invariants for maintainers.
- [`ebox.el` Commentary](ebox.el): complete supported API inventory.
- [Changelog](CHANGELOG.md): user-visible changes and migration notes.

## Checks

From the workspace root:

```sh
make -C ebox structure-check
make -C ebox check
```

`make -C ebox check` includes structure validation, byte compilation and the
public acceptance scenarios listed by the package.

## License

Ebox is distributed under GPL-3.0-or-later.  See [LICENSE](LICENSE).
