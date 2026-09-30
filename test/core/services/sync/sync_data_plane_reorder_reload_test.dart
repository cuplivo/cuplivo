import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The reload tail of an apply whose only change was the *order* of a
/// conversation's messages: the rows are already here, so every counter the
/// apply reports stays at zero while the timeline the user reads does not. An
/// open window has to be told, or it keeps rendering the pre-sync order.
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

  late Directory root;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase database;
  late ChatDatabaseRepository repository;
  late ChatService chatService;
  late SyncDataPlane dataPlane;
  const conversationId = 'conv';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync_reorder_reload_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
    chatService = ChatService(existingRepository: repository);
    await chatService.init();
    dataPlane = SyncDataPlane(
      repository: repository,
      chatService: chatService,
      businessRepository: BusinessRepository(database),
    );
  });

  tearDown(() async {
    await chatService.close();
    await database.close();
    PathProviderPlatform.instance = previousPathProvider;
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// A conversation an earlier build left shifted: orders far above the count,
  /// which is the state the re-derivation has to repair.
  Future<void> seedShiftedOrder() => repository.putMigrationBatch(
    conversations: [
      Conversation(
        id: conversationId,
        title: conversationId,
      ).copyWith(messageIds: const ['m1', 'm2']),
    ],
    messages: [
      (
        message: ChatMessage(
          id: 'm1',
          conversationId: conversationId,
          role: 'user',
          content: 'm1',
          timestamp: DateTime.fromMicrosecondsSinceEpoch(2000000),
        ),
        messageOrder: 1000000,
      ),
      (
        message: ChatMessage(
          id: 'm2',
          conversationId: conversationId,
          role: 'assistant',
          content: 'm2',
          timestamp: DateTime.fromMicrosecondsSinceEpoch(3000000),
        ),
        messageOrder: 1000001,
      ),
    ],
    toolEventsByMessageId: const {},
    geminiSignaturesByMessageId: const {},
  );

  Future<List<({String id, int order})>> storedOrder() async {
    final rows = await database
        .customSelect(
          'SELECT id, message_order FROM message_rows '
          'WHERE conversation_id = ? ORDER BY message_order, id;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    return [
      for (final row in rows)
        (id: row.read<String>('id'), order: row.read<int>('message_order')),
    ];
  }

  Future<SyncSubtreeApplyOutcome> apply(SyncSubtreePayload payload) async =>
      (await dataPlane.applySubtrees(
        [payload],
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        checkpointRowsByConversation: const {},
      ))[conversationId]!;

  test('a reorder-only apply still rebuilds the conversation it fixed', () async {
    await seedShiftedOrder();

    // The subtree is built from this device's own row shape with an older
    // mutation clock, so the fixture cannot drift from the wire format and every
    // incoming row loses the merge: repairing the order is the only thing this
    // apply does.
    final conversationRow = (await repository.syncReadConversationRow(
      conversationId,
    ))!;
    final payload = SyncSubtreePayload(
      conversation: {
        ...conversationRow,
        'updated_at': (conversationRow['updated_at'] as num).toInt() - 1000000,
      },
      messages: [
        for (final row in await repository.syncReadMessageRows(conversationId))
          {...row, 'updated_at': ((row['updated_at'] as num?) ?? 0) - 1000000},
      ],
      parts: const [],
    );

    final before = chatService.externalWriteRevision(conversationId);
    final outcome = await apply(payload);

    // Every counter says nothing happened — which is exactly why the repair
    // needs a flag of its own: this is the state that used to be reloaded by
    // nobody.
    expect(outcome.upsertedMessages, 0);
    expect(outcome.deletedMessages, 0);
    expect(outcome.conversationRowChanged, isFalse);
    expect(outcome.reordered, isTrue);
    expect(await storedOrder(), [(id: 'm1', order: 0), (id: 'm2', order: 1)]);

    // The open window hears about it, or the user keeps reading the pre-sync
    // order until they leave the conversation and come back.
    expect(
      chatService.externalWriteRevision(conversationId),
      greaterThan(before),
      reason: 'a repaired order changes what the window shows',
    );

    // And it does not over-fire: the same payload applied again has nothing left
    // to repair, so the window stays quiet.
    final settled = chatService.externalWriteRevision(conversationId);
    final again = await apply(payload);
    expect(again.reordered, isFalse);
    expect(
      chatService.externalWriteRevision(conversationId),
      settled,
      reason: 'an apply with nothing to do must not wake the window',
    );
  });
}
