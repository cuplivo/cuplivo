import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/services/proactive_care_message_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Future<String> Function() originalDataDirPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_headless_db_');
    originalDataDirPathProvider =
        ProactiveCareHeadlessChatStore.dataDirPathProvider;
    await ProactiveCareHeadlessChatStore.close();
    ProactiveCareHeadlessChatStore.dataDirPathProvider = () async =>
        tempDir.path;
  });

  tearDown(() async {
    await ProactiveCareHeadlessChatStore.close();
    ProactiveCareHeadlessChatStore.dataDirPathProvider =
        originalDataDirPathProvider;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'loads an assistant from a pre-v20 table without the cwd column',
    () async {
      final dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
      final repository = ChatDatabaseRepository.open(file: dbFile);
      await repository.ensureReady();
      await repository.putAssistant(
        Assistant(id: 'assistant-1', name: 'Legacy Assistant'),
      );
      await repository.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute(
        'ALTER TABLE assistant_rows '
        'DROP COLUMN workspace_default_directories_json',
      );
      rawDb.close();

      final assistant = await ProactiveCareHeadlessChatStore.loadAssistantFor(
        'assistant-1',
      );

      expect(assistant, isNotNull);
      expect(assistant!.workspaceDefaultDirectories, isEmpty);
    },
  );
}
