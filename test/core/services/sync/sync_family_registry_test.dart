import 'dart:io';

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

  test('the kind scan claims declarations and camelCase uses only', () {
    final found = extensionKindsInSource('''
      class A {
        static const kind = 'composerDraft';
        static const entityKind = 'conversationContext';
        extensionKind: 'skill',
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
    ''');
    expect(found.keys.toSet(), {
      'composerDraft',
      'conversationContext',
      'skill',
      'contextCompressionTask',
      'composerPublishedFile',
      'composerPrivateFile',
      'composerShareReceipt',
    });
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
