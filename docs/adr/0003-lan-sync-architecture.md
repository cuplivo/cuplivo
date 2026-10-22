# ADR-0003: LAN sync — entity-row payload, deterministic symmetric merge, per-device pairing

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
  *Superseded for the certificate case by slice 10*: a failed handshake is the *address* being
  wrong, not the device answering, so it now disqualifies that address and the walk continues. A
  refused PIN or an identity mismatch — the device itself — still ends the attempt.
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

## Amendment (2026-09, slice 6): sending is not receipt — review hardening

An adversarial review of slices 1–5 found twelve defects; this amendment records what the
fixes settled. The most important one is a correction to the checkpoint doctrine the earlier
slices assumed.

- **A checkpoint entry only advances to state the peer reached.** "Sent" and "received" were
  indistinguishable: the responder answered the push with a bare count, so a conversation it
  deferred (a generation was writing there) or a business apply it deferred (a restore held
  the write fence) still advanced the initiator's checkpoint. On the next session the peer's
  older copy matched that checkpoint, and the merge's deletion oracle — which reads the
  checkpoint as "the rows the peer last had" — deleted the sender's own new rows. Both faces
  did this, and so did the mirror: the responder recorded its own send optimistically, so when
  *it* initiated next, it read the initiator's older copy as a deletion and dropped its own
  message. The push beat now answers with an acknowledgement (`SyncApplyAck`: applied,
  deferred conversation ids, `businessDeferred`) and both hellos carry the list of what that
  side could not apply last session, persisted in the checkpoint, so the peer re-sends rather
  than inferring a deletion. The oracle additionally skips conversations the peer reported as
  never applied.
- **Rejected: confirming every advance against the peer's next hello manifest.** Strictly
  simpler on paper — an entry moves only when the peer's own advertisement equals it — but it
  breaks deletion propagation, and the failure was measured, not argued: the sender's entry is
  also what lets the *peer* tell "this device deleted the conversation" from "this device never
  had it", and a device that refuses to record what it sent makes its own later deletion
  uninterpretable. The peer either skips the deletion (it stays, forever, on one device) or
  downloads the conversation back. Inferring from manifests alone cannot distinguish the two,
  which is why the deferral has to be *reported* rather than inferred.
- **A peer deletion keeps its checkpoint entry until the peer's manifest agrees.** Dropping the
  entry when the deletion is requested made the next session read "a conversation the peer has
  and this device never had" and download it back, so a deletion the peer deferred (a
  generation writing there) resurrected the subtree. The entry is dropped by `bothDeleted`, the
  state where both manifests agree it is gone. *Rejected: reporting failed deletions back in
  the response batch* — the same rule covers it with no wire field, because the requesting side
  retries until the peer's manifest catches up.
- **Rival version-group rows resolve to one row per slot.** Two devices that each regenerate
  the same message create rows with the same `(conversation_id, group_id, version)` and
  different ids. The merge unions by id, so both rows had to exist and the second insert
  violated the schema's unique key: the apply aborted, no checkpoint was written, and every
  later session of that pair failed identically. One winner now takes the slot — newer
  `COALESCE(updated_at, timestamp)`, ties to the higher row id; the clock and the id are both
  device-independent, so both peers decide alike — and the losers are deleted with their parts
  and counted as deletions.
- **The slot a message row carries leads the order assignment.** The apply re-derived every
  order by `(timestamp, id)`, which silently undid the placement the app itself maintains
  (deleting a group's anchor version moves the surviving revision onto the freed slot). Because
  `message_order` is in no digest, the local placement could never win the next session back
  either. `(timestamp, id)` now only breaks a tie on the carried slot, and sequential
  assignment keeps the result dense and unique; concurrent appends still interleave alike.
- **A message's mutation clock is floored at its own timestamp.** `updated_at` was stamped with
  bare `DateTime.now()`, unlike message parts and provider artifacts, which already floor it. A
  message authored under a skewed (future) peer clock therefore had its clock *lowered* by a
  local edit, and the peer's untouched copy won the next exchange, reverting the edit on both
  devices.
- **A peer-chosen skill id is contained.** `SkillDirectorySync` interpolated the id into
  `p.join(root, id)` unchecked (the sibling `deleteDirectory` did check), so a crafted id could
  rename a directory — and recursively delete the displaced one — outside the skills root on
  POSIX targets. Every path built from a skill id now goes through the same canonicalize +
  `isWithin` rule.
- **Asset-reference replacement is scoped to its conversation, and only the subtree's own
  messages register assets.** A revision id is a global primary key, so the unscoped delete let
  a wire-crafted part unlink a same-named message in another conversation; with its references
  gone, the asset GC quarantined and deleted the file while the victim message still showed it.
- **The hello body identity must equal the authenticated caller.** `handleHello` never read its
  `peerDeviceId`: the peer lookup, the busy guard and the session slot were keyed on the body's
  `deviceId`, so a paired caller could name a different paired device and have that device's
  next fetch beat run the caller's plan — including deletions — while the caller's own beats
  died on a missing session. A mismatch is a new refusal reason (with localized wording).
- **`/pair` is capped and every malformed body is a 4xx.** The route answers before any
  authentication, yet its body was folded into memory whole and a JSON object missing the
  pairing fields — or an unparseable certificate — threw out of the route as a 500 with the
  server's stack printed. The body is read through one pass that stops buffering past 64 KB and
  answers 413 once drained; missing fields and bad PEMs answer 400.
- **Preference reads are registry-filtered, and business deletions join the write queue.** The
  manifest, apply and delete paths all consult `BusinessKeyRegistry`, but the read path did not,
  so a fetch request naming a device-local key was answered with its value. And
  `deleteBusinessRow` called the repository directly while this ADR already said apply *and*
  deletion share the serialized write queue a provider's whole-list rewrite runs on.
- **The pairing code dialog refuses route-level pops.** It was barrier-dismissible and ignored
  the back gesture while the five-minute window it opens had no other surface; only the explicit
  close (which cancels) or expiry ends it now.

## Amendment (2026-09, slice 7): confirmed receipt everywhere, and a replaced database

A second adversarial review found eleven more defects, ten of them in the same family as the
slice-6 correction: places where the checkpoint advanced, or was read, on something other than
state the peer demonstrably reached. It also produced the one missing concept — a device whose
database is replaced wholesale.

- **The fetch beat's sends are not receipt either.** Slice 6 fixed the push beat; the responder's
  answer to the fetch beat stayed optimistic, so an initiator killed between fetching and applying
  left the responder asserting the peer held the conversation, and the next sessions deleted the
  only copy on both devices (reproduced end to end). The responder no longer advances an `iSend`
  entry on that beat: the entry appears one session later, on `none`, when both manifests agree —
  the manifest *is* the receipt, and no fourth beat is needed.
- **A deletion is announced, not inferred from an absence.** Removing the optimistic advance
  removed the only signal that a conversation the peer lacks was *deleted* rather than never
  delivered, and the plan read it as "never had it" — so a deletion could no longer propagate at
  all (measured: the conversation stayed on one device forever). Each hello now carries the
  conversations this device still holds a shared-history record for but no longer has, with the
  digest both sides last agreed on: the entry is derived from the checkpoint, so it is announced
  for exactly as long as the peer has not caught up, and the digest preserves *edit beats delete* —
  a copy that moved on since is not deleted. This is the alternative the slice-6 amendment
  predicted would eventually be needed, and it is what lets the fetch beat stay unconfirmed.
- **A skill is a record plus a directory, and the acknowledgement says so.** A skill whose body
  could not be fetched has its record stripped on the receiver (a record without a body installs a
  broken skill), yet the acknowledgement reported only that the row apply succeeded — so the sender
  recorded the skill as peer-seen and deleted its own record and directory next session
  (reproduced). `SyncApplyAck` now carries `deferredSkills`, and those rows keep their entries and
  content baselines.
- **An `iSend` entry is built from the payload that was sent.** The advance re-read local state, so
  a message written while the session was in flight — a user send, or a generation appending a row
  — was recorded as peer-seen although it never crossed the wire; the next session planned
  `peerSends`, the incoming subtree lacked the row, and the deletion oracle removed it. The entry
  now describes the outgoing subtree read for the push.
- **A bulk replacement of the database is announced as an epoch.** A restore (or an overwrite
  import) drops rows that were never deleted, and every such absence read as a deletion: a peer
  holding the only copy of a conversation the restored device no longer had deleted it to match.
  Resetting the replaced device's own checkpoints is not enough — the peer's checkpoint still
  asserts a shared history — so the replacement also bumps a data epoch kept beside the
  checkpoints, the epoch rides the hello, and is recorded per peer. A peer that sees a different
  epoch converts its own deletions to re-sends for that session (recovering what was lost) while a
  deletion it made itself still stands, because that plans `peerDeletes` and travels through the
  announcement rather than through an absence. The row-level oracle is silenced for that session
  too. Hooks: the restore cutover, after the new database is installed and verified; an overwrite
  import. A *rollback* is not hooked — it returns to the exact state the checkpoints tracked — and
  an in-app "clear all data" is not either: that is a deletion intent, which propagates.
- **A stale entry heals on `none`.** The `none` arm kept the previous entry whenever one existed,
  so an entry an interrupted session left behind never refreshed; with a stale digest the next
  session read the peer's deletion as a local edit and re-uploaded the conversation, silently
  undoing the deletion once. `none` means both manifests agree, so local state *is* the shared
  state: the entry is refreshed from local (the business face already did this).
- **The push beat always runs.** It was skipped when this device had nothing outgoing, but it is
  also where the responder performs its blob pull — including the retries its checkpoint still
  owes — and where the value the fetch beat persists as `pendingBlobs` comes from. A session with
  an empty push wrote the empty default over that list, so a blob the responder still owed was
  never requested again. An empty batch costs one round trip; the pull is skipped when nothing is
  wanted.
- **Every request has a deadline, on both planes.** The only timeout in the plane was the
  three-second revoke. A paired peer that stopped answering left the initiator's `await` pending
  forever — `busyDeviceIds` stayed set and automatic rounds stopped for the life of the process —
  and any LAN host could wedge the *serial* request loop with a `/pair` body that announced a
  length and then stopped arriving, silencing pairing and sync alike until restart. Client
  budgets: hello 60 s, push/fetch 20 min, blob 15 min of inactivity, pairing 60 s. Server route
  budgets: pair and hello 60 s, revoke 30 s, the data routes 30 min as a backstop for a large push
  and the reverse pulls inside it. Both are injectable so the stalled-peer paths are testable
  without waiting one out.
- **One session per pair, in both roles.** The busy guard refused only a *different* device, a
  same-device hello replaced the live slot, and both roles write the same checkpoint file from the
  copy each read at its own hello. Both devices firing their launch round at once is routine, and
  the later write discarded the other's advance — which is what manufactures a stale entry. A
  per-peer initiator marker now sits beside the responder session map, taken before the first
  await (Dart's single isolate is the whole lock): an initiator round is refused while a session
  exists for that pair, and a hello from a peer this device is initiating to is refused as busy.
  Both sides may refuse a simultaneous round; the next trigger retries, and the ADR no longer
  claims a deterministic lower-deviceId winner that the code never had.
- **References are registered for every present file, not just this session's arrivals.** The
  registration replaces a revision's whole reference set, and a referenced file the receiver
  already held with the advertised hash was never fetched (`neededFileBlobs` skips it) — so its
  reference was deleted although the message still named it, leaving the file to the unreferenced
  asset GC. Advertised file blobs that needed no fetch are now part of the registered set, on both
  roles.
- **A skill directory's hash, its zip and its extraction share one dot-file policy.** All three
  walks skipped every dot-prefixed basename while the extractor installed every entry, so
  `.github/**` and `.gitignore` were invisible to the content clock: an edit touching only those
  names could never converge, and the zip the peer verified did not carry everything the hash
  counted. The skip existed to hide `.sync-blob-cache`, which lives beside the skills rather than
  inside a body; the walks now exclude exactly the sync plane's own `.sync-*` scratch names and the
  Finder/Explorer bookkeeping files.
- **`updateMessageFields` floors the clock too.** The slice-6 floor covered `_messageUpdate` but
  not the partial-column path the UI takes for translations and artifact writes, so an edit there
  could still lower a row's effective LWW clock below its own timestamp and let the peer's
  untouched copy win.

## Amendment (2026-09, slice 8): references follow the apply, and the row state the plan never read

A third adversarial review found eleven defects. Two are the same mistake in different places — a
rule applied to the wrong set — one corrects a claim this document itself made, and two are
reachable only through a narrower window than the review described; the corrections are recorded
below as measured, not as reported.

- **Asset references are registered for the revisions the apply wrote.** The registration replaced
  a revision's whole reference set from the wire parts of every incoming subtree. A revision the
  merge *kept* (the local copy won LWW) was therefore described by the parts it beat: the winner's
  own attachment was unlinked and its file left to the seven-day asset GC, while a revision that
  never landed (a deferred conversation, a resolved version-group loser) dangled against the
  revision foreign key — `INSERT OR IGNORE` does not cover foreign keys — and aborted the session
  between the committed apply and the checkpoint, repeating every session. Registration is now
  scoped to the outcome's written revisions, and keyed off the peer's advertised manifest rather
  than off what the pull landed, so a blob whose fetch failed is already referenced when a later
  session's retry lands it.
- **A conversation-row-only change is visible to the plan.** The conversation digest covers message
  rows only, so a rename, a pin, a version selection or an extras edit moved nothing the planner
  compared: the plan said `none`, the checkpoint was re-recorded from local, and the change could
  never transfer in any later session either. The conversation row's own clock now decides the
  agreement case — equal digests with different clocks is `bothSend`, which the apply's row-level
  LWW settles. Business rows pass no clocks: their digest already covers the whole row.
- **A peer-supplied path is only served from a managed root.** A file entry in the peer's manifest
  was remembered by whatever path it carried; the resolver returns an existing absolute path
  unchanged, and the serving path re-checked nothing, so a paired peer could name any readable local
  file and fetch it back by a hash it chose. The published map now applies the same allowlist every
  other consumer of a wire key already did (registration applies it too, which also closes the
  registry fallback), making the route's own comment true again.
- **An entity's list position is part of its digest.** A drag rewrites every row's `sort_order` and
  clock while leaving its payload untouched, so a payload-only digest compared equal and each device
  stayed on its own order — the claim that the order "travels with the row" did not hold. The entity
  digest now covers the position; preferences, which have none, keep the payload digest. Accepted
  consequence: the formula change makes the first session after the upgrade exchange every entity
  once, then settle. A reorder is a row write, so it still beats an older content edit under LWW —
  that is the doctrine, not a defect.
- **A wire message row must be this conversation's, and not another conversation's already.** A
  message id is a global primary key and the apply's upsert conflicts on it, so a crafted subtree
  could carry another conversation's id and move that message into itself, or label a row as a
  different conversation and insert it there. An honest peer produces neither (its own reader filters
  by conversation), and the analogous asset path already refused the same shape. Both are dropped
  before the merge, and non-string ids and revision ids are skipped rather than thrown on.
- **A failed session reports a reason, not an exception.** A transport failure was persisted as the
  engine's machine summary and rendered verbatim on the card and in the snackbar — the peer's
  address and port in a sentence no localizer could touch, surviving restarts in the record. Failures
  now carry a structured reason (unreachable, timeout, peer error, internal) classified at the catch,
  with the exception text going to the log only; `no_endpoint` is unreachable; the panel and the
  record render the reason, and the key that took rendered text is gone.
- **A settled conversation is not rebuilt every session.** The `none` arm refreshed every settled
  conversation from local — a full message-row read, a hash and a share of the checkpoint rewrite,
  for the whole library, on every launch, resume and manual round. The manifest already carries the
  digest and row clock that refresh would read, and both come from the same rows, so an entry that
  equals them cannot change; an entry that disagrees is still rebuilt, which is exactly the heal
  slice 7 introduced.
- **Pairing names the field that is wrong.** An empty address or an unparsable port reported "wrong
  pairing code": the user was sent to re-check the other device while the field that needed fixing
  was never named. Validation is now one pure helper that reports the address/port and the code
  separately, and the code is compared with its spaces stripped — the dialog shows it as `123 456`,
  so the space a user copies is not a wrong code.
- **`zh_Hans` says it in Simplified characters.** The listener string carried Traditional characters
  and rendered as such in the panel.
- **A skill with no carried files still has a body.** A directory whose carried set is empty (a lone
  `.DS_Store`, or every name excluded by the policy) hashes to the empty body, and that hash
  travelled in the manifest — but the zip writer refused to produce it and the importer refused to
  unpack an empty archive, so the fetch 404ed every session and the record stayed deferred forever.
  The empty body is now first-class: the writer emits the zero-entry zip, and the apply path
  recognises the hash, skips the importer that rejects it, and lets the re-hash verify the empty
  directory it swaps in. The import flow's own refusal of empty archives is untouched.

Reachability, measured rather than assumed: the losing side's parts do **not** reach the winner on a
first-sync `bothSend` (the push beat aligns them before the fetch beat reads its subtree), so the
reachable trigger for the reference defect is a local write landing between the payload's blob pull
and the merge — that is the window the regression test models; the version-group-loser variant of
the dangling-reference abort is likewise unreachable, while a deferred (streaming) conversation is
not; and the crafted-row defect is reachable as a re-home and as a cross-conversation insert, not as
the unique-slot collision the review also described, because the order re-derivation compacts slots
before writing.

## Amendment (2026-09, slice 9): advertised candidates, a remembered endpoint set, the rebuilt window

Three defects from field use of 4.0, none of them in the merge: a device that advertised no
address at all, a peer record that could hold only one address, and an open conversation that
kept showing pre-sync content.

- **The candidate filter excluded the addresses that work.** The list was restricted to RFC1918 —
  the reasoning was that a human types it. A campus network that hands out globally routable IPv4
  directly then had nothing left to advertise: no endpoint in the QR, "no LAN address" in the
  panel, while a peer on the same segment could reach it. The rule is now every unicast IPv4, with
  loopback, link-local, multicast and the reserved blocks dropped (the enumeration excludes
  loopback and link-local itself).
- **The same filter kept the addresses that do not work.** Virtual adapters live in the private
  ranges, so VMware's host-only network was advertised — and two machines running the same
  hypervisor carry the same default clone subnet, so a joiner trying that candidate reaches
  *itself* and fails the pin. Interfaces are now filtered by name (stems `vmware`, `virtualbox`,
  `vethernet`, `docker`, `wsl`, the tunnel and VPN families, and `rmnet`/`clat`/`pdp_ip` on
  phones): excluded rather than demoted, because a demoted candidate keeps that failure reachable.
  Names a tethered peer must dial are deliberately kept — `bridge*` (an iPhone's personal
  hotspot), Windows' "Local Area Connection* N" (the mobile hotspot adapter) and `swlan*` (Android
  soft AP) — and the advertised list is capped at four addresses so the QR stays scannable.
- **An address is a (device, network) fact, not a device fact.** The peer record stored one
  `lastHost`/`lastPort`, so every move between home, office and a phone hotspot became a re-scan.
  It now holds up to six endpoints, best first: a session promotes the endpoint that answered and
  keeps the rest behind it as hints, which is what makes roaming back to a known network heal in
  one round. Only "could not be reached at all" falls through to the next candidate — a refusal is
  the peer's verdict on *all* of its addresses — and a handshake mismatch counts as unreachable,
  because the pin refuses inside the handshake before any request byte. That is what makes trying
  the next address free.
- **Both sides start with a set.** Pairing keeps the QR's other candidates as hints, and the joiner
  advertises its own addresses in the pair request (`candidateHosts`, additive: a 4.0 peer ignores
  the field, so no protocol bump) so the responder remembers more than the single address the
  pairing arrived from. Manual repair replaces the whole set — the automatic memory is what failed,
  or the user would not be typing.
- **4.0 records are upgraded on read.** The stored pair becomes a one-element set seeded with
  `lastSyncedAt`, and the next save writes the new shape. The peer store is plain JSON per peer, so
  there is no database migration; letting every paired device re-pair on update was not an
  acceptable cost for a feature whose whole point is durable pairing.
- **An open conversation is rebuilt, not left behind.** The apply already reloaded the caches, but
  the controller's only reaction to that notification was "does the conversation still exist?", so
  a conversation the peer had just written into kept showing pre-sync content until the user left
  it and came back — the take-the-phone-and-keep-chatting journey ended on a stale screen. The
  apply now names the conversations it changed, and the controller compares a per-conversation
  external-write counter against the one its window was built from: it rebuilds the window
  (tail-following at the bottom, anchored on the first loaded row above it) and refreshes the row
  the page renders outside the window. A write that lands while a local generation owns the window
  is held back and applied when the stream releases it; every other notification costs one integer
  comparison. *Rejected: a targeted partial cache reload* — the shared persisted caches are the
  trap it opens, and the full reload is what the apply has always run, so the counter alone buys
  the user-visible fix. *Rejected: live-reloading open editor pages* — a form rewritten under the
  user's hands is worse than a snapshot, and the row-level LWW rule plus the report's lost-row
  counter already covers the outcome.

## Amendment (2026-09, slice 10): candidates are probed first, and one address is not the pairing

Slice 9 made a peer record hold every address a peer was known at. That turned a single dial into a
sequence of dials, and the sequence inherited two rules that only made sense for one address: a
failed attempt cost a full dial budget, and an answer that was not the peer stopped everything.

- **Candidates are probed in parallel, then dialed in order.** Every candidate is first reached with
  a bare TCP connect, all at once, under a two-second budget; the addresses that answered are dialed
  in sequence under a three-second connect budget (ten seconds before — a LAN host answers a SYN in
  milliseconds, so the only thing ten seconds bought was a slower failure). The cost of unreachable
  addresses becomes the maximum instead of the sum: a peer remembered at six addresses across three
  networks used to cost up to a minute of a background round before the live one was tried. A probe
  loser is appended rather than dropped — a probe is one SYN, and losing one is not evidence that the
  serial dial could not reach the address — and a single candidate skips the probe entirely, where
  the dial already is one. The probe classifies the address only: identity is still the certificate
  pin, checked at dial time. *Rejected: full RFC 8305 racing* — the pairing PIN is one-shot, so two
  concurrent `/pair` requests would race for one window instead of one of them simply being tried
  second, and with at most six candidates the serial TLS leg costs nothing worth that.
- **The remembered order is a history of networks; the subnet says where this device is.** Given
  equal reachability, candidates sharing an IPv4 /24 with one of this device's own addresses are
  dialed first. A laptop arriving home still has the office address at the head of its set from last
  night, and that head is exactly what the round needs to skip. The preference is applied *inside*
  each of the probe's two groups, so topology can never promote an address that did not answer above
  one that did.
- **An address that answers with the wrong certificate no longer ends a pairing.** Slice 4's rule
  ("an endpoint that answers wrongly stops the attempt, because the same answer awaits on every
  candidate") conflated two different verdicts. A refused PIN or an identity mismatch *is* the
  scanned device answering, and it would answer the same way on every address it holds — still
  terminal. A failed handshake is not an answer from the device at all: the pin refused that address
  before any request byte left, which is what the slice-4 security argument already rested on. Such
  an address is now disqualified and the loop continues, so a QR whose first address is a recycled
  lease or a machine that happens to answer on the sync port still pairs on the address behind it.
  When *every* address answered as something else, that is the reported failure
  (`fingerprint_mismatch`): no retry helps, a fresh code does. *Rejected: reporting the mismatch as
  unreachable* — "nothing answered" and "something answered and it was not your peer" need different
  repairs.
- **The address list is re-enumerated, not remembered from startup.** It used to be computed once
  per launch, so a device that changed networks kept advertising the one it had left: a QR pointing
  at a dead address, and a dial ordered by a network the device was no longer on. It is now refreshed
  when the app resumes and when the pairing dialog opens — on a desktop, changing networks fires no
  lifecycle event at all — and the same list is pushed into the engine so the screen and the dial
  cannot disagree. The QR follows it too: the image was encoded once at open while the list beside it
  was read live, so the two could show different networks. It is re-encoded when, and only when, its
  endpoints changed, which keeps the once-a-second countdown tick from rebuilding it.

## Amendment (2026-09, slice 11): the dual stack

Slice 9 fixed what a device *advertises*; this one fixes what it *listens on and stores*. Both were
IPv4-shaped, so a network that hands out IPv6 only — and every peer reaching this device over IPv6 —
had nothing to pair with.

- **One listener, both stacks.** `HttpServer.bindSecure` now binds the IPv6 any-address. Measured on
  Windows: a listener on `::` answers `127.0.0.1`, and the caller arrives as `::ffff:127.0.0.1`; and
  `::` is a genuinely exclusive wildcard — it refuses to bind while another socket holds `0.0.0.0` on
  that port, and the reverse fails too, so there is no window in which two listeners both serve it. A
  machine with IPv6 disabled falls back to the IPv4 wildcard, which is exactly what the listener was
  before: no bind that *fails* ends up worse off than 4.0. (A host whose `bindv6only=1` does not fail
  the bind — see the known limits below, and the slice 13 correction.)
  *Rejected: a second listener per family* — it would need its own port, its own firewall rule and its
  own peer memory for a socket flag the platform already provides.
- **Storage is bare, everything that faces a URI or a human is bracketed.** The mapped form a
  dual-stack listener reports for an IPv4 caller is a valid address to a socket but not to
  `Uri.parse` and not to a person: stored as-is, every IPv4 peer would live under two names and the
  stored one could not be dialed back. `normalizeHost` (strip brackets, reduce a mapped literal to
  IPv4), `uriHost` and `formatHostPort` are the entire boundary, and the storage layer, the dial, the
  QR payload, the peer label and the typed address all route through them. The QR wire format is
  unchanged for IPv4 — a payload from a 4.0 peer round-trips identically — and the payload's
  last-colon split needs no change for IPv6 because the literal travels bracketed.
- **Both families are advertised, under one cap.** Kept: global unicast (`2000::/3`) and unique local
  (`fd00::/8`) — the two ranges an interface actually holds and a peer on the same network reaches.
  Dropped: link-local (`fe80::/10`, whose zone id is a property of *this* device's interface and
  means nothing to a peer), multicast, the unspecified address, the reserved `fc00::/8` half, and the
  IPv4-mapped and IPv4-compatible forms, which are an IPv4 address wearing an IPv6 shape and are
  enumerated as IPv4 instead. The four-address cap counts both families together: a machine with an
  address of each keeps the four its interfaces reported first. *Rejected: a per-family quota* — a
  typical machine holds one or two global addresses per family, so a quota would add a selection rule
  to defend against a shape that does not occur, and the probe layer already handles any mix.
- **The pairing QR was resized for the payload it now carries.** Four IPv4 endpoints already encoded
  to ~280 characters — version 12 at error correction M, under 2.8 px per module in the 180 px square
  — while an IPv6 endpoint is ~45 characters where an IPv4 one is 19, which would have crossed into
  version 14 and ~2.4 px per module. The square is now 220 px and the correction level L, putting the
  worst case (four IPv6 endpoints, ~380 characters) at version 13 and ~3.2 px per module: better than
  what shipped for IPv4 alone. *Rejected: keeping M at 220 px* — the same worst case lands on version
  15 and ~2.9 px, and at these payload sizes a version step costs more scannability than the extra
  correction buys for a code read at close range off a clean screen.
- **Known limits, recorded rather than papered over.** A Linux host with `bindv6only=1` binds `::`
  successfully but serves only IPv6, so an IPv4 peer's dial to that port cannot land; the fallback
  above covers only a bind that *fails*, and the sysctl is not visible from the socket, so the
  listener cannot detect this and correct itself. Windows privacy extensions rotate temporary
  IPv6 addresses, so an advertised v6 endpoint can go stale — the probe, the endpoint set and the
  promotion-on-success rule already treat a stale address as an ordinary drift to heal. And an older
  build reading a peer record that holds an IPv6 endpoint cannot dial it, which is the same
  downgrade position as slice 9: unsupported, not worked around.
- **The tests are sensitive to a running app.** The suite's providers prefer port 9527; when the
  installed app is running, that port is taken, so every provider falls back to an ephemeral port —
  which has no firewall rule, which is the branch that notifies. That surfaced a pre-existing defect
  (a notification after `dispose`, reported as an unhandled async error against an unrelated test),
  now guarded by a `_disposed` flag the provider's notification helper checks.

## Amendment (2026-09, slice 12): the panel says what to do about it

The session layer was already honest about *why* something failed; the panel was not. This slice
closes the gap between what the engine knows and what the card says.

- **A peer with no address is not an unreachable peer.** The engine recorded "this record remembers
  nowhere to dial" as `unreachable` — the value a peer that *was* dialed and never answered also gets
  — so both rendered one sentence, and each one's repair was wrong for the other: turning the other
  device on does nothing for a record with no address at all. `noEndpoint` is its own reason (wire
  `no_endpoint`), with a line that asks for an address. *Rejected: carrying the engine's `summary`
  string on the stored report* — the summary is machine text built for logs, while the reason is the
  value the panel localizes, and the enum's unknown-value fallback is exactly what makes adding one
  safe: a value the enum cannot parse renders the generic line rather than nothing, and a record
  written before this one still holds `unreachable`, which is a reason it can still read.
- **The failure line names the repair.** The unreachable line stated the fact and stopped, while the
  code already knew the remedy — a peer that moved is healed by re-scanning its QR or by typing the
  address on its card (this is the drift rule below, in slice 9) — so the line now names both.
  *Rejected: a separate guidance line on the card* — "a failure is a reason, not a sentence" is the
  panel's rule, and a second line would have to be wired into two renderers (the card and the
  snackbar) to stay in step.
- **A pairing typed by hand is announced like every other one.** The manual form closed in silence,
  so the one success the user triggered entirely by hand was the only unreported one. The name does
  not have to be assembled from the form: the engine returns the record it wrote and the provider was
  discarding it, so the outcome now carries that record's name and id and every path announces the
  name the card will show. Known-ness is read from the peer list *before* the call, so re-pairing an
  already-paired device still reads as an update rather than as a first pairing.
- **The card's time line answers "is this current?"** How long ago, not a timestamp: a date makes the
  reader subtract, and the question on that line is recency. Past a week the stamp returns — at nine
  days old the date *is* the more useful fact — the exact time rides in the tooltip, and a stamp in
  the future (a peer whose clock ran ahead, or a clock that moved backwards) reads as just synced
  rather than as a countdown on a line about the past. The units are ARB strings: `intl` dropped
  `RelativeDateTimeFormatter` in 0.20, so the alternative was a dependency or a formatter that does
  not exist — and this keeps the wording in the app's own four translations. *Rejected: keeping the
  absolute timestamp as the line itself* — it is already in the tooltip, so the line would spend its
  width on the less useful half.
- **The remembered set is counted, and the address copies.** A peer this device has reached on two
  networks showed only the address in use, which is indistinguishable from a peer with one address;
  the count now rides with it ("(+2)"). The address itself copies on tap, with the confirmation every
  other copy in the app gives: it is the one string on this card that belongs somewhere else — typed
  into another device, or read out to whoever is on the other end of the call.
- **A widget test does not join the shared side list.** The pairing-dialog and peer-card tests drive
  a stub provider over a side that runs no engine; adding such a side to a suite's shared `sides`
  list made the shared teardown dispose an uninitialised engine, and a teardown that throws never
  clears the list — so every later test in the file re-disposed the leak. Sixty tests failed that
  way, none of them about the change under test. Such a side cleans up after itself instead.

## Amendment (2026-09, slice 13): review hardening — the walk keeps walking

A review of slices 9–12 traced three long chains (apply → controller rebuild, enumeration → QR →
stored endpoint, listener/notify paths) and found five defects in them. Four are the same shape:
the documented rule was right and the code had a hole in it. Each fix below therefore moves code
to match language this file and `CONTEXT.md` already carried, and every behavioural fix has a test
that was red before it went in.

- **A refused certificate is a verdict on the address, not on the session.** `_syncWithPeerAt`
  documented that a `HandshakeException` is a null "so the next candidate is still a fair attempt",
  and `CONTEXT.md` says an endpoint answering with the wrong certificate falls through — but the
  handlers caught `SocketException` and `TimeoutException` only, while a `HandshakeException`
  implements `TlsException`, **not** `SocketException`. The refusal escaped to the catch-all, which
  returns a *non-null* report: the walk ended there with the peer never dialed although it was live
  at the address right behind the stranger, and the session was recorded as `unreachable`. A
  `TlsException` is now caught beside the socket case. *Rejected: a new `SyncFailureReason` for
  "every address answered as another device"* — the `unreachable` line already names the repairs
  that fit it (re-scan the QR, or edit the address), so a fifth value would buy wording rather than
  an action, and the enum's unknown-value fallback makes the existing one safe to keep.
- **The address that refused the peer is not promoted as one that worked.** The same path reached
  `_finish` with its host and port and was stamped by `noteEndpointSuccess`, so the foreign address
  became the head of the remembered set — and the string the card showed — ahead of the address the
  last successful session ran over. Fixing the exception class removes the harmful case at its
  source: what still reaches `_finish` either succeeded, was refused *by the peer* (a refusal proves
  the address reaches it), or failed after a pin-verified hello.
- **Probe winners keep their input order.** `orderCandidates` promised that and appended from the
  probe's completion callback, so the order was a race: the same set of addresses could be dialed
  in a different order on consecutive rounds, and that order is what the pairing record stores as
  hints behind the winner. The injected-connect tests could not see it — an immediately-completing
  fake finishes in the order it was started. Winners and losers are now rebuilt in input order,
  with a test that gates the probes on completers and finishes them out of order.
- **A foreground round waits for the addresses it stands on.** The enumeration and the round were
  both fired unawaited with nothing sequencing them, so the first round after a launch could compute
  its dial order from an empty list — where `_preferSameSubnet` returns its input untouched,
  dropping the nearest-subnet rule the probing exists for. The resume path had the identical pair,
  under a comment claiming the ordering. Both call sites now go through one sequenced helper, and
  the entering side of pairing re-enumerates too, because the addresses it advertises are the
  candidates the peer will remember. *Rejected: refreshing inside `autoSyncRound`* — the pairing
  surface needs the list whether or not a round runs, so the two calls stay distinct and only their
  order is fixed.
- **A reorder-only apply is a change.** The repository repairs a stored order that disagrees with
  the re-derived one and reports `upsertedMessages: 0, deletedMessages: 0,
  conversationRowChanged: false` — correctly, no row's content changed — while the data plane admits
  a conversation to the reload set on those counters alone. The order was therefore corrected with
  no revision bump, no notification and no rebuild, and a window open on that conversation kept
  rendering the pre-sync order until the user left it and came back. The drift is now its own fact
  (`SyncSubtreeApplyOutcome.reordered`) instead of a hidden part of the reorder decision, and it
  admits the conversation to the same reload. *Rejected: counting the repair in
  `conversationRowChanged`* — that field means the conversation row was written, and overloading it
  would make the report lie about a different write.
- **A dialog owns the controllers its fields use.** Found by the repair-dialog test rather than by
  the review: the card's address and rename dialogs created their controllers as locals and
  disposed them right after `await showDialog(...)`, which completes when the route *pops*, not when
  it is gone. The still-mounted field rebuilt against a disposed controller during the exit
  animation — "A TextEditingController was used after being disposed", with a 99679 px `RenderFlex`
  overflow as the cascade — and it was timing-dependent, which is why it survived until a test
  submitted the form. Both dialogs are stateful now, so the state that owns a controller disposes
  it, as every other dialog in this feature already did.
- **The repair field stores the host form pairing stores.** `CONTEXT.md` already said an endpoint is
  stored bare and bracketed only where a human or a URI reads it; the repair field was the one
  exception, so pasting back the address the card had just copied (bracketed, as its label shows it)
  stored `[fd00::9]`, and the next dial would have bracketed it a second time inside the request
  URI. The field now normalizes like the pairing form.
- **Three untrue claims, corrected.** The local-address header said the enumeration is IPv4-only
  while it deliberately asks for both families; the `_octetPattern` doc said a padded octet is
  rejected while the pattern accepted it (the existing `10.x` vs `010.x` cases pass either way,
  because the two prefixes differ as text — two *padded* forms still matched each other); and the
  listener comment, `CONTEXT.md` and slice 11's own fallback paragraph said a `bindv6only=1` host
  "falls back to IPv4", when such a host accepts the `::` bind and serves IPv6 only — a claim slice
  11's *known limits* bullet thirty lines below already contradicted. All four statements are
  corrected in place, and the mapped-IPv6 branch in `_isUsableIpv6` was dead as well — its condition
  requires a zero first byte, which both keeps already reject — so it is gone. *Rejected: a
  self-connect probe to detect `bindv6only=1`* — it would add an untestable branch (no such sysctl on
  the machines the suite runs on) and startup traffic, for a host configuration none of this app's
  platforms defaults to; the limit is written down instead.

Verification: the fixes' red proofs are the pre-fix runs recorded in each commit body; the full
suite reports the same 77 known failures as this branch's baseline, with none added.

## Amendment (2026-09, slice 14): the panel says what is true about a peer, and a first sync shows its work

The panel's wording was written for a feature that ran rarely and finished quickly: one
"Sync failed" line for every non-success, one " · "-joined counter line for success, a spinner with
no beat behind it, and a "last synced" stamp that moved on failures. Field reports all said the same
thing — alarmist where the situation was ordinary (a peer asleep), silent where the wait was long
(the first sync), and forgetful about what the user had set (a renamed peer). This is the UI-facing
half of the fix; three facts below it are what make it possible.

- **A rename is *this device's* fact, so it has its own field.** The record kept one `name` and
  pairing rebuilt the whole record, so a re-pair silently reset a name the user had typed — and a
  re-pair is the drift-repair journey, which this feature expects users to perform whenever an
  address changes. `customName` now holds the override (absent means none; a blank string is not an
  override, so an empty rename dialog cannot blank a card), the card renders `displayName`, and a
  re-pair carries the override, the last-sync stamp and the last report across from the record it
  replaces. *Rejected: inferring a rename by comparing the stored name with the hello's* — the two
  are equal whenever the user retyped what the peer already called itself, so the heuristic is
  silently wrong in exactly the case it exists for.
- **A re-pair does not reset the checkpoint, and it no longer looks like it does.** The checkpoint
  file is keyed by `deviceId`, which pairing never changes, so the drift-repair journey always
  re-used it; what a re-pair *did* reset was the record's own stamp and report, which the panel
  renders as "never synced". Carrying them over is what makes "pair again" read as the repair it is.
- **"Last synced" means the last *successful* session.** `_finish` stamped `lastSyncedAt` for every
  outcome, so a peer that was switched off made the line claim the data was current — the one moment
  it must not. `lastReport` still changes on failures and refusals, which is what the outcome area
  beside it renders.
- **Reachability is probed, so the card can say "offline" instead of "sync failed".**
  `anyEndpointReachable` reuses the dial's own bare-TCP probe over the remembered endpoints — the
  same probe, budget and "the probe classifies the address, never the peer" contract as the
  candidate ordering — and the provider re-runs it on start, on resume, on a 30-second timer while
  the app is visible, and after every session; a session in flight counts as its own proof.
  *Superseded in part by slice 15*: only a session **past its dial** is proof — a round that
  has merely started proves nothing, and the optimistic green it painted was exactly the
  flicker an automatic round showed against a sleeping peer. The card
  draws it as a green/gray dot on the platform badge, and an `unreachable` outcome renders as a calm
  "not reachable right now" note rather than a failure banner: a peer that is asleep is routine, and
  it syncs again by itself when both devices are back on one network. The durable-socket gap (the
  probe cannot tell "asleep" from "moved to an unknown network") is accepted — the actionable repair
  still reaches the user through the manual sync's toast, which keeps the rescan/edit-address
  wording. *Rejected: a persistent discovery protocol* — out of scope since slice 4 deferred it, and
  a probe answers the only question a dot asks: does an address this pair already knows answer now?
- **A running session publishes its beat.** The engine records `SyncSessionProgress` (connecting,
  exchanging, sending, receiving, files with a done/total count, applying) and clears it when the
  session ends; the card names the beat where the sync button was. That is the difference between a
  first sync that looks hung and one that is visibly working, and the file beat is the one that can
  take minutes.
- **Pairing starts the first session itself.** Pairing has just proved the peer reachable with both
  apps open — the exact window a first (whole-history) sync needs, and one a mobile OS closes the
  moment the app leaves the foreground. `pairWith`/`pairWithQr` therefore kick the session and
  return; the card shows the beats and, on a never-synced peer, the keep-both-devices-awake note.
  Both pairing dialogs carry the same advisory, because that is the only moment the user is holding
  both devices. A round that lands while that session runs is skipped as busy, by the existing
  single-flight rule. *Rejected: waiting for the next foreground round* — the round is throttled by
  a minute and the phone is usually pocketed by then.
- **The success line is a card, not a string.** Counters render as icon chips (sent, received,
  messages, entities, preferences, files with their size, skills) and the sentence-shaped warnings —
  skill edits replaced, local rows replaced, files missing on the other device, deferred items,
  clock skew — get a row each; a session that moved nothing reads "up to date" instead of "0 sent ·
  0 received". The engine's machine `summary` stays for the logs, and the one-line form survives
  only for the snackbar, which has room for one line. The "up to date" chip is additionally gated on
  nothing being withheld: a session that deferred a conversation, or that never received a blob the
  peer holds, is not current — the sentence row below says which item is owed, so the chip does not
  claim otherwise over it. (Skill conflicts, replaced rows and clock skew do not gate it: they are
  not data this device is missing.)
- **The window rebuild is triggered by "the peer sent this conversation", not by "a counter moved".**
  Applying a subtree told an open chat window to rebuild only when one of four counters was non-zero
  (upserted/deleted messages, a changed conversation row, a repaired order), and the fourth of those
  existed precisely because counters cannot express every change: a written asset reference — the
  retry that lands a file's bytes in a later session — makes an attachment start resolving while the
  row it hangs off never moves, so the window kept showing the pre-sync state until the user switched
  conversations and back. A rule that has to grow a flag per newly discovered silent write is a rule
  that will be wrong again, so the apply now publishes every non-deferred conversation the peer sent,
  and the asset-reference registration publishes its own conversations. The cost is one window
  rebuild per arrived conversation per session (only for the conversation that is actually open); the
  counters stay exactly as they are for the report. The one case this still does not cover is bytes
  landing in a session that carries no subtree for the conversation — the reference is registered
  before the bytes arrive, so that attachment appears on the next session or on re-entry.
- **The dot's evidence is layered, and a session outranks a probe.** A bare TCP connect and a
  session are not the same measurement: an address behind a NAT port-forward (or any listener that
  is not this peer) can accept a connection and never complete the TLS handshake a session needs,
  so a probe-only dot stayed green while every session failed. The probe keeps its cheap
  address-level contract, but a finished session now files a verdict — answered (success, any
  refusal, or a failure that needed an answer to happen) or silent (`unreachable`, `timeout`) —
  which outranks the probe for `sessionVerdictTtl` (one minute, so the verdict cannot outlive the
  peer's actual state). The probe itself gained jitter tolerance: one miss is remembered, two in a
  row clear the dot, because a green dot that flickers gray every half minute is worse than one
  that is half a minute stale. The card's tooltip says which evidence it is reporting. Two edges are
  known and accepted. `internal` is the catch-all failure reason, so a failure that never left this
  device — a manifest build against a broken database, a certificate context that will not open —
  files "answered" for up to the verdict's TTL; separating it from the 401 refusal that shares the
  reason would need a "did a request leave this device" signal the engine does not publish, and the
  probe corrects the dot within the minute. And a session that dials nothing (`noEndpoint`) files no
  verdict, because the probe is the only evidence it could file — but the session marks its peer
  online on the way in, so that mark is removed again on the way out: with no endpoint there is no
  probe to correct it. *Superseded by slice 15*: the optimistic mark on the way in is gone
  altogether, so a no-endpoint session has nothing to undo and files nothing.
  *Rejected: upgrading the probe to a pinned TLS handshake* — it would overturn the documented
  "a probe tests the *address*, never the peer" contract, make the 30-second probe carry crypto and
  a new failure surface (self-signed certificates, IPv6 literals), and still be a weaker statement
  than the session verdict that is now in the model for free. *Overturned by slice 19*: the probe is
  now exactly that pinned, authenticated request, because "reachable" without "still paired" turned
  out to be the wrong question — the crypto cost is bounded by asking the tiered tick about two
  addresses rather than all of them, and the session verdict still outranks a probe answer as the
  dot's stated source.
- **The dial beat names its address, and "comparing data" may only appear after the hello.** The
  connecting phase was published once, before the candidate walk, and the exchanging phase was set
  *before* the hello call — so "dial → handshake → hello in flight" (up to the 3-second connect
  timeout plus the 60-second hello deadline, per candidate) was displayed to the user as "comparing
  data", which is what made a hanging dial look like a hung comparison with nothing to act on.
  `connecting` now carries the endpoint and the candidate's rank (`正在连接 13.173.213.34:9527…（2/3）`),
  and `exchanging` is published only once both manifests are in hand. A candidate that will never
  answer is now visibly *the* thing taking the time, and it is bounded: each candidate ends in
  `unreachable`, which the session verdict turns into a gray dot. Two things about that label came
  back from review. It lives in **its own row**, not beside the peer's name: an address plus a rank is
  wider than the space left in the header row, and a `Row` measures a non-flexible child at its
  intrinsic width before the flexible children, so the label took the whole line and left the name at
  zero width — a phone-width card lost the device name for the entire dial. And the beats are
  published on **their own notification channel** (`onProgressChanged`): the panel reloads every peer
  record when engine state changes, while the file counter advances once per pulled blob, so a first
  sync of a history with images re-listed and re-decoded the whole peers directory once per file. A
  beat cannot have changed a record; the session's end still notifies the record channel once.
  *Partly superseded by slice 20*: the label no longer carries a rank — the probe ranks every
  candidate in parallel and the dial only walks the addresses that probe reached — while the
  address itself, its own row and the separate notification channel all stand.
- **A peer dial is always DIRECT.** Dart's `HttpClient` defaults to
  `findProxyFromEnvironment`, so a proxy exported in the environment (the Clash/v2ray-style
  `HTTP_PROXY`/`ALL_PROXY` that desktop users and every developer with a VPN client run) captured every
  dial to a peer whose address was not in the environment's `NO_PROXY` — and that list covers private
  ranges only, while the addresses a pairing actually remembers are whatever the network handed out: a
  NAT'd public address, or an IPv6 one. Both clients (pairing and session) are now built through one
  factory that sets `findProxy = DIRECT`. The symptom that found this is worth keeping: the *probe*
  behind the online dot is a bare `Socket.connect` and never consulted the proxy, so the card showed a
  green dot next to sessions that could never connect — a reminder that when two measurements disagree,
  the cheaper one is the one that is wrong. The guard needed a second fix of its own: it asserted
  arrival at a loopback alias while relying on the *ambient* environment to carry a proxy, and an
  environment with none makes `findProxyFromEnvironment` answer DIRECT for every address — so on CI it
  passed whether or not the rule was there. It now installs the environment it needs (`HttpOverrides`
  handing back a client whose `findProxy` consults `findProxyFromEnvironment` with a proxy pointed at a
  dead port), asserts first that the control case — a client built without the rule — cannot reach the
  listener, and only then that the factory does. A guard whose premise is the machine it runs on is
  not a guard.
- **A `not_paired` refusal comes with the repair gesture.** The refusal is the client's reading of a
  401: the peer's auth gate refused this device's secret, which means the pairing is gone *there* —
  unpaired on the other device, reset there, or a re-pairing that only one side finished (the
  responder rotates the secret the moment its `/pair` handler runs, so a lost answer leaves the
  initiator holding the old one). Nothing this device can do on its own repairs it, so the card's
  refusal banner now carries a "pair again" button that opens the pairing dialog prefilled with the
  address the card already knows (the code still comes from the other device's screen).

## Amendment (2026-10, slice 15): the dot reports answers, not attempts

Field use of the online dot found it lying in the most routine case there is: an automatic
round against a sleeping peer turned the dot green the moment the round started —
`syncNow` marked the peer online on its way in, and the presence round answered `true` for
any busy peer ("a session in flight counts as its own proof") — so every launch and resume
showed a green dot for exactly the seconds the dial then spent failing, then gray again.
Trying to reach a peer is not reaching it.

- **Three kinds of evidence, and an attempt is none of them.** The dot may say online from
  a probe that reached a remembered endpoint, a finished session that got an answer (a
  refusal included — that has not changed), or a running session **past its dial**: any
  beat from `exchanging` on means both hello manifests are in hand, i.e. the peer
  demonstrably answered while the session is still running. That last source is what keeps
  a minutes-long first sync green while it actually runs — the honest half of the rule the
  optimistic mark was reaching for.
- **A busy peer is neither probed nor assumed.** The presence round skips peers with a
  session in flight and leaves their current evidence untouched (they still count as known,
  so unpairing cannot leave a stale dot); the session's own verdict settles the dot when it
  lands. Previously the round answered `true` for a busy peer outright, which is the same
  conflation from the probe's side.
- *Rejected: keeping the optimistic mark for manual syncs only.* The button already shows
  the session's beats, a manual dial against an offline peer is the same lie, and the
  verdict lands seconds later anyway — "who started it" is not evidence either.

## Amendment (2026-10, slice 16): a quiet round that brings data says so

Slice 4's cadence made every automatic round silent — right when the feature was new and a
toast per resume would have been noise, but field use found the other failure: a phone
picked up at the office receives the whole day's messages and says nothing, so the user
cannot tell sync happened without walking to the settings page.

- **Arrivals are announced, attempts are not.** A session that *brought data to
  this device* (received conversations, applied message edits or deletions, business rows,
  blobs, skills) emits one arrival event; a root-mounted announcer turns it into a toast —
  "Synced with <peer>", five seconds, one "Details" action opening the card's own report
  breakdown in a dialog over the root navigator. A session that moved nothing, or only sent
  (the peer got the news), announces nothing; failures and refusals never announce — a
  sleeping peer is routine, and the card already carries the outcome. The gate is one pure
  predicate on the report, so the "what counts as an arrival" rule is testable without a
  toast.
- **Both halves of a session can be the arrival.** `syncWithPeer` announced only the rounds
  this device starts; the round a *peer* starts lands here through the responder path, which
  this device never chose and never sees — and that is the direction field use actually
  exercises (the phone picked up at the office pushes its day to the desktop; the desktop,
  sitting in the foreground, starts nothing). The engine hands the responder's own report to
  the provider when the answered session ends, under the same gates — data arrived here, no
  panel mounted — so a device hears about every arrival, whichever side ran the session. The
  "manual sync is not announced" rule is per-device: unannounced on the device whose user
  pressed, because its card is already talking; the peer that data was *pushed to* may still
  announce, because there the data landed unbidden.
- **The panel is the suppressor.** The mobile page and the desktop pane render one shared
  panel body, and it marks itself mounted on the provider: while it is, the cards are
  showing the same news and the toast would be noise. A manual "sync now" keeps the
  snackbar its card already shows; the pairing kick is likewise not an announcement. The
  provider decides *whether* (a counter, so an odd dispose order cannot silence a live
  panel); the announcer widget decides only *what it looks like*, and is a pass-through
  wrapper at the app root so it is alive wherever the user is.
- *Rejected: announcing every successful round.* "Synced · up to date" on every launch and
  resume is a toast nobody needs twice, and it trains the user to dismiss toasts — which is
  exactly the reflex the arrival toast must not build.

## Amendment (2026-10, slice 17): a re-pair keeps the networks it has met

Slice 9 made a peer record hold every address a peer was known at, but left the pairing paths
building a *fresh* record: `_carryPairingFacts` moved the rename, the last-sync stamp and the
last report across, and the endpoint set was rebuilt from the address the pairing ran over
plus the candidates that QR advertised. Both sides, every time. So the remembered set only
ever described the network the last pairing happened on, and the multi-network story it was
built for did not hold: pair at home, repair once at the office, and home is gone from both
records — pairing again at home forgets the office in turn. Alternating two places cost a
re-scan at every switch, which is precisely the journey the endpoint set exists to spare.

- **A re-pair carries the old endpoints over, behind the fresh ones.** After the address the
  pairing proved (the new head) and the candidates the QR or the pair request advertised
  (current-network hints), the previous record's endpoints are appended with their own
  `lastSuccessAt` stamps, deduplicated and inside the same six-endpoint cap
  (`SyncPeerRecord.rememberEndpointHistory`). Both pairing sides do it, because both hold a
  memory of where the other was.
- **Manual repair still replaces the whole set.** That wipe is deliberate and unchanged
  (slice 9): the user typed an address because the automatic memory failed, so keeping the
  rest would keep the failure. The distinction is which gesture is being performed — a
  re-scan says "the peer moved", typing says "what you know is wrong".
- *Rejected: carrying the old endpoints in `_carryPairingFacts`.* The order would then be
  history-first, so a stale address from another network would be dialed ahead of the
  current network's hints; the carry has to happen after the pairing's own endpoint writes,
  and the doc comment on `_carryPairingFacts` now says why endpoints are not in it.
- *Rejected: a separate "forget other networks" action.* It would ask the user to maintain a
  set the code can bound by itself (six entries, trimmed in order), and the probe makes a
  stale entry cost one parallel SYN rather than a dial budget.

## Amendment (2026-10, slice 16 follow-up): the gate reads only what arrived

Field use of the slice-16 announcement — and a read of it against the desktop shell — found
three holes in the launch version. None changes the intent above; all three change what the
gate and the suppressor may read.

- **The viewer follows the user, not the element tree.** The panel marked itself a viewer on
  mount and released it on teardown, which is the same thing only while a panel is unmounted
  when it leaves the screen. On desktop it is not: the home page keeps its tabs alive in an
  `IndexedStack` ("so ongoing chat streams are not canceled when switching tabs"), so after
  one visit to Settings → LAN Sync — the journey the pairing QR forces — the panel stays
  mounted, the release never runs, and *every* arrival is suppressed for the rest of the
  launch. Every `IndexedStack` child carries a visibility scope, so the mark now follows
  `Visibility.of(context)`, re-evaluated in `didChangeDependencies`: shown, hidden and shown
  again release and re-take the viewer. The provider still counts (not a bool), and the
  reference `dispose` needs is still kept while the element is alive.
- **Only what arrived counts.** `entityRows`/`preferenceRows` on the report add both
  directions, because the card's "moved" chip wants the total; the gate was reading them, so
  a session that only *pushed* a synced preference or a new assistant — a routine quiet round
  — announced "Synced with `peer`" over a device where nothing had changed. The report gains
  received-only counters (`entityRowsReceived`, `preferenceRowsReceived`, filled from the
  incoming payload alone) and the gate reads those. Every other counter it reads was already
  one-directional; business rows were the only pair whose card meaning and gate meaning
  differ, so the aggregate stays as the card wants it.
- **An arrival that lands after teardown is dropped, not thrown.** `dispose` closes the
  arrival stream but does not stop the engine, which is deliberate (the listener is the app's,
  and the graceful stop is the exit flush's job). A session that finished in that window
  answered the peer with a 500 — *after* applying its data — because `add` on a closed
  controller throws into the request handler. Announcements now go through one guarded sink
  (`_announce`), the same rule `_notify` already followed for exactly this class of late tail.
- *Rejected: having the desktop host pass a "my tab is selected" flag down.* It would have to
  be threaded through the pane and page, would not cover a future offstage host, and the
  visibility scope every `IndexedStack`/`Visibility` child already carries says the same thing.
- *Rejected: gating on `TickerMode`.* `IndexedStack` does not mute tickers for its non-selected
  children; the signal that actually travels is the visibility scope.

## Amendment (2026-10, slice 18): workspace carriage — the record rides rows, the files ride a table

Through slice 17 a workspace was the one entity kind that never travelled, and the reason was
sound: a *linked* workspace is a host path, and a *managed* one is an unbounded local project
directory. The product decision that overturned the blanket rule is narrower than it looks — work
follows the user across their machines, and a workspace is where the work sits — so the rule became
per-row and per-face instead of per-kind.

- **The record travels; a linked workspace's row does not.** `isLinkedWorkspace(payload)` (parsing
  the payload, treating an unparseable one as an ordinary row rather than throwing) is the single
  authority the backup face and the sync face both call, so the two cannot drift apart. The
  exclusion is *row-level* and lives at every entry point that could leak or delete: the manifest
  refs, the id set, the payload read (the security boundary), the apply, and the delete guard (a
  peer may neither seed nor delete a linked row here). That shape is forced by the merge rule — a
  row that never entered a manifest cannot be read as a deletion — so "exclude this row" and "leave
  the kind out" are *not* interchangeable, and only the former is available.
- **Files travel on their own face, described by a table.** A per-pair, per-workspace map of
  `relative path → (size, mtimeMs)` rides **both** directions of the delta batch. Both directions
  because each side plans what it lacks: the responder plans inside the push beat (so the initiator
  must publish *before* pushing), and the initiator plans after the fetch response (so the responder
  must re-walk its index, including the files it just landed, or the initiator can never learn the
  transfer succeeded and re-sends forever). The transfers themselves are pulls — the side that wants a
  file fetches it over the peer's own listener — until slice 23, which added the push fallback for a
  peer that cannot be dialled back.
- **Identity is metadata, and the ledger is two-sided.** A file is what its size and mtime say it is;
  no byte is read to plan a session. Each pair keeps the last revision **both** sides proved, as two
  stamps (`mine`, `peer`) inside that pair's checkpoint, and it advances only on agreement or on a
  file this device just *landed* and verified — never on a send (slice 23 made "landed" the rule, since
  a pushed file lands without anyone fetching it). Two stamps rather than one tolerance
  constant because a receiver cannot make the sender's filesystem agree with the mtime it wrote
  (coarse-granularity filesystems round it), and "agreed" has to stay an exact comparison.
- **Absence is a deletion, and an edit beats it.** A ledger path the peer's table no longer lists is
  deleted here, and the mirror image holds there. The rule is only safe because of the two guards
  below, and because a session against a bulk-replaced peer (a different data epoch) sends
  `allowDeletes: false` — the same discipline the row faces already follow.
- **A workspace is planned only when both sides advertised a table.** A missing table means "not
  shared" (switched off, over a cap, not this peer's); an empty table means "shared, and it has no
  files". For the deletion rule those are opposite statements, so the wire shape keeps them
  distinct (a present-but-empty table survives decoding) and nothing collapses them.
- **Caps are hard gates and the switch cannot lift them.** Over 2,000 files or 200 MB, a workspace
  contributes **no** content — the whole block, never half a table, because a half table reads some
  files as "never agreed" (re-send, safe) and others as "agreed" (the entry a deletion could be read
  from). The switch is device-local (`sync/workspaces.json` holds the *disabled* set, so a new
  workspace is on by default) and controls files alone: the record keeps travelling either way,
  since removing a workspace from the manifest is what deletes the peer's copy.
- **An incompletely read index is not shared at all.** If a directory cannot be listed or a file
  cannot be stat'ed, that workspace publishes nothing that round and nothing is deleted for it, and
  the panel says so (`无法读取`). This is a data-safety decision, not politeness: a file missing from
  a table is indistinguishable from a deleted one, so one permission accident would otherwise delete
  the peer's copy. The price is that a workspace with a single unreadable file syncs no content until
  it can be read — accepted, because the alternative can destroy data and this one cannot.
- **Landing a file is four gates, not a write.** The relative path must be safe (no absolute path, no
  drive or ADS colon, no backslash, no NUL, no empty/`.`/`..` segment, no trailing dot or space, no
  DOS device name); it must be lexically inside the workspace root; the *nearest existing ancestor*
  must resolve inside it too (checked **before** `create`, because `create(recursive: true)` follows a
  symlinked ancestor and builds the directory outside the root); and the landed size must equal the
  advertised one. A failure fails closed — the file is treated as not applied and retried next
  session. `setLastModified` to the peer's mtime is best-effort and logged; the ledger records each
  side's real stamps, so a filesystem that rounds the mtime cannot turn into a re-send loop.
- **A managed workspace row removed by sync takes its folder with it.** Leaving the directory behind
  would hide hundreds of megabytes behind a workspace the app no longer lists.
- *Rejected: content hashing* (a digest per file, or one per workspace). It reads every byte to
  answer a question mtime already answers, and it is the expensive half of the "avoid a catastrophic
  walk" requirement this slice was asked for.
- *Rejected: directory-level LWW.* One edited file would move a whole tree, and a conflict would
  discard the loser's entire directory instead of one file.
- *Rejected: seeding only on the first sync* (transfer once, then leave the two copies alone). It is
  the cheapest thing to build and the only one with no way back: after the first session the copies
  drift with nothing to detect it.
- *Rejected: a content digest folded into the row digest* (the C-era plan, following the skill
  precedent). Slice 18 already re-lists every workspace's files on every session, so content needs no
  trigger; mixing it in would make "a file changed" mean "the row changed" — an extra row transfer
  per edit plus a fabricated LWW-loss count on the panel.
- *Rejected: a separate ledger file per peer* (`sync/workspace-ledger/<deviceId>.json.gz`). The
  ledger is this pair's state, advanced by one session and written at one moment, so it belongs in
  the same atomic checkpoint write. The free consequence is what settled it: `deletePeer` and
  `resetCheckpoints()` (the bulk-replacement hooks) already cover a checkpoint, and a ledger that
  outlived a restore would delete the peer's files.
- *Rejected: `Sent`/`BytesSent` counters.* The transfer is a pull, so the sending side cannot know
  what arrived; every counter on this face counts what **this** device landed, deleted, lost or
  withheld.
- *Rejected: a switch that can override the caps* ("sync it anyway"). The requirement was to avoid a
  catastrophic scan and transfer; a switch that re-enables both is that requirement with an off
  button. The tooltip says so instead: over-cap workspaces do not sync content, the record always
  does, and the switch only controls files.
- Known limits of this face are collected in the consequences section below (mtime granularity and
  clock skew, no permission bits or symlinks, rename = delete + create, the over-cap and 20k-ledger
  drop, the unreadable-workspace freeze, and linked workspaces being absent from the panel's
  workspace section).

## Amendment (2026-10, slice 19): a probe that is a request, endpoints as first-class things, and a round that yields

Slice 10 gave the pairing walk a bare TCP probe and slice 14/15 built the online dot on the same
primitive. Both were answering the wrong question. "Something completed a TCP handshake at this
address" is not "this peer will talk to me", and the two disagree in exactly the cases a user
complains about — a recycled DHCP lease, a machine that happens to listen on the port, a peer that
was unpaired on the other side.

- **`POST /sync/ping`: idempotent, authenticated, and answerable beside a running session.** It
  writes nothing and answers 204 to a caller that presents its pairing secret (401 for a pairing
  that is gone; 503 `ping_busy` past eight probes in flight, which is a statement about the
  listener's load rather than about the peer). A probe is now the *pair* of facts a session needs —
  reachable **and** still paired — which is what lets the dot and the dial both read one measurement
  instead of two disagreeing ones.
- **The listener's request loop stopped awaiting the serial lane.** It used to be
  `await for (request) { await route(request) }`, so a twenty-minute data beat blocked *reading the
  next request*: any probe dispatched beside it could not be answered, and the peer looked offline
  for the whole session. The loop now chains the serial lane (`serial = serial.then(...)`) and
  dispatches probes straight from the loop, which is what makes a probe a viable per-tick question.
  The guard is a request that occupies the lane with a half-sent body while a probe must still
  answer within seconds.
- **An endpoint is a thing, not a line of text.** The remembered set went from six addresses to
  **twelve**; each endpoint carries a device-local `customName` (empty = the bare host is the name),
  when it was added, how many sessions it has carried and what the last probe measured. Manual repair
  became **per address** — add, edit or delete one, where the old "edit address" replaced the whole
  set: the automatic memory is what failed, so retyping the rest of the set asks the user to
  reproduce something the app already knows.
- **Probing is tiered, and the dot forgives one miss.** A ten-second tick asks the two best-answered
  addresses, and the silent tail (up to four) only on a full round — start, resume, a panel opening,
  a finished session, a completed pairing. One miss is forgiven and a `ping_busy` is not a verdict;
  two consecutive misses darken the dot. Without the tiering the cap of twelve would make every tick
  twelve handshakes, and without the forgiveness the dot would flicker.
- **A round that has not been answered yields to an arriving hello.** Until the peer's hello comes
  back, an initiator round has proved nothing — it may be sitting on an address that never answers,
  which is precisely the one-way-LAN case where the user can see the peer online on the other device
  while this one reports failure. So a hello arriving during the dial *supersedes* the round: it
  closes its socket and records nothing (not even a failure — the pair's real outcome is arriving
  from the other side), and the inbound session runs. Past the hello the round is live and a peer
  hello is refused as busy instead. The mirror case — both devices deciding to sync in the same
  moment — is covered by one retry five seconds after a busy refusal, so a collision cannot end with
  neither session having run. *(Corrected by slice 21: a crossing round reports `superseded`, not
  `busy`, and the retry was armed on one caller only; the pair is now unblocked by the expiry of the
  session a yield leaves behind.)*
- **The dial beat names the address, and the rest of the card stops shouting.** The beat that can sit
  for seconds is the dial, so it names the address it is trying (and, since slice 20, never a rank).
  The header carries no IP at all — a peer is a device first — and the addresses are a grid of tiles,
  one per (device, network) pair, each showing what that network is called and what it last measured.
  A tile whose latest probe did not answer shows `—` rather than a stale figure, because a stale
  number beside a silent address is the one thing that would make the grid lie; the persisted
  measurement lives in the address's own detail view.
- *Superseded by this slice*: **"Rejected: upgrading the probe to a pinned TLS handshake"** (slice 14
  above). The rejection's three objections were answered rather than ignored: the "a probe tests the
  *address*, never the peer" contract was the thing that was wrong (a peer's answer is more useful
  than an address's); the crypto cost was bounded by asking the tick about two addresses instead of
  every remembered one, and by keeping the pairing walk's bare TCP probe where no secret exists yet;
  and the "weaker statement than the session verdict" argument is why the session verdict still
  outranks a probe answer for the dot's stated source.
- *Rejected: keeping the bare TCP connect as the dot's evidence.* It is cheap and it is wrong: it can
  answer while every session fails, and a green dot next to failing sessions is worse than no dot.
- *Rejected: one boolean per peer* ("one of these addresses works"). It is what the old card showed,
  and it is why a user could not tell a dead address from a slow one or see a latency at all.
- *Rejected: a longer endpoint memory without tiering.* Twelve addresses probed every tick is twelve
  handshakes per tick per peer; the cap is only affordable because the tick asks the addresses that
  already answered.

## Amendment (2026-10, slice 20): the dial spends the probe instead of walking

The dial used to be a walk: probe every remembered address in parallel, then dial them one at a
time — proved first, the silent tail after — publishing `正在连接 <address>…（2/3）` as it went.
Two things were wrong with that, and only one of them was visible in the screenshot.

- **The probe was already the parallel answer.** `probePeerEndpoints` asks every address at
  once, each with a pinned TLS handshake and an authenticated request; an address's answer is a
  latency, a refusal, or a silence. The dial then re-asked the same addresses *serially*, paying
  a connect budget for every repetition of a question that had just been answered in parallel.
  The rank was the tell: `（2/3）` is a serial artefact in a system whose evidence is parallel.
- **The rank was not something a user could act on.** "Which address is this stuck on" is
  actionable; "the second of three guesses" is not, and it reads as a system fumbling through
  addresses when the probe had in fact already ordered them by measured round trip.

The dial now spends the proof. `dialableCandidates` keeps the addresses the probe reached —
`answered`, or `noVerdict`, because a 503 says the listener was too loaded to judge rather than
that the address is wrong — in measured-latency order, and those are dialed until one runs a
session. An address the probe did not reach is not dialed. A probe that proved nothing still
buys exactly **one** dial: the best-remembered address, the head of the set, because a single
measurement is not a verdict on a network. That one guess is what keeps the old rule — one lost
packet is not a permanent loss — true now that the walk is gone, and it bounds a sleeping peer's
round at one connect budget instead of one per remembered address (twelve addresses used to cost
up to thirty-six seconds of "connecting"). `SyncSessionProgress` loses `attempt`/`attempts`,
`lanSyncPhaseConnectingAt` and its translations are deleted, and the beat is either
`正在连接 <address>…` or nothing.

The same review removed the last report row that said nothing new. `unreachable` — the peer
asleep, off the Wi-Fi, on a network this device has never met — drew a banner
(`暂时连不上——对方可能已休眠或换了网络…`) under a card whose subtitle already said
`· 暂时连不上`. The row is gone, and the card asks `syncReportHasRow` before it renders the
report area at all, so the empty outcome costs no stray gap above it. The manual press keeps its
actionable line (`同步失败：连不上对方设备…重新扫描二维码或编辑地址`) in the snackbar, which
is where an action belongs: a routine absence is a state, not an incident.

- *Rejected: racing the transports at dial time* (`SecureSocket.connect` against every candidate
  at once, the pin enforced, the first handshake winning, the rest aborted). It is the one design
  that gives a silent address a second chance at the dial's own level and bounds the worst case
  to a single budget instead of one per address. It was rejected on three counts: the probe
  already buys that evidence — a pinned handshake *and* an authenticated request — once per tick,
  so a race re-buys it per session and adds N−1 handshakes to a path that normally needs one; the
  aborted legs arrive at the peer as connections that complete a handshake and then close without
  a request, which the listener's `await for (final request in server)` surfaces as a stream
  error, so the race needs accept-loop hardening that does not belong in this slice; and the case
  it wins — the probe could not reach an address within its five-second budget while a full dial
  could — is narrow enough to measure before paying for.
- *Rejected: dialing nothing when the probe proved nothing.* It removes the last serial step
  entirely and reports a sleeping peer as `unreachable` with no wait at all, but it turns one
  missed probe into a lost round, leaving the periodic tick as the only second chance. One dial
  is the cheaper half of that trade.
- *Known limit.* An address that cannot answer the probe — its SYN is filtered, or it needs the
  longer hello budget to wake — is not tried at dial time unless nothing else was proved. The
  remedies are the ones already documented for drift (re-scan the QR, or edit the address on the
  card), and the next tick probes again.

## Amendment (2026-10, slice 21): review hardening — the walk after the apply, an id that is a path, and one yield per crossing

A review of slices 18–20 turned up nine defects and one unnumbered one. They are fixed where they
were made, and every fix is guarded by a test that was shown red before it landed. Nothing here
changes the wire: no message shape, no protocol bump.

- **The initiator plans workspace content from a walk taken after its business apply.** Slice 18's
  initiator walk has to run before the push — the responder fetches inside that beat — but the same
  list was then reused for the *planning* half, after the apply. A workspace record that had just
  arrived was absent from it, so the folder that record made this device's to populate waited a whole
  session, while the other direction transferred immediately. The planning walk is now taken after
  `applyBusiness`, exactly as the responder's is; the pre-push walk stays what it is for (publishing
  what this device serves inside the push beat). Both roles therefore walk twice per session, which
  the responder already did.
- **A workspace id is one plain path segment.** The id is interpolated into
  `<appData>/workspaces/<id>/files` (`AppDirectories.workspaceFilesDir`) and it arrives from the wire
  and from a backup — and only a row's *payload* had ever been validated. A paired peer advertising a
  workspace whose id was `..` got this device to walk a directory outside the managed tree, advertise
  it back to that peer over `/sync/wsfile`, and delete it recursively when the peer dropped the row.
  `isSafeWorkspaceId` — a single segment: no separator of either flavour, no NUL, no colon, no
  trailing dot or space, no DOS device name, not `.`/`..` — now joins the row-level rule that already
  excluded linked workspaces, so such a row is invisible in **both** directions: never announced,
  never served by name, never accepted from a peer, never deleted through sync. The filesystem sink
  refuses the id last, so any future caller inherits the guard.
- **The linked-row rule reads the local half too.** The apply guard inspected only the *incoming*
  payload, so a peer's `managed` row at the id of a local `linked` workspace replaced the user's link
  — precisely the case the guard's own comment named. The local payload is checked now as well: a row
  this device does not offer is not one a peer may overwrite either. The peer re-offers that row every
  session, because nothing here ever announces it; that is one skipped row per session and no data
  moved.
- **A yielded session is provisional.** `handleHello` cancels this device's own unanswered round when
  the peer's hello arrives, and answers with a session instead. In a crossing dial both sides do that,
  so neither client is left to drive either session, and each side then refuses its own dials as busy.
  That state was permanent: `_sessions` was swept only at the top of `handleHello`, which a pair that
  refuses its own dials never calls, and the TTL there measured **from the hello**, so it could not
  tell a working session from an abandoned one (slice 22 splits it). A session
  created by a yield is now marked as such and records its first beat; one the peer has not pushed
  into within **four seconds** is dropped, and the sweep runs before `syncWithPeer` refuses a round —
  which is the call site whose absence made the wedge unbreakable. A crossing therefore costs one
  attempt, not a listener restart.
- **The busy retry belongs to every trigger.** It was armed inside `autoSyncRound` alone, so the ADR's
  own "one retry five seconds after a busy refusal" was true only of an automatic round: a manual
  press and the post-pairing kick got no retry at all. It is armed from `syncNow`, one per round and
  without chaining, and the delay carries an offset derived from this device's id (FNV-1a over the
  id, folded into `[0, 1200)` ms) so two devices that collided cannot retry in lockstep and collide
  again.
- **A `ping_busy` is not a verdict.** A 503 from a saturated listener was stored over the previous
  good measurement: the tile dropped to `—`, the address detail said "not reachable", and the
  persisted latency was cleared — the opposite of what the module's own contract says ("it must not
  overwrite a working verdict"). A `noVerdict` result now keeps the previous entry for that endpoint,
  is never written to the peer record, and renders as `—` rather than as a reachability verdict.
  *(On the **tick** path only: the session's own fallback round kept overwriting it, which slice 22
  fixes at one shared choke point — the rule had two implementations and therefore one.)*
- **The silent tail rotates.** Both probe shapes took the *first* `kSyncTailProbeCount` silent
  addresses in endpoint order, so with more than four cold addresses the ones behind them were never
  asked by any round — no measurement ever proved them, so the dial never tried them either, and the
  single unproved guess a dial spends was always index 0. The cold tail is now ordered least recently
  asked first (never-asked addresses lead, ties keep the memory's order, which is also the endpoint
  order the guess reads), so `⌈12/4⌉` rounds cover the whole memory. The rotation falls out of the
  answers already kept for endpoints a tick did not visit; no counter, no randomness.
- **A root that cannot be resolved is reported, not dropped.** `snapshots()` documented that an
  unreadable workspace is still reported — the panel has to be able to say "this one is not syncing"
  — and then `continue`d past a `resolveRoot` failure, so the row vanished from the panel and from
  every count. It now yields a snapshot with no root and an incomplete index, which is the same
  refusal to share a partial tree an unreadable directory gets; the panel's existing "unreadable"
  pill renders it and the report counts it as a workspace not syncing files.
- **The online-dot label follows the dot.** The two session presence sources were collapsed into one
  in slice 19, and the label was then chosen from the *source* alone: a grey dot whose last word came
  from a failed session was labelled "Online — the last sync connected", in the tooltip and in the
  semantics. The polarity now comes from the same flag that paints the dot, so the two cannot
  disagree, and `lanSyncOfflineFromSession` is restored in all four locales.
- **A measurement's age is its own.** The provider stamped a whole probe snapshot with the time it
  was published, while it keeps the answers for endpoints a tick did not visit — so a figure from a
  minute ago could pass the dial's fifteen-second freshness gate, take a place in the candidate
  order, and bound that candidate's connect budget. The dial now filters per measurement
  (`EndpointProbeResult.measuredAt`), and `PeerProbeSnapshot` — which existed only to carry the
  mis-stamped publish time — is gone.
- *Rejected: a device-id tie-break for a crossing dial* (only the higher id yields, so exactly one
  session is stored). It is the smaller change and it converges in-session, but it needs to know
  whether the peer is *also* mid-crossing, which is not locally observable — a hello is sent by every
  dialer — so the less informed version makes the one-way case depend on the peer's next trigger
  instead of on the arriving hello, and trades that guarantee for this one. The provisional-session
  expiry closes the wedge without reordering the yield rule; a fully informed version would need a
  hello-response flag, i.e. a wire change, for a case that now costs one attempt.
- *Rejected: clearing a provisional session on an authenticated probe.* A probe lands during healthy
  sessions too — the peer's own ten-second tick — and a session is not this device's to discard
  because the peer can reach it. The expiry covers the abandoned case without that risk.
- *Rejected: gating the second walk on the workspace id set.* Comparing the id set after the apply
  (one query) and re-walking only when it changed would save a stat walk in the common case, at the
  price of making correctness depend on a second signal agreeing with the first. The responder
  already walks twice per session, and the walk is stat-only, capped and off the UI isolate.
- *Rejected: dropping the local busy refusal when the held session has no beat yet.* It would let a
  device that holds an untouched session dial instead of refusing, which breaks the one-session-per-
  pair rule exactly when the peer's push is being built — the window in which a big library takes
  seconds to assemble. The expiry is bounded and cannot corrupt a live session.
- *Known limits.* A linked workspace's id, once known to a peer, is re-offered by that peer every
  session and skipped here each time (one row, no data). A crossing dial still cannot complete a
  session *in* the crossed round: the pair recovers on the next attempt, which a manual press or the
  busy retry reaches within seconds. An address whose every probe answer is `ping_busy` reads as
  unknown (`—`) rather than as either reachable or dead, which is what the answer says.

## Amendment (2026-10, slice 22): review hardening — a sweep that means "idle", one fold per rule, and limits that know about each other

A second review of slices 18–21 turned up four defects, three of them in code slice 21 had just
written, plus four below-threshold items. They are fixed where they were made, every fix is guarded by
a test that was shown red first, and the two sentences slice 21 got wrong are corrected above. No
wire change: no message shape, no protocol bump (`kSyncProtocolVersion` stays 5; the new `409` is a
status on an existing route).

- **The sweep means "idle", not "old".** Slice 21 replaced one rule with one rule: any session older
  than two minutes since its **hello** was dropped. A first sync of a large library is a single push
  beat that runs for minutes, so the sweep deleted the session that was transferring, and the peer's
  next beat — and the fetch beat that closes the session — failed against a session that no longer
  existed (`sync_session_missing`, surfaced as a 500). It is now three states, named for their jobs:
  `_dropIdleSessions` measures from the peer's last beat (`lastBeatAt ?? startedAt`), and skips any
  session with a beat in flight (`beatsInFlight`, raised in `_beginBeat` and lowered in `_endBeat` in
  `finally`, with the stamp written at *both* ends so a beat that ran for minutes is recent activity
  when it finishes); `_dropAbandonedYieldedSessions` keeps slice 21's four-second rule for a yielded
  session never beaten. `SyncEngine` gained a `now` clock, so the regression — a session beaten at
  2:29 that must survive a sweep at 2:30 — is a test that runs in milliseconds instead of the 2m18s
  probe that found it.
- **A fetch beat requires the push it belongs to, and the ledger is never defaulted.** Every session
  is one push then one fetch, and the responder's workspace ledger — the record of what both sides now
  hold — is produced by the push. The fetch beat was answered regardless, and its checkpoint write
  defaulted that ledger (`session.workspaceOutcome?.ledger ?? const {}`), so a beat that arrived
  without its push persisted an **empty** ledger: the next session reads "we never agreed about these
  files" and re-transfers, and reads a file deleted here as one the peer never had. `handleFetchSubtrees`
  now refuses with `409 push_required` (`SyncRequestRefusal`, which the server maps to a status instead
  of the 500 every handler exception used to become — `sync_session_missing` is a 409 too), and the
  checkpoint carries `session.workspaceOutcome!.ledger`: the push is the only producer, so the outcome
  is not optional and cannot silently become emptiness.
- **The address cap is a refusal, and the affordance is reachable.** `SyncPeerRecord.addEndpoint`
  appended, trimmed the set back to twelve and returned `true` — so a user's thirteenth address was
  reported as saved and silently discarded, and the card offered "add address" only in the empty-set
  state, which is the one state where a *second* network cannot be added. `addEndpoint` now returns
  `SyncEndpointAdd` (`added` / `duplicate` / `invalid` / `full`) and **refuses at the cap instead of
  evicting** a proven address; pairing's automatic learning still keeps the freshest twelve but returns
  what it dropped, which the engine logs; the provider returns the outcome and the card says the limit
  out loud in a snackbar. The card shows the add button whenever the set is below the cap, which is
  also where the layout has a free cell.
- **One probe fold, one budget, and limits that are derived from each other.** "A 503 is not a verdict"
  had two call sites and one implementation: the tick kept a working figure, the session's own fallback
  round overwrote it. Both now go through `_storeProbeResults`. The fan-out and the listener's
  concurrency cap were also chosen in isolation — twelve remembered endpoints against eight answered
  probes — so a peer's full address memory could 503 *its own* listener, and every answer came back
  "no verdict", disabling the measurement the round existed for. `sync_limits.dart` now owns both: the
  listener's cap is **derived** from the endpoint cap (`kMaxPingsInFlight = kMaxPeerEndpoints + 2`), the
  probe budget is `kSyncProbeConcurrency = kMaxPeerEndpoints`, and `probePeerEndpoints` chunks rather
  than fans out past its budget, so the relationship cannot drift again by editing one number.
- **The per-workspace switch protects the folder from a peer-driven deletion.** `deleteBusinessRow`
  removed a managed workspace's folder whenever the peer deleted the row, switch or no switch — so
  "off" meant "protected from transfers, removed when the peer tidies up". With the switch off the row
  still goes (it is gone on the peer, and a row that stayed would be re-advertised), the folder stays,
  and the session report counts it (`workspaceFoldersKept`, one line in all four locales), because a
  folder that is invisible in the app and present on disk has to be explained somewhere. The switch
  keeps working in the other direction too: a switched-off workspace is neither sent nor served, and
  flipping it off drops the current advertisement.
- **An advertisement lives inside its session.** `_served` was only ever replaced by the next publish,
  so a file this device advertised in one session stayed servable to that peer until the next one —
  including after the user switched the workspace off. It is now dropped when the initiator's round
  ends, when the peer is unpaired or revokes, and when a workspace is switched off. It is **not**
  dropped when the responder's fetch response is written: the initiator pulls the files it was told
  about *after* that response, and the first version of this fix did exactly that, 404-ing every
  workspace transfer in the suite (`workspace_file_unavailable`). The next hello therefore drops the
  previous session's table — the responder's one lasts exactly as long as the pulls it invited.
- **The device-local switch is mutated, not read-modify-written.** `workspaces.json` holds every
  workspace's choice in one file, and `setEnabled` read the set, edited it and wrote it back. Two
  callers in one turn — two switches, or a switch and a session's own read — both complete their read
  before either write, so the second write erases the first id: a switch that flips back on the next
  read, with nothing in the logs. `SyncStore.mutateWorkspaceContentDisabled` chains read-edit-write as
  one serialized step (with a queue that survives a failed write), and `setEnabled` is its only caller.
- **A stalled probe answers 408, not 200.** The ping lane's `catch` closed a response that had never
  been given a status, which HTTP sends as `200 OK`: a probe whose body stalled for five seconds
  reported "the peer answered in 5 s", the one thing a liveness probe must never invent. It answers
  `408` now.
- *Rejected: a device-id tie-break for the crossing.* Reconsidered now that the crossing case has a
  retry: a stable tie-break would still have to read a fact both sides read identically, and the pair's
  problem is not "who speaks first" (arrival order decides that, correctly, and is what gives a
  one-way LAN its in-session convergence) but two triggers that keep landing in the same instant. The
  fix is a per-attempt random salt on the retry (`kSyncRetrySaltMs`), which decorrelates the *attempt*
  rather than the device; `superseded` now arms that retry at all, which it previously did not — the
  crossing pair waited for the next automatic trigger a minute later. Device ids stay where they
  belong: deciding values both sides must compute identically (the LWW tie).
- *Rejected: raising the listener's probe cap alone.* It would hide the contradiction instead of
  relating the two numbers, and a second paired peer's tick can still saturate a listener legitimately
  — which is why the fold must tolerate `noVerdict` on every path. The cap moved because it is derived,
  not because a bigger number is a fix.
- *Rejected: dropping the served table when the fetch response is written.* It is the obvious place and
  it breaks the initiator's pull (above). The table's honest lifetime is "until the next hello, the
  switch going off, or the pair going away".
- *Known limits.* A folder the switch protected is orphaned: its row is gone, so nothing in the app
  points at it until a workspace with that id is created or a backup restores one; the report line is
  the only trace. Between sessions the responder's advertisement still serves a **paired** peer a file
  that was walked in the previous session and has not changed since — the stamp check is what makes it
  the same bytes, and unpaired peers are refused at the route. The sweep still cannot tell a beat that
  is *hung* from one that is slow: a session whose beat never returns is never swept, which is the
  deliberate trade (the alternative is killing working transfers) and is bounded by the route
  deadlines in `sync_server.dart`.
- *Mechanisms, not just fixes.* The sweep is guarded by a state table rather than one example
  (`_assertSessionInvariants` at every `_sessions` transition under `assert`, plus the injected clock);
  the probe rule and the workspace ledger each have exactly one choke point; the limits live together
  and are derived; and `AGENTS.md` now carries the rule this round's worst defect came from — a change
  to a shared predicate, TTL, cap or sweep names every caller of it and what changes for each, and a
  new call site for an existing rule gets the rule's state table, not its happy path.

## Amendment (2026-10, slice 23): the file a peer cannot fetch is pushed to it

The first two-device run of slice 18 — an Android emulator and the desktop app on the same machine —
ended with a workspace holding one tiny HTML file, the desktop's card saying `1 个工作区文件未能应用`,
and both sides calling the session a success. The emulator's own state named the cause:
`peers/e4c81a….json` listed its three addresses as `2402:f000:9:4801:145c:543f:6fd:80c1`,
`59.66.74.109` and `10.0.2.15` — the first two are *the desktop's own* WLAN IPv6 and IPv4 — the
report read `success:true, workspaceFiles:0, workspaceFilesMissing:1`, the checkpoint for that peer
had no `workspaceFiles` key at all, and the workspace's `files/` directory was there and empty. This
slice is the fix, and it changes the wire (`kSyncProtocolVersion` 5 → 6).

- **A peer can dial out and still not be dialled back.** Every file transfer in slices 18–22 was a
  *pull* by the side that wanted the file, so a responder — always the side that did not start the
  session — needed the initiator to be reachable at the address its connection arrived from. A NAT
  rewrite makes that address the *forwarder's*: the Android emulator's user-mode network presents every
  outbound connection as coming from the host, so the desktop's "where the peer connected from" was the
  desktop's own LAN address and `_openReverseConnection` dialled **itself** (the certificate pin then
  refused it, and the failure was swallowed). All three of the emulator's advertised addresses were
  unusable from the desktop: two were the desktop's own, the third was the emulator's NAT address.
  Nothing could move from the emulator to the desktop — not workspace files, not the blobs
  `_unreachableBlobPull` marks pending — while the row half of the session worked perfectly, which is
  why it read as success.
- **Opening a session is not connecting.** `SyncClient.openSession` builds an `HttpClient` and a
  session object and performs no I/O, so the old dial's `try`/`catch` could never observe a failure and
  "no connection at all" was indistinguishable from "the peer refused this file": both counted as
  `filesMissing`, and the first of the two was not even logged. The reverse dial now **pings** each
  candidate before using it (that ping is also what makes a self-dial cheap: the pin refuses it in
  milliseconds), and a `fetch == null` miss logs why.
- **The push fallback (v6).** The initiator already holds a connection the pair has proved works, so
  that is where a file the responder cannot fetch now travels. The responder's push acknowledgement
  gained `workspaceRequests` — the pairs it planned and did not land, each with the version the
  initiator advertised — and `/sync/wsfile` gained a `PUT` that receives one such file as its raw body
  (the pair base64url in headers, a declared length, no content coding). The initiator pushes exactly
  those files before its fetch beat, so the responder's own walk — taken while it answers that beat —
  already sees them. A v5 peer would read the request list as "nothing owed" and had no reverse
  connection to fetch over either, so the two sides would agree to disagree about a workspace's files
  forever.
- **The request set is the write authorization.** The responder accepts a push only for a pair this
  session asked for — the set is built from the table the initiator itself advertised — and only for
  the size that was asked for; an unrequested pair, a substituted version and a body longer than its
  own declaration are all refused, and the pair leaves the set once it lands. Loopback and this
  device's own addresses are still *tried* as candidates (another instance of this app on one machine
  is a legitimate peer at 127.0.0.1, and the ping refuses a self-dial for free) but are never
  *remembered*: the address a caller appears to connect from can be this device's own, and remembering
  it is how the panel grew an endpoint that could only ever fail.
- **The lander advances the entry — the fetcher was only ever the common case.** Slice 18 and slice 22
  both said the side that *fetches* advances the ledger entry, because until now a fetch was the only
  way a file could arrive. A pushed file arrives at the responder, after the beat that produced its
  ledger, so the responder finalises the ledger once at the fetch beat: the push beat's ledger plus
  every file the initiator pushed. The sender still never advances anything — it cannot know its bytes
  arrived — and an entry the lander did not write asks for the same file for the life of the pairing.
- **A miss a push repaired is not also reported as missing.** The responder counts a failed fetch as
  `filesMissing` when it happens, and the push that repairs it arrives later; reporting both would put
  "1 个工作区文件" and "1 个工作区文件未能应用" on one card. `_report` subtracts what the pushes
  repaired, so what is left is what no direction moved.
- **The hello now advertises where the initiator can be reached** (`candidateHosts`, beside
  `listenPort`), which is what gives the reverse dial something to try after the observed address: the
  pairing request has carried the same list since slice 9, and a session had no way to say it.
- *Rejected: carrying the bytes in the fetch request.* The obvious one-message fix, and it makes every
  `.dart_tool`-sized workspace a base64 blob inside a JSON control body. The `PUT` streams, which is
  what the caps (2000 files / 200 MB) are sized for.
- *Rejected: a relay, or requiring both peers to be dialable.* Nothing in the protocol needs a third
  party to move a file that the peer holding it can already push.
- *Rejected: keeping v5 compatibility ("no requests ⇒ old behaviour").* The old behaviour is exactly
  the silent failure this slice exists to remove, and a half-spoken protocol is worse than an
  honest refusal at hello.
- *Known limits.* The blob plane still had only the reverse pull when this slice landed, so an
  undiallable peer's attachments and skill bodies kept failing — closed by slice 24, with the same
  shape and the skill-body coupling that shape brings. The push is sequential, and the
  reverse dial now costs up to three connect budgets before it gives up and the fallback runs — paid
  only in sessions that need the reverse direction at all.

## Amendment (2026-10, slice 24): the blob a peer cannot fetch is pushed to it

Slice 23 closed with its own limit written down: "the blob plane still has only the reverse pull, so an
undiallable peer's attachments and skill bodies keep failing (the next slice, with the same shape)".
The report that named the symptom is issue #1018, whose second half reads *"还会忽略消息中的图片，导致跨设备
对话没法接续"*. Same cause one plane over: the rows of a conversation arrive, the picture they reference
never does, and both sides call the session a success. This slice is the fix, and it changes the wire
(`kSyncProtocolVersion` 6 → 7).

- **The one face slice 23 left behind.** A blob was fetched only by the side that wanted it, so a
  responder needed the initiator to be reachable at the address its connection arrived from — the same
  NAT rewrite that made a workspace's HTML file unmovable made every image unmovable too.
  `_unreachableBlobPull` marked the whole wanted set `failed`, the checkpoint carried it as
  `pendingBlobs`, and the retry had exactly the same requirement next session, so for a NAT'd pair the
  images never arrived at all. Images do live under the managed roots (`upload`, `images`), and the
  manifest does find them (`kelivoFileUrisInRows`): this was never a discovery problem.
- **The push fallback (v7).** The initiator already holds a connection the pair has proved works, so
  that is where a blob the responder cannot fetch now travels. `SyncApplyAck` gained `blobRequests` —
  the entries the responder planned and did not land, each with the hash the initiator advertised —
  and `/sync/blob/<sha256>` gained a `PUT` that receives one of them: the entry's `kind` and its key
  (base64url) in headers, the raw bytes as the body with a declared length. The initiator pushes them
  after the workspace files and before its fetch beat, so the responder's own walk — taken while it
  answers that beat — already describes what it holds.
- **The request set is the write authorization, and the version is the request.** A push is accepted
  only for a `(kind, key)` this session asked for, and only when the route's hash *is* that entry's
  hash: a crafted target has never been advertised and can never be written, and the placement
  allowlist still keeps even an advertised URI inside the managed roots. A file blob's declared length
  must equal the size that was asked for, so a peer cannot substitute a different version for the one
  it offered; a skill's zip has no length that could be agreed in advance (it is packed on demand),
  so its guard is `applySkillBlob`'s own 200 MB cap and the transfer deadline. An entry leaves the set
  once it lands, which is what makes a replayed body a refusal rather than a second write.
- **The receiver verifies — in both directions now.** A file blob is hashed as it is placed and
  compared with the requested digest; a skill body is extracted and its directory re-hashed before the
  swap. That is exactly the authority the pull path already had on the *client* side, moved to the
  side that writes bytes; the push route adds no new kind of trust, and a blob that fails either check
  is simply still owed.
- **The initiator serves only what it still backs.** Resolution goes through `handleFetchBlob` — the
  same authority the `GET` route consults, including its fallbacks for a blob pending from an earlier
  session — and a file blob is re-hashed on top of it (the hasher memoises by path, length and mtime,
  so an unchanged file costs a stat). A file edited since its manifest is skipped with a log instead
  of being pushed into a refusal, and the responder keeps it owed.
- **A pushed skill body is paired with its record in the same session.** The push beat strips the
  record of every skill whose body it could not verify, and a pushed body lands *after* that apply, so
  the session would otherwise end with a directory and no row. That is not a harmless intermediate
  state: `SkillsService`'s rescan adopts a row-less directory as a fresh record stamped *now*, which
  then wins the next LWW merge and silently replaces the peer's skill settings with defaults. So the
  write path applies that skill's rows from the same push and folds them into the payload the fetch
  beat's checkpoint advance reads. The acknowledgement was already sent when this happens, so the
  initiator keeps one stale skill-content baseline and re-offers the record next session; that session
  finds the hashes equal, transfers nothing and converges.
- **A list that is peer input has a bound.** `kMaxBlobRequestsPerSession` (2048) caps the ask. Every
  entry costs the initiator more than a lookup — a hash it did not publish this session falls through
  to the asset registry and to a full scan of the local skill directories — and the list is *truncated,
  not refused*: what falls off stays in the responder's pending set and is asked for again. The
  workspace request list needs no such bound, because a pair is a lookup in the table the peer itself
  advertised and that table is already capped by its own walk.
- *Rejected: carrying the blob bytes in the acknowledgement or the fetch request.* The one-message
  fix, and it puts an `.dart_tool`-sized attachment inside a JSON control body; the `PUT` streams.
- *Rejected: deferring the whole business apply to the fetch beat*, so a pushed body is present before
  the record is written. It reorders an apply whose write fence, arrival gate and reporting are
  load-bearing, to save applying one row late.
- *Rejected: doing this for file blobs only.* The skill plane has the same shape and the same failure,
  and the coupling above is the actual work of including it.
- *Known limits.* A session killed between a pushed skill body landing and its record being applied
  leaves a row-less directory for the next rescan to adopt — a window of milliseconds, and the only
  state in which the rescan's default record can still win. A NAT'd first sync asks for at most
  `kMaxBlobRequestsPerSession` blobs, so a large library converges over more than one session. A blob
  has no byte cap beyond the skill zip's 200 MB: the pull path never had one either, and the bound on
  both is the transfer deadline. And the reverse dial still costs up to three connect budgets before
  the fallback runs, paid only in sessions that need the reverse direction at all.

## Amendment (2026-10, slice 25): the round-3 review — nine findings, one choke point each

An adversarial read of this branch (five traces over the long chains, plus probes that reproduced the
two worst findings end to end) produced nine findings. All nine were real, and each is fixed at the
rule it belongs to rather than at the symptom. Nothing here changes the wire: v7 stands, and the
version gate is what makes that safe (see the last bullet).

- **A workspace row's identity is written twice, and only one half was checked (Sev 5).** The `id`
  column decides what the row *is*; the payload's own `id` is what `Workspace.fromJson` reads, and
  therefore what the panel lists, what an update writes and what a delete removes. Only the column
  was validated, so a paired peer — or an imported backup — could push a row whose column is a safe
  `w-1` and whose payload names `..`: the panel showed an ordinary managed workspace called “Notes”,
  and deleting it with the default “also delete files” built `<appData>/workspaces/..` and removed the
  app data root — conversations, skills, sync state — recursively. `workspacePayloadNamesId` is now
  the one rule (the payload names exactly the row's id, and that id is a safe path segment), read by
  `_syncSkipsRow` — the choke point all six sync call sites already share — so a row whose halves
  disagree is invisible in both directions. The provider refuses such a row on load as well (so no
  unsafe id can reach the panel and no update can mint a second row under an id of the peer's
  choosing), one unreadable payload now costs its own workspace rather than the whole list, and the
  delete sink refuses a non-segment id on its own account. That last guard is unreachable today — the
  load filter already stops the row — and is kept deliberately: it is the last place before the id
  becomes a path.
- **One serialized merge path for a peer record.** The record has two owners writing it at once (the
  panel: a rename, an endpoint edit, the measured latency; a session: `lastSyncedAt`, `lastReport`,
  the endpoint it promoted), and every one of them wrote the *whole* record from a copy it had read
  earlier. The visible half was the worst: a successful session came back saying “Never synced”,
  because `syncNow` hands the engine a peer object, the engine holds it for the session and writes the
  outcome into it, while the session's own first state change makes the provider re-read `peers` from
  disk — so the post-session probe write saved a *pre-session* snapshot over the outcome. Every
  provider-driven session hit it, the manual button and each automatic round alike. `SyncStore.mutatePeer`
  is now read-modify-write **inside** a per-peer section; eight whole-record writers became merges, and
  `savePeer` remains only as the record's *origin* (a pairing answer is where a record begins).
- **The blob-retry fold was implemented twice, with two different bodies.** The initiator folded
  retries with `putIfAbsent` (“a superseded target is replaced by the fresh entry”); the responder's map
  literal listed the retry set *last*, so the stale entry won the target key. A blob's target is
  `(kind, key)`, so re-referencing an attachment keeps the target and changes the hash: the responder
  asked, session after session, for the hash it had pending, the initiator skipped it as “no longer
  backs”, and the picture never arrived while neither report named anything — the exact class slice 24
  exists to fix. One `_foldBlobWanted(fresh, pending)` now serves both halves.
- **The push beat had no “already taken” guard** while the fetch beat refused its half of the same
  one-push-one-fetch rule. A replayed `/sync/subtrees` replaced the session's whole outcome — the state
  the fetch beat and the report are built from — while the counters a landing books into kept
  accumulating, over-reducing the report's misses and losing the first beat's landings.
  `SyncRequestRefusal.pushAlreadyTaken()` (409) refuses it before the beat begins; the fetch beat still
  belongs to the first push.
- **The route-hash comparison was correct and its proof was wrong.** Slice 24 recorded it as an early
  refusal with “no final-state proof — the digest check refuses the same bytes later”. It does not: the
  digest is compared against the *route's* hash, so without this comparison a body hashing to some
  other valid hash is written at the requested key and booked under the legitimate hash. The test now
  sends exactly that, so the guard has a final-state proof instead of a note.
- **A report that cannot say a file both arrived and is missing.** Three ways the workspace face could
  tell the user something untrue: a conflict repaired by a *push* was never counted (`peerWins`
  promises the discarded edit is counted, and the fetch half counted it while the fallback half did
  not); a repaired miss was printed as missing (the summary part was gated on the raw miss count and
  printed the reduced one, so the one card the fallback exists for read “workspace files pushed 1 (6 B)
  · workspace files missing 0”); and a workspace dropped by the advertised-table cap was counted
  nowhere, because the omission count only ever saw the snapshot's own `shared` flag. The request set
  now carries which of its entries were `peerWins` (the plan knows the action, the request does not, and
  the landing is where the edit is lost), the summary gates on what is left after the repair, and
  `tablesOf` reports how many shared workspaces it dropped so both roles can name it.
- **The fan-out budget was per call, and there is more than one call.** The tick fans out one full
  round *per peer, concurrently*, and a session runs its own round when its snapshot is stale: two of
  those stacked `2 × kSyncProbeConcurrency` probes on one listener whose own cap is
  `kMaxPingsInFlight = kMaxPeerEndpoints + 2`, and the overflow answers `ping_busy` — correctly read as
  “no verdict”, so the device disabled the measurement the fan-out was grown to support. One
  device-wide pool (`_ProbePool`, sized `kSyncProbeConcurrency`) now hands out every probe of every
  round, from either path, for every peer. A bigger constant could not have fixed it: nothing bounds the
  number of paired peers, so no constant covers `P × 12`.
- **A mixed round darkened the dot for a peer that had just answered.** A `ping_busy` arrives over the
  *pinned* handshake, so the device at that address proved it is this peer and then declined to be
  judged — stronger presence evidence than the silence of a remembered address beside it. The rule
  suppressed the miss only when the whole round was no-verdict, so one silent memory turned a live
  peer's full round into a miss, and two of those cleared the dot: `every` → `any`.
- **A refused landing took the local copy with it.** `land` deleted the destination before checking the
  staged bytes, so a refusal left the path empty — the version that was there was, at that moment, the
  only copy this device had, and the next session re-fetched a file that was never lost. The size is
  verified before the destination is touched; the post-rename stat stays as the belt for a writer that
  lands in between. Reachability was, and remains, narrow (the sender re-stats and refuses a changed
  file), which is why it was recorded as a lead rather than a finding — but the repair is a reorder.
- **The one guess a round that proved nothing spends went to the memory's head.** The freshness rule
  keeps a minute-old figure from *ordering* the dial, but the address that figure names is not a bad
  bet. The unfiltered snapshot is now kept beside the filtered one on the round, and the single guess
  prefers the first candidate that has ever answered, falling back to the head. Order is preserved
  inside each half, so topology still breaks the tie, and a *fresh* answered address is in `dialable`,
  so this never overrides fresh evidence.
- *Rejected: a bigger `kMaxPingsInFlight`.* It cannot be derived for an unbounded peer count, and the
  property the file claims is about the *device*, not about one round.
- *Rejected: probing again when the snapshot is partly stale.* It adds probe traffic inside a
  user-visible session, breaks the “one wave” property, and voids the meaning of the freshness test.
  The one guess covers the case for one connect budget instead.
- *Rejected: carrying the `peerWins` action on the wire.* The initiator does not care whether its push
  replaces the peer's edit; the flag is the receiving side's own bookkeeping, so it stays off the wire.
- *Rejected: capability negotiation instead of the strict version gate* — the gate is exactly what
  removes the need for version-shaped guards, and it is why the leniency left in the parsers is
  input-hardening rather than compatibility (see the next bullet).
- **No compat guards, and the leniency that remains is not one.** There is exactly one version check in
  the sync code — the hello gate, exact equality — and no code path anywhere branches on a version.
  The lenient parses (`tryParse` dropping a bad blob entry, the request list truncated at
  `kMaxBlobRequestsPerSession`, defaults for absent batch fields) guard against a peer that is
  *dishonest or broken*, which the gate cannot rule out: it proves the peer is v7, not that it is
  correct, and a proxy, a truncated body or a corrupt row produce the same shapes with no version skew
  at all.
- *Known limits.* The delete sink's segment check and the second-push refusal are both
  unreachable-by-construction today (Occ 1: no shipped client double-pushes, and the load filter
  already stops a bad id) — kept because each is the last word at its own boundary, and named here so
  nobody counts them as proven by a test they do not have. A workspace whose file entries exceed the
  advertised-table cap still syncs nothing for that session; it is now *named* on the card rather than
  silent, and raising the cap remains a product decision. And the probe pool serialises two peers'
  rounds instead of stacking them, so a tick over many peers takes longer in wall-clock than it did —
  bounded by `kSyncProbeConcurrency` per wave, and the alternative was a listener refusing its own
  device's questions.

## Amendment (2026-10, slice 26): the addendum review — five findings, and two boundaries named

A second adversarial pass over the same branch (two delegated traces plus a source read) produced five
more findings after slice 25. All five were real and are fixed here, again at the rule each belongs
to; the wire does not change (v7 stands). The same pass confirmed two *acceptance boundaries* rather
than defects, recorded at the end.

- **A re-pair dropped the name and history of every address it re-advertised (Sev 3/Occ 4).** Pairing
  lands the address it came in on and every advertised candidate *before* it merges the previous
  record's endpoints, and `rememberEndpointHistory` skipped a collision
  (`if (endpointFor(host, port) != null) continue;`). The skipped addresses are the ones that matter:
  the address the pair is on today is usually a network it has synced over before, so a re-scan at
  home erased the home tile's name, session count and probe measurement, while an address from a
  network the pair had *left* kept them. The merge now folds the old tile's facts into the fresh copy
  — the name, the earlier first-learned, the later session and probe stamps with the measurement that
  belongs to them, and the session count *added* (the old count precedes the re-pair; the fresh one is
  this pairing) — while the fresh copy keeps its position, because that position is the dial order the
  call exists to build.
- **The push window was not a beat, so a long upload was swept (Sev 3/Occ 3).** The idle sweep keeps a
  session with a beat in flight and drops one whose last beat is older than `kSessionIdleTtl` (two
  minutes). Hello, push and fetch were beats; the file and blob bodies between the push ack and the
  fetch were not — the put routes neither opened a beat nor stamped `lastBeatAt`. A first sync whose
  upload phase outlasted the window was therefore swept by this device's own next round (the sweep runs
  *before* `syncWithPeer`'s busy refusal), after which every remaining put found no session and the
  fetch beat threw `sessionMissing`. Each put is a beat now: the body streams with `beatsInFlight > 0`,
  so no sweep can take the session mid-transfer, and both ends of the beat refresh the stamp, so a
  continuous upload stays fresh while a genuinely silent one still expires.
- **A limit another limit depends on was restated, and its named proof did not exist (Sev 2/Occ 3).**
  `kMaxWorkspaceLedgerEntries` (20,000) exists because it is ten workspaces at `kMaxWorkspaceFiles`
  (2,000); the doc said so in prose and named `sync_limits_test.dart` as the proof, and no such file
  existed. Both caps now live in `sync_limits.dart` and the ledger cap is *computed*
  (`10 * kMaxWorkspaceFiles`), so raising the file cap raises it; the named test exists and asserts the
  relationships rather than the numbers (ledger over file cap, listener headroom over the endpoint cap,
  probe budget equal to it, reverse-dial budget within it). Values are unchanged.
- **A port the store refuses was silently discarded (Sev 2/Occ 2).** The address form popped on
  anything `int.tryParse` accepted, while the store refuses `port <= 0` (`SyncEndpointAdd.invalid`),
  and the field has no input formatter — so `0`, `-1` or `70000` from a desktop keyboard closed the
  sheet and then wrote nothing: `addPeerEndpoint` returned `invalid`, `mutatePeer` saw `false`, and the
  only l10n mapping of the enum is `full`. On the edit path the sheet simply showed the old address
  again, so the repair silently did not happen. The form checks 1..65535 and stays open, which makes
  that silent state unreachable from the UI; `duplicate` remains the documented no-op, and the store's
  guard remains the wire-level one.
- **A doc block was two documents fused into one (Sev 1/Occ 2).** `panelOpened`'s doc and
  `workspaceSummaries`' doc sat in one block with no blank line between them, so the field carried the
  method's doc and the method carried none. Split.

Boundaries this pass confirmed and did **not** change — recorded so the claim "every workspace face
applies the rule" is not read as stronger than it is:

- **The versioned-backup merge is the one workspace writer outside the choke points.** It copies
  `kind IN ('workspace', 'skill', 'composerPublishedFile')` rows verbatim from an attached backup with
  none of the three predicates (the id check, the linked-row exclusion, the payload-names-id
  agreement). It is reached only after `sanitizeDatabase` → `BackupPortability.portable` dropped linked
  rows and stripped `hostPath`, and every downstream face filters a half-disagreeing row, so no path
  from it to a filesystem write was found. It is an acceptance boundary, not a defect with a symptom.
- **A non-workspace kind may still reference a linked workspace id.** A synced `mcpServer` row's
  `workspaceId` is resolved by `WorkspaceProvider.byId` — which applies the payload/id agreement but
  not `isLinkedWorkspace` — and turned into a read-write mount. Assistant `defaultWorkspaceId` and
  conversation extras are the same shape (scrubbed for backups, not on the wire). This is pre-existing
  on `master` (mcp rows sync there too) and outside this branch's diff; the peer must first *learn* the
  UUID, and conversation extras do carry ids and do sync. It needs a product decision — whether a peer
  may bind an MCP server to this device's linked external folder — rather than a silent fix here.

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
- **Workspace sync** — *overturned by slice 18*: managed workspaces are unbounded local project
  directories and linked ones are host paths, so the blanket rule was right about the *kind* and
  wrong as a rule — the restriction belongs per row (linked never travels) and per face (a managed
  directory travels under caps, a prune list and an unreadable-index guard).
- **Content hashing for workspace files** — reads every byte to answer what mtime answers, which
  is the expensive half of the "avoid a catastrophic walk" requirement (slice 18).
- **Directory-level LWW for workspaces** — one edited file would move a whole tree, and a conflict
  would discard a directory rather than a file (slice 18).
- **Seeding workspace content only on the first sync** — cheapest to build, and the only variant
  with no way back: after the first session the two copies drift with nothing left to detect it
  (slice 18).
- **Folding a workspace content digest into the row digest** (the skill precedent) — the face
  already re-lists every workspace's files each session, so content needs no trigger; mixing it in
  would make a file edit look like a row edit, adding a row transfer and a fabricated LWW loss per
  edit (slice 18).
- **A switch that overrides the workspace caps** — the requirement was to avoid a catastrophic walk
  and transfer, so a switch that re-enables both is that requirement with an off button; the
  tooltip says the record still travels and the switch only controls files (slice 18).
- **A separate workspace ledger file per peer** — the ledger is one pair's state advanced by one
  session and written at one moment; inside the checkpoint, `deletePeer` and `resetCheckpoints()`
  already cover it, and a ledger that outlived a restore would delete the peer's files (slice 18).
- **Capability negotiation instead of a protocol bump** — a "does the peer do this?" handshake
  multiplies the half-synced combinations to reason about (which is the failure mode it would
  create) for a one-time upgrade cost a strict version gate pays once (slice 18, protocol v5).
- **A bare-TCP probe as the dot's evidence** — it answers while every session fails, which is the
  one thing the dot must never do (slice 19).
- **Replacing the whole endpoint set from the repair dialog** — asks the user to retype the
  addresses the app already remembers, in order to fix the one that failed (slice 19).
- **Racing TLS handshakes at dial time** (happy-eyeballs across candidates, first winner taken) —
  the probe already buys the same evidence once per tick, the aborted legs need accept-loop
  hardening, and the case it wins is narrow (slice 20).
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
- **A fourth beat acknowledging the fetch response** — it would confirm the responder's sends
  exactly, but the next session's manifest already carries the same fact (both manifests agree ⇒
  `none` ⇒ the entry is the shared state), and a deletion that intervenes is covered by the
  announcement. An extra round trip per session buys nothing the manifest does not say.
- **Deriving announced deletions from `tombstone_rows`** — the app already writes a tombstone on
  every conversation deletion, so the wire list could be read from there. Rejected: tombstones are
  pruned after 90 days, so a peer offline longer than that would miss the deletion and resurrect
  the conversation, and it would put a second source of truth beside the checkpoint. The
  checkpoint-derived list has no expiry and disappears exactly when the peer catches up.
- **Planning a replaced peer's session against an empty checkpoint** — the obvious reading of "a
  bulk replacement invalidates the checkpoint". Rejected because it also invalidates *this*
  device's own deletions: a conversation this device deleted and the peer still holds would plan
  `peerSends`, and the device would download back what it deliberately removed. The epoch converts
  only deletions to re-sends, which is the direction that recovers data without reversing intent.
- **A per-pair lock inside `SyncStore`** — file locking or a read-modify-write guard on
  `saveCheckpoint`. Rejected: both writers live in one isolate, where the interleaving is decided
  by the engine's own awaits, so the lock belongs where both roles are visible
  (`_initiatorRounds` beside the responder session map) rather than in the store, which cannot see
  that a responder session and an initiator round are the same pair.

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
- An address a peer has moved away from is found by the probe rather than by a failed session: the
  ten-second tick (and the full round every evidence-changing moment triggers) asks the remembered
  set in parallel, so the address that answers becomes the new head without a connect timeout being
  spent on the ones that do not. Since slice 19 that probe is also an authenticated request, so the
  panel's claim is about the *pair* — reachable and still paired — rather than about the addresses
  alone, which is what the bare-TCP version could never say.
- Since slice 20 an unreachable peer costs **one** connect attempt, not one per remembered address:
  the dial spends the probe's answer and, when the probe reached nothing at all, spends a single
  guess on the best-remembered address. The corollary is a known limit: an address the probe cannot
  reach — its SYN is filtered, or it needs the longer hello budget to wake — is not tried at dial
  time unless nothing else was proved, so the remedy for that shape stays the documented drift
  repair (re-scan the QR, or edit the address on the card) and the next tick probes again.
- Workspace content inherits the mtime family's limits: a FAT/exFAT volume's two-second timestamp
  granularity, a clock more than five minutes off (the same yellow flag the rows raise), and two
  edits that leave both size and mtime identical are invisible to the file table. A rename reads as
  a delete plus a create, so a renamed large file is re-sent whole; permission bits, symlinks and
  empty directories do not travel.
- Workspace caps are not escapable and are the panel's own business: over 2,000 files or 200 MB a
  workspace syncs no content at all (its row and its size are shown as a lower bound), and the
  twenty-thousand-entry ledger cap drops whole workspaces back to conservative re-sending rather
  than to deleting. A workspace whose index could not be read contributes nothing that round — no
  table, no deletions, `无法读取` on the panel — which is the price of never being able to mistake an
  unreadable file for a deleted one.
- Linked workspaces are absent from the panel's workspace section (they have no content to sync, so
  a permanently-off switch would be noise): a user with three workspaces and two rows is seeing the
  one kind of workspace the panel cannot do anything about, and the difference is documented rather
  than explained in prose on the panel.
- A workspace record removed by sync takes its directory with it, so a peer's deletion is not
  visible-only: the disk is reclaimed too, which also means a workspace deleted on one device
  cannot be recovered from the other one's directory.
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
- `lastReport` changes on a refused attempt as well as a failed one, so the card's outcome area
  describes the last *attempt*; the "last synced" line beside it is success-only (slice 14), because
  it answers "how fresh is what I see?" rather than "when did the app last try?".
- The checkpoint now also holds what this device owes itself (conversations and the business
  face whose apply it deferred), and the peer reads it from the next hello: a peer that never
  reports a deferral reintroduces the deletion bug, which is why the protocol gate is strict
  equality rather than a compatibility window.
- A deletion the peer deferred propagates one session later than before: the requesting device
  keeps its checkpoint entry until the peer's manifest shows the deletion landed, trading a
  resurrection for a retry.
- Message order is now preserved across an apply, so a version group no longer jumps after a
  peer-side change; the corollary is that a conversation whose stored orders were left in the
  shifted range by the never-shipped slice-2 defect is no longer compacted by an apply either
  (that compaction was the same re-derivation that erased deliberate placements).
- A conversation this device sends in a fetch response is recorded as peer-seen one session later,
  when the peer's manifest confirms it: convergence is unchanged, but a session that ends before
  that confirmation re-sends rather than assuming. The alternative — a second acknowledgement
  round-trip — was rejected as a fourth beat for a fact the next manifest already carries.
- A deletion now needs a checkpoint entry to be announced. A device that never recorded the
  conversation (an unconfirmed transfer, a checkpoint reset) stays silent about it, which is the
  safe direction: it re-sends instead. A device whose checkpoints were reset cannot announce the
  deletions it made before the reset — the epoch already makes the peer re-converge from "nothing
  shared", so the rows return and a fresh deletion propagates normally from there.
- A simultaneous double-initiate between two devices now refuses both rounds instead of losing one
  device's checkpoint advance; the next trigger (launch, resume, or the manual button) retries. A
  device that is only ever resumed in lockstep with its peer could collide repeatedly, which is why
  the refusal is visible on the card rather than silent.
- Every request is bounded, so a peer that stops answering costs one deadline rather than the
  process: the corollary is that a genuinely slow transfer past 20 minutes (push/fetch) or 15
  minutes without a blob byte aborts and is retried by the next session rather than completing.
- A restore or an overwrite import costs one full re-convergence with every paired device: the
  rows both sides still hold are re-exchanged under `edit beats delete`, and the one-session
  override only suppresses deletions.

## Amendment (2026-10, close-to-tray): moved to ADR-0015

The listener's graceful stop is no longer the exit flush's job, and a close that hides to the tray is
no longer answered as a quit. That decision, its platform evidence and its rejected alternatives live
in [ADR-0015](0015-close-to-tray-listener.md); the parenthetical in the slice-16 amendment above ("the
graceful stop is the exit flush's job") is superseded by it.
