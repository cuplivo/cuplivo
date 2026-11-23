// A page carries every part of every row it carries.
//
// The parts of a page's own rows are one contiguous id interval, and the rows a
// cursor stepped over — a message written while the transfer ran sorts *below*
// the page that finally carries it — are outside it. Reading parts by interval
// alone therefore lost the whole page's parts the moment one late row rode
// along, silently: both sides would compose a digest with no part lines and
// record it as an agreement, and the text would be gone on the receiver while
// the sender still held it.
//
// The case pins both halves of the fix: the late row is carried, and the page
// still carries its own four parts plus that row's.
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:Cuplivo/core/services/sync/sync_budget.dart';
import 'package:Cuplivo/core/services/sync/sync_family_registry.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_probe_page_parts_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows can keep a handle for a moment; the temp dir is disposable.
    }
  });

  Future<SyncDataPlane> planeIn(AppDatabase database) async {
    final repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
    final businessRepository = BusinessRepository(database);
    final chatService = ChatService(existingRepository: repository);
    await chatService.init();
    return SyncDataPlane(
      repository: repository,
      chatService: chatService,
      businessRepository: businessRepository,
    );
  }

  /// Six messages, each with a ~1 KB text part, ids `conv-p-m0` … `conv-p-m5`
  /// (ascending in SQLite's byte order).
  Future<void> seed(ChatDatabaseRepository repository) async {
    final messages = [
      for (var index = 0; index < 6; index++)
        ChatMessage(
          id: 'conv-p-m$index',
          conversationId: 'conv-p',
          role: index.isEven ? 'user' : 'assistant',
          content: 'part $index ${'x' * 1000}',
        ),
    ];
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: 'conv-p',
          title: 'conv-p',
        ).copyWith(messageIds: [for (final message in messages) message.id]),
      ],
      messages: [
        for (final (index, message) in messages.indexed)
          (message: message, messageOrder: index),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  }

  test('a late row below the page start does not cost the page its parts', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final dataPlane = await planeIn(database);
    final repository = dataPlane.repository;
    await seed(repository);

    final messageFamily = syncFamilyOfTable('message_rows');
    final partFamily = syncFamilyOfTable('message_part_rows');

    // One row's wire size, so the page-1 budget holds exactly two of them.
    final sample = await repository.syncReadMessageChunk('conv-p', limit: 2);
    final rowBytes = [for (final row in sample) wireBytesOf(row) + 1];
    final conversationRow = await repository.syncReadWireConversationRow(
      'conv-p',
    );
    final conversationBytes = wireBytesOf(conversationRow);
    // ignore: avoid_print
    print('PROBE row wire bytes: $rowBytes, conversation: $conversationBytes');

    // Page 1: two rows only (a row budget that fits exactly two), and a page
    // budget loose enough that the trim pass never runs.
    final first = await dataPlane.readSubtreePage(
      'conv-p',
      after: null,
      rowBudget: conversationBytes + rowBytes[0] + rowBytes[1] + 2,
      pageBytes: 100000,
      sentIds: const {},
    );
    expect(first, isNotNull);
    final firstIds = [
      for (final row in first!.payload.rowsOf(messageFamily))
        row['id'] as String,
    ];
    expect(firstIds, ['conv-p-m0', 'conv-p-m1'], reason: 'page 1 is two rows');
    expect(first.payload.more, isTrue);
    expect(first.nextAfter, 'conv-p-m1');

    // The two controls share the same `after`; one gets a late row.
    Future<({SyncSubtreePayload payload, String? nextAfter, int overflow})>
    readLast() async => (await dataPlane.readSubtreePage(
      'conv-p',
      after: 'conv-p-m1',
      rowBudget: 100000,
      pageBytes: 100000,
      sentIds: {'conv-p-m0', 'conv-p-m1'},
    ))!;

    final control = await readLast();
    // ignore: avoid_print
    print(
      'PROBE control: messages=${control.payload.rowsOf(messageFamily).length} '
      'parts=${control.payload.rowsOf(partFamily).length} '
      'more=${control.payload.more}',
    );
    expect(control.payload.rowsOf(partFamily), hasLength(4));

    // A row written while the transfer ran, sorting before the resume cursor —
    // the shape `sentIds`/`late` exists for, and the shape the ADR names.
    await repository.putMigrationBatch(
      conversations: const [],
      messages: [
        (
          message: ChatMessage(
            id: 'conv-p-late',
            conversationId: 'conv-p',
            role: 'user',
            content: 'written during the transfer ${'y' * 100}',
          ),
          messageOrder: 6,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final probe = await readLast();
    final messageIds = [
      for (final row in probe.payload.rowsOf(messageFamily))
        row['id'] as String,
    ];
    // ignore: avoid_print
    print(
      'PROBE probe:   messages=$messageIds '
      'parts=${probe.payload.rowsOf(partFamily).length} '
      'more=${probe.payload.more} ids=${probe.payload.ids}',
    );
    expect(messageIds, contains('conv-p-late'), reason: 'the late row rides');
    expect(
      probe.payload.rowsOf(partFamily),
      hasLength(5),
      reason:
          'the control\'s four parts plus the late row\'s own: a page whose '
          'parts were read by interval alone would carry none, because the late '
          'id sorts below the page and collapses that interval',
    );
  });
}
