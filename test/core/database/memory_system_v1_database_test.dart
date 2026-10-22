import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/business_restore_service.dart';
import 'package:Cuplivo/core/database/business_settings_merger.dart';
import 'package:Cuplivo/core/database/business_settings_router.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('memory system v1 database (§18.2)', () {
    test(
      '17: new database passes raw structure and schema validation',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'kelivo_memory_validate_',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final file = File('${directory.path}/kelivo.db');
        final repository = ChatDatabaseRepository.open(file: file);
        addTearDown(repository.close);

        await expectLater(repository.ensureReady(), completes);

        final raw = sqlite.sqlite3.open(file.path);
        addTearDown(raw.close);
        expect(raw.userVersion, AppDatabase.currentSchemaVersion);
        final tables = raw
            .select("SELECT name FROM sqlite_master WHERE type = 'table';")
            .map((row) => row['name'] as String)
            .toSet();
        expect(
          tables,
          containsAll(const {
            'memory_entry_rows',
            'user_profile_field_rows',
            'message_prompt_rows',
          }),
        );
      },
    );

    test(
      '19: message_prompt_rows cascade when message or conversation deleted',
      () async {
        final database = AppDatabase(
          NativeDatabase.memory(
            setup: (raw) {
              raw.execute('PRAGMA foreign_keys = ON;');
            },
          ),
        );
        addTearDown(database.close);
        await database.customSelect('SELECT 1;').getSingle();

        final now = DateTime.utc(2026, 8, 8);
        await database
            .into(database.conversationRows)
            .insert(
              ConversationRowsCompanion.insert(
                id: 'c1',
                title: 'Chat',
                createdAt: now,
                updatedAt: now,
              ),
            );
        await database
            .into(database.messageRows)
            .insert(
              MessageRowsCompanion.insert(
                id: 'm1',
                conversationId: 'c1',
                role: 'user',
                timestamp: now,
                messageOrder: 0,
              ),
            );
        await database
            .into(database.messagePromptRows)
            .insert(
              MessagePromptRowsCompanion.insert(
                revisionId: 'm1',
                conversationId: 'c1',
                payload: 'frozen prompt',
                createdAt: now,
              ),
            );

        expect(
          await database.select(database.messagePromptRows).get(),
          hasLength(1),
        );

        await (database.delete(
          database.messageRows,
        )..where((t) => t.id.equals('m1'))).go();
        expect(
          await database.select(database.messagePromptRows).get(),
          isEmpty,
        );

        await database
            .into(database.messageRows)
            .insert(
              MessageRowsCompanion.insert(
                id: 'm2',
                conversationId: 'c1',
                role: 'user',
                timestamp: now,
                messageOrder: 0,
              ),
            );
        await database
            .into(database.messagePromptRows)
            .insert(
              MessagePromptRowsCompanion.insert(
                revisionId: 'm2',
                conversationId: 'c1',
                payload: 'another',
                createdAt: now,
              ),
            );
        await (database.delete(
          database.conversationRows,
        )..where((t) => t.id.equals('c1'))).go();
        expect(
          await database.select(database.messagePromptRows).get(),
          isEmpty,
        );
      },
    );

    test('20: memory_entry_rows scope/assistantId CHECK constraints', () async {
      final database = AppDatabase(
        NativeDatabase.memory(
          setup: (raw) {
            raw.execute('PRAGMA foreign_keys = ON;');
          },
        ),
      );
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();
      final now = DateTime.utc(2026, 8, 8);

      await expectLater(
        database
            .into(database.memoryEntryRows)
            .insert(
              MemoryEntryRowsCompanion.insert(
                id: 'mem_badglob1',
                sortOrder: 0,
                scope: 'global',
                assistantId: const Value('assistant-a'),
                type: 'identity',
                status: 'active',
                content: 'x',
                contentNormalized: 'x',
                entryCreatedAt: now,
                entryUpdatedAt: now,
                payload: '{}',
                updatedAt: now,
              ),
            ),
        throwsA(isA<sqlite.SqliteException>()),
      );

      await expectLater(
        database
            .into(database.memoryEntryRows)
            .insert(
              MemoryEntryRowsCompanion.insert(
                id: 'mem_badasst1',
                sortOrder: 0,
                scope: 'assistant',
                type: 'identity',
                status: 'active',
                content: 'x',
                contentNormalized: 'x',
                entryCreatedAt: now,
                entryUpdatedAt: now,
                payload: '{}',
                updatedAt: now,
              ),
            ),
        throwsA(isA<sqlite.SqliteException>()),
      );
    });

    test(
      '21: typed columns derive from payload via BusinessRepository',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final repository = BusinessRepository(database);
        await database.customSelect('SELECT 1;').getSingle();

        const createdAt = 1786012880106000;
        const updatedAt = 1786099280106000;
        await repository.upsertEntity(
          BusinessEntityKind.memoryEntry,
          BusinessEntityValue(
            id: 'mem_a1b2c3d4',
            sortOrder: 0,
            payload: jsonEncode({
              'id': 'mem_a1b2c3d4',
              'scope': 'global',
              'assistantId': null,
              'type': 'workflow',
              'status': 'active',
              'content': '  User   likes\nFlutter  ',
              'source': 'extracted',
              'relatedIds': <String>[],
              'createdAt': createdAt,
              'updatedAt': updatedAt,
            }),
          ),
        );

        final typed = await database
            .customSelect(
              "SELECT scope, assistant_id, type, status, content, "
              "content_normalized, entry_created_at, entry_updated_at, "
              "updated_at, payload FROM memory_entry_rows "
              "WHERE id = 'mem_a1b2c3d4';",
            )
            .getSingle();
        expect(typed.read<String>('scope'), 'global');
        expect(typed.data['assistant_id'], isNull);
        expect(typed.read<String>('type'), 'workflow');
        expect(typed.read<String>('status'), 'active');
        expect(typed.read<String>('content'), '  User   likes\nFlutter  ');
        expect(
          typed.read<String>('content_normalized'),
          BusinessRepository.normalizeMemoryContent(
            '  User   likes\nFlutter  ',
          ),
        );
        expect(typed.read<int>('entry_created_at'), createdAt);
        expect(typed.read<int>('entry_updated_at'), updatedAt);
        // Row write time must not reuse the payload business updatedAt.
        expect(typed.read<int>('updated_at'), isNot(updatedAt));
        expect(
          jsonDecode(typed.read<String>('payload')),
          isNot(contains('contentNormalized')),
        );
      },
    );

    test(
      '22: orphan assistant-scoped rows are invisible by assistant join',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final repository = BusinessRepository(database);
        await database.customSelect('SELECT 1;').getSingle();

        await repository.upsertEntity(
          BusinessEntityKind.assistant,
          BusinessEntityValue(
            id: 'assistant-alive',
            sortOrder: 0,
            payload: jsonEncode({'id': 'assistant-alive', 'name': 'Alive'}),
          ),
        );
        final now = DateTime.now().toUtc().microsecondsSinceEpoch;
        Future<void> putAssistantMemory(String id, String assistantId) {
          return repository.upsertEntity(
            BusinessEntityKind.memoryEntry,
            BusinessEntityValue(
              id: id,
              sortOrder: id == 'mem_alive001' ? 0 : 1,
              payload: jsonEncode({
                'id': id,
                'scope': 'assistant',
                'assistantId': assistantId,
                'type': 'voice',
                'status': 'active',
                'content': id,
                'source': 'manual',
                'relatedIds': <String>[],
                'createdAt': now,
                'updatedAt': now,
              }),
            ),
          );
        }

        await putAssistantMemory('mem_alive001', 'assistant-alive');
        await putAssistantMemory('mem_orphan01', 'assistant-deleted');

        final visible = await database
            .customSelect(
              "SELECT m.id FROM memory_entry_rows m "
              "WHERE m.scope = 'assistant' AND m.status = 'active' "
              "AND EXISTS (SELECT 1 FROM assistant_rows a "
              "WHERE a.id = m.assistant_id) "
              "ORDER BY m.id;",
            )
            .get();
        expect(visible.map((row) => row.read<String>('id')), ['mem_alive001']);

        final orphanCount = await database
            .customSelect(
              "SELECT COUNT(*) AS count FROM memory_entry_rows m "
              "WHERE m.scope = 'assistant' "
              "AND NOT EXISTS (SELECT 1 FROM assistant_rows a "
              "WHERE a.id = m.assistant_id);",
            )
            .getSingle();
        expect(orphanCount.read<int>('count'), 1);
      },
    );
  });

  group('memory system v1 backup (§18.3)', () {
    late AppDatabase database;
    late BusinessRepository repository;
    late BusinessRestoreService restore;

    setUp(() async {
      database = AppDatabase(NativeDatabase.memory());
      repository = BusinessRepository(database);
      restore = BusinessRestoreService(repository);
      await database.customSelect('SELECT 1;').getSingle();
    });

    tearDown(() => database.close());

    Map<String, Object?> memoryFixture() {
      const t0 = 1786012880106000;
      const t1 = 1786099280106000;
      return {
        'memory_entries_v1': jsonEncode([
          {
            'id': 'mem_global01',
            'scope': 'global',
            'assistantId': null,
            'type': 'identity',
            'status': 'active',
            'content': 'User is a Flutter developer.',
            'source': 'extracted',
            'relatedIds': ['mem_archiv01'],
            'createdAt': t0,
            'updatedAt': t1,
          },
          {
            'id': 'mem_archiv01',
            'scope': 'global',
            'assistantId': null,
            'type': 'identity',
            'status': 'archived',
            'content': 'Older identity note.',
            'source': 'tool',
            'relatedIds': ['mem_global01'],
            'createdAt': t0,
            'updatedAt': t0,
          },
        ]),
        'user_profile_fields_v1': jsonEncode([
          {
            'id': 'preferred_name',
            'value': 'Psyche',
            'source': 'tool',
            'updatedAt': t1,
          },
        ]),
      };
    }

    test('23: export overwrite-restore keeps memories and profile', () async {
      await restore.overwrite(memoryFixture());
      final portable = BusinessSettingsRouter.exportSnapshotWithRowIds(
        await repository.readSnapshot(),
      );

      await restore.overwrite({
        'assistants_v1': jsonEncode([
          {'id': 'other', 'name': 'Other'},
        ]),
      });
      expect(
        await repository.readEntities(BusinessEntityKind.memoryEntry),
        isEmpty,
      );

      await restore.overwrite(
        portable.settings,
        entityRowIds: portable.entityRowIds,
      );

      final memories = await repository.readEntities(
        BusinessEntityKind.memoryEntry,
      );
      expect(memories.map((row) => row.id).toSet(), {
        'mem_global01',
        'mem_archiv01',
      });
      final profiles = await repository.readEntities(
        BusinessEntityKind.userProfileField,
      );
      expect(profiles.single.id, 'preferred_name');
      expect(jsonDecode(profiles.single.payload)['value'], 'Psyche');
      final archived = memories.firstWhere((row) => row.id == 'mem_archiv01');
      expect(jsonDecode(archived.payload)['status'], 'archived');
      expect(jsonDecode(archived.payload)['relatedIds'], ['mem_global01']);
    });

    test('24: merge drops content dupes, remaps ids, rewrites relatedIds', () {
      const t0 = 1786012880106000;
      BusinessEntityValue entry({
        required String id,
        required String content,
        List<String> relatedIds = const [],
        int sortOrder = 0,
      }) => BusinessEntityValue(
        id: id,
        sortOrder: sortOrder,
        payload: jsonEncode({
          'id': id,
          'scope': 'global',
          'assistantId': null,
          'type': 'workflow',
          'status': 'active',
          'content': content,
          'source': 'manual',
          'relatedIds': relatedIds,
          'createdAt': t0,
          'updatedAt': t0,
        }),
      );

      final local = BusinessSnapshot(
        entities: {
          BusinessEntityKind.memoryEntry: [
            entry(id: 'mem_local001', content: 'Same content'),
            entry(
              id: 'mem_shared01',
              content: 'Local unique',
              relatedIds: const ['mem_local001'],
            ),
          ],
        },
        preferences: const {},
      );
      final incoming = BusinessSnapshot(
        entities: {
          BusinessEntityKind.memoryEntry: [
            entry(id: 'mem_dup0001', content: 'Same content'),
            entry(
              id: 'mem_shared01',
              content: 'Incoming different',
              relatedIds: const ['mem_dup0001', 'mem_missing'],
              sortOrder: 1,
            ),
          ],
        },
        preferences: const {},
      );

      final merged = BusinessSettingsMerger.mergeSnapshots(
        local,
        incoming,
        incomingKeys: {BusinessEntityKind.memoryEntry.sourceKey},
      );
      final rows = merged.entities[BusinessEntityKind.memoryEntry]!;
      expect(rows.map((row) => jsonDecode(row.payload)['content']), [
        'Same content',
        'Local unique',
        'Incoming different',
      ]);
      final remapped = rows.last;
      expect(remapped.id, isNot('mem_shared01'));
      expect(remapped.id, startsWith('mem_'));
      final related = (jsonDecode(remapped.payload)['relatedIds'] as List)
          .cast<String>();
      // mem_dup0001 was content-deduped away; mem_missing never existed.
      expect(related, isEmpty);
    });

    test(
      '25: old backup overwrite-restore clears memory (expected behaviour)',
      () async {
        await restore.overwrite(memoryFixture());
        expect(
          await repository.readEntities(BusinessEntityKind.memoryEntry),
          isNotEmpty,
        );

        // Old backup: no memory_entries_v1 / user_profile_fields_v1 keys.
        await restore.overwrite({
          'assistants_v1': jsonEncode([
            {'id': 'assistant-1', 'name': 'Assistant'},
          ]),
          'theme_mode_v1': 'dark',
        });

        expect(
          await repository.readEntities(BusinessEntityKind.memoryEntry),
          isEmpty,
        );
        expect(
          await repository.readEntities(BusinessEntityKind.userProfileField),
          isEmpty,
        );
      },
    );

    test('26: entityRowIds length mismatch throws FormatException', () {
      expect(
        () => BusinessSettingsRouter.normalizeAndRoute(
          {
            'memory_entries_v1': jsonEncode([
              {
                'id': 'mem_a1b2c3d4',
                'scope': 'global',
                'type': 'identity',
                'content': 'x',
                'createdAt': 1,
                'updatedAt': 1,
              },
            ]),
          },
          entityRowIds: {
            for (final kind in BusinessEntityKind.values)
              if (kind != BusinessEntityKind.provider)
                kind.sourceKey: kind == BusinessEntityKind.memoryEntry
                    ? <String>['mem_a1b2c3d4', 'extra']
                    : <String>[],
          },
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'memory_entries_v1',
          ),
        ),
      );
    });

    test(
      '27: database snapshot preserves memory rows through validation',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'kelivo_memory_snapshot_',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final sourceFile = File('${directory.path}/source.db');

        final db = AppDatabase.open(file: sourceFile);
        await db.customSelect('SELECT 1;').getSingle();
        final repo = BusinessRepository(db);
        const t0 = 1786012880106000;
        await repo.upsertEntity(
          BusinessEntityKind.memoryEntry,
          BusinessEntityValue(
            id: 'mem_snap0001',
            sortOrder: 0,
            payload: jsonEncode({
              'id': 'mem_snap0001',
              'scope': 'global',
              'type': 'instruction',
              'content': 'Prefer Dart examples.',
              'status': 'active',
              'source': 'manual',
              'relatedIds': <String>[],
              'createdAt': t0,
              'updatedAt': t0,
            }),
          ),
        );
        await db.close();

        final source = ChatDatabaseRepository.open(file: sourceFile);
        addTearDown(source.close);
        await source.ensureReady();
        await source.putMigrationBatch(
          conversations: [
            Conversation(id: 'c1', title: 'Snap', messageIds: const ['m1']),
          ],
          messages: [
            (
              message: ChatMessage(
                id: 'm1',
                role: 'user',
                content: 'hi',
                conversationId: 'c1',
              ),
              messageOrder: 0,
            ),
          ],
          toolEventsByMessageId: const {},
          geminiSignaturesByMessageId: const {},
        );

        final snapshotFile = File('${directory.path}/snapshot.db');
        await ChatDatabaseRepository.createConsistentSnapshot(
          sourceFile: sourceFile,
          destinationFile: snapshotFile,
        );
        await source.close();

        final candidate = sqlite.sqlite3.open(snapshotFile.path);
        addTearDown(candidate.close);
        final count =
            candidate
                    .select(
                      "SELECT COUNT(*) AS c FROM memory_entry_rows "
                      "WHERE id = 'mem_snap0001';",
                    )
                    .single['c']
                as int;
        expect(count, 1);

        final live = ChatDatabaseRepository.open(file: snapshotFile);
        addTearDown(live.close);
        await expectLater(live.ensureReady(), completes);
      },
    );
  });

  group('memory system v1 merge conversation watermarks (§18.3/28)', () {
    test(
      '28: merge restore sets lastMemoryExtractedOrder to max and clears hash',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'kelivo_memory_merge_order_',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });

        final liveFile = File('${directory.path}/live.db');
        final sourceFile = File('${directory.path}/source.db');
        final live = ChatDatabaseRepository.open(file: liveFile);
        final source = ChatDatabaseRepository.open(file: sourceFile);
        await live.ensureReady();
        await source.ensureReady();

        final anchor = DateTime.utc(2026, 8, 8, 12);
        await source.putMigrationBatch(
          conversations: [
            Conversation(
              id: 'imported',
              title: 'Imported',
              createdAt: anchor,
              updatedAt: anchor,
              messageIds: const ['m0', 'm1', 'm2'],
              injectedMemoryHash: 'stale-hash',
              lastMemoryExtractedOrder: 0,
            ),
          ],
          messages: [
            for (final (id, order) in [('m0', 0), ('m1', 1), ('m2', 2)])
              (
                message: ChatMessage(
                  id: id,
                  role: order.isEven ? 'user' : 'assistant',
                  content: 'msg-$order',
                  conversationId: 'imported',
                  timestamp: anchor,
                ),
                messageOrder: order,
              ),
          ],
          toolEventsByMessageId: const {},
          geminiSignaturesByMessageId: const {},
        );
        await source.close();

        await live.mergeBackupSnapshot(sourceFile);
        // Insert path already applies §6.7 watermarks; also exercise the
        // data_sync post-merge SQL hook against the live file.
        await live.close();
        final db = AppDatabase.open(file: liveFile);
        await BusinessRepository(
          db,
        ).applyPostMergeMemoryConversationState(const ['imported']);
        await db.close();

        final reopened = ChatDatabaseRepository.open(file: liveFile);
        addTearDown(reopened.close);
        await reopened.ensureReady();
        final conversation = await reopened.getConversation('imported');
        expect(conversation, isNotNull);
        expect(conversation!.injectedMemoryHash, isNull);
        expect(conversation.lastMemoryExtractedOrder, 2);
      },
    );

    test('28b: post-merge watermarks skip untouched conversations', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_memory_scoped_watermark_',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final file = File('${directory.path}/kelivo.db');
      final repository = ChatDatabaseRepository.open(file: file);
      await repository.ensureReady();

      final anchor = DateTime.utc(2026, 8, 8, 12);
      for (final id in const ['merged', 'local']) {
        await repository.putMigrationBatch(
          conversations: [
            Conversation(
              id: id,
              title: id,
              createdAt: anchor,
              updatedAt: anchor,
              messageIds: const ['a', 'b'].map((s) => '$id-$s').toList(),
              injectedMemoryHash: 'stale-$id',
            ),
          ],
          messages: [
            for (final (suffix, order) in [('a', 0), ('b', 1)])
              (
                message: ChatMessage(
                  id: '$id-$suffix',
                  role: order.isEven ? 'user' : 'assistant',
                  content: 'msg-$order',
                  conversationId: id,
                  timestamp: anchor,
                ),
                messageOrder: order,
              ),
          ],
          toolEventsByMessageId: const {},
          geminiSignaturesByMessageId: const {},
        );
      }
      await repository.close();

      final database = AppDatabase.open(file: file);
      await BusinessRepository(
        database,
      ).applyPostMergeMemoryConversationState(const ['merged']);
      await database.close();

      final reopened = ChatDatabaseRepository.open(file: file);
      addTearDown(reopened.close);
      await reopened.ensureReady();
      final merged = await reopened.getConversation('merged');
      final local = await reopened.getConversation('local');
      expect(merged!.injectedMemoryHash, isNull);
      expect(merged.lastMemoryExtractedOrder, 1);
      expect(local!.injectedMemoryHash, 'stale-local');
      expect(local.lastMemoryExtractedOrder, -1);
    });
  });

  group('memory payload validation (§5.8)', () {
    test('rejects invalid memory and profile payloads', () {
      expect(
        () => BusinessSettingsRouter.normalizeAndRoute({
          'memory_entries_v1': jsonEncode([
            {
              'id': 'mem_x',
              'scope': 'global',
              'type': 'identity',
              'content': '   ',
              'createdAt': 1,
              'updatedAt': 1,
            },
          ]),
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => BusinessSettingsRouter.normalizeAndRoute({
          'memory_entries_v1': jsonEncode([
            {
              'id': 'mem_x',
              'scope': 'global',
              'assistantId': 'a',
              'type': 'identity',
              'content': 'ok',
              'createdAt': 1,
              'updatedAt': 1,
            },
          ]),
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => BusinessSettingsRouter.normalizeAndRoute({
          'user_profile_fields_v1': jsonEncode([
            {'id': 'nickname', 'value': 'x', 'updatedAt': 1},
          ]),
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => BusinessSettingsRouter.normalizeAndRoute({
          'user_profile_fields_v1': jsonEncode([
            {'id': 'preferred_name', 'value': '  ', 'updatedAt': 1},
          ]),
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
