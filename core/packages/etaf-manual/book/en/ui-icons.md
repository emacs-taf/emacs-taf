# Icons

An icon is a small, non-text mark that occupies standard text rows and keeps the surrounding layout untouched. The catalog draws icons from a *registry*: a set maps a symbolic name such as `play` to a font glyph or an SVG body, and the component resolves a name through an explicit set, the default set and the built-in fallbacks before finally showing the name itself. This chapter defines the registry and its lifecycle, the resolution order, the icon and toggle components, the text variant used in retained updates, the metrics query that tells whether a set fits the standard line, and the SVG element helpers for composing scenes. [UI Overview](ui-overview.md) defines the catalog's shared contract, [Hosts](hosts.md) the box properties the icon Host uses, and [Images](images.md) the image Host that renders the composed scenes.

## The registry

<!-- index: icon set; icon glyph; SVG icon; fallback; registry order -->

An icon set is registry data, not a new element type. Six sets ship built in: `nerd`, `fa`, `material`, `octicons` and `sys` draw font glyphs, and `svg` draws vector paths. `etaf-ui-icon-sets` returns them in registration order, and each set has one specification object.

A font specification needs a family name, a height ratio relative to the standard line, and a map from symbolic names to single characters; a set whose font is absent or lacks a glyph simply cannot supply that name, and resolution moves on. An SVG specification needs a viewbox and path bodies or nullary draw functions, with a default inset that keeps the drawing clear of the box edge. Either kind may supply printable-ASCII fallbacks for terminal frames and for names the font cannot draw.

Registration is atomic and versioned by replacement: registering a name that already exists replaces its whole specification, every validation failure leaves the registry unchanged, and a successful change invalidates the cached fonts, faces and images so the next render resolves the new data. Values already on mounted surfaces stay valid until their next render; a registry change never re-renders mounted components by itself.

## Resolving a name

<!-- index: resolution order; default set; missing glyph; plain-text fallback -->

Resolution walks a fixed candidate chain: the explicitly requested set, then `etaf-ui-icon-default-set`, then `sys`, then `svg`, and finally the plain name. On a text terminal a request for the `svg` set resolves through the registered `tty` set first, because a terminal cannot draw the artwork at all; names that set does not cover continue to the requested set and the rest of the chain. A font-set request keeps the requested set first and consults `tty` second. A candidate qualifies only when it contains the name and can actually draw it: a font set whose family is missing, or whose font has no glyph for the character, is skipped, so a partial set falls through to the next candidate instead of failing. When no candidate qualifies, the name itself is shown as text, with control and non-ASCII characters escaped so a hidden name cannot corrupt the display.

An explicitly requested set must be registered; an unknown one is a usage error rather than a reason to fall through, because the caller asked for something specific. The default set is a preference, not an override: it is consulted after the explicit set, and configuring an unregistered default makes every resolution fail even when the explicit set is valid.

On graphical frames with SVG support, a font glyph is drawn as SVG text in the same square canvas as the vector sets, so ink that exceeds the font's declared ascent and descent is never clipped by the row. Without SVG, a font set falls back to its clamped named face as text, and a two-row icon puts the text variant on the first row while reserving the second.

## Painted size and rows

<!-- index: icon size; clamped size; two-row icon; image slice; min-width -->

An icon reserves one standard row by default and exactly two rows with two lines requested. Its size scales the drawn box but is clamped to the reserved pixel height, so a large scale value cannot enlarge the line. The rows always come from the standard line height, never from the glyph's intrinsic metrics; a set whose declared metrics exceed the line is still safe to draw, and the metrics query reports that the unclamped declaration does not fit.

Two-row icons use two slices of one square canvas; one-row icons use the whole canvas. The icon Host keeps `max-content` width, a minimum width in character cells, and hidden overflow, and centers the drawing in each row. The minimum width keeps a narrow glyph — a single character or a small vector — from collapsing the click target below a usable size.

Only a pixel-level color reaches the drawing: the component takes foreground and background from the color and face props and ignores every other face attribute, because a caller's typography must not change the icon's line metrics. The vector scenes use the foreground through `currentColor`, so a themed color flows into path fills that use it.

## The icon component

<!-- index: etaf-ui-icon; pressable icon; accessible icon name -->

#### Component: etaf-ui-icon (&key name set size color face lines min-width help-echo on-press tab-index aria-label id class ref)

Render one semantic icon in one or two standard rows.

**Arguments.** NAME is a nonempty symbol or string naming the icon. SET is the explicitly requested set; an unknown set is a usage error. SIZE is a positive number scaling the drawing, clamped to the reserved rows, and defaults to 1.0. COLOR is a pixel color that overrides the icon's foreground; FACE is a face name or a plist whose foreground and background are used and whose other attributes are ignored. LINES is 1 or 2 and defaults to 1. MIN-WIDTH is a positive number of character cells (default 2). HELP-ECHO is a string painted as native help. ON-PRESS is a zero-argument callback on the complete box. TAB-INDEX is the icon's Tab index when pressable and defaults to 0. ARIA-LABEL is the accessible name and defaults to a string HELP-ECHO, then NAME. ID, CLASS and REF reach the rendered Host.

**Semantics.** The name is resolved as [Resolving a name](#resolving-a-name) describes and painted as [Painted size and rows](#painted-size-and-rows) describes. A pressable icon is a Tab stop with `:on-press`; a negative TAB-INDEX keeps it clickable but out of Tab order, for example when an enclosing list already owns the keyboard. The whole box is the press target, including both rows of a two-row icon. The help text is left unset when omitted so an enclosing control's own help stays visible.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when SIZE is not positive, LINES is neither 1 nor 2, MIN-WIDTH is below one cell, or ON-PRESS is neither a function nor nil. `error→ user-error` when NAME is neither a symbol nor a nonempty string, or when SET names an unregistered set.

**Example.**

```elisp
(etaf-ui-icon :name 'play :set 'svg :help-echo "Play"
              :on-press (lambda () (message "Playing")))
```

**See also.** `etaf-ui-icon-lines`, `etaf-ui-toggle-icon`, `etaf-ui-icon-metrics`.

#### Function: etaf-ui-icon (name &key set (size 1.0) color face (lines 1) (min-width 2) help-echo on-press tab-index aria-label id class ref)

Return the same typed icon View from ordinary Elisp with positional NAME.

**Arguments.** NAME is the first, positional argument; the keyword arguments are those of the Component form.

**Semantics.** Pass the result directly to `etaf-mount`, or use the Component's `:name` form inside `etaf-view`. The rendered box, resolution, painting and errors are exactly those of the Component entry above.

**Returns.** A View.

**See also.** the `etaf-ui-icon` Component entry.

## Text variants

<!-- index: etaf-ui-icon-lines; retained icon text -->

#### Function: etaf-ui-icon-lines (name &key set (size 1.0) color face (lines 1))

Return owned propertized strings for one or two standard icon rows.

**Arguments.** NAME, SET, SIZE, COLOR and FACE use the same resolution and painting as `etaf-ui-icon`. LINES is 1 or 2 and defaults to 1.

**Semantics.** The result is a list of LINES strings. Each row is ready to be a Text payload: it carries the image or face properties the icon needs, and a two-row result puts the drawing or text on the first row and the reserved second row's content on the second. Resolve this once in a Component binding and select the strings from retained Host text expressions instead of adding an overlapping positioned icon. Returned strings are independent copies, so a caller may change one without affecting another or the shared image; shared image values must not be mutated.

**Returns.** A list of LINES propertized strings, in row order.

**Errors.** `error→ etaf-component-call-error` when SIZE is not positive or LINES is neither 1 nor 2. `error→ user-error` when NAME is neither a symbol nor a nonempty string, or when SET names an unregistered set.

**Example.**

```elisp
(etaf-ui-icon-lines 'play :set 'svg :lines 2)
     ⇒ (">" " ")
```

**See also.** `etaf-ui-icon`, [Reactivity](reactivity.md).

## The toggle icon

<!-- index: toggle icon; retained text update; on-color -->

#### Component: etaf-ui-toggle-icon (&key value off on set size color on-color face lines min-width help-echo on-press tab-index aria-label id class ref)

Render one icon that switches between OFF and ON through retained Host text.

**Arguments.** VALUE is a boolean or a reactive source. OFF and ON name the two variants. SET, SIZE, COLOR, FACE, LINES, MIN-WIDTH, HELP-ECHO, ON-PRESS, TAB-INDEX, ID, CLASS and REF match `etaf-ui-icon`. ON-COLOR overrides COLOR for the ON variant and defaults to it. ARIA-LABEL defaults to a string HELP-ECHO, then the name pair `"OFF / ON"`.

**Semantics.** Both variants resolve while rendering, and each row's text then reads VALUE directly, so a change publishes a retained Host text update instead of re-rendering the Component. OFF and ON may name the same icon when only ON-COLOR differs, which turns a color state such as shuffle or repeat into the same retained update. A plain boolean is a settled variant; pass a ref or computed for a value that changes. The complete box is the ON-PRESS target, exactly as for `etaf-ui-icon`.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when VALUE is neither a boolean nor a reactive source, or when any shared prop falls outside the `etaf-ui-icon` contract. `error→ user-error` for a bad name or an unregistered set.

**Example.**

```elisp
(etaf-ui-toggle-icon :value playing :off 'play :on 'pause :set 'svg)
```

**See also.** `etaf-ui-icon`, [Reactivity](reactivity.md).

## The registry interface

<!-- index: default set; icon set spec; icon names -->

#### Variable: etaf-ui-icon-default-set

The registered fallback style, initially `nerd`; bind or set it before rendering.

**Semantics.** Resolution consults the explicit set first and this variable afterwards. Changes take effect on the next render; already mounted values stay valid and are not implicitly re-rendered. The value must name a registered set, or every icon resolution fails.

**See also.** `etaf-ui-icon-set-register`, [Resolving a name](#resolving-a-name).

#### Variable: etaf-ui-terminal-icon-set

The icon set consulted first on a text terminal for an SVG request, initially `tty`.

**Semantics.** A terminal cannot draw the SVG artwork, so a request for that set resolves through this one first; names it lacks continue to the requested set and the rest of the chain. Set it to a registered font set whose glyphs the terminal font contains — `nerd` with a Nerd Font — to keep one icon family in the terminal. A font-set request keeps the requested set first and consults this one second. Names that the terminal set does not cover fall through, so a partial set is safe.

**See also.** `etaf-ui-icon-default-set`, `etaf-ui-icon-set-register`, [Resolving a name](#resolving-a-name).

#### Function: etaf-ui-icon-set-register (name spec)

Register NAME with the icon set SPEC, replacing a previous registration, and return NAME.

**Arguments.** NAME is a symbol. For a font set, SPEC needs `:kind font`, a string `:family`, a positive float `:height` relative to the default line, and a `:glyphs` alist mapping symbols to single characters above the control range. For an SVG set it needs `:kind svg`, a four-number `:viewbox` with positive width and height, and `:paths` (symbol to body string) and/or `:draw` (symbol to nullary function), plus an optional nonnegative integer `:inset` defaulting to 2 pixels. Either kind accepts an optional `:fallback` alist mapping names to nonempty printable-ASCII strings.

**Semantics.** Registration validates SPEC completely before replacing anything, so an invalid specification leaves the registry unchanged; a successful registration or replacement invalidates every cached font, face and image, so the change is visible to the next render. Treat the stored specification as immutable: re-register to change it. Duplicate names within one specification are rejected.

**Returns.** NAME.

**Errors.** `error→ user-error` for an invalid name or specification shape (`"Invalid icon set name/specification: %S"`), a font or SVG specification missing a required member (`"Invalid font icon set specification for %S"` / `"Invalid svg icon set specification for %S"`), duplicate names (`"Duplicate icon names in %S"`), or a fallback that is not a nonempty printable-ASCII string (`"Icon fallbacks must be nonempty printable ASCII strings"`). The messages name the set where possible.

**Example.**

```elisp
(etaf-ui-icon-set-register
 'brand '(:kind svg :viewbox [0 0 16 16]
                :paths ((logo . "<path d='M2 8L8 2L14 8L8 14Z'/>"))
                :fallback ((logo . "L"))))
```

**See also.** `etaf-ui-icon-set-remove`, `etaf-ui-icon-sets`, `etaf-ui-icon-set-spec`.

#### Function: etaf-ui-icon-set-remove (name)

Remove registered set NAME and invalidate the cached fonts, faces and images.

**Semantics.** Removing an absent set is harmless. Existing rendered values remain valid until their next render, and the removal returns nil.

**Returns.** nil.

**See also.** `etaf-ui-icon-set-register`.

#### Function: etaf-ui-icon-sets ()

Return registered icon set names in registration order.

**Semantics.** The list reflects the current registry; custom sets appear after the built-in `nerd`, `fa`, `material`, `octicons`, `sys` and `svg` sets in the order they were registered.

**Returns.** A list of set name symbols.

**See also.** `etaf-ui-icon-names`.

#### Function: etaf-ui-icon-set-spec (name)

Return the stored immutable specification for NAME, or nil when it is absent.

**Semantics.** The returned object is the registry's own data. Do not mutate it; re-register the name to change it.

**Returns.** The specification plist, or nil.

**See also.** `etaf-ui-icon-set-register`.

#### Function: etaf-ui-icon-names (&optional set)

Return SET's own names, or the union of all sets when nil.

**Semantics.** The result lists the names the set declares — glyphs, paths and draw functions together — and never invents names through fallback lookup; use the component for resolution. With nil, the union of every registered set is returned without duplicates.

**Returns.** A list of name symbols.

**Errors.** `error→ user-error` for an unknown non-nil SET.

**Example.**

```elisp
(memq 'play (etaf-ui-icon-names 'svg))  ⇒ (play)
```

**See also.** `etaf-ui-icon-sets`.

## Metrics

<!-- index: icon metrics; fit; missing font -->

#### Function: etaf-ui-icon-metrics (set &optional frame)

Return unclamped SET metrics relative to FRAME's standard line.

**Arguments.** SET is a registered set name. FRAME defaults to the selected frame.

**Semantics.** The returned plist has `:family` (the declared family or nil for SVG), `:height` (the declared ratio), `:line-pixel-height` (the row the *declaration* would need), `:line-height` (the frame's standard row) and `:fit` (non-nil when the declared row is no larger than the standard row). Font metrics include the surrounding default font's ascent and descent, because a taller font can grow a mixed text row through either half of the baseline. A missing GUI font reports nil `:line-pixel-height` and nil `:fit`. In batch or terminal frames, where no font is resolved, the height is estimated from the declared ratio and the standard row, without claiming font availability. SVG sets report the line box.

**Returns.** The metrics plist.

**Errors.** `error→ user-error` for an unknown SET.

**See also.** [Painted size and rows](#painted-size-and-rows), `etaf-ui-icon`.

## SVG scenes

<!-- index: SVG scene; SVG element; image descriptor; scene caching -->

The SVG scene helpers compose a scene as markup and hand it to an image source or image Host through `etaf-ui-svg-image`. Each element helper validates its geometry and attributes, XML-escapes text and string attribute values, formats numbers identically, and omits an attribute whose value is nil. Every failure signals `etaf-ui-svg-error` before any markup is produced, so an invalid scene never paints partially. Keep a text fallback for terminal frames, and cache a composed scene by its state key rather than rebuilding the document on every redraw.

#### Function: etaf-ui-svg-rect (x y width height &rest attributes)

Return SVG markup for a rectangle at X/Y with positive WIDTH and HEIGHT.

**Arguments.** ATTRIBUTES accept `:rx`, `:ry`, `:transform` and the shared paint family `:fill`, `:stroke`, `:stroke-width`, `:stroke-linecap`, `:stroke-linejoin`, `:stroke-dasharray` and `:opacity`.

**Example.**

```elisp
(etaf-ui-svg-rect 0 0 16 10 :rx 2 :fill "#F0E2C6")
     ⇒ "<rect x='0' y='0' width='16' height='10' rx='2' fill='#F0E2C6'/>"
```

**See also.** `etaf-ui-svg-image`, `etaf-ui-svg-error`.

#### Function: etaf-ui-svg-circle (cx cy radius &rest attributes)

Return SVG markup for a circle centred at CX/CY with positive RADIUS.

**Arguments.** ATTRIBUTES accept `:transform` and the shared paint family `:fill`, `:stroke`, `:stroke-width`, `:stroke-linecap`, `:stroke-linejoin`, `:stroke-dasharray` and `:opacity`.

**See also.** `etaf-ui-svg-image`.

#### Function: etaf-ui-svg-line (x1 y1 x2 y2 &rest attributes)

Return SVG markup for a line from X1/Y1 to X2/Y2.

**Arguments.** ATTRIBUTES accept `:stroke`, `:stroke-width`, `:stroke-linecap`, `:stroke-linejoin`, `:stroke-dasharray` and `:opacity`.

**See also.** `etaf-ui-svg-image`.

#### Function: etaf-ui-svg-path (d &rest attributes)

Return SVG markup for path data D, a nonempty string.

**Arguments.** ATTRIBUTES accept `:fill`, `:stroke`, `:stroke-width`, `:stroke-linecap`, `:stroke-linejoin`, `:stroke-dasharray` and `:opacity`.

**See also.** `etaf-ui-svg-image`.

#### Function: etaf-ui-svg-text (x y text &rest attributes)

Return SVG markup for single-line TEXT anchored at X/Y; its content is XML escaped.

**Arguments.** ATTRIBUTES accept `:font-family`, `:font-size`, `:font-weight`, `:text-anchor`, `:dominant-baseline`, `:fill`, `:stroke`, `:stroke-width` and `:opacity`.

**See also.** `etaf-ui-svg-image`.

#### Function: etaf-ui-svg-group (children &rest attributes)

Return SVG markup for group CHILDREN sharing ATTRIBUTES.

**Arguments.** CHILDREN is the concatenated markup of nested elements. ATTRIBUTES accept `:transform`, `:fill`, `:stroke`, `:stroke-width`, `:stroke-linecap`, `:stroke-linejoin`, `:stroke-dasharray` and `:opacity`.

**See also.** `etaf-ui-svg-image`.

#### Function: etaf-ui-svg-image (body width height viewbox &optional preserve-aspect-ratio)

Return an `(image :type svg :data STRING)` descriptor showing scene BODY in a WIDTH by HEIGHT pixel box over VIEWBOX.

**Arguments.** BODY is markup composed from the element helpers. WIDTH and HEIGHT are the pixel box the prepared image fills; VIEWBOX is the scene window `(X Y WIDTH HEIGHT)` mapped onto that box, with positive size. PRESERVE-ASPECT-RATIO is nil for the SVG default centring, `none` to scale the complete scene to the box; any other value is an error.

**Semantics.** The descriptor is accepted by image sources and image Hosts such as the tile grid's cell image. Ebox draws one image per displayed row, so slice per cell only where each cell owns its own interaction target and use block rows for passive artwork.

**Returns.** An image descriptor.

**Errors.** `error→ etaf-ui-svg-error` when BODY is not a string, the viewbox is not four numbers with positive size, a width or height is not positive, or the aspect-ratio argument is neither nil nor `none`.

**Example.**

```elisp
(etaf-ui-svg-image
 (concat (etaf-ui-svg-rect 0 0 16 10 :fill "#F0E2C6" :stroke "#A98956")
         (etaf-ui-svg-circle 8 5 3.6 :fill "#FFF8E7")
         (etaf-ui-svg-text 8 6.4 "车" :fill "#AD3830" :font-size 8
                           :text-anchor "middle"))
 48 30 '(0 0 16 10))
```

**See also.** `etaf-ui-svg-error`, [Images](images.md).

#### Error: etaf-ui-svg-error

Invalid input to the SVG scene helpers.

**Semantics.** Raised before any markup is produced, with a message naming the element, the geometry or attribute and the received value. Accepted attribute keys are element-specific; unknown or repeated keys, a missing value, a value of the wrong kind, non-positive geometry, invalid text and an invalid aspect-ratio argument all signal this condition.

**See also.** the SVG element entries above.

## Errors and recovery

- Invalid props of the icon components signal `error→ etaf-component-call-error` through `etaf-check-prop`, naming the component, the property, the received value and the expectation: a non-positive SIZE, LINES other than 1 or 2, MIN-WIDTH below one cell, ON-PRESS that is neither a function nor nil, and a VALUE that is neither boolean nor a reactive source.
- A bad icon name or an unregistered set signals `error→ user-error`, because the registry cannot resolve the request; the message names the name or the set.
- Scene construction signals `error→ etaf-ui-svg-error` and returns no markup, so a caller can catch one condition around a whole scene composition.
- Registry failures are atomic: a rejected registration leaves the previous specification and the rendered values untouched. A successful change takes effect at the next render and never re-renders mounted components implicitly.
- A missing font or glyph is not an error: resolution falls through the candidate chain and finally shows the name as plain text.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery).

```elisp :run
(etaf-view
 (row :item-gap '(ch 2) :cross-align 'center
   (etaf-ui-icon :name 'play :set 'svg :help-echo "Play")
   (etaf-ui-toggle-icon :value t :off 'play :on 'pause :set 'svg)
   (etaf-ui-icon :name 'heart :set 'svg :color "#B73951")
   (etaf-ui-icon :name 'play :set 'svg :lines 2)))
```
