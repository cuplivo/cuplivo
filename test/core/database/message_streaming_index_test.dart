import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase database;
  late ChatDatabaseRepository repository;

  setUp(() async {
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (rawDatabase) {
          rawDatabase.execute('PRAGMA foreign_keys = ON;');
        },
      ),
    );
    repository = ChatDatabaseRepository(database);
    await database.customSelect('SELECT 1;').getSingle();
  });

  tearDown(() => database.close());

  test(
    'resetStaleStreamingState clears only streaming rows via partial index',
    () async {
      const totalNonStreaming = 100000;
      const streamingIds = ['stream-a', 'stream-b'];
      final now = DateTime.utc(2026, 8, 10);

      await database
          .into(database.conversationRows)
          .insert(
            ConversationRowsCompanion.insert(
              id: 'conversation-1',
              title: 'Conversation',
              createdAt: now,
              updatedAt: now,
            ),
          );

      await database.transaction(() async {
        final companions = <MessageRowsCompanion>[
          for (var i = 0; i < totalNonStreaming; i++)
            MessageRowsCompanion.insert(
              id: 'msg-$i',
              conversationId: 'conversation-1',
              role: 'user',
              timestamp: now,
              messageOrder: i,
              isStreaming: const Value(false),
            ),
          for (var i = 0; i < streamingIds.length; i++)
            MessageRowsCompanion.insert(
              id: streamingIds[i],
              conversationId: 'conversation-1',
              role: 'assistant',
              timestamp: now,
              messageOrder: totalNonStreaming + i,
              isStreaming: const Value(true),
            ),
        ];
        await database.batch((batch) {
          batch.insertAll(database.messageRows, companions);
        });
      });

      final plan = await database
          .customSelect(
            'EXPLAIN QUERY PLAN '
            'UPDATE message_rows SET is_streaming = 0 '
            'WHERE is_streaming = 1;',
          )
          .get();
      final planDetail = plan
          .map((row) => row.read<String>('detail'))
          .join('\n');
      expect(planDetail, contains('idx_message_rows_streaming'));
      expect(
        RegExp(
          r'scan message_rows(?! using index)',
          caseSensitive: false,
        ).hasMatch(planDetail),
        isFalse,
      );

      await repository.resetStaleStreamingState();

      final stillStreaming = await database
          .customSelect(
            'SELECT id FROM message_rows WHERE is_streaming = 1 ORDER BY id;',
          )
          .get();
      expect(stillStreaming, isEmpty);

      final cleared = await database
          .customSelect(
            'SELECT id FROM message_rows '
            'WHERE id IN (?, ?) AND is_streaming = 0 ORDER BY id;',
            variables: streamingIds
                .map((id) => Variable<String>(id))
                .toList(growable: false),
          )
          .get();
      expect(
        cleared.map((row) => row.read<String>('id')).toList(),
        streamingIds.toList()..sort(),
      );
    },
  );
}
