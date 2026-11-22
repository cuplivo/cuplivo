import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/sync/sync_merge.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The conversation's mutation clock, as a state table (the plan's G6).
///
/// Two times now live on a conversation row: `updated_at`, which the home list
/// orders and groups by, and `extras['sync.clock']`, which is what LAN sync
/// compares. This file pins the rule that separates them —
///
/// * every local write moves the sync clock, and two writes inside one
///   microsecond still move it (`copyWrittenSinceAgreement` compares `>`);
/// * metadata writes (rename, pin, summary, suggestions, model override,
///   settings, the truncate reset) do **not** move `updated_at`;
/// * content writes move both;
/// * the applier writes the winner's clock and never stamps;
/// * the archive importer stores the archive's clock, not "now";
/// * the SQL reader in the manifest and the Dart reader in the merge agree —
///   if they did not, the plan would say "changed" and the merge "unchanged",
///   and the pair would re-send every round.
void main() {
  group('the clock rule', () {
    test('a write always moves the clock, even twice in one microsecond', () {
      final first = nextSyncClock(
        nowUs: 1000,
        currentUs: 1000,
        updatedAtUs: 1000,
      );
      final second = nextSyncClock(
        nowUs: 1000,
        currentUs: first,
        updatedAtUs: 1000,
      );
      expect(first, greaterThan(1000));
      expect(second, greaterThan(first));
    });

    test('a clock ahead of the wall clock is stepped over, not waited out', () {
      // A peer with a fast clock (or a restored archive) leaves a key in the
      // future; `now` would never pass it, `current + 1` does.
      expect(nextSyncClock(nowUs: 10, currentUs: 5000, updatedAtUs: 10), 5001);
    });

    test('an empty row falls back to the display clock', () {
      expect(
        effectiveConversationClock({'updated_at': 42, 'extras_json': '{}'}),
        42,
      );
    });

    test('a stored key is the clock, even when the display clock is newer', () {
      // Deliberately not `max`: `updated_at` is the display clock, and a write
      // that only reorders the list must not claim it changed the row.
      expect(
        effectiveConversationClock({
          'updated_at': 42,
          'extras_json': jsonEncode({syncClockExtrasKey: 99}),
        }),
        99,
      );
    });

    test(
      'a junk bag or a non-integer value falls back instead of throwing',
      () {
        expect(
          effectiveConversationClock({
            'updated_at': 7,
            'extras_json': 'not json',
          }),
          7,
        );
        expect(
          effectiveConversationClock({
            'updated_at': 7,
            'extras_json': jsonEncode([syncClockExtrasKey]),
          }),
          7,
        );
        expect(syncClockOf(jsonEncode({syncClockExtrasKey: 'nope'})), isNull);
        expect(syncClockOf(jsonEncode({syncClockExtrasKey: 1.5})), isNull);
        expect(syncClockOf(null), isNull);
      },
    );
  });

  group('the two readers agree', () {
    late AppDatabase database;
    late ChatDatabaseRepository repository;

    setUp(() async {
      database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      await repository.ensureReady();
    });

    tearDown(() => database.close());

    test('manifest SQL and the Dart reader give the same clock', () async {
      final extras = <String, String>{
        'none': '{}',
        'older-key': jsonEncode({syncClockExtrasKey: 500}),
        'newer-key': jsonEncode({syncClockExtrasKey: 9000}),
        'junk': 'not json',
        'array': '[]',
        'text-key': jsonEncode({syncClockExtrasKey: '123'}),
        'real-key': jsonEncode({syncClockExtrasKey: 1234.5}),
        'other-keys': jsonEncode({'workspace.id': 'w1'}),
      };
      var updatedAt = 1000;
      for (final entry in extras.entries) {
        await database.customStatement(
          'INSERT INTO conversation_rows (id, title, created_at, updated_at, '
          'extras_json) VALUES (?, ?, ?, ?, ?);',
          [entry.key, entry.key, 1000, updatedAt, entry.value],
        );
        updatedAt += 1000;
      }

      final refs = {
        for (final ref in await repository.syncConversationRefs())
          ref.conversationId: ref.updatedAtUs,
      };
      for (final id in extras.keys) {
        final row = (await repository.syncReadConversationRow(id))!;
        expect(
          refs[id],
          effectiveConversationClock(row),
          reason: 'the manifest and the merge disagree about $id',
        );
      }
    });
  });

  group('every local writer stamps', () {
    late AppDatabase database;
    late ChatDatabaseRepository repository;
    final createdAt = DateTime.fromMicrosecondsSinceEpoch(1000000);

    setUp(() async {
      database = AppDatabase(NativeDatabase.memory());
      repository = ChatDatabaseRepository(database);
      await repository.ensureReady();
    });

    tearDown(() => database.close());

    Future<Map<String, dynamic>> row(String id) async =>
        (await repository.syncReadConversationRow(id))!;

    int clock(Map<String, dynamic> row) => effectiveConversationClock(row);

    int updatedAt(Map<String, dynamic> row) =>
        (row['updated_at'] as num).toInt();

    Future<Conversation> seed(
      String id, {
      String? provider,
      String? model,
      Map<String, dynamic> extras = const {},
    }) async {
      final conversation = Conversation(
        id: id,
        title: id,
        createdAt: createdAt,
        updatedAt: createdAt,
        chatModelProvider: provider,
        chatModelId: model,
        extras: extras,
      );
      await repository.putConversation(conversation);
      return conversation;
    }

    test('a new row is stamped, and its display clock is its own', () async {
      await seed('conv');
      final stored = await row('conv');
      expect(clock(stored), greaterThan(updatedAt(stored)));
      expect(updatedAt(stored), createdAt.microsecondsSinceEpoch);
    });

    test('rename moves the clock and leaves the display clock', () async {
      final conversation = await seed('conv');
      final before = await row('conv');

      conversation.title = 'renamed';
      // Even a cached object that has bumped its own `updatedAt` — the shape
      // `renameConversation` used to write — does not move the stored one: the
      // gate reads the display clock from the row, not from the copy.
      conversation.updatedAt = DateTime.now();
      await repository.putConversation(conversation);

      final after = await row('conv');
      expect(clock(after), greaterThan(clock(before)));
      expect(updatedAt(after), updatedAt(before));
    });

    test(
      'a settings write moves the clock and leaves the display clock',
      () async {
        await seed('conv');
        final before = await row('conv');

        await repository.updateConversationExtras(
          'conv',
          (extras) => {...extras, 'workspace.id': 'w1'},
        );

        final after = await row('conv');
        expect(clock(after), greaterThan(clock(before)));
        expect(updatedAt(after), updatedAt(before));
      },
    );

    test(
      'an MCP binding moves the clock and leaves the display clock',
      () async {
        await seed('conv');
        final before = await row('conv');

        await repository.updateConversationMcpServers('conv', const ['srv']);

        final after = await row('conv');
        expect(clock(after), greaterThan(clock(before)));
        expect(updatedAt(after), updatedAt(before));
      },
    );

    test('clearing a model override moves the clock', () async {
      await seed('conv', provider: 'p', model: 'm');
      final before = await row('conv');

      final changed = await repository.clearConversationModelOverrides(
        providerKey: 'p',
      );

      final after = await row('conv');
      expect(changed, 1);
      expect(clock(after), greaterThan(clock(before)));
      expect(updatedAt(after), updatedAt(before));
    });

    test('the truncate reset moves the clock', () async {
      await seed('conv');
      await database.customStatement(
        'UPDATE conversation_rows SET truncate_index = 0 WHERE id = ?;',
        ['conv'],
      );
      final before = await row('conv');

      await repository.readContextOperations('conv');

      final after = await row('conv');
      expect(clock(after), greaterThan(clock(before)));
      expect(updatedAt(after), updatedAt(before));
    });

    test('a content write moves both clocks', () async {
      await seed('conv');
      final before = await row('conv');

      await repository.moveConversationToAssistant(
        conversationId: 'conv',
        assistantId: 'assistant',
        updatedAt: DateTime.now(),
      );

      final after = await row('conv');
      expect(clock(after), greaterThan(clock(before)));
      expect(updatedAt(after), greaterThan(updatedAt(before)));
    });

    test('the applier takes the winner clock and never stamps', () async {
      const localUpdatedAt = 5000;
      const winnerUpdatedAt = 1000;
      const winnerClock = 9000;
      await database.customStatement(
        'INSERT INTO conversation_rows (id, title, created_at, updated_at, '
        'extras_json) VALUES (?, ?, ?, ?, ?);',
        [
          'conv',
          'conv',
          1000,
          localUpdatedAt,
          jsonEncode({syncClockExtrasKey: 5000}),
        ],
      );

      await repository.syncApplySubtree(
        payload: SyncSubtreePayload(
          conversation: {
            'id': 'conv',
            'title': 'from the peer',
            'created_at': 1000,
            'updated_at': winnerUpdatedAt,
            'is_pinned': 0,
            'assistant_id': null,
            'truncate_index': 0,
            'version_selections_json': '{}',
            'summary': null,
            'last_summarized_message_count': 0,
            'chat_suggestions_json': '[]',
            'last_memory_extracted_order': -1,
            'chat_model_provider': null,
            'chat_model_id': null,
            'extras_json': jsonEncode({syncClockExtrasKey: winnerClock}),
          },
          families: const {},
        ),
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        checkpointRows: const {},
      );

      final after = await row('conv');
      // The winner's clock crossed: the peer's pin (a write that does not move
      // the display clock) is what won, and nothing stamped on the way in.
      expect(clock(after), winnerClock);
      // …but its display clock did not move this device's list backwards.
      expect(updatedAt(after), localUpdatedAt);
      expect(after['title'], 'from the peer');
    });

    test('the archive importer stores the archive clock, not now', () async {
      final archived = Conversation(
        id: 'imported',
        title: 'imported',
        createdAt: createdAt,
        updatedAt: DateTime.fromMicrosecondsSinceEpoch(1000),
        extras: const {syncClockExtrasKey: 777},
      );

      await repository.putMigrationBatch(
        conversations: [archived],
        messages: const [],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final stored = await row('imported');
      expect(clock(stored), 777);
      expect(updatedAt(stored), 1000);
    });
  });

  test('every writer of conversation_rows is named here, with its reason', () {
    // The table is written through seven shapes and only some of them go through
    // the gate. This guard counts every *site* of every shape, per file, and
    // holds the counts: a new writer — a new file, or one more write in an old
    // one — fails here instead of shipping without a clock decision. Adding a
    // write therefore means editing this list and saying why, which is the point.
    const shapes = <String, String>{
      'drift insert': r'\.into\(\s*_db\.conversationRows',
      'drift update': r'_db\.update\(\s*_db\.conversationRows',
      'batch insert': r'batch\.insert\(\s*_db\.conversationRows',
      'applier upsert': r"_upsertSyncRow\(\s*'conversation_rows'",
      'recycle insert': r"_insertRow\(\s*'conversation_rows'",
      'raw insert': r'INSERT INTO\s+(?:main\.)?conversation_rows',
      'raw update': r'UPDATE conversation_rows SET',
    };
    const expected = <String, Map<String, int>>{
      // The gate itself: putConversation's insert, the two copy
      // (duplicate/fork) paths, the linear append and the deprecated
      // message-order rewrite.
      'drift insert': {'lib/core/database/chat_database_repository.dart': 5},
      // The gate's whole-row updates; the context `part` stamps its own
      // truncate reset through the same helper.
      'drift update': {
        'lib/core/database/chat_database_repository.dart': 9,
        'lib/core/database/chat_context_repository.dart': 1,
      },
      // The archive importer (`_writeBackupData`, `clock: null`): the one local
      // writer that keeps the clocks its archive carries.
      'batch insert': {'lib/core/database/chat_database_repository.dart': 1},
      // The applier, which writes the winner's clocks and must never stamp.
      'applier upsert': {'lib/core/database/chat_database_repository.dart': 2},
      // The recycle bin is the one place a deleted row comes back; it stamps
      // itself (`withSyncClock` + `nextSyncClock`) because it writes the row
      // directly rather than through the repository.
      'recycle insert': {'lib/core/services/recycle/recycle_service.dart': 1},
      // The merge importer copies a subtree out of `merge_source` with the
      // archive's own clock, like the backup writer.
      'raw insert': {'lib/core/database/chat_database_repository.dart': 1},
      // The memory watermark, recomputed from the messages on both sides; and
      // the backup sanitizer, rewriting an archive's own bag before it lands.
      'raw update': {
        'lib/core/database/business_repository.dart': 1,
        'lib/core/database/backup_portability.dart': 1,
      },
    };

    final found = <String, Map<String, int>>{
      for (final shape in shapes.keys) shape: <String, int>{},
    };
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      final source = entity.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      final path = entity.path.replaceAll('\\', '/');
      for (final entry in shapes.entries) {
        final hits = RegExp(entry.value).allMatches(source).length;
        if (hits > 0) found[entry.key]![path] = hits;
      }
    }
    for (final shape in shapes.keys) {
      expect(
        found[shape],
        expected[shape],
        reason:
            'the sites that write conversation_rows for "$shape" changed: each '
            'one must stamp (see _nextConversationClock) or be listed here with '
            'the reason it does not',
      );
    }
  });

  test('a wire row never carries the clock under a device-local key', () {
    // The key has to cross the wire — both peers must agree on the clock — so it
    // must not be in the set the wire read strips and the applier restores.
    expect(
      ChatDatabaseRepository.syncLocalExtrasKeys,
      isNot(contains(syncClockExtrasKey)),
    );
  });
}
