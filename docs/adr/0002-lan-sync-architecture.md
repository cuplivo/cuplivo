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
5. **Per-device keypair, QR/PIN pairing, mutual TLS.** deviceId = hash of the public key;
   pairing exchanges pinned certificates once; discovery (mDNS `_cuplivo._sync._tcp`)
   automates reconnection afterwards. The sync face carries API keys, so the channel must
   resist LAN sniffing and impersonation.
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
9. **Event-driven sessions.** Peer discovered → sync; local writes → debounced follow-up;
   manual button as escape hatch. No polling, no background daemon on mobile.

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
- File avatars degrade on the peer in v1 (report-flagged); carrying them is additive later.
