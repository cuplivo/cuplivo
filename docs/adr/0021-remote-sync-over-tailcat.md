# ADR-0021: Remote sync over tailcat — a second transport under the same sync engine

**Status:** Proposed (2026-11), ships as experimental
**Deciders:** cuplivo

## Context

[ADR-0003](0003-lan-sync-architecture.md) built LAN sync as one engine plus one transport: a TLS
HTTP listener on the sync port, a per-device self-signed certificate whose SHA-256 **is** the
deviceId, QR/PIN pairing that pins that certificate, and a symmetric, deterministic merge that
never asks which side wins. Protocol 11 carries conversations, business rows, blobs, skills and
workspace content between a user's own devices. The feature assumes the two devices are on the
same network: addresses are enumerated from local interfaces, paired endpoints are LAN endpoints,
and a session is a foreground round or a manual push.

That assumption is the product gap. A phone on cellular and a desktop at home never share a
network, and Cuplivo has no account system, no hub device and no server of its own by design. The
request is to make the same sync work across networks without turning Cuplivo into a service.

The constraints this design had to satisfy:

- **LAN sync does not change.** Not just "still works": the same protocol version, the same wire
  formats, the same merge semantics, the same pairing window, the same LAN QR parser. The remote
  path must be additive, because the LAN transport has years of behavioural detail behind it and
  is the one that ships to everyone.
- **No Cuplivo account, control plane or relay fleet.** The sync face carries API keys and full
  conversations. Sending them through infrastructure Cuplivo runs would change the product's
  privacy story, and running reliable relays is an operational commitment this project does not
  have.
- **No root, no system VPN.** On iOS and Android an app cannot create a system WireGuard
  interface; the transport has to live inside the app process.
- **Encrypted in transit and authenticated peers.** The tunnel is not a substitute for the LAN
  transport's authentication; it may only add a layer beneath it.
- **NAT traversal with a relay fallback.** Direct connections fail often enough (CGNAT, carrier
  firewalls, symmetric NAT) that a relay path has to exist from day one.
- **Five platform targets, with native code.** Android, iOS, macOS, Windows and Linux each need a
  native artifact; the repository's build policy is that CI, not a developer laptop, produces what
  ships.
- **Experimental, with a small blast radius.** The feature is labelled experimental and can be
  changed or withdrawn without moving the LAN contract.

[Tailcat](https://github.com/tailscale/tailcat) is Tailscale's embeddable version of their
WireGuard data plane: point-to-point TCP and UDP over an encrypted path, NAT traversal first and
Tailscale's public DERP relays as the fallback, with no Tailscale account, no control plane and no
root. It ships a C ABI (`cmd/libtailcat`, ABI version 1). `libtailcat` is a Dart package over that
ABI that returns ordinary `dart:io` `Socket`/`ServerSocket` objects, which is exactly the shape
this repository's sync client already speaks.

Two audit facts shaped the choice of *which* libtailcat to consume. Upstream moves quickly, and
the pinned tree needs one Android-specific behaviour overlay: Android denies apps the netlink
socket Go's `net.Interfaces` uses (golang/go#40569), so tailcat's region probe dereferences a nil
interface. The overlay (`native/patches/android_ifaces.go`) registers one synthetic interface with
the outbound source addresses instead. The fork's previous pin had fallen **28 commits behind**
`tailscale/tailcat` `main` — the gap that argued for owning the pin and its audit rather than
inheriting whatever the upstream package happened to publish — and the pin now names the latest
tailcat commit, `7dda98775372`, explicitly.

The LAN sync domain language stays in `CONTEXT.md`; this ADR records the remote decisions, the
rejected alternatives and the platform and size cost the feature is accepted with.

## Considered options

| option | why not chosen |
|---|---|
| LAN sync only, with the user setting up port forwarding / DDNS | router configuration the product cannot do for the user, still fails behind CGNAT, exposes the mTLS listener to the internet, and gives no relay fallback |
| Ask the user to install Tailscale (or any system VPN) and pair over it | an account and a system-wide tunnel outside the app; mobile users cannot run it inside the app's permission model; two products to keep configured |
| Tailscale `tsnet` / official `libtailscale` C library | needs a Tailscale account / auth key and a tailnet registration per device; that is an account system, which this product deliberately does not have |
| Hand-rolled WireGuard (`wireguard-go`) plus our own STUN/signalling | reimplements NAT traversal, relay selection and hole punching, and requires a relay fleet with an SLA — the cost is the whole feature, not a wrapper |
| WebRTC data channels | a signalling service of ours in the middle of every pairing, no stable peer address, and a native WebRTC stack on five platforms |
| A third-party tunnel/relay service (ngrok, Cloudflare Tunnel, …) | account-bound, changing URLs, traffic through their edge, rate limits; no stable identity for a pairing QR to carry |
| Self-hosted DERP relay in v1 | a server, a domain, TLS certificates and an operator on call — the infrastructure the product is trying to avoid; also cannot match the reach of the public relay map on day one |
| Consume the community libtailcat as published, unpinned (or with a local post-checkout patch) | a moving dependency whose native artifacts we did not build, no Android fix, and a local patch is exactly what the next re-base drops ([ADR-0004](0004-follow-upstream-rebase.md)) |
| Embed official tailcat directly in this repository via cgo/gomobile | this repository would own the Go/NDK/Xcode cross-compilation matrix for five targets, including iOS simulator slices; building and signing that matrix is a project of its own |
| Reuse the LAN QR scheme as `cuplivo-pair:v2:` | would change the LAN parser and its behaviour — the one thing the feature must not touch; an old build must answer "not a sync code", not misread a remote one |
| **tailcat behind a self-maintained libtailcat fork whose natives are built by CI** | chosen: the tunnel and relay problem is Tailscale's, the packaging problem is the fork's, and the sync protocol, merge and pairing stay this repository's |

## Decisions

1. **A second transport, not a second sync engine.** Remote sync is the same engine, the same
   wire protocol (10), the same hello/plan/apply/ack exchange, the same merge and the same
   checkpoints. Only the socket underneath the sync client changes. A remote endpoint and a LAN
   endpoint are two entries in the same peer record's endpoint set, and a peer may have both; the
   session code does not know which one it dialed, and the LAN code path is untouched.

2. **The binding is a fork we pin and CI builds.** Cuplivo consumes
   [`cuplivo/libtailcat`](https://github.com/cuplivo/libtailcat), a fork of the libtailcat Dart
   package, at a pinned commit in `pubspec.yaml` (not a version range or a branch). The fork pins
   official tailcat commit `7dda9877537278cde7ce9e700e8381436acc92a8` (Go 1.27.4, C ABI 1) and
   carries exactly one patch over it, the Android interface overlay described above. Native
   libraries are built by the fork's GitHub Actions workflow from that pin and published under a
   tag that names the commit, `native-7dda98775372-1`; the release publishes `BUILD_INFO.json`,
   `SHA256SUMS` and GitHub build-provenance attestations, and the package's build hook verifies
   the downloaded artifact's SHA-256. Nothing is built on a developer machine and nothing is
   patched inside this repository.

   *Audit basis for self-maintenance:* upstream moves quickly, and the fork's previous pin had
   fallen 28 commits behind upstream `main`; that gap is why the pin and its audit are owned here
   instead of inherited. The one patch is Android-only, so the reviewed delta is "whatever moved
   since the previous pin, plus one file". CI builds every target reproducibly and the upgrade is
   a pin bump instead of a re-base conflict. The fork is still an external dependency by pin, so
   this does not carry fork-only architecture (ADR-0004).

3. **The tunnel is below TLS; the existing TLS endpoints stay the terminus on both ends.** The
   tailcat server accepts tunnelled connections on the sync port constant (9527, a protocol
   constant because a peer is addressed by its tailcat address, not by host:port) and relays each
   one to the device's existing LAN sync listener over an ephemeral loopback relay. The dialing
   side maps a stored `tcat:` endpoint to a tailcat dial, relays it into a loopback socket, and
   has the sync client complete the TLS handshake over that socket itself. The handshake has to
   live there rather than in `HttpClient`: when a `connectionFactory` is installed, dart:io
   assumes the factory already produced the transport the scheme needs and writes HTTPS bytes
   over it without wrapping it, so a tunnelled dial is a plain socket that the sync client wraps
   with `SecureSocket.secure` before the first HTTP byte. The TLS session is therefore still
   end-to-end between the two apps — nested inside WireGuard, not replaced by it — so the pinned
   certificate (deviceId = SHA-256 of the peer's DER), the per-peer pairing secret, the protocol
   version and the JSON/gzip codecs are all reused exactly as LAN sync defined them. No TLS
   upgrade of the binding's own socket is needed, which matters because the binding cannot wrap
   its sockets in `SecureSocket`: only the loopback end is wrapped, which is an ordinary socket.

4. **Fixed server identity, ephemeral clients, on the device.** The server persists only
   `privateKey` and `presharedKey` in `<appData>/sync/tailcat-identity.json` (written atomically
   into the app-private sync directory, which is already excluded from backups). Everything
   else — the address text — is derived from those keys, so the device keeps a stable remote
   address across restarts without a server-side directory. Clients generate an ephemeral tailcat
   identity per tunnel and persist nothing, so there is no client key lifecycle to manage and the
   tunnel address alone never authenticates a sync session: the inner pinned TLS and the pairing
   secret do. The key file lives in the sync
   directory beside the device identity because both are device-local secrets and the sync
   directory is already excluded from backups.

5. **Reset rotates the address, and only the remote relation.** "Reset key" mints a new
   keypair/PSK pair, which changes the device's address. Pairing records are kept — the devices
   are still paired in the product's sense — but every `tcat:` endpoint is removed from them;
   dropping the address is the invalidation, so the panel asks the user to re-pair. LAN endpoints,
   LAN sessions and LAN pairing secrets are untouched; a pair that got to know each other on the
   LAN keeps working through a reset. A malformed key file is treated the same way (a new identity
   is minted): the old address is unrecoverable by definition.

6. **A separate pairing payload, and the LAN QR parser is not modified.** Remote pairing uses
   `cuplivo-tailcat:v1:<base64url(JSON)>` with `{d, n, a, pin}`: `d` is the peer's certificate
   fingerprint (the same trust anchor the LAN QR carries, pinned inside the TLS callback), `n` the
   device name, `a` the opaque tailcat address text, and `pin` the six-digit code from the same
   one-shot pairing window LAN pairing uses. The address is a capability: it is shown only in the
   pairing dialog (as text or a QR code), never resident in the panel, and the peer stores it as
   its `tcat:` endpoint (decision 7) — that stored copy is what a later reconnect dials. Parsing
   is a new, independent parser with its own error codes (`not_tailcat_qr`, `bad_version`,
   `malformed`); `SyncPairQrPayload` and the LAN pairing walk are byte-for-byte unchanged. The
   manual path stays "paste the address and the six-digit code": as on the LAN, that path has no
   fingerprint to pin, so the answer is bound to the certificate the session actually saw when the
   pairing is recorded.

7. **The remote endpoint is a token in the existing endpoint vocabulary.** A paired peer stores
   its remote memory as the host `tcat:<tailcat address>` in the endpoint set it already keeps
   (remembered addresses, probe order, per-endpoint names). No schema change, no protocol change,
   no new table: the sync client's dial path rewrites the host only when the marker is present and
   the tunnel runtime exists, and leaves every network address exactly as it was. A relayed
   session also tells the listener that its source is loopback via the `x-cuplivo-remote` request
   marker; the server uses that only to suppress remembering `127.0.0.1` as the peer's LAN
   endpoint, never as authentication. A failed remote endpoint is ordinary endpoint drift, not a
   new failure state. The endpoint is not pairing-only: a peer that runs remote sync advertises
   its `tcat:` endpoint in the hello — the initiator beside its LAN addresses, the responder as
   the only entry in its answer because the initiator has no reverse-dial consumer for LAN hints
   — and both sides persist such a candidate onto the paired record. The field is optional on
   the wire, so an older build ignores it. A pair made on the LAN therefore becomes
   remote-capable the first time the two sessions meet after both sides enable remote sync, with
   no second pairing; a peer without the transport advertises nothing and its record is
   unchanged.

8. **Reachable only while the app runs, with no new daemon.** The tunnel and its listener start
   with the app when the key file exists — a device that has paired remotely must answer without
   the user opening the remote tab first — and start on demand the first time the remote tab is
   opened on a device that never used it. They stop with the app. There is no background service,
   no new sync trigger, and no polling: the existing foreground round and the manual "sync now"
   are the only triggers, on both transports. On iOS this means a suspended app's tunnel stops
   with it, exactly as its LAN listener stops being reachable; the feature does not pretend
   otherwise.

9. **Remote is a latency class, not a new failure language.** A tunnel's first byte may need a
   relay round trip and a NAT traversal attempt, so the remote budgets are wider than the LAN's:
   60 s for a dial, 120 s for the session's first hello, 30 s for a ping or a revoke, with 45 s
   inside the tunnel dial itself for the relay round trip and the NAT traversal attempt (a
   LAN-sized ping deadline would report a present peer as offline over a relayed path). Session
   outcomes, report rows and refusal codes stay the LAN ones; a slow transport is not a different
   protocol.

10. **Experimental is a positioning, not a disclaimer.** The settings entry and page are renamed
    to **Convenient Sync** (「便捷同步」) with a segmented control: **LAN Sync** (「局域网同步」)
    stays the default tab and the remote tab is labelled **Remote Sync (Experimental)**
    (「远程同步（实验性）」). The remote tab carries this device's state, pairing (QR / address +
    code), paired devices, key reset, and an About section that states the WireGuard encryption,
    the P2P-then-DERP behaviour and what the relay can see. The LAN tab is the existing panel body. Because both transports share the data plane, a pair can move
    between LAN and remote at will, and remote can be withdrawn for a platform or build without
    touching LAN sync.

11. **Public DERP first; self-hosted DERP is a later decision.** v1 uses Tailscale's public DERP
    relays through tailcat's default relay map, `https://tailcat.dev/derpmap.json`: Tailscale
    operates those relays, they are free and rate-limited, and their nodes include hosts such as
    `tc301a.ipn.dev` in several regions. Cuplivo configures no custom `derpMapUrl` and runs no
    derper. Direct peer-to-peer is attempted first and is the normal case; the relay is the
    fallback. The relay sees connection metadata (addresses, timing, volume), not sync content,
    which is WireGuard-encrypted end to end and carries the pinned TLS session inside. The About
    copy discloses the relay fallback and that the content stays encrypted on it; the relay's
    geography and the latency it can cost in mainland China (where the nearest public region may
    be far away, for example Tokyo) are recorded here as a risk instead of being promised away in
    the UI. A compliant in-region DERP is something we would accept help with (a GitHub issue is
    the contact path) but have not committed to run.

12. **Platform floors and configuration are part of the decision.** macOS deployment target moves
    from 12.0 to 13.0 (`macos/Podfile` and every build configuration in
    `macos/Runner.xcodeproj`), because the Go runtime inside the library does not run on older
    macOS. iOS needs an app-level `PrivacyInfo.xcprivacy` declaring
    `NSPrivacyAccessedAPICategoryFileTimestamp` (reason `C617.1`) and
    `NSPrivacyAccessedAPICategorySystemBootTime` (reason `35F9.1`), and it is wired into the
    Runner target's Resources phase so it is inside the app bundle; `NSLocalNetworkUsageDescription`
    already exists, and the existing macOS network entitlements already cover the listener and the
    tunnel. Android needs `INTERNET` (already present) and `minSdk` 24 — Flutter 3.47.6's
    `flutter.minSdkVersion` is already 24 (checked against the pinned Flutter tree), so the app's
    Gradle file is unchanged and 16 KB page support is whatever Flutter enables. Linux requires
    glibc 2.28+; shipped Windows builds are x64 only, because the native release has no Windows
    arm64 artifact — a Windows-on-Arm build from source fails at the build hook rather than
    producing an app with a disabled tab, and LAN sync itself stays platform-independent; the web
    is not a shipped target and has no `dart:ffi`.

13. **Size is a first-class cost, paid per shipped architecture.** Each architecture the app ships
    adds roughly **6 MB compressed** and **14–17 MB uncompressed** (platform detail below). The
    library is bundled into the app by the build hook — never downloaded at runtime — so there is
    no code-download or store-policy question, but every user pays the size whether or not they
    enable the feature. Android keeps its per-ABI APKs / app bundle so a download grows by one
    ABI's slice, not by three; a universal macOS build carries both slices. This is accepted for
    an experimental feature and revisited if it becomes the reason not to ship.

14. **Upgrade is a pin bump with an audit, done by CI.** Bumping libtailcat means: (a) review the
    upstream diff since the previous pin, including the commits the old pin lagged, with attention
    to WireGuard, netstack and relay changes; (b) point the fork at the new tailcat commit and let
    GitHub Actions build and publish the new `native-<12hex>-<n>` release; (c) verify the
    attestations and `SHA256SUMS`; (d) update the fork commit pin and the package's recorded
    native hashes in this repository (lockfile included); (e) update this ADR's pin and
    `THIRD_PARTY_NOTICES.md`. There is no runtime auto-update of the native library and no
    floating branch. The Android overlay is removed when upstream lands an equivalent fallback.

## What this does not change

- Protocol version (10), wire formats, merge rules, checkpoints, schema version.
- The LAN transport: listener, candidate enumeration, QR parser, pairing window, pairing secret,
  LAN deadlines and probe behaviour.
- Sync triggers: foreground round and manual sync; no background daemon, no push notifications.
- Backup/restore and workspace rules; the native library and its keys travel with neither.
- The product's no-account, no-server-of-ours stance: the only third party on the path is
  Tailscale's public relay service, and only for relayed connections.

## Consequences

**Positive**

- Two devices on different networks sync with no account, no port forwarding, no hub device and
  no service Cuplivo runs; a direct peer-to-peer path is used when NAT traversal succeeds and a
  relayed path otherwise.
- The blast radius is one socket: the sync engine, protocol, merge, pairing and reporting are the
  LAN ones, so a defect in the tunnel cannot silently change what a sync means, and the LAN path
  can be verified independently.
- The trust model is layered rather than replaced: the tailcat address is a capability, the
  pairing secret authenticates the peer, and the pinned certificate inside the tunnel still
  decides which device is on the other end. A relay therefore cannot impersonate a peer even if
  it forwards the connection.
- The server's address is stable across restarts (fixed keys), while clients stay ephemeral —
  no client key management, no address churn for the device others dial.
- Pairing is the same ceremony users already know: a QR code or an address plus a six-digit code,
  with the same one-shot window and the same certificate pinning; only the payload scheme and the
  way the joiner reaches the listener are new.
- Platform support is explicit rather than inferred: the native release names its targets, so a
  build for an unsupported architecture fails at the build hook and a shipped build never offers a
  mode that cannot work, while LAN sync keeps working on every platform.

**Negative / accepted**

- Every user pays about 6 MB compressed / 14–17 MB uncompressed per shipped architecture for an
  experimental feature, including users who never open the remote tab.
- iOS suspends the app, and with it the tunnel and its listener; remote reachability is a
  foreground property, and a paired device can be "away" until the app is opened.
- Windows artifacts are x64 only: there is no Windows arm64 native library, so a Windows-on-Arm
  source build fails at the build hook instead of shipping a partial app.
- The public DERP path is rate-limited and has no SLA, and mainland China may be relayed through a
  distant region (for example Tokyo); relayed sessions can be slow, and a direct path is not
  guaranteed. The relay map is Tailscale's (`tailcat.dev/derpmap.json`), not ours.
- A pin bump is an explicit, audited action; it never follows upstream automatically, so upstream
  fixes are only present after that audit and rebuild. Keeping the pin current is a standing
  obligation, not an automatic property.
- One Go runtime per process: adding a second Go-based native library later is not supported by
  the runtime; that is a constraint on future dependencies, not just on this one.
- Both the pairing QR and the stored endpoint contain the address, which is a long-lived
  capability; the reset is the revocation path, and the address is kept out of logs
  (`toString()` redaction) and out of the panel's resident display.
- A mixed-version LAN pair is unaffected in the common case (an older build cannot create a
  remote pairing), but a `tcat:` candidate from a newer peer's hello is meaningless to a build
  without the transport and must remain a failed candidate, never a protocol error.

## Risks and mitigations

| risk | why it can happen | what the design does |
|---|---|---|
| iOS background suspension | every app is suspended after a short background window | no background promise; foreground rounds and manual sync are the triggers; the panel reports the peer as away, not as broken |
| Windows on Arm | no native artifact for that architecture | shipped builds are x64 only; an unsupported-architecture build fails at the build hook; LAN sync unaffected; revisit when the binding publishes arm64 Windows |
| DERP rate limits / no SLA | the public relays are free and shared | direct P2P is preferred and normally wins; relayed sessions are slower but protocol-identical; failures are ordinary session errors |
| Mainland China latency | the nearest public DERP region may be distant and CGNAT blocks the direct path | recorded here and in the release notes, and the About copy states the relay fallback and the encryption; the user can fall back to LAN sync; a compliant in-region DERP is open for contribution |
| app size | the native library embeds a Go runtime and netstack | measured, documented and accepted for an experimental feature; per-ABI distribution keeps Android's growth to one slice |
| pin drift | upstream tailcat moves faster than the audit | a pinned fork with one patch, CI-built and attested; every bump is a reviewed pin move, made explicitly rather than followed automatically |
| fixed server key compromise | the key file is the identity | the key file sits in the app's private sync directory, never in backups; reset rotates the address and invalidates the old one |
| expired relay map / relay outage | Tailscale's public infrastructure changes | tunnel failures surface as ordinary "unreachable" reports; the LAN path is always available |

## Platform and size cost

| platform | native artifact | minimum | compressed | uncompressed |
|---|---|---|---|---|
| Android arm64-v8a / armeabi-v7a / x86_64 | one `.so` per ABI | API 24 (already Flutter 3.47.6's default) | ≈ 6 MB per ABI | 15–17 MB per ABI |
| iOS device arm64, simulator arm64/x64 | `.dylib` | iOS 13 (app floor is 15) | ≈ 5.5 MB | ≈ 14 MB |
| macOS arm64/x64 | `.dylib` | macOS 13 (raised from 12) | ≈ 5.5 MB | 14–15 MB |
| Linux x64/arm64 | `.so` | glibc 2.28+ | ≈ 6 MB | ≈ 15 MB |
| Windows x64 | `.dll` | Windows 10/11 | ≈ 6 MB | ≈ 16 MB |

Headline: **≈ +6 MB compressed / +14–17 MB uncompressed per shipped architecture**, matching the
figures in the libtailcat documentation. `THIRD_PARTY_NOTICES.md` records the licenses and the
build provenance of the redistributed binaries.

## Follow-ups

- Decide on a self-hosted, in-region DERP only if the public relay proves to be the blocker for
  real users, and only with an operator willing to run it; adding one is a deployment change, not
  a redesign of this feature (the About copy already names the relay fallback).
- Revisit iOS background reachability if the binding or the platform gains a supported background
  story; today it is out of scope and stated.
- Revisit Windows arm64 when the native release publishes an artifact; until then shipped Windows
  artifacts stay x64 and a source build for another architecture fails at the build hook.
- Bump the pin on a schedule (or when an upstream security-relevant change lands), with the audit
  checklist in decision 14; drop the Android overlay when upstream lands the equivalent fallback.
- Cover mixed-build LAN pairs in tests: a `tcat:` candidate from a newer peer must be treated as
  an undialable candidate by a build without the transport, never as a protocol error.
- Audit logs, crash reports and QR exports for address/key redaction before the feature leaves the
  experimental label.
- Revisit bundling (a per-feature distribution or lazy install) only if the size cost becomes
  unacceptable; v1 keeps the library bundled by the build hook.
- Package the native libraries' own notices (the libtailcat release publishes a
  `THIRD_PARTY_NOTICES` covering Tailscale, WireGuard and the Go dependencies) into the shipped
  artifacts before the feature leaves experimental: today `THIRD_PARTY_NOTICES.md` records them
  at source level only, while the binaries are redistributed inside the app.
