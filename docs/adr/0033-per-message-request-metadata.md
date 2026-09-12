# ADR-0033: Per-Message Request Metadata (Image Options) Persisted on the User Message

Port of upstream PR Chevey339/kelivo#599 (image generation options panel):
the routing decision (`requestAllowImagesApiRouting`) and the effective
options body (`requestExtraBodyJson`) are persisted on the originating user
message as two nullable Drift columns (schema v15), so regenerate/continue can
replay exactly how a request was sent. The input-bar panel controller itself is
session-scoped; the message row is the durable record.

## Context

Upstream stores these on Hive fields 20/21 of `ChatMessage`. This fork's
messages live in Drift (`MessageRows`, schema v14), and regenerate
(`ChatActions.regenerateAtMessage`) rebuilds requests purely from DB messages —
its `allowImagesApiRouting` defaulted to `true` with no memory. Without
persistence, regenerating a dismissed-image-mode prompt would silently re-route
to the images API, and custom options (e.g. 4K, 2 images) would collapse to
defaults. Both failure modes are invisible to the user, violating the
no-silent-degradation rule.

## Considered Options

1. **Persist on the user message (chosen).** Two nullable columns
   (`requestAllowImagesApiRouting` BOOL, `requestExtraBodyJson` TEXT), written
   at send time, replayed by
   `MessageGenerationService.resolveRequestOptionsFromMessages` on
   regenerate/continue. Schema v15 migration + heal set + backup round-trip
   (old backups default to null — backward compatible). Matches upstream
   semantics exactly.
2. **Session-only (no persistence).** Regenerate loses routing and options.
   Rejected: the panel would lie — options shown as set, silently ignored on
   regenerate. The dismiss-flow (image mode remembered per model key) also
   breaks across regenerate.
3. **Persist panel state in the input draft / settings instead.** Rejected:
   request metadata is per-message, not per-draft; the draft is a single global
   key (`chat_draft_v1`) and would conflate "what I typed" with "how it was
   sent". The message row is the only place reachable from regenerate.

## Consequences

- Every message write/read in the repository layer carries two more nullable
  fields; backup export/restore must round-trip them for fidelity.
- Schema v15 — the heal set and its regression test must be updated in the same
  change (AGENTS.md §3.20 mirror constraint).
- The panel controller stays session-scoped; cold-start draft restore does NOT
  restore panel state (documented in CONTEXT.md).
- Legacy rows (written before v15) have null metadata → regenerate falls back
  to `allowImagesApiRouting: true` + no options, i.e. today's behavior.
- Replay is owned by `MessagePipeline`, not hand-rolled per path. The pipeline
  anchors the replay to the turn being generated — by default it scans only
  the messages BEFORE the assistant placeholder; callers whose prepared list
  extends past the turn (Multi-AI retries append the placeholder at the tail)
  pass the turn's user message row instead. A newer user turn's metadata can
  never leak into a regenerate/continue/Multi-AI retry. All single-chat paths
  (send / regenerate / continue-after-tool), Multi-AI threads, and group
  members share this single implementation.
- Live composer input always wins: when `inputData != null` the pipeline uses
  the input's routing/options body and never replays persisted metadata.
