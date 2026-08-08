# Linux Sandbox v2: real runtimes, layout, and explicit base env

Supersedes the Android-stub / single-flat-root parts of ADR-0020. Tool names,
approval defaults, path jail rules, and **metadata-only backup** remain.

## Decision

Each sandbox owns a tree under app data:

```
{appData}/linux_sandboxes/<id>/{files,linux,tmp}/
```

- `files/` — user workspace; path-jailed file tools and shell cwd.
- `linux/` — per-sandbox rootfs / runtime payload (native, PRoot).
- `tmp/` — install and runtime scratch.

**v1 migrate:** a flat `linux_sandboxes/<id>/` tree (no `files/` child) moves
non-reserved entries into `files/` on `ensureLayout`.

`ensureReady` is **layout only** (create dirs + migrate). It does not download
or mark the sandbox ready for tools.

`installBaseEnv` is **explicit** (UI / provider). Modes that only need layout
(native Linux without a full rootfs pack) may write a base-env marker and set
`status=ready`. Heavier modes (Windows WSL shared distro, Android PRoot)
download/import as needed. **Windows never succeeds as localJail for tools.**

### Platform runtime modes

| Mode | Platform | Notes |
| --- | --- | --- |
| `wsl` | Windows **only** | Real Linux via shared WSL distro `Cuplivo-Sandbox`. UAC once to enable platform; reboot may be required. Rootfs imported once and shared across sandboxes. |
| `localJail` | (legacy enum) | **Not a usable Windows tool mode.** Host `files/` jail still backs path-jailed file ops; shell never falls back to `cmd`. |
| `nativeLinux` | Linux desktop | Shell via `/bin/sh -c`, cwd=`files/`. |
| `proot` | Android | Convenience isolation, **not a security boundary**; network remains unrestricted residual risk. |
| `unsupported` | iOS/macOS/etc. | Tools refused. |

### Windows WSL base env (shared import)

1. Probe `wsl.exe` (`-l -q`). Ready only when marker + `Cuplivo-Sandbox`
   registered and `wsl -d Cuplivo-Sandbox -- echo ok` works.
2. If platform missing: best-effort elevated
   `wsl --install --no-distribution --no-launch` (10 min timeout). Exit 3010 /
   restart messaging → `broken` + prefs flag
   `linux_sandbox_wsl_resume_install_v1` so UI prompts “restart complete — tap
   Install” (no auto-install after reboot).
3. If platform OK but shared distro missing: download Ubuntu base amd64
   (same URL as Android), gunzip to `.tar`,
   `wsl --import Cuplivo-Sandbox {appData}/wsl/Cuplivo-Sandbox <tar> --version 2`.
4. Success → marker + `runtimeMode=wsl` + `ready`. Failure → `broken` (never
   silent localJail success).
5. Shell: only `execWslShell` with distro `Cuplivo-Sandbox`. WSL failure at
   shell time → tool error (`wsl_unavailable` / `sandbox_not_ready`), not cmd.
6. Delete sandbox: destroy sandbox tree only; **do not** `wsl --unregister` the
   shared distro (shared across sandboxes).
7. `isSupported` on Windows stays true (management UI works); tools still
   require `ready` + working WSL.

### Status machine

`disabled` | `notReady` | `installing` | `ready` | `broken`

- Tools (defs + exec) require `status == ready`.
- Load integrity: persisted `installing` → `broken` (crashed mid-install).
- Unknown status string in JSON → `broken` (never silent-ready).
- New sandboxes start `notReady`; create UI may call `installBaseEnv` when base env is checked.

### Backup

Unchanged from v1: prefs / `settings.json` metadata only. Disk under
`linux_sandboxes/` and shared `{appData}/wsl/` is never included in
backup/restore.

### Factory

`createSandboxRuntime(id)` selects Windows (WSL-only), native Linux, Android
PRoot, or unsupported.

### Android PRoot

Hybrid install path:

- Dart: download Ubuntu base tarball (DioHttpClient), extract with
  `package:archive` into per-sandbox `linux/`, patch DNS/hosts/tmp, write
  base-env marker.
- Kotlin (`app.linux_sandbox`): ABI/native lib dir + `execShell` via
  `libproot_exec.so` binding `files/` → `/workspace`.

`ensureReady` remains layout-only. Shell requires ready rootfs (`linux/bin/sh`
+ marker). PRoot is convenience isolation, not a security boundary.

## Consequences

- Windows tools require a working shared WSL distro; folder-jail-only is not
  offered as a ready tool mode.
- UAC / reboot may interrupt first install; resume is user-driven after reboot.
- Android UI may exist earlier than a security claim; copy must not oversell.
- Provider owns status persistence; runtimes own layout, probe, and install.
