# ADR-0013: Recycle bin — undo a deletion and a losing last-write-wins comparison, with no schema change

**Status:** Accepted (2026-xx)
**Deciders:** cuplivo

## Context

Cuplivo 3.x had a trash: `DeletedRecordsStore` dual-wrote `deleted_record_rows` (the recovery payload) and
`deletion_marker_rows` (an id-only tombstone), `TrashRestoreCoordinator` restored across seven entity types,
and `TrashDetailPage` listed them. The 4.x line re-baselined on Kelivo stable and restarted the SQLite
contract at schema 1, so both tables are gone — and with them the only way back from a mistaken delete.

What makes the gap worse in 4.x than it was in 3.x is LAN sync (ADR-0003). Two of its merge rules destroy
local content that the user never asked to destroy:

- **modified-modified.** A row that changed on both sides keeps the newer clock. The losing side's content is
  read, counted in the session report (`entityRowsLost` / `preferencesLost`), and then overwritten. The
  report tells the user an edit was replaced and offers nothing to do about it.
- **modified-deleted.** Deletion propagates by plan diff against the per-peer checkpoint, not by clock: a row
  the peer no longer has is deleted here *whether or not this device edited it since the last session*.
  Nothing about the local edit protects it.

A third path arrives with #1030 (workspace carriage): a workspace file whose peer stamp wins is fetched and
landed over the local file, and a file the peer deleted is removed here. Both are ordinary convergence
behaviour, and both silently discard the local bytes.

So there are three questions to answer at once: where the recovery copy lives, what it costs, and how to keep
it out of shared state. The last one is the constraint that shapes everything else: **the bin must not ride
sync.** A recovery copy that propagates would resurrect on one device what another device deliberately
deleted, and would put "your deleted conversation" into a peer's storage.

## Decisions

1. **No schema change: the bin is a device-local file tree at `<appData>/recycle`.** `AppDatabase`
   stays at schema version 3 and nothing in the database describes the bin, so `BusinessSnapshot`, the
   migration engine, the settings merger, the backup archive and every `for (final kind in
   BusinessEntityKind.values)` loop are untouched by construction rather than by a new exclusion to
   remember. The standing is exactly `<appData>/sync`'s (device identity, per-peer checkpoints): outside
   the backup face and outside every sync manifest. `extension_entity_rows` was the other candidate — it
   is the schema-3 "no migration needed" host — and was rejected: its rows live inside `kelivo.db`, which
   the backup archive carries and the sync manifest enumerates, so the bin would have to be *excluded*
   from both, and an exclusion is a rule that can be forgotten.

2. **One directory per entry, and one file for everything small.** An entry is
   `<deletedAtUs>-<uuid8>/entry.json`. A business row, a synced preference or a conversation row set
   keeps its tables **inline** in that file, so a losing memory entry or setting is exactly one file. The
   two shapes that can be large travel beside it: a conversation subtree as `body.json` (so listing never
   parses a multi-megabyte chat), a workspace file as `body`, **moved** rather than re-encoded — a rename
   preserves the bytes and the mtime, and it is O(1) where a copy is O(size). Nothing is compressed: a
   moved file cannot be compressed without giving up both properties, and the row snapshots are bounded by
   the caps below rather than by a codec. The envelope carries `v`, so a future build may add one.

3. **Staging reads where the content still exists, and writes off the caller's path.**
   `ChatDatabaseRepository.deleteConversation` — the single funnel every conversation deletion passes
   through, including a peer's (`syncApplyPeerDeletion`) and an assistant's cascade — captures the whole
   subtree **inside its own transaction, in one statement**: SQLite builds the rows as JSON
   (`json_group_array` over `json_object`, from the same `currentSchemaColumns` lists the sync apply writes
   through), so the capture is consistent with exactly what the cascade is about to remove and costs the
   delete a single round trip it does not notice. The *write* is detached: the operation hands the captured
   rows to the bin and returns, because the bin is a net held under the operation and the operation must
   not wait for its own net. `BusinessRepository._deleteEntity` captures the row a user just removed;
   `syncDeleteEntity` / `syncDeletePreference` capture the row a peer's plan is about to delete (the
   modified-deleted case); the two loss points in `syncApplyBusinessRows` capture the local row a peer's
   newer version is about to replace (modified-modified), and **only when the content actually differed** —
   a bothSend echo coming back at a tied clock is not a lost edit, which is the same line the loss counters
   already draw. Bulk replacement (`_clearEntities`, `_replaceEntities`, `clearAllData`, restore) stages
   nothing: replacing the whole local state is not a deletion intent, the rule the conversation tombstones
   already follow. The bin is attached by `main`, through a factory on the gateway — never by the gateway
   itself: test harnesses acquire the gateway too, and a collaborator that keeps writing after an operation
   has returned must not be handed to every one of them.

4. **Staging is best effort, and only the capture is transactional.** An unwritable or unencodable entry
   logs and returns, and the delete or the merge proceeds: the bin is a safety net under an action the user
   asked for, not a condition of it. The capture sits inside the operation's transaction, so what is staged
   is exactly what is about to be removed; the write does not, so a hard kill between the commit and the
   finished write loses that one copy. The reverse order — write first, then delete — would instead leave an
   entry for a row that still exists, which restore handles as an upsert: it can only duplicate, never lose.
   Both windows are small, and the one that costs a *recoverable* copy is the one a delete cannot pay for,
   because paying for it means making every delete wait on the filesystem.

5. **A restore is a fresh local write, never a clock resurrection.** Where a clock decides the next
   comparison the restored row is stamped `now()` — the conversation row, every business row, every
   preference. Writing back the *staged* clock would hand the next session's comparison to the same newer
   version that won last time, and the recovered content would silently disappear again on the next sync.
   A conversation that is already back is refused (`skippedExisting`) rather than merged over: this feature
   answers "bring back what I lost", not "merge two histories". The deletion's tombstone is removed with
   the restore it recorded, and the entries that staged that identity are retired, so one row cannot be
   restored twice into two competing copies.

6. **The bin is bounded on three axes: 90 days, 256 MB, 1000 entries.** Eviction is oldest-first and runs
   when something is staged and when the page opens, so an install that stops deleting still shrinks. The
   entry just staged is exempt from eviction but still counted, because a cap that instantly ate the
   newest deletion would make the newest mistake the one thing the bin could not show. A directory that no
   longer parses is dropped by eviction rather than by listing: listing stays read-only.

7. **It has a screen, reached from Storage space, and it does not count as reclaimable space.** The bin is
   a managed category there (v3's shape: `TrashDetailPage` hosted by the storage page) that reports what it
   costs and opens the list; like displaced databases it is deliberately absent from the "space you can
   reclaim" total, because every entry is something the user already lost once and is emptied from its own
   screen, where each entry says what it is. The category is always shown, even when empty — a recovery
   feature that appears only after something has been lost is the feature nobody finds.

## Consequences

- The capture is transactional and the write is not, so the bin is *eventually* consistent with the
  operations it observed: `RecycleService.settle()` is what a test awaits before asserting on the bin, and
  it is deliberately the only handle on that timing — production never needs it, because nothing there
  inspects the bin on the operation's own path.
- Restoring a conversation brings back its messages, message parts, provider artifacts, prompts, asset
  references and MCP server bindings, and stamps the conversation row `now()`. Its **asset files** are the
  one part the bin does not own: assets are garbage-collected on their own 7-day schedule, so a restore
  after that window returns the text and drops the references whose asset row is gone (a foreign key would
  refuse them, and they would render as broken attachments anyway).
- Message-level deletion is deliberately **not** a bin operation. Deleting one message is an edit inside a
  conversation the bin still holds; a deleted conversation is recovered with its messages because they are
  part of its snapshot, not because messages are staged individually. v3 had a `message` type; this line
  does not, and a test pins the boundary.
- A local `removePreference` (an explicit key removal) is likewise not staged; only the comparison's losers
  and the rows a user removes through their own lists are.
- Deleting an assistant stages the assistant row and, separately, each of its conversations (the cascade
  goes through the same delete funnel). Restoring the assistant does not restore its conversations; they
  are their own entries, and the entry records no back-reference to the assistant.
- A restore re-enters the sync manifest with a fresh clock, so peers that had received the deletion learn
  about the recovery on the next session and get the row back. That is what "recover" means here; the bin
  itself never travels.
- A full restore (overwrite) replaces the database while the bin stays on disk. Its entries then describe
  ids that may not exist in the restored state; restoring one is an upsert, so the outcome is a new row
  rather than a corrupted one.
- The workspace-file side of this — staging the local file a peer's version replaces, and landing a staged
  file back through the four path gates — is designed here but implemented with #1030, because the code it
  hooks does not exist before that lands. The store already carries the entry shape (`stageFile`,
  `bodyFile`) and `RecycleService.restore` reports `unsupported` for those entries until it does.

## Not in scope

- Syncing the bin, in any form. It is device-local by decision, not by omission.
- A per-entry preview or diff before restoring; an entry shows what it is, and restore is the action.
- Compressing row snapshots. The envelope's `v` field leaves room for it.
- Message-level, per-version or attachment-only recovery.
