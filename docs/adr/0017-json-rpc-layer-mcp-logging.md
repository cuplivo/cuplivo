# Log MCP at the JSON-RPC layer, not the HTTP layer

MCP request logging records each message at the JSON-RPC layer of the vendored `mcp_client` `Client` (method, params, result, error), not at the HTTP transport layer, so that all four transport shapes — SSE, Streamable HTTP, stdio, and the in-memory `@kelivo/fetch` / `@kelivo/subagent` servers — produce identical, uniform log entries.

The existing LLM request-log pipeline is HTTP-shaped (URL, status codes, chunked bodies); reusing it for MCP would have covered only the HTTP transports, missed stdio and in-memory servers, mixed transport-level heartbeat pings into the log, and hidden the JSON-RPC method identity that MCP debugging actually needs.

## Considered Options

1. **JSON-RPC layer (chosen).** One logging hook in the vendored `Client` covers every transport, because all transports (including in-memory) funnel through it. Entries carry method/params/result — the shape the MCP domain needs. Costs: the vendored path dependency gains a hook (the library stays generic; the app-side bridge formats, suppresses, and writes), and MCP entries have no URL or HTTP status, so the existing request-log detail page cannot be reused for them — the viewer instead parses category-tagged entries.
2. **HTTP layer (rejected).** Reusing the existing HTTP logging (URL, status, bodies) for the Streamable HTTP / SSE transports. Rejected: no coverage for stdio and in-memory servers, heartbeat pings become log noise, and JSON-RPC method identity is lost behind the transport.

## Consequences

- MCP log entries use category tags `[MCP REQ n]` / `[MCP RES n]` with `method=`, `body=`, `result=` / `error=` lines — no URL, no status code.
- Successful heartbeats (tagged `tools/list` calls) are suppressed at write time; real failures are logged, while rate-limit failures of heartbeat calls are suppressed too (the app treats rate limits as proof the server is alive).
- Repeated failures are suppressed per server (`code|message` dedupe, cap 20) and flushed as a one-line summary on recovery, disconnect, or cap overflow.
