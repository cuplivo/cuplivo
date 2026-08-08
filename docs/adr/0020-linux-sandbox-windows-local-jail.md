# Linux Sandbox v1: Windows local path jail; Android UI stub

> Superseded in part by [ADR-0021](0021-linux-sandbox-real-runtimes.md) (per-sandbox `{files,linux,tmp}/` layout, explicit `installBaseEnv`, status gating, real runtime modes).

v1 ships a **Windows local path jail** runtime: each sandbox is a directory under app support `linux_sandboxes/<id>/`. Guest paths are resolved, normalized, and canonicalized (`resolveSymbolicLinks` where possible); escapes via `..`, absolute host paths, unsafe Win32 segments, and symlink targets outside the jail are rejected. Shell runs with `workingDirectory` set to the jail root, default timeout 30s (max 120s), stdout/stderr capped at 256KB, process killed on timeout. Write/edit/shell default to `needsApproval=true`; read does not.

Android/iOS/macOS/Linux use `UnsupportedSandboxRuntime` (`isSupported=false`) so the management UI can exist as a stub while tool calls return `platform_unsupported`. A pluggable `SandboxRuntime` factory is the extension point for a future Android/container runtime.

Backup persists **sandbox metadata only** (prefs / settings.json). Disk files under `linux_sandboxes/` are not included in backup/restore.

## Threat model (v1)

| Control | Rationale |
| --- | --- |
| Path canonicalize + under-root check | Prevent jail escape via `..`, mixed separators, or trailing-dot Win32 quirks |
| Reject symlink escape | Canonical target must remain inside jail root |
| Shell cwd = jail root + output caps + timeout/kill | Limit blast radius of approved shell; no unbounded hang or log flood |
| Default approval on write/edit/shell | Human gate for destructive or network-capable commands |
| Metadata-only backup | Avoid shipping arbitrary sandbox disk state across devices |

## Consequences

- Windows is the only fully functional runtime in v1; other platforms refuse tool execution.
- Future Android runtime plugs in via `createSandboxRuntime()` without changing tool names or provider prefs shape.
- Deleting a sandbox scrubs `Assistant.sandboxId` bindings and destroys the local jail directory.
