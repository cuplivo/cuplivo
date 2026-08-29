# ADR-0045: Sub-Agent Wait-Only Unification: One Tool, One Word, Guided Setup

Sub-agent delegation (Handoff) shipped as a historical two-mode split — `kelivo_handoff`
(fire-and-forget, UUID-only tool result) and `kelivo_handoff_sync` (wait-mode, full output
as tool result) — with equally split user-facing vocabulary: 「任务交接 / 同步交接」 in
assistant settings vs 「子代理 / 子对话」 in the chat 子代理面板, while users only ask for
「子 agent」. ADR-0045 retires the split: one wait-mode tool, one unified user-facing
name, and on-boarding guidance at every place a user can enable the feature.

## Problem

Three real-world failure classes, all observed in support interviews:

1. **Vocabulary incoherence.** The same feature carried four user-visible names
   (「任务交接」「同步交接」「子代理」「子助手」). A user asking 「可以开子 agent 吗」
   was told 「去开启同步交接的本地工具」 — a word they never saw again; they then
   flipped 「可被其他助手发现」 (the *target-side* toggle) because "被发现" was the
   only knob that looked related, and concluded "该开的都开了" without anything working.
2. **Invisible prerequisite graph.** Setup needs ≥2 assistants (self-delegation is
   rejected), a target with 「可被其他助手发现」 + a unique 「交接标识」, *and* a source
   with the handoff local tool enabled — spread across two tabs of the assistant editor
   plus the Tools Hub, with zero UI stating "you are missing X".
3. **Model-side ambiguity.** Two near-identical tool definitions forced the model to
   choose between "no result returned" and "block until result" semantics; models regularly
   picked the wrong one (or the user experienced v1 as "it didn't do anything").

The two-mode machinery also duplicated code: two tool definitions, two l10n rows, two
toggles in every surface, a forward-chip branch keyed on tool name, and dual-mode
documentation — while the execux layer (`HandoffToolService.execute`) was already a
single function parameterized by `waitForResult`.

## Decision

1. **Single wait-mode tool.** `kelivo_handoff` is THE handoff tool: delegate + wait +
   return the child's full output. The `kelivo_handoff_sync` definition is retired
   (recorded tool events keep rendering via the legacy name map; `LocalToolNames.handoffSync`
   stays as an alias constant). `HandoffToolService` loses its `waitForResult` branch.
2. **Unified user-facing term 「子代理 (sub-agent)」, action 「委派」.** Settings land on
   the panel's existing vocabulary: section 「子代理 / 委派」, target-side toggle
   「可作为子代理被其他助手委派」 (EN: "Delegateable as a sub-agent by other assistants"),
   「委派标识」 (was Handoff ID), single local-tool row 「子代理委派」.
   The tool-call card title keys keep their l10n keys as legacy display aliases.
3. **Construction-time normalization.** `Assistant` construction normalizes any
   `kelivo_handoff_sync` entry in `localToolIds` to `kelivo_handoff` (dedupe). Storage
   (SQLite `localToolIdsJson`, settings.json backups) is untouched — the normalized value
   is written back on the next save. No DB migration; both `_assistantFromRow` mappers
   (mirror constraint) stay unchanged; backups round-trip portable in both directions.
4. **Forward chip removed.** The v1 UUID-parse chip is deleted along with fire-and-forget
   (a wait-mode event content is the child's output, never a parseable UUID). Navigation
   to children: 子代理面板 查看子对话 while running, conversation-list
   `parentConversationId` badge afterwards. Backward chip and badge stay.
5. **Guidance at every enablement surface.** All three sides, shared components:
   - Toggle-time hint (Tools Hub + assistant 本地工具 tab, shared helper): enabling
     「子代理委派」 with zero available targets immediately explains 「子代理需要另一个
     助手开启可被委派」 with a `去设置` jump.
   - Assistant settings status row: 「可用目标 N 个 · 查看」 (rich surface; the target
     count comes from the live discoverable-assistant list).
   - Tools Hub persistent badge: mobile sheet count tag 「N 个目标」 (mirrors the MCP
     count-tag precedent), desktop compact row trailing gray text; warning emphasis at 0.
6. **Docs.** CONTEXT.md Handoff section rewritten for the single-tool world; the stale
   "parallel wait-mode handoffs are impossible / exactly one active job slot" claim is
   corrected (see Consequences) — this doc fix is part of this ADR.

## Rejected alternatives

- **One tool + `wait` boolean parameter.** Keeps both semantics for the model to pick —
  the "AI confusion" root cause survives in a clothed form, and the async path keeps
  two descriptions. The concept that users know is one: 委派并等结果.
- **Keep two tools, collapse the two toggles into one row.** Hides but never solves the
  code/l10n/AI split; recorded-data duality stays forever.
- **DB migration + backup rewrite of `kelivo_handoff_sync` ids.** More surfaces to touch
  (migration v16, heal set, backup import/export, restore symmmetry) for a field whose
  storage is only ever read after normalization anyway. Constructor normalization makes
  every read path see one id without any stored-state rewrite.
- **Forward chip via UUID-content heuristic.** The child's output *could* in principled
  be a bare UUID; a heuristic chip would occasionally navigate to a nonexistent
  conversation, and the chip has marginal value when the panel badge covers navigation.
- **Onboarding wizard / dedicated 子代理 page.** Disproportionate for a feature whose
  prerequisite graph has 4 knobs; the hint + status + badge pattern answers each failure
  point at the place it occurs (KISS; revisit only if support data still shows dead ends).

## Consequences

- **Behavior upgrade**: assistants that had only v1 `kelivo_handoff` silently switch to
  wait-mode (delegate now returns the child's output). This is the intended product
  change; CHANGELOG notes it. Custom assistant prompts referencing `kelivo_handoff_sync`
  by name will get a tool-not-found error — the model self-corrects (recorded calls keep
  working).
- **Parallel waits are supported today**: same-turn tool calls run concurrently wherever
  the provider `Future.wait`s the handler (openai_common / claude_official /
  google_vertex); each wait-mode handoff gets its own 子代理面板 entry
  (live_panel `_activeJobs`). google_common's event-stream path stays serial — one wait
  completes before the next starts; accepted, results still arrive in call order.
- **Unified surface inventory** (single-row toggles, hint, status, badge): the local-tools
  tab (`assistant_settings_edit_local_tools_tab.dart`), the desktop edit page handoff
  section (`assistant_settings_edit_page.dart`, parallel surface), the mobile basic tab
  (`assistant_settings_edit_basic_tab.dart`), Tools Hub (`tools_hub_content.dart`, both
  shells), the l10n keys in all 4 ARB files.
- **Retired strings stay renderable**: legacy tool-event name → icon/title mapping
  (`chat_message_widget.dart`) keeps both `kelivo_handoff` and `kelivo_handoff_sync`
  names mapped for historical messages; the two title l10n keys are retained (values
  converge on the unified term).
