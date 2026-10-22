import 'dart:io';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/utils/kelivo_file_uri.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  group('sandbox path migration version', () {
    late Directory directory;
    late File dbFile;
    late ChatDatabaseRepository repository;
    var repositoryClosed = false;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'kelivo_sandbox_path_migration_',
      );
      dbFile = File('${directory.path}/chat.sqlite');
      repository = ChatDatabaseRepository.open(file: dbFile);
      repositoryClosed = false;
      await repository.ensureReady();
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: 'conversation',
            title: 'Paths',
            messageIds: const ['plain', 'path'],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: 'plain',
              conversationId: 'conversation',
              role: 'user',
              content: 'plain text',
            ),
            messageOrder: 0,
          ),
          (
            message: ChatMessage(
              id: 'path',
              conversationId: 'conversation',
              role: 'user',
              parts: const [ImagePart(uri: '/old/sandboxoldtoken/a.png')],
            ),
            messageOrder: 1,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
    });

    tearDown(() async {
      if (!repositoryClosed) await repository.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('首次按批迁移并在同一事务写 version receipt', () async {
      final result = await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/new',
        batchSize: 1,
        rewriteUri: (uri) =>
            uri.replaceFirst('/old/sandboxoldtoken/', '/new/sandboxnewtoken/'),
      );

      expect(result.ran, isTrue);
      expect(result.scannedMessages, 1);
      expect(result.updatedMessages, 1);
      expect(result.skippedParts, 0);
      final migrated = (await repository.getMessagesRange(
        'conversation',
        start: 0,
        limit: 10,
      )).last;
      expect(
        migrated.parts.whereType<ImagePart>().single.uri,
        '/new/sandboxnewtoken/a.png',
      );
    });

    test('同版本后续启动不读取候选消息', () async {
      await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/same',
        rewriteUri: (uri) => uri,
      );

      final result = await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/same',
        rewriteUri: (_) => throw StateError('must_not_scan'),
      );

      expect(result.ran, isFalse);
      expect(result.scannedMessages, 0);
      expect(result.skippedParts, 0);
    });

    test('rewrite 失败回滚内容且不写 receipt，可重试', () async {
      await expectLater(
        repository.migrateSandboxPaths(
          targetVersion: 1,
          targetRoot: '/new',
          rewriteUri: (_) => throw StateError('rewrite_failed'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'rewrite_failed',
          ),
        ),
      );

      final retry = await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/new',
        rewriteUri: (uri) =>
            uri.replaceFirst('/old/sandboxoldtoken/', '/new/sandboxnewtoken/'),
      );
      expect(retry.ran, isTrue);
      expect(retry.updatedMessages, 1);
    });

    test('同版本目标根变化时重新执行一次', () async {
      await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/first',
        rewriteUri: (uri) => uri,
      );

      final result = await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/second',
        rewriteUri: (uri) => uri.replaceFirst(
          '/old/sandboxoldtoken/',
          '/second/sandboxnewtoken/',
        ),
      );

      expect(result.ran, isTrue);
      expect(result.updatedMessages, 1);
    });

    test('损坏附件不阻塞迁移并保持原 payload 与 dirty 状态', () async {
      const malformedPayload =
          '{"uri":"/old/sandboxoldtoken/a.png","mime":["/private/secret"]}';
      final database = sqlite.sqlite3.open(dbFile.path);
      try {
        database.execute(
          'UPDATE message_part_rows SET payload = ? '
          "WHERE revision_id = 'path' AND kind = 'image';",
          [malformedPayload],
        );
        database.execute(
          "DELETE FROM asset_reference_dirty_rows WHERE revision_id = 'path';",
        );
      } finally {
        database.close();
      }

      final result = await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/new',
        rewriteUri: (uri) =>
            uri.replaceFirst('/old/sandboxoldtoken/', '/new/sandboxnewtoken/'),
      );

      expect(result.ran, isTrue);
      expect(result.scannedMessages, 1);
      expect(result.updatedMessages, 0);
      expect(result.skippedParts, 1);

      final verify = sqlite.sqlite3.open(dbFile.path);
      try {
        expect(
          verify
              .select(
                "SELECT payload FROM message_part_rows WHERE revision_id = 'path';",
              )
              .single['payload'],
          malformedPayload,
        );
        expect(
          verify.select(
            "SELECT 1 FROM asset_reference_dirty_rows WHERE revision_id = 'path';",
          ),
          hasLength(1),
        );
        expect(
          verify.select(
            "SELECT 1 FROM chat_storage_meta_rows "
            "WHERE key = 'sandbox_path_migration_version';",
          ),
          hasLength(1),
        );
      } finally {
        verify.close();
      }
    });

    test('路径重写后 ImagePart URI 更新且 FTS 索引完整', () async {
      await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/new',
        rewriteUri: (uri) =>
            uri.replaceFirst('/old/sandboxoldtoken/', '/new/sandboxnewtoken/'),
      );

      final migrated = (await repository.getMessagesRange(
        'conversation',
        start: 0,
        limit: 10,
      )).last;
      expect(
        migrated.parts.whereType<ImagePart>().single.uri,
        '/new/sandboxnewtoken/a.png',
      );
      // Text remains searchable; attachment URIs live outside text FTS.
      expect(
        (await repository.searchConversationMatches(
          tokens: const ['plain'],
        )).single.messageId,
        'plain',
      );

      // Force FTS setup path, then integrity-check on a raw connection.
      await repository.searchConversationMatches(
        tokens: const ['__fts_integrity__'],
      );
      await repository.close();
      repositoryClosed = true;
      final database = sqlite.sqlite3.open(dbFile.path);
      try {
        database.execute(
          "INSERT INTO message_search_fts(message_search_fts) "
          "VALUES('integrity-check');",
        );
      } finally {
        database.close();
      }
    });

    test(
      'stale unavailable cleared when rewritten local file exists',
      () async {
        final newFile = File('${directory.path}/sandboxnewtoken/a.png');
        await newFile.parent.create(recursive: true);
        await newFile.writeAsBytes(const <int>[0x89, 0x50, 0x4E, 0x47]);

        await repository.putMigrationBatch(
          conversations: [
            Conversation(
              id: 'unavailable-conversation',
              title: 'Unavailable',
              messageIds: const ['unavailable-path'],
            ),
          ],
          messages: [
            (
              message: ChatMessage(
                id: 'unavailable-path',
                conversationId: 'unavailable-conversation',
                role: 'user',
                parts: [
                  ImagePart(
                    uri: '/old/sandboxoldtoken/a.png',
                    unavailable: true,
                  ),
                ],
              ),
              messageOrder: 0,
            ),
          ],
          toolEventsByMessageId: const {},
          geminiSignaturesByMessageId: const {},
        );

        await repository.migrateSandboxPaths(
          targetVersion: 1,
          targetRoot: directory.path,
          rewriteUri: (uri) => uri.replaceFirst(
            '/old/sandboxoldtoken/',
            '${directory.path}/sandboxnewtoken/',
          ),
        );

        final migrated = (await repository.getMessagesRange(
          'unavailable-conversation',
          start: 0,
          limit: 10,
        )).single;
        final image = migrated.parts.whereType<ImagePart>().single;
        expect(image.uri, newFile.path);
        expect(image.unavailable, isFalse);
      },
    );

    test('kelivo-file URI stays canonical when targetRoot changes', () async {
      final uploadDir = Directory('${directory.path}/upload')
        ..createSync(recursive: true);
      final file = File('${uploadDir.path}/canon.png')
        ..writeAsBytesSync(const <int>[0x89, 0x50, 0x4E, 0x47]);
      SandboxPathResolver.debugSetDirs(docsDir: directory.path);
      addTearDown(() {
        SandboxPathResolver.debugSetDirs(docsDir: null, supportDir: null);
      });

      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: 'canon-conversation',
            title: 'Canon',
            messageIds: const ['canon-msg'],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: 'canon-msg',
              conversationId: 'canon-conversation',
              role: 'user',
              parts: [
                ImagePart(
                  uri: 'kelivo-file:///upload/canon.png',
                  unavailable: true,
                ),
              ],
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      // Prior receipt with a different root forces a re-run.
      await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/old-root',
        rewriteUri: (uri) => KelivoFileUri.isKelivoFileUri(uri) ? uri : uri,
      );

      final result = await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: directory.path,
        rewriteUri: (uri) => KelivoFileUri.isKelivoFileUri(uri)
            ? uri
            : SandboxPathResolver.fix(uri),
      );

      expect(result.ran, isTrue);
      final migrated = (await repository.getMessagesRange(
        'canon-conversation',
        start: 0,
        limit: 10,
      )).single;
      final image = migrated.parts.whereType<ImagePart>().single;
      expect(image.uri, 'kelivo-file:///upload/canon.png');
      expect(image.unavailable, isFalse);
      expect(file.existsSync(), isTrue);
    });

    test('kelivo-file unavailable recomputed when file missing', () async {
      SandboxPathResolver.debugSetDirs(docsDir: directory.path);
      addTearDown(() {
        SandboxPathResolver.debugSetDirs(docsDir: null, supportDir: null);
      });

      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: 'missing-canon',
            title: 'Missing',
            messageIds: const ['missing-msg'],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: 'missing-msg',
              conversationId: 'missing-canon',
              role: 'user',
              parts: const [
                ImagePart(
                  uri: 'kelivo-file:///upload/does-not-exist.png',
                  unavailable: false,
                ),
              ],
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: '/previous-root',
        rewriteUri: (uri) => KelivoFileUri.isKelivoFileUri(uri) ? uri : uri,
      );

      await repository.migrateSandboxPaths(
        targetVersion: 1,
        targetRoot: directory.path,
        rewriteUri: (uri) => KelivoFileUri.isKelivoFileUri(uri)
            ? uri
            : SandboxPathResolver.fix(uri),
      );

      final migrated = (await repository.getMessagesRange(
        'missing-canon',
        start: 0,
        limit: 10,
      )).single;
      final image = migrated.parts.whereType<ImagePart>().single;
      expect(image.uri, 'kelivo-file:///upload/does-not-exist.png');
      expect(image.unavailable, isTrue);
    });

    test(
      'canonicalize rewrite persists kelivo-file and skips UNC I/O',
      () async {
        final docs = Directory('${directory.path}/docs')..createSync();
        final upload = Directory('${docs.path}/upload')..createSync();
        final file = File('${upload.path}/a.png')
          ..writeAsBytesSync(const [1, 2, 3]);
        SandboxPathResolver.debugSetDirs(docsDir: docs.path);
        addTearDown(() => SandboxPathResolver.debugSetDirs());

        final now = DateTime.utc(2026, 1, 1);
        await repository.putMigrationBatch(
          conversations: [
            Conversation(
              id: 'canon-conversation',
              title: 'Canon',
              createdAt: now,
              updatedAt: now,
              messageIds: const ['canon-msg'],
            ),
          ],
          messages: [
            (
              message: ChatMessage(
                id: 'canon-msg',
                conversationId: 'canon-conversation',
                role: 'user',
                content: '',
                timestamp: now,
                parts: [
                  ImagePart(uri: file.path, mime: 'image/png'),
                  ImagePart(
                    uri: 'file://attacker/share/a.png',
                    mime: 'image/png',
                    unavailable: false,
                  ),
                ],
              ),
              messageOrder: 0,
            ),
          ],
          toolEventsByMessageId: const {},
          geminiSignaturesByMessageId: const {},
        );

        final result = await repository.migrateSandboxPaths(
          targetVersion: 1,
          targetRoot: docs.path,
          rewriteUri: SandboxPathResolver.canonicalize,
        );
        expect(result.ran, isTrue);

        final migrated = (await repository.getMessagesRange(
          'canon-conversation',
          start: 0,
          limit: 10,
        )).single;
        final parts = migrated.parts.whereType<ImagePart>().toList();
        expect(parts[0].uri, 'kelivo-file:///upload/a.png');
        expect(parts[0].unavailable, isFalse);
        expect(parts[1].uri, 'file://attacker/share/a.png');
        expect(parts[1].unavailable, isTrue);
      },
    );

    test('拒绝高于当前实现的已有 migration version', () async {
      await repository.migrateSandboxPaths(
        targetVersion: 2,
        targetRoot: '/future',
        rewriteUri: (uri) => uri,
      );

      await expectLater(
        repository.migrateSandboxPaths(
          targetVersion: 1,
          targetRoot: '/current',
          rewriteUri: (uri) => uri,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'sandbox_path_migration_version',
          ),
        ),
      );
    });
  });
}
