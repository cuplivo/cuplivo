import 'dart:convert';

import 'lan_sync_models.dart';

/// Pure functions for LAN sync plan computation, extracted from
/// [LanSyncServer] for testability without a [ChatService] or database.
///
/// All methods here are synchronous and side-effect-free.

/// Finds the last common messageId between two ordered lists.
///
/// Both lists must be ordered by [messageOrder] (ascending). Returns the
/// last element in [a] that also exists in [b], scanning [a] in order and
/// stopping at the first divergence after a common element is found.
///
/// Returns `null` when either list is empty or no common element exists.
String? findForkPoint(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return null;
  final bSet = b.toSet();
  String? lastCommon;
  for (final id in a) {
    if (bSet.contains(id)) {
      lastCommon = id;
    } else if (lastCommon != null) {
      break;
    }
  }
  return lastCommon;
}

/// Input for a single conversation's plan computation.
class ConvPlanInput {
  final String conversationId;
  final String? conversationTitle;
  final List<String> initiatorMsgIds;
  final List<String> serverMsgIds;

  const ConvPlanInput({
    required this.conversationId,
    this.conversationTitle,
    required this.initiatorMsgIds,
    required this.serverMsgIds,
  });
}

/// Computes a single conversation's sync plan from the two ordered message ID
/// lists.
SyncConvPlan computeConvPlan(ConvPlanInput input) {
  final forkPoint = findForkPoint(input.initiatorMsgIds, input.serverMsgIds);
  final theirIncrement =
      input.initiatorMsgIds.length -
      (input.initiatorMsgIds.indexOf(forkPoint ?? '') + 1).clamp(
        0,
        input.initiatorMsgIds.length,
      );
  final myIncrement =
      input.serverMsgIds.length -
      (input.serverMsgIds.indexOf(forkPoint ?? '') + 1).clamp(
        0,
        input.serverMsgIds.length,
      );

  final theirInc = theirIncrement < 0 ? 0 : theirIncrement;
  final myInc = myIncrement < 0 ? 0 : myIncrement;

  SyncConvState state;
  if (theirInc == 0 && myInc == 0) {
    state = SyncConvState.identical;
  } else if (theirInc > 0 && myInc == 0) {
    state = SyncConvState.initiatorOnly;
  } else if (theirInc == 0 && myInc > 0) {
    state = SyncConvState.serverOnly;
  } else {
    state = SyncConvState.fork;
  }

  return SyncConvPlan(
    conversationId: input.conversationId,
    conversationTitle: input.conversationTitle,
    state: state,
    forkPointMessageId: forkPoint,
    initiatorIncrementCount: theirInc,
    serverIncrementCount: myInc,
  );
}

/// Row keys that never participate in metadata-conflict detection: `id` and
/// `createdAt` are immutable identity, `messageIds` are already proven
/// identical by the message-ID-list comparison, and `updatedAt` must not
/// fabricate a conflict — it simply drifts with sync order across devices.
const Set<String> metadataExcludedRowKeys = {
  'id',
  'createdAt',
  'updatedAt',
  'messageIds',
};

/// Deep equality for the row values compared by [conversationMetadataConflict]
/// (nested maps/lists compare by content, not identity — e.g.
/// `versionSelections`, `workspaceDirectoryOverrides`, `chatSuggestions`,
/// `persistentQuickInstructionIds`).
bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!_deepEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Whether two serialized conversation rows differ as user-meaningful
/// metadata (category D, issue #615). Excludes [metadataExcludedRowKeys].
/// Missing keys only compare against present keys when the other side is
/// missing them too — a one-sided extra field is still a difference.
bool conversationMetadataConflict(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  for (final key in a.keys) {
    if (metadataExcludedRowKeys.contains(key)) continue;
    if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return true;
  }
  for (final key in b.keys) {
    if (metadataExcludedRowKeys.contains(key)) continue;
    if (!a.containsKey(key)) return true;
  }
  return false;
}

/// Whether a conversation is a metadata-only conflict worth shipping its row
/// in round 2 (issue #615 category D).
///
/// All conditions must hold: the session has a confirmed non-auto direction
/// (auto sessions stay byte-identical — no payload shape change), the
/// message-ID lists are identical (forked/one-sided rows already ride their
/// delta payload), both sides' row JSONs are available (modern peers), the
/// conversation is not a group (group payloads carry group metadata), and the
/// rows actually differ under [conversationMetadataConflict].
bool conversationIsMetadataOnlyConflict({
  required SyncConvPlan plan,
  required Map<String, dynamic>? theirRowJson,
  required Map<String, dynamic>? myRowJson,
  required bool hasConfirmedDirection,
}) {
  if (!hasConfirmedDirection) return false;
  if (plan.state != SyncConvState.identical) return false;
  if (plan.metadataOnly) return false;
  if (theirRowJson == null || myRowJson == null) return false;
  if (myRowJson['conversationKind'] == 'group') return false;
  return conversationMetadataConflict(theirRowJson, myRowJson);
}

/// Computes the earliest `since` timestamp from a list of conversation plans
/// and a timestamp lookup function.
///
/// The [forkPointTimestamp] function receives a [conversationId] and a
/// [forkPointMessageId], and should return the [DateTime] of that message,
/// or `null` if not found.
///
/// When there are conversations with increments but no fork point (one-sided
/// conversations), [earliestSince] is never set from those conversations.
/// In that case, if there are any non-identical conversations, the fallback
/// [DateTime(2000)] is returned to ensure a zip is produced.
DateTime? computeEarliestSince(
  List<SyncConvPlan> plans,
  DateTime? Function(String conversationId, String forkPointMessageId)
  forkPointTimestamp,
) {
  DateTime? earliest;
  bool hasNonIdentical = false;

  for (final plan in plans) {
    if (plan.state == SyncConvState.identical) continue;
    hasNonIdentical = true;

    if (plan.forkPointMessageId != null) {
      final ts = forkPointTimestamp(
        plan.conversationId,
        plan.forkPointMessageId!,
      );
      if (ts != null) {
        if (earliest == null || ts.isBefore(earliest)) {
          earliest = ts;
        }
      }
    }
  }

  // Fallback: if there are non-identical conversations but no fork point was
  // found (all conversations are one-sided), use epoch so that all data is
  // included in the incremental zip.
  if (earliest == null && hasNonIdentical) {
    return DateTime(2000);
  }

  return earliest;
}

/// Computes the set of zip-entry paths the [local] side must send to [peer]
/// so the peer ends up with the newest content for every path both share.
///
/// Rule (identical on both peers, deterministic per path — at most one side
/// packs a given path per run):
/// - path absent on [peer] → send;
/// - otherwise send iff `local.mtimeMs > peer.mtimeMs`.
///
/// Equal mtime is treated as "already synced" (mtime is ms-precision and a
/// restore sets the file's mtime to the sender's exact value, so an equal
/// mtime is a strong same-content signal). There is deliberately no size
/// tie-break: the receiving side's merge is strictly-newer per file, so a
/// size tie-break would send files the receiver never applies.
Set<String> computeFileDelta(
  Map<String, FileManifestEntry> local,
  Map<String, FileManifestEntry> peer,
) {
  final toSend = <String>{};
  for (final entry in local.entries) {
    final peerEntry = peer[entry.key];
    if (peerEntry == null || entry.value.mtimeMs > peerEntry.mtimeMs) {
      toSend.add(entry.key);
    }
  }
  return toSend;
}

/// Returns total bytes of the [delta] paths according to [manifest].
int sumDeltaBytes(Map<String, FileManifestEntry> manifest, Set<String> delta) {
  var total = 0;
  for (final key in delta) {
    total += manifest[key]?.size ?? 0;
  }
  return total;
}

// ---------------------------------------------------------------------------
// Multipart parsing (pure, no I/O dependencies)
// ---------------------------------------------------------------------------

/// Parses a multipart/form-data byte array and returns a map of
/// part name → raw body bytes.
///
/// [bytes] is the full request body. [boundary] is the multipart boundary
/// string (without the leading `--`).
Map<String, List<int>> parseMultipartBytes(List<int> bytes, String boundary) {
  final result = <String, List<int>>{};
  final boundaryBytes = utf8.encode('--$boundary');
  final parts = _splitByPattern(bytes, boundaryBytes);

  for (final part in parts) {
    if (part.isEmpty) continue;
    // Skip the closing boundary (--boundary--)
    if (part.length < 4) continue;

    // Find the header/body separator (\r\n\r\n).
    final separator = _findSublist(part, utf8.encode('\r\n\r\n'));
    if (separator == -1) continue;

    final headerBytes = part.sublist(0, separator);
    final bodyBytes = part.sublist(separator + 4);
    // Trim the multipart transport padding (\r\n) that precedes the next
    // boundary. We strip exactly \r\n (2 bytes) or bare \n (1 byte), never
    // unbounded — a zip body can legitimately end with 0x0D or 0x0A.
    var bodyEnd = bodyBytes.length;
    if (bodyEnd >= 2 &&
        bodyBytes[bodyEnd - 2] == 0x0D &&
        bodyBytes[bodyEnd - 1] == 0x0A) {
      bodyEnd -= 2;
    } else if (bodyEnd >= 1 && bodyBytes[bodyEnd - 1] == 0x0A) {
      bodyEnd -= 1;
    }

    final headerStr = utf8.decode(headerBytes);
    // Extract name from Content-Disposition.
    final nameMatch = RegExp(r'name="([^"]+)"').firstMatch(headerStr);
    if (nameMatch != null) {
      final name = nameMatch.group(1)!;
      result[name] = bodyBytes.sublist(0, bodyEnd);
    }
  }
  return result;
}

List<List<int>> _splitByPattern(List<int> data, List<int> pattern) {
  final result = <List<int>>[];
  var start = 0;
  while (true) {
    final idx = _findSublist(data, pattern, start);
    if (idx == -1) break;
    if (idx > start) {
      result.add(data.sublist(start, idx));
    }
    start = idx + pattern.length;
  }
  if (start < data.length) {
    result.add(data.sublist(start));
  }
  return result;
}

int _findSublist(List<int> data, List<int> pattern, [int start = 0]) {
  for (var i = start; i <= data.length - pattern.length; i++) {
    var match = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}
