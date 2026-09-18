/// Progress snapshot for an incremental/LAN-sync merge restore, shown by the
/// sync UI while a received zip is applied.
class RestoreProgress {
  final RestoreStage stage;
  final double? fraction;
  final int filesCopied;
  final int filesTotal;
  final int bytesCopied;
  final int bytesTotal;
  final int conversationsMerged;
  final int conversationsTotal;

  const RestoreProgress({
    required this.stage,
    this.fraction,
    this.filesCopied = 0,
    this.filesTotal = 0,
    this.bytesCopied = 0,
    this.bytesTotal = 0,
    this.conversationsMerged = 0,
    this.conversationsTotal = 0,
  });
}

/// Optional progress callback threaded through a restore. Null for callers
/// that do not surface progress.
typedef RestoreProgressCallback = void Function(RestoreProgress progress);

/// Stages of applying a received incremental/LAN-sync payload.
enum RestoreStage {
  downloading,
  extracting,
  mergingChats,
  copyingFiles,
  restoringSettings,
  finishing,
  done,
}
