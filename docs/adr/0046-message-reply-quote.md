# ADR-0046: Message Reply — Quote Citation + `<reply-to>` Context Injection

Issue #312: QQ-style message-level reply. A user can reply to any message via the
message 更多 sheet (whole-message quote, `id` only) or via the text-selection
toolbar (ranged quote, adds `start`/`end`). The reply is stored as a **Quote**
`{ id, start?, end? }` on the originating user message, rendered as a one-line
citation above the bubble (LivePanel-style row in the composer as a draft), and
build-time injected into `apiMessages` as a `<reply-to>` prefix. Never a thread,
never a tree, never a role change.

## Why not display-only

A reply whose context never reaches the model is an ornament: the user says
"what about the part where…" and the model, whose window may have trimmed the
target, cannot know what "part" means. The **range** is precisely the new
information the model needs (`start`/`end` select the piece being answered);
id-only carries the whole message. So the quote is a display citation **plus** a
context-carrier — the "display-only" option was floated mid-design and
retracted.

## Why offsets are raw-markdown-space (not plain-space)

Offsets index `ChatMessage.content` directly (markdown-space, half-open
`[start, end)`). Three consequences were priced and accepted:

- The API slice is a raw markdown fragment — the model reads markdown best; no
  re-derivation from a display string.
- The bubble/draft rendering strips the slice to plain text per-character
  (inline markers only); unbalanced boundaries (`**bo`) degrade to character
  artifacts confined to a small slice — accepted.
- The selection bridge is `subsequenceRange(content, selectedPlainText)` — an
  extension of the existing `subsequenceMatch` family (normalizes whitespace/
  bullets/zero-width), so selection→offsets is deterministic.

Plain-space offsets (canonical derived string) were rejected: they tie all
consumers to one derived string, force the API injection to re-derive markdown
content, and still need the same selection bridge. With raw-markdown-space,
`content` is the single persisted truth everything derives from.

## Why `<reply-to>` prefix, not a synthetic history message

The injection is a build-time content transform in the shared `apiMessages`
construction: a user message carrying a resolvable Quote becomes

```
<reply-to>{span-or-full-plain}</reply-to>

{real content}
```

- Single message → no Anthropic role-alternation hazard, no synthetic row.
- Matches the repo's model-facing XML-tag idiom (`<available_skills>`,
  `<time-note>`); no escaping, matching that precedent.
- Symmetric and simple: id-only also gets `<reply-to>` (model always grounded),
  ranged gets the span; no split behaviors.
- One transform → multi-AI parallel threads and fuse inherit automatically; no
  per-mode plumbing.
- Never persisted, never in `toJson`, purely derived from `quoteJson`. Missing/
  unresolved target → no prefix; the UI stub is UI language, never model
  language.

## Why `quote_json` single nullable TEXT column

One JSON column (see `request_extra_body_json` precedent) keeps the schema bump
small (v20; v21 if PR #449's tree lands first — whoever merges first takes the
number, sequential, no field conflict since they are independent columns),
keeps the healer mirror + row mappers to one addition, and matches the model /
draft-blob shape 1:1. The `start`/`end` keys exist now so a future
selection-driven reply needs no schema change — but no v1 code path writes them.

## Why the pending reply rides `chat_draft_v1`

`{ text, images, documents, quote }` under the existing synchronous-preloaded
draft key. One source of truth for composer state, cleared on sent/queued, kept
on rejected — identical semantics to text/images. The visual language is
LivePanel (transparent rows in the input card) but the state ownership is the
input bar / draft — LivePanel entries are transient agent status
(conversation-scoped) and a pending reply is composer draft state, so it is
never a LivePanel entry.

## Why stub on missing target, no snapshot text

Reference model (QQ-like): `id` resolves live. Snapshotting the quoted text
would duplicate content into the message row, go stale on edits, and bloat
backup round-trips. Delete → localized stub; edit → live re-render of the new
content with the stored range (bounds-clamped; display-time relocation via
`subsequenceRange` degrades to span-only on match failure). Scope: normal chat
(both roles) — group chat deferred to a follow-up (speaker attribution +
draft-free group composer).

## Considered and rejected

- **Display-only / wire-invisible**: rejected (see "Why not display-only").
- **Plain-space offsets (canonical plain string)**: rejected (see above).
- **Synthetic `user` history message carrying the span**: rejected — role
  alternation risk on Anthropic providers, insertion-point plumbing, and no
  benefit over the prefix.
- **Nested quote rendering (a reply quoting a reply)**: rejected — the quote
  renders its direct target only; no recursion (v1).
- **Snapshot text in the quote (`{id, text}`)**: rejected (see "Why stub").
- **Full-message render with span highlight**: rejected — markdown-space
  offsets cannot be mapped onto a plain-text render; the display is a
  center-window (span visible, pre/post clipped) instead.

## Consequences

- Schema: `message_rows.quote_json` + migration + healer set + discoverable
  regression test (`schema_heal_discoverable_test.dart`), alongside the
  `ChatMessage` sentinel `copyWith` / `toJson` / `fromJson` additions (backup
  round-trip rides existing JSON serialization).
- `MessageQuote.fromJson`/`toJson` shared between `quoteJson` and the draft
  blob — one parse path.
- Retry/edit paths copy `quoteJson` with content (content identity).
- New shared core: `quotePlainText` (markdown→plain) + `subsequenceRange`
  (selection bridge) + display windowing — single extraction for draft row,
  bubble, and API prefix.
- ARB ×4: 更多 sheet "回复" label, selection-toolbar reply label, deleted-target
  stub text.
- Tests: `subsequenceRange` matrix, quotePlainText consistency
  (UI == API), builder prefix (normal / multi-AI / fuse), missing-target no
  prefix, draft ride-along semantics.
