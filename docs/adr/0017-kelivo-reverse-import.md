# ADR-0017: A backup written for Kelivo — the export names its reader

**Status:** Accepted (2026-11-06)
**Deciders:** cuplivo

## Context

A backup is a *claim about the reader*. Two maps in the archive are keyed by business entity:
`settings.json` and the manifest's `businessEntityRowIds`, and a reader meeting a source key it has no
kind for does not ignore it — `BusinessSettingsRouter._rowIdsByKind` throws
`FormatException(entry.key)` on the first unknown key, inside the business-restore step, **after**
every compatibility check on the archive has passed.

The group-chat unit (`5136e617b`, #1052) added `BusinessEntityKind.groupChat`, and
`exportSnapshotWithRowIds` writes a key for every kind, so every backup since carries
`"group_chats_v1": []` — the empty list is not the problem; the key is. Nothing on the compatibility
axes moved with it, so nothing declined the archive on the way in: archive format stayed 3 and
`AppDatabase.currentSchemaVersion` stayed 5, which is exactly what every Kelivo release from v1.3.2 on
reads as *its own*. The result was that **no Cuplivo backup could be restored into Kelivo, including
for a user who had never created a group**, and the failure surfaced as a `FormatException` part-way
through a restore rather than as a refusal.

Two mechanisms existed for exactly this and neither covers it:

- `_minimumReadableFormatVersion` / `SchemaMigrations.minimumReadableSchemaVersion` are declarations a
  *newer* archive makes about older readers, and they are only consulted when the reader is older and
  the structure is strippable. Here the reader saw the format as current.
- `_stripUnknownManifestKeys` drops unknown manifest **keys**, never unknown **values inside a known
  key** — and `businessEntityRowIds` is a known key.

Every restore test in this tree is Cuplivo reading Cuplivo, so the reverse direction had no gate at
all: `flutter test` stays entirely green while the archive is unusable.

## Decisions

1. **The export has a target, and the target is data.** `BackupTarget.cuplivo` writes every kind in
   the current format. `BackupTarget.kelivo` writes only the kinds, categories and archive format
   frozen in `KelivoVocabulary.v1_3_2` — one constant per release, never edited in place, generated
   from that release's own tree (`business_data.dart`, `backup_scope.dart`, `app_database.dart`).
   The constant is the *floor* of the range the target claims: v1.3.2 is the first release that opens
   SQL schema 5, and every release from there to the v1.3.6 baseline carries the same vocabulary at the
   same archive format, so an archive built for the floor imports into all of them. The label
   「Kelivo {version}+」 is built from `KelivoVocabulary.release`, not typed beside it.

   The pin's `manifestRootKeys` is the fourth axis, and it is why the writer keeps `skippedEntries`
   out of an archive written for a foreign reader. That reader stages a candidate before restoring
   and then compares the manifest's root key set **exactly**; its unknown-key trim only runs for an
   archive that declares a newer build, which a format-3 archive does not. So a root key its rewrite
   does not remove and its validator does not expect is refused after the user has already consented
   to the restore. `skippedEntries` is such a key — a diagnostic upstream added in 1.3.6, newer than
   the floor — and the source key set is now pinned beside the entity keys, the categories and the
   format number rather than discovered in a departing user's restore.

2. **One list decides what is unreadable, and three call sites read it.**
   `unreadableEntitySourceKeys(target)` is the difference between `BusinessEntityKind.values` and the
   target's vocabulary; the settings export strips those keys from both halves of the archive, and
   `BackupPortability.sanitizeDatabase` drops their rows and the conversation link that points at them.
   A stripped key with a surviving row would be an archive contradicting its own manifest. Both halves
   of the database repair are derived from `unreadableKindDispositions` — the row storage from the
   kind's `extensionKind`, the link from the entry's declared `conversationLink` — so a kind leaves the
   archive everywhere at once instead of at the call sites someone remembered to update. A kind with no
   extension storage, or one the table says nothing about, throws rather than being half-stripped: the
   prose rule that a table-backed kind needs its own handling is now a `StateError`, because a
   half-repair is invisible once it ships.

3. **The archive format moves to 4 and declares 4, but this build still reads 2 and 3.** The default
   export must be *refused early* by an older reader rather than fail part-way. Format 3 stays readable
   because a Kelivo-target archive is written in 3 — refusing it would make a backup this build just
   produced unreadable to itself. The numbers live in `BackupArchiveFormat` because
   `RestoreBundleStaging` restates them for the staged candidate; a bump that touched one side would
   have this build reject its own archives. The staging candidate's resumable formats are derived from
   the same place, so a restore interrupted across an upgrade still resumes.

   The manifest `scope` block is validated for every format that *declares* one
   (`BackupArchiveFormat.declaresScope`), never for "the format this build writes": keyed on the
   current number, that check silently left format 3 — the format of every backup written before this
   release — the moment the number moved to 4, and a block that is absent reads as *everything
   included*. Same for the readability floor the export declares: only the format this build writes
   may promise a lower floor than itself, so a target whose format is newer than `BackupArchiveFormat
   .current` is refused by the pin test rather than stamped with a promise about a parser that does
   not exist here.

4. **The vocabulary is pinned by a test, not by a comment.**
   `test/core/database/kelivo_vocabulary_test.dart` refuses a `BusinessEntityKind` that is neither in
   the pinned vocabulary nor in `unreadableKindDispositions`, so a new kind — the next #1052 — cannot
   ship without someone writing down what a Kelivo user loses. It also asserts the schema axis, which
   the pin did not carry before #1095: the target stamps every archive with
   `AppDatabase.currentSchemaVersion`, so a schema bump that leaves the floor behind makes the label
   false for *every* archive the target writes. That failure is the decision point — keep the pinned
   schema, move the floor (and the label with it), or retire the target — never a number to raise
   quietly.

5. **Group chats do not travel backwards, and that is said out loud.** A group has no Kelivo
   equivalent; its rows and the `groupChat.id` link leave with the archive, while the conversations
   remain as ordinary chats. A reader that tolerates an unknown entity key is upstream's change to
   make, not ours — a fork cannot patch the reader it is leaving for.

6. **The target is a standing choice in the backup settings, not a question asked at export time.**
   It lives beside 「Backup scope」 and rides both provider configs (`WebDavConfig`, `S3Config`),
   because the WebDAV and S3 uploads never open a sheet and would otherwise write for the wrong
   reader — an S3 provider that carried the scope but not the target is exactly that bug. The cost is
   stated once, inside the picker, in the user's terms: 「可在 Kelivo 中导入，但会丢失群聊数据」. No
   banner: the rule that a standing choice applies to *every* later backup is recorded here and in the
   changelog, not repeated on the page. `prepareBackupFileFromDatabase` and the local-snapshot path
   never consult the target; both rebuild an archive this build owns, and a lowered target there would
   silently drop data a rollback depends on.

## Consequences

- A user taking their data back to Kelivo gets a working archive, minus group structure. Ordinary
  backups are unaffected.
- A build older than this one, including earlier Cuplivo versions, refuses a **new** backup with
  `manifest_version` instead of failing mid-restore. That is the intended trade and belongs in the
  changelog.
- Adding a business kind now costs a disposition line: in the vocabulary if the release knows it,
  otherwise a sentence about what the older reader loses. This is the check that makes the
  rebase-runbook's rule 17 mechanical.
- Pinning a later Kelivo release means adding a constant next to `v1_3_2` and re-generating it from
  that tag — never editing the old one, or archives already written change meaning. The floor only
  moves when the target itself must move (a schema bump past the floor); the label follows the
  constant, so it cannot be updated on its own. A config written before the tokens were unversioned
  (`kelivoV1_3_4`, shipped in 4.7.0) still reads back as the Kelivo target rather than falling back to
  Cuplivo, which would put group chats back into a departing user's archive.
