import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/database/composer_draft_store.dart';
import 'package:Cuplivo/core/database/compression_repository.dart';
import 'package:Cuplivo/core/database/conversation_owned_kinds.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/compression_config.dart';
import 'package:Cuplivo/core/models/context_operation.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/image_context.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

/// What a conversation deletion leaves behind, and what a restore puts back.
///
/// The boundary this file also pins: deleting one message is not a bin
/// operation, and a bulk reset stages nothing at all.
/// A bin that says when it starts writing, for the test that has to prove the
/// write is not on the delete's own path.
///
/// [onStage] runs at the moment the snapshot is handed over, so it can read the
/// database and answer whether the delete had already committed by then.
class _RecordingStore extends RecycleStore {
  _RecordingStore({required super.directory});

  Future<void> Function(String key)? onStage;
  final List<String> stagedKeys = <String>[];

  @override
  Future<RecycleEntry?> stageRows({
    required RecycleEntryType type,
    required RecycleOrigin origin,
    required RecycleReason reason,
    required String key,
    required String title,
    required Map<String, List<Map<String, Object?>>> tables,
    String? kindWire,
    RecycleGroup? group,
  }) async {
    stagedKeys.add(key);
    await onStage?.call(key);
    return super.stageRows(
      type: type,
      origin: origin,
      reason: reason,
      key: key,
      title: title,
      tables: tables,
      kindWire: kindWire,
      group: group,
    );
  }
}

void main() {
  group('conversation deletion recovery', () {
    late Directory directory;
    late Directory binRoot;
    late AppDatabase database;
    late ExtensionEntityStore extensions;
    late _RecordingStore store;
    late RecycleService recycle;
    late ChatDatabaseRepository repository;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('kelivo_recycle_conv_');
      binRoot = Directory('${directory.path}/bin');
      database = AppDatabase.open(file: File('${directory.path}/chat.sqlite'));
      extensions = ExtensionEntityStore(database);
      store = _RecordingStore(directory: () async => binRoot);
      recycle = RecycleService(database, store: store);
      repository = ChatDatabaseRepository(database, recycle: recycle);
      await repository.ensureReady();
    });

    tearDown(() async {
      await repository.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    /// The bin writes *after* the operation that fed it — a delete must not wait
    /// for its own safety net — so an assertion about the bin lets that write
    /// finish first. The "stages nothing" tests go through here for the same
    /// reason and one more: without it they would pass merely because the write
    /// had not started yet.
    Future<List<RecycleEntry>> binEntries() async {
      await recycle.settle();
      return recycle.list();
    }

    Future<void> seedConversation(String id, {int messages = 2}) async {
      final createdAt = DateTime.utc(2026, 8, 1);
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: id,
            title: 'Topic $id',
            createdAt: createdAt,
            updatedAt: createdAt,
            messageIds: [
              for (var index = 0; index < messages; index++) '$id-m$index',
            ],
          ),
        ],
        messages: [
          for (var index = 0; index < messages; index++)
            (
              message: ChatMessage(
                id: '$id-m$index',
                role: index == 0 ? 'user' : 'assistant',
                content: 'message $index',
                conversationId: id,
                groupId: '$id-m$index',
                version: 0,
                timestamp: createdAt.add(Duration(minutes: index)),
              ),
              messageOrder: index,
            ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
    }

    /// The three documents a conversation keeps outside its messages, written
    /// through the store the app writes them with, so a payload's shape is the
    /// model's rather than the test's.
    Future<void> seedDocuments(String id, {String? ownerId}) async {
      await extensions.upsert(
        ImageContextSettings.entityKind,
        id,
        ImageContextSettings(
          automatic: false,
          pinned: {'$id-m1|content|0'},
        ).toJson(),
        ownerId: ownerId ?? id,
      );
      await extensions.upsert(CompressionConfig.conversationKind, id, const {
        'mode': 'auto',
        'templateId': 'builtin-default',
        'keep': 'tail',
      }, ownerId: ownerId ?? id);
      // The context repository writes a JSON *array* of operations
      // (`_encodeContextOperations`) and its reader casts the payload to `List`,
      // where the store's `upsert` takes an object — so this row is written with
      // the writer's own encoding of the model, and the restore test reads it
      // back through `readContextOperations` to prove the shape survives.
      await database.customStatement(
        'INSERT INTO extension_entity_rows'
        '(kind,id,sort_order,owner_id,payload,updated_at) VALUES(?,?,0,?,?,?) '
        'ON CONFLICT(kind,id) DO UPDATE SET payload = excluded.payload;',
        [
          ContextOperation.entityKind,
          id,
          ownerId ?? id,
          jsonEncode([
            ContextOperation(
              id: 'op-1',
              kind: ContextOperationKind.compress,
              anchorGroupId: '$id-m1',
              appliedAfterGroupId: '$id-m1',
              sourceGroups: ['$id-m0'],
              dependencies: const [],
              createdAt: DateTime.utc(2026, 8, 1, 12),
              summary: 'the first turn',
              originalSummary: 'the first turn',
              keepUserMessages: 1,
              model: 'probe',
              inputTokens: 11,
              inputParts: 1,
            ).toJson(),
          ]),
          0,
        ],
      );
    }

    /// One draft row, as the composer writes it: the conversation id in `id`, the
    /// assistant it was composed for in `owner_id`.
    Future<void> seedDraft(String id, {String text = 'half a thought'}) async {
      await database.customStatement(
        'INSERT INTO extension_entity_rows(kind,id,sort_order,owner_id,payload,updated_at) '
        'VALUES(?,?,0,?,?,0) '
        'ON CONFLICT(kind,id) DO UPDATE SET payload = excluded.payload;',
        [
          ComposerDraftStore.kind,
          id,
          'a1',
          jsonEncode({
            'conversationId': id,
            'compose': {'text': text},
          }),
        ],
      );
    }

    /// A conversation's extension rows as `kind → payload`, optionally narrowed to
    /// [kinds] — the form both halves of the rule can be compared in.
    Future<Map<String, String>> extensionPayloads(
      String id, {
      Set<String>? kinds,
    }) async {
      final placeholders = List.filled(kinds?.length ?? 0, '?');
      final rows = await database
          .customSelect(
            'SELECT kind, payload FROM extension_entity_rows WHERE id = ?'
            '${placeholders.isEmpty ? '' : ' AND kind IN (${placeholders.join(', ')})'}'
            ' ORDER BY kind;',
            variables: <Variable<Object>>[
              Variable<String>(id),
              for (final kind in kinds ?? const <String>{})
                Variable<String>(kind),
            ],
          )
          .get();
      return {
        for (final row in rows)
          row.read<String>('kind'): row.read<String>('payload'),
      };
    }

    test('a deleted conversation is staged with its whole subtree', () async {
      await seedConversation('c1');
      final partsBefore = await repository.syncReadMessagePartRows('c1');

      await repository.deleteConversation('c1');

      final entry = (await binEntries()).single;
      expect(entry.type, RecycleEntryType.conversation);
      expect(entry.key, 'c1');
      expect(entry.title, 'Topic c1');
      expect(entry.origin, RecycleOrigin.local);
      expect(entry.reason, RecycleReason.deleted);

      final tables = await store.readTables(entry);
      expect(tables!['conversation_rows']!.single['title'], 'Topic c1');
      expect(tables['message_rows'], hasLength(2));
      expect(tables['message_part_rows'], hasLength(partsBefore.length));
    });

    test('restoring brings the subtree back and wins the next clock', () async {
      await seedConversation('c1');
      final partsBefore = await repository.syncReadMessagePartRows('c1');
      await repository.deleteConversation('c1');
      final entry = (await binEntries()).single;
      final staged = await store.readTables(entry);
      final stagedClock =
          staged!['conversation_rows']!.single['updated_at']! as int;

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      final restored = await repository.syncReadConversationRow('c1');
      expect(restored, isNotNull);
      expect(restored!['title'], 'Topic c1');
      expect(
        restored['updated_at'] as int,
        greaterThan(stagedClock),
        reason: 'a restore is a fresh local write, not a clock resurrection',
      );
      expect(await repository.syncReadMessageRows('c1'), hasLength(2));
      expect(
        (await repository.syncReadMessagePartRows('c1')).length,
        partsBefore.length,
      );
      expect(
        await repository.readTombstones(),
        isEmpty,
        reason: 'the deletion record goes with the deletion it recorded',
      );
      expect(
        await binEntries(),
        isEmpty,
        reason: 'the entry is retired by its own restore',
      );
    });

    test('a conversation that is present again is not overwritten', () async {
      await seedConversation('c1');
      await repository.deleteConversation('c1');
      final entry = (await binEntries()).single;
      await seedConversation('c1');

      expect(
        await recycle.restore(entry),
        RecycleRestoreOutcome.skippedExisting,
      );
      expect(
        await binEntries(),
        hasLength(1),
        reason: 'nothing was restored, so nothing is retired',
      );
    });

    test('a peer deletion stages with the remote origin', () async {
      await seedConversation('c1');

      expect(await repository.syncApplyPeerDeletion('c1'), isTrue);

      final entry = (await binEntries()).single;
      expect(entry.origin, RecycleOrigin.remote);
      expect(entry.key, 'c1');
    });

    test('a delete returns before the bin has begun writing', () async {
      // The delete is something the user waits for; the bin is only its safety
      // net. "Detached" therefore has to mean the bin's decode and encode are not
      // on the delete's own stack — an async body runs synchronously up to its
      // first await, so *calling* the closure puts that work back on the path.
      await seedConversation('c1');

      await repository.deleteConversation('c1');

      expect(
        store.stagedKeys,
        isEmpty,
        reason: 'nothing may be decoded or written on the delete\'s own path',
      );
      await recycle.settle();
      expect(store.stagedKeys, ['c1']);
    });

    test('the capture crosses the transaction it was taken in', () async {
      // The other half, and the one a detach alone cannot give: the capture has
      // to be staged *after* the transaction that removed the rows commits, or
      // the decode holds the write transaction open for its duration. Read per
      // staging rather than into one variable: a build that stages twice would
      // otherwise let the second, later reading answer for the first.
      await seedConversation('c1');
      final rowPresentWhenStaged = <bool>[];
      store.onStage = (key) async {
        rowPresentWhenStaged.add(
          await repository.syncReadConversationRow(key) != null,
        );
      };

      await repository.deleteConversation('c1');
      await recycle.settle();

      expect(rowPresentWhenStaged, isNotEmpty);
      expect(
        rowPresentWhenStaged.first,
        isFalse,
        reason: 'the write runs after the delete committed, not before it',
      );
    });

    test('deleting one message stages nothing', () async {
      await seedConversation('c1');

      await repository.deleteMessage('c1-m1');

      expect(
        await binEntries(),
        isEmpty,
        reason:
            'message-level deletion is an edit inside a conversation, '
            'not a conversation leaving the bin\'s custody',
      );
      expect(await repository.syncReadMessageRows('c1'), hasLength(1));
    });

    test('a bulk reset stages nothing', () async {
      await seedConversation('c1');
      await seedConversation('c2');

      await repository.clearAllData();

      expect(
        await binEntries(),
        isEmpty,
        reason: 'replacing the whole local state is not a deletion intent',
      );
      expect(await repository.readTombstones(), isEmpty);
    });

    test('a bulk reset removes every kind the conversation rule names', () async {
      await seedConversation('c1');
      for (final kind in conversationDeletedKinds) {
        await extensions.upsert(kind, 'c1', const {
          'probe': true,
        }, ownerId: 'c1');
      }

      await repository.clearAllData();

      expect(
        await extensionPayloads('c1'),
        isEmpty,
        reason:
            'a reset that claims to replace the local state takes the rows the '
            'rule names — a kind added to it must not outlive the reset',
      );
    });

    test('a deleted conversation comes back with its documents', () async {
      await seedConversation('c1');
      await seedDocuments('c1');
      final before = await extensionPayloads('c1');
      expect(before.keys, unorderedEquals(conversationDocumentKinds));

      await repository.deleteConversation('c1');

      expect(
        await extensionPayloads('c1'),
        isEmpty,
        reason: 'every kind the delete owns goes with the conversation',
      );
      final entry = (await binEntries()).single;
      final staged = (await store.readTables(entry))!['extension_entity_rows']!;
      expect(
        {for (final row in staged) row['kind']},
        unorderedEquals(conversationDocumentKinds),
        reason: 'the capture stages this conversation and nothing else',
      );

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      expect(
        await extensionPayloads('c1'),
        before,
        reason: 'a restore writes back the bytes it staged',
      );
      expect(
        (await repository.readImageContextSettings('c1')).pinned,
        {'c1-m1|content|0'},
        reason: 'the row is not only present, its reader still understands it',
      );
      expect(
        await CompressionRepository(extensions).overrides('c1'),
        containsPair('templateId', 'builtin-default'),
      );
      expect(
        (await repository.readContextOperations(
          'c1',
        )).map((operation) => operation.id),
        ['op-1'],
        reason: 'the payload is not only byte-identical, a reader parses it',
      );
    });

    test(
      'a draft made since the deletion does not keep the documents out',
      () async {
        await seedConversation('c1');
        await seedDocuments('c1');
        await seedDraft('c1', text: 'staged');
        await repository.deleteConversation('c1');
        final entry = (await binEntries()).single;

        await seedDraft('c1', text: 'typed since');

        expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

        final payloads = await extensionPayloads('c1');
        expect(
          payloads.keys,
          containsAll(conversationDocumentKinds),
          reason: 'the gate is about the draft, not about the conversation',
        );
        expect(
          payloads[ComposerDraftStore.kind],
          contains('typed since'),
          reason: 'what the user typed since still wins',
        );
      },
    );

    test(
      'an in-flight compression task is neither staged nor restored',
      () async {
        await seedConversation('c1');
        await seedDocuments('c1');
        await extensions.upsert('contextCompressionTask', 'c1', const {
          'startedAt': 'now',
        }, ownerId: 'c1');

        await repository.deleteConversation('c1');

        final entry = (await binEntries()).single;
        final staged = (await store.readTables(
          entry,
        ))!['extension_entity_rows']!;
        expect(
          {for (final row in staged) row['kind']},
          unorderedEquals(conversationDocumentKinds),
          reason: 'a run that is happening now is not history to hand back',
        );
        expect(await extensionPayloads('c1'), isEmpty);

        expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

        expect(
          await extensionPayloads('c1', kinds: conversationUnrecoverableKinds),
          isEmpty,
          reason:
              'a restored task would describe a stream no writer is feeding',
        );
      },
    );

    test('the delete claims these rows by id, not by owner_id', () async {
      await seedConversation('c1');
      await seedDocuments('c1', ownerId: 'another-owner');

      await repository.deleteConversation('c1');

      expect(
        await extensionPayloads('c1'),
        isEmpty,
        reason:
            'the row belongs to the conversation by its id; a delete that read '
            'owner_id would leave it behind',
      );
      final entry = (await binEntries()).single;
      final staged = (await store.readTables(entry))!['extension_entity_rows']!;
      expect(
        {for (final row in staged) row['kind']},
        unorderedEquals(conversationDocumentKinds),
        reason: 'the same column the delete reads is the one the capture reads',
      );
    });

    test(
      'an entry carrying a kind this build has no rule for is not written',
      () async {
        // No build stages such an entry: the capture stages exactly
        // conversationCapturedKinds, and the guard test pins that to the documents
        // plus the draft. The case is what a widened capture list would produce,
        // and the restore's job is to leave the row out rather than write it back
        // through the rule that belongs to a document.
        await seedConversation('c1');
        await seedDocuments('c1');
        await repository.deleteConversation('c1');
        final staged = (await store.readTables((await binEntries()).single))!;
        const foreignKind = 'aKindThisBuildDoesNotRestore';

        await store.stageRows(
          type: RecycleEntryType.conversation,
          origin: RecycleOrigin.local,
          reason: RecycleReason.deleted,
          key: 'c1',
          title: 'Topic c1',
          tables: {
            ...staged,
            'extension_entity_rows': [
              ...?staged['extension_entity_rows'],
              const <String, Object?>{
                'kind': foreignKind,
                'id': 'c1',
                'sort_order': 0,
                'owner_id': 'c1',
                'payload': '{}',
                'updated_at': 0,
              },
            ],
          },
        );

        RecycleEntry? forged;
        for (final candidate in await binEntries()) {
          final tables = await store.readTables(candidate);
          final rows = tables?['extension_entity_rows'] ?? const [];
          if (rows.any((row) => row['kind'] == foreignKind)) forged = candidate;
        }
        expect(
          forged,
          isNotNull,
          reason: 'the entry the test means to restore',
        );

        expect(await recycle.restore(forged!), RecycleRestoreOutcome.restored);

        expect(
          await extensionPayloads('c1', kinds: const {foreignKind}),
          isEmpty,
          reason: 'a kind with no restore rule is not written through one',
        );
        expect(
          (await extensionPayloads('c1')).keys,
          unorderedEquals(conversationDocumentKinds),
          reason:
              'the documents the build does have a rule for still came back',
        );
      },
    );

    test('the delete list and the capture list are one rule', () {
      expect(
        conversationCapturedKinds,
        containsAll(conversationDocumentKinds),
        reason: 'every document the delete removes is one the bin stages',
      );
      expect(
        conversationDeletedKinds.difference(conversationUnrecoverableKinds),
        unorderedEquals(conversationDocumentKinds),
        reason: 'the only thing deleted and not staged is the in-flight task',
      );
      expect(
        conversationUnrecoverableKinds,
        unorderedEquals(<String>{'contextCompressionTask'}),
      );
      expect(
        conversationCapturedKinds,
        unorderedEquals(<String>{
          ...conversationDocumentKinds,
          ComposerDraftStore.kind,
        }),
        reason:
            'the draft travels under its own delete path, not this one — and '
            'this identity is what makes the restore exhaustive: a document is '
            'written whole, a draft goes through its gate, and there is no '
            'third case to fall between them',
      );
    });

    test('every staged kind is keyed by the conversation id', () async {
      var index = 0;
      for (final kind in conversationCapturedKinds) {
        final id = 'keyed${index++}';
        await seedConversation(id);
        await extensions.upsert(kind, id, const {'probe': true}, ownerId: id);

        await repository.deleteConversation(id);

        final entry = (await binEntries()).single;
        final staged = (await store.readTables(
          entry,
        ))!['extension_entity_rows']!;
        expect(
          {for (final row in staged) row['kind']},
          contains(kind),
          reason:
              'a kind the capture cannot reach is a row a restore cannot '
              'bring back',
        );

        await recycle.restore(entry);
        expect(
          await extensionPayloads(id),
          containsPair(kind, '{"probe":true}'),
        );
      }
    });
  });
}
