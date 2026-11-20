# Media and Reactions

Two components cover media and lightweight interaction: a modal viewer for one image, video or audio file, and a row of reaction chips with an optional emoji picker. Both are controlled — the caller owns the open flag, the media source or the reaction items — and both compose surfaces the earlier chapters already define. [Native Video](native-video.md) defines the video source and playback session the viewer drives, [Overlays](ui-overlays.md) the modal surface and dismissal rules, and [UI Overview](ui-overview.md) the shared contract.

## The media viewer

<!-- index: etaf-media-viewer; modal viewer; transport bar; keyboard playback -->

#### Component: etaf-media-viewer (&key open kind src source-size title subtitle caption duration on-close on-previous on-next autoplay)

Show one image, video or audio file in a controlled modal viewer over the application, inside the same buffer.

**Arguments.** OPEN is a value, ref or computed. KIND is `image` (default), `video` or `audio`. SRC is an `image` Host source — a file or image descriptor, including the SVG descriptors the icon helpers build — an `etaf-video` source for video, or an audio file played through ffplay for audio. SOURCE-SIZE is the media's pixel `(WIDTH . HEIGHT)`; without it the viewer reads the image or probes the video once. TITLE, SUBTITLE and CAPTION are optional strings: the header shows the first two, and an image's footer and an audio stage show the caption. DURATION (seconds) gives an audio file its total time. AUTOPLAY defaults to t. ON-CLOSE is required; ON-PREVIOUS and ON-NEXT are optional browse callbacks.

**Semantics.** The viewer sits on a fixed dark scrim covering the root canvas's first viewport, with its own palette independent of the application Theme, so mount it in an application whose root is one window tall such as a `(vh 100)` shell. The media keeps its aspect ratio and fits the live viewport, following window resizes: images are not enlarged beyond their natural size and video fills the stage. An image footer shows CAPTION; video and audio start when AUTOPLAY and get a transport bar with play and pause, back and forward ten seconds, elapsed and total time, a seek bar, the playback speed and sound — clicking the media toggles playback. With ON-PREVIOUS or ON-NEXT the viewer adds side arrows, the `p` and `n` keys and two-finger swipes for browsing a gallery; with images the arrow keys browse too, with video they seek five seconds. While open the viewer's keys outrank the application's, other printing keys do nothing, and closing returns focus to the prior control.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when KIND is not one of the three, DURATION is neither nil nor a non-negative number, ON-CLOSE is not a function, ON-PREVIOUS or ON-NEXT is neither a function nor nil, SOURCE-SIZE is neither nil nor a positive pixel pair, or TITLE, SUBTITLE or CAPTION is neither a string nor nil.

**Example.**

```elisp
(etaf-media-viewer :open viewer :kind 'image :src "photo.png"
                   :title "photo.png" :source-size '(640 . 480)
                   :on-close (lambda () (setf viewer nil)))
```

**See also.** `etaf-video`, `etaf-popover`.

## Reactions

<!-- index: etaf-reactions; reaction chip; emoji picker; chosen state -->

#### Component: etaf-reactions (&key items on-toggle choices add-label)

Render one row of controlled reaction chips, for example under a chat message.

**Arguments.** ITEMS — a value or ref — are plists with a unique non-nil scalar `:key` (a symbol, integer or string, the identities ETAF View keys accept), a nonempty string `:label` (usually an emoji), an optional natural `:count` shown after the label, and a boolean `:chosen`. ON-TOGGLE receives the key of the pressed chip. CHOICES, an alist of `(KEY . LABEL)`, adds a trailing smile chip named ADD-LABEL (default `"Add reaction"`) that opens a popover of the choices.

**Semantics.** A chosen chip paints the accent foreground on the accent-soft tint and carries a `chosen` class and an accessible `(chosen)` suffix; chosen and unchosen chips share padding and weight, so toggling never moves a neighbour, and only a count gaining a digit widens its chip. The picker lays the choices out six per row in four-column cells with a blank row between rows, so even wide emoji sit centered in an even grid; picking one closes the popover and calls ON-TOGGLE with that key. The row does not wrap, so keep ITEMS short enough for its container.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ITEMS is not a list of reaction plists with unique scalar keys, nonempty labels and natural counts; CHOICES is not an alist of unique keys and nonempty string labels; ON-TOGGLE is not a function; or ADD-LABEL is not a nonempty string.

**Example.**

```elisp
(etaf-reactions :items '((:key heart :label "❤" :count 3 :chosen t)
                         (:key laugh :label "😂"))
                :choices '((heart . "❤") (laugh . "😂") (party . "🎉"))
                :on-toggle #'toggle-reaction)
```

**See also.** `etaf-popover`, `etaf-ui-icon`.

## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected prop through `etaf-check-prop`, naming the component, property, received value and expectation, including a bad media kind, a negative duration and a malformed reaction or choice list.
- The viewer owns no media state: it never decides when to close, and every dismissal path — Escape, `q`, the close control, an outside press — requests ON-CLOSE. A missing decoder or audio program degrades to the image host's placeholder or silence rather than failing the mount.
- Reactions are pure presentation of the caller's items: a press reports a key, and the row re-renders only when the caller's ITEMS change, so an ignored toggle leaves the chips as they were.
- Neither component keeps focus or playback state across a rejected publication: the previous committed media frame or chip row stays visible.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Overlays](ui-overlays.md).

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-reactions :items '((:key heart :label "❤" :count 3 :chosen t)
                            (:key laugh :label "😂"))
                   :on-toggle #'ignore)))
```
