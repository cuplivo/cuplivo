// Trimming a page is arithmetic, not another round trip.
//
// The row budget is filled with *metadata*, while the prose lives in the parts,
// so a page almost always overflows once its parts are added. The trim that
// follows must therefore cost one pass: one part query for the page, one encode
// per row. Re-reading the parts and re-encoding the page per removed row turns
// a page into hours of local work on a large conversation.
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/sync_budget.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:Cuplivo/core/services/sync/sync_family_registry.dart';
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

/// Counts the part-range reads one page costs.
class _CountingRepository extends ChatDatabaseRepository {
  _CountingRepository(super.database);

  var partRangeQueries = 0;

  @override
  Future<List<Map<String, dynamic>>> syncReadPartRowsBetween(
    String conversationId,
    String fromRevisionId,
    String toRevisionId,
  ) {
    partRangeQueries++;
    return super.syncReadPartRowsBetween(
      conversationId,
      fromRevisionId,
      toRevisionId,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_probe_trim_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // The temp dir is disposable.
    }
  });

  test('probe: one page costs one part query per trimmed row', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = _CountingRepository(database);
    await repository.ensureReady();
    final businessRepository = BusinessRepository(database);
    final chatService = ChatService(existingRepository: repository);
    await chatService.init();
    final dataPlane = SyncDataPlane(
      repository: repository,
      chatService: chatService,
      businessRepository: businessRepository,
    );

    // 120 messages whose text is 4x the size of their row metadata — the
    // ordinary shape: the row is a pointer, `message_part_rows.payload` is the
    // prose, and only the parts are big.
    final messages = [
      for (var index = 0; index < 120; index++)
        ChatMessage(
          id: 'conv-t-m${index.toString().padLeft(3, '0')}',
          conversationId: 'conv-t',
          role: index.isEven ? 'user' : 'assistant',
          content: 'message $index ${'x' * 2000}',
        ),
    ];
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: 'conv-t',
          title: 'conv-t',
        ).copyWith(messageIds: [for (final message in messages) message.id]),
      ],
      messages: [
        for (final (index, message) in messages.indexed)
          (message: message, messageOrder: index),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final messageFamily = syncFamilyOfTable('message_rows');
    final partFamily = syncFamilyOfTable('message_part_rows');
    final sample = await repository.syncReadMessageChunk('conv-t', limit: 1);
    final rowBytes = wireBytesOf(sample.single) + 1;
    final conversationRow = await repository.syncReadWireConversationRow(
      'conv-t',
    );
    final conversationBytes = wireBytesOf(conversationRow);

    // The production ratio, at test scale: the page budget is four times the
    // row budget that a page is filled to, so the parts make it overflow and
    // the trim pass has to walk back.
    const rowBudget = 12000;
    final pageBytes = rowBudget + conversationBytes;

    repository.partRangeQueries = 0;
    final page = await dataPlane.readSubtreePage(
      'conv-t',
      after: null,
      rowBudget: rowBudget,
      pageBytes: pageBytes,
      sentIds: const {},
    );

    final payload = page!.payload;
    final rows = payload.rowsOf(messageFamily).length;
    final parts = payload.rowsOf(partFamily).length;
    // ignore: avoid_print
    print(
      'PROBE one page (pageBytes=$pageBytes, rowBytes=$rowBytes): '
      'rows=$rows parts=$parts wire=${conversationWireBytes(payload)} '
      'partRangeQueries=${repository.partRangeQueries} more=${payload.more}',
    );
    expect(page.nextAfter, isNotNull);
    expect(
      repository.partRangeQueries,
      lessThanOrEqualTo(2),
      reason:
          'one pass over the page needs one part query; the count is the number '
          'of removed rows, because every iteration re-reads the parts and '
          're-encodes the whole page',
    );
  });
  test(
    'a page is measured at its budget and its cursor is the last row kept',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = _CountingRepository(database);
      await repository.ensureReady();
      final chatService = ChatService(existingRepository: repository);
      await chatService.init();
      final dataPlane = SyncDataPlane(
        repository: repository,
        chatService: chatService,
        businessRepository: BusinessRepository(database),
      );

      final messages = [
        for (var index = 0; index < 40; index++)
          ChatMessage(
            id: 'conv-w-m${index.toString().padLeft(3, '0')}',
            conversationId: 'conv-w',
            role: index.isEven ? 'user' : 'assistant',
            content: 'message $index ${'x' * 2000}',
          ),
      ];
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: 'conv-w',
            title: 'conv-w',
          ).copyWith(messageIds: [for (final message in messages) message.id]),
        ],
        messages: [
          for (final (index, message) in messages.indexed)
            (message: message, messageOrder: index),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      // Two shapes. The first is the ordinary page: the fill meters the parts, so
      // the page ends at the budget and nothing is trimmed. The second makes the
      // trim do the work — a row budget far above the page one — because that is
      // where a cursor taken from the rows *read* rather than *kept* steps over
      // the rows it removed and makes the next page re-read them by id.
      for (final trimIsDoingTheWork in [false, true]) {
        final pageBytes = 12000;
        final messageFamily = syncFamilyOfTable('message_rows');
        final carried = <String>[];
        String? cursor;
        var pages = 0;
        while (true) {
          final page = await dataPlane.readSubtreePage(
            'conv-w',
            after: cursor,
            rowBudget: trimIsDoingTheWork ? 1 << 20 : pageBytes,
            pageBytes: pageBytes,
            sentIds: carried.toSet(),
          );
          expect(page, isNotNull);
          pages += 1;
          final ids = [
            for (final row in page!.payload.rowsOf(messageFamily))
              row['id'] as String,
          ];
          expect(
            conversationWireBytes(page.payload),
            lessThanOrEqualTo(pageBytes),
            reason:
                'the fill meters the parts, so the page ends where its budget does '
                'instead of loading several times that and trimming back',
          );
          if (page.nextAfter != null) {
            expect(
              page.nextAfter,
              ids.reduce((a, b) => a.compareTo(b) > 0 ? a : b),
              reason:
                  'the cursor names the last row the page carried; one past it '
                  'steps over rows that then have to be re-read by id',
            );
          }
          carried.addAll(ids);
          if (!page.payload.more) break;
          cursor = page.nextAfter;
          expect(
            cursor,
            isNotNull,
            reason: 'a page that is not last has a cursor',
          );
          expect(pages, lessThan(200), reason: 'the loop must terminate');
        }
        expect(
          carried.toSet(),
          hasLength(messages.length),
          reason: 'every row arrives',
        );
        expect(
          carried.toSet(),
          hasLength(carried.length),
          reason: 'no row is carried twice',
        );
      }
    },
  );
}
