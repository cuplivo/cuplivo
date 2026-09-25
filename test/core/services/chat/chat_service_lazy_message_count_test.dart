import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/utils/app_directories.dart';

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

class _SpyChatDatabaseRepository extends ChatDatabaseRepository {
  _SpyChatDatabaseRepository(super.db, {super.databaseFile});

  int messageCountsByConversationCalls = 0;
  int perConversationMessageCountCalls = 0;
  final List<int> messagesRangeLimits = <int>[];

  @override
  Future<Map<String, int>> getMessageCountsByConversation() async {
    messageCountsByConversationCalls++;
    return super.getMessageCountsByConversation();
  }

  @override
  Future<int> getMessageCount(String conversationId) async {
    perConversationMessageCountCalls++;
    return super.getMessageCount(conversationId);
  }

  @override
  Future<List<ChatMessage>> getMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) async {
    messagesRangeLimits.add(limit);
    return super.getMessagesRange(conversationId, start: start, limit: limit);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];
  final repositories = <ChatDatabaseRepository>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_lazy_message_count_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    for (final repository in repositories) {
      await repository.close();
    }
    repositories.clear();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ChatService createService({ChatDatabaseRepository? existingRepository}) {
    final service = ChatService(existingRepository: existingRepository);
    services.add(service);
    return service;
  }

  Future<File> databaseFile() async {
    final appDataDir = await AppDirectories.getAppDataDirectory();
    return File('${appDataDir.path}/${AppDatabase.databaseFileName}');
  }

  Future<_SpyChatDatabaseRepository> openSpyRepository() async {
    final file = await databaseFile();
    final spy = _SpyChatDatabaseRepository(
      AppDatabase.open(file: file),
      databaseFile: file,
    );
    await spy.ensureReady();
    repositories.add(spy);
    return spy;
  }

  Future<(String, List<String>)> seedConversation({
    int messageCount = 3,
  }) async {
    final writer = createService();
    await writer.init();
    final conversation = await writer.createConversation(title: 'Chat');
    final ids = <String>[];
    for (var i = 0; i < messageCount; i++) {
      final message = await writer.addMessage(
        conversationId: conversation.id,
        role: i.isEven ? 'user' : 'assistant',
        content: 'message $i',
      );
      ids.add(message.id);
    }
    await writer.close();
    services.remove(writer);
    return (conversation.id, ids);
  }

  group('lazy message-count cold start (Issue 3)', () {
    test(
      'cold-start path does not call getMessageCountsByConversation and leaves counts unknown',
      () async {
        final (conversationId, _) = await seedConversation(messageCount: 2);
        final spy = await openSpyRepository();
        final service = createService(existingRepository: spy);

        await service.init();

        expect(spy.messageCountsByConversationCalls, 0);
        expect(service.getConversation(conversationId), isNotNull);
        expect(service.isMessageCountKnown(conversationId), isFalse);
        expect(service.getMessageCount(conversationId), -1);
      },
    );

    test(
      'loadRecentMessages with unknown count returns non-empty for N>0 and backfills count',
      () async {
        final (conversationId, ids) = await seedConversation(messageCount: 4);
        final spy = await openSpyRepository();
        final service = createService(existingRepository: spy);
        await service.init();

        expect(service.isMessageCountKnown(conversationId), isFalse);
        expect(service.getMessageCount(conversationId), -1);

        final recent = await service.loadRecentMessages(conversationId);

        expect(recent, isNotEmpty);
        expect(recent.length, lessThanOrEqualTo(ids.length));
        expect(service.isMessageCountKnown(conversationId), isTrue);
        expect(service.getMessageCount(conversationId), ids.length);
        // -1 must never be treated as the empty-conversation short-circuit.
        expect(spy.perConversationMessageCountCalls, greaterThan(0));
      },
    );

    test(
      'loadMessages with unknown count takes DB path, never uses limit -1, and backfills',
      () async {
        final (conversationId, ids) = await seedConversation(messageCount: 3);
        final spy = await openSpyRepository();
        final service = createService(existingRepository: spy);
        await service.init();

        // Simulate a stale empty cache hit candidate with unknown count.
        service.debugPrimeMessageCountState(
          conversationId,
          cachedMessages: const [],
          clearCounts: true,
        );
        expect(service.isMessageCountKnown(conversationId), isFalse);
        expect(service.isConversationFullyCached(conversationId), isFalse);

        final messages = await service.loadMessages(conversationId);

        expect(messages.map((m) => m.id), ids);
        expect(service.isMessageCountKnown(conversationId), isTrue);
        expect(service.getMessageCount(conversationId), ids.length);
        expect(service.isConversationFullyCached(conversationId), isTrue);
        expect(spy.messagesRangeLimits, isNotEmpty);
        expect(spy.messagesRangeLimits, everyElement(greaterThanOrEqualTo(0)));
        expect(spy.messagesRangeLimits, isNot(contains(-1)));
        expect(spy.messagesRangeLimits.first, ids.length);
        expect(spy.perConversationMessageCountCalls, greaterThan(0));
        expect(spy.messageCountsByConversationCalls, 0);
      },
    );
  });
}
