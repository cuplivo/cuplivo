import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/sync/sync_family_registry.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/sync_payload.dart';

/// A conversation's identity, composed from the family table.
///
/// Two things are being held here. First, that the composition is *complete*: a
/// change in any synced family must move the digest, or the plan cannot see it
/// and the change waits for something else to happen in that conversation. The
/// families that were device-local until this version are exactly the ones that
/// used to wait.
///
/// Second, that the two readers agree. The manifest composes the same inputs in
/// one SQL aggregate per family — a manifest must not materialise a row per
/// message — while a checkpoint re-reads the rows in Dart. If they ever disagree,
/// a settled conversation would look changed forever, and both peers would keep
/// sending it.
void main() {
  const conversationId = 'conv';

  /// One valid row per synced conversation family, keyed by family name.
  Map<String, Map<String, dynamic>> fixtures() => {
    'messages': {
      'id': 'm1',
      'conversation_id': conversationId,
      'updated_at': 10,
      'timestamp': 10,
    },
    'messageParts': {
      'revision_id': 'm1',
      'ordinal': 0,
      'conversation_id': conversationId,
      'updated_at': 10,
      'created_at': 10,
      'payload': 'hi',
    },
    'mcpBindings': {
      'conversation_id': conversationId,
      'server_id': 's1',
      'ordinal': 0,
    },
    'providerArtifacts': {
      'conversation_id': conversationId,
      'revision_id': 'm1',
      'kind': 'signature',
      'payload': 'sig',
      'updated_at': 10,
      'created_at': 10,
    },
    'conversationContext': {
      'kind': 'conversationContext',
      'id': conversationId,
      'sort_order': 0,
      'owner_id': conversationId,
      'payload': '{"ops":[]}',
      'updated_at': 10,
    },
    'conversationImageContext': {
      'kind': 'conversationImageContext',
      'id': conversationId,
      'sort_order': 0,
      'owner_id': conversationId,
      'payload': '{"auto":false}',
      'updated_at': 10,
    },
    'conversationCompression': {
      'kind': 'conversationCompression',
      'id': conversationId,
      'sort_order': 0,
      'owner_id': conversationId,
      'payload': '{"mode":"off"}',
      'updated_at': 10,
    },
  };

  /// What one family contributes for [row].
  String inputFor(SyncFamily family, Map<String, dynamic> row) =>
      syncFamilyDigestInput(family, [row]);

  /// A change the family's own rule must be able to see.
  Map<String, dynamic> changed(SyncFamily family, Map<String, dynamic> row) {
    switch (family.identity) {
      case SyncIdentityContribution.rowClocks:
        return {...row, family.clockColumn!: 99};
      case SyncIdentityContribution.rowValues:
        return {...row, family.identityColumns.last: 7};
      case SyncIdentityContribution.payloadDigest:
        return {...row, 'payload': '{"changed":true}'};
      case SyncIdentityContribution.none:
      case SyncIdentityContribution.conversationClock:
        fail('${family.name} contributes no identity to change');
    }
  }

  test('a change in any synced family moves the digest', () {
    final rows = fixtures();
    for (final family in syncedConversationFamilies) {
      if (family.isSubtreeRoot) continue;
      final row = rows[family.name];
      expect(
        row,
        isNotNull,
        reason:
            '${family.name} travels in a subtree but this test has no fixture '
            'for it, so nothing proves its content reaches the plan',
      );
      final before = composeConversationDigest({
        family.name: inputFor(family, row!),
      });
      final after = composeConversationDigest({
        family.name: inputFor(family, changed(family, row)),
      });
      expect(before, isNot(equals(after)), reason: family.name);
    }
  });

  test('a family that changes nothing leaves the digest alone', () {
    // The other half of the rule: a re-read that returns the same rows must not
    // move the identity, or every session would re-send every conversation.
    final rows = fixtures();
    final first = composeConversationDigest({
      for (final family in syncedConversationFamilies)
        if (!family.isSubtreeRoot && rows[family.name] != null)
          family.name: inputFor(family, rows[family.name]!),
    });
    final second = composeConversationDigest({
      for (final family in syncedConversationFamilies)
        if (!family.isSubtreeRoot && rows[family.name] != null)
          family.name: inputFor(family, rows[family.name]!),
    });
    expect(first, second);
    expect(first, isNot(emptyConversationDigest));
  });

  test('an empty conversation is the empty digest', () {
    expect(composeConversationDigest(const {}), emptyConversationDigest);
  });

  test('a family name cannot be swapped for another', () {
    // The family name is part of the text: two different families contributing
    // the same lines must not compose to the same identity.
    expect(
      composeConversationDigest(const {'a': 'x'}),
      isNot(composeConversationDigest(const {'b': 'x'})),
    );
  });

  group('the two readers agree', () {
    late AppDatabase database;
    late ChatDatabaseRepository repository;

    setUp(() async {
      database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      await repository.ensureReady();
      await repository.putMigrationBatch(
        conversations: [
          Conversation(id: conversationId, title: conversationId),
        ],
        messages: const [],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
    });

    tearDown(() => database.close());

    /// Every family written through the one apply path, so both readers see a
    /// conversation that really has something in each of them.
    Future<void> seedAllFamilies() async {
      final rows = fixtures();
      await repository.syncApplySubtree(
        payload: subtreePayload(
          conversation: {
            'id': conversationId,
            'title': conversationId,
            'created_at': 1,
            'updated_at': 1,
            'is_pinned': 0,
            'assistant_id': null,
            'truncate_index': 0,
            'version_selections_json': '{}',
            'summary': '',
            'last_summarized_message_count': 0,
            'chat_suggestions_json': '{}',
            'injected_memory_hash': null,
            'last_memory_extracted_order': 0,
            'chat_model_provider': null,
            'chat_model_id': null,
            'extras_json': '{}',
          },
          messages: [
            {
              'id': 'm1',
              'conversation_id': conversationId,
              'role': 'user',
              'timestamp': 10,
              'model_id': null,
              'provider_id': null,
              'total_tokens': null,
              'is_streaming': 0,
              'reasoning_start_at': null,
              'reasoning_finished_at': null,
              'translation': null,
              'reasoning_segments_json': null,
              'group_id': null,
              'version': 0,
              'prompt_tokens': null,
              'completion_tokens': null,
              'cached_tokens': null,
              'duration_ms': null,
              'message_order': 0,
              'updated_at': 10,
              'sender_id': null,
              'extras_json': '{}',
            },
          ],
          parts: [
            {
              'conversation_id': conversationId,
              'revision_id': 'm1',
              'ordinal': 0,
              'kind': 'text',
              'payload': 'hi',
              'created_at': 10,
              'updated_at': 10,
            },
          ],
          mcpServers: [
            {
              'conversation_id': conversationId,
              'server_id': 's1',
              'ordinal': 0,
            },
          ],
          families: {
            for (final family in syncedConversationFamilies)
              if (!family.isSubtreeRoot && family.table != 'message_rows')
                if (family.table != 'message_part_rows')
                  if (family.table != 'conversation_mcp_server_rows')
                    family.name: [rows[family.name]!],
          },
        ),
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        checkpointRows: const {},
      );
    }

    test(
      'the SQL aggregate and the Dart re-read compose the same identity',
      () async {
        await seedAllFamilies();

        final aggregated = <String, String>{};
        for (final family in syncedConversationFamilies) {
          if (family.isSubtreeRoot ||
              family.identity == SyncIdentityContribution.none) {
            continue;
          }
          final inputs = await repository.syncFamilyDigestInputs(family);
          final mine = inputs.where(
            (input) => input.conversationId == conversationId,
          );
          if (mine.isEmpty) continue;
          aggregated[family.name] = mine.single.digestInput;
        }

        expect(
          composeConversationDigest(aggregated),
          await repository.syncConversationDigest(conversationId),
          reason:
              'the manifest reads families in SQL and a checkpoint re-reads them '
              'in Dart; a disagreement re-sends a settled conversation forever',
        );
      },
    );
  });
}
