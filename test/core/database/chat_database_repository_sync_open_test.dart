import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_sync_open_');
    dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'ensureReady opens sync connection after migration; cache reads kind',
    () async {
      final repo = ChatDatabaseRepository.open(file: dbFile);
      // Before ensureReady, sync path must not be required to work.
      await repo.ensureReady();

      final conversation = Conversation(
        title: 'hello',
        conversationKind: Conversation.kindNormal,
        proactiveCareEnabledOverride: true,
        proactiveCareNextMessageAt: DateTime.utc(2027, 1, 2, 3, 4, 5),
      );
      await repo.putConversation(conversation);

      final listed = repo.getAllConversationsSync(includeGroup: true);
      expect(listed.map((c) => c.id), contains(conversation.id));
      expect(
        listed.singleWhere((c) => c.id == conversation.id).isGroup,
        isFalse,
      );
      final loaded = listed.singleWhere((c) => c.id == conversation.id);
      expect(loaded.proactiveCareEnabledOverride, isTrue);
      expect(
        loaded.proactiveCareNextMessageAt?.isAtSameMomentAs(
          DateTime.utc(2027, 1, 2, 3, 4, 5),
        ),
        isTrue,
      );

      final group = Conversation(
        title: 'g',
        conversationKind: Conversation.kindGroup,
      );
      await repo.putConversation(group);
      // Reopen sync so it sees the new row (and schema remains v14).
      repo.reopenSyncConnection();
      final nonGroup = repo.getAllConversationsSync(includeGroup: false);
      expect(nonGroup.any((c) => c.id == group.id), isFalse);
      final all = repo.getAllConversationsSync(includeGroup: true);
      expect(all.any((c) => c.id == group.id), isTrue);

      await repo.close();
    },
  );

  test(
    'openShared serves one live connection per file and rebuilds after close',
    () async {
      // Two concurrent callers get the same live instance.
      final sharedA = await AppDatabase.openShared(file: dbFile);
      final sharedB = await AppDatabase.openShared(file: dbFile);
      expect(identical(sharedA, sharedB), isTrue);
      await sharedA.close();

      // The memo must not hand out a closed connection: the next open builds
      // a fresh executor (regression: ChatService seed→close→reopen pattern in
      // chat_service_init_concurrency_test.dart).
      final reopened = await AppDatabase.openShared(file: dbFile);
      expect(identical(reopened, sharedA), isFalse);
      await reopened.customSelect('SELECT 1').get();
      await reopened.close();
    },
  );
}
