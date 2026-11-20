# v2 surface fixtures

Redacted wire captures of the six DSH surfaces documented in
[`client-api.md`](../client-api.md) §15: terminal, workspace files, attachments,
the composer command menus, context usage, and automations/jobs.

Captured from a real DeepSeek Harness Host running **0.2.2-rc.1** on
2026-11-20, over the v1 browser-cookie session (`GET /?token=…` → cookie →
`POST /api/<ns>/<method>` and `GET /api/remote.mux`). Every call was made from a
plain client against the live Host; nothing here is sketched from typings unless
the file says so in a `note`.

## Redaction

All fixtures are shapes with substituted identities:

- Host name → `<host>`, authority → `<authority>`, home/workspace root →
  `<workspace>`.
- Session, terminal, stream, message, command, schedule and receipt ids →
  `<sessionId>`, `<terminalId>`, `<streamId>`, `<messageId>`, `<commandId>`,
  `<scheduleId>`, `<receiptId>`, `<attachmentId>`, `<caller-minted id>`.
- Opaque freshness tokens (`version`, `expectedUpdatedAt`) → `<opaque-version>`
  / `<rfc3339 UTC>`.
- Numeric values (byte sizes, widths/heights, limits, sequence numbers, token
  counts, frame counts) are the real captured values — they are what a client
  has to size against.
- Terminal `screen`/`data` strings keep their ANSI/escape sequences; only the
  literal user@host part is replaced.

No token, cookie, credential, parameter content or absolute Host path from the
capture survives in this directory.

## Files

| File | Answers |
| --- | --- |
| `terminal.json` | `terminal/environment`, `shells`, `create` (idempotency, closed-id refusal), `list`, `attach` frame vocabulary (`snapshot`/`output`/`state`/`ack`, `write`/`resize` uplink, `inputWindow`), `retain`, concurrent attachments and input revocation, process exit (`exit 3`), `close`, session scoping. |
| `workspace-files.json` | `workspaceFiles/list` root and directory shape, `read` text page/range/past-EOF, `not-found`, `stat`, `readBytes` multipart anatomy (image, ranged blob, PDF) with the `metadata` envelope and `bytes-N` parts, `changes` stream ready frame. |
| `attachments.json` | `POST /api/session/uploadFileBinary` request/response, the `fileUploads/upload` RPC fallback, `session/prompt` with a receipt, a real user message carrying an image attachment, assistant-stream usage/commit frames, `session/attachment` durable read, and the `/api/file` redirect → immutable-cache chain. |
| `commands.json` | Host `commands/list` roster, `skills/list`, `fileReferences/list`, `commands/execute` success and unknown-line answers, and the composition/order of the `/` menu (`指令` then `技能`; client `/file` contribution; leading vs inline availability). |
| `context-usage.json` | `session/projections` values used by the context ring (`tokenUsage`, `contextPressure`, `contextBreakdown`), plus the computed percent rule and the events that also carry the fields. |
| `automations-jobs.json` | `schedule/catalog`, `schedule/list` (all + active), `schedule/create`, `schedule/edit` pause and delete, `deleteInactive`, `deliveryLimits`; `job/list` rows stream and `job/follow` unknown-id refusal. |

## Reading conventions

- `args` in a fixture is the exact JSON body of `payload.args` for a unary
  `POST /api/<method>` with the `{type:'client-request',rpcId,method,payload}`
  envelope around it; `value`/`error` is `result.value`/`result.error`.
- Stream fixtures show the `open` frame and the `item` values the server sends
  for that stream (the `streamId` is elided to `<streamId>`; it is chosen by the
  client and echoed by the Host).
- Binary RPC results (`workspaceFiles/readBytes`) are the multipart body split
  into parts: `head` is the part headers, `body_len` includes the trailing
  CRLF, `metadata_envelope` is the JSON part exactly as sent (with
  `value.data` still `null` and the top-level `attachments` mapping), and
  `decoded_value` is what the client reconstructs after filling `data` from the
  named part.
- Fields annotated `"_note"` or described in a `note` are capture commentary,
  not wire data.

## Regenerating

The captures live outside the repository (they contain live credentials).
These files were produced from them by a scratch script that loads the raw
`curl`/WebSocket dumps, replaces the identities listed above and re-serialises
the JSON. Do not hand-edit them: change the script and re-run it, so a later
capture round can refresh them the same way.
