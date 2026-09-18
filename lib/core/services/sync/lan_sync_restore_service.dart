import 'dart:io';

import 'package:flutter/foundation.dart';

import '../backup/data_sync.dart';
import '../backup/incremental_apply_service.dart';
import '../chat/chat_service.dart';
import '../sync/restore_progress.dart';

/// End-to-end apply of a received incremental/LAN-sync zip.
///
/// Working-tree composition of the fork's restore path: chats delta through
/// [IncrementalApplyService], settings through the business settings merger,
/// asset files additively into the live roots. The caller drives progress
/// reporting and the restart prompt.
class LanSyncRestoreService {
  LanSyncRestoreService({
    required this.chatService,
    required this.dataSync,
    required this.applyService,
    required this.businessRestore,
  });

  final ChatService chatService;
  final DataSync dataSync;
  final IncrementalApplyService applyService;
  final Future<void> Function(Map<String, Object?> settings) businessRestore;

  /// Applies [zipFile]. [incomingWinsConflicts] selects the metadata winner
  /// on conversation-level conflicts (role-relative; see
  /// [resolveSyncPrecedence] in the fork lineage).
  Future<IncrementalApplyReport> applyZip(
    File zipFile, {
    bool incomingWinsConflicts = true,
    void Function(RestoreProgress progress)? onProgress,
  }) async {
    final engine = dataSync.incrementalEngine;

    onProgress?.call(const RestoreProgress(stage: RestoreStage.extracting));
    final payload = await engine.readIncrementalZip(zipFile);

    onProgress?.call(const RestoreProgress(stage: RestoreStage.mergingChats));
    final report = await applyService.apply(
      payload.chats,
      incomingWinsConflicts: incomingWinsConflicts,
    );

    final settings = payload.settings;
    if (settings != null) {
      onProgress?.call(
        const RestoreProgress(stage: RestoreStage.restoringSettings),
      );
      try {
        await businessRestore(
          settings.map((k, v) => MapEntry(k, v as Object?)),
        );
      } catch (e) {
        // Settings merge is best-effort in a sync apply: chats are already
        // committed, and a malformed settings block must not roll the whole
        // exchange back.
        debugPrint('lan sync: settings merge failed: $e');
      }
    }

    onProgress?.call(const RestoreProgress(stage: RestoreStage.copyingFiles));
    final roots = await dataSync.assetRootPaths();
    final appData = roots.values.first;
    await engine.extractAssetFiles(zipFile, Directory(appData));

    onProgress?.call(
      RestoreProgress(
        stage: RestoreStage.done,
        fraction: 1,
        conversationsMerged:
            report.insertedConversations + report.updatedConversations,
      ),
    );
    return report;
  }
}

/// Role-relative direction resolution (fork lineage): the wire bit is
/// absolute (initiator wins / server wins); this device's effective choice
/// depends on which side it was.
bool resolveIncomingWins({bool? syncPriority, required bool isInitiator}) {
  if (syncPriority == null) return true;
  // Wire value 'initiator wins': the initiator's rows win everywhere; the
  // server applies incoming, the initiator keeps local — but both still
  // union peer-exclusive data, so the merge itself stays additive.
  return isInitiator ? false : true;
}
