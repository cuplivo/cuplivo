import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/backup.dart';

/// The current protocol phase of a LAN sync peer (server or client).
///
/// UI-facing only: the widgets map a phase to a localized status line.
/// The services never emit user-visible strings themselves.
enum LanSyncPhase {
  /// No sync operation in progress.
  idle,

  /// Server: listening for the initiator. Client: connecting / sending index.
  waiting,

  /// Server: sync plan sent, waiting for the initiator's zip.
  planSent,

  /// Client: sync plan received, awaiting user confirmation.
  planReceived,

  /// Both: incremental zip is being built / transferred.
  exchanging,

  /// Client: the server had nothing to send (empty exchange response).
  noData,

  /// Both: exchange complete; apply and restart.
  done,
}

/// A single file's identity in a sync file manifest: its byte size and
/// filesystem modification time in milliseconds since epoch (ms precision so
/// a peer that restored the file reports the exact mtime the sender stored —
/// second-granularity would trigger cross-run re-send churn).
class FileManifestEntry {
  final int size;
  final int mtimeMs;

  const FileManifestEntry({required this.size, required this.mtimeMs});

  Map<String, dynamic> toJson() => {'size': size, 'mtime': mtimeMs};

  static FileManifestEntry fromJson(Map<String, dynamic> json) {
    return FileManifestEntry(
      size: json['size'] as int,
      mtimeMs: json['mtime'] as int,
    );
  }
}

/// Per-session conflict-direction bit chosen by the initiator (issue #615).
///
/// Absolute, role-based: `initiatorWins` means "the device that started this
/// sync keeps its copy on conflicts"; `serverWins` means "the listening device
/// keeps its copy". Each side derives its role-relative
/// [ConflictPrecedence] (localWins / incomingWins) from this value. Null /
/// absent on the wire = auto (current fixed-policy merge, zero change).
/// Old peers ignore the unknown field and degrade to auto silently.
enum SyncPriority {
  initiatorWins,
  serverWins;

  /// Parses the wire value. Unknown values degrade to null (auto) instead of
  /// throwing: a newer peer introducing a future mode must not break the plan
  /// request on an older build — symmetric with "absent field = auto".
  static SyncPriority? tryParse(String? raw) {
    if (raw == null) return null;
    for (final value in SyncPriority.values) {
      if (value.name == raw) return value;
    }
    debugPrint(
      'lan sync: unknown syncPriority value "$raw", degrading to auto',
    );
    return null;
  }
}

/// Resolves the role-relative restore precedence for this device.
///
/// [isInitiator] is true when this device started the sync; [priority] is the
/// session's absolute choice (wire value). Null -> auto. The rule: local wins
/// iff the absolute winner IS this device.
ConflictPrecedence resolveSyncPrecedence(
  SyncPriority? priority, {
  required bool isInitiator,
}) {
  if (priority == null) return ConflictPrecedence.auto;
  final thisDeviceWins =
      (priority == SyncPriority.initiatorWins) == isInitiator;
  return thisDeviceWins
      ? ConflictPrecedence.localWins
      : ConflictPrecedence.incomingWins;
}

/// Index sent from the initiator (device A) to the server (device B) in round 1.
///
/// Contains per-conversation message IDs (ordered by messageOrder), the
/// initiator's assistant IDs, and — for modern peers — the initiator's full
/// file manifest (zip-entry path → size/mtime), so the server can compute an
/// exact per-file delta instead of gating the zip by a global `since`.
class SyncIndex {
  final Map<String, List<String>> conversations;
  final List<String> assistantIds;

  /// The initiator's file tree keyed by zip-entry path (e.g. `workspaces/x`).
  /// Null when sent by an old peer — the receiver then falls back to the
  /// `since`-based packing path.
  final Map<String, FileManifestEntry>? fileManifest;

  /// The initiator's conversation rows (id → `Conversation.toJson`), so a
  /// modern server can detect metadata-only conflicts (identical message-ID
  /// lists, different row fields — category D) in confirmed-direction
  /// sessions. Null when sent by an old peer — the receiver then degrades
  /// to message-ID-only planning.
  final Map<String, Map<String, dynamic>>? conversationRows;

  /// The initiator's chosen conflict direction for this sync session.
  /// Null = auto/absent (old peer or no choice made).
  final SyncPriority? syncPriority;

  const SyncIndex({
    required this.conversations,
    required this.assistantIds,
    this.fileManifest,
    this.conversationRows,
    this.syncPriority,
  });

  Map<String, dynamic> toJson() => {
    'conversations': conversations,
    'assistantIds': assistantIds,
    'fileManifest': fileManifest?.map((k, v) => MapEntry(k, v.toJson())),
    if (conversationRows != null) 'conversationRows': conversationRows,
    if (syncPriority != null) 'syncPriority': syncPriority!.name,
  };

  String toJsonString() => jsonEncode(toJson());

  static SyncIndex fromJson(Map<String, dynamic> json) {
    final convsRaw = json['conversations'] as Map<String, dynamic>;
    final conversations = convsRaw.map(
      (k, v) => MapEntry(k, (v as List).cast<String>()),
    );
    final manifestRaw = json['fileManifest'] as Map<String, dynamic>?;
    final rowsRaw = json['conversationRows'] as Map<String, dynamic>?;
    final rawPriority = json['syncPriority'] as String?;
    return SyncIndex(
      conversations: conversations,
      assistantIds: (json['assistantIds'] as List).cast<String>(),
      fileManifest: manifestRaw?.map(
        (k, v) => MapEntry(
          k,
          FileManifestEntry.fromJson((v as Map).cast<String, dynamic>()),
        ),
      ),
      conversationRows: rowsRaw?.map(
        (k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()),
      ),
      syncPriority: SyncPriority.tryParse(rawPriority),
    );
  }

  static SyncIndex fromJsonString(String s) =>
      fromJson(jsonDecode(s) as Map<String, dynamic>);
}

/// Per-conversation divergence classification.
enum SyncConvState {
  /// Only the initiator (A) has increments after the fork point.
  initiatorOnly,

  /// Only the server (B) has increments after the fork point.
  serverOnly,

  /// Both sides have different increments after the fork point (fork).
  /// v1 detects but does not resolve.
  fork,

  /// Both sides are identical (no fork point needed).
  identical,
}

/// One conversation's sync classification in the plan.
class SyncConvPlan {
  final String conversationId;
  final String? conversationTitle;
  final SyncConvState state;

  /// The last common messageId (fork point). Null when the conversation
  /// only exists on one side or when both sides are identical with no
  /// messages after the fork.
  final String? forkPointMessageId;

  /// Number of messages the initiator (A) has after the fork point.
  final int initiatorIncrementCount;

  /// Number of messages the server (B) has after the fork point.
  final int serverIncrementCount;

  /// The fork-point message's timestamp (resolved server-side). Used by both
  /// peers as this conversation's per-conversation `since` for the chat export
  /// in round 2. Null for identical conversations and for one-sided
  /// conversations with no fork point (the whole conversation is an increment
  /// and is exported in full).
  final DateTime? since;

  /// Category D (issue #615): the message-ID lists are identical but the
  /// conversation row differs (title, isPinned, assistantId, summary, …).
  /// Confirmed-direction sessions ship the row (without its messages) so the
  /// winner's metadata reaches the merge. False for message-diff states — a
  /// forked/one-sided payload always carries its row anyway.
  final bool metadataOnly;

  const SyncConvPlan({
    required this.conversationId,
    this.conversationTitle,
    required this.state,
    this.forkPointMessageId,
    required this.initiatorIncrementCount,
    required this.serverIncrementCount,
    this.since,
    this.metadataOnly = false,
  });

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'conversationTitle': conversationTitle,
    'state': state.name,
    'forkPointMessageId': forkPointMessageId,
    'initiatorIncrementCount': initiatorIncrementCount,
    'serverIncrementCount': serverIncrementCount,
    'since': since?.toIso8601String(),
    'metadataOnly': metadataOnly,
  };

  static SyncConvPlan fromJson(Map<String, dynamic> json) {
    final sinceStr = json['since'] as String?;
    return SyncConvPlan(
      conversationId: json['conversationId'] as String,
      conversationTitle: json['conversationTitle'] as String?,
      state: SyncConvState.values.byName(json['state'] as String),
      forkPointMessageId: json['forkPointMessageId'] as String?,
      initiatorIncrementCount: json['initiatorIncrementCount'] as int,
      serverIncrementCount: json['serverIncrementCount'] as int,
      since: sinceStr != null ? DateTime.parse(sinceStr) : null,
      metadataOnly: json['metadataOnly'] as bool? ?? false,
    );
  }
}

/// The sync plan returned from the server (B) to the initiator (A) in round 1.
class SyncPlan {
  /// Per-conversation classification.
  final List<SyncConvPlan> conversations;

  /// Assistant IDs that the server (B) is missing (should be sent by A).
  final List<String> missingAssistantIds;

  /// Assistant IDs that the initiator (A) is missing (will be sent by B).
  final List<String> remoteMissingAssistantIds;

  /// The earliest fork-point timestamp across all conversations.
  /// Used as the `since` parameter for incremental backup zip creation.
  /// Both sides use this to build their zip.
  final DateTime? since;

  /// Number of files the server (B) will pack into its incremental zip, and
  /// their total size in bytes. Null when unknown (old peer, or `since` was
  /// null so no zip will be built). Optional — forward/backward compatible.
  final int? serverFileCount;
  final int? serverFileSizeBytes;

  /// The server's (B) file manifest, so the initiator (A) can compute its own
  /// outbound per-file delta. Null when the peer is old (`since`-based flow).
  final Map<String, FileManifestEntry>? serverFileManifest;

  /// The server's echo of the initiator's [SyncIndex.syncPriority] (issue
  /// #615): non-null only when this server READ and accepted the sent value.
  /// The initiator applies its chosen direction only after receiving an
  /// identical echo — a mixed-version session (old server ignores the field)
  /// must fall back to auto on BOTH sides, never apply asymmetric rules.
  final SyncPriority? syncPriority;

  /// Convenience: total conversations with initiator-only increments.
  int get initiatorOnlyCount =>
      conversations.where((c) => c.state == SyncConvState.initiatorOnly).length;

  /// Convenience: total conversations with server-only increments.
  int get serverOnlyCount =>
      conversations.where((c) => c.state == SyncConvState.serverOnly).length;

  /// Convenience: total conversations with forks.
  int get forkCount =>
      conversations.where((c) => c.state == SyncConvState.fork).length;

  /// Convenience: total metadata-only conflicts (identical message lists,
  /// differing conversation rows).
  int get metadataOnlyCount =>
      conversations.where((c) => c.metadataOnly).length;

  const SyncPlan({
    required this.conversations,
    required this.missingAssistantIds,
    required this.remoteMissingAssistantIds,
    required this.since,
    this.serverFileCount,
    this.serverFileSizeBytes,
    this.serverFileManifest,
    this.syncPriority,
  });

  Map<String, dynamic> toJson() => {
    'conversations': conversations.map((c) => c.toJson()).toList(),
    'missingAssistantIds': missingAssistantIds,
    'remoteMissingAssistantIds': remoteMissingAssistantIds,
    'since': since?.toIso8601String(),
    if (serverFileCount != null) 'serverFileCount': serverFileCount,
    if (serverFileSizeBytes != null) 'serverFileSizeBytes': serverFileSizeBytes,
    if (serverFileManifest != null)
      'serverFileManifest': serverFileManifest!.map(
        (k, v) => MapEntry(k, v.toJson()),
      ),
    if (syncPriority != null) 'syncPriority': syncPriority!.name,
  };

  String toJsonString() => jsonEncode(toJson());

  static SyncPlan fromJson(Map<String, dynamic> json) {
    final convs = (json['conversations'] as List)
        .map((c) => SyncConvPlan.fromJson((c as Map).cast<String, dynamic>()))
        .toList();
    final sinceStr = json['since'] as String?;
    final manifestRaw = json['serverFileManifest'] as Map<String, dynamic>?;
    final rawPriority = json['syncPriority'] as String?;
    return SyncPlan(
      conversations: convs,
      missingAssistantIds: (json['missingAssistantIds'] as List).cast<String>(),
      remoteMissingAssistantIds: (json['remoteMissingAssistantIds'] as List)
          .cast<String>(),
      since: sinceStr != null ? DateTime.parse(sinceStr) : null,
      serverFileCount: json['serverFileCount'] as int?,
      serverFileSizeBytes: json['serverFileSizeBytes'] as int?,
      serverFileManifest: manifestRaw?.map(
        (k, v) => MapEntry(
          k,
          FileManifestEntry.fromJson((v as Map).cast<String, dynamic>()),
        ),
      ),
      syncPriority: SyncPriority.tryParse(rawPriority),
    );
  }

  static SyncPlan fromJsonString(String s) =>
      fromJson(jsonDecode(s) as Map<String, dynamic>);
}
