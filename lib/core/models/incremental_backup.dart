import 'backup.dart';

class ConvRange {
  final int count;
  final int messageCount;
  final String? oldestTitle;

  /// Null when [count] <= 1.
  final String? newestTitle;
  const ConvRange({
    required this.count,
    required this.messageCount,
    this.oldestTitle,
    this.newestTitle,
  });
}

class IncrementalScope {
  final ConvRange newConversations;
  final ConvRange updatedConversations;
  final int newFileCount;
  final int totalFileSizeBytes;
  const IncrementalScope({
    required this.newConversations,
    required this.updatedConversations,
    required this.newFileCount,
    required this.totalFileSizeBytes,
  });
}

class IncrementalBackupConfig {
  final DateTime since;
  final bool includeSettings;
  final bool includeFiles;
  final bool updateBackupTime;
  final IncrementalScope? scope;

  /// Unified content scope (backup page redesign). When null, the legacy
  /// [includeSettings]/[includeFiles] pair defines the effective scope (old
  /// peers, LAN sync, old dialogs) — see [effectiveScope].
  final BackupContentScope? contentScope;

  /// LAN-sync per-conversation chat export window. Presence of a key means the
  /// conversation is exported; the value is that conversation's own `since`
  /// (null = one-sided conversation → export the whole conversation). Absence
  /// means the conversation is identical on both peers and is skipped. When
  /// null, the single global [since] is used (normal incremental backups).
  final Map<String, DateTime?>? conversationSince;

  /// LAN-sync per-file delta: the exact set of zip-entry paths to pack (e.g.
  /// `workspaces/x`). When set, replaces the mtime `>= since` file filter in
  /// the zip packer. Null → legacy mtime filter (normal backups / old peers).
  final Set<String>? includeFilePaths;

  /// LAN-sync metadata-only conversations (issue #615 category D): the
  /// conversation ROW is exported (so the merge can apply the chosen conflict
  /// direction to title/isPinned/assistantId/summary …) but its MESSAGES are
  /// deliberately excluded — identical message-ID lists must neither duplicate
  /// nor drop anything. Only meaningful alongside [conversationSince].
  final Set<String>? metadataOnlyConversationIds;

  const IncrementalBackupConfig({
    required this.since,
    this.includeSettings = true,
    this.includeFiles = true,
    this.updateBackupTime = true,
    this.scope,
    this.contentScope,
    this.conversationSince,
    this.includeFilePaths,
    this.metadataOnlyConversationIds,
  });

  /// The unified scope for this incremental run. Legacy fields map as:
  /// chats always ride; settings = includeSettings; file dirs =
  /// includeFiles; skills stay true (old logic always packed them).
  BackupContentScope get effectiveScope =>
      contentScope ??
      BackupContentScope(
        chatsAndAssistants: true,
        settings: includeSettings,
        attachments: includeFiles,
        workspaces: includeFiles,
        skills: true,
        fontsAndAvatars: includeFiles,
      );

  /// Returns true if [timestamp] is on or after [since].
  bool sinceCheck(DateTime timestamp) =>
      timestamp.isAfter(since) || timestamp.isAtSameMomentAs(since);
}
