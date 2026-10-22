# ADR-0012: Message reply — a Quote citation and the `<reply-to>` context injection

**Status:** Accepted (2026-10)
**Deciders:** cuplivo

## Context

Cuplivo 3.x shipped a QQ-style message reply (#559, its ADR-0046): a user message carries a **Quote**
naming the message it answers, the bubble shows a one-line citation above its content, and the shared
`apiMessages` builder turns a resolvable Quote into a `<reply-to>…</reply-to>` prefix so the model
knows what the reply is about. The 4.x line re-baselined on Kelivo stable and re-does Cuplivo's
features as cherry-picks, so this one has to be redone — and v3's mechanism cannot be copied, because
the piece it stood on is gone.

What v3 did, and why each part had to change here:

- **Half-open byte offsets into the target's raw markdown** (`{id, start, end}`), re-located at
  display time by `subsequenceRange(fullPlain, spanPlain)` — the subsequence matcher family.
  The Markdown IR line **deleted** that matcher: it fired exactly in the unmodelled cases, and its
  answer was indistinguishable from a wrong one. 4.4 then replaced the IR itself with markstream, which
  has no such matcher at all (`docs/markstream-delta-audit.md`). A reply feature must not bring it back.
- **A `quote_json` column** on `message_rows` (v3 schema v20). This line has a documented
  message-scoped extension point that did not exist as such then: `MessageRows.extrasJson`, whose
  comment says a field belongs there *unless* it needs an index, a foreign key or a CHECK. A citation
  needs none of the three.
- **A `quotePlainText` regex stripper** shared by the draft row, the bubble and the API. This line
  has spent four ADRs deleting ad-hoc markdown parsing in favour of one parsed document — today
  markstream's AST (`docs/markstream-delta-audit.md`) — and the API does not need a display string at
  all.

Three inputs come from measurement rather than from v3's prose:

- The desktop copy-selection hotkey exists because the framework can drop a long backward selection
  on right-click. The same loss takes the reply entry away with it, because the selection toolbar is
  where a ranged reply starts. 4.4 answers both from one recording (decision 10).
- This line's user prompt is **assembled and frozen** (`message_prompt_rows`): what a turn sends is
  what later turns replay, which is what keeps the prompt cache stable. A citation derived fresh on
  every request would step outside that contract.
- A conversation's loaded window is not the whole conversation, and a copy of a conversation mints
  new row ids. Both facts are load-bearing for a pointer that names a row.

## Decisions

1. **The citation is offset-free: `{id, text?}`.** `text` is the quoted span as **raw markdown**, taken
   from the document the copy path already uses (`MarkstreamSelection.markdown`, i.e. `toMarkdown` of
   the selection's own clipped AST); `text == null` means the whole target message, resolved live from
   `id`. No offsets, no relocation, no subsequence matcher — the snapshot is what the user selected,
   and it cannot drift. The markdown is **canonical, not byte-exact**: markstream re-emits markers and
   escapes text (`\\(`, `&amp;`, `*em*`), and only app extensions keep their original spelling. That is
   what the model reads, and the label path (decision 10) re-parses it, so nothing user-visible shows an
   escape.
2. **The citation persists in `message_rows.extras_json` under `reply.quote`.** No schema version
   moves, so no Drift products, no migration, and no LAN sync pause across the upgrade window
   (`CONTEXT.md` § Sync session, symmetric version gate). Every message insert path already funnels
   through one companion, and both token-extras writers merge onto the row they read, so the citation
   and the `tokens.*` / `timing.*` side channel coexist without either dropping the other.
3. **The citation reaches the model as `<reply-to>{markdown}</reply-to>` folded into the user body
   before the prompt is assembled.** It therefore freezes with the memory prefix and the message
   template: a later edit of the target cannot silently rewrite what an earlier turn sent, and the
   prompt cache keeps its prefix. The target resolves from the request's own stream, then the
   conversation cache, then the database — a citation of a message that has scrolled out of the
   window still grounds. That last step is **scoped to the conversation the citation is sent in**: a
   row id means something only inside its own conversation, and the primary-key lookup that ignores
   this is how a stale id reaches a different message (see Consequences). With no conversation to
   scope it to, the step is skipped rather than widened — a citation that grounds outside its own
   conversation is worse than one that does not ground. An unresolvable target injects **nothing**;
   the UI stub is UI language.
4. **The cited text is raw markdown, uncapped.** ADR-0046's own reasoning holds — the model reads
   markdown best — and no display-derived string ever reaches the wire.
5. **Two entry forms, three surfaces each.** A whole-message reply from the message menus (the
   `⋯` sheet, the desktop right-click menu on a user bubble, the mobile long-press popup); a ranged
   reply from the assistant content's selection toolbar, next to the platform Copy and `Markdown`.
   The toolbar item and the ranged hotkey go through **one mapping** (`selectionMarkdownFrom`), so a
   citation can never be markdown the copy path would not have produced.
6. **A desktop hotkey, default `Ctrl/Cmd+Shift+R`, rebindable, in the existing in-app scope.** It acts
   on the recorded assistant selection (选区记忆), exactly as copy-as-Markdown does, because the
   right-click that loses the selection is the reason the hotkey exists. Nothing recorded → nothing
   happens. The memory now files the selection's **message id** alongside its document and text.
7. **A ranged citation is self-sufficient; a whole-message citation is not.** The chip above a bubble
   renders the citation's text in the IR's *display space* — the same walk, and the same records, the
   bubble itself rendered with. That walk is paid once per citation rather than once per build: the
   chip holds the derived line and re-derives it only when the quoted source, its streaming state, or
   a setting the walk reads changes. The timeline rebuilds on every stream publish, so re-walking a
   long quoted answer to draw one line of 120 code units is work the reader never sees and the frame
   budget does. A ranged citation therefore always shows its own text, even after its
   target is deleted (the target only feeds the tap that jumps to it); a whole-message citation shows
   the target it resolved, or a localized stub when it cannot. That target is resolved against the
   quoted message's **slot**, not the exact revision the citation names: the timeline holds one
   revision per group, and a version switch, a regeneration or an edit-and-resend moves which one the
   slot shows, so the revision on screen answers for every id the slot has held. The chip shows the
   message **as it is now** — the rule an edited target already followed — instead of claiming a
   message that is still there is unavailable. A target that resolved but renders to nothing (an
   image-only message, an answer that is only a tool call) falls back to the item's own 「回复」/Reply
   label, the same fallback the composer's preview row already applies, because a stub would assert an
   absence that is not one. The composer preview row shows the same
   text with the one tap that drops the citation. The chip hugs its own content, capped at the width
   the bubble itself may reach, so a reply's citation ends on the same right edge as the bubble it
   answers instead of hanging at the far left of a box as wide as the widest bubble.
8. **The whole-message entry is withheld while the target streams; the ranged entry is not.** A
   whole-message citation would freeze a reply that is still being written, while a ranged one is
   captured by value from text the reader had already read — the same reasoning the retired
   selection-copy ADR recorded: a selection is a snapshot, not a range.
9. **The item reads 「回复」 / "Reply"; the domain term is Quote.** v4's zh strings already spend 「引用」
   on search citations (「引用来源」, 「引用 (共 N 条)」), and v3's own glossary flagged the overload.
10. **The selection is read from markstream's clipped AST and *recorded*, never mapped from plain text.**
    - `MarkstreamSelection.content` is already the selected subtree with its containers kept
      (`selectedDocument` clips text spans and drops what is not selected), so `toMarkdown` of it
      yields complete markers. Nothing re-matches plain text against the document, so the
      `stripRendererInsertedCharacters` family has no successor here — and the copy path and the
      citation can share one function without either being lossy.
    - The recording exists because the live selection is Flutter's: markstream re-reads the range from
      the `SelectionContainer` delegates on every access and keeps nothing, so a secondary tap or a tap
      elsewhere — including the one that opens the toolbar — leaves nothing to map. What is recorded is
      the selection's AST, by reference, never a rendered string: a drag must not re-serialize on every
      frame, so the markdown is produced when an action asks for it.
    - `AppSelectionArea` is the only recorder: one place serves the toolbar item, the copy hotkey and
      the reply hotkey, and every surface files its recording under its own `State`, so a menu is never
      answered by a sibling bubble's selection. Only surfaces that render a message record at all
      (`messageId`), so a markdown preview cannot become replyable.

## Consequences

- A copy of a conversation (fork, duplicate) remaps the citations it carries onto the copy's own rows.
  A citation whose target is not part of the copy is **dropped only when it is a whole-message one** —
  a pointer that names a row the copy does not hold is worse than no pointer, and the pointer is all
  that form has. A **ranged** citation carries its own text, so the copy keeps it exactly as it
  stands, which is the state a deleted target already leaves it in: the chip shows the span, the tap
  has nowhere to go, and the turn still sends it. Its id survives unmapped rather than being cleared,
  because a citation is named by one and message ids are UUIDs — no row of the copy can be mistaken
  for the target, and every resolution path is scoped to its own conversation.
- The chip resolves a whole-message citation against the message **slot**, so display and the wire can
  name different revisions of one group once a version switch moves the selection: the chip follows
  what the reader sees, while the turn keeps the revision it cited, frozen into
  `message_prompt_rows` at send time. That is not new — an edited target already reads live while an
  earlier turn keeps what it sent — and re-resolving the citation at send time instead would silently
  rewrite a quoted turn, which is exactly what decision 3 forbids.
- A **merge-mode backup import** remaps message ids but copies `extras_json` verbatim, because the
  conversation fingerprint hashes that payload and a repeated merge dedupes on the fingerprint. A
  whole-message citation inside an imported conversation therefore still names its pre-remap id, and
  resolves to nothing there — the chip shows the stub, the turn injects no `<reply-to>`. That is the
  same outcome as a citation whose target the copy does not hold, and it is why the resolution step
  above is scoped rather than trusted. Remapping on import was rejected: it would change the imported
  payload's fingerprint and make every repeated merge of the same backup import a second copy.
- A citation is part of the message's content identity: a new version of the row carries it, and
  `copyWith` never clears it.
- A citation rides `ChatInputData` from the composer into the row, so **every** rebuild of a
  submitted input carries it — the composer-draft submission, the queued-send copy, the detached
  composer snapshot. One rebuild that forgets it loses the chip *and* the injection at once, on the
  path that looks like it works. The citation's one-line **label** rides the same payload for the
  restore paths, because a whole-message citation's text lives on a target the restored composer no
  longer holds.
- Nothing consults the citation for context accounting beyond the ordinary user turn: the injected
  prefix is part of the frozen user body, so it counts as chat history like the rest of it.
- Losses against v3, recorded rather than hidden: the chip shows the selected span alone, without
  v3's `…pre + highlighted span + post…` centre window (that needed the live full text *and* a
  relocation match); an edited target leaves a ranged citation showing what was quoted rather than
  re-rendering the new text under a stored range; the API slice is raw markdown where v3 sent a
  plain-text extraction.
- Two things v3 had are deliberately not re-introduced: the text-level 「引用粘贴」 action (selection →
  `> …` into the composer), which is a separate feature that merely shares the Chinese word, and
  nested citation rendering (a reply to a reply renders only its direct target).

## Not in scope

- Group chat, the multi-AI comparison and subagent threads: this line does not have them.
- Quoting across conversations: a citation names a row of the conversation it is sent in.
- Re-resolving an unresolvable whole-message citation on a later tap: the daemon that would notice a
  target arriving is a feature of its own.
