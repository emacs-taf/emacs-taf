# Interactive Use

The string interface lays out text it owns; the buffer commands in this chapter lay out text the user owns. Justification is a projection: EKP computes a plan for a hard paragraph and installs it as display properties on the existing characters. The character sequence never changes, so saving, searching, syntax highlighting and ordinary Lisp see the logical text, while the window shows justified lines. Removing the projection restores the buffer's plain appearance, and nothing that was only a layout decision can reach the file.

This chapter defines the interactive layer: the justify and unjustify commands, the automatic mode with its editing transaction, the session-local protection regions, the Org and Markdown setups, and the layout diagnostic. The line-breaking model is [Line-Breaking Principles](ekp-principles.md), the prohibition and edge rules are [CJK Typesetting](ekp-cjk.md), and hyphenation is [Hyphenation](ekp-hyphenation.md). Every width, tolerance and policy named here is a user option collected in the [Parameter Reference](ekp-parameters.md) chapter.

## The projection model

<!-- index: projection; buffer layout; session-local protection; effective measure; layout conflict -->

A projection touches the buffer through text properties only. No character is inserted, deleted or moved, no overlay is created, and no file-local state is written, so the buffer's text, point, mark and markers behave exactly as before. The projection is installed inside an operation that suppresses modification bookkeeping: justification does not set the modified flag, does not add undo entries and does not run external change hooks. Point and mark positions, and whether the mark is active, are preserved across the operation.

A layout unit is a hard paragraph: the text between newlines. Each paragraph is planned on its own, so a hard newline always survives, and a projected region contains only the paragraphs it intersects. Within a paragraph some content stays untouched by design: paragraphs marked verbatim for the session, paragraphs wearing a face in the buffer's skip set, paragraphs accepted by the buffer's skip predicate, paragraphs that contain fields or read-only text, and paragraphs that carry a foreign display or line-prefix owner all pass through unprojected. When the automatic mode skips a paragraph because it exceeds its planning limit or because EKP's `natural` overlong-token policy leaves it alone, the diagnostic records why.

The width used by a projection is the effective measure: the narrowest live window displaying the buffer by default, or the fixed width or capped width that the buffer's measure option selects. Wrapping and the plan are computed from that width, so a projection is only as good as the window it was planned for; reflowing at another width is a layout call with that width, or a resize while the automatic mode is active.

While a buffer carries any projection, EKP installs its copy and kill integration, which strips EKP's layout properties from copied text while preserving every other property and any filter the buffer already had. The integration is removed when the last projection disappears, so a buffer that has never been justified is untouched.

## Justifying and un-justifying

#### Function: ekp-justify-region (beg end &optional pixel)

Project BEG through END as KP layout at PIXEL without changing text.

**Arguments.** BEG and END delimit the region; their order does not matter. PIXEL is the target width in pixels. When omitted, the region is projected at the effective measure: the narrowest live window showing the buffer, or the fixed or capped width the measure option selects.

**Semantics.** The region is divided into hard paragraphs and each paragraph is planned and installed independently, so paragraphs stay inside their newlines. PIXEL, when given, must be a positive integer. Protected content is skipped as the projection model describes. Existing projection in the region is replaced, so justifying the same region twice at the same width yields the same result as justifying it once, and justifying at a new width is a fresh layout, not an accumulation. The operation preserves point, mark and the active region; with font lock active and any face-based policy in effect it ensures the region is fontified first. Interactive calls read the region, or the hard paragraph at point when no region is active, and take a numeric prefix argument as PIXEL; they also refuse a read-only buffer.

**Returns.** Unspecified; the projection is the effect.

**Errors.** `error→ user-error` with the message `Line width must be a positive integer, got PIXEL` when PIXEL is zero, negative or not an integer. An interactive call in a read-only buffer signals `buffer-read-only` before doing anything.

**Example.**

```elisp
(with-current-buffer "notes.txt"
  (ekp-justify-region (point-min) (point-max))
  (buffer-substring-no-properties (point-min) (point-max)))
     ⇒ the original characters, now displayed as justified lines
```

**See also.** `ekp-unjustify-region`, `ekp-justify-buffer`.

#### Function: ekp-justify-buffer (&optional pixel)

Project the accessible buffer as KP layout at PIXEL.

**Arguments.** PIXEL is the target width in pixels, defaulting to the effective measure like `ekp-justify-region`.

**Semantics.** It is `ekp-justify-region` over the whole accessible region, so narrowing limits the work exactly as it does there; hard paragraphs, protections, replacement of an earlier projection and the preservation of point and mark all behave the same. Interactive calls take a numeric prefix argument as PIXEL and refuse a read-only buffer.

**Returns.** Unspecified; the projection is the effect.

**Errors.** `error→ user-error` for an invalid PIXEL, and `buffer-read-only` for an interactive call in a read-only buffer.

**Example.**

```elisp
(with-current-buffer "notes.txt"
  (ekp-justify-buffer))
     ⇒ every hard paragraph in the accessible region projected at window width
```

**See also.** `ekp-justify-region`, `ekp-unjustify-buffer`.

#### Function: ekp-unjustify-region (beg end)

Remove EKP display projection intersecting BEG through END.

**Arguments.** BEG and END delimit the region; their order does not matter.

**Semantics.** Every projection that intersects the region is removed, including a projection that extends past it: the unit of removal is the affected projection, not the characters in the argument range. Text and non-EKP properties are untouched. When the last projection in the buffer is gone, the copy and kill integration is removed as well, returning the buffer to its pre-justification state. Interactive calls use the active region or the paragraph at point, like justification.

**Returns.** Unspecified; the removal is the effect.

**Errors.** None of its own. It does not require the region to be projected, and an interactive call in a read-only buffer reports `buffer-read-only` before touching anything.

**Example.**

```elisp
(ekp-unjustify-region (point-min) (point-max))
     ⇒ the whole buffer displays as plain text again
```

**See also.** `ekp-justify-region`, `ekp-unjustify-buffer`.

#### Function: ekp-unjustify-buffer ()

Remove EKP display projection from the accessible buffer.

**Arguments.** None.

**Semantics.** It removes every projection in the accessible region, exactly as `ekp-unjustify-region` over the whole buffer would, and drops the copy and kill integration when nothing is projected anymore. It leaves the decision of what was projected to the projection itself, so a narrowed buffer releases only its accessible part.

**Returns.** Unspecified; the removal is the effect.

**Errors.** An interactive call in a read-only buffer reports `buffer-read-only`; a Lisp call removes the projection regardless of the buffer's read-only flag, because a projection is display state, not text.

**Example.**

```elisp
(ekp-unjustify-buffer)
     ⇒ no EKP layout properties remain in the buffer
```

**See also.** `ekp-unjustify-region`, `ekp-justify-buffer`.

## The automatic mode

`ekp-auto-justify-mode` keeps completed paragraphs projected while ordinary editing continues. The mode does not justify everything on every keystroke, because a whole-paragraph reflow while the user types would be both slow and disruptive. Instead it maintains one edit transaction around the line being edited: typing inside the active visual row changes only that row's display, leaving the committed rows around it in place, and a complete plan is published when the edit naturally crosses a visual row, when a hard newline or paragraph completes, on the next real edit elsewhere, on an explicit refill, or when width, font, face or layout context changes. Point motion alone never plans or writes anything, and there is no idle timer that snaps a whole paragraph into place.

The mode follows the buffer's effective measure, so the projection tracks the window. A resize is debounced by the resize delay before the buffer is reflowed, which keeps a window drag from running one reflow per intermediate size. Large buffers reflow visible-first: the part on screen is updated immediately and the rest follows in bounded background chunks. Automatic planning is also bounded per paragraph by the paragraph limit, so a very long paragraph stays natural and editable instead of blocking input; `ekp-refill-paragraph` is the explicit command that performs the unbounded pass for the paragraph at point.

The mode is non-mutating like the manual commands: enabling, editing, resizing and disabling do not add undo entries, do not set the modified flag and do not run external change hooks. It temporarily takes over the buffer's line truncation so that a narrow side-by-side window still soft-wraps, and disabling the mode restores the previous ownership of those settings along with removing every projection.

#### Function: ekp-auto-justify-mode (&optional arg)

Maintain a non-mutating KP display projection.

**Arguments.** ARG follows the minor-mode convention: omitted, nil or positive enables the mode, zero or negative disables it, and `toggle` flips it. Interactive calls toggle when no prefix argument is given.

**Semantics.** Enabling computes the effective measure, projects completed paragraphs, installs the hooks that watch resizing, scrolling, text scaling, font and theme changes and buffer changes, and installs the copy and kill integration. While it is on, the active hard line is edited in a local transaction as described above, and the mode's menu offers the justify, un-justify, region-protection and diagnostic commands. Disabling cancels pending asynchronous work and timers, releases the edit transaction, removes every projection and restores the truncation ownership the mode changed. Completed paragraphs use the effective measure; because the mode consults the buffer's mode profile and skip rules, an Org or Markdown buffer protects its code the same way an explicit `ekp-org-setup` or `ekp-markdown-setup` would.

**Returns.** The new value of `ekp-auto-justify-mode`.

**Errors.** `error→ error` with the message `Invalid ekp-buffer-measure: MEASURE` when the buffer's measure option holds a value that is neither `narrowest-window`, a positive integer nor a `(max . N)` cons with positive N. The failure happens before any projection is installed, so the buffer is left as it was.

**Example.**

```elisp
(ekp-auto-justify-mode 1)
     ⇒ t
(ekp-auto-justify-mode -1)
     ⇒ nil
```

**See also.** `ekp-refill-paragraph`, `ekp-diagnose`, `ekp-justify-buffer`.

#### Function: ekp-refill-paragraph ()

Apply a complete KP layout to the hard paragraph at point.

**Arguments.** None.

**Semantics.** It releases the automatic mode's active edit transaction and committed state for the paragraph and justifies the whole hard paragraph at point in one layout call at the effective width. The limitation that keeps automatic planning bounded does not apply: this is the command to run when a long paragraph must actually be justified rather than left natural, and it is also useful outside the mode to re-project a single paragraph after an edit. In the mode's keymap it replaces the ordinary `fill-paragraph` command.

**Returns.** Unspecified; the projection of the paragraph is the effect.

**Errors.** An interactive call in a read-only buffer reports `buffer-read-only`. An invalid buffer measure fails as `ekp-auto-justify-mode` does.

**Example.**

```elisp
(with-current-buffer "notes.txt"
  (ekp-refill-paragraph))
     ⇒ the paragraph at point planned as a whole, however long it is
```

**See also.** `ekp-auto-justify-mode`, `ekp-justify-region`.

## Protecting regions

Two session-local protections keep specific content out of layout. A no-break region becomes a rigid atom: EKP will not break inside it, will not hyphenate it and will not stretch the gaps inside it, no matter how narrow the measure is. A verbatim region keeps whole paragraphs untouched: any paragraph that intersects the region is laid out by Emacs's own wrapping. Both protections live in the buffer as text properties, apply to the current buffer session only, and disappear when the text is saved and reopened; they are removed by the matching clear command.

The protection commands take an optional ANNOUNCE argument. When it is non-nil, the command reports the effect in the echo area and states that it lasts for the current buffer session only. An interactive call always passes ANNOUNCE, and uses the active region.

#### Function: ekp-no-break-region (beg end &optional announce)

Mark BEG through END as an unbreakable session-local atom.

**Arguments.** BEG and END delimit the region. ANNOUNCE requests interactive feedback.

**Semantics.** The marked range behaves as one atom in every later projection: no line break or hyphenation point inside it is used, and the glue inside it stays rigid, so an overlong atom overflows a line rather than splitting. The protection is stronger than a break policy and outlives re-justification in either direction, because it is an input to layout rather than a result of it. Marking a range that is already protected is idempotent, and marking part of an existing atom extends the protection.

**Returns.** Unspecified; the marking is the effect.

**Errors.** None. The range may be empty or larger than one paragraph.

**Example.**

```elisp
(ekp-no-break-region 10 25)
     ⇒ "the-no-break-atom" keeps its shape at any width
```

**See also.** `ekp-allow-break-region`, `ekp-verbatim-region`.

#### Function: ekp-allow-break-region (beg end &optional announce)

Clear the unbreakable-region protection from BEG through END.

**Arguments.** BEG and END delimit the region. ANNOUNCE requests interactive feedback.

**Semantics.** It removes the no-break protection from the range; later projections may break and hyphenate there again. Clearing a range that was not protected, or only part of a protected atom, is allowed and removes exactly what the range covers. The command does not re-project by itself; the change takes effect when the region is next justified, or immediately under the automatic mode, which reflows after a region policy change.

**Returns.** Unspecified; the removal is the effect.

**Errors.** None.

**Example.**

```elisp
(ekp-allow-break-region 10 25)
(ekp-justify-region 1 40 20)
     ⇒ the former atom may now wrap at any legal point inside it
```

**See also.** `ekp-no-break-region`, `ekp-clear-verbatim-region`.

#### Function: ekp-verbatim-region (beg end &optional announce)

Keep paragraphs intersecting BEG through END verbatim this session.

**Arguments.** BEG and END delimit the region. ANNOUNCE requests interactive feedback.

**Semantics.** Every hard paragraph that intersects the range stays under the buffer's natural wrapping while the rest of the buffer is projected. The unit is the paragraph, not the marked characters: marking a single word protects the whole paragraph that contains it, because a partial justification of one paragraph is not meaningful. The protection is session-local and is an input to layout, so ordering with justification does not matter: mark first and justify, or justify first and mark, and the paragraph stays natural either way.

**Returns.** Unspecified; the marking is the effect.

**Errors.** None.

**Example.**

```elisp
(ekp-verbatim-region (point) (line-end-position))
(ekp-justify-buffer)
     ⇒ the paragraph at point keeps its own wrapping
```

**See also.** `ekp-clear-verbatim-region`, `ekp-org-setup`, `ekp-markdown-setup`.

#### Function: ekp-clear-verbatim-region (beg end &optional announce)

Clear verbatim protection from BEG through END.

**Arguments.** BEG and END delimit the region. ANNOUNCE requests interactive feedback.

**Semantics.** It removes verbatim protection from the range, so the intersecting paragraphs become eligible for projection again. As with the no-break clear command, the removal takes effect at the next layout call or immediately under the automatic mode; it is also the way to undo a protection that was applied to the wrong paragraph.

**Returns.** Unspecified; the removal is the effect.

**Errors.** None.

**Example.**

```elisp
(ekp-clear-verbatim-region (point) (line-end-position))
(ekp-refill-paragraph)
     ⇒ the paragraph is projected again
```

**See also.** `ekp-verbatim-region`, `ekp-allow-break-region`.

## Org and Markdown

Org and Markdown delimit code by faces, and the mode profile for each major mode lists the block faces whose paragraphs must stay verbatim and the inline faces whose spans use the inline-code break policy. The presets apply automatically while the automatic mode is on; the two setup functions copy the same policy into buffer-local variables for manual justification, so a call to `ekp-justify-buffer` in an Org or Markdown buffer protects code without any further configuration.

#### Function: ekp-org-setup ()

Protect common Org structural faces in the current buffer.

**Arguments.** None.

**Semantics.** It sets the buffer's skip-face list to the Org structural faces — block, block-begin-line, block-end-line, table and meta-line — and the inline-face list to `org-code` and `org-verbatim`. Paragraphs wearing a skip face are left verbatim; spans wearing an inline face follow the inline-code policy, whose default keeps their source spacing literal and suppresses dictionary hyphenation while still allowing ordinary breaks. The values are buffer-local: calling the function in one buffer does not affect another, and it does not modify the global defaults.

**Returns.** Unspecified; the buffer-local face lists are the effect.

**Errors.** None.

**Example.**

```elisp
(add-hook 'org-mode-hook #'ekp-org-setup)
     ⇒ Org code blocks stay verbatim under manual justification
```

**See also.** `ekp-markdown-setup`, `ekp-verbatim-region`.

#### Function: ekp-markdown-setup ()

Protect common Markdown code faces in the current buffer.

**Arguments.** None.

**Semantics.** The Markdown counterpart of `ekp-org-setup`: it sets the buffer-local skip faces to the code, pre and table faces and the inline faces to the inline code face. The same rules then apply — block faces keep their paragraphs verbatim, inline spans use the inline-code policy. Markdown modes that derive from `markdown-mode` inherit the profile through the mode alist, and an explicit call to this function fixes the choice for the buffer.

**Returns.** Unspecified; the buffer-local face lists are the effect.

**Errors.** None.

**Example.**

```elisp
(add-hook 'markdown-mode-hook #'ekp-markdown-setup)
     ⇒ fenced code stays verbatim while prose is justified
```

**See also.** `ekp-org-setup`, `ekp-verbatim-region`.

## Diagnosing layout

When a buffer does not look the way the source suggests it should, the question is usually which measure was used and which paragraphs were skipped. `ekp-diagnose` answers both without changing anything: it reports the width story, the active policy and every conflict recorded by the last justify call.

#### Function: ekp-diagnose ()

Report the authoritative width and any skipped projection conflicts.

**Arguments.** None.

**Semantics.** It reads the buffer's window, its measure option and its policy context, and emits one echo-area summary: the requested measure, the narrowest live window width, the effective width, whether the effective width exceeds the window (overflow risk), and the number of conflicts, followed by the active inline-code, hyphenation, kinsoku and overlong-token policies. The conflict list holds one entry per paragraph that the last justification did not project, each with the range and the reason, such as a foreign display owner or the automatic paragraph limit.

**Returns.** A diagnostic plist with the requested, narrowest, effective and `:width` values, the `:overflow-risk` flag, the `:policy` plist used for the pass and the `:conflicts` list. The plist is fresh data; changing it does not affect the buffer.

**Errors.** None. Diagnosing a buffer that has never been justified reports zero conflicts and the width that a justification would use.

**Example.**

```elisp
(let ((report (ekp-diagnose)))
  (list (plist-get report :width) (plist-get report :conflicts)))
     ⇒ (77 ((1 45 "foreign `display' property")))
```

**See also.** `ekp-auto-justify-mode`, `ekp-justify-region`.

## Errors and recovery

The interactive layer has few failure modes, and none of them damages text. A width argument is either a positive integer or a user error: `ekp-justify-region`, `ekp-justify-buffer`, and the automatic mode through its measure option all validate the width they will use, and a rejected call changes nothing. An interactive command in a read-only buffer signals `buffer-read-only` before it starts; the same command called from Lisp is not blocked by the read-only flag, because installing or removing display state does not modify the buffer.

Recovery follows from the model. A bad width is corrected by calling again with a valid one; a read-only buffer is unlocked first. Projections can always be removed with the unjustify commands, and protections with their clear commands, so a buffer that was laid out or protected by mistake returns to its plain state without editing the text. Because the protections are session-local, saving and reopening the file leaves no residue; re-applying them is a deliberate, explicit step.
