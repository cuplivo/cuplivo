# ADR-0021: Filesystem deletions ride the DB tombstone protocol (DeletionMarkerRows + deleted.json)

The `@kelivo/filesystem` MCP server introduces a new deletable entity class — workspace files under `@workspaces`, which participate in backup and LAN sync (mtime-filtered, `includeFiles`-gated). A filesystem deletion therefore must be declarable to sync peers, and the natural channel is the existing tombstone protocol: `deletion_markers` (`DeletionMarkerRows`, `type='workspaceFile'`, `id` = mount-relative wire path) exported as a `workspaceFile` group in `deleted.json`. The marker is written WITHOUT a `deleted_records` payload — files are physically gone and not recoverable (Skill precedent), so the marks are advisory records, not trash.

Remote declarations stay advisory and mirror the entity flow: if the file still exists locally, the UI shows 远端已删除 with an optional one-click local delete, which runs the normal delete path (physical delete + writes an `origin='local'` marker + removes the remote row). Local marks are dismissible (acknowledge). Echo avoidance, the unified 5000-row FIFO cap, per-type `deleted.json` caps, and merge-only import apply unchanged; `clearAllData` remains peer-blind (no markers). No schema change — `type` is a free string.

## Considered Options

1. **Reuse `deletion_markers` (chosen).** Zero new protocol surface: echo avoidance, FIFO caps, `deleted.json` serialization, and forward compatibility (old builds silently ignore the unknown type) come for free.
2. **Separate tombstone table / separate channel.** Rejected: would duplicate echo-avoidance, cap, and serialization logic for no semantic gain — tombstones and remote markers are structurally identical (id + type + timestamp, no payload), the same argument that collapsed the three-table variant in ADR-0011.
3. **`deleted.json` entries without DB rows.** Rejected: no local UI state for the marks section, no "still exists locally" filter without a queryable store, no dismiss semantics.
4. **Physical-delete-only, no tombstone.** Rejected: a peer could never distinguish "deleted elsewhere" from "never existed", and the trash-page marks section would have no source.

## Consequences

- `DeletedRecordsStore` gains a marker-only write path (no `recoveryJson` payload) for `type='workspaceFile'`; the existing `recordDeletion` dual-write stays for recoverable entities. Writing a local file marker also supersedes (removes) any `origin='remote'` row for the same path — a local deletion makes the peer declaration's "offer local delete" purpose moot.
- The `deleted.json` import path in `restoreData` gains a `workspaceFile` branch: "still exists locally" means the wire path resolves to a file OR directory inside the `@workspaces` tree; a match writes an `origin='remote'` marker.
- **Directory deletions propagate as a single directory mark** (recursive `delete` or moving a directory out of `@workspaces`). Applying it on a peer is a user-confirmed recursive local delete — the local directory may contain files that never existed on the source (e.g. created locally after the last sync), so the UI shows the local file count in the confirmation dialog. Per-file propagation (option A) was rejected: it floods the unified 5000-row FIFO on large trees.
- Markers are never written for dot-prefixed wire paths (`.fetch_cache/` and friends) — the same dotfile rule as the content plane. The import filter repeats the check as defense-in-depth for markers written before this rule.
- The unified 5000-row marker FIFO is now shared with file tombstones — a bulk `unzip` + `delete` session can evict conversation tombstones. Accepted: one budget for all types, same eviction semantics.
- Backup/sync exclude dot-prefixed entries (`@workspaces/.fetch_cache/`) so the content plane and the marker plane stay aligned (a never-synced file must never receive a meaningful remote marker).
- The trash-page "marks section" is record-only: workspace files have no restore path, and the UI must say so explicitly.
