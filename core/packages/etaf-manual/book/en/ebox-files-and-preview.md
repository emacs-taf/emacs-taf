# .ebox Files and Preview

A `.ebox` file is an author form in a file: one Elisp expression, quoted so the tags are data, with optional companions beside it. The file contract belongs to the core package — reading, evaluating and previewing a `.ebox` file needs no application and no playground — and this chapter documents it. [Node Construction](ebox-node-construction.md) defines the author forms a file contains, [Style System](style-system.md) defines the rule files a `.ebox` file may attach, and [Mount and Lifecycle](ebox-mount-lifecycle.md) the mounted buffer the preview creates.

## The file contract

<!-- index: .ebox file; quoted form; companion; rule file; preview buffer -->

A file holds exactly one expression, and the expression is read without evaluation and then evaluated once. In practice the expression is a quoted author form:

```elisp
'(box :width (ch 32) :height (lh 4)
      (text "Inbox")
      (row :item-gap (ch 1) (box "open") (box "done")))
```

The quote is not decoration. The file is read as data first, which is why `#.` is rejected instead of evaluated, and evaluated afterwards, which is why an unquoted `(box ...)` would try to call `box` as a function and fail. Everything Lisp can do between the two steps is available — a file can compute parts of its form — but a form that is meant to be a tree must evaluate to one.

Two kinds of companions sit beside a `.ebox` file. A same-basename `.el` file is loaded before the form is evaluated, so it can define helpers the form calls. A same-basename `.ecss` file, or a file named by the form's `:ecss-file` property, supplies style rules; the form is then returned with a snapshot of those rules embedded under `:ecss`, ready for `ebox-build`. Companions are optional and never required: the core file contract works on a bare `.ebox` file.

A preview is a mounted buffer like any other. `ebox-file-preview` evaluates the file and renders the resulting tree into a buffer of its own, which the preview command then displays; the buffer is owned by Ebox while it lives. Opening a `.ebox` file also selects a derived Emacs Lisp mode with a header line and `C-c C-c` bound to the preview.

## Reading

#### Function: ebox-file-read-form (source)

Read exactly one Elisp expression from SOURCE.

**Arguments.** SOURCE is a string with the file's contents.

**Semantics.** The string is read in an Emacs Lisp buffer with the standard syntax table and with evaluation of read-time forms disabled, so `#.` signals a read error instead of running code. Whitespace and comments around the expression are allowed; anything but one expression is rejected. The result is inert data: symbols such as `box` are symbols, and `(px 20)` is a list. The function reads text only — it opens no file, loads nothing and evaluates nothing.

**Returns.** The expression as data.

**Errors.** `error→ user-error` "The Ebox DSL source is empty" for empty or whitespace-only input, and "The Ebox source must contain one Elisp expression" when there is more than one expression; a malformed read signals an ordinary read error.

**Example.**

```elisp
(ebox-file-read-form "(box :width (px 20) \"x\")")
     ⇒ (box :width (px 20) "x")
```

**See also.** `ebox-file-read-file`, `ebox-build`.

#### Function: ebox-file-read-file (file)

Read one Ebox expression from FILE without evaluating it.

**Semantics.** The file must be readable; its bytes are read into a temporary buffer and handed to `ebox-file-read-form`. Nothing is evaluated and no companion is loaded, so the function is the safe first half of the file contract and the one to use when a tool wants to inspect a file's form.

**Returns.** The expression as data.

**Errors.** `error→ user-error` "Ebox DSL file is not readable: FILE" when FILE cannot be read, plus the errors of `ebox-file-read-form` for its contents.

**See also.** `ebox-file-read-form`, `ebox-file-evaluate-form`.

## Companion loading

#### Function: ebox-file-load-companion (&optional file)

Load FILE's same-basename `.el` companion when it exists.

**Semantics.** The load happens only when FILE names a `.ebox` file and a readable same-basename `.el` file lies beside it; anything else is a no-op, including nil. The load uses `load-prefer-newer`, so a compiled `.elc` companion is used only when it is not older than its source. The companion is ordinary Emacs Lisp and defines whatever the file's form may call; loading happens before evaluation, so the definitions are in place when the form runs.

**Returns.** Unspecified; the effect is the load.

**Errors.** Errors from the companion's own code propagate; a missing or unreadable companion is not an error.

**See also.** `ebox-file-evaluate-form`, `ebox-file-read-file`.

## Evaluating

#### Function: ebox-file-evaluate-form (form &optional source-file)

Evaluate FORM once, loading SOURCE-FILE companions and local styles.

**Arguments.** FORM is the expression read from a file. SOURCE-FILE is the file it came from, used for companions and for relative paths; nil means no companions and no stylesheet, with relative paths taken from the current directory.

**Semantics.** The evaluation happens with `default-directory` bound to SOURCE-FILE's directory, so paths inside the form resolve beside the file rather than wherever Emacs happens to be. Before evaluating, the same-basename `.el` companion is loaded; when SOURCE-FILE names a `.ebox` file with a same-basename `.ecss` file, that rule list becomes the root's first file rules. After evaluating, every Box form in the result is walked: its `:ecss-file` property, if present, names a rule file that is read and snapshotted, its inline `:ecss` rules are appended after the file rules, and each property value is re-quoted so the result is inert data again. The returned form is what `ebox-build` consumes; it contains the styles, not the file names. No declaration value is evaluated at any point.

**Returns.** The evaluated, style-resolved form.

**Errors.** `error→ user-error` ":ecss-file requires a file name" for a non-string property, "An ECSS companion requires a Box root" when a same-basename `.ecss` exists but the form's root cannot carry styles, and the rule file's own unreadable-file error; errors from evaluating FORM or loading its companion propagate.

**Example.**

```elisp
(ebox-file-evaluate-form '(quote (box "x")))
     ⇒ (box "x")
```

**See also.** `ebox-file-evaluate-buffer`, `ebox-file-read-form`, `ebox-style-scope-with-rules`.

#### Function: ebox-file-evaluate-buffer (&optional buffer)

Evaluate the Ebox expression in BUFFER through the core file contract.

**Semantics.** The buffer's text is read with `ebox-file-read-form` and evaluated with the buffer's file name as SOURCE-FILE, so a buffer visiting a file gets the same companions, relative paths and style snapshots as the file on disk. BUFFER defaults to the current buffer. A buffer that visits no file has no companion and no stylesheet; a relative `:ecss-file` then resolves from the current directory and fails if nothing is there.

**Returns.** The evaluated, style-resolved form.

**Errors.** The errors of `ebox-file-read-form` and `ebox-file-evaluate-form`.

**Example.**

```elisp
(with-temp-buffer
  (insert "'(column \"a\" \"b\")")
  (ebox-file-evaluate-buffer))
     ⇒ (column "a" "b")
```

**See also.** `ebox-file-evaluate-form`, `ebox-file-preview`.

## Preview

#### Function: ebox-file-preview (&optional buffer)

Render the `.ebox` source in BUFFER into a dedicated preview buffer.

**Semantics.** BUFFER defaults to the current buffer. Its contents are evaluated through `ebox-file-evaluate-buffer`, the result is built with `ebox-build`, and the tree is mounted with `ebox-render-to-buffer` in a buffer named `*Ebox Preview: NAME*`, where NAME is the file's path or, without a file, the source buffer's name. The preview buffer is displayed and returned; running the command again evaluates the source afresh and replaces the preview's contents through the ordinary mount path. The preview is a normal mounted Ebox buffer, so scrolling, focus and interaction work there, and it stays until it is killed or replaced.

**Returns.** The preview buffer.

**Errors.** The errors of `ebox-file-evaluate-buffer` and of building the form.

**Example.**

```elisp
;; In a buffer visiting a .ebox file:
(string-prefix-p "*Ebox Preview: " (buffer-name (ebox-file-preview)))
     ⇒ t
```

**See also.** `ebox-file-evaluate-buffer`, `ebox-render-to-buffer`, `ebox-unmount-buffer`.

## How the entries work together

The readers and the evaluator split the file contract in two. `ebox-file-read-form` and `ebox-file-read-file` turn text into data and never run it; `ebox-file-evaluate-form` and `ebox-file-evaluate-buffer` take that data through the one evaluation, companion loading and style snapshot that a file needs. `ebox-file-load-companion` is the piece that runs before evaluation, and the style resolution is the piece that runs after it. `ebox-file-preview` is the interactive whole: read, evaluate, build, mount.

The reference playground, ebox-playground, builds a richer workflow on the same contract: it renders a DSL file into a buffer, renders the current DSL buffer beside a right-hand preview, and opens the default example. Its `examples/` directory is the best collection of `.ebox` files to read, and none of it is required to load a `.ebox` file.

## Semantic details

<!-- index: rule snapshot order; file rule precedence; relative path -->

The style snapshot has a defined order. A same-basename `.ecss` companion comes first, then the rules of the `:ecss-file` named on the same Box, then the Box's inline `:ecss` rules. Later rules of equal specificity win, so inline rules override file rules, and a file named on the Box overrides the companion. The rules are copied into the form as inert data: after evaluation the result no longer mentions either file, so moving or editing them cannot change a tree that was already built. A companion `.ecss` applies at the root and therefore needs a root that can carry styles — a Box form; the `:ecss-file` property on a nested Box is resolved where it is written, and children's Boxes are processed too.

Evaluation order matters for files. The `.el` companion is loaded before the form runs, so the form can call what the companion defines. Paths resolve in SOURCE-FILE's directory, not in the caller's, which is what makes a `.ebox` file self-contained: it can name `:ecss-file "theme.ecss"` next to itself and work when loaded from anywhere. Reading, by contrast, is pure: no file is opened for companions, no value is evaluated, and `#.` is rejected — a `.ebox` file can be inspected safely.

The editing mode completes the workflow. Opening a `.ebox` file selects a derived Emacs Lisp mode with a header line that names the preview key, no line truncation and left-to-right display; `C-c C-c` runs `ebox-file-preview`. The mode is an editing convenience — the commands it binds are the same public entry points this chapter defines.

## Errors and recovery

| Situation | Signal |
| --- | --- |
| Empty or whitespace-only source | `error→ user-error`, "The Ebox DSL source is empty" |
| More than one expression | `error→ user-error`, "The Ebox source must contain one Elisp expression" |
| `#.` in the source | a read error; read-time evaluation is disabled |
| File not readable | `error→ user-error`, "Ebox DSL file is not readable: FILE" |
| `:ecss-file` is not a string | `error→ user-error`, ":ecss-file requires a file name" |
| A `.ecss` companion with a non-box root | `error→ user-error`, "An ECSS companion requires a Box root" |
| The named rule file is not readable | the rule reader's unreadable-file error |
| The form or its companion signals | the error propagates from evaluation |

Recovery follows the stage. A read error means the file is not exactly one expression; fix the file or use the buffer's contents directly. An evaluation error usually means an unquoted form or a missing companion definition; adding the quote or the companion fixes it. A missing rule file is a path problem: paths are relative to the source file, so a file that works from one directory keeps working from another only when its companions travel with it. A failed preview changes nothing on disk and leaves any existing preview buffer as it was, because the failure happens before the mount.
