# Real-DSH Android E2E infrastructure

Status: **part A live and verified; part B prepared and awaiting approval.**
The real DeepSeek Harness instance is running on the disposable `us-vps1` VPS
and was exercised end to end (launch token → operator cookie → RPC → WebSocket
mux → real streamed model answer) from a host outside that VPS. The workflow
change that feeds the endpoint into the Android E2E build is written and
validated offline, but **not applied** to
`.github/workflows/e2e-android.yml` yet: it lands as a separate small PR to
`master` (branch `ci/e2e-dsh-endpoint`) **before** the feature PR asks for
`/e2e`, because `/e2e` runs the default branch's workflow.

The delivery contract this document serves is
[`roadmap.md`](roadmap.md) gate 5 ("the E2E run must exercise a real DSH
server") and gate 6 ("never commit secrets or private infrastructure").

Nothing in this file, and nothing in the CI change, contains the real hostname,
address or token. Those live in the operator's private notes (see
[§10](#10-real-values-and-where-they-live)); the repository only knows the
secret names `E2E_DSH_URL` and `E2E_DSH_TOKEN`.

## 1. Topology

```text
GitHub Actions runner (ubuntu-24.04, Android API 36 emulator)
        │  HTTPS 443? no: TLS on <e2e-dsh-port> only
        │  Host: <e2e-dsh-host>:<e2e-dsh-port>
        ▼
nginx on us-vps1  — public entry point, existing publicly-trusted certificate
        │  plain HTTP, loopback only
        ▼
127.0.0.1:3080  dsh --profile web (0.2.2-rc.1, Node 22.22.1)
   DSH_HOME=/var/lib/dsh-e2e   (isolated, disposable)
   user: dsh (system account)  workspace: /var/lib/dsh-e2e/workspace
        │  DeepSeek Messages API
        ▼
https://api.deepseek.com/anthropic   (temporary, quota-limited test key)
```

Why this shape:

- **DSH binds loopback only.** Its `--host` flag accepts one concrete local
  address and rejects wildcards; loopback keeps the token-authenticated API off
  the public TCP plane.
- **nginx (already installed) is the TLS terminator.** A certificate whose name
  already resolves to this VPS exists (managed by certbot), so no DNS change is
  needed. Port 443 is already serving an unrelated API and is not touched; the
  DSH vhost listens on a dedicated port.
- **Nothing else on the VPS is modified.** nginx's existing vhosts and the
  other services on the box are left as they are; the only additions are one
  nginx server block, one systemd unit, one service user and one harness home.

## 2. Reproducible VPS setup

Target: Ubuntu 24.04, 2 vCPU / 2 GiB RAM / 30 GiB disk, `us-vps1` in the
operator's SSH config (`ssh us-vps1`). Every command below is run on that VPS
as root unless stated otherwise. Replace `<e2e-dsh-host>` with the public
hostname whose certificate and DNS record point at this machine, and
`<e2e-dsh-port>` with the dedicated TLS port (8443 in the current setup).

### 2.1 Node 22 and the DSH CLI

```bash
# Self-contained runtime: nothing in the distro's package set changes.
curl -fsSL --retry 2 -o /opt/node22.tar.xz \
  https://nodejs.org/dist/v22.22.1/node-v22.22.1-linux-x64.tar.xz
tar -xJf /opt/node22.tar.xz -C /opt
mv /opt/node-v22.22.1-linux-x64 /opt/node22
rm -f /opt/node22.tar.xz
export PATH=/opt/node22/bin:$PATH
node --version                      # v22.22.1

# The CLI and its bundles resolve from this installation.
npm i -g @deepseek-ai/dsh@0.2.2-rc.1
dsh --version                       # 0.2.2-rc.1
```

`dsh`'s entry file starts with `#!/usr/bin/env node`, so any unit that runs it
must put `/opt/node22/bin` on `PATH` (the first two service starts in this
bring-up failed with exit 127 for exactly that reason).

### 2.2 Isolated harness home and service user

```bash
useradd --system --home-dir /var/lib/dsh-e2e \
  --create-home --shell /usr/sbin/nologin dsh
install -d -o dsh -g dsh -m 750 /var/lib/dsh-e2e
install -d -o dsh -g dsh -m 750 /var/lib/dsh-e2e/workspace
```

`DSH_HOME` must be a dedicated directory: the web profile auto-initializes on
first boot from the shipped templates (`@deepseek-ai/dsh-base`,
`@deepseek-ai/dsh-web-app`) and writes sessions, projections, credentials and
the browser-session signing secret underneath it. It never touches the
operator's own `~/.dsh`.

### 2.3 Model credential

The provider is the shipped `deepseek-official` route (model
`deepseek-flash`), configured with the temporary test key from the product
brief. The key exists **only** in a root-owned environment file on the VPS:

```bash
# Value typed/piped on stdin so it never appears in argv or shell history.
install -o root -g root -m 0600 /dev/stdin /etc/dsh-e2e.env <<'EOF'
DEEPSEEK_API_KEY=<temporary-test-key>
EOF
```

`systemd` reads `EnvironmentFile=` as root before dropping privileges, so the
service user never needs read access to the file. No key is stored in the
repository, in workflow files, in artifacts or in this document.

### 2.4 systemd unit

`/etc/systemd/system/dsh-e2e-web.service` (redacted; the two `Environment=`
lines carry the policy, not secrets):

```ini
[Unit]
Description=DeepSeek Harness web (disposable E2E instance)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
User=dsh
Group=dsh
Environment=DSH_HOME=/var/lib/dsh-e2e
Environment=NODE_ENV=production
Environment=PATH=/opt/node22/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NODE_OPTIONS=--max-old-space-size=768
EnvironmentFile=/etc/dsh-e2e.env
WorkingDirectory=/var/lib/dsh-e2e/workspace
ExecStart=/opt/node22/bin/dsh --profile web --no-open \
  --host 127.0.0.1 --port 3080 \
  --public-url https://<e2e-dsh-host>:<e2e-dsh-port> \
  --trusted-host <e2e-dsh-host>
Restart=always
RestartSec=5
TimeoutStopSec=20
# This 2 GiB box also runs nginx and another service; keep the harness fenced.
MemoryHigh=900M
MemoryMax=1300M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/dsh-e2e
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dsh-e2e-web

[Install]
WantedBy=multi-user.target
```

Flag notes:

| flag | why it is set this way |
|---|---|
| `--host 127.0.0.1` | DSH rejects wildcard binds; loopback keeps the plain-HTTP API off the public plane. |
| `--port 3080` | Free on this host; DSH's own default. |
| `--public-url https://<host>:<port>` | Advertised root for the printed URL, `DSH_WEB_URL` and browser handoff. Grants no trust by itself. |
| `--trusted-host <host>` | Port-less authority, so the `/api` Host fence accepts the browser-visible `host:<port>`. The listener's own bind literal is accepted independently of this list. |
| `--no-open` | No display; avoids a credential-free diagnostic path. |

Enable and start:

```bash
systemctl daemon-reload
systemctl enable --now dsh-e2e-web.service
journalctl -u dsh-e2e-web.service -f     # wait for the "dsh web:" URL line
```

On first boot the profile materializes under
`/var/lib/dsh-e2e/profiles/web` and the process prints a tokenized URL such as
`dsh web: https://<host>:<port>/?token=<token>`. Measured footprint after boot:
~300 MB RSS for the Node process (box has 2 GiB + swap; `MemoryMax` leaves the
other services untouched).

### 2.5 nginx TLS front

`/etc/nginx/conf.d/dsh-e2e-tls.conf` (redacted):

```nginx
# Dedicated TLS front for the disposable DSH E2E instance.
server {
    listen <e2e-dsh-port> ssl;
    listen [::]:<e2e-dsh-port> ssl;
    server_name <e2e-dsh-host>;

    # No access log: the initial /?token= exchange puts the launch token in the
    # request URI, and this credential must not be persisted to disk.
    access_log off;
    error_log  /var/log/nginx/dsh-e2e.error.log;

    ssl_certificate     /etc/letsencrypt/live/<e2e-dsh-host>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/<e2e-dsh-host>/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_http_version 1.1;
        # Keep the browser-visible authority, including :<port>. The /api
        # Host/Origin fence compares the Origin against this exact authority,
        # so forwarding a port-less Host makes every browser request 403.
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        # /api/remote.mux is a WebSocket and must upgrade.
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        # Streamed turns must not be buffered.
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 10s;
    }
}
```

`$connection_upgrade` is the map already provided by nginx's conf.d directory on
this host. Apply with `nginx -t && systemctl reload nginx` (a reload, not a
restart: the existing vhost on 443 is unaffected).

Two non-obvious constraints, both learned the hard way in this bring-up:

1. **`Host` must include the port.** DSH's `/api` fence accepts a trusted
   authority and then compares the request's `Origin` against the `Host`
   authority. A browser on a non-default port sends
   `Origin: https://<host>:<port>`, so a port-less `Host` produced a 403 on
   every plugin/API fetch. `proxy_set_header Host $http_host` fixes it; a
   port-less `--trusted-host` entry still matches.
2. **Do not log the tokenized URL.** The launch-token exchange is a
   `GET /?token=…`, so nginx's default access log would persist a live
   credential. `access_log off` on this vhost; the DSH journal keeps its own
   startup line, which is root-readable only.

### 2.6 Operator helper scripts on the VPS

`/usr/local/bin/dsh-e2e-url` (mode 700, root only) prints the current launch
URL:

```bash
#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
systemctl is-active --quiet dsh-e2e-web.service || { echo "service not active" >&2; exit 1; }
journalctl -u dsh-e2e-web.service --no-pager --since "-30 days" \
  | grep -oE "dsh web: https?://[^ ]+" | tail -1 | sed -E "s/^dsh web: //"
```

`/usr/local/bin/dsh-e2e-reset` (mode 700) returns the instance to a
deterministic pre-run state: stops the service, removes `sessions/` and the
projection cache, clears the workspace's `sessionIds` (the workspace itself
stays registered, so clients do not have to pick a directory again), restarts
and prints the new URL. It keeps the profile, the model credential and the
browser-session signing secret.

## 3. Connectivity model

| question | answer |
|---|---|
| Is there a host firewall? | No: `ufw` inactive, `iptables -L` empty on this host. |
| Is there a provider-level port filter? | Observed none for the chosen port. A SYN to a non-listening arbitrary port on the public address is answered with an immediate RST (not a timeout), and the TLS port answers from a different provider's machine. |
| Was it tested from outside the VPS? | Yes: token exchange, `/api` RPC, `wss://…/api/remote.mux` upgrade and a real streamed prompt were run from a host in a different network (public path, not loopback). |
| Was it tested from GitHub's network? | Not directly in part A. The final proof is the `/e2e` run itself; the workflow now carries a fast preflight that distinguishes "unreachable" from "token rotated", so a network block would show up as an explicit failure before the emulator starts. |
| Is cleartext HTTP acceptable in the app? | `android/app/src/main/AndroidManifest.xml` sets `android:usesCleartextTraffic="true"` and there is no `network-security-config`, so a plain-HTTP endpoint *would* work. It was still rejected: the launch token is a credential, so the public leg is TLS. |
| Does the emulator trust the certificate? | Yes: it is a publicly-trusted certificate (same ACME CA already used by the host's other vhost); recent Android system trust stores include the CA, and the Flutter/Dart HTTP client uses the platform store. |
| What does a valid request look like? | TLS to `<host>:<port>`, `Host: <host>:<port>`, no `Origin` (native client) or a same-authority `Origin` (WebView/browser), cookie from `/connect` or `/?token=`. |

Alternatives considered and rejected:

- **DSH-native TLS** (`--tls-cert/--tls-key`): works, but DSH never renews or
  reloads certificates, so the certbot material would have to be copied into a
  service-readable directory and refreshed with a deploy hook plus a service
  restart. nginx already runs and already reloads on renewal.
- **Path prefix behind the existing 443 vhost**: would modify an unrelated,
  actively used API vhost and depend on prefix-stripping. A dedicated port is a
  smaller blast radius.
- **Self-signed certificate**: the app would need a `network-security-config`
  plus a bundled CA, i.e. a repository change for infrastructure reasons.
- **Plain HTTP on a public port**: rejected for credential hygiene; it would
  also skip the trust-fence exercise.

## 4. Security model

What the launch token grants, and what bounds the blast radius:

- **Owner-level control of one disposable harness.** With the token an
  attacker can mint an operator cookie and drive RPC/streams as the owner: read
  sessions (there is no personal data in this home), create sessions, run the
  agent's tools inside `/var/lib/dsh-e2e/workspace` as the `dsh` system user.
  The service has `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome` and a
  memory fence; the host's other services are not reachable by it (loopback
  bind is the API surface, the agent shell is unprivileged).
- **The temporary model key is reachable from the agent shell.** The DSH
  process inherits `DEEPSEEK_API_KEY` from its unit environment, and the agent's
  bash tool runs as a child of that process, so it can read the variable. This
  is acceptable because the key is explicitly temporary, quota-limited and has
  an expiry, and the endpoint is only handed to same-repository PR builds. It is
  called out in the risk table so nobody reuses a long-lived credential here.
- **The token is a process credential, not a stored config value.** DSH mints a
  fresh random launch token per process; there is no stable-token option in
  0.2.2-rc.1. Rotation is therefore a restart away (see §6).
- **The operator cookie survives restarts.** `/connect` mints a signed operator
  cookie valid for 30 days, signed with a secret persisted in
  `DSH_HOME/.credentials.yaml`. Restarting DSH invalidates the launch token but
  not an already-minted cookie. CI always starts from the launch token, so this
  only matters for manual debugging.
- **No credential in logs.** nginx access logging is off for this vhost;
  systemd's journal keeps the tokenized startup line for root only; the CI
  workflow passes the values through a `0600` file, never argv, and a
  post-run guard deletes any artifact that contains the token and fails the
  job (§7.5).
- **Fork PRs never receive the token.** `/e2e` runs in the base repository's
  context, where repository secrets *are* available, and it checks out the
  PR's head. The request job therefore resolves the head repository via the
  pull-files/pull API and the run job only receives the secrets when the head
  repository is this repository (§7.1).

## 5. Endpoint contract for the acceptance scenario

The Android acceptance scenario (and the app code it drives) reads two
compile-time defines:

| define | value |
|---|---|
| `E2E_DSH_URL` | base root, e.g. `https://<e2e-dsh-host>:<e2e-dsh-port>` — no token, no trailing slash |
| `E2E_DSH_TOKEN` | the launch token |

```dart
const e2eDshUrl = String.fromEnvironment('E2E_DSH_URL');
const e2eDshToken = String.fromEnvironment('E2E_DSH_TOKEN');
final connectionUrl = e2eDshUrl.isEmpty ? '' : '$e2eDshUrl/?token=$e2eDshToken';
```

Rules for a scenario that exercises the real server:

1. **Both defines empty → hermetic mode.** The scenario must still boot the
   app, navigate and capture its screenshots; it skips only the assertions that
   need a live server (or points them at the in-process stub of §9). It must
   pass. This is what a fork PR always gets.
2. **Both defines set → real mode.** Connect, create a session, send one short
   prompt, wait (bounded) for the streamed assistant answer, capture the
   acceptance frames. A real run currently costs ~9 K tokens of system prompt
   plus the answer.
3. **Exactly one set → fail loudly.** A half-configured secret must not
   silently degrade to "hermetic green".
4. **Never print the URL or token.** No `print`, no log line, no `debugPrint`,
   no filled-in text field in a captured frame. The workflow's artifact guard
   turns such a leak into a failed job, but the scenario is the first line of
   defence.
5. **Bound every wait.** A stale token or unreachable host must surface as a
   clear failure, not a hang; the workflow preflights already cover the
   endpoint, and the scenario should use a generous but finite timeout (the
   harness caps the drive run at 420 s).
6. **Start from a fresh session.** Sessions accumulate on the instance between
   runs; a scenario must not assume "no sessions yet", only that it can create
   one. `dsh-e2e-reset` (§6) restores the empty state when a deterministic
   starting point matters.

A model round trip takes 1–3 s against the current endpoint; the whole E2E job
stays inside its 45-minute timeout with a wide margin.

## 6. Token rotation and reset runbook

The launch token changes on **every** DSH start. Two recipes, both run from the
operator's machine (never inside the repository):

```
# Rotate: restart the DSH process, then refresh both repository secrets.
#   (the helper script uses gh for cuplivo/cuplivo and prints nothing secret)
/root/research/e2e-infra/rotate.sh

# Reset: clear sessions/projections but keep the workspace and profile, then
# refresh the secrets from the new process token.
ssh us-vps1 dsh-e2e-reset
/root/research/e2e-infra/publish-secrets.sh
```

Three scripts on the VPS own the lifecycle (all mode 700, root only):
`dsh-e2e-url` prints the current tokenized URL, `dsh-e2e-rotate` restarts the
service, waits for the listener and prints the new URL, and `dsh-e2e-reset`
clears sessions/projections, keeps the workspace registration, restarts and
prints the new URL.

`rotate.sh` (operator host) performs: `dsh-e2e-rotate` over SSH, verify the new
URL with a bounded `GET /?token=… → 303`, and write both values to the
repository secrets through `gh secret set` from stdin, so the values never
reach argv or the transcript. `publish-secrets.sh` does the last step from
whatever instance is currently running.

**Stale-token behaviour in CI:** the run job's first preflight requests the
endpoint with the configured token and classifies the answer:

| response | workflow result |
|---|---|
| `303` | proceed to the API preflight and the build |
| `401`/`403` | fail in seconds with `::error::` text naming the rotation command |
| no response (`000`, `curl` error) | fail in seconds with a reachability message |
| anything else | fail with "a valid launch token returns 303" |

Measured on the live instance: a stale token answers `401` in ~0.6 s; an
unreachable host errors out immediately with curl exit 7. Nothing retries and
nothing waits on the emulator, so a rotated secret never looks like a hang.

## 7. CI wiring (prepared patch — not applied yet)

The change is deliberately confined to `.github/workflows/e2e-android.yml` plus
a note in `docs/e2e-android.md`. It ships as its own PR to `master` because
`/e2e` (an `issue_comment` run) executes the **default branch's** workflow; a
feature PR cannot use a wiring change that only exists on its own branch.
Pre-merge validation of the wiring uses the `run-e2e` label or a
`workflow_dispatch` on the branch (§8), both of which use the ref's own
workflow version.

### 7.1 `same_repo` gate (request job)

The request job gains one output, `same_repo`, and resolves it per event path:

| event | resolution |
|---|---|
| `issue_comment` (`/e2e`) | `gh api repos/$REPO/pulls/<n>` → `.head.repo.full_name` compared case-insensitively with the base repository |
| `pull_request` (label) | `github.event.pull_request.head.repo.full_name != github.repository` is already computed as `PR_IS_FORK`; same repo means not a fork |
| `workflow_dispatch` + `pr_number` | the same pull-API comparison |
| `workflow_dispatch` ref-only | `true` for an ordinary ref of this repository; **`false` for any `refs/pull/*` ref**, because a PR ref can name fork code |
| deleted fork repo (`.head.repo` is `null`) | `false` |

The `gh` JSON is fetched with the read-only `pull-requests: read` permission
the request job already has; no new permission is added.

### 7.2 Secrets reach the build only for a same-repository PR

```yaml
    env:
      E2E_DSH_URL: ${{ needs.request.outputs.same_repo == 'true' && secrets.E2E_DSH_URL || '' }}
      E2E_DSH_TOKEN: ${{ needs.request.outputs.same_repo == 'true' && secrets.E2E_DSH_TOKEN || '' }}
```

Both are repository **secrets** (so GitHub masks them in every log line). On a
fork `pull_request` run GitHub supplies no repository secrets at all; on an
`issue_comment` run it does, which is exactly why the gate exists. The `run`
job is the only job that receives them — `request`, `skip` and `publish` do
not.

### 7.3 Values reach the compiler from a `0600` file

```yaml
      - name: Prepare the real-DSH dart-defines file
        if: env.E2E_DSH_URL != '' && env.E2E_DSH_TOKEN != ''
        run: |
          set -euo pipefail
          define_file="$RUNNER_TEMP/e2e_dsh_defines.json"
          umask 077
          python3 - "$define_file" <<'PY'
          ...writes {"E2E_DSH_URL": …, "E2E_DSH_TOKEN": …} and chmods 0600...
          PY
          echo "E2E_DSH_DEFINES_FILE=$define_file" >> "$GITHUB_ENV"
```

The build then adds `--dart-define-from-file="$E2E_DSH_DEFINES_FILE"` and the
file is deleted immediately after the build. Consequences: the token never
appears on a command line (no `ps`, no logged argv), never in the job log, and
never in the workspace after the build. The arm64 manual-review APK is built
**without** the module, so the distributed artifact cannot embed the token.

### 7.4 Fast preflights

Two steps run right after checkout and before the ~15-minute build/emulator
work:

1. **Endpoint + token**: bounded `curl` of `/?token=…`, expecting `303`; a
   `401`/`403` prints the rotation command, an empty response prints a
   reachability message.
2. **API contract**: bounded `GET /connect?token=…&interactions=answer`
   expecting `302`, then a `POST /api/session/list` with the RPC envelope
   expecting `200 {"ok":true,…}`. This proves the operator-cookie exchange the
   app actually uses, not just the landing page.

Both are skipped when the defines are empty, so fork PRs behave exactly as
before.

### 7.5 Artifact guard

E2E logs, screenshots, video and the review APK are published to artifacts and
to an artifact branch. A step before the uploads greps `build/e2e` for the
token (the x64 test APK, which legitimately carries the compiled defines, is
excluded because it is never uploaded), deletes any hit, and fails the job. A
scenario that prints the URL therefore fails the run instead of publishing a
credential.

### 7.6 Repository configuration

Create in `cuplivo/cuplivo` → Settings → Secrets and variables → Actions:

| name | kind | value |
|---|---|---|
| `E2E_DSH_URL` | repository secret | the base root, e.g. `https://<e2e-dsh-host>:<e2e-dsh-port>` |
| `E2E_DSH_TOKEN` | repository secret | the current launch token (`ssh us-vps1 dsh-e2e-url`) |

Both are secrets, not variables, so the values are masked in logs. The operator
can set them without exposing the values:

```bash
printf '%s' "$BASE_URL" | gh secret set E2E_DSH_URL   -R cuplivo/cuplivo
printf '%s' "$TOKEN"    | gh secret set E2E_DSH_TOKEN -R cuplivo/cuplivo
```

### 7.7 Exact patch

```diff
--- a/.github/workflows/e2e-android.yml
+++ b/.github/workflows/e2e-android.yml
@@ -78,6 +78,7 @@
       target: ${{ steps.decide.outputs.target }}
       target_count: ${{ steps.decide.outputs.target_count }}
       reason: ${{ steps.decide.outputs.reason }}
+      same_repo: ${{ steps.decide.outputs.same_repo }}
     steps:
       - name: Decide whether to run
         id: decide
@@ -112,6 +113,11 @@
           target=""
           target_count=0
           reason=""
+          # Whether the checked-out revision belongs to this repository. The
+          # real-DSH endpoint and token are handed to the build only then: an
+          # issue_comment run carries the repository's secrets even when the PR
+          # head lives in a fork, so the origin must be resolved from the API.
+          same_repo=false
 
           emit() {
             {
@@ -125,6 +131,7 @@
               echo "target=$target"
               echo "target_count=$target_count"
               echo "reason=$reason"
+              echo "same_repo=$same_repo"
             } >> "$GITHUB_OUTPUT"
           }
 
@@ -138,6 +145,8 @@
             pr_head_sha="$(printf '%s' "$pr_json" | jq -r '.head.sha')"
             pr_head_ref="$(printf '%s' "$pr_json" | jq -r '.head.ref')"
             pr_author="$(printf '%s' "$pr_json" | jq -r '.user.login')"
+            # A deleted fork repository yields null; that is not this repo.
+            pr_head_repo="$(printf '%s' "$pr_json" | jq -r '.head.repo.full_name // ""')"
             return 0
           }
 
@@ -150,6 +159,12 @@
                 target="$DISPATCH_TARGET"
                 head_sha="$GITHUB_SHA"
                 checkout_ref="${DISPATCH_REF:-$GITHUB_REF_NAME}"
+                # A PR ref may name fork code; only ordinary refs of this
+                # repository are allowed to receive the DSH credential.
+                case "$checkout_ref" in
+                  refs/pull/*) same_repo=false ;;
+                  *) same_repo=true ;;
+                esac
                 echo "Manual run on $checkout_ref (no PR comment)."
               else
                 if ! printf '%s' "$pr_number" | grep -Eq '^[0-9]+$'; then
@@ -164,6 +179,9 @@
                   exit 0
                 fi
                 run=true
+                if [ "${pr_head_repo,,}" = "${REPO,,}" ] && [ -n "$pr_head_repo" ]; then
+                  same_repo=true
+                fi
                 target="$DISPATCH_TARGET"
                 head_sha="$pr_head_sha"
                 checkout_ref="refs/pull/$pr_number/head"
@@ -177,8 +195,10 @@
               checkout_ref="refs/pull/$pr_number/head"
               requested_by="$GITHUB_ACTOR_NAME"
               can_comment=true
+              same_repo=true
               if [ "$PR_IS_FORK" = "true" ]; then
                 can_comment=false
+                same_repo=false
                 echo "Fork PR: artifacts only (pull_request token is read-only)."
               fi
               run=true
@@ -221,6 +241,9 @@
                 exit 0
               fi
               run=true
+              if [ "${pr_head_repo,,}" = "${REPO,,}" ] && [ -n "$pr_head_repo" ]; then
+                same_repo=true
+              fi
               head_sha="$pr_head_sha"
               checkout_ref="refs/pull/$pr_number/head"
               can_comment=true
@@ -370,6 +393,13 @@
       E2E_PR_NUMBER: ${{ needs.request.outputs.pr_number }}
       E2E_HEAD_SHA: ${{ needs.request.outputs.head_sha }}
       E2E_REQUESTED_BY: ${{ needs.request.outputs.requested_by }}
+      # Real-DSH acceptance endpoint. Both values come from repository secrets
+      # and are handed to a same-repository build only: a fork PR's code must
+      # never see the launch token, and on a fork `pull_request` run GitHub
+      # supplies no repository secrets at all. Empty means "hermetic scenario
+      # only" -- the acceptance test must still run and pass without them.
+      E2E_DSH_URL: ${{ needs.request.outputs.same_repo == 'true' && secrets.E2E_DSH_URL || '' }}
+      E2E_DSH_TOKEN: ${{ needs.request.outputs.same_repo == 'true' && secrets.E2E_DSH_TOKEN || '' }}
     steps:
       - name: Checkout the requested revision
         uses: actions/checkout@v6
@@ -378,6 +408,57 @@
           fetch-depth: 1
           persist-credentials: false
 
+      - name: Preflight the real-DSH endpoint
+        # Fail in seconds instead of after a 15-minute emulator run when the
+        # endpoint is down or the launch token rotated with a DSH restart.
+        if: env.E2E_DSH_URL != '' && env.E2E_DSH_TOKEN != ''
+        run: |
+          set -uo pipefail
+          status="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
+            "$E2E_DSH_URL/?token=$E2E_DSH_TOKEN" || true)"
+          case "$status" in
+            303|307) echo "DSH endpoint accepted the launch token." ;;
+            401|403)
+              echo "::error::The DSH endpoint rejected the launch token (HTTP $status)."
+              echo "::error::The token is minted per DSH process: refresh the E2E_DSH_TOKEN secret with 'ssh us-vps1 dsh-e2e-url' and re-run."
+              exit 1
+              ;;
+            000|'')
+              echo "::error::The DSH endpoint did not answer (no HTTP response). Check that the host is up and the TLS front is reachable."
+              exit 1
+              ;;
+            *)
+              echo "::error::The DSH endpoint answered HTTP $status; a valid launch token returns 303."
+              exit 1
+              ;;
+          esac
+
+      - name: Preflight the real-DSH API
+        # The app talks to the Remote API with the operator cookie, not the
+        # launch token, so prove that exchange too before building.
+        if: env.E2E_DSH_URL != '' && env.E2E_DSH_TOKEN != ''
+        run: |
+          set -uo pipefail
+          jar="$RUNNER_TEMP/e2e_dsh_cookies.txt"
+          code="$(curl -sS --max-time 15 -c "$jar" -o /dev/null -w '%{http_code}' \
+            "$E2E_DSH_URL/connect?token=$E2E_DSH_TOKEN&interactions=answer" || true)"
+          if [ "$code" != "302" ]; then
+            echo "::error::The DSH /connect token exchange failed (HTTP ${code:-none}); expected 302."
+            exit 1
+          fi
+          rid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
+          body="{\"type\":\"client-request\",\"rpcId\":\"$rid\",\"method\":\"session/list\",\"payload\":{\"args\":{\"_request\":{}}}}"
+          reply="$(curl -sS --max-time 20 -b "$jar" -H 'content-type: application/json' \
+            -X POST "$E2E_DSH_URL/api/session/list" --data "$body" -w '\n%{http_code}' || true)"
+          rpc_code="${reply##*$'\n'}"
+          rpc_body="${reply%$'\n'*}"
+          rm -f "$jar"
+          if [ "$rpc_code" != "200" ] || ! printf '%s' "$rpc_body" | grep -q '"ok":true'; then
+            echo "::error::The DSH Remote API preflight failed (HTTP ${rpc_code:-none})."
+            exit 1
+          fi
+          echo "DSH API preflight passed (token -> cookie -> session/list)."
+
       - name: Set up Java
         uses: actions/setup-java@v4
         with:
@@ -400,15 +481,52 @@
       - name: Record start time
         run: echo "E2E_START=$(date +%s)" >> "$GITHUB_ENV"
 
+      - name: Prepare the real-DSH dart-defines file
+        # The launch token is a live credential. It reaches the compiler from a
+        # 0600 JSON file rather than argv, so it never appears in a process
+        # list or a logged command line, and the file is deleted right after
+        # the build. The review APK is built without it.
+        if: env.E2E_DSH_URL != '' && env.E2E_DSH_TOKEN != ''
+        run: |
+          set -euo pipefail
+          define_file="$RUNNER_TEMP/e2e_dsh_defines.json"
+          umask 077
+          python3 - "$define_file" <<'PY'
+          import json, os, sys
+
+          path = sys.argv[1]
+          with open(path, "w", encoding="utf-8") as handle:
+              json.dump(
+                  {
+                      "E2E_DSH_URL": os.environ["E2E_DSH_URL"],
+                      "E2E_DSH_TOKEN": os.environ["E2E_DSH_TOKEN"],
+                  },
+                  handle,
+              )
+          os.chmod(path, 0o600)
+          PY
+          echo "E2E_DSH_DEFINES_FILE=$define_file" >> "$GITHUB_ENV"
+
       - name: Build the E2E test APK (x86_64)
         id: build_e2e_apk
         run: |
           set -euo pipefail
           mkdir -p build/e2e
+          # One entry per accepted dart-defined value. Empty on fork PRs and on
+          # hosts without the endpoint, which keeps the build hermetic there.
+          defines=()
+          if [ -n "${E2E_DSH_DEFINES_FILE:-}" ]; then
+            defines+=("--dart-define-from-file=$E2E_DSH_DEFINES_FILE")
+          fi
           flutter build apk --debug \
             --target="$E2E_TARGET" \
-            --target-platform=android-x64
+            --target-platform=android-x64 \
+            "${defines[@]}"
           cp build/app/outputs/flutter-apk/app-debug.apk build/e2e/e2e-test-x64.apk
+
+      - name: Remove the real-DSH dart-defines file
+        if: always() && env.E2E_DSH_DEFINES_FILE != ''
+        run: rm -f -- "$E2E_DSH_DEFINES_FILE"
 
       - name: Build the manual-review APK (arm64)
         id: build_review_apk
@@ -516,6 +634,24 @@
           } >> "$GITHUB_OUTPUT"
           if [ -f build/e2e/summary.md ]; then
             cat build/e2e/summary.md >> "$GITHUB_STEP_SUMMARY"
+          fi
+
+      - name: Keep the DSH launch token out of published artifacts
+        # E2E logs, screenshots, video and the review APK are published; a
+        # credential must never be in them. The x64 test APK is the one file
+        # that legitimately carries the compiled defines and it is not
+        # uploaded, so it is excluded; a hit anywhere else (a scenario that
+        # printed the URL, or a review APK that inherited the defines) fails
+        # the job and removes the offending files.
+        if: always() && env.E2E_DSH_TOKEN != ''
+        run: |
+          set -uo pipefail
+          found="$(grep -rlF --exclude=e2e-test-x64.apk -- "$E2E_DSH_TOKEN" build/e2e 2>/dev/null || true)"
+          if [ -n "$found" ]; then
+            echo "::error::The DSH launch token reached E2E artifacts; deleting the offending files."
+            printf '%s\n' "$found"
+            printf '%s\n' "$found" | xargs -r rm -f
+            exit 1
           fi
 
       - name: Upload screenshots
```

### 7.8 `docs/e2e-android.md` note (same PR)

```diff
--- a/docs/e2e-android.md
+++ b/docs/e2e-android.md
@@ -155,6 +155,38 @@
 - The workflow needs to exist on the default branch before `/e2e` can be used.
   On the workflow's own pre-merge PR, use the `run-e2e` label or
   `workflow_dispatch` with an explicit target.
+
+## Real-DSH acceptance endpoint
+
+The Android E2E run can exercise a **real DeepSeek Harness server** for
+same-repository PRs. The `request` job resolves the PR head repository through
+the pull API (or `pull_request` metadata); only when it is this repository does
+the `run` job receive `E2E_DSH_URL` and `E2E_DSH_TOKEN` from repository secrets
+of the same names. A fork PR, and any run where the head origin cannot be
+proven to be this repository, gets neither value.
+
+The values reach the app as compile-time Dart defines from a `0600` JSON file
+(`--dart-define-from-file`), never as command-line arguments, and the file is
+deleted right after the build. A scenario reads them with
+`String.fromEnvironment('E2E_DSH_URL')` / `String.fromEnvironment('E2E_DSH_TOKEN')`:
+
+| defines | scenario contract |
+|---|---|
+| both empty | hermetic run: boot, navigate and capture as usual; skip only the assertions that need a live server (or use the in-process stub); must pass |
+| both set | real run: connect, create a session, send one prompt, assert the streamed answer, capture the screenshots |
+| exactly one set | misconfiguration: fail with a clear message instead of silently running hermetically |
+
+`E2E_DSH_URL` is the base root (`https://<host>:<port>`, no token, no trailing
+slash); `E2E_DSH_TOKEN` is the DSH launch token (minted per DSH process, so it
+rotates with every server restart). Compose the connection URL in the scenario
+as `$E2E_DSH_URL/?token=$E2E_DSH_TOKEN` when the connection form takes the
+tokenized URL.
+
+Two preflight steps run before the build and fail in seconds when the endpoint
+is unreachable or the token is stale. A step after the run deletes any artifact
+that contains the token and fails the job, because `e2e-logs`, screenshots,
+video and the review APK are published. The endpoint is operator
+infrastructure: its address and token live outside this repository.
 - The emulator profile is API 36, `pixel_7`, `google_apis`, `x86_64`,
   SwiftShader, with animations and the spellchecker disabled.
 - The cleanup workflow runs on PR close and weekly; it deletes the per-PR
```

## 8. Pre-merge validation of the wiring PR

`/e2e` cannot validate a workflow change before it lands on `master` (it uses
the default branch's workflow). Two paths run the PR's own workflow version:

1. **`run-e2e` label on the wiring PR** (`pull_request` event → the PR's
   workflow). The PR has no changed acceptance scenario, so the request job
   skips the emulator (`no-target`); this validates the `same_repo` output and
   the gating expressions but not the build step.
2. **`workflow_dispatch` with an explicit target** — the complete pre-merge
   proof:

   ```bash
   gh workflow run e2e-android.yml --ref ci/e2e-dsh-endpoint \
     -f pr_number=<wiring-PR-number> \
     -f target=integration_test/e2e/example_acceptance_test.dart
   ```

   `workflow_dispatch` accepts a non-default ref once the workflow file exists
   on the default branch (it does), and uses that ref's workflow file. With
   `pr_number` set, the request job resolves the head repository from the pull
   API — a same-repository PR, so `same_repo=true` — checks out
   `refs/pull/<n>/head`, passes the secrets, runs both preflights and builds
   the APK with the defines. The example scenario itself does not use the
   defines, so the run proves the plumbing, not the product path; the real
   acceptance is the feature PR's `/e2e` run after merge.

After the wiring PR merges, the feature PR's `/e2e` comment runs `master`'s
workflow against the PR's head commit: `same_repo=true`, real endpoint,
acceptance screenshots from a real remote turn.

## 9. Fallback: hermetic stub scenario

When the endpoint is unavailable — fork PR, a rotated token before the
operator refreshes it, or the VPS being down — the acceptance run must still
produce UI evidence. The contract is a **hermetic scenario**:

- The scenario runs an in-process stub DSH server inside the integration-test
  process (`HttpServer` + `WebSocketTransformer` on `127.0.0.1:0`) that speaks
  the minimum the app needs: token exchange (`/?token=` → 303 + cookie),
  `/connect` → operator cookie, `session/list`, `session/create`, one streamed
  assistant turn on `/api/remote.mux`. No external network, no credential.
- It asserts the same UI states and captures the same frames as the real run;
  only the assertions that are about *server state* are skipped when
  `E2E_DSH_URL` is empty.
- The PR body must state which mode the published run used. Gate 5 of the
  roadmap requires at least one real-endpoint run before the feature PR is
  declared done.

The stub is deliberately scenario-local (not a repository-wide fake): the
acceptance harness stays a UI acceptance tool, and `pr-check.yml` unit tests
cover the client protocol separately.

## 10. Real values and where they live

Operator-only, outside the repository, directory mode 700, files mode 600:

```text
/root/research/e2e-infra/README.md      endpoint, token, evidence, runbook
/root/research/e2e-infra/dsh-url.txt     current tokenized launch URL
/root/research/e2e-infra/rotate.sh      restart + refresh the two repo secrets
/root/research/e2e-infra/publish-secrets.sh  publish current values as secrets
/root/research/e2e-infra/ui-*.png        browser evidence from the real prompt
```

The repository knows only the secret names. Neither a hostname, an address nor
a token belongs in a commit, a PR body, a screenshot or an artifact; the
workflow guard enforces the last two.

## 11. Risks and mitigations

| risk | severity | mitigation |
|---|---|---|
| Token rotates on every DSH restart, silently invalidating CI | medium | fast preflight fails in seconds with the rotation command; `/connect` operator cookie survives restarts for manual sessions; `rotate.sh` refreshes both secrets in one step |
| Token leaks through a same-repository PR's code | low | endpoint only for same-repo PRs (trusted authors); token rotates on demand; harness home is disposable, agent shell unprivileged, no personal data; temp model key is quota-limited and expiring |
| Token leaks through a published log/screenshot/APK | medium | token never on argv, `0600` define file deleted after build, review APK built without defines, post-run artifact guard deletes hits and fails the job, no filled token field in captured frames |
| Fork PR reaching the endpoint | high if broken | `same_repo` resolved from the pull API on every event path, `refs/pull/*` dispatch refs forced false, empty secrets otherwise; validated offline against same-repo/fork/deleted-fork/mixed-case cases |
| Certificate renewal breaks the TLS front | low | certbot already renews this name and nginx reloads on renewal; the new vhost only references the existing live paths; no DSH-side certificate copying |
| Provider-level port filter blocks the chosen port | medium | confirmed reachable from another network and no RST/timeout asymmetry; preflight reports an unreachable endpoint explicitly; fallback port swap is a one-line nginx change |
| 2 GiB host OOMs while DSH runs | low | measured ~300 MB RSS; `MemoryHigh=900M`, `MemoryMax=1300M`, `NODE_OPTIONS=--max-old-space-size=768`; 1.4 GiB swap already configured; other services untouched |
| Model key expires or quota runs out | medium | preflight cannot detect it (it does not call the model); the real scenario fails with a visible model error; replace `DEEPSEEK_API_KEY` in `/etc/dsh-e2e.env` and restart; hermetic fallback keeps UI evidence flowing |
| Sessions accumulate across runs and perturb screenshots | low | scenario starts from a fresh session; `dsh-e2e-reset` restores an empty state while keeping the workspace registration |
| Single VPS is a single point of failure for acceptance | medium | fallback scenario (§9); rotation/reset runbook; the infra is intentionally disposable and reproducible from this document |
| Secret values set by the operator drift from the running instance | medium | `rotate.sh`/`publish-secrets.sh` always derive from the live instance; stale values fail the preflight with an explicit message |

## 12. Manual verification recipes

Run from any machine with network access; replace the placeholders.

```bash
B='https://<e2e-dsh-host>:<e2e-dsh-port>'
T='<token>'

# 1. Unauthenticated root must be 401.
curl -sS -o /dev/null -w '%{http_code}\n' "$B/"

# 2. Launch token exchange must be 303 with a cookie.
curl -sS -D - -o /dev/null "$B/?token=$T" | grep -iE '^(HTTP/|set-cookie:)'

# 3. Operator cookie exchange must be 302.
curl -sS -c /tmp/dsh.jar -o /dev/null -w '%{http_code}\n' \
  "$B/connect?token=$T&interactions=answer"

# 4. RPC must return {"ok":true,...}.
curl -sS -b /tmp/dsh.jar -H 'content-type: application/json' \
  -X POST "$B/api/session/list" \
  --data '{"type":"client-request","rpcId":"1","method":"session/list","payload":{"args":{"_request":{}}}}'
```

A WebSocket mux check and a real streamed turn need a browser or a WS client;
the part-A evidence was captured with a headless browser against the real
endpoint: tokenised URL → workspace → prompt → streamed "pong" (1 s) and a
20-line answer at ~200 tok/s, with a `wss://…/api/remote.mux` socket and 125
downstream frames through nginx.

## 13. Current status

| item | state |
|---|---|
| DSH 0.2.2-rc.1 installed on us-vps1, isolated home, web profile | done |
| systemd unit (`enabled`, `Restart=always`, resource/hardening fences) | done |
| DeepSeek provider using the temporary test key | done — real turns recorded |
| TLS front on the dedicated port, loopback-only DSH listener | done |
| token → cookie → `/api` RPC → `wss` mux → streamed answer, from outside | verified |
| `dsh-e2e-url` / `dsh-e2e-reset` / `rotate.sh` / `publish-secrets.sh` | done and exercised |
| `E2E_DSH_URL` / `E2E_DSH_TOKEN` repository secrets | set, values never printed |
| workflow patch + docs note | prepared, validated offline, **awaiting approval / separate PR** |
| body of the port filter and the GitHub-side network path | final proof is the first `/e2e` run |
