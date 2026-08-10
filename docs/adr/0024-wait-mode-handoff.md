# Wait-Mode Handoff: Live Panel + Result Return via Handler-Layer Await

Wait-mode handoff (`kelivo_handoff_sync`) lets an orchestrator delegate a task to a
sub-agent and BLOCK until the sub-agent finishes, returning the child's full output
as the tool result so the orchestrator can synthesize. The user watches progress in
a live panel (子代理面板) pinned above the parent conversation's input bar, and can
answer approval/ask_user requests raised by the child from either the panel or the
child conversation.

This is the `startAndWait()` upgrade path named in ADR-0013, with the v1
fire-and-forget shape untouched.

## Problem

v1 `kelivo_handoff` returns only the child conversation UUID; the orchestrator never
sees the child's output. Collecting the result requires the tool handler to await a
sub-generation that may run for minutes. Two obstacles:

1. **MCP request timeout**: every `tools/call` await is bounded by the mcp_client
   `requestTimeout` (global default 30 s, `mcp_request_timeout_ms_v1`), including
   the in-memory subagent client. Blocking inside the MCP response would fail at
   30 s — or require a per-server long timeout, which reproduces the anti-pattern
   `@kelivo/fetch`'s own CLIENT-SIDE cap comment warns about: "Request timed out"
   while the engine still completes in-isolate, leaving silently-written output the
   model believes failed (and would retry → duplicate output).
2. **No live progress surface**: `HeadlessGenerationService.chunkStream()` had zero
   callers — the child conversation froze until completion; there was no way to
   watch a running sub-agent.

## Decision: fast MCP dispatch, wait in the tool-handler layer

- The engine returns the child conversation UUID immediately — **identical to v1**,
  no protocol, timeout, or vendored-dependency changes. The `kelivo_handoff_sync`
  tool result is structured JSON `{"conversation": "...", "status": "started"}` so
  the handler extracts the UUID without parsing prose.
- The wait happens in `ToolHandlerService.buildToolCallHandler`, which special-cases
  the wait tool: after the fast MCP call, it awaits a completion future from the
  root live store and returns the child's full output as the tool result.
- `HeadlessGenerationService` (already the root owner of sub-generations) gains the
  **live store**: per-conversation job state `{status, lastStep, startedAt,
  completion future}`, fed from the chunk stream (last tool call / streaming
  char count) and settled on completion/error/cancel. The orchestrator's stream
  loop already awaits `onToolCall` with no open HTTP connection during the handler,
  so the multi-minute wait is free on the outer side.

This shape generalizes: any future long-running tool job (e.g. sandbox command
execution with live stdout) is the same three-layer pattern — MCP dispatches fast,
the handler awaits, the UI watches the store. No abstraction is pre-built for
non-existent jobs.

## Rejected alternatives

1. **Engine blocks + per-server timeout override** (mirroring `@kelivo/fetch`'s
   10-minute override). Rejected: the fetch override is safe only because the fetch
   engine bounds its own work; a sub-agent is unbounded (bounded only by the
   child's `maxTokens`), so any fixed timeout is arbitrary. A timeout would report
   failure while the sub-agent keeps running and persisting — the silent-completion
   anti-pattern. Also couples an unbounded wait to the MCP request lifecycle.
2. **Truncated result return** (mirroring `kelivo_fetch`'s 5000/20000-char cap with
   `start_index`). Rejected: fetch truncates because its input is unbounded; a
   sub-agent's output is bounded by its `maxTokens`. Every output token is already
   paid for; truncation forces lossy synthesis (or an expensive retry). The existing
   `applyContextLimit` is the general safety net for pathological lengths.

## Consequences

- New tool `kelivo_handoff_sync` alongside `kelivo_handoff` (same parameters, same
  call-time validation). v1 semantics, recorded tool events, and existing prompts
  are untouched.
- **子代理面板 (subagent panel)**: a transient widget pinned above the parent
  conversation's input bar (collapsed pill ↔ expanded card). Shows phase
  (思考中/输出中/等待批准 — running states only; the panel disappears on
  completion/error/cancel and the tool-call card takes over), the child's
  last step, elapsed time, and
  [查看子对话]. Its ✕ button cancels the sub-agent after a confirmation dialog —
  the awaited handler resolves with a cancelled result and the orchestrator
  continues.
- **Cancellation is cascading**: cancelling the parent generation also cancels an
  in-flight wait-mode sub-agent; fire-and-forget sub-agents keep v1 behavior. The
  completion future MUST resolve in all paths (normal/error/cancel) — the handler
  await never hangs.
- **Approval/ask_user dual visibility**: the child's tool handler is built WITH
  `ToolApprovalService` / `AskUserInteractionService` (v1 omitted both — approval
  tools silently auto-executed). Both services are root ChangeNotifiers keyed by
  `toolCallId` with one completer per request, so the parent panel (auto-expanded to
  an interactive card) and the child conversation render the same buttons and stay
  in sync.
- **Result record**: the handler's return value flows through the normal
  `toolResults` chunk path, so the tool event `content` records the child's FULL
  output automatically — no extra write-back. Known residual (out of scope):
  cancelled/crashed outer streams leave tool events at `content: null`, a
  pre-existing general issue for all tools.
- **Recovery**: the live store is in-memory; after an app restart the parent
  conversation shows the tool-call card with the `started` result and no synthesis —
  a natural break, user re-asks. The child conversation holds the full output.
- **Child page live rendering**: the page-subscription mechanism documented in
  CONTEXT.md is implemented (it did not exist): the child conversation renders its
  streaming message via `StreamingContentNotifier`; the DB write stays one-shot at
  completion.
- **Parallel waits**: Same-turn tool calls are executed CONCURRENTLY by all
  providers (`Future.wait` over `onToolCall`), so two `kelivo_handoff_sync`
  calls in one turn start both sub-agents simultaneously; results map back by
  `tool_call_id` in call order. Event-stream paths that yield per-event
  results stay serial. Same-turn tools no longer have order guarantees.
- **Rendering state source**: the headless job owns the accumulated
  text/reasoning buffer and persists tool events + reasoning itself; the page
  registers its `StreamingContentNotifier` on the job while viewing the child
  (no page-side chunk buffer). Long-term (cuplivo v3): extract the
  page-independent chunk-processing pipeline from `stream_controller` and
  reuse it in the headless run, eliminating the functional subset entirely.
- **Live rendering via registered notifier**: `_run` updates the registered
  notifier per chunk (content + reasoning) and persists tool events /
  reasoningText so the child conversation renders tool cards and thinking
  after completion.
