# ADR-0009: The selection-copy surface

**Status:** Accepted (2026-10)
**Deciders:** cuplivo

## Context

Selecting rendered text in an assistant reply and copying it yields flattened plain text: the markdown
source that produced the rendering (`**`, `##`, `- `, `` ` ``, `[text](url)`, fences) is not recoverable
from the rendered widgets. Cuplivo 3.x shipped this as *naive subsequence Markdown copy* (PR #122),
later extended with Quote, Reply and Speak on the same captured selection. The 4.x line re-baselined on
Kelivo stable and re-does Cuplivo's features as cherry-picks, so this one had to be re-done.

**What the mapping is, is no longer this ADR's decision.** ADR-0007/0008 gave the renderer one walk that
produces a Markdown IR, and the IR re-emits the markdown a selection covers; ADR-0007 decision 5 deletes
the subsequence matcher rather than keeping it as a second fallback, "because it would fire exactly in the
unmodelled cases that are the bug". Review of the pre-IR branch measured that bug: selecting `bold text`
inside `**bold** text` returned `bold** text`, an orphaned closing delimiter — worse than a plain copy.
The IR completes the markers a cut run needs and leaves the rest of the source alone.

What is left for this record is the **surface**: which item a user sees, what exactly reaches the
clipboard, who owns a selection, and the shortcut. Three inputs come from measurement:

- The renderer writes U+200B into rendered text to make an over-long token breakable (inline code and
  table cells, plus empty cells). Those reach the clipboard on a plain copy: cuplivo #738.
- It used to write U+200C into an enumerated ATX heading to keep the list component from claiming its
  body. That mask is gone — a heading body is now walked with the inline components, which is what its
  content actually is — so nothing inserts U+200C any more.
- Review of the pre-IR branch: an ancestor copy-intent override registered for a whole bubble made Ctrl+C
  inside a code block copy **nothing** (short code, long code, table cell), because those own their
  selection area and never report to the bubble's region.
- Review of this PR found the other half of that failure: retiring the override only when the region's own
  cache is empty is not the same as retiring it when the region *no longer owns* the selection. Select
  prose, then select inside a code block (short or long), a table cell or a diagram, then Ctrl+C: the
  nested owner's selection never reaches the region, the cache still held the prose, and the override —
  which the framework's own copy actions forward to (`Action.overridable`) — wrote the stale prose where
  master, registering no override at all, copies the nested text.

## Decisions

1. **One short item, `Markdown`, next to the platform Copy.** The choice reads "markdown source" versus
   "clean plain text"; v3's pair ("Copy as Markdown" / "Copy as Plain Text") restated the verb and was
   hard to scan. The platform Copy stays, sanitized.
2. **Offered while a reply streams.** v3 hid the item until generation finished. The selection is
   captured by value, so appended content cannot shift it, and a source rewritten underneath degrades to
   sanitized plain text — hiding the item only removed a working action.
3. **The surface hands the mapping the renderer's own inputs.** The bubble's source, the settings that
   pick the component set, the streaming flag, and the `MarkdownDetailsExpansion` record the renderer
   reads (ADR-0007 decisions 3 and 7), with the walk rebuilt per copy rather than cached per rendered
   widget. Menu item and hotkey go through one mapping so they cannot drift apart — but they read
   *different* selections, and that is now the rule rather than an accident: **the item maps the
   surface that built the menu**, while the hotkey maps the most recent assistant selection, because a
   global shortcut has no surface to ask. With split-paragraph bubbles each part is its own surface and
   keeps its own selection text, exactly as it already keeps its own expansion record.
4. **Sanitize the clipboard by exactly what the renderer inserts, and only that.** U+200B goes; the
   broader invisible set stays in the IR's *matching* normalization, where a lossy answer only means a
   fallback. There is no U+200C rule: nothing inserts it, and a ZWNJ in copied text is orthography
   (Persian, Arabic, Urdu) that a clipboard must keep. This is the general fix for #738 at every markdown
   selection surface, not a feature-local one.
5. **The copy-intent override covers this surface's selection, and retires the moment a nested owner
   claims one.** A diagram's code view and the lazy code viewport past the line threshold are what still
   nest an owner the framework copies itself — ADR-0010 moved a code block's body and a table's cells onto
   this surface's own area, and leaves an owner nested only where the area cannot reach the text. Such a
   selection never reaches this region's `onSelectionChanged`, and the framework builds its own copy
   actions with `Action.overridable`, so they *forward to* an ancestor override: while it is registered it
   wins inside them too. The region is silent about that: the probe that measured this bug prints its
   `onSelectionChanged` still reporting the prose after the nested drag, so the claim cannot be inferred
   and has to come from the owner. Every owner the project builds reports it, and a source-level test fails
   when the number of claims in those files stops matching the number of owners in them — which is what
   keeps a new owner from arriving without that report. A caller that nests its own selectable inside this
   area owes the same report; nothing else can stand the override down. Each nested owner therefore reports
   the claim, the area drops its cache, and the framework copies the nested owner's own text. Measured cost,
   recorded rather than hidden: that copy is un-sanitized, and on this line it is a contract rather than an
   observable leak — what those owners show is code or diagram source, with no renderer-inserted character
   to strip. A claim retires the override but not the region's *own* selection
   — this state holds no handle on the region's `SelectableRegionState`, and the selection is still the
   user's — so re-selecting the **identical** text in that region reports no change (the framework compares
   `plainText`), leaves the cache empty, and that copy is un-sanitized too. Selecting different text reports
   a change and restores the override; so does any `Markdown` item press, which reads the per-part
   selection text rather than the cache.
6. **A desktop hotkey for the same action**, default `Ctrl+Shift+C` / `Cmd+Shift+C`, rebindable, in the
   existing in-app hotkey scope so it does not claim a system-wide key. It acts on the recorded assistant
   selection, which is what makes it a workaround for the framework dismissing a long backward selection
   on right-click. That dismissal itself is a framework behaviour and is not worked around further;
   `Ctrl+X`, `Ctrl+Q` and `Ctrl+R` were rejected as defaults.

## Consequences

- The assistant selection menu reads **Copy | Markdown | Share | Select All**. The `Markdown` item
  finishes the way the platform's Copy does — the selection survives on iOS and desktop, Android clears
  it — rather than clearing it everywhere.
- Keyboard copy, toolbar Copy and Share from any markdown surface no longer carry renderer-inserted
  characters. A nested owner's copy is the exception, by decision 5.
- Carried-over limits, each a degrade rather than a silent wrong answer: a selection that repeats inside
  one bubble maps to the **first** occurrence — so the emitted markdown can carry markup the user did not
  select (`Setup` maps by the earlier `## Setup`, `npm ci` by the earlier code span, `docs` by the
  earlier link). Nothing better is available to the mapping: the framework reports a selection as text
  alone (`SelectedContent` carries `plainText` only), so it has no offset, let alone one it could prefer.
  Markers that sit entirely outside the selection are dropped (the span rule); table pipes ride along with
  the source range; a nested owner's copy is un-sanitized.
- 选区记忆 is single-slot and assistant-only, and it is filed under the surface that recorded it: a
  surface that goes away (a reply scrolled out of the viewport, a conversation switched away from) retires
  its own recording, so the hotkey can never copy a selection the user cannot see. It holds the most
  recent assistant selection whichever bubble made it — a global shortcut has no surface to ask — and a
  selection made in another markdown surface (or a right-click that clears the selection first) leaves the
  hotkey with nothing. The toast reports what was actually copied.
- The `Markdown` item never consults 选区记忆: it maps the selection of the surface whose menu is open, so
  two replies (or two split parts) holding live selections cannot answer for each other.
- Reasoning text is sanitized but has no `Markdown` item: what it displays is not the source the mapping
  would run against.

## Not in scope

- Quote, reply-with-quote and speak-selection: v3 built all three on the same captured selection, and
  reply is schema-level on this line. **Amended by ADR-0012**: the reply's ranged item now sits beside
  this one in the same toolbar, from the same mapping, and the citation it stores is a snapshot rather
  than a range — so it needs no schema version and no relocation matcher. 引用粘贴 and
  speak-selection stay out of scope.
- A `Markdown` item for a selection made *inside* a nested area: a selection inside a table cell or a code
  body is the bubble's own selection and reaches the same item, because ADR-0010 put those on the surface's
  area; one made inside a diagram's code tab or a body past the lazy threshold belongs to that block
  instead, and the block's own toolbar is what serves it.
- Making the soft breaks disappear from copies altogether instead of being stripped: the softening
  itself is a renderer decision, and this record keeps the strip as the clipboard's narrow backstop. (The
  `SelectableAdapter` route it once named is no longer needed for correctness: a widget-backed inline run
  under the surface's owner contributes its own text and the placeholder is never copied — ADR-0010.)
