# ADR-0022: Filesystem wire format is mount-relative; absolute paths are rejected

The `@kelivo/filesystem` MCP server addresses files exclusively as mount-relative wire paths (`@alias/rel/path`). Absolute host paths — and `..` segments, backslashes, empty segments, trailing slashes, and unknown mount aliases — are rejected with errors. Most filesystem tools accept both; we deliberately accept only the relative form.

Rationale: wire paths double as identity (workspaceFile marker ids in `deleted.json`, tool-call records in conversations), and host-absolute paths are unstable across devices and app updates — the same container path-drift failure mode that forced `canon()` normalization in the storage refcount scan (ADR-0006/0007). Mount-relative paths also keep host layout out of the model context and the MCP request logs.

## Considered Options

1. **Mount-relative only (chosen).** Marker ids and recorded paths stay meaningful when the app-data container moves or the OS re-installs; no host-path leakage into prompts or logs; approval UI shows only mount-relative paths. Cost: the model must discover mounts first (`read('/')` lists them).
2. **Accept absolute paths alongside (rejected).** Convenient, but breaks marker-id stability across containers/OS reinstall, leaks host layout, and introduces case-fold ambiguity on Windows/macOS for the same logical file.
3. **Single canonical root, no mounts.** Rejected at the design level — the mount concept (ro/rw, external desktop-only, never-synced) is the feature.

## Consequences

- Hard to reverse: once devices exchange `deleted.json` with `workspaceFile` entries whose ids are wire paths, and conversations record tool calls using the `@alias/...` syntax, changing the format breaks every device and every model that learned it.
- Wire-path validation lives in the server's path resolver: first segment must be a known mount alias; remaining segments must be clean relative segments; the mount root itself is never deletable or movable.
- **Segment rule is Win32-aware**: beyond `..`, segments ending in a dot or space, whitespace-only segments, and all-dot names (`...`) are rejected on ALL platforms — Win32 strips trailing dots/spaces from the final path component and treats all-dot names as `..`, so those forms would resolve outside the mount on Windows. The shared `isSafeWireSegment` helper is reused by the `deleted.json` import filter, the trash-page path resolver, and the unzip zip-slip pre-scan (same class of escape via ZIP entry names).
