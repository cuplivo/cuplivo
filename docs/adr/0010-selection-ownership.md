# ADR-0010: Selection ownership — one owner per surface

**Status:** Accepted (2026-10)
**Deciders:** cuplivo

## Context

ADR-0007 decision 3 made display text the node's own business, and ADR-0008 decision 6 let every
widget-backed block *own its selection area*: a code block, a table, a formula and a diagram each
participated in the outer display space as a gap node and nothing else. That was measured rather than
assumed, and it made the copy mapping honest for the shapes it covered.

Two consequences were measured on the shipped renderer, and neither is fixable from the mapping side:

- **A cell's own `SelectableText` bakes a widget-backed run into one U+FFFC.** An editable's value is
  `textSpan.toPlainText()`, and a `WidgetSpan` is a `PlaceholderSpan` that plain text represents as a
  single object-replacement character. Copying a cell therefore put that character on the clipboard —
  the reported `[OBJ]` — and the run had no interior position to select into, so the code inside a cell
  could not be selected at all. (Probe: the value is `before \uFFFC after`, so the four characters of
  `code` are one character of value, and the clipboard is a substring of that value.)
- **Nested owners cannot be crossed.** One drag stopped at each owner, each owner built its own toolbar,
  and the copy-intent override had to stand down for selections it could not read (ADR-0009 decision 5),
  which left those copies un-sanitized.

Flutter already provides the mechanism the renderer was not using. A widget takes part in the
*enclosing* selection either by being text under it (`Text`/`RichText` registers with the ancestor
registrar, and `RenderParagraph` splits itself on placeholders and never copies them) or by declaring
what it contributes (`SelectableAdapter`, or `SelectionContainer` with a delegate); `SelectionContainer.disabled`
opts a subtree out. Nothing forces a second owner.

## Decisions

1. **One selection owner per surface.** The assistant bubble's `SelectionArea` owns the selection for the
   whole message, and a markdown surface without one provides it (the skill body, the export sheet).
   Everything selectable in that surface is a paragraph of that owner; a block whose text the owner
   cannot reach nests its own instead: a diagram's code tab — a view of its own, `SelectableText` or the
   code view — and the lazy code viewport, which only builds the chunks it shows. Those report the claim,
   which is why the copy-intent override still stands down on one (ADR-0009 decision 5).
2. **A table cell and a code body are ordinary paragraphs — up to the lazy threshold.** A cell renders
   `Text.rich`, and so does a code block's body; one drag crosses cells and a block. Past the threshold
   the body is a chunk viewport that builds only the chunks it shows, so its text is not reachable from
   the owner at all: the block owns its own selection, and its node is a gap, like a diagram's.
3. **A widget-backed run declares what it contributes.** Text-like content is text: a run that must be a
   widget — a link, a citation chip, an inline formula, an image — declares the text it shows, which is
   what makes it copyable and partially selectable from the surrounding selection. Content with no text
   of its own (a rule, a diagram, a disabled display-math block) contributes nothing.
4. **The display space must equal what the renderer contributes.** If a selection reports a table's cells
   and a code block's body, the IR declares them: the table node is `opaque` with its cells' text, and
   `FencedCodeBlockMd` declares the code the block shows. A node that declares no display text is a node
   that contributes none — a gap is for what really shows nothing. A diagram's fence is that gap: its
   preview is a bitmap and its code view owns its own selection, so the surface contributes no line of
   the diagram's text, and one predicate decides both the routing and the walk.
5. **Render state that changes what is shown is an input to the document build.** ADR-0007 decision 7
   made `<details>` expansion an input; a collapsed code block shows its first lines, and a selection
   over it reports only those, so the same holds there. `MarkdownCodeExpansion` carries the setting while
   the blocks themselves record their manual toggles, exactly as `MarkdownDetailsExpansion` does.
6. **Chrome is not text.** A table's toolbar and row pager, a code block's header, and a diagram's loading
   and error hints stay out of the selection, so copying a whole surface yields its text and never a
   button label or a status line. A code block's header already had this through its toggle; it is stated
   once here so it is not re-derived per widget.

## Consequences

- One drag selects across prose, cells and code bodies, and one toolbar serves the surface; a body past
  the lazy threshold is selected inside its viewport instead, and a selection spanning it re-emits the
  whole fence, because its gap is what carries the fence back.
- A copied cell carries the code it shows instead of U+FFFC, and a selection spanning a table or a code
  block maps to its source, re-emitting the table or the fence, because the display space declares what
  the selection reports.
- The un-sanitized nested copy of ADR-0009 decision 5 keeps a narrower case than it was written for: a
  body past the lazy threshold and every diagram's code tab own their selections, so a copy inside one is
  answered by the framework. Their text is code or diagram source, which carries no renderer-inserted
  character to strip.
- Supersedes "a fenced code body is selectable only inside its own area" (ADR-0007 consequences) and,
  for code blocks and tables, "each own their selection area, so a gap node is the whole of their
  participation" (ADR-0008 decision 6). Formulas and diagrams are unchanged: they declare their text or
  contribute nothing.
- Removed with the code view's own selection: the iOS translate-on-selection item, which lived in that
  view's toolbar. The translate page's whole-message entry stays.
- Costs, recorded rather than hidden: a compact (mobile) table is selectable now, so a long-press inside
  one starts a selection instead of doing nothing (a touch drag over it still does not scroll it —
  measured identical in the old and new structures); and a code block no longer offers a toolbar of its
  own, so copying part of a block goes through the surface's toolbar while the header's button copies the
  whole block. Past the lazy threshold that last point inverts: the viewport is a 420-pixel window, so the
  surface owner copies no part of the body and the block's own toolbar comes back for it — and the seam is
  the fence, not the visible lines, so a selection that spans the viewport re-emits the fence whole.

## Not in scope

- Renaming `SelectableHighlightView`: the view no longer owns a selection and the name says it does. The
  rename is mechanical and touches many test references, so it is kept out of this change.
- The iOS `app.ios_translation` native handler, which now has no Dart caller.
