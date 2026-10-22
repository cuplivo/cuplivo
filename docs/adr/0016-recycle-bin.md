# ADR-0016: Recycle bin — undo a deletion and a losing last-write-wins comparison, with no schema change

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
- **deleted here, untouched.** Deletion propagates by plan diff against the per-peer checkpoint, not by
  clock: the row the peer no longer has is deleted here — and `planRowSync` reaches that verdict only for a
  row this device has not touched since the checkpoint (`mineDigest == checkpointDigest` → `iDelete`, its
  lines 124-128). A business row edited here is re-sent instead (`iSend`), so an edit beats the deletion and
  there is no lost local content to preserve. The one exception is a conversation whose *row* changed while
  its messages did not: the conversation digest covers the message rows, so a rename, a pin or a version
  selection made here since the last session is deleted along with the conversation.

A third path arrived with #1030 (workspace carriage): a workspace file whose peer stamp wins is fetched and
landed over the local file, and a file the peer deleted is removed here. Both are ordinary convergence
behaviour, and both used to discard the local bytes without keeping them anywhere.

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
   A move is also a commitment: an entry is published by renaming the staging directory into place, and a
   failure *after* the body was moved hands the file back to its original path before that directory is
   discarded. `stageFile` returning null therefore means "not preserved", which is what the landing and
   deletion paths answer with their ordinary delete — a bin that had already deleted the file on its way out
   would make that answer a lie.

3. **Staging reads where the content still exists, and everything else waits for the transaction to
   close.** `ChatDatabaseRepository.deleteConversation` — the single funnel every conversation deletion
   passes through, including a peer's (`syncApplyPeerDeletion`) and an assistant's cascade — captures the
   whole subtree **inside its own transaction, in one statement**: SQLite builds the rows as JSON
   (`json_group_array` over `json_object`, from the same `currentSchemaColumns` lists the sync apply writes
   through), so the capture is consistent with exactly what the cascade is about to remove and costs the
   delete a single round trip it does not notice. Everything after that statement waits: the funnel hands
   the *still-encoded* capture out through `RecycleService.captureConversationDeletion`, the transaction
   commits, and only then does `stageCapturedConversation` decode it and write the entry. The decode and the
   entry's `jsonEncode` are both linear in the conversation's size, and the delete is something the user is
   waiting for while the bin is only the net under it.

   The first version of this said the same thing and did the opposite, in a way worth recording because it
   is a Dart language trap rather than a slip: `_detach(() async { … })` *calls* the closure, and an `async`
   body runs synchronously up to its first `await` — so the `jsonDecode` that was supposed to be detached
   ran on the delete's own stack, inside its transaction. Measured on 200 messages × 5 KB: the delete cost
   37–56 ms more with a bin than without, and the bin's `stageRows` was reached from two
   `DatabaseConnectionUser.transaction` frames. After the split the same probe measures 7.6 ms more than the
   no-bin baseline, of which ~4 ms is the capture query itself, and **zero** transaction frames; `_detach`
   now schedules its closure (`Future<void>.delayed(Duration.zero, …)`) instead of invoking it, so a delete
   returns before any of that work starts. The two runs are different machines, so what is comparable is the
   within-run delta, not the absolute milliseconds.
   `BusinessRepository._deleteEntity` captures the row a user just removed;
   `syncDeleteEntity` / `syncDeletePreference` capture the row a peer's plan is about to delete — the only
   shape a peer's deletion takes, since an edit made here re-sends instead; the two loss points in
   `syncApplyBusinessRows` capture the local row a peer's
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
   answers "bring back what I lost", not "merge two histories".

   **What a restore finds alive decides what it may do, and the entry's own record says which case it is.**
   An entry staged by a **deletion** is refused when its identity is back: the live row is not the version
   the entry lost to — a peer re-sent it, or the user re-made it — so writing over it would discard content
   nothing asked to replace. A conversation, a workspace file, a business row and a synced preference all
   take that rule together. An entry staged by a **losing last-write-wins comparison** is the one case that
   must overwrite, and refusing it would make it permanently unrecoverable: the live row is exactly what it
   lost to, and the bin exists because that loss was not the user's choice. So that restore writes the
   staged content back *and* stages the version it displaced — the live row — as an entry of its own, which
   is what makes "a restore can only duplicate, never lose" true of every entry rather than most of them,
   and what makes one restore undoable by the next. A live row that already says what the restore would
   write displaces nothing and stages nothing.

   The deletion's tombstone is removed with the restore it recorded, and the entries that staged that
   identity are retired — all except the one a restore itself produced — so one row cannot be restored
   twice into two competing copies. Removing the tombstone is bookkeeping, not mechanism: nothing on the
   sync path reads tombstones (an announced deletion is derived from the checkpoint), so the restored
   row's clock is what keeps the conversation from being announced again.

   **For a conversation the clock that decides is the sync digest, and the row's `now()` was inert until
   protocol v8.** The digest is computed from the message rows, so a restore that writes the row back with
   `now()` and the messages back byte-identical left it unchanged — and the peer's announced deletion,
   which compared digests only, deleted the restored conversation again at the next session (the plan said
   `iSend`, the announcement rewrote it to `iDelete`). The announcement now carries the agreement's row
   clock beside the digest, so a copy whose digest matches but whose row is newer counts as written here
   since, which is what a restore is (ADR-0003). Nothing in the recycle bin changed for this: the restore
   already stamped `now()`; the announcement had to start reading it.

   The plan table's own delete branch had to learn the same thing, and it is the case the announcement
   cannot cover: when *this* device deleted the conversation, the peer deleted on request and has nothing
   to announce, while the checkpoint entry survives on `peerDeletes` — so the restored copy met a plan that
   said `iDelete` and was removed again, silently, once. Both readers now ask one function
   (`copyWrittenSinceAgreement`), so the two faces cannot drift apart again.

   **The business face was the second caller of that same rule, and it had the same hole.** A business
   row's digest is its *content* (`entityRowDigest(payload, sortOrder)`, `businessContentDigest(value)`), so
   a restore writes the same digest back with a new clock and the digest-only delete branch read it as
   "unchanged". `planBusinessSync` — entities *and* synced preferences — and the skill-content plan now pass
   the same clock pair, from manifests and checkpoint entries that already carried it. The window is
   narrower than the conversation one for a reason worth recording: a business checkpoint *drops* its entry
   on `peerDeletes` (`SyncEngine._advanceBusinessCheckpoint`), where the conversation face keeps it, so it
   takes this device deleting and restoring a row, and the peer deleting the same row, all before one
   session runs. The peer's own clock is deliberately not passed on that face: a row whose digest covers
   its content is not something a clock-only difference should make the two sides exchange, so the
   equal-digest branch's `bothSend` stays a conversation rule — pinned by a test, which is what keeps the
   next caller from enabling it by accident.

6. **The bin is bounded on three axes: 90 days, 256 MB, 1000 entries.** Eviction is oldest-first and runs
   when the page opens, so an install that stops deleting still shrinks, and once at the end of a staging
   burst. It used to run on *every* staged entry, and eviction starts by reading and parsing the whole
   bin — so an assistant's cascade, one entry per conversation, was O(entries × bin size): measured at
   ~90 ms per entry into an empty bin and ~190 ms into one holding ~220 entries, i.e. 1.8 s and 3.8 s for a
   twenty-conversation cascade. Staging now only *asks* for a sweep, and `RecycleService` runs it when the
   burst's last write lands: the same twenty entries cost one scan (226 ms into an empty bin, 570 ms into a
   full one, and the remaining cost is the entry writes). The caps therefore hold a moment after the burst
   rather than after each write — the same "eventually" the writes themselves already had. The entry just
   staged is exempt from eviction but still counted, because a cap that instantly ate the newest deletion
   would make the newest mistake the one thing the bin could not show. A directory that no longer parses is
   dropped by eviction rather than by listing: listing stays read-only.

7. **It has a screen, reached from Storage space, and it does not count as reclaimable space.** The bin is
   a managed category there (v3's shape: `TrashDetailPage` hosted by the storage page) that reports what it
   costs and opens the list; like displaced databases it is deliberately absent from the "space you can
   reclaim" total, because every entry is something the user already lost once and is emptied from its own
   screen, where each entry says what it is. The category is always shown, even when empty — a recovery
   feature that appears only after something has been lost is the feature nobody finds.

8. **One deletion event is one group, and an entry still owns exactly one key.** Deleting an assistant
   removes its conversations too, and leaving that fact out of the bin makes the list read as N unrelated
   deletions. The alternative — folding the conversations into the assistant's entry — was rejected: an
   entry's body is one key's data, restore reasons per key (`skippedExisting`, asset filtering, the
   tombstone, retiring that key's older entries), a conversation can also be deleted individually, and the
   caps count entries, so one large assistant entry would evict the bin around it. Instead the envelope
   gains an optional `group: {id, label}`, and every conversation a cascade stages carries the same one;
   the list draws one header, names the assistant from the label, and offers a restore that loops the
   existing per-entry path. **The assistant's own row carries it too.** The list write that removes the
   assistant is a delete call for the rows it drops — `synchronizeEntities` removes the row through
   `_deleteEntity`, the same funnel a cascade uses — so the caller that decided to delete passes its group
   down to it, and the row is staged as a member of the event rather than as a stray entry beside it. That
   is what makes the header's button the act it promises: the assistant comes back first, then the
   conversations that name it. It is also why the header counts **conversations** only — the assistant is a
   member of the event, not another conversation in it — and why the header is drawn only where a
   conversation of that group is visible (the Assistants tab shows the assistant as a card of its own
   instead of under a header that talks about the list that tab filters out).
   Only a local cascade stamps a group: a peer's equivalent arrives as independent plan items, with
   nothing on the wire saying they were one act.

9. **An entry can be opened, because "restore" is a decision the user cannot make from a title.** The
   detail view reads the staged copy — the same bytes a restore would write, never a reconstruction — and
   shows the JSON it stores: the envelope's facts (identity, origin, clock, size), each staged table with
   its row count, and the messages' rows, which are the part a reader recognises. A body over the preview
   budget is cut on a character boundary and says so; a moved file is shown as text when it decodes as
   UTF-8 and as its size when it does not; an unreadable body says it is damaged instead of showing an
   empty page. A conversation whose assistant no longer exists warns before the restore, because the
   conversation would come back bound to an owner this device does not have.

   The budget is applied while the body is **read**, not after it is in memory. A file body is opened as a
   range of `cap + 4` bytes and only that head is decoded (with up to three trailing bytes dropped, so a cut
   inside a rune does not read as a binary file); a row set is encoded through a bounded sink. The bin's own
   caps let one workspace file be 200 MB, and `readAsBytes` + two `utf8.decode`s + a pretty-printed copy
   held for the copy button was hundreds of megabytes of transient allocation on the UI isolate to show the
   first 200 KB. What the page shows is also what its copy button copies: a second whole-body copy for that
   button would reintroduce exactly the cost the cap exists to avoid. A conversation's `body.json` is still
   parsed whole, because JSON cannot be previewed from a prefix — that is the one cost the split body shape
   leaves, and it is bounded by the caps rather than by the page. Measured on staged conversations rather
   than argued, on a debug desktop build: 6 ms at 0.5 MB, 15 ms at 4.1 MB and 40 ms at 16.3 MB for the read
   the page needs before it can count the rows it draws (the review's own run of the same probe read 6, 19
   and 49) — a frame of jank at the caps, not a stall, so the byte-file half is the only half that had to
   be bounded.

10. **A workspace file is staged by moving it, at the one landing path and behind the four gates.**
    `WorkspaceContentSync` has one landing path (`land`) and one deletion (`_deleteOne`), and both stage,
    under `RecycleOrigin.remote`. Staging *moves* the file, which is what makes it fit: the move keeps the
    bytes and the mtime, and it frees the path, so the rename that follows needs no delete at all. It is
    awaited rather than detached, unlike every row path above, because that move has to finish before the
    session records the path as landed or as deleted. A staging that failed falls back to the plain delete:
    an unpreserved file is bad, a merge that cannot land is worse, and this is the path the peer waits on.
    The hook sits *after* the four gates and the size check, because a landing that is refused must not
    leave a copy in the bin of a file nothing replaced. A restore goes back through the same gates — the
    same `workspacePathWithin`, `nearestExistingAncestor` and `isReallyInsideWorkspace`, since a restored
    path arrives from the wire just as a fetched one does — is refused when the workspace itself is gone
    (`workspaceGone`: a folder no row describes is an orphan the next round removes, so putting the file
    back would lose it again, more quietly), and is stamped `now()`: decision 5 applies to a file
    unchanged. What it finds at the path follows decision 5's split, and this is the half that had to be
    fixed rather than documented: an entry staged by a **deletion** is skipped when the path is occupied
    again, but an entry staged by a **losing comparison** is *always* looking at an occupied path — the
    landing moved the old version out and renamed the new one in — so refusing it made that entry
    permanently unrestorable, which is the one thing the split exists to prevent. That restore now moves
    the live file into the bin first (`overwritten`, local origin) and copies the staged bytes in after
    it; a bin that cannot take the live version stops the restore (`failed`, nothing written) rather than
    being written over. The sweep waits until the bytes are back, because it is the sweep that could
    evict the entry being restored. No group: each overwrite and each deletion is its own event, and
    nothing on the wire ties them together.

11. **A conversation's unsent draft is part of its snapshot.** The row is one device-local
    `extension_entity_rows` entry (`kind = composerDraft`, id = the conversation id), and the delete removes
    it in the same transaction that removes the conversation — so a restore that left it out handed back a
    conversation whose composer was empty, which is losing text the user typed and never sent. It travels in
    the same one-statement capture, filtered by that kind rather than by the id alone (a future device-local
    row keyed the same way should be a decision, not an accident), and a restore writes it back only when no
    live draft exists: the composer is state the user is in the middle of, and replacing what they have
    typed would be a worse surprise than an older unsent message staying lost. What the bin cannot carry is
    the draft's private attachment files — the delete empties that directory too — so a restored
    `images`/`documents` reference whose file is gone is dropped instead of being drawn as a broken chip;
    the text, the selection and the citation stay. The device-local store also has to take the id back
    (`ComposerDraftStore.reloadRestored`): a delete fences an id for the store's whole lifetime, and without
    that seam the composer of the restored conversation cannot open at all.

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
- A restored conversation also brings back its unsent draft (decision 11): the text and its citation, plus
  the attachment references whose files still exist. The draft's own private files are not staged, so an
  attachment the delete removed is dropped on the way back.
- Restoring a row that a **losing comparison** staged leaves the version it displaced in the bin (decision
  5): the bin then holds the copy that is not live, which is what makes the restore reversible. That is the
  one way a restore *grows* the bin, and it is bounded by the same caps as everything else. A workspace
  file the merge replaced is the same case and takes the same path: the live file moves into the bin and
  the staged bytes go back on disk.
- The displaced copy is staged *after* the live row is written for a row, so a bin that cannot take it
  (an unwritable directory, a full disk) leaves the live row replaced and the entry retired — the one
  window in this feature where a restore is not undoable, and it needs the filesystem to fail at the exact
  moment the database write succeeded. Ordering it the other way would trade that window for a worse one:
  a row read, staged and then written after another writer had already replaced it, which stages the wrong
  version. A file does not have the window at all: the live file is moved into the bin *before* the staged
  bytes are copied back, so a staging that fails stops the restore with the workspace untouched.
- Restoring a conversation this device deleted itself also survives now, and that was the harder direction:
  the peer has nothing to announce (it deleted on request) while this device keeps the checkpoint entry, so
  the plan's own delete branch was the thing that removed the restored copy. Both faces ask one function
  (decision 5), which is also why a rename or a pin — a row write that leaves every message alone — now
  survives a peer's deletion: it moves the same clock.
- A device whose clock lags the agreement by more than a session can absorb still loses the restored copy,
  in either direction, and it is staged into the bin again on the way out. That is the skew the session
  report already warns about, not a hole in the rule.
- Message-level deletion is deliberately **not** a bin operation. Deleting one message is an edit inside a
  conversation the bin still holds; a deleted conversation is recovered with its messages because they are
  part of its snapshot, not because messages are staged individually. v3 had a `message` type; this line
  does not, and a test pins the boundary.
- A local `removePreference` (an explicit key removal) is likewise not staged; only the comparison's losers
  and the rows a user removes through their own lists are.
- Deleting an assistant stages the assistant row and, separately, each of its conversations (the cascade
  goes through the same delete funnel). What joins them is the group (decision 8), and all of them are in
  it, the assistant included: **Restore all** restores the event — the assistant first, then the
  conversations that name it — which is the one thing the header's button can promise. Restoring the
  assistant on its own still does not resurrect its conversations: they are their own entries, and one
  restore stays one restore.
- Restoring a *peer's* deletion undoes it on the peer too: this device re-enters its manifest with a fresh
  row clock, the announcing peer now reads that clock beside the digest (protocol v8), so the deletion it
  made is re-learned as an edit and the conversation comes back everywhere. That is what "recover" means
  here; the bin itself never travels. Two limits worth knowing: a conversation with no message rows has no
  digest to move, so for it the clock is the only signal — which is exactly why the clock is compared — and
  a device whose clock lags the announcing one by more than the agreement can absorb will see the restored
  copy deleted again (it is staged into the bin once more, so it is recoverable, and the skew is what the
  session report already warns about).
- A full restore (overwrite) replaces the database while the bin stays on disk. Its entries then describe
  ids that may not exist in the restored state; restoring one is an upsert, so the outcome is a new row
  rather than a corrupted one.
- The workspace-file side rides the same entry shape the rows do: the store's `stageFile` and `bodyFile`,
  and a `RecycleService.restore` that writes the bytes back through the four landing gates. A workspace
  file's entry therefore behaves like the rest of the bin — same caps, same 90 days, same detail view and
  same device-locality — with one difference a reader should expect: its body is the file itself, so the
  preview shows text only when the bytes decode as UTF-8.

## Not in scope

- Syncing the bin, in any form. It is device-local by decision, not by omission.
- Compressing row snapshots. The envelope's `v` field leaves room for it.
- Staging a **draft** conversation. A draft is composer state, not rows: a conversation with only a draft
  has no `conversation_rows` row to restore into, so its capture would be an empty subtree. It is deleted
  with its assistant and its text is gone.
- Inferring a group on the receiving side. A peer's cascade reaches this device as independent deletions,
  and the only way to join them would be to read the conversations' `assistant_id` from rows that are about
  to be deleted (and that may already have been reassigned). The group stays a local deletion's fact.
- Message-level, per-version or attachment-only recovery.
- Staging the private attachment files of a composer draft (decision 11). Only the row travels; the files the
  delete removed are gone, and the references to them are dropped on the way back.
- The proactive-care re-arm's reaction to a schedule whose owner is gone. Restoring a conversation whose
  assistant no longer exists is one of the ways that state arises, and `rescheduleAll` refuses the app-wide
  re-arm while any such schedule is still future-dated — a decision pinned by its own test. Separating "the
  owner really is gone" from "the assistant store has not loaded" needs a change to that call's contract,
  not to this bin.
- Staging the files of a **workspace that is deleted** (`WorkspaceContentSync.deleteContent`). That is one
  act about a workspace, not N deletions of files: staging it would fill the caps with a single action and
  evict everything else in the bin, and the workspace's own row is staged through the ordinary entity path
  so the deletion itself is still recoverable. What is lost with the folder is the files in it.
- Staging `generation_run_rows`. A run is process bookkeeping for a generation that is happening now, not
  history the user could want back: the delete removes those rows with the messages they target
  (`target_revision_id`), and a restored run would describe a stream no writer is feeding. Decision 3's list
  of tables is therefore what the *capture* recovers, not an exhaustive map of everything a delete touches.
- A lazily laid-out preview. The detail page draws its budgeted body as one selectable block, so a
  conversation whose body reaches the 200 KB cap is one very tall paragraph; splitting it into lazy rows or
  lowering the cap are both open, and neither is worth doing before someone measures a frame time.
