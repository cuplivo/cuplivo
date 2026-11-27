import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/workspace_binding.dart';
import 'package:Cuplivo/core/services/sync/sync_merge.dart';

void main() {
  late AppDatabase database;
  late ChatDatabaseRepository repository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
  });

  tearDown(() => repository.close());

  test('putConversation round-trips extras', () async {
    final conversation = Conversation(
      id: 'c1',
      title: 'Chat',
      extras: const {
        'workspace.id': 'ws-1',
        'workspace.cwd': 'lib',
        'workspace.tools_used': true,
      },
    );
    await repository.putConversation(conversation);
    final loaded = await repository.getConversation('c1');
    expect(loaded, isNotNull);
    expect(loaded!.extras['workspace.id'], 'ws-1');
    expect(loaded.extras['workspace.cwd'], 'lib');
    expect(loaded.extras['workspace.tools_used'], isTrue);
  });

  test('malformed extras_json becomes an empty map', () async {
    await repository.putConversation(Conversation(id: 'c2', title: 'Chat'));
    await database.customStatement(
      "UPDATE conversation_rows SET extras_json = 'not-json' WHERE id = 'c2';",
    );
    final loaded = await repository.getConversation('c2');
    expect(loaded!.extras, isEmpty);
  });

  test(
    'updateConversationExtras moves the sync clock, not updatedAt',
    () async {
      final createdAt = DateTime.utc(2026, 9, 1);
      await repository.putConversation(
        Conversation(
          id: 'c3',
          title: 'Chat',
          createdAt: createdAt,
          updatedAt: createdAt,
          extras: const {'keep': true},
        ),
      );
      Future<int> clock() async => syncClockOf(
        (await repository.syncReadConversationRow('c3'))!['extras_json'],
      )!;

      final before = await clock();
      await repository.updateConversationExtras('c3', (current) {
        return const WorkspaceBinding(
          workspaceId: 'ws-1',
          cwd: 'src',
        ).applyTo(current);
      });

      final afterBind = await repository.getConversation('c3');
      expect(afterBind!.extras['keep'], isTrue);
      expect(afterBind.extras[WorkspaceBinding.keyId], 'ws-1');
      // A settings write is not activity: the list must not reorder.
      expect(
        afterBind.updatedAt.microsecondsSinceEpoch,
        createdAt.microsecondsSinceEpoch,
      );
      final boundClock = await clock();
      expect(boundClock, greaterThan(before));

      await repository.updateConversationExtras(
        'c3',
        (current) => Map<String, dynamic>.from(current),
      );
      expect(await clock(), boundClock);

      await repository.updateConversationExtras('c3', (current) {
        return const WorkspaceBinding().applyTo(current);
      });
      final unbound = await repository.getConversation('c3');
      expect(unbound!.extras.containsKey(WorkspaceBinding.keyId), isFalse);
      expect(unbound.extras['keep'], isTrue);
      expect(
        unbound.updatedAt.microsecondsSinceEpoch,
        createdAt.microsecondsSinceEpoch,
      );
      expect(await clock(), greaterThan(boundClock));
    },
  );

  test('duplicateConversation keeps extras', () async {
    await repository.putConversation(
      Conversation(
        id: 'source',
        title: 'Chat',
        extras: const {'workspace.id': 'ws-1'},
      ),
    );
    final duplicate = await repository.duplicateConversation('source');
    expect(duplicate, isNotNull);
    expect(duplicate!.extras['workspace.id'], 'ws-1');
    expect(duplicate.id, isNot('source'));
  });
}
