import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/models/group_chat_message.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/chat/group_chat_service.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final chatServices = <ChatService>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'cuplivo_group_chat_service_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    for (final service in chatServices) {
      await service.close();
    }
    chatServices.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<GroupChatService> createGroupService() async {
    final chat = ChatService();
    chatServices.add(chat);
    await chat.init();
    final group = GroupChatService(chatService: chat);
    await group.ensureLoaded();
    return group;
  }

  group('GroupChatService message cache growable', () {
    test(
      'addMessage after getMessages does not throw fixed-length list error',
      () async {
        final svc = await createGroupService();
        final group = await svc.createGroup(
          title: 'Fixed list repro',
          assistantIds: const ['a1', 'a2'],
        );

        // Mirrors opening the group page: load timeline into cache.
        // Repo returns toList(growable: false); prior bug stored that
        // list and crashed on the next add.
        final before = await svc.getMessages(group.id);
        expect(before, isEmpty);

        final written = await svc.addMessage(
          GroupChatMessage(
            groupId: group.id,
            role: 'user',
            content: 'hello group',
          ),
        );

        expect(written.content, 'hello group');
        final after = await svc.getMessages(group.id);
        expect(after, hasLength(1));
        expect(after.single.id, written.id);
        expect(after.single.content, 'hello group');
      },
    );

    test(
      'addMessage after reloadMessages with existing rows stays appendable',
      () async {
        final svc = await createGroupService();
        final group = await svc.createGroup(
          title: 'Reload then send',
          assistantIds: const ['a1', 'a2'],
        );

        await svc.addMessage(
          GroupChatMessage(groupId: group.id, role: 'user', content: 'first'),
        );

        // Drop in-memory cache and reload fixed-length rows from SQLite.
        await svc.reload();
        final loaded = await svc.reloadMessages(group.id);
        expect(loaded, hasLength(1));

        final second = await svc.addMessage(
          GroupChatMessage(groupId: group.id, role: 'user', content: 'second'),
        );

        final timeline = await svc.getMessages(group.id);
        expect(timeline, hasLength(2));
        expect(timeline.last.id, second.id);
        expect(timeline.map((m) => m.content).toList(), ['first', 'second']);
      },
    );

    test('updateMessage and deleteMessage work after getMessages', () async {
      final svc = await createGroupService();
      final group = await svc.createGroup(
        title: 'Update delete',
        assistantIds: const ['a1', 'a2'],
      );

      await svc.getMessages(group.id);
      final msg = await svc.addMessage(
        GroupChatMessage(
          groupId: group.id,
          role: 'assistant',
          content: '',
          speakerAssistantId: 'a1',
          isStreaming: true,
        ),
      );

      await svc.updateMessage(
        msg.copyWith(content: 'streamed', isStreaming: false),
      );
      var timeline = await svc.getMessages(group.id);
      expect(timeline.single.content, 'streamed');
      expect(timeline.single.isStreaming, isFalse);

      await svc.deleteMessage(group.id, msg.id);
      timeline = await svc.getMessages(group.id);
      expect(timeline, isEmpty);
    });
  });
}
