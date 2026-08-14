# Workspace Terminal is an Android proot PTY, not exec

The mobile Linux sandbox already exposes a one-shot `exec` for the model Shell
tool (no stdin, 128K cap, timeout). A human Termux-like terminal needs a real
PTY. Decision: add an Android-only interactive session (host PTY + proot
`/bin/bash -l`, cwd `/workspace`) behind a new launch spec; do not reuse
`exec`. The page is killed on pop (no Termux-style service). iOS iSH remains
one-shot (stdin is `/dev/null`, kernel boots once). The human terminal is
independent of `shellEnabled` and may run concurrently with model `exec`.

## Considered options

1. **Command-box over `exec`.** Rejected: no stdin, no vim/htop/Ctrl+C — not a terminal.
2. **iOS PTY in v1.** Rejected: iSH stdin is `/dev/null` and the kernel boots once; session work is a separate mountain.
3. **Keep-alive sessions (Termux Service, max 8).** Rejected: user chose kill-on-pop.
