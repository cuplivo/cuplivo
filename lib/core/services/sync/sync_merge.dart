import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'sync_models.dart';

/// Pure, side-effect-free sync planning and merge rules (ADR-0003).
///
/// Every function here is deterministic and symmetric: both peers, given the
/// same three views (mine, peer, checkpoint), compute the same plan; both
/// peers, given the same two row sets, converge to the same merged state.
/// That property is what removes the 3.x direction knob — there is never a
/// "which side wins" question for the user to answer.

/// What this device should do about one conversation.
enum SyncConvAction {
  /// Nothing to do; states already agree.
  none,

  /// This device sends its subtree.
  iSend,

  /// The peer sends its subtree.
  peerSends,

  /// Both sides changed since the checkpoint; both send, both merge.
  bothSend,

  /// The conversation was deleted here and the peer is unmodified — the peer
  /// must delete it. This device just drops its checkpoint entry.
  peerDeletes,

  /// The conversation was deleted on the peer and this device is unmodified —
  /// delete locally. If this device modified it, delete-vs-edit resolves to
  /// edit: this device keeps it and sends.
  iDelete,

  /// Deleted on both sides; nothing to move, checkpoint entry goes away.
  bothDeleted,
}

class SyncConvPlan {
  final String conversationId;
  final SyncConvAction action;

  const SyncConvPlan(this.conversationId, this.action);
}

/// Computes the full session plan from three manifests: [mine] and [peers]
/// are the hello manifests, [checkpoint] is the row state this device last
/// observed on the peer. Runs identically (with swapped roles) on the other
/// device.
List<SyncConvPlan> planSync({
  required SyncManifest mine,
  required SyncManifest peers,
  required SyncCheckpoint checkpoint,
}) {
  final ids = <String>{
    ...mine.conversations.keys,
    ...peers.conversations.keys,
    ...checkpoint.conversations.keys,
  };
  final plans = <SyncConvPlan>[];
  for (final id in ids) {
    plans.add(
      SyncConvPlan(
        id,
        _planConversation(
          mine: mine.conversations[id],
          peers: peers.conversations[id],
          checkpoint: checkpoint.conversations[id],
        ),
      ),
    );
  }
  return plans;
}

SyncConvAction _planConversation({
  SyncManifestEntry? mine,
  SyncManifestEntry? peers,
  SyncCheckpointConversation? checkpoint,
}) => planRowSync(
  mineDigest: mine?.digest,
  peerDigest: peers?.digest,
  checkpointDigest: checkpoint?.digest,
);

/// The one decision table both sync faces use: a conversation and a business
/// row (entity or preference) differ only in what "row state" means, so the
/// presence-and-digest reasoning is shared rather than copied.
///
/// A null digest means "this side does not have the row".
SyncConvAction planRowSync({
  required String? mineDigest,
  required String? peerDigest,
  required String? checkpointDigest,
}) {
  if (mineDigest == null && peerDigest == null) {
    return checkpointDigest == null
        ? SyncConvAction.none
        : SyncConvAction.bothDeleted;
  }
  if (mineDigest == null) {
    // Deleted here (or never had it) since the checkpoint.
    if (checkpointDigest == null) return SyncConvAction.peerSends;
    return peerDigest == checkpointDigest
        ? SyncConvAction.peerDeletes
        : SyncConvAction.peerSends; // peer modified: edit beats delete
  }
  if (peerDigest == null) {
    if (checkpointDigest == null) return SyncConvAction.iSend;
    return mineDigest == checkpointDigest
        ? SyncConvAction.iDelete
        : SyncConvAction.iSend; // modified here: edit beats delete
  }
  if (mineDigest == peerDigest) return SyncConvAction.none;
  if (checkpointDigest != null && peerDigest == checkpointDigest) {
    return SyncConvAction.iSend;
  }
  if (checkpointDigest != null && mineDigest == checkpointDigest) {
    return SyncConvAction.peerSends;
  }
  return SyncConvAction.bothSend;
}

/// One business row's plan. [kindWire] is a table name or
/// [kSyncPreferenceWire]; [id] is a row id or a preference key.
class SyncBusinessPlanItem {
  final String kindWire;
  final String id;
  final SyncConvAction action;

  const SyncBusinessPlanItem(this.kindWire, this.id, this.action);
}

/// Plans every business row in one pass over the union of both manifests and
/// the checkpoint. Entity kinds and preference keys go through the same table:
/// they are rows on the same clock.
List<SyncBusinessPlanItem> planBusinessSync({
  required SyncManifest mine,
  required SyncManifest peers,
  required SyncCheckpoint checkpoint,
}) {
  final plans = <SyncBusinessPlanItem>[];

  final kinds = <String>{
    ...mine.entities.keys,
    ...peers.entities.keys,
    ...checkpoint.entities.keys,
  };
  for (final kind in kinds) {
    final mineRows = mine.entities[kind] ?? const <String, SyncManifestEntry>{};
    final peerRows =
        peers.entities[kind] ?? const <String, SyncManifestEntry>{};
    final checkpointRows =
        checkpoint.entities[kind] ?? const <String, SyncCheckpointEntry>{};
    final ids = <String>{
      ...mineRows.keys,
      ...peerRows.keys,
      ...checkpointRows.keys,
    };
    for (final id in ids) {
      plans.add(
        SyncBusinessPlanItem(
          kind,
          id,
          planRowSync(
            mineDigest: mineRows[id]?.digest,
            peerDigest: peerRows[id]?.digest,
            checkpointDigest: checkpointRows[id]?.digest,
          ),
        ),
      );
    }
  }

  final keys = <String>{
    ...mine.preferences.keys,
    ...peers.preferences.keys,
    ...checkpoint.preferences.keys,
  };
  for (final key in keys) {
    plans.add(
      SyncBusinessPlanItem(
        kSyncPreferenceWire,
        key,
        planRowSync(
          mineDigest: mine.preferences[key]?.digest,
          peerDigest: peers.preferences[key]?.digest,
          checkpointDigest: checkpoint.preferences[key]?.digest,
        ),
      ),
    );
  }
  return plans;
}

/// LWW for one business row: the newer `updated_at` wins; an exact tie falls
/// to the higher deviceId, so both peers reach the same verdict without
/// talking to each other. Same rule as message and conversation rows.
bool incomingBusinessRowWins({
  required int localUpdatedAtUs,
  required int incomingUpdatedAtUs,
  required String myDeviceId,
  required String peerDeviceId,
}) {
  var cmp = incomingUpdatedAtUs.compareTo(localUpdatedAtUs);
  if (cmp == 0) cmp = peerDeviceId.compareTo(myDeviceId);
  return cmp >= 0;
}

/// One skill's content verdict for this session (slice 3).
///
/// The skill *record* rides the ordinary business plan; this is the separate
/// decision about its directory body, which has no clock of its own. The
/// record's `updated_at` does not track content edits, so the manifest digest
/// for a skill is `combineSkillDigest(payloadDigest, dirHash)` — content edits
/// are visible to [planRowSync], and the checkpoint holds the same combined
/// digest, which is what makes "unchanged side adopts the changed side" work.
class SkillContentPlan {
  final String skillId;
  final SyncConvAction action;

  const SkillContentPlan(this.skillId, this.action);
}

/// Plans every skill directory against the same three views as the row plan.
/// [skillWire] is the wire kind name of the skill entity kind (the authority
/// is `BusinessEntityKind.skill.wireName`).
///
/// The caller resolves [SyncConvAction.bothSend] with the one LWW rule —
/// newer record clock, ties to the higher deviceId — and reports the loser;
/// this planner only says that both sides changed.
List<SkillContentPlan> planSkillContentSync({
  required SyncManifest mine,
  required SyncManifest peers,
  required SyncCheckpoint checkpoint,
  required String skillWire,
}) {
  final mineRows =
      mine.entities[skillWire] ?? const <String, SyncManifestEntry>{};
  final peerRows =
      peers.entities[skillWire] ?? const <String, SyncManifestEntry>{};
  final checkpointRows =
      checkpoint.entities[skillWire] ?? const <String, SyncCheckpointEntry>{};
  final ids = <String>{
    ...mineRows.keys,
    ...peerRows.keys,
    ...checkpointRows.keys,
  };
  return [
    for (final id in ids)
      SkillContentPlan(
        id,
        planRowSync(
          mineDigest: mineRows[id]?.digest,
          peerDigest: peerRows[id]?.digest,
          checkpointDigest: checkpointRows[id]?.digest,
        ),
      ),
  ];
}

/// Content hash of a business row's payload or a preference's value. It rides
/// the manifest alongside `updated_at` so "same clock, different content"
/// (skewed or coarse clocks) still counts as divergence and gets exchanged.
String businessContentDigest(String content) =>
    crypto.sha256.convert(utf8.encode(content)).toString();

/// Result of merging one conversation row.
class ConversationRowMerge {
  /// The row to persist (local or incoming) plus whether it changed locally.
  final Map<String, dynamic> winner;
  final bool incomingWon;

  const ConversationRowMerge(this.winner, this.incomingWon);
}

/// LWW for the conversation row: newer `updated_at` wins; ties fall to the
/// higher deviceId so both peers decide identically. `updated_at` is
/// required on both rows (the column is non-nullable in the schema).
///
/// Row maps use the raw column names and raw SQLite values (microsecond
/// integers, 0/1 booleans) — the wire format is the storage format, so no
/// translation layer exists to drift out of sync with the schema.
ConversationRowMerge mergeConversationRow({
  required Map<String, dynamic> local,
  required Map<String, dynamic> incoming,
  required String myDeviceId,
  required String peerDeviceId,
}) {
  final localAt = (local['updated_at'] as num).toInt();
  final incomingAt = (incoming['updated_at'] as num).toInt();
  int cmp = incomingAt.compareTo(localAt);
  if (cmp == 0) {
    cmp = peerDeviceId.compareTo(myDeviceId);
  }
  return cmp >= 0
      ? ConversationRowMerge(incoming, true)
      : ConversationRowMerge(local, false);
}

/// Per-message merge decision for one conversation.
class MessageMergePlan {
  /// Incoming rows that must be written (insert or overwrite).
  final List<Map<String, dynamic>> upserts;

  /// Local message ids to delete: present locally, present in the checkpoint
  /// (so the peer used to have them), absent from the incoming subtree, and
  /// untouched here since — i.e. the peer deleted them.
  final List<String> deletes;

  const MessageMergePlan(this.upserts, this.deletes);
}

/// Coalesced mutation time of a message row: `COALESCE(updated_at, timestamp)`
/// — exactly the semantics the schema documents for sync/LWW.
int messageRowMutationUs(Map<String, dynamic> row) {
  final updatedAt = row['updated_at'];
  if (updatedAt is num) return updatedAt.toInt();
  return (row['timestamp'] as num).toInt();
}

/// Union-merge of message rows with LWW per row and checkpoint-based
/// deletion detection. [checkpointRows] is the peer-observed row set from the
/// last successful session for this conversation.
MessageMergePlan mergeMessageRows({
  required Map<String, Map<String, dynamic>> local,
  required Map<String, Map<String, dynamic>> incoming,
  required Map<String, int> checkpointRows,
  required String myDeviceId,
  required String peerDeviceId,
}) {
  final upserts = <Map<String, dynamic>>[];
  for (final entry in incoming.entries) {
    final localRow = local[entry.key];
    if (localRow == null) {
      upserts.add(entry.value);
      continue;
    }
    final localAt = messageRowMutationUs(localRow);
    final incomingAt = messageRowMutationUs(entry.value);
    var cmp = incomingAt.compareTo(localAt);
    if (cmp == 0) cmp = peerDeviceId.compareTo(myDeviceId);
    if (cmp >= 0) upserts.add(entry.value);
  }

  final deletes = <String>[];
  for (final entry in local.entries) {
    if (incoming.containsKey(entry.key)) continue;
    final seenAt = checkpointRows[entry.key];
    if (seenAt == null) continue; // created here since the last sync: keep
    if (messageRowMutationUs(entry.value) == seenAt) {
      deletes.add(entry.key); // untouched here, gone there: peer deleted it
    }
    // else: edited here — edit beats delete, keep the row.
  }
  return MessageMergePlan(upserts, deletes);
}

/// The ids of message rows that must lose the `(conversation_id, group_id,
/// version)` slot they share with another row of [rows].
///
/// Two devices that each regenerate (or edit-append) the same message create
/// rival rows with the same group and version but different ids, and the
/// schema's `UNIQUE(conversation_id, group_id, version)` allows only one: the
/// union of both sides would violate it and abort the apply — and every later
/// session with it. The winner is the newer mutation clock, ties to the higher
/// row id; both peers hold the same rival rows, and neither the clock nor the
/// id depends on which side is asking, so both reach the same verdict without
/// negotiating (the same property the per-row LWW rule has).
///
/// Rows without a group id cannot collide — SQLite treats NULLs as distinct in
/// a unique index — and are left alone.
List<String> resolveVersionGroupCollisions(
  Iterable<Map<String, dynamic>> rows,
) {
  final bySlot = <String, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    final groupId = row['group_id'];
    if (groupId is! String || groupId.isEmpty) continue;
    bySlot.putIfAbsent('$groupId\u0000${row['version']}', () => []).add(row);
  }
  final losers = <String>[];
  for (final cluster in bySlot.values) {
    if (cluster.length < 2) continue;
    cluster.sort((a, b) {
      final byClock = messageRowMutationUs(
        b,
      ).compareTo(messageRowMutationUs(a));
      if (byClock != 0) return byClock;
      return (b['id'] as String).compareTo(a['id'] as String);
    });
    for (final loser in cluster.skip(1)) {
      losers.add(loser['id'] as String);
    }
  }
  return losers;
}

/// Deterministic message order for a merged conversation. The slot each row
/// *carries* leads, and only a tie on that slot falls to `(timestamp, id)`;
/// assigning sequential values then compacts the result and guarantees
/// uniqueness. Both peers run this over the same merged rows and land on
/// identical orders, which resolves concurrent appends without touching
/// `updated_at`.
///
/// The carried slot has to lead because the app itself places rows by it: when
/// a user deletes the version a group is anchored on, the surviving revision is
/// moved onto the freed slot so the group does not jump to the bottom of the
/// timeline. Re-deriving from `(timestamp, id)` alone silently undid exactly
/// that, and the order is in no digest, so the local placement could never win
/// the next session back either.
Map<String, int> rederiveMessageOrder(Iterable<Map<String, dynamic>> rows) {
  final ordered = rows.toList()
    ..sort((a, b) {
      final bySlot = ((a['message_order'] as num).toInt()).compareTo(
        (b['message_order'] as num).toInt(),
      );
      if (bySlot != 0) return bySlot;
      final byTime = ((a['timestamp'] as num).toInt()).compareTo(
        (b['timestamp'] as num).toInt(),
      );
      if (byTime != 0) return byTime;
      return (a['id'] as String).compareTo(b['id'] as String);
    });
  return {
    for (var i = 0; i < ordered.length; i++) ordered[i]['id'] as String: i,
  };
}

/// Builds a checkpoint entry from the post-merge row state. Both peers call
/// this after applying; identical inputs produce identical entries, which is
/// what keeps the next session's plan symmetric.
SyncCheckpointConversation buildCheckpointConversation({
  required Map<String, dynamic> conversationRow,
  required Iterable<Map<String, dynamic>> messageRows,
}) {
  final rows = {
    for (final row in messageRows)
      row['id'] as String: messageRowMutationUs(row),
  };
  return SyncCheckpointConversation(
    updatedAtUs: (conversationRow['updated_at'] as num).toInt(),
    digest: computeConversationDigest(
      rows.entries.map((e) => (id: e.key, updatedAtUs: e.value)),
    ),
    rows: rows,
  );
}
