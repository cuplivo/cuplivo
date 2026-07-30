import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/director_session.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/group_chat_member.dart';
import 'package:Cuplivo/core/models/group_chat_message.dart';
import 'package:Cuplivo/core/models/incremental_backup.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/chat/group_chat_service.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

void main() {
  group('DataSync backup file', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_data_sync_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      SharedPreferences.setMockInitialValues({'backup_test_key': 'value'});
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test(
      'packs files as deflated zip entries and removes staging files',
      () async {
        final uploadDir = Directory('${root.path}/upload');
        await uploadDir.create(recursive: true);
        final uploadFile = File('${uploadDir.path}/large.bin');
        await uploadFile.writeAsBytes(List<int>.filled(1024 * 1024, 7));
        final fontsDir = Directory('${root.path}/fonts');
        await fontsDir.create(recursive: true);
        final fontFile = File('${fontsDir.path}/custom.ttf');
        await fontFile.writeAsBytes(List<int>.filled(256, 9));

        final tmpDir = Directory('${root.path}/tmp');
        final staleWorkDir = Directory('${tmpDir.path}/kelivo_backup_stale');
        await staleWorkDir.create(recursive: true);
        await File('${staleWorkDir.path}/orphan.zip').writeAsString('old');
        await File('${tmpDir.path}/kelivo_backup_old.zip').writeAsString('old');
        await File('${tmpDir.path}/_bk_chats.json').writeAsString('{}');

        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: true),
        );

        expect(await staleWorkDir.exists(), isFalse);
        expect(
          await File('${tmpDir.path}/kelivo_backup_old.zip').exists(),
          isFalse,
        );
        expect(await File('${tmpDir.path}/_bk_chats.json').exists(), isFalse);

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final settingsEntry = archive.findFile('settings.json');
          final uploadEntry = archive.findFile('upload/large.bin');
          final fontEntry = archive.findFile('fonts/custom.ttf');

          expect(settingsEntry, isNotNull);
          expect(uploadEntry, isNotNull);
          expect(fontEntry, isNotNull);
          expect(settingsEntry!.compression, CompressionType.deflate);
          expect(uploadEntry!.compression, CompressionType.deflate);
          expect(fontEntry!.compression, CompressionType.deflate);
          expect(uploadEntry.readBytes(), List<int>.filled(1024 * 1024, 7));
          expect(fontEntry.readBytes(), List<int>.filled(256, 9));
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        expect(
          await File('${backupFile.parent.path}/_bk_settings.json').exists(),
          isFalse,
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);

        expect(await backupFile.exists(), isFalse);
        expect(await backupFile.parent.exists(), isFalse);
      },
    );

    test('restores managed font files in overwrite and merge modes', () async {
      final sourceDir = Directory('${root.path}/source_fonts');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/custom.ttf');
      await sourceFile.writeAsBytes(List<int>.filled(128, 5));

      final zipFile = File('${root.path}/fonts_backup.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'fonts/custom.ttf');
      encoder.closeSync();

      final fontsDir = Directory('${root.path}/fonts');
      await fontsDir.create(recursive: true);
      final existingFile = File('${fontsDir.path}/existing.ttf');
      await existingFile.writeAsBytes(List<int>.filled(64, 3));

      final sync = DataSync(chatService: ChatService());
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: true),
        mode: RestoreMode.merge,
      );

      expect(await existingFile.exists(), isTrue);
      expect(
        await File('${fontsDir.path}/custom.ttf').readAsBytes(),
        List<int>.filled(128, 5),
      );

      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: true),
        mode: RestoreMode.overwrite,
      );

      expect(await existingFile.exists(), isFalse);
      expect(
        await File('${fontsDir.path}/custom.ttf').readAsBytes(),
        List<int>.filled(128, 5),
      );
    });

    test(
      'merge restore imports assistant memories and mcp servers without clobbering local entries',
      () async {
        SharedPreferences.setMockInitialValues({
          'assistant_memories_v1': jsonEncode([
            {'id': 1, 'assistantId': 'local', 'content': 'keep local'},
            {'id': 2, 'assistantId': 'dup', 'content': 'same memory'},
          ]),
          'mcp_servers_v1': jsonEncode([
            {
              'id': 'local-server',
              'enabled': true,
              'name': 'Local Server',
              'transport': 'sse',
              'url': 'http://local.example/sse',
              'tools': [],
            },
            {
              'id': 'shared-server',
              'enabled': true,
              'name': 'Local Shared Server',
              'transport': 'sse',
              'url': 'http://local-shared.example/sse',
              'tools': [],
            },
          ]),
        });

        final settingsFile = File('${root.path}/settings.json');
        await settingsFile.writeAsString(
          jsonEncode({
            'assistant_memories_v1': jsonEncode([
              {'id': 1, 'assistantId': 'remote', 'content': 'remote memory'},
              {'id': 2, 'assistantId': 'dup', 'content': 'same memory'},
              {'id': 4, 'assistantId': 'new', 'content': 'new memory'},
            ]),
            'mcp_servers_v1': jsonEncode([
              {
                'id': 'shared-server',
                'enabled': false,
                'name': 'Imported Shared Server',
                'transport': 'sse',
                'url': 'http://imported-shared.example/sse',
                'tools': [],
              },
              {
                'id': 'remote-server',
                'enabled': true,
                'name': 'Remote Server',
                'transport': 'http',
                'url': 'http://remote.example/mcp',
                'tools': [],
              },
            ]),
          }),
        );

        final zipFile = File('${root.path}/settings_merge_backup.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        encoder.addFileSync(settingsFile, 'settings.json');
        encoder.closeSync();

        final sync = DataSync(chatService: ChatService());
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.merge,
        );

        final prefs = await SharedPreferences.getInstance();
        final memories =
            jsonDecode(prefs.getString('assistant_memories_v1')!) as List;
        expect(memories, hasLength(4));
        expect(
          memories.where(
            (e) =>
                (e as Map)['assistantId'] == 'dup' &&
                e['content'] == 'same memory',
          ),
          hasLength(1),
        );
        expect(
          memories.any(
            (e) =>
                (e as Map)['assistantId'] == 'remote' &&
                e['content'] == 'remote memory' &&
                e['id'] != 1,
          ),
          isTrue,
        );
        expect(
          memories.any(
            (e) =>
                (e as Map)['assistantId'] == 'new' &&
                e['content'] == 'new memory' &&
                e['id'] == 4,
          ),
          isTrue,
        );

        final servers = jsonDecode(prefs.getString('mcp_servers_v1')!) as List;
        expect(servers, hasLength(3));
        expect(
          servers
              .where((e) => (e as Map)['id'] == 'shared-server')
              .single['name'],
          'Local Shared Server',
        );
        expect(
          servers.any(
            (e) =>
                (e as Map)['id'] == 'remote-server' &&
                e['name'] == 'Remote Server',
          ),
          isTrue,
        );
      },
    );

    test('cleans temporary restore files when WebDAV restore fails', () async {
      final sourceDir = Directory('${root.path}/source_upload');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/file.txt');
      await sourceFile.writeAsString('payload');

      final zipFile = File('${root.path}/restore_source.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(sourceFile, 'upload/file.txt');
      encoder.closeSync();

      await File('${root.path}/upload').writeAsString('not a directory');

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        await request.response.addStream(zipFile.openRead());
        await request.response.close();
      });

      final sync = DataSync(chatService: ChatService());
      final tmpDir = Directory('${root.path}/tmp');
      final item = BackupFileItem(
        href: Uri.parse('http://127.0.0.1:${server.port}/restore_source.zip'),
        displayName: 'restore_source.zip',
        size: await zipFile.length(),
        lastModified: null,
      );

      await expectLater(
        sync.restoreFromWebDav(
          const WebDavConfig(includeChats: false, includeFiles: true),
          item,
        ),
        throwsA(anything),
      );

      expect(await File('${tmpDir.path}/restore_source.zip').exists(), isFalse);
      expect(await tmpDir.list().toList(), isEmpty);
    });

    test(
      'incremental: since param produces cuplivo_incr_ prefix and includeSettings=false excludes settings.json',
      () async {
        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: DateTime.now().subtract(const Duration(days: 30)),
            includeSettings: false,
          ),
        );

        expect(p.basename(backupFile.path).startsWith('cuplivo_incr_'), isTrue);

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('settings.json'), isNull);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test(
      'incremental: no since param produces normal filename without cuplivo_incr_',
      () async {
        final sync = DataSync(chatService: ChatService());
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: false, includeFiles: false),
        );

        expect(
          p.basename(backupFile.path).startsWith('cuplivo_incr_'),
          isFalse,
        );
        expect(
          p.basename(backupFile.path),
          matches(RegExp(r'kelivo_backup_\d{8}T\d{6}\.\d{6}\.zip')),
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);
      },
    );

    test(
      'incremental: cuplivo_incr_ filename forces merge mode on restore',
      () async {
        final zipFile = File(
          '${root.path}/cuplivo_incr_20260703-123456-123456_20260701-000000.zip',
        );
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        final settingsTmp = File('${root.path}/tmp_settings.json');
        await settingsTmp.writeAsString('{}');
        encoder.addFileSync(settingsTmp, 'settings.json');
        encoder.closeSync();

        final sync = DataSync(chatService: ChatService());
        // Should not throw: overwrite mode is silently degraded to merge
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.overwrite,
        );
      },
    );

    test('incremental: includeFiles=true packs upload and fonts', () async {
      final uploadDir = Directory('${root.path}/upload');
      await uploadDir.create(recursive: true);
      await File('${uploadDir.path}/doc.txt').writeAsString('hello');
      final fontsDir = Directory('${root.path}/fonts');
      await fontsDir.create(recursive: true);
      await File(
        '${fontsDir.path}/custom.ttf',
      ).writeAsBytes(List<int>.filled(64, 9));

      final sync = DataSync(chatService: ChatService());
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(includeChats: false, includeFiles: true),
        incremental: IncrementalBackupConfig(
          since: DateTime.now().subtract(const Duration(days: 30)),
          includeFiles: true,
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        expect(archive.findFile('settings.json'), isNotNull);
        expect(archive.findFile('upload/doc.txt'), isNotNull);
        expect(archive.findFile('fonts/custom.ttf'), isNotNull);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test('incremental: includeFiles=false excludes files', () async {
      final uploadDir = Directory('${root.path}/upload');
      await uploadDir.create(recursive: true);
      await File('${uploadDir.path}/doc.txt').writeAsString('hello');

      final sync = DataSync(chatService: ChatService());
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(includeChats: false, includeFiles: true),
        incremental: IncrementalBackupConfig(
          since: DateTime.now().subtract(const Duration(days: 30)),
          includeSettings: false,
          includeFiles: false,
        ),
      );

      final input = InputFileStream(backupFile.path);
      Archive? archive;
      try {
        archive = ZipDecoder().decodeStream(input);
        expect(archive.findFile('settings.json'), isNull);
        expect(archive.findFile('upload/doc.txt'), isNull);
      } finally {
        archive?.clearSync();
        input.closeSync();
      }

      await DataSync.cleanupTemporaryBackupFile(backupFile);
    });

    test(
      'round-trips complete group aggregates and sidecar artifacts',
      () async {
        final chatService = ChatService();
        await chatService.init();
        final groupService = GroupChatService(chatService: chatService);
        await groupService.ensureLoaded();

        final group = GroupChat(id: 'backup-group', title: 'Backup Group');
        final members = [
          GroupChatMember(
            id: 'backup-user',
            groupId: group.id,
            kind: GroupChatMember.kindUser,
          ),
          GroupChatMember(
            id: 'backup-a1',
            groupId: group.id,
            kind: GroupChatMember.kindAssistant,
            assistantId: 'a1',
            sortOrder: 1,
          ),
          GroupChatMember(
            id: 'backup-a2',
            groupId: group.id,
            kind: GroupChatMember.kindAssistant,
            assistantId: 'a2',
            sortOrder: 2,
          ),
        ];
        final message = GroupChatMessage(
          id: 'backup-group-message',
          groupId: group.id,
          role: 'assistant',
          speakerAssistantId: 'a1',
          content: 'group answer',
          reasoningText: 'private reasoning',
        );
        await chatService.repo.putGroupChatRestoreBatch(
          groups: [group],
          membersByGroup: {group.id: members},
          messagesByGroup: {
            group.id: [message],
          },
          directorSessions: [
            DirectorSession(
              id: 'backup-director',
              groupId: group.id,
              status: DirectorSession.statusDone,
              messages: const [
                {'role': 'assistant', 'content': 'decision'},
              ],
            ),
          ],
          toolEventsByMessageId: {
            message.id: [
              {
                'id': 'tool-1',
                'name': 'search',
                'arguments': {'q': 'Cuplivo'},
                'content': 'result',
              },
            ],
          },
          geminiThoughtSignaturesByMessageId: {message.id: 'signature-1'},
        );
        await groupService.reload();

        final sync = DataSync(
          chatService: chatService,
          groupChatService: groupService,
        );
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: true, includeFiles: false),
        );

        await chatService.clearAllData();
        await groupService.reload();
        expect(groupService.getAllGroups(), isEmpty);

        await sync.restoreFromLocalFile(
          backupFile,
          const WebDavConfig(includeChats: true, includeFiles: false),
        );

        expect(groupService.getAllGroups().single.id, group.id);
        expect(await groupService.getMembers(group.id), hasLength(3));
        expect(
          (await groupService.getMessages(group.id)).single.content,
          'group answer',
        );
        expect(
          await chatService.repo.getGroupToolEvents(message.id),
          hasLength(1),
        );
        expect(
          await chatService.repo.getGroupGeminiThoughtSignature(message.id),
          'signature-1',
        );
        expect(
          (await groupService.getDirectorSession(group.id))?.id,
          'backup-director',
        );

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental export includes the complete changed group aggregate',
      () async {
        final chatService = ChatService();
        await chatService.init();
        final since = DateTime.now().subtract(const Duration(days: 30));
        final group = GroupChat(
          id: 'changed-group',
          title: 'Changed Group',
          createdAt: since.subtract(const Duration(days: 30)),
          updatedAt: since.add(const Duration(days: 1)),
        );
        final oldMessage = GroupChatMessage(
          id: 'old-group-message',
          groupId: group.id,
          role: 'user',
          content: 'older but required for a complete aggregate',
          timestamp: since.subtract(const Duration(days: 20)),
        );
        await chatService.repo.putGroupChatRestoreBatch(
          groups: [group],
          membersByGroup: {
            group.id: [
              GroupChatMember(
                id: 'changed-user',
                groupId: group.id,
                kind: GroupChatMember.kindUser,
              ),
            ],
          },
          messagesByGroup: {
            group.id: [oldMessage],
          },
          directorSessions: const [],
        );

        final sync = DataSync(chatService: chatService);
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: true, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );
        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final chats = archive.findFile('chats.json');
          final data =
              jsonDecode(utf8.decode(chats!.readBytes() ?? const <int>[]))
                  as Map<String, dynamic>;
          expect((data['groups'] as List).single['id'], group.id);
          expect((data['groupMembers'] as List), hasLength(1));
          expect((data['groupMessages'] as List).single['id'], oldMessage.id);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'legacy chats backup without group fields restores as empty groups',
      () async {
        final chatsFile = File('${root.path}/legacy_chats.json');
        await chatsFile.writeAsString(
          jsonEncode({
            'version': 1,
            'conversations': <Object?>[],
            'messages': <Object?>[],
            'toolEvents': <String, Object?>{},
            'geminiThoughtSigs': <String, Object?>{},
          }),
        );
        final zipFile = File('${root.path}/legacy_backup.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipFile.path);
        encoder.addFileSync(chatsFile, 'chats.json');
        encoder.closeSync();

        final chatService = ChatService();
        await chatService.init();
        final groupService = GroupChatService(chatService: chatService);
        await groupService.ensureLoaded();
        await chatService.repo.putGroupChat(
          GroupChat(id: 'local-group', title: 'Local Group'),
        );
        await groupService.reload();

        final sync = DataSync(
          chatService: chatService,
          groupChatService: groupService,
        );
        await sync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: true, includeFiles: false),
        );

        expect(groupService.getAllGroups(), isEmpty);
        await chatService.close();
      },
    );

    test(
      'incremental: message-level filtering captures old conversation with new messages',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final recentDate = DateTime.now().subtract(const Duration(days: 1));
        final since = DateTime.now().subtract(const Duration(days: 30));

        final conv = Conversation(
          id: 'test-conv-1',
          title: 'Old Conversation',
          createdAt: oldDate,
          updatedAt: recentDate,
          messageIds: ['msg-old', 'msg-recent'],
        );
        final oldMsg = ChatMessage(
          id: 'msg-old',
          role: 'user',
          content: 'old message',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        final recentMsg = ChatMessage(
          id: 'msg-recent',
          role: 'assistant',
          content: 'recent message',
          timestamp: recentDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        await chatService.restoreConversation(conv, [oldMsg, recentMsg]);

        final sync = DataSync(chatService: chatService);
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: true, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final chatsEntry = archive.findFile('chats.json');
          expect(chatsEntry, isNotNull);

          final data =
              jsonDecode(utf8.decode((chatsEntry!.readBytes() ?? <int>[])))
                  as Map<String, dynamic>;
          final convs = data['conversations'] as List;
          final msgs = data['messages'] as List;
          final toolEvents = data['toolEvents'] as Map;

          expect(convs, hasLength(1));
          expect(convs[0]['id'], 'test-conv-1');
          expect(msgs, hasLength(1));
          expect(msgs[0]['id'], 'msg-recent');
          expect(toolEvents, isEmpty);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: message-level filtering skips old conversation with no new messages',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final since = DateTime.now().subtract(const Duration(days: 30));

        final conv = Conversation(
          id: 'test-conv-2',
          title: 'Stale Conversation',
          createdAt: oldDate,
          updatedAt: oldDate,
          messageIds: ['msg-old-only'],
        );
        final oldMsg = ChatMessage(
          id: 'msg-old-only',
          role: 'user',
          content: 'old message',
          timestamp: oldDate,
          conversationId: conv.id,
          isStreaming: false,
        );
        await chatService.restoreConversation(conv, [oldMsg]);

        final sync = DataSync(chatService: chatService);
        final backupFile = await sync.prepareBackupFile(
          const WebDavConfig(includeChats: true, includeFiles: false),
          incremental: IncrementalBackupConfig(
            since: since,
            includeSettings: false,
            includeFiles: false,
          ),
        );

        final input = InputFileStream(backupFile.path);
        Archive? archive;
        try {
          archive = ZipDecoder().decodeStream(input);
          final chatsEntry = archive.findFile('chats.json');
          expect(chatsEntry, isNotNull);

          final data =
              jsonDecode(utf8.decode(chatsEntry!.readBytes() ?? <int>[]))
                  as Map<String, dynamic>;
          final convs = data['conversations'] as List;
          final msgs = data['messages'] as List;

          expect(convs, isEmpty);
          expect(msgs, isEmpty);
        } finally {
          archive?.clearSync();
          input.closeSync();
        }

        await DataSync.cleanupTemporaryBackupFile(backupFile);
        await chatService.close();
      },
    );

    test(
      'incremental: analyzeIncrementalScope returns correct counts',
      () async {
        final chatService = ChatService();
        await chatService.init();

        final since = DateTime.now().subtract(const Duration(days: 30));
        final oldDate = DateTime.now().subtract(const Duration(days: 60));
        final recentDate = DateTime.now().subtract(const Duration(days: 1));

        // New conversation (created after since)
        final newConv = Conversation(
          id: 'new-conv',
          title: 'New Chat',
          createdAt: since.add(const Duration(hours: 1)),
          updatedAt: since.add(const Duration(hours: 1)),
          messageIds: ['msg-n1', 'msg-n2'],
        );
        await chatService.restoreConversation(newConv, [
          ChatMessage(
            id: 'msg-n1',
            role: 'user',
            content: 'hello',
            timestamp: since.add(const Duration(hours: 1)),
            conversationId: newConv.id,
            isStreaming: false,
          ),
          ChatMessage(
            id: 'msg-n2',
            role: 'assistant',
            content: 'hi',
            timestamp: since.add(const Duration(hours: 2)),
            conversationId: newConv.id,
            isStreaming: false,
          ),
        ]);

        // Old conversation with new message
        final oldConv = Conversation(
          id: 'old-conv',
          title: 'Old Chat',
          createdAt: oldDate,
          updatedAt: recentDate,
          messageIds: ['msg-o1', 'msg-o2'],
        );
        await chatService.restoreConversation(oldConv, [
          ChatMessage(
            id: 'msg-o1',
            role: 'user',
            content: 'old msg',
            timestamp: oldDate,
            conversationId: oldConv.id,
            isStreaming: false,
          ),
          ChatMessage(
            id: 'msg-o2',
            role: 'user',
            content: 'recent msg',
            timestamp: recentDate,
            conversationId: oldConv.id,
            isStreaming: false,
          ),
        ]);

        // Stale conversation (no new messages)
        final staleConv = Conversation(
          id: 'stale-conv',
          title: 'Stale Chat',
          createdAt: oldDate,
          updatedAt: oldDate,
          messageIds: ['msg-s1'],
        );
        await chatService.restoreConversation(staleConv, [
          ChatMessage(
            id: 'msg-s1',
            role: 'user',
            content: 'stale',
            timestamp: oldDate,
            conversationId: staleConv.id,
            isStreaming: false,
          ),
        ]);

        final sync = DataSync(chatService: chatService);
        final scope = await sync.analyzeIncrementalScope(
          IncrementalBackupConfig(since: since, includeFiles: false),
        );

        expect(scope.newConversations.count, 1);
        expect(scope.newConversations.messageCount, 2);
        expect(scope.newConversations.oldestTitle, 'New Chat');
        expect(scope.updatedConversations.count, 1);
        expect(scope.updatedConversations.messageCount, 1);
        expect(scope.updatedConversations.oldestTitle, 'Old Chat');
        expect(scope.newFileCount, 0);

        await chatService.close();
      },
    );
  });
}
