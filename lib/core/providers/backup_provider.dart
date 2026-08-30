import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import '../models/backup.dart';
import '../models/incremental_backup.dart';
import '../services/chat/chat_service.dart';
import '../services/backup/data_sync.dart';
import '../services/trash_restore_coordinator.dart';

class BackupProvider extends ChangeNotifier {
  final DataSync _dataSync;
  WebDavConfig _cfg;
  bool _busy = false;
  String? _message;

  BackupProvider({
    required ChatService chatService,
    required TrashRestoreCoordinator trashRestoreCoordinator,
    required BusinessPreferences preferences,
    WebDavConfig? initialConfig,
  }) : _dataSync = DataSync(
         chatService: chatService,
         preferences: preferences,
         localIdResolver: trashRestoreCoordinator.getLocalIds,
       ),
       _cfg = initialConfig ?? const WebDavConfig();

  WebDavConfig get config => _cfg;
  bool get busy => _busy;
  String? get message => _message;

  void updateConfig(WebDavConfig cfg) {
    _cfg = cfg;
    notifyListeners();
  }

  Future<bool> test() async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await _dataSync.testWebdav(_cfg);
      return true;
    } catch (e) {
      _message = e.toString();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> backup({BackupStageCallback? onStage}) async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await _dataSync.backupToWebDav(_cfg, onStage: onStage);
      _message = 'Backup uploaded';
      return true;
    } catch (e) {
      _message = e.toString();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<IncrementalScope> analyzeIncrementalScope(
    IncrementalBackupConfig config,
  ) => _dataSync.analyzeIncrementalScope(config);

  Future<bool> incrementalBackup(
    IncrementalBackupConfig config, {
    BackupStageCallback? onStage,
  }) async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await _dataSync.backupToWebDav(
        _cfg,
        incremental: config,
        onStage: onStage,
      );
      _message = 'Backup uploaded';
      return true;
    } catch (e) {
      _message = e.toString();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> restoreFromItem(
    BackupFileItem item, {
    RestoreMode mode = RestoreMode.overwrite,
    RestoreProgressCallback? onProgress,
  }) async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await _dataSync.restoreFromWebDav(
        _cfg,
        item,
        mode: mode,
        onProgress: onProgress,
      );
    } catch (e) {
      _message = e.toString();
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<BackupFileItem>> listRemote() async {
    return _dataSync.listBackupFiles(_cfg);
  }

  Future<List<BackupFileItem>> deleteAndReload(BackupFileItem item) async {
    await _dataSync.deleteWebDavBackupFile(_cfg, item);
    return _dataSync.listBackupFiles(_cfg);
  }

  Future<File> exportToFile({
    BackupStageCallback? onStage,
    BackupFormat format = BackupFormat.jsonl,
  }) async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      return await _dataSync.exportToFile(
        _cfg,
        onStage: onStage,
        format: format,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<File> incrementalExportToFile(
    IncrementalBackupConfig config, {
    BackupStageCallback? onStage,
  }) async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      return await _dataSync.exportToFile(
        _cfg,
        incremental: config,
        onStage: onStage,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> restoreFromLocalFile(
    File file, {
    RestoreMode mode = RestoreMode.overwrite,
    RestoreProgressCallback? onProgress,
  }) => _dataSync.restoreFromLocalFile(
    file,
    _cfg,
    mode: mode,
    onProgress: onProgress,
  );
}
