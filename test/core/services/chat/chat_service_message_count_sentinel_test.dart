import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/services/chat/chat_service.dart';

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
  final services = <ChatService>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_message_count_sentinel_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ChatService createService() {
    final service = ChatService();
    services.add(service);
    return service;
  }

  group('message-count unknown-vs-0 sentinel', () {
    test('empty cache with unknown count is not fully cached', () async {
      final service = createService();
      await service.init();
      const id = 'unknown-conversation';

      service.debugPrimeMessageCountState(
        id,
        cachedMessages: const [],
        clearCounts: true,
      );

      expect(service.isMessageCountKnown(id), isFalse);
      expect(service.getMessageCount(id), -1);
      expect(service.isConversationFullyCached(id), isFalse);
    });

    test('known count 0 with empty cache is fully cached', () async {
      final service = createService();
      await service.init();
      final conversation = await service.createConversation(title: 'New');

      service.debugPrimeMessageCountState(
        conversation.id,
        cachedMessages: const [],
        messageCount: 0,
        orderIds: const [],
      );

      expect(service.isMessageCountKnown(conversation.id), isTrue);
      expect(service.getMessageCount(conversation.id), 0);
      expect(service.isConversationFullyCached(conversation.id), isTrue);
    });

    test(
      'isMessageCountKnown covers order-only and unknown; cold start leaves counts unknown',
      () async {
        final writer = createService();
        await writer.init();
        final conversation = await writer.createConversation(title: 'Chat');
        await writer.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'hello',
        );
        await writer.close();
        services.remove(writer);

        final service = createService();
        await service.init();

        expect(service.getConversation(conversation.id), isNotNull);
        expect(service.isMessageCountKnown(conversation.id), isFalse);
        expect(service.getMessageCount(conversation.id), -1);

        service.debugPrimeMessageCountState(
          conversation.id,
          clearCounts: true,
          orderIds: const ['order-only-id'],
        );
        expect(service.isMessageCountKnown(conversation.id), isTrue);
        expect(service.getMessageCount(conversation.id), 1);

        service.debugPrimeMessageCountState(conversation.id, clearCounts: true);
        expect(service.isMessageCountKnown(conversation.id), isFalse);
        expect(service.getMessageCount(conversation.id), -1);

        expect(service.isMessageCountKnown('never-seen'), isFalse);
        expect(service.getMessageCount('never-seen'), -1);
      },
    );
  });
}
