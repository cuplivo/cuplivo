import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';
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

  Completer<void>? gateMessageIds;

  /// When true, only the first [getMessageIds] call awaits [gateMessageIds].
  bool gateOnlyFirstCall = false;
  Object? messageIdsError;
  int getMessageIdsCalls = 0;
  int getMessagesForGroupsCalls = 0;

  @override
  Future<List<String>> getMessageIds(String conversationId) async {
    getMessageIdsCalls += 1;
    final call = getMessageIdsCalls;
    final gate = gateMessageIds;
    if (gate != null && (!gateOnlyFirstCall || call == 1)) {
      await gate.future;
    }
    final error = messageIdsError;
    if (error != null) throw error;
    return super.getMessageIds(conversationId);
  }

  @override
  Future<List<ChatMessage>> getMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async {
    getMessagesForGroupsCalls += 1;
    return super.getMessagesForGroups(conversationId, groupIds);
  }
}

/// Advances a frame then lets queued idle-priority scheduler tasks run.
///
/// Order backfill waits on a post-frame callback before the idle slot, so a
/// plain microtask drain is not enough. Bare `test()` cases have no
/// WidgetTester pump loop — drive the frame callbacks manually.
Future<void> _flushIdleTasks() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.scheduleFrame();
  binding.handleBeginFrame(Duration.zero);
  binding.handleDrawFrame();
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];
  final repositories = <_SpyChatDatabaseRepository>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_message_order_backfill_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    for (final repository in repositories) {
      final gate = repository.gateMessageIds;
      if (gate != null && !gate.isCompleted) {
        gate.complete();
      }
    }
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
    int messageCount = 5,
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

  Future<(String, String, List<String>)> seedMultiVersionConversation() async {
    final writer = createService();
    await writer.init();
    final conversation = await writer.createConversation(title: 'Versions');
    final user = await writer.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: 'prompt',
    );
    final v0 = await writer.addMessage(
      conversationId: conversation.id,
      role: 'assistant',
      content: 'answer v0',
      groupId: 'answer',
      version: 0,
    );
    final v1 = await writer.addMessage(
      conversationId: conversation.id,
      role: 'assistant',
      content: 'answer v1',
      groupId: 'answer',
      version: 1,
    );
    await writer.setSelectedVersion(conversation.id, 'answer', 1);
    await writer.close();
    services.remove(writer);
    return (conversation.id, 'answer', [user.id, v0.id, v1.id]);
  }

  group('loadTimelinePage idle-deferred message-order backfill (Issue 2)', () {
    test(
      'returns page before idle; getMessageIds stays 0 until idle flush',
      () async {
        final (conversationId, ids) = await seedConversation(messageCount: 6);
        final spy = await openSpyRepository();
        spy.gateMessageIds = Completer<void>();
        final service = createService(existingRepository: spy);
        await service.init();

        final page = await service.loadTimelinePage(conversationId, limit: 40);
        expect(page, isNotNull);
        expect(page!.slots, isNotEmpty);

        // Before idle: page usable, skeleton absent, deferred future registered,
        // and getMessageIds has not started.
        expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
        expect(service.isMessageCountKnown(conversationId), isFalse);
        expect(service.getMessageIndex(conversationId, ids.first), -1);
        final backfill = service.debugMessageOrderBackfillFuture(
          conversationId,
        );
        expect(backfill, isNotNull);
        expect(spy.getMessageIdsCalls, 0);

        spy.gateMessageIds!.complete();
        await _flushIdleTasks();
        await backfill;

        expect(spy.getMessageIdsCalls, 1);
        expect(service.debugHasMessageOrderSkeleton(conversationId), isTrue);
        expect(
          service.debugMessageOrderSkeletonLength(conversationId),
          ids.length,
        );
        expect(service.isMessageCountKnown(conversationId), isTrue);
        expect(service.getMessageCount(conversationId), ids.length);
        expect(service.getMessageIndex(conversationId, ids.first), 0);
        expect(
          service.getMessageIndex(conversationId, ids.last),
          ids.length - 1,
        );
        expect(await service.getMessageIds(conversationId), ids);
      },
    );

    test(
      'skeleton becomes complete atomically after idle; never partial',
      () async {
        final (conversationId, ids) = await seedConversation(messageCount: 8);
        final spy = await openSpyRepository();
        spy.gateMessageIds = Completer<void>();
        final service = createService(existingRepository: spy);
        await service.init();

        final observedLengths = <int?>[];
        void observe() {
          if (!service.debugHasMessageOrderSkeleton(conversationId)) {
            observedLengths.add(null);
            return;
          }
          observedLengths.add(
            service.debugMessageOrderSkeletonLength(conversationId),
          );
        }

        observe();
        final page = await service.loadTimelinePage(conversationId, limit: 3);
        expect(page, isNotNull);
        observe();
        expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
        expect(spy.getMessageIdsCalls, 0);

        final backfill = service.debugMessageOrderBackfillFuture(
          conversationId,
        );
        expect(backfill, isNotNull);
        spy.gateMessageIds!.complete();
        await _flushIdleTasks();
        await backfill;
        observe();

        expect(observedLengths, contains(null));
        expect(
          observedLengths.whereType<int>().every((len) => len == ids.length),
          isTrue,
        );
        expect(
          service.debugMessageOrderSkeletonLength(conversationId),
          ids.length,
        );
      },
    );

    test(
      'multiple loadTimelinePage calls schedule at most one full ID backfill',
      () async {
        final (conversationId, _) = await seedConversation(messageCount: 5);
        final spy = await openSpyRepository();
        // Hold the query so the first deferred future cannot finish between
        // page loads (which would clear the map and look like a second plan).
        spy.gateMessageIds = Completer<void>();
        final service = createService(existingRepository: spy);
        await service.init();

        await service.loadTimelinePage(conversationId, limit: 2);
        final first = service.debugMessageOrderBackfillFuture(conversationId);
        expect(first, isNotNull);
        expect(spy.getMessageIdsCalls, 0);

        await service.loadTimelinePage(conversationId, limit: 2);
        expect(
          identical(
            service.debugMessageOrderBackfillFuture(conversationId),
            first,
          ),
          isTrue,
        );
        await service.loadTimelinePage(
          conversationId,
          beforeRevisionId: (await service.loadTimelinePage(
            conversationId,
            limit: 1,
          ))!.slots.first.message.id,
          limit: 2,
        );
        expect(
          identical(
            service.debugMessageOrderBackfillFuture(conversationId),
            first,
          ),
          isTrue,
        );
        expect(spy.getMessageIdsCalls, 0);

        spy.gateMessageIds!.complete();
        await _flushIdleTasks();
        await first;
        expect(spy.getMessageIdsCalls, 1);
        expect(service.debugHasMessageOrderSkeleton(conversationId), isTrue);
      },
    );

    test(
      'failed getMessageIds leaves page usable, no bad known count, retry ok',
      () async {
        final (conversationId, ids) = await seedConversation(messageCount: 4);
        final spy = await openSpyRepository();
        spy.gateMessageIds = Completer<void>();
        spy.messageIdsError = StateError('boom_getMessageIds');
        final service = createService(existingRepository: spy);
        await service.init();

        final page = await service.loadTimelinePage(conversationId, limit: 40);
        expect(page, isNotNull);
        expect(page!.slots, isNotEmpty);
        expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
        expect(spy.getMessageIdsCalls, 0);

        final backfill = service.debugMessageOrderBackfillFuture(
          conversationId,
        );
        expect(backfill, isNotNull);
        spy.gateMessageIds!.complete();
        await _flushIdleTasks();
        await backfill;

        expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
        expect(service.debugMessageOrderSkeletonLength(conversationId), isNull);
        expect(service.isMessageCountKnown(conversationId), isFalse);
        expect(service.getMessageIndex(conversationId, ids.first), -1);
        expect(page.slots, isNotEmpty);

        // Retry allowed after failure.
        spy.messageIdsError = null;
        spy.gateMessageIds = null;
        await service.loadTimelinePage(conversationId, limit: 40);
        final retry = service.debugMessageOrderBackfillFuture(conversationId);
        expect(retry, isNotNull);
        await _flushIdleTasks();
        await retry;
        expect(service.debugHasMessageOrderSkeleton(conversationId), isTrue);
        expect(service.getMessageCount(conversationId), ids.length);
      },
    );

    test('delete while deferred does not resurrect order/count', () async {
      final (conversationId, _) = await seedConversation(messageCount: 4);
      final spy = await openSpyRepository();
      spy.gateMessageIds = Completer<void>();
      final service = createService(existingRepository: spy);
      await service.init();

      await service.loadTimelinePage(conversationId, limit: 40);
      final backfill = service.debugMessageOrderBackfillFuture(conversationId);
      expect(backfill, isNotNull);
      expect(spy.getMessageIdsCalls, 0);

      await service.deleteConversation(conversationId);
      spy.gateMessageIds!.complete();
      await _flushIdleTasks();
      await backfill;

      expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
      expect(service.isMessageCountKnown(conversationId), isFalse);
    });

    test('close completes while idle backfill is still deferred', () async {
      final (conversationId, _) = await seedConversation(messageCount: 3);
      final spy = await openSpyRepository();
      spy.gateMessageIds = Completer<void>();
      final service = createService(existingRepository: spy);
      await service.init();

      await service.loadTimelinePage(conversationId, limit: 40);
      expect(
        service.debugMessageOrderBackfillFuture(conversationId),
        isNotNull,
      );
      expect(spy.getMessageIdsCalls, 0);

      await service.close().timeout(const Duration(seconds: 2));
      services.remove(service);
      spy.gateMessageIds!.complete();
    });

    test(
      'loadMessagesForGroups merges bodies without installing order skeleton',
      () async {
        final (conversationId, groupId, ids) =
            await seedMultiVersionConversation();
        final spy = await openSpyRepository();
        spy.gateMessageIds = Completer<void>();
        final service = createService(existingRepository: spy);
        await service.init();

        final page = await service.loadTimelinePage(conversationId, limit: 40);
        expect(page, isNotNull);
        expect(spy.getMessageIdsCalls, 0);

        final versions = await service.loadMessagesForGroups(conversationId, [
          groupId,
        ]);
        expect(versions, hasLength(2));
        expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
        expect(service.isMessageCountKnown(conversationId), isFalse);
        expect(spy.getMessageIdsCalls, 0);
        expect(spy.getMessagesForGroupsCalls, greaterThan(0));

        // Cached group bodies are readable without full order.
        expect(
          service
              .getMessagesForGroups(conversationId, [groupId])
              .map((m) => m.id)
              .toSet(),
          {ids[1], ids[2]},
        );

        spy.gateMessageIds!.complete();
        await _flushIdleTasks();
        await service.debugMessageOrderBackfillFuture(conversationId);
        expect(service.debugHasMessageOrderSkeleton(conversationId), isTrue);
      },
    );

    test(
      'multi-version first screen completes with getMessageIds gated; preload only',
      () async {
        final (conversationId, groupId, ids) =
            await seedMultiVersionConversation();
        final spy = await openSpyRepository();
        spy.gateMessageIds = Completer<void>();
        final service = createService(existingRepository: spy);
        await service.init();
        final controller = ChatController(chatService: service);
        addTearDown(controller.dispose);

        await controller.setCurrentConversationAndLoad(
          service.getConversation(conversationId)!,
        );

        // Fetch/open completed while full order is still gated.
        expect(controller.collapsedMessages, isNotEmpty);
        expect(controller.collapsedMessages.last.id, ids.last);
        expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
        expect(spy.getMessageIdsCalls, 0);
        expect(spy.getMessagesForGroupsCalls, greaterThan(0));
        expect(
          service
              .getMessagesForGroups(conversationId, [groupId])
              .map((m) => m.id)
              .toSet(),
          {ids[1], ids[2]},
        );

        spy.gateMessageIds!.complete();
        await _flushIdleTasks();
        await service.debugMessageOrderBackfillFuture(conversationId);
        expect(spy.getMessageIdsCalls, 1);
        expect(service.debugHasMessageOrderSkeleton(conversationId), isTrue);
        expect(
          service.debugMessageOrderSkeletonLength(conversationId),
          ids.length,
        );
      },
    );

    test(
      'failed backfill does not wipe foreground-installed complete order',
      () async {
        final (conversationId, seededIds) = await seedConversation(
          messageCount: 6,
        );
        final spy = await openSpyRepository();
        spy.gateMessageIds = Completer<void>();
        spy.gateOnlyFirstCall = true;
        final service = createService(existingRepository: spy);
        await service.init();

        await service.loadTimelinePage(conversationId, limit: 40);
        final backfill = service.debugMessageOrderBackfillFuture(
          conversationId,
        );
        expect(backfill, isNotNull);
        await _flushIdleTasks();
        // Background call 1 is blocked; order still absent.
        expect(spy.getMessageIdsCalls, 1);
        expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);

        // Foreground path installs a complete skeleton while backfill waits.
        final sent = await service.addMessage(
          conversationId: conversationId,
          role: 'user',
          content: 'foreground send',
        );
        expect(spy.getMessageIdsCalls, 2);
        expect(service.debugHasMessageOrderSkeleton(conversationId), isTrue);
        expect(service.isMessageCountKnown(conversationId), isTrue);
        expect(
          service.debugMessageOrderSkeletonLength(conversationId),
          seededIds.length + 1,
        );
        final orderAfterForeground = await service.getMessageIds(
          conversationId,
        );
        expect(orderAfterForeground, [...seededIds, sent.id]);
        expect(service.getMessageCount(conversationId), seededIds.length + 1);

        // Background call 1 fails — must not delete the foreground cache.
        spy.messageIdsError = StateError('boom_stale_backfill');
        spy.gateMessageIds!.complete();
        await backfill;

        expect(service.debugHasMessageOrderSkeleton(conversationId), isTrue);
        expect(service.isMessageCountKnown(conversationId), isTrue);
        expect(await service.getMessageIds(conversationId), [
          ...seededIds,
          sent.id,
        ]);
        expect(service.getMessageCount(conversationId), seededIds.length + 1);
        for (final id in seededIds) {
          expect(service.getMessageIndex(conversationId, id), greaterThan(-1));
        }

        // Subsequent send keeps full history in the authoritative order.
        final sent2 = await service.addMessage(
          conversationId: conversationId,
          role: 'assistant',
          content: 'after failed backfill',
        );
        final orderAfterSend = await service.getMessageIds(conversationId);
        expect(orderAfterSend, [...seededIds, sent.id, sent2.id]);
        expect(service.getMessageCount(conversationId), seededIds.length + 2);
      },
    );
  });
}
