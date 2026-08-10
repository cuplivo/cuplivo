# ADR-0024: User-relocatable @workspaces host directory, wire format unchanged

The built-in `@workspaces` sandbox lives at `<appData>/workspaces/`, which pins it to the OS system drive (Windows: `C:\Users\<user>\AppData\...`) and to the app container on mobile. Desktop users want it elsewhere (a secondary drive, a synced folder); the wire format (ADR-0022) deliberately keeps host paths out of the model context, so relocation can be purely a host-side setting.

Decision: the host location of `@workspaces` is user-configurable on desktop targets via the SharedPreferences key `workspaces_dir_v1`, honored only by `AppDirectories.getWorkspacesDirectory()` — the single resolution point for the backup pack, restore, `clearAllData`, the trash-page resolver, `kelivo_fetch` download targets, and the mounts provider. Mobile targets ignore the key entirely (device-local config, same rule as external mounts). The setting rides `settings.json` in backups, so a desktop→desktop migration carries the location (files restore into it); desktop→mobile restore is inert.

Relocation guards (canonicalized comparison via `AppDirectories.canonPath`, Windows case-folded, root-aware):

1. The target must not nest inside the current sandbox — a recursive-copy hazard during the optional move.
2. The target must not overlap ANY sync tree — the six packed directories (upload/images/avatars/fonts/skills/workspaces) — neither containing nor contained: a sandbox at a drive/partition root would sweep the whole volume into every incremental backup and LAN sync pack.
3. The target must not overlap any existing external mount, in either direction: a sandbox containing a mount would sweep the mount's host content into backups, and a sandbox inside a mount would resolve the same host file under two aliases (a delete via the mount alias writes no tombstone and would resurrect on the next merge restore).
4. The same overlap rule applies when ADDING external mounts: a mount inside or containing a sync tree would silently enter the sync scope and break "external mounts never sync" (issue #242 mis-sync report: a Windows mount surfaced on a phone via backup-restored settings). Persisted mounts are re-validated at load for the same reason — a legacy mount created before the check existed is skipped at mount time (config stays in prefs, no data loss).
5. With `moveFiles=true`, a non-empty destination is rejected: its pre-existing content would silently become part of the synced sandbox.
6. The `workspaces_dir_v1` pref itself is re-validated at LOAD (absolute, non-root, no overlap with the fixed sync trees): settings.json is restored wholesale into prefs and can carry any value, so a restored drive-root or sync-tree path would otherwise be mounted as the rw sandbox and widen the pack walk. Unsafe values fall back to the default location with a log.

The optional move of existing files is same-volume rename, falling back to copy+delete when the target exists or the move crosses volumes. The copy path creates nested directories and preserves mtimes (`setLastModified`) — relocation is a physical move, not new content, so peers see no mtime-driven re-sync burst. The `workspaces_dir_v1` pref is persisted BEFORE the move; a failed move rolls the setting back and attempts a best-effort data move-back, so a stale setting never points at moved-but-lost data. Symlinks inside the sandbox are recreated best-effort during copy (reliable on POSIX, privilege-dependent on Windows; failures are logged, not fatal).

## Considered Options

1. **Relocatable host dir via a single resolution point (chosen).** Wire paths, marker ids, tool-call records, and backups stay unchanged — the host location was never part of the wire format (ADR-0022's rationale). All consumers follow `getWorkspacesDirectory()` automatically. Cost: the sandbox is only as portable as the path the user chose (backups pack whatever that path holds — guarded by rule 2).
2. **Mount sandbox subdirectories on mobile instead (original reading of issue #242 "自选内置挂载文件夹").** Rejected: iOS cannot address external directories at all; Android 10+ scoped storage returns SAF `content://` URIs that the path-based mount machinery (`Directory` ops, mtime protocol, markers) cannot consume. Mobile "outside" interaction is served by Files-app exposure (UIFileSharingEnabled) plus open/share (issue #242 item 5).
3. **Allow arbitrary mounts into sync trees, or make sync scope per-mount configurable.** Rejected: two sync participants can double-pack the same bytes or fight over mtime-based merge; and a model-side delete without a tombstone (markers are `@workspaces`-only) would resurrect deleted files on peers after merge restore.
4. **Store the location in settings.json as a first-class field instead of a prefs key.** Rejected: prefs already ride settings.json wholesale; a dedicated field would fork the serialization surface for no gain.

## Consequences

- Desktop users can move the sandbox off the system drive; backups/LAN sync follow the configured location with identical wire-path identity.
- `filesystem_mounts_v1` (external mounts) and `workspaces_dir_v1` are both device-local in effect: loaded/honored on desktop only, still carried in settings.json (desktop→desktop migration works, phone restore is inert).
- The preview char budget diverged from `kelivo_read` at the same time (256 KB user-facing vs 32 KB model window) — a related but separate decision recorded in CONTEXT.md "File content preview".
- Residual risk: a desktop user who relocated to a path that later becomes unavailable (drive letter change, network mount gone) gets a sandbox that `FilesystemMountsProvider.init()` recreates at that path; the old default location is not consulted. The settings page always shows the effective path.
