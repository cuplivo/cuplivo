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
   widget. Menu item and hotkey go through one mapping so they cannot drift apart.
4. **Sanitize the clipboard by exactly what the renderer inserts, and only that.** U+200B goes; the
   broader invisible set stays in the IR's *matching* normalization, where a lossy answer only means a
   fallback. There is no U+200C rule: nothing inserts it, and a ZWNJ in copied text is orthography
   (Persian, Arabic, Urdu) that a clipboard must keep. This is the general fix for #738 at every markdown
   selection surface, not a feature-local one.
5. **The copy-intent override is registered only while this surface owns a selection.** A code block and
   a table cell own their selection area (ADR-0008 decision 6), so the bubble's override covers
   selections it cannot read; standing down leaves those to the framework, which is what copied them
   before. Measured cost, recorded rather than hidden: such a copy is un-sanitized, and the only surface
   where that is observable is a table cell's soft-break ZWSPs, which leaked before this branch existed.
6. **A desktop hotkey for the same action**, default `Ctrl+Shift+C` / `Cmd+Shift+C`, rebindable, in the
   existing in-app hotkey scope so it does not claim a system-wide key. It acts on the recorded assistant
   selection, which is what makes it a workaround for the framework dismissing a long backward selection
   on right-click. That dismissal itself is a framework behaviour and is not worked around further;
   `Ctrl+X`, `Ctrl+Q` and `Ctrl+R` were rejected as defaults.

## Consequences

- The assistant selection menu reads **Copy | Markdown | Share | Select All**.
- Keyboard copy, toolbar Copy and Share from any markdown surface no longer carry renderer-inserted
  characters.
- Carried-over limits, each a degrade rather than a silent wrong answer: a selection that repeats inside
  one bubble maps to the first occurrence; markers that sit entirely outside the selection are dropped
  (the span rule); table pipes ride along with the source range; a nested owner's copy is un-sanitized.
- 选区记忆 is single-slot and assistant-only, so a selection made in another markdown surface (or a
  right-click that clears the selection first) leaves the hotkey with nothing; the toast reports what was
  actually copied.
- Reasoning text is sanitized but has no `Markdown` item: what it displays is not the source the mapping
  would run against.

## Not in scope

- Quote, reply-with-quote and speak-selection: v3 built all three on the same captured selection, and
  reply is schema-level on this line.
- A `Markdown` item for a selection made *inside* a nested area: the renderer owns those menus, and the IR
  maps no display text for a code body or a table (ADR-0007 consequences).
- Making the soft breaks disappear from copies altogether instead of being stripped — the emitter's
  `SelectableAdapter` route for widget-backed inline runs, and removing the table-cell softening at the
  source. Both are renderer slices of the #1017 line; this record keeps the strip as the clipboard's
  narrow backstop until then.
