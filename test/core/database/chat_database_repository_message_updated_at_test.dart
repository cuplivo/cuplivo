import 'dart:io';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// message_rows.updated_at contract (schema 3): inserts leave it null — the
/// effective value is COALESCE(updated_at, timestamp) — and every repository
/// UPDATE path bumps it so a future sync can detect in-place edits.
void main() {
  group('ChatDatabaseRepository message updated_at', () {
    late Directory directory;
    late File databaseFile;
    late ChatDatabaseRepository repository;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'kelivo_message_updated_at_test_',
      );
      databaseFile = File('${directory.path}/chat.sqlite');
      repository = ChatDatabaseRepository.open(file: databaseFile);
      await repository.ensureReady();
    });

    tearDown(() async {
      await repository.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    ChatMessage message(String id) => ChatMessage(
      id: id,
      role: 'user',
      content: 'hello',
      conversationId: 'topic',
      groupId: id,
      version: 0,
      timestamp: DateTime.utc(2026, 8, 1),
    );

    Future<void> seed() async {
      final createdAt = DateTime.utc(2026, 8, 1);
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: 'topic',
            title: 'Topic',
            createdAt: createdAt,
            updatedAt: createdAt,
            messageIds: const ['u1'],
          ),
        ],
        messages: [(message: message('u1'), messageOrder: 0)],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
    }

    Object? rawUpdatedAt(String messageId) {
      final raw = sqlite.sqlite3.open(
        databaseFile.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        return raw.select('SELECT updated_at FROM message_rows WHERE id = ?;', [
          messageId,
        ]).single['updated_at'];
      } finally {
        raw.close();
      }
    }

    test('inserted rows keep updated_at null', () async {
      await seed();

      expect(rawUpdatedAt('u1'), isNull);
    });

    test('updateMessageFields bumps updated_at', () async {
      await seed();

      await repository.updateMessageFields('u1', translation: 'bonjour');

      expect(rawUpdatedAt('u1'), isNotNull);
    });

    test('putMessage upserts bump updated_at', () async {
      await seed();
      expect(rawUpdatedAt('u1'), isNull);

      await repository.putMessage(message('u1'), messageOrder: 0);

      expect(rawUpdatedAt('u1'), isNotNull);
    });

    test(
      'an edit never lowers the LWW clock below the row timestamp',
      () async {
        // A message authored on a peer whose clock runs ahead arrives with a
        // future timestamp; editing it here before this clock catches up must
        // not stamp updated_at below that timestamp. The effective LWW clock is
        // COALESCE(updated_at, timestamp), and a lower updated_at would hand
        // the next exchange to the peer's untouched copy, reverting the edit on
        // both devices.
        final createdAt = DateTime.utc(2026, 8, 1);
        final future = DateTime.now().toUtc().add(const Duration(hours: 1));
        ChatMessage futureMessage(String content) => ChatMessage(
          id: 'u1',
          role: 'user',
          content: content,
          conversationId: 'topic',
          timestamp: future,
        );
        await repository.putMigrationBatch(
          conversations: [
            Conversation(
              id: 'topic',
              title: 'Topic',
              createdAt: createdAt,
              updatedAt: createdAt,
              messageIds: const ['u1'],
            ),
          ],
          messages: [
            (message: futureMessage('from the future'), messageOrder: 0),
          ],
          toolEventsByMessageId: const {},
          geminiSignaturesByMessageId: const {},
        );

        await repository.updateMessage(futureMessage('edited locally'));

        final stored = rawUpdatedAt('u1') as int?;
        expect(stored, isNotNull);
        expect(
          stored,
          greaterThanOrEqualTo(future.microsecondsSinceEpoch),
          reason: 'updated_at must never sit below the row timestamp',
        );
      },
    );
  });
}
