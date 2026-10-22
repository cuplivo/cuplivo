import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/database/composer_draft_store.dart';
import 'package:Cuplivo/core/models/composer_draft.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

/// The unsent text a conversation was carrying when it was deleted.
///
/// A draft is one device-local row keyed by the conversation id, and the delete
/// removes it in the same transaction that removes the conversation — so it is
/// part of what "recover the conversation" has to mean. What the bin cannot
/// carry is the draft's private attachment files, which the delete also empties:
/// those references are dropped rather than restored as broken chips.
void main() {
  group('an unsent draft', () {
    late Directory directory;
    late AppDatabase database;
    late RecycleStore store;
    late RecycleService recycle;
    late ChatDatabaseRepository repository;
    late File keptImage;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('kelivo_bin_draft_');
      database = AppDatabase.open(file: File('${directory.path}/chat.sqlite'));
      store = RecycleStore(
        directory: () async => Directory('${directory.path}/bin'),
      );
      recycle = RecycleService(database, store: store);
      repository = ChatDatabaseRepository(database, recycle: recycle);
      await repository.ensureReady();
      keptImage = File('${directory.path}/kept.png')
        ..writeAsBytesSync(const <int>[1, 2, 3]);
    });

    tearDown(() async {
      await repository.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    /// The bin writes *after* the operation that fed it, so an assertion about
    /// the bin lets that write finish first.
    Future<List<RecycleEntry>> binEntries() async {
      await recycle.settle();
      return recycle.list();
    }

    Future<void> seedConversation(String id) async {
      final at = DateTime.utc(2026, 8, 1);
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: id,
            title: 'Topic $id',
            createdAt: at,
            updatedAt: at,
            messageIds: const <String>[],
          ),
        ],
        messages: const [],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
    }

    /// Writes the row the delete is supposed to take with it, through the model
    /// that owns the shape so a field rename cannot silently pass.
    Future<void> seedDraft({
      String id = 'c1',
      required String text,
      List<String> imagePaths = const <String>[],
      String? quoteLabel,
    }) async {
      final draft = ComposerDraft(
        conversationId: id,
        assistantId: 'a1',
        compose: ComposerDraftInput(
          text: text,
          images: [for (final path in imagePaths) DraftImage(path: path)],
          quoteLabel: quoteLabel,
        ),
      );
      await database.customStatement(
        'INSERT INTO extension_entity_rows'
        '(kind,id,sort_order,owner_id,payload,updated_at) VALUES(?,?,0,?,?,0) '
        'ON CONFLICT(kind,id) DO UPDATE SET payload = excluded.payload;',
        [ComposerDraftStore.kind, id, 'a1', jsonEncode(draft.toJson())],
      );
    }

    Future<ComposerDraft?> readDraftRow({String id = 'c1'}) async {
      final row = await database
          .customSelect(
            'SELECT payload FROM extension_entity_rows '
            'WHERE kind = ? AND id = ?;',
            variables: [
              const Variable<String>(ComposerDraftStore.kind),
              Variable<String>(id),
            ],
          )
          .getSingleOrNull();
      if (row == null) return null;
      return ComposerDraft.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(row.read<String>('payload')) as Map,
        ),
      );
    }

    test('goes into the bin with the conversation and comes back', () async {
      await seedConversation('c1');
      await seedDraft(
        text: 'half a thought',
        imagePaths: [keptImage.path, '${directory.path}/gone.png'],
        quoteLabel: 'the line being quoted',
      );

      await repository.deleteConversation('c1');

      final entry = (await binEntries()).single;
      expect(
        (await store.readTables(entry))!['extension_entity_rows'],
        hasLength(1),
        reason: 'the draft is part of the conversation the delete removed',
      );

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      final restored = await readDraftRow();
      expect(restored, isNotNull);
      expect(restored!.compose.text, 'half a thought');
      expect(restored.compose.quoteLabel, 'the line being quoted');
      expect(restored.compose.images.map((image) => image.path), [
        keptImage.path,
      ], reason: 'a file the delete removed is not restored as a broken chip');
    });

    test('a draft made since the deletion is not replaced', () async {
      await seedConversation('c1');
      await seedDraft(text: 'staged');
      await repository.deleteConversation('c1');
      final entry = (await binEntries()).single;

      await seedDraft(text: 'typed since');

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      expect((await readDraftRow())!.compose.text, 'typed since');
    });

    test('the draft store takes the id back after a restore', () async {
      await seedConversation('c1');
      await seedDraft(text: 'staged');
      final drafts = ComposerDraftStore(
        database,
        directory: () async => Directory('${directory.path}/drafts'),
      );
      await drafts.initialize();

      await drafts.delete(
        'c1',
        deleteConversation: () => database.customStatement(
          'DELETE FROM conversation_rows WHERE id = ?;',
          ['c1'],
        ),
      );
      // The fence a delete leaves behind: without the restore's seam the
      // composer cannot even open the conversation it just brought back.
      await expectLater(drafts.load('c1'), throwsStateError);

      await seedDraft(text: 'staged');
      await drafts.reloadRestored('c1');

      expect((await drafts.load('c1')).compose.text, 'staged');
      expect(drafts.hasDraft('c1'), isTrue);
    });
  });
}
