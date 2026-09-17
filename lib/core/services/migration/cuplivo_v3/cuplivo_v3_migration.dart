import 'dart:io';
import 'dart:isolate';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/database/database_installation_gate.dart';
import 'package:Cuplivo/core/services/backup/backup_task_progress.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/migration/cuplivo_v3/cuplivo_v3_reader.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of the startup probe for an old fork-lineage database.
class CuplivoV3MigrationDecision {
  const CuplivoV3MigrationDecision({
    required this.needsMigration,
    this.oldDatabasePath,
  });

  final bool needsMigration;
  final String? oldDatabasePath;
}

/// Counts reported by a completed migration.
class CuplivoV3MigrationResult {
  const CuplivoV3MigrationResult({
    required this.conversationCount,
    required this.messageCount,
    required this.retiredDatabasePath,
  });

  final int conversationCount;
  final int messageCount;
  final String retiredDatabasePath;
}

/// First-run migration of a Cuplivo v3 install (Drift schema v23
/// `kelivo.sqlite`, fork lineage) into the current database.
///
/// The old database is never modified and never deleted: after a successful
/// restore it is renamed to `kelivo.sqlite.pre-v4.bak` and a device-local
/// receipt marks the migration complete. Any failure leaves both files as
/// they were, and the next launch retries from scratch — the restore itself
/// is transactional per domain, and re-running it overwrites cleanly.
class CuplivoV3MigrationService {
  CuplivoV3MigrationService(this.decision);

  static const String receiptKey = 'cuplivo_v3_migration_complete_v1';
  static const String oldDatabaseFileName = 'kelivo.sqlite';
  static const String retiredSuffix = '.pre-v4.bak';

  final CuplivoV3MigrationDecision decision;

  /// Cheap startup probe: a migration is needed when the receipt is unset and
  /// a readable v23 `kelivo.sqlite` sits in the app data directory.
  static Future<CuplivoV3MigrationDecision> check(
    Directory appDataDirectory,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(receiptKey) == true) {
      return const CuplivoV3MigrationDecision(needsMigration: false);
    }
    final oldPath = p.join(appDataDirectory.path, oldDatabaseFileName);
    final file = File(oldPath);
    if (await file.exists() && CuplivoV3Reader.looksLikeV3Database(oldPath)) {
      return CuplivoV3MigrationDecision(
        needsMigration: true,
        oldDatabasePath: oldPath,
      );
    }
    return const CuplivoV3MigrationDecision(needsMigration: false);
  }

  /// Runs the migration. Throws on any failure; safe to retry on the next
  /// launch while [decision.oldDatabasePath] still exists.
  Future<CuplivoV3MigrationResult> run(
    Directory appDataDirectory, {
    void Function(BackupPhase phase)? onPhase,
  }) async {
    final oldPath = decision.oldDatabasePath;
    if (oldPath == null) {
      throw StateError('cuplivo_v3_migration_no_source');
    }

    // The migration page runs before the normal admission loop, so make sure
    // the target database exists with the current schema first.
    await DatabaseInstallationGate.ensureReady(
      appDataDirectory: appDataDirectory,
    );

    final databaseFile = File(
      p.join(appDataDirectory.path, AppDatabase.databaseFileName),
    );
    final database = AppDatabase.open(file: databaseFile);
    final chatRepository = ChatDatabaseRepository(
      database,
      databaseFile: databaseFile,
    );
    try {
      await chatRepository.ensureReady();
      await chatRepository.validateConnectionContract();
      final businessRepository = BusinessRepository(database);
      final chatService = ChatService(existingRepository: chatRepository);
      final dataSync = DataSync(
        chatService: chatService,
        businessRepository: businessRepository,
      );

      onPhase?.call(BackupPhase.extracting);
      final data = await Isolate.run(
        () => CuplivoV3Reader.readDatabase(oldPath),
      );

      final conversations =
          (data.chatsJson['conversations'] as List? ?? const []).length;
      final messages = (data.chatsJson['messages'] as List? ?? const []).length;

      await dataSync.restoreLegacyPayload(
        chats: data.chatsJson,
        settings: data.settings,
        onPhase: onPhase,
      );

      // Retire the source file only after both domains committed. The rename
      // doubles as the natural "done" marker: if the receipt write is lost,
      // the missing source file keeps the next probe from re-running.
      final retiredPath = '$oldPath$retiredSuffix';
      await File(oldPath).rename(retiredPath);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(receiptKey, true);

      return CuplivoV3MigrationResult(
        conversationCount: conversations,
        messageCount: messages,
        retiredDatabasePath: retiredPath,
      );
    } finally {
      await chatRepository.close();
    }
  }
}
