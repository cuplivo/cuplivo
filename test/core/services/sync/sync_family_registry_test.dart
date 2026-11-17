import 'dart:io';

import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/conversation_owned_kinds.dart';
import 'package:Cuplivo/core/services/sync/sync_family_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guard the plan calls G0: a family that nobody classified fails the
/// build.
///
/// Two defences, because a family can appear in two places:
///
/// * a new `extension_entity_rows.kind` — found by scanning the source, since
///   the kind is a string literal and the storage has no column to declare it;
/// * a new table hanging off a conversation — found in the schema map the sync
///   writer already trusts, so it needs no one to remember anything.
///
/// A family is registered as `synced` or as `deviceLocal` with a reason. There is
/// no third answer, and "nobody said" is not one of the two.
void main() {
  final families = kSyncFamilies;

  test('the registry holds', () {
    expect(
      syncFamilyProblems(
        families,
        conversationTables: conversationAttachedTables,
      ),
      isEmpty,
    );
  });

  test('every extension kind in lib is registered', () {
    final found = <String, List<String>>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      final kinds = extensionKindsInSource(entity.readAsStringSync());
      for (final entry in kinds.entries) {
        (found[entry.key] ??= []).add(
          '${entity.path}: ${entry.value.join(', ')}',
        );
      }
    }
    expect(
      found.keys.toSet().difference(registeredSyncKinds),
      isEmpty,
      reason:
          'an extension_entity_rows kind nobody registered '
          '(add a SyncFamily to kSyncFamilies): $found',
    );
  });

  test('every table hanging off a conversation is registered', () {
    for (final table in conversationAttachedTables) {
      expect(
        families.where((family) => family.table == table),
        isNotEmpty,
        reason: '$table hangs off a conversation but is registered nowhere',
      );
    }
  });

  test('the business families are the entity kinds, one for one', () {
    expect(
      {
        for (final family in syncedBusinessFamilies)
          if (family.table != 'preference_rows') family.kind ?? family.table,
      },
      {for (final kind in BusinessEntityKind.values) kind.wireName},
      reason:
          'the business face reads its rows by kind, so a kind with no family '
          'would travel to nobody and a family with no kind would be read from '
          'nothing',
    );
  });

  test('the kind scan claims declarations and camelCase uses only', () {
    final found = extensionKindsInSource('''
      class A {
        static const kind = 'composerDraft';
        static const kind = 'composer_draft';
        static const entityKind = 'conversationContext';
        static const entityKind = 'conversation_context';
        static const conversationKind = 'conversationCompression';
        static const entryKind = 'composerEntry2';
        extensionKind: 'skill';
        extensionKind: 'group_chat';
        static const String artifactKind = 'image_ocr_v1';
        // The store's own convention: the word first, not last. It is the shape
        // a contributor copies from `extension_entity_store.dart`.
        static const String kindWorkspace = 'workspaceFixture';
        // Not a kind declaration: `kinds` is the plural word, not a kind name.
        static const String kinds = 'notAKind';
        // The same shape, but a blob-plane entry kind, not a row: claiming it
        // would demand a family over a table that never holds it.
        static const String kindFile = 'file';
      }
      void b() {
        final r = kind.equals('contextCompressionTask');
        final s = "WHERE kind = 'composerPublishedFile'";
        final t = "WHERE kind IN ('composerPrivateFile','composerShareReceipt')";
      }
      void c() {
        // The other tables in these files: word-shaped kinds, never extension
        // kinds, and never to be asked for a registration.
        final u = kind.equals('text');
        final v = "WHERE kind = 'tool_call'";
        final w = kind: 'image';
      }
      void d() {
        // The entity store takes the kind first, so a kind written this way is
        // neither a declaration nor a `kind`-named use.
        store.upsert('composerMigrationDraft', 'x', {});
        store.listByKind('composerWatchKind');
        store.delete('a1b2c3d4');
      }
    ''');
    expect(found.keys.toSet(), {
      // A declaration is a kind whatever its casing: a capture that stopped at
      // the first non-letter would drop these two silently, and the family they
      // name would travel nowhere while this guard stayed green.
      'composerDraft',
      'composer_draft',
      'composerEntry2',
      'conversationContext',
      'conversation_context',
      'conversationCompression',
      'skill',
      'group_chat',
      'contextCompressionTask',
      'composerPublishedFile',
      'composerPrivateFile',
      'composerShareReceipt',
      // Positional, claimed like a use: the hash in `store.delete` above is not,
      // which is what keeps a store keyed by hash out of the registry.
      'composerMigrationDraft',
      'composerWatchKind',
      // The store's front-form declaration. A guard that knew only the suffix
      // forms left exactly the shape the tree itself teaches unclaimed.
      'workspaceFixture',
    });
    expect(found.keys, isNot(contains('notAKind')));
    expect(found.keys, isNot(contains('file')));
  });

  test('a table-owning family kinds are not extension kinds', () {
    // `provider_artifact_rows` syncs whole, so `image_ocr_v1` wants no family of
    // its own — but it is declared with exactly the shape of one. Both files
    // that name it are scanned, not just the synthetic snippet above.
    for (final path in [
      'lib/core/database/chat_database_repository.dart',
      'lib/features/home/services/ocr_service.dart',
    ]) {
      final found = extensionKindsInSource(File(path).readAsStringSync());
      expect(
        found.keys,
        isNot(contains('image_ocr_v1')),
        reason: '$path declares a provider-artifact kind, not an entity kind',
      );
    }
  });

  test('a compound-named kind declaration in the tree is a kind', () {
    // The document kind this registry already carries is declared as
    // `static const conversationKind`, not `static const kind`. A pattern that
    // knew only the latter could not see it: a new document family declared the
    // same way would go unregistered while this guard stayed green — the exact
    // failure the registry exists to prevent.
    final found = extensionKindsInSource(
      File('lib/core/models/compression_config.dart').readAsStringSync(),
    );
    expect(found.keys, contains('conversationCompression'));
    expect(
      found.keys,
      contains('compressionTemplate'),
      reason: 'the `entityKind` form still has to be claimed',
    );
  });

  test('an unregistered kind would fail the build', () {
    final found = extensionKindsInSource("extensionKind: 'ghostFamily',");
    expect(found.keys.toSet().difference(registeredSyncKinds), {'ghostFamily'});
  });

  test('an unregistered conversation table would fail the build', () {
    final problems = syncFamilyProblems(
      families,
      conversationTables: {...conversationAttachedTables, 'ghost_rows'},
    );
    expect(
      problems.where((problem) => problem.contains('ghost_rows')),
      isNotEmpty,
    );
  });

  test('a synced family that contributes no identity would fail', () {
    final problems = syncFamilyProblems([
      ...families,
      const SyncFamily(
        name: 'ghostRows',
        table: 'message_rows',
        ownership: SyncFamilyOwnership.synced,
        scope: SyncFamilyScope.conversation,
      ),
    ], conversationTables: conversationAttachedTables);
    expect(
      problems.where((problem) => problem.contains('contributes nothing')),
      isNotEmpty,
    );
  });

  test(
    'a specialised family on a table the merge body does not know would fail',
    () {
      // The dangerous direction of `SyncFamily.apply`: read, sent and digested,
      // and no rule writes it — a conversation that re-plans every session and
      // never converges, with nothing red to say so.
      final problems = syncFamilyProblems([
        ...families,
        const SyncFamily(
          name: 'ghostSpecialised',
          table: 'provider_artifact_rows',
          wireKey: 'ghost',
          ownership: SyncFamilyOwnership.synced,
          scope: SyncFamilyScope.conversation,
          identity: SyncIdentityContribution.rowValues,
          identityColumns: ['revision_id'],
          apply: SyncFamilyApply.specialised,
        ),
      ], conversationTables: conversationAttachedTables);
      expect(
        problems.where((problem) => problem.contains('never applied')),
        isNotEmpty,
      );
    },
  );

  test('a conversation family without a conflict target would fail', () {
    // The applier writes a family's rows through this target; a registration
    // that does not name one is read, sent and digested, and then throws on the
    // first peer apply — on a device instead of in this test.
    final problems = syncFamilyProblems([
      ...families,
      const SyncFamily(
        name: 'ghostNoTarget',
        table: 'message_rows',
        wireKey: 'ghostNoTarget',
        ownership: SyncFamilyOwnership.synced,
        scope: SyncFamilyScope.conversation,
        identity: SyncIdentityContribution.rowClocks,
        identityColumns: ['id'],
        clockColumn: 'updated_at',
      ),
    ], conversationTables: conversationAttachedTables);
    expect(
      problems.where((problem) => problem.contains('conflict target')),
      isNotEmpty,
    );
  });

  test('a conflict target column outside the schema would fail', () {
    final problems = syncFamilyProblems([
      ...families,
      const SyncFamily(
        name: 'ghostBadColumn',
        table: 'message_rows',
        wireKey: 'ghostBadColumn',
        ownership: SyncFamilyOwnership.synced,
        scope: SyncFamilyScope.conversation,
        identity: SyncIdentityContribution.rowClocks,
        identityColumns: ['id'],
        clockColumn: 'updated_at',
        conflictTarget: ['not_a_column'],
      ),
    ], conversationTables: conversationAttachedTables);
    expect(
      problems.where((problem) => problem.contains('not_a_column')),
      isNotEmpty,
    );
  });

  test('a whole-document family on a table with no payload would fail', () {
    // The applier reads `row['payload']` for every document row and drops one
    // that is not a string; a registration on such a table would travel and
    // never land.
    final problems = syncFamilyProblems([
      ...families,
      const SyncFamily(
        name: 'ghostNoPayload',
        table: 'conversation_rows',
        wireKey: 'ghostNoPayload',
        ownership: SyncFamilyOwnership.synced,
        scope: SyncFamilyScope.conversation,
        identity: SyncIdentityContribution.rowClocks,
        identityColumns: ['id'],
        clockColumn: 'updated_at',
        isWholeDocument: true,
        conflictTarget: ['id'],
      ),
    ], conversationTables: conversationAttachedTables);
    expect(
      problems.where((problem) => problem.contains('no payload column')),
      isNotEmpty,
    );
  });

  test('every conversation-scope extension kind is captured or written off', () {
    // The bin's capture and the conversation's delete read
    // `conversationDocumentKinds`, which is derived from this registry — so a new
    // synced document joins them without a second list. A device-local
    // conversation kind does not travel, which makes the bin its only way back:
    // it has to be named as unrecoverable, or a delete leaves a row describing a
    // conversation that is gone.
    final kinds = {
      for (final family in kSyncFamilies)
        if (family.scope == SyncFamilyScope.conversation && family.kind != null)
          family.kind!,
    };
    expect(
      kinds.difference(conversationDocumentKinds),
      conversationUnrecoverableKinds,
    );
  });

  test('a business family that declares an identity would fail', () {
    // A business row's digest is `entityRowDigest(payload, sort_order)`; the
    // registry's `identity` is read only for conversation families. Declaring
    // one on a business family used to be required and inert — a field that
    // promised a digest change nothing would ever make.
    final problems = syncFamilyProblems([
      ...families,
      const SyncFamily(
        name: 'ghostEntity',
        table: 'extension_entity_rows',
        kind: 'ghostEntityKind',
        ownership: SyncFamilyOwnership.synced,
        scope: SyncFamilyScope.business,
        identity: SyncIdentityContribution.rowClocks,
      ),
    ]);
    expect(
      problems.where((problem) => problem.contains('nothing reads')),
      isNotEmpty,
    );
  });

  test('a device-local family without a reason would fail', () {
    final problems = syncFamilyProblems([
      ...families,
      const SyncFamily(
        name: 'ghostDraft',
        table: 'extension_entity_rows',
        kind: 'composerGhost',
        ownership: SyncFamilyOwnership.deviceLocal,
        scope: SyncFamilyScope.business,
      ),
    ]);
    expect(
      problems.where((problem) => problem.contains('without a reason')),
      isNotEmpty,
    );
  });

  test('a kind on a table that has none would fail', () {
    final problems = syncFamilyProblems([
      ...families,
      const SyncFamily(
        name: 'ghostKind',
        table: 'message_rows',
        kind: 'ghostFamily',
        ownership: SyncFamilyOwnership.deviceLocal,
        deviceLocalReason: 'a test violation',
        scope: SyncFamilyScope.conversation,
      ),
    ], conversationTables: conversationAttachedTables);
    expect(
      problems.where((problem) => problem.contains('which has none')),
      isNotEmpty,
    );
  });
}
