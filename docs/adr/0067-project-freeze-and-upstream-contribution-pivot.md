# Project freeze at v3.2.1 and contribution pivot to upstream Kelivo

Upstream Kelivo v1.2.7 (2026-09) shipped mature workspace/sandbox, Skills, background generation and scheduled tasks, catching up with roughly half of Cuplivo's added feature set and exceeding it in completeness. Cuplivo has diverged far from the upstream tree — it missed the large data/persistence migration — and several of its architectures remain incomplete. With limited maintainer time and energy, Cuplivo cannot keep pace going forward, and the day-to-day friction of iOS self-signing remains unresolved. The fork has served its purpose as Kelivo's proving ground, including pitching designs upstream (LAN sync and other items still awaited). We therefore freeze Cuplivo at v3.2.1 (2026-09-12, its 42nd release since v1.2.0) and move development to Kelivo's Issues and PRs. The repository stays unarchived as an archive line and the QQ group stays open; users are expected to migrate to Kelivo.

## Considered Options

- **Keep developing Cuplivo in parallel** — rejected: upstream now moves faster, and a diverging fork with an incomplete architecture would keep accumulating maintenance debt (and iOS self-signing makes an iOS release path unviable anyway).
- **Archive the repository** — rejected for now: existing installs and backups remain valid, the archive line is useful for issue triage (checking whether a Cuplivo commit already covers an upstream issue) and the community channel stays reachable.
- **Contribution pivot to upstream Kelivo (chosen)** — issues and small PRs go to `Chevey339/kelivo`; Cuplivo's remaining important features (LAN sync, incremental backup, group chat, etc.) are proposed upstream rather than maintained here.

## Consequences

- The freeze is announced in `README.md` / `README_ZH_CN.md` (both files stay in sync) and on the official website homepage.
- Local branch model changes: `cuplivo` is the frozen archive line tracking `origin/master`; `master` is a pristine mirror tracking `upstream/master` (never pushed to `origin`); `kelivo-dev` is a local-only debug identity layered on `master`; `pr/<issue>` branches are cut from `master` for upstream fork PRs.
- `kelivo-dev` exists so a local build can be installed alongside both Kelivo (`com.psyche.kelivo`) and Cuplivo (`com.cup11.cuplivo`). It uses application id / bundle ids `com.cup11.kelivodev`, display name "Kelivo Dev", binary name `kelivodev`, MCP OAuth scheme `cup11.kelivodev` and App Group `group.com.cup11.kelivodev`. The Dart package name deliberately stays `Kelivo` to keep upstream rebases cheap. This identity commit is never pushed and never included in an upstream PR.
- Issue triage uses this repository as a two-lineage index: `git log cuplivo --grep=…` checks whether Cuplivo already implemented something, `git log master --grep=…` checks upstream. Feature proposals derive from the Cuplivo README feature list.
- No new feature work lands on the Cuplivo line unless explicitly requested; documentation and branding remain its only active surface.
