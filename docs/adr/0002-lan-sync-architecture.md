# ADR-0002: LAN sync — entity-row payload, deterministic symmetric merge, per-device pairing

**Status:** Accepted (2026-09)
**Deciders:** cuplivo

## Context

Cuplivo 3.x had LAN sync as a zip exchange: a manual server/client split with a PIN, a plan
built from per-conversation message-ID lists, session-wide conflict-priority knobs
(initiatorWins/serverWins), and settings riding shared_preferences. It failed three ways:
no persistent pairing (host:port re-entry on every IP change), conversation-boundary
blindness (the ID list could not see edits, deletions or reorders), and settings whose
overwrite direction was wrong as often as right.

The Kelivo v1.3.0 baseline this line restarts from ships a persistence layer that was
designed for sync but never got one: `message_rows.updated_at` ("in support of sync/LWW"),
conversation deletion tombstones written transactionally, per-key `preference_rows.updated_at`,
a business-settings router that separates entities from preferences, and a content-addressed
asset store. Meanwhile the backup format changed to packed database snapshots gated by schema
version — so exchanging backup zips between builds is no longer version-portable at all.

The full domain language for this feature lives in `CONTEXT.md` ("LAN Sync"); this ADR
records the pillar decisions and the rejected alternatives.

## Decisions

1. **Entity rows, never files.** Peers exchange versioned repository rows (JSON) over the
   wire; each side applies them through its own repositories at its own schema version. A
   database file or backup zip is never handed to a peer.
2. **Transfer unit vs merge unit.** The conversation subtree (row + messages + parts + asset
   references) moves and applies atomically — nothing can fall through a conversation
   boundary, the 3.x failure mode. Merge resolution is per row: newer
   `COALESCE(updated_at, timestamp)` wins, ties fall to deviceId. Both sides compute the
   same result independently. Concurrent appends interleave by timestamp.
3. **No direction knob.** Because the merge is deterministic and symmetric, the 3.x
   session-priority control has no equivalent. "Which side wins" is never a user question.
4. **Symmetric version gate.** Each side refuses a peer whose database schema version is
   newer than its own. A schema bump pauses sync for the upgrade window rather than letting
   an older build mangle newer rows and propagate the loss through LWW.
5. **Per-device keypair, QR/PIN pairing, pinned listener certificate.** deviceId = hash of the
   public key; pairing exchanges pinned certificates once and mints a per-peer secret. The QR
   path pins the scanned fingerprint inside the handshake (slice-4 amendment); LAN discovery is
   deferred, not part of this decision. The sync face carries API keys,
   so the channel must resist LAN sniffing and impersonation: TLS is server-authenticated (the
   client pins the listener's certificate), and each `/sync/*` request proves the pairing with the
   secret established at pairing. See the amendment below for why client certificates are not the
   mechanism.
6. **Preferences split by the classifier, not by storage.** `BusinessKeyRegistry` gains a
   `syncedPreference` disposition; the new-device test decides membership. Session-position
   keys (`current_assistant_id_v1`, `selected_model_v1`), proxies, fonts, platform flags and
   all `display_*` stay device-local.
7. **Skills ride sync as record + directory blob.** The record's `updatedAt` does not track
   content edits, so skill content is delta-detected by directory hash and transferred as a
   zip blob with deterministic conflict resolution off the checkpointed hash. Workspace
   entities stay device-local.
8. **Apply without restart.** Sync writes ride repository transactions, then one state
   reload (`BusinessPreferences.reload()` + providers' `_load()` + ChatService refresh).
   Restore still restarts — it swaps the database file; sync does not.
9. **Foreground-driven sessions.** An app-resume round (and one after start) plus a manual
   button; no polling, no background daemon on mobile. *Superseded in form by the slice-4
   amendment*: the original discovery trigger and the write-debounce follow-up are not built.

## Amendment (2026-09, slice 1b): mutual TLS → pinned listener + per-peer secret

Decision 5 originally said *mutual TLS with pinned client certificates*: the listener would
request a client certificate and pin the presented certificate's SHA-256 against the peer store.
Implementing slice 1b's end-to-end test showed that **this is not achievable with `dart:io`**:
`HttpServer.bindSecure(..., requestClientCertificate: true)` aborts every handshake against a
self-signed client certificate — `Connection closed before full header was received` on the
client, with an empty trust store and with `withTrustedRoots: true` alike (measured on Dart 3.13 /
Flutter 3.47; a control run with `requestClientCertificate: false` succeeds on the same code).
Since unpaired devices must still reach `/pair` on the same listener, requesting a certificate
cannot be the authentication mechanism at all.

What replaced it keeps the property that motivated the decision — a paired identity must be
proven before any sync route answers:

- **Server → client**: the listener presents its self-signed certificate; the client pins it
  (`badCertificateCallback` compares the presented DER hash against the paired deviceId). Nothing
  else can answer as that peer.
- **Client → server**: pairing mints a 32-byte secret, returned in the pair answer inside the
  TLS session the initiator has already pinned, and stored on both sides. Every `/sync/*` request
  carries `X-Cuplivo-Device` + `X-Cuplivo-Token`; the listener reads the peer record and compares
  in constant time. Pairing and unpairing take effect immediately (no cached trust set).
- **First contact** stays PIN-gated (one-shot, five-minute window), and the responder verifies
  that the claimed deviceId hashes to the certificate in the request, so a passive relay cannot
  forge the binding. The PIN path's MITM exposure is unchanged and still closed later by the QR
  fingerprint.

Identity, keypair and the certificate pin are unchanged; only the client-certificate half is
gone. Revisit if `dart:io` gains a way to request a client certificate without verification, or
if the listener moves to a transport that supports it.

## Amendment (2026-09, slice 2): business entities and preferences

Decision 1 (entity rows) and decision 6 (`syncedPreference`) are implemented, over the same
session and the same decision table as conversations. What the implementation settled:

- **One decision table.** `planRowSync` decides a conversation and a business row with the same
  presence-and-digest reasoning; `planSync` and `planBusinessSync` are two projections of it.
  LWW is likewise one rule — newer `updated_at` wins, an exact tie falls to the higher deviceId
  — so both peers reach the same verdict without negotiating.
- **The wire protocol went to v2.** The hello manifest and the session batch carry business
  sections (entity rows under their stable table name, plus synced preference keys); a v1 peer is
  refused at hello. A business manifest entry reuses the conversation entry shape: `u` is the
  row's `updated_at` and `d` a content hash of its payload (or preference value), which is what
  makes "same clock, different content" visible instead of silently diverging.
- **Deletions ride the per-peer checkpoint**, exactly as message deletions do, so no tombstone
  bookkeeping was added to the hot path of every entity edit.
- **`providers_order_v1` is not synced**: the runtime view derives provider order from the
  provider rows' `sort_order`, which travels with each row.
- **Skills and workspaces are excluded from this slice.** Workspaces are device-local by
  decision; a skill's record is deliberately held back until its directory blob lands (slice 3),
  because a record without its body installs a broken skill.
- **Apply writes rows with the peer's clock**, never `DateTime.now()` — that timestamp is the
  entire basis for the next session's comparison.
- **Reload without restart** (decision 8) needed real plumbing: `BusinessPreferences.reload()`
  re-reads the database into the in-memory view, and a `BusinessStateReloader` re-runs each
  provider's load afterwards. Sync apply and deletion join the same serialized write queue as
  local entity edits, because a provider rewrites a whole entity list at a time and could
  otherwise clobber rows an apply just wrote; the residual read-modify-write window is
  self-healing (the loser's row is still newer on its own device, so the next session re-sends
  it).
- **A restore defers sync writes**: `BusinessPreferences.writesBlockedForRestore` makes the apply
  return deferred, and the session keeps its previous checkpoint entries to retry later rather
  than writing over a restore.

## Amendment (2026-09, slice 3): blobs — attachments, avatars and skill bodies

Decision 7 is implemented, and with it the general rule it implied: **blobs follow URIs**.
The sender scans the rows it is actually sending (message parts, entity payloads, synced
preference values) for `kelivo-file` URIs and publishes one blob entry per referenced file —
canonical URI, sha256, byte size. A skill record publishes a directory entry instead, keyed by
its directory hash. The receiver keeps what it already has (hash match), pulls the rest, and
lands each file at the path its URI names.

What the implementation settled:

- **The wire protocol went to v3.** The session batch carries the blob manifest and the skill
  directory hashes; hello carries the initiator's own listener port. A v2 peer is refused at
  hello, because it would apply rows whose blobs it never receives — the broken-skill case the
  slice-2 holdback existed to prevent.
- **Blobs are pulled, never pushed, and the responder pulls back over the initiator's
  listener.** The manifest travels with the rows, in both directions: the initiator pulls its
  needs over the session it already has, and the responder — which has no session of its own —
  opens a short authenticated client connection to `hello.listenPort` at the address the request
  came from, using the certificate pin and per-peer secret pairing already established. One GET
  per blob (`/sync/blob/<sha256>`), no Range or resume: a LAN retry is cheaper than a resumable
  transfer state machine, and a failed blob is simply retried next session.
- **URIs are never rewritten.** Placement is the canonical path the URI names, so the applied
  rows keep byte-identical payloads and the conversation digests stay comparable. Rewriting a
  URI locally would diverge that conversation's digest and re-send it forever.
- **The server serves only what it published.** `handleFetchBlob` resolves a hash from the
  manifest this device advertised, then from the content-addressed asset registry, then from a
  live skill-directory hash scan; a request never names a path. The receiver's own writes are
  root-allowlisted (`upload`, `images`, `avatars`, `fonts`) — `skills` is a directory blob, and
  workspaces and sessions are device-local.
- **GC needs no lease.** A landed blob is registered against the revisions that reference it
  (`message_asset_rows`), which is exactly what protects it from the sweep and what makes the
  next session skip it on the hash check. The residual race is the sender's own file
  disappearing between manifest and fetch, which surfaces as a reported 404.
- **A blob failure does not defer a conversation but does defer a skill.** A conversation
  without its picture is still a conversation (the row applies, the blob goes pending, the
  report names it); a skill record without its body would install a broken skill, so the record
  waits — the slice-2 holdback, now enforced by the blob outcome rather than by excluding the
  kind.
- **A skill's content clock is its directory hash.** The record's `updated_at` does not track
  body edits, so the manifest digest for a skill is the record payload digest combined with the
  directory hash. That single change makes a body-only edit visible to the ordinary
  presence-and-digest table: the unchanged side adopts the changed side, and a genuine
  concurrent edit falls to the same clock-then-deviceId rule as every other row, with the loser
  named in the report. Deletion removes the row *and* the directory in one operation, because
  the skills rescan would otherwise resurrect a record for a directory that is still on disk.
- **File avatars became portable.** `avatar_type: file` values were stored as host absolute
  paths — meaningless on the peer. They are now written in canonical `kelivo-file` form (the
  same storage form the branding rule already prescribed for managed files), which makes sync,
  backup and cross-platform rendering work through the reading path that was already
  dual-form. Legacy absolute values keep resolving and are canonicalized on load.
- **A directory blob is verified after extraction, not as bytes.** Its hash describes the
  unpacked tree, so the transport checksum would be the wrong check; the receiver re-hashes the
  staged extraction and only then swaps it in, which subsumes a byte check.

No order-repair maintenance task was added for the slice-2 message-order defect: the buggy code
never shipped in a release, so the only affected data is unreleased test-device state, which any
message edit in the affected conversation repairs.

## Amendment (2026-09, slice 4): QR pairing; LAN discovery deferred

Decision 5 said "QR/PIN pairing"; this slice makes the QR the recommended path and settles what
it carries. Decision 9's cadence is replaced by the foreground round, because the discovery
trigger it named is not being built.

What the implementation settled:

- **The QR carries endpoints, the certificate fingerprint and the window's PIN.** One image, one
  scan, no typing: the joiner tries the advertised `ip:port` candidates in order (the responder
  knows its actually bound port, including an ephemeral fallback, and its adapter list — the
  multi-NIC guess is taken away from the human). The payload is versioned
  (`cuplivo-pair:v1:<base64 json>`, the same convention as the provider-share codes) and bound to
  the open five-minute window by the PIN, so a stale photo pairs nothing. Its exposure is the
  same as the dialog it replaces, which already printed the endpoints and the PIN side by side.
- **The fingerprint is pinned inside the TLS callback.** With `expectedDeviceId` set, a
  certificate that does not hash to the scanned deviceId is refused *during* the handshake, so
  the request body — the PIN included — never reaches a wrong endpoint, and the responder's
  window is not spent. This closes the hole PIN typing cannot: a typed code proves nothing about
  which device answered, so an active relay can terminate both legs and mint its own secret for
  each side. Six digits cannot carry a 256-bit fingerprint; a scanned image can. The manual path
  keeps its weaker-but-real property (the answer is bound to the certificate actually seen, which
  defeats a passive relay only).
- **An endpoint that answers wrongly stops the attempt; a dead one moves on.** Connection
  refused or timed out → try the next candidate. Wrong PIN, wrong certificate or identity
  mismatch → stop, because the same answer awaits on every candidate, and a certificate mismatch
  is either a spoof or a recycled address the user can fix by hand.
- **Re-pairing is the repair action for a drifted endpoint.** Scanning a paired device again
  overwrites its address and rotates the secret (the old one is dead on the responder). This is
  why discovery can be deferred without stranding a user whose peer moved, and why the UI says
  "pairing updated" rather than pretending it is a first pairing.
- **Five wrong PINs close the window.** The window did not count failures, and a 6-digit code is
  brute-forceable inside five minutes; reopening mints a fresh PIN and resets the counter. The
  window remains the consent mechanism — there is no approval prompt on the responder (the
  joiner is at the screen showing the code, and the image set is exactly what the old dialog
  exposed).
- **The trigger became the foreground round.** Without a discovery event, the cadence is: the
  app resuming (the "picked the device up" journey) and once after start run one quiet round over
  every paired peer with an endpoint, throttled to one round per minute; "sync now" is never
  throttled. Results land on the peer cards, with no notification — an automatic round must not
  interrupt.
- **Discovery is deferred, not deleted.** mDNS/DNS-SD would cost iOS Bonjour service
  declarations plus the local-network permission, an Android multicast lock, a Windows inbound
  UDP 5353 rule, and a background traffic story — for endpoint auto-healing that a one-gesture
  re-scan covers. The service name `_cuplivo._sync._tcp` is reserved in `CONTEXT.md` so adding it
  later is purely additive (the peer store is already the trust anchor a discovered deviceId is
  checked against).

## Amendment (2026-09, slice 5): clock skew surfaced, lost rows counted, unpair propagated

The last slice closes the claims `CONTEXT.md` made but the code did not yet keep, plus the
evidence gap in the multi-device story.

What the implementation settled:

- **Clock skew is surfaced on both devices, and the protocol version moved to 4.** Hello carries
  the sender's wall clock (`clockUs`, the same µs unit row clocks use); each side compares the
  peer's reading with its own and flags a divergence beyond five minutes in the session report — a
  yellow-flag line, never a failure: the session completes and the rows move. Both sides compute it
  independently from the same two readings, so either card can carry the warning. The threshold is
  a hardcoded health constant (Kerberos-style tolerance): below it, LWW comparisons stay honest for
  any realistic edit rhythm; above it, timestamps lie systematically and the fix is a device clock,
  not a setting. The version bump is deliberate rather than additive — nothing has shipped, the gate
  is strict equality, and a v3 peer would sync *silently* without the warning it cannot compute. A
  missing reading parses to "no warning", not an error.
- **A lost local edit is counted where it was lost.** The apply path already knew which incoming
  rows won LWW; it discarded the losers in silence. It now counts them per face (entity rows,
  synced preferences) and the report carries the number, so "local rows replaced by newer versions
  on the peer" appears on the card. Counters, not names: which row lost stays in the log (the "one
  number per face" doctrine). A loss means the local *content* changed, which is not the same as
  the incoming row winning the comparison: a `bothSend` echoes this device's own row back at a tied
  clock, and the tie-break (higher deviceId) hands it the win — the row is rewritten to adopt the
  peer's clock, which is what keeps the next session's digests equal, but nothing was lost. Only a
  genuinely different incoming row counts. (This is not hypothetical: the first version counted
  every winning apply and reported a phantom lost row on whichever side lost the deviceId
  tie-break, i.e. on a coin flip.)
- **Unpairing is local-first with a best-effort remote notice.** This device always drops the
  pairing at once; it then asks the peer to forget it over the same authenticated listener
  (`POST /sync/revoke`, authenticated by the pairing secret it still holds, so a device can only
  ever revoke its own pairing and never a third device's). The call is fire-and-forget with a short
  timeout: unpairing must not wait on a peer that may be gone. When the notice cannot land, the
  fallback is the ordinary path — the next session is refused as `not_paired`.
- **A refusal now reaches the peer card.** The card renders `peer.lastReport`, but the early-return
  paths (peer refusal, schema refusal, missing endpoint) returned without persisting anything, so a
  refusal left the card showing the *previous* successful session. Every attempt against a peer
  record now lands its outcome on that record, which is what the transport-error path already did.
  The 401 the listener answers an unpaired caller with is likewise parsed as a `not_paired`
  *refusal* instead of surfacing as a raw `SyncClientException(401)` string: the localized "no
  longer paired" wording exists for exactly this case and was unreachable for it.
- **Multi-hop convergence is tested, not just argued.** A↔B↔C (with no A↔C pairing) proves the three
  properties the pairwise-session design claims: A's rows reach C through B; a repeat round moves
  nothing, because B holds A's rows at A's own clock and cannot push them back (the no-ping-pong
  property a re-stamping hop would break); and a row edited concurrently on all three converges
  identically everywhere, with the fixed point stable.

## Considered options (rejected)

- **Whole-database / backup-zip exchange** — not version-portable; a newer schema on an
  older build is fatal by design (`database_schema_too_new`).
- **Conversation-atomic LWW** — simplest semantics, but silently loses one side of a
  concurrent append ("messages I wrote are gone").
- **Fork preservation (duplicate conversations)** — lossless, but pushes "which branch is
  real" onto the user.
- **Session-priority direction knobs** — existed only because 3.x's merge was asymmetric.
- **Downgrade translation** (newer peer rewrites payload to older schema) — a field-level
  translation layer maintained for a rare upgrade window.
- **Shared passphrase trust** — simplest UX, but no device identity and no per-device
  revocation.
- **Hybrid logical clocks in v1** — requires touching every `updated_at` bump path in
  upstream repository code; skew is surfaced in the report instead.
- **Workspace sync** — managed workspaces are unbounded local project directories; linked
  workspaces are host paths by definition.
- **Byte-verifying a skill zip against its entry hash** — the entry hash is the *directory*
  hash (that is what makes content edits visible to the row plan), so verifying the zip bytes
  against it rejects every honest transfer. Structural extraction plus a re-hash of the staged
  tree is the check that matches the value's meaning. (Measured: the integration test failed
  every skill transfer with `blob_digest_mismatch` until this was fixed.)
- **Blob push in the session body** — no second connection, but custom binary framing, no
  per-blob retry, and a huge response body; pulling one blob per GET over an authenticated
  connection reuses the transport, the pin and the secret unchanged.
- **A GC lease for in-flight transfers** — the registry registration that already protects a
  referenced asset is the same thing that protects a freshly landed blob, so a lease would be
  machinery for a window that no longer exists.
- **A responder-side approval prompt for QR pairing** — the image set is what the old dialog
  already showed side by side (endpoints + PIN), so a prompt would add a step without removing
  an exposure: the gate stays "the responder opened the window and a human is holding the code
  in front of the joiner's camera".
- **A separate nonce inside the QR** — the one-shot window PIN already plays that role (random
  per window, spent on use, dead when the window closes), so a second replay guard would be
  redundancy with its own lifetime to get wrong.
- **A URI-scheme QR payload** (with deep-link registration) — the app's QR convention is a
  versioned prefix plus base64 JSON (`ai-provider:v1:`); nothing here needs the OS to route a
  scan into the app, and a custom scheme would tempt exactly that.
- **A local-write debounced sync trigger** — it means touching every write path to serve a
  journey the foreground round already covers (open the other device → it syncs); the write
  burst it would capture is small next to the complexity of hooking repositories.
- **mDNS/DNS-SD discovery in this slice** — see the amendment; the platform surface (Bonjour
  declarations, local-network permission, multicast lock, inbound UDP rule) is real and
  endpoint drift has a one-gesture repair.
- **An optional clock field that keeps protocol v3** — strictly more forgiving (a v3 peer would
  simply never warn), but it buys a silent gap in the exact report line this slice exists to make
  true, to stay compatible with a protocol nothing had shipped against yet.
- **A "revoked remotely" state on the peer record** — showing the peer a tombstone card
  ("unpaired on the other device") instead of deleting its record. Most explicit, but it adds a
  state and a way to leave it, so a device that can never sync again keeps a permanent card;
  deleting on the notice, with the fallback refusal as the safety net, keeps one representation of
  "not paired".
- **Listing the losing rows by name on the card** — the ids are opaque (a skill id, a preference
  key) and a concurrent-edit burst would inflate the card without bound; the number on the card
  plus the ids in the log is the split the rest of the report already uses.

## Consequences

- A schema bump pauses sync between mismatched builds (days at most); the refusal message
  directs the user to update.
- `BusinessKeyRegistry` becomes the single maintenance point for the syncability of each
  preference key; new keys default to `unknownPreference` (never synced) until classified —
  fail-closed.
- The state-reload entry point (apply → reload) is new plumbing that must be kept coherent
  as providers evolve; it is also the foundation any future runtime data-change feature
  would reuse.
- Clock skew tilts LWW within the warning threshold; the sync report names the offending
  device.
- File avatars now travel (slice 3) instead of degrading: the stored value is canonical, so the
  blob follows it like any other referenced file.
- A blob that the sender no longer has is retried once per session while it stays pending, and
  the report says how many never arrived; the *rows* still converge, so a missing picture never
  blocks a conversation.
- Serving a skill body costs one zip build per content hash and launch (cached under
  `<skills>/.sync-blob-cache`), and directory hashing is memoised per launch by fingerprint.
- A peer whose address drifted reports `unreachable` until the user re-scans its QR or edits the
  address: without discovery nothing heals an endpoint change on its own, and the panel shows the
  last attempt rather than an "online" state it cannot verify.
- A foreground round over an unreachable peer waits out the client's 10-second connect timeout
  before moving to the next one; the one-minute throttle keeps that from becoming a loop, and
  nothing blocks the UI.
- Scanner availability follows the platform, not the package: `mobile_scanner` has Android and
  iOS implementations wired here, so desktop devices show a QR and pair by typing the code (the
  port field is prefilled with the preferred port). macOS is deliberately excluded even though
  the package supports it — this target declares no camera usage description or entitlement, and
  an undeclared camera access kills the process; adding those is platform config, not a Dart
  change, and belongs with a macOS build to verify it.
- A clock more than five minutes off shows on both cards after any session, successful ones
  included; the warning clears itself once the clock is fixed and the next session runs, since
  only the last report is stored.
- Unpairing a device that is off leaves its record on the peer until that peer's next attempt
  fails with "no longer paired" — the user unpairs it there, the same gesture as any other
  cleanup.
- A `/sync/revoke` arriving while a session with that peer is running drops the responder's
  session state; the in-flight session then fails on its next beat because the peer no longer
  authenticates — the same end state as a revocation landing between sessions.
- `lastReport` now also changes on a refused attempt, so the card's "last synced" line marks the
  last *attempt*; that was already true of transport failures, and the outcome line beside it
  says what happened.
