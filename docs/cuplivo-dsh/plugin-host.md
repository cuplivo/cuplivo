# Plugin-enabled real-DSH host — what the E2E may rely on

Status: **verified against the live disposable instance on 2026-11-20 (UTC).**
The host that serves `E2E_DSH_URL` / `E2E_DSH_TOKEN` now runs the two Cuplivo
plugin bundles on top of the stock `dsh web` profile: `@ds-hu/dsh-better-search`
0.5.0 and `@ds-hu/dsh-better-workspaces` 0.4.1. This note records what that
means for the acceptance scenario and the CI wiring: which surfaces the Host now
renders, what survives a reset, what the seeded workspace contains, and which
assertions are safe versus fragile.

It is written for the v2 surfaces that depend on host-side plugin state
(plugin pages in the embedded WebView, the better-workspaces right rail,
terminal, file previews). Nothing here contains the real hostname, address or
token; those stay in the operator's private notes
([`e2e-infra.md`](e2e-infra.md) §10). The API contract is in
[`protocol.md`](protocol.md), the acceptance scenario in
[`e2e-scenario.md`](e2e-scenario.md).

## 1. Host snapshot

| item | value |
|---|---|
| Harness | DSH `0.2.2-rc.1`, Node 22.22.1, pnpm 10.34.9 |
| Unit | `dsh-e2e-web.service` (systemd, `Restart=always`, `MemoryHigh=900M`, `MemoryMax=1300M`) |
| User / shell | `dsh` system account; `/bin/bash` since 2026-11-20 03:58 UTC (was `nologin`) |
| `DSH_HOME` | `/var/lib/dsh-e2e` (disposable) |
| Profile | `web`, at `/var/lib/dsh-e2e/profiles/web` |
| Listeners | TLS reverse proxy on `<e2e-dsh-port>` → `127.0.0.1:3080` (loopback only) |
| Launch token | random per process, 43-char base64url; rotates on every restart |
| Bundles | stock `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app`, then `@ds-hu/dsh-better-search`, `@ds-hu/dsh-better-workspaces` |

`dsh.profile.bundles` in the profile `package.json` lists all four entries;
`node_modules/@ds-hu/` contains `dsh-better-search`, `dsh-better-workspaces`,
`dsh-bw-core`, `dsh-bw-diff`, `dsh-bw-forge`, `dsh-bw-status` and
`dsh-bw-worktree`. Install history is under
`profiles/web/.plugin-manager/logs/operation-*/pnpm.log`.

The plugin inventory endpoint (`pluginInventory/list`) reports **204 entries,
176 active, `managementAvailable: true`, 4 agent presets**. The five plugin rows
are all enabled and `fiberPhase: active` with **no diagnostic**:

- `include:dsh-better-search` — Search services
- `include:bw-diff` — Code changes
- `include:bw-worktree` — New worktree
- `include:bw-status` — Workspace Git status
- `include:bw-forge` — Issues & pull requests

The journal since the last restart contains only the periodic
`[llm-deepseek-api-key] model listing … loaded 2 model(s), skipped 0 row(s)`
lines; no plugin load error, warning or failure.

## 2. What each plugin adds on the host

### 2.1 `@ds-hu/dsh-better-search` 0.5.0

One host row. It registers web search/fetch providers into `ctx.web`, pins
`web.searchProvider`/`web.fetchProvider` defaults, and adds two client surfaces:
a management section inside the native Plugins page, and an optional sidebar
page module.

Verified UI (zh-CN): the `搜索服务` page lists two built-in providers
(`DeepSeek 官方`, `DeepSeek Search API`), shows the empty third-party state
(`还没有第三方搜索服务`), a `添加搜索服务` action, and the settings block
`抓取方式` (`仅官方服务`), `启动时自动测试连接`, `最大结果数 8`,
`超时时间（秒） 30`. The stock settings document still has
`web.searchProvider: deepseek-official` and `web.fetchProvider: http` — the
fixture configures no third-party provider, no keys, and nothing secret.

### 2.2 `@ds-hu/dsh-better-workspaces` 0.4.1

A meta bundle plus four independently switchable rows (`@ds-hu/dsh-bw-core` is
the shared library, not a row):

| row | what it adds |
|---|---|
| `bw-diff` | right-rail page `代码变更`: diff page, action ladder, editor |
| `bw-worktree` | composer worktree strip + right-rail page `新建 worktree` (config `worktreesDir`) |
| `bw-status` | workspace branch badge + composer diff pill |
| `bw-forge` | composer GitHub control + right-rail page `Issue 与 PR` |

Verified UI (zh-CN):

- Right rail, opened with the `打开右侧边栏` button, lists
  `工作区文件` (built in), `代码变更`, `新建终端` (aria-label only),
  `新建 worktree`, `Issue 与 PR`, `更多工具`; closed with `收起右侧边栏`.
- `代码变更` renders `diff`, tabs `未提交` / `本会话` / `对比基线`, branch
  `⎇ main`, toggles `忽略空白` / `自动换行`, `刷新`, `更多 ▾`, and the clean-tree
  empty state `没有变更`.
- `新建 worktree` renders the heading and helper text
  `从当前分支创建一个隔离的 worktree，并在新会话里继续。`, `取消`, `基于:main`,
  `创建`.
- `Issue 与 PR` renders its helper text and `刷新`; because the workspace has no
  GitHub remote and `gh` is not installed on the VPS, it shows the honest empty
  state `该仓库没有可用的 GitHub 远端`.
- `bw-status` shows `main` under the workspace title in a session view and adds
  the composer pill `工作区内修改`.
- The `bw-worktree` composer strip (`本地 ▾`) only appears once the workspace is
  a git repository — it was absent before the seeded `git init` and present
  afterwards. This is the reason the fixture is a repository.

## 3. Persistence: settings and plugin toggles live in the profile patch layer

Both `settings/update` and `pluginManager/setPluginEnabled` persist into the
profile's loader patch document, `<DSH_HOME>/profiles/web/cordis.patch.yml`
(the "your patch layer" file, applied after every bundle layer):

- A settings change appends a patch entry with the owning unit id, package name
  and the changed config, e.g.

  ```yaml
  - id: ui-conversation
    name: "@deepseek-ai/dsh-client-ui-conversation"
    config:
      busyEnter: steer
  ```

- Disabling a plugin row appends a minimal entry such as

  ```yaml
  - id: bw-status
    disabled: true
  ```

  and re-enabling removes it again; the diff was byte-identical after the
  round-trip. `pluginInventory/list` reflected the change immediately
  (`enabled: false`, no `fiberPhase`) and the row returned to `active` after the
  re-enable.

`dsh-e2e-reset` does not touch `profiles/`, so installed bundles, the
enabled/disabled state of every row and all persisted settings survive a reset.
Verified live: a deliberately non-default `ui-conversation.busyEnter` value
survived one reset and was then reverted to the stock default; after two resets
all five plugin rows were still `enabled`/`active` with no diagnostics.

Two restart consequences that are *not* persistent:

- **The launch token rotates.** The two repo secrets must be refreshed right
  after every restart (`publish_secrets.py` in the operator's private notes);
  the local `dsh-url.txt` copy must match the running instance.
- **The operator cookie does not survive.** A v2 cookie minted before a restart
  gets `401 unauthorized`; probes must re-run the
  `GET /?token=…` → `GET /connect?token=…` handshake after a restart. The E2E app
  connects with the token on every run, so it is unaffected.

Settings revisions restart at `0` after a reload even though values persist.

## 4. Seeded workspace fixture

The workspace `/var/lib/dsh-e2e/workspace` (owner `dsh:dsh`, files `0644`,
directories `0755`) is seeded with a small, secret-free fixture:

| path | bytes | sha256 (prefix) | purpose |
|---|---|---|---|
| `hello.txt` | 122 | `e8bf5b50c6eb4ab2…` | 2-line text; first line `Hello from the Cuplivo end-to-end workspace.` |
| `notes.md` | 164 | `8ccaf29ea5b522ca…` | heading, two bullets, one `dart` fence — Markdown preview |
| `data/table.csv` | 58 | `6afb3268217edd03…` | header `name,kind,count` + 3 rows — table preview (renders asynchronously) |
| `assets/pixel.png` | 189 | `cdc1a7091d2bf74c…` | valid 8×8 RGB PNG — image preview |
| `docs/report.pdf` | 599 | `20c34a061dfcdad7…` | valid one-page PDF 1.4, text `Cuplivo E2E report` |
| `data/blob.bin` | 260 | `c8be27199acc4537…` | bytes `0x00…0xFF` + `00 ff fe fd`; deliberately non-UTF8 |

The directory is also a git repository: `git init -b main`, single commit
`209c1e19da7b1373eb0a67ed03f40ca26150199b` (`seed: deterministic E2E workspace`),
clean tree, no remote, ~280 KB total. The repository is what makes the
better-workspaces surfaces render deterministically: the branch badge shows
`main`, the worktree strip appears, and `代码变更` shows `没有变更` instead of a
repository-less error. No remote is intentional — GitHub data is not part of the
fixture.

Read paths verified against the live API and the real agent:

- **Agent tool**: a Chinese prompt asking the agent to read `hello.txt` produced
  one `read` tool call whose result contained both numbered lines, and the
  assistant answered the first line; `turn/end` was `completed` in ≈2.9 s
  including the tool round trip.
- **Workspace files API** (`workspaceFiles/*`, scoped by a session id):
  `list` on `"."` returns `.git`, `assets`, `data`, `docs`, `hello.txt` (122),
  `notes.md` (164), `truncated: false`; `stat` returns the absolute path, a
  version and the byte count; `read` is **1-based** (`offset: 0` is rejected
  with `gateway/bad-request: offset must be a safe integer of at least 1`) and
  returns `text`, `lines`, `eof`, `offset`; `read` on `data/blob.bin` fails
  deliberately with `workspace-file/not-text: "data/blob.bin" is not UTF-8
  text`.
- **`/api/file?path=…`**: `302` to the versioned asset URL for a regular file,
  `403` for a directory, which is the route behind the native preview widgets.
- **Preview fallbacks in the UI**: text and Markdown render in the files panel;
  `pixel.png` renders as an image (`img`, `100%`); `table.csv` shows `表格`
  while its document renderer works (`文档渲染中...`); `data/blob.bin` shows
  `该格式文件暂时无法预览`.

The seed is not a reset. `dsh-e2e-reset` deliberately keeps workspace contents,
so anything an agent writes in one run is still there in the next. The scenario
should read the fixture (and assert presence, not exclusivity) or reset before a
run that needs a pristine tree; it must not assume the tree is untouched.

## 5. Plugin surfaces in the WebView — what is and is not addressable

The DSH Web client is **one SPA with no per-panel URL routing**. Every in-app
navigation (`插件`, `搜索服务`, `自动化任务`, `更多`, a right-rail page) keeps the
browser location at the host root (`https://<e2e-dsh-host>:<e2e-dsh-port>/`,
path `/`, no hash); the panels are React slot registrations, not routes.
Consequences for the E2E:

- **No deep link exists.** Opening a URL cannot select `搜索服务` or a rail page;
  a fresh browse/reload returns to the client's own initial state and, on a
  client with no stored selection, may show the workspace picker
  (`选择工作区` / `选择一个工作区开始`) first. Assertions must navigate in-app
  (role + label / aria) and screenshot the result, never assert a URL.
- **Plugin management rows are client-side toggles.** A row's state lives in
  `pluginInventory` and the profile patch layer; the Web UI reads it over
  `pluginManager/*`. Reading the inventory over RPC is the stable check; the
  plugin pages themselves are a screenshot/smoke surface.

Deterministic labels observed under the client locale `zh-CN` (the host UI is
Chinese; other locales translate these strings, so pin the WebView locale or
prefer API/data assertions):

- Sidebar rows are buttons whose accessible names are exactly `插件`,
  `搜索服务`, `自动化任务`, `更多`; the footer shows `探索未至之境` / `预览版`.
- `插件` page: heading `安装、启用和配置插件`, actions `刷新`, `添加插件`, and
  sections `内置插件配置` (`子智能体`, `网页搜索`, `Agent 循环`, `终端`),
  `实验性插件` (`智能体团队`, `语音输入`, `自定义插件索引`, `自动授权审查`,
  `变更请求与工作树`) and `已安装插件` (`搜索服务`, `工作区增强`).
- `搜索服务` page: `DeepSeek 官方`, `DeepSeek Search API`, `还没有第三方搜索服务`,
  `添加搜索服务`, `抓取方式`, `仅官方服务`, `启动时自动测试连接`,
  `最大结果数`, `超时时间（秒）`.
- `自动化任务` page: tabs `新建` / `已开启` / `已暂停` / `已结束` / `全部`, empty
  state `没有已开启的自动化任务`, action `新建自动化任务`.
- `更多` page: `浏览更多插件`, `创建你的插件`.
- Right rail: `打开右侧边栏` / `收起右侧边栏` are aria-labels; entry text as in
  §2.2. `新建终端` is an aria-label (no text child).
- Terminal: an xterm panel with `bash`, prompt `dsh@<host>:~/workspace$`;
  commands run as the `dsh` user with the workspace as cwd, e.g.
  `echo hello-terminal; pwd; id -un` printed `hello-terminal`,
  `/var/lib/dsh-e2e/workspace`, `dsh`. The panel depends on the `dsh` account
  having a usable shell: while it was `nologin` the panel showed
  `进程已退出（1）` and `This account is currently not available.`; the operator
  changed it to `/bin/bash`, which the runbook must keep.
- Files panel (`工作区文件`): shows the absolute workspace path and a tree
  (`.git`, `assets`, `data`, `docs`, `hello.txt`, `notes.md`); a click opens the
  preview described in §4.

## 6. What the CI may rely on, and what it must not

Safe to rely on for same-repo runs against this host (re-verified after the
restarts below):

| dependency | status |
|---|---|
| Endpoint preflight (token `303`, `/connect` `302`, RPC `200 ok`) | safe; ≈0.3–0.7 s per call from an external runner |
| Model catalog: 2 models (`deepseek-flash`, `deepseek-v4-pro`), `failures: []` | safe while the temporary key has quota |
| Short prompt round trip + streaming, `turn/end: completed` | safe; keep prompts short |
| One registered workspace titled `workspace`, seeded files readable | safe; assert presence, not exclusivity |
| Five plugin rows enabled/active, no diagnostics | safe (same-repo E2E only) |
| Plugin pages and right-rail pages render with the labels above | safe; screenshot/smoke level |
| Terminal command runs as `dsh` in the workspace | safe (requires the bash shell) |
| Text/Markdown/image previews; binary fallback text | safe |
| `git`-dependent surfaces (branch badge `main`, worktree strip, `没有变更`) | safe because the fixture is a repo |

Not safe / do not assert:

- **A URL or hash for a plugin page** — none exists (§5).
- **A pristine workspace** — agent writes persist across resets (§4).
- **GitHub data** — no remote and no `gh` on the VPS; `Issue 与 PR` is an empty
  state, `bw-forge`'s composer control has nothing to talk to. Do not assert PR
  checks, reviews or diffs.
- **Creating a worktree** — it writes under the repository's worktree
  directory, so it is deterministic only right after a reset; a smoke assertion
  on the page's labels is enough.
- **Plugin internals** — provider keys for better-search are not configured, so
  do not call the third-party search path from the test; `web.searchProvider`
  stays on the built-in `deepseek-official`.
- **Plugin versions/labels forever** — the two bundles are pinned at the
  versions above in `package.json`; an operator upgrade is a cue to re-verify
  this note and the fixtures. Prefer data-level assertions over long Chinese
  labels when a locale change is possible.
- **Zero sessions** — concurrent colleagues and the E2E itself create sessions;
  the scenario tolerates existing sessions and resets only when determinism
  matters.

Recommendation on the "should CI install the plugins?" question: **no.**
Plugin state is host-side, installed once by the operator and preserved by
`dsh-e2e-reset`; forks stay hermetic and never reach the host, and same-repo
runs only need the endpoint secrets. If the host is rebuilt, the install steps
are the ones in the operator notes, before the first same-repo run — not
something the workflow should do on every run (it needs registry access and
root on the VPS, which runners do not have). The workflow should keep its
current shape: endpoint preflight, bounded waits, artifact guard.

## 7. Operator runbook additions (2026-11-20)

- `dsh-e2e-reset` stops the unit, deletes `sessions/` and
  `storages/session_projcache/`, clears session references in
  `storages/workspace.json`, restarts, and prints the new launch URL. Observed
  resets: 04:12:18 → 04:12:20 and 04:13:49 → 04:13:56 UTC. Keep expectations:
  `profiles/`, `.credentials.yaml`, the workspace registry entry and the seeded
  files (including `.git`) remain; sessions become 0 at the moment of reset.
- Immediately afterwards: refresh the two repo secrets with
  `publish_secrets.py`, update the local URL copy, and confirm the file matches
  the running instance (`dsh-e2e-url`); the token is new.
- If a probe needs RPC, mint a fresh operator cookie after the restart; a stale
  cookie answers `401 unauthorized`.
- Another admin restart also rotates the token. Always refresh URL + secrets
  right before a validation run, never reuse yesterday's values.
- Leftover from an install run invoked without `DSH_HOME`
  (`/var/lib/dsh-e2e/.dsh/profiles/web`, ≈3.1 MB, same content as the live
  profile): harmless, not loaded by the unit, can be deleted at the next
  maintenance window.

## 8. Verification log (2026-11-20 UTC, disposable instance)

Each item below was exercised against the live endpoint from outside the VPS;
the Web UI checks used Playwright with the operator cookie obtained through the
normal token handshake.

- **A — service after plugin install**: unit `active`, no restarts, RSS
  ≈291 MB shortly after start and ≈300–370 MB steady state (pre-plugin baseline
  ≈292 MB), machine memory available ≈1.2–1.3 GB; listeners as expected; no
  plugin/error/warn journal lines; `pluginInventory` clean; `dsh-url.txt`
  matched the running instance.
- **B — persistence**: settings and row toggles written to
  `profiles/web/cordis.patch.yml` as described in §3; round-trip of
  `setPluginEnabled` restored the file byte-for-byte; a non-default setting
  survived a reset; after two resets all five rows were `active`, and the
  fixture, registry and settings were intact.
- **C — workspace**: seeded files and hashes as in §4; `read` tool, file API and
  `/api/file` all read them; binary read fails with the documented
  `workspace-file/not-text`; previews behave as described.
- **D — UI**: plugin pages, right rail, its three better-workspaces pages,
  terminal and the five preview kinds were opened and screenshotted; the
  location stayed at the host root for every navigation; the worktree strip
  appeared only after the git fixture existed.
- **E — readiness**: catalog `deepseek-flash` + `deepseek-v4-pro`,
  `failures: []`; providers `deepseek-official` + `deepseek-account`; a real
  Chinese prompt with a `read` tool call completed in ≈2.9 s; a terminal command
  printed the expected cwd and user; no blockers found for relying on the host's
  plugin state.

## 9. Pointers

- Host topology, token lifecycle, CI wiring and artifact guard:
  [`e2e-infra.md`](e2e-infra.md).
- Wire protocol and RPC envelope: [`protocol.md`](protocol.md).
- Acceptance scenario and stable widget keys: [`e2e-scenario.md`](e2e-scenario.md).
- Reference screenshots and their reading order:
  `docs/cuplivo-dsh/e2e-evidence/README.md`.
