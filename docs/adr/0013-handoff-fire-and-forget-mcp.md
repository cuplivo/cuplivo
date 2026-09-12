# ADR-0013: Handoff: Fire-and-Forget Delegation via In-Memory MCP Server

Status: superseded by [ADR-0056](0056-subagent-wait-only-unification.md)

Handoff lets one assistant delegate a task to another. We chose fire-and-forget semantics (no result collection) implemented as an in-memory MCP server (`@kelivo/subagent`), rather than synchronous delegation inside the outer model's tool loop.

## Considered Options

1. **Synchronous delegation (collect results).** The handoff tool handler awaits the sub-generation and returns the full text as the tool result. The outer model synthesizes. Rejected for v1: requires a nested `ToolHandlerService`, inner cancellation propagation, timeout bridging, and context-window management. Workload more than doubles. The upgrade path remains open — `HeadlessGenerationService.startAndWait()` can be added later without undoing the v1 shape.

2. **Page-controller-driven generation.** The handoff handler calls back into the page-level `ChatActions.sendMessage()`. Rejected: couples the feature to the page lifecycle, leaves no room for background/isolate generation later.

3. **Fire-and-forget via `HeadlessGenerationService` (chosen).** A root-level provider owns the sub-generation. The handoff tool handler creates a conversation, starts the generation detached, and returns the UUID. The user navigates manually. Full tool support (MCP, local, memory, search) works because the service reuses `ToolHandlerService` via the `contextProvider` pattern. Approval/ask_user widgets work because the user arrives at the sub-conversation and interacts inline.

## Consequences

- `@kelivo/subagent` is an in-memory MCP server. Per-assistant binding via `mcpServerIds` replaces a dedicated `handoffDisabled` field — don't bind the server, can't delegate. The former `@kelivo/fetch` in-memory MCP server was later retired in favor of the search-layer `web_fetch` tool.
- Three new fields on `Assistant` (`discoverable`, `handoffId`, `handoffDescription`) enable decentralized discovery. The target declares itself; the source doesn't maintain a list.
- One new field on `Conversation` (`parentConversationId`) enables bidirectional navigation bars (forward on the handoff message, backward on the first user message).
- The tool uses a free-form `assistant` string parameter validated at call time (no schema enum), eliminating the stale-cache problem inherent in MCP's connection-time `tools/list`.
- Recursion is allowed with no depth limit. The user is watching and can cancel.
