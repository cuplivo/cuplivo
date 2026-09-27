import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// Wire vocabulary for LAN sync slice 1 (ADR-0002).
///
/// Everything on the wire is JSON built from plain maps. Conversation subtrees
/// are exchanged as *raw database row maps* — column name to JSON value — not
/// domain models, so the payload shape is owned by the schema, and the
/// symmetric version gate (equal schema versions only) makes unknown-column
/// handling a non-question. DateTime columns travel as microseconds-since-epoch
/// integers (`*Us` suffix), matching `MicrosecondDateTimeConverter`.

/// Version of the sync wire protocol itself. Both peers must agree; unknown
/// means refuse. Bump when a message shape changes in a way old builds cannot
/// parse safely.
///
/// v2: the hello manifest and the session batch gained the business sections
/// (entity rows by table name + synced preference rows); v1 peers are refused
/// at hello instead of parsing a manifest they cannot understand.
const int kSyncProtocolVersion = 2;

/// Wire name of the preference "kind" inside business manifests and payloads.
/// Entity kinds travel under their stable table name, which can never collide
/// with this sentinel (they all end in `_rows`).
const String kSyncPreferenceWire = '__preference__';

/// Stable identity of one business row across manifests, plans and checkpoints:
/// its kind plus its row id (or preference key). The separator cannot occur in
/// a table name or a preference key.
String syncBusinessKey(String kindWire, String id) => '$kindWire\u0000$id';

/// A conversation's identity inside a sync manifest: the row's `updated_at`
/// (µs), its message count, and a digest over every message id with its
/// coalesced mutation time (`COALESCE(updated_at, timestamp)`). The digest
/// changes on insert, edit *and* delete, which is what makes manifest
/// comparison sufficient to detect divergence without shipping rows.
///
/// The same entry shape describes business rows (entities and preferences):
/// `u` is the row's `updated_at`, `d` a content hash of the payload/value
/// (which catches "same clock, different content"), and `c` is unused (0).
class SyncManifestEntry {
  final int updatedAtUs;
  final int messageCount;
  final String digest;

  const SyncManifestEntry({
    required this.updatedAtUs,
    required this.messageCount,
    required this.digest,
  });

  Map<String, dynamic> toJson() => {
    'u': updatedAtUs,
    'c': messageCount,
    'd': digest,
  };

  static SyncManifestEntry fromJson(Map<String, dynamic> json) =>
      SyncManifestEntry(
        updatedAtUs: (json['u'] as num).toInt(),
        messageCount: (json['c'] as num).toInt(),
        digest: json['d'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is SyncManifestEntry &&
      other.updatedAtUs == updatedAtUs &&
      other.messageCount == messageCount &&
      other.digest == digest;

  @override
  int get hashCode => Object.hash(updatedAtUs, messageCount, digest);
}

/// One peer's whole conversation state, sent in hello. Slice 2 added the
/// business sections: entity rows by wire kind (table name) and the synced
/// preference keys; a v1 manifest simply has neither map present.
class SyncManifest {
  final Map<String, SyncManifestEntry> conversations;
  final Map<String, Map<String, SyncManifestEntry>> entities;
  final Map<String, SyncManifestEntry> preferences;

  const SyncManifest(
    this.conversations, {
    this.entities = const {},
    this.preferences = const {},
  });

  Map<String, dynamic> toJson() => {
    'conversations': conversations.map(
      (id, entry) => MapEntry(id, entry.toJson()),
    ),
    'entities': entities.map(
      (kind, rows) =>
          MapEntry(kind, rows.map((id, entry) => MapEntry(id, entry.toJson()))),
    ),
    'preferences': preferences.map(
      (key, entry) => MapEntry(key, entry.toJson()),
    ),
  };

  static SyncManifest fromJson(Map<String, dynamic> json) => SyncManifest(
    _flatEntries(json['conversations']),
    entities: _nestedEntries(json['entities']),
    preferences: _flatEntries(json['preferences']),
  );

  static Map<String, SyncManifestEntry> _flatEntries(Object? raw) => {
    if (raw is Map)
      for (final entry in raw.entries)
        entry.key: SyncManifestEntry.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        ),
  };

  static Map<String, Map<String, SyncManifestEntry>> _nestedEntries(
    Object? raw,
  ) => {
    if (raw is Map)
      for (final kind in raw.entries) kind.key: _flatEntries(kind.value),
  };
}

/// Digest over a conversation's message rows: sha256 of the sorted
/// `id:coalescedUpdatedAtUs` lines. Order-independent and sensitive to any
/// row insert, edit or delete.
String computeConversationDigest(
  Iterable<({String id, int updatedAtUs})> rows,
) {
  final lines = rows.map((row) => '${row.id}:${row.updatedAtUs}').toList()
    ..sort();
  return digestFromSortedLines(lines.join('\n'));
}

/// Digest of an already-sorted, newline-joined digest input. The repository
/// produces that text in one grouped query (`id:coalescedUpdatedAtUs` lines),
/// so manifest building never materialises a row per message.
String digestFromSortedLines(String sortedLines) =>
    crypto.sha256.convert(utf8.encode(sortedLines)).toString();

/// Digest of a newline-joined digest input in *any* line order: sorts the
/// lines first, so callers never depend on SQL `group_concat` ordering.
String digestFromDigestInput(String lines) {
  if (lines.isEmpty) return emptyConversationDigest;
  final sorted = lines.split('\n')..sort();
  return digestFromSortedLines(sorted.join('\n'));
}

/// The digest input for an empty conversation (no message rows).
final String emptyConversationDigest = digestFromSortedLines('');

/// Hello request/response body. The initiator sends its manifest with hello;
/// the responder answers with its own, so one round trip is enough to plan
/// both directions.
class SyncHello {
  final int protocolVersion;
  final int schemaVersion;
  final String deviceId;
  final String deviceName;
  final String platform;
  final SyncManifest manifest;

  const SyncHello({
    required this.protocolVersion,
    required this.schemaVersion,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.manifest,
  });

  Map<String, dynamic> toJson() => {
    'protocolVersion': protocolVersion,
    'schemaVersion': schemaVersion,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'manifest': manifest.toJson(),
  };

  static SyncHello fromJson(Map<String, dynamic> json) => SyncHello(
    protocolVersion: (json['protocolVersion'] as num).toInt(),
    schemaVersion: (json['schemaVersion'] as num).toInt(),
    deviceId: json['deviceId'] as String,
    deviceName: (json['deviceName'] as String?) ?? '',
    platform: (json['platform'] as String?) ?? '',
    manifest: SyncManifest.fromJson(
      (json['manifest'] as Map).cast<String, dynamic>(),
    ),
  );
}

/// Why a session cannot proceed. Wire values are stable strings.
enum SyncRefusalReason {
  /// Peer's database schema is newer than ours (symmetric version gate).
  peerSchemaNewer('peer_schema_newer'),

  /// Peer's wire protocol is unknown to us.
  protocolUnknown('protocol_unknown'),

  /// Device is not paired (certificate not pinned).
  notPaired('not_paired'),

  /// Another session is running; the deterministic initiator (lower deviceId)
  /// wins.
  busy('busy');

  final String wire;
  const SyncRefusalReason(this.wire);

  static SyncRefusalReason? tryParse(String? raw) => switch (raw) {
    'peer_schema_newer' => peerSchemaNewer,
    'protocol_unknown' => protocolUnknown,
    'not_paired' => notPaired,
    'busy' => busy,
    _ => null,
  };
}

/// A hello that ended in a refusal instead of a session.
class SyncHelloRefusal {
  final SyncRefusalReason reason;
  final String message;

  const SyncHelloRefusal(this.reason, this.message);

  Map<String, dynamic> toJson() => {'reason': reason.wire, 'message': message};

  static SyncHelloRefusal fromJson(Map<String, dynamic> json) =>
      SyncHelloRefusal(
        SyncRefusalReason.tryParse(json['reason'] as String?) ??
            SyncRefusalReason.protocolUnknown,
        (json['message'] as String?) ?? '',
      );
}

/// The last session's outcome as stored on a peer record. Structured rather
/// than a rendered summary so the panel can localize it — the engine's own
/// `summary` is machine text built for logs.
class SyncPeerReport {
  final bool success;
  final int sent;
  final int received;
  final int upsertedMessages;
  final int deletedMessages;
  final int deletedConversations;
  final int deferred;

  /// Business rows exchanged in either direction (entities + preferences).
  final int entityRows;
  final int preferenceRows;
  final SyncRefusalReason? refusal;

  /// Raw failure detail for non-refusal failures (transport errors).
  final String? error;

  const SyncPeerReport({
    required this.success,
    this.sent = 0,
    this.received = 0,
    this.upsertedMessages = 0,
    this.deletedMessages = 0,
    this.deletedConversations = 0,
    this.deferred = 0,
    this.entityRows = 0,
    this.preferenceRows = 0,
    this.refusal,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'success': success,
    'sent': sent,
    'received': received,
    'upserted': upsertedMessages,
    'deleted': deletedMessages,
    'deletedConversations': deletedConversations,
    'deferred': deferred,
    'entityRows': entityRows,
    'preferenceRows': preferenceRows,
    if (refusal != null) 'refusal': refusal!.wire,
    if (error != null) 'error': error,
  };

  static SyncPeerReport fromJson(Map<String, dynamic> json) => SyncPeerReport(
    success: (json['success'] as bool?) ?? true,
    sent: (json['sent'] as num?)?.toInt() ?? 0,
    received: (json['received'] as num?)?.toInt() ?? 0,
    upsertedMessages: (json['upserted'] as num?)?.toInt() ?? 0,
    deletedMessages: (json['deleted'] as num?)?.toInt() ?? 0,
    deletedConversations: (json['deletedConversations'] as num?)?.toInt() ?? 0,
    deferred: (json['deferred'] as num?)?.toInt() ?? 0,
    entityRows: (json['entityRows'] as num?)?.toInt() ?? 0,
    preferenceRows: (json['preferenceRows'] as num?)?.toInt() ?? 0,
    refusal: SyncRefusalReason.tryParse(json['refusal'] as String?),
    error: json['error'] as String?,
  );
}

/// One conversation subtree on the wire: the conversation row, its message
/// rows in stable order, its MCP server bindings, and the message part rows.
/// All values are JSON primitives; timestamps as µs ints; nullable columns may
/// be absent.
class SyncSubtreePayload {
  final Map<String, dynamic> conversation;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> parts;
  final List<Map<String, dynamic>> mcpServers;

  const SyncSubtreePayload({
    required this.conversation,
    required this.messages,
    required this.parts,
    this.mcpServers = const [],
  });

  Map<String, dynamic> toJson() => {
    'conversation': conversation,
    'messages': messages,
    'parts': parts,
    'mcpServers': mcpServers,
  };

  static SyncSubtreePayload fromJson(Map<String, dynamic> json) =>
      SyncSubtreePayload(
        conversation: (json['conversation'] as Map).cast<String, dynamic>(),
        messages: [
          for (final message in (json['messages'] as List? ?? const []))
            (message as Map).cast<String, dynamic>(),
        ],
        parts: [
          for (final part in (json['parts'] as List? ?? const []))
            (part as Map).cast<String, dynamic>(),
        ],
        mcpServers: [
          for (final server in (json['mcpServers'] as List? ?? const []))
            (server as Map).cast<String, dynamic>(),
        ],
      );
}

/// Business rows travelling in one direction: entity rows by wire kind (table
/// name) plus synced preference rows. Every row map uses raw column names and
/// raw SQLite values, exactly like a conversation subtree — storage format is
/// wire format.
class SyncBusinessPayload {
  final Map<String, List<Map<String, dynamic>>> entities;
  final List<Map<String, dynamic>> preferences;

  const SyncBusinessPayload({
    this.entities = const {},
    this.preferences = const [],
  });

  bool get isEmpty =>
      entities.values.every((rows) => rows.isEmpty) && preferences.isEmpty;

  Map<String, dynamic> toJson() => {
    'entities': entities.map(
      (kind, rows) => MapEntry(kind, rows.map((row) => row).toList()),
    ),
    'preferences': preferences,
  };

  static SyncBusinessPayload fromJson(Map<String, dynamic> json) =>
      SyncBusinessPayload(
        entities: {
          if (json['entities'] is Map)
            for (final kind in (json['entities'] as Map).entries)
              kind.key.toString(): [
                for (final row in (kind.value as List? ?? const []))
                  (row as Map).cast<String, dynamic>(),
              ],
        },
        preferences: [
          for (final row in (json['preferences'] as List? ?? const []))
            (row as Map).cast<String, dynamic>(),
        ],
      );
}

/// A batch of changes travelling in one direction: conversation subtrees and,
/// since slice 2, the business rows (entities + preferences) that changed.
class SyncDeltaBatch {
  final List<SyncSubtreePayload> subtrees;
  final SyncBusinessPayload business;

  const SyncDeltaBatch(
    this.subtrees, {
    this.business = const SyncBusinessPayload(),
  });

  Map<String, dynamic> toJson() => {
    'subtrees': subtrees.map((s) => s.toJson()).toList(),
    'business': business.toJson(),
  };

  static SyncDeltaBatch fromJson(Map<String, dynamic> json) => SyncDeltaBatch(
    [
      for (final subtree in (json['subtrees'] as List? ?? const []))
        SyncSubtreePayload.fromJson((subtree as Map).cast<String, dynamic>()),
    ],
    business: json['business'] == null
        ? const SyncBusinessPayload()
        : SyncBusinessPayload.fromJson(
            (json['business'] as Map).cast<String, dynamic>(),
          ),
  );

  String encodeJson() => jsonEncode(toJson());

  static SyncDeltaBatch decodeJson(String source) =>
      fromJson(jsonDecode(source) as Map<String, dynamic>);
}

/// What the initiator asks the responder to send back in the fetch beat:
/// conversation subtrees, entity rows by kind, and preference keys. The fetch
/// beat runs even when this is empty — that request is where the responder
/// executes its own plan (deletions, checkpoint advance, report).
class SyncFetchRequest {
  final List<String> conversationIds;
  final Map<String, List<String>> entityIds;
  final List<String> preferenceKeys;

  const SyncFetchRequest({
    this.conversationIds = const [],
    this.entityIds = const {},
    this.preferenceKeys = const [],
  });

  Map<String, dynamic> toJson() => {
    'ids': conversationIds,
    'entities': entityIds,
    'preferences': preferenceKeys,
  };

  static SyncFetchRequest fromJson(Map<String, dynamic> json) =>
      SyncFetchRequest(
        conversationIds: [
          for (final id in (json['ids'] as List? ?? const [])) id.toString(),
        ],
        entityIds: {
          if (json['entities'] is Map)
            for (final kind in (json['entities'] as Map).entries)
              kind.key.toString(): [
                for (final id in (kind.value as List? ?? const []))
                  id.toString(),
              ],
        },
        preferenceKeys: [
          for (final key in (json['preferences'] as List? ?? const []))
            key.toString(),
        ],
      );
}

/// The per-peer checkpoint: the row state this peer last observed on the other
/// device. `rows` holds each message's coalesced mutation time so the merge
/// can tell "the peer deleted this row" from "I edited it since".
///
/// Since slice 2 it also remembers the business rows (entities by table name,
/// plus preference keys) this peer last had, which is what lets the plan tell
/// "the peer deleted this row" from "the peer never had it".
class SyncCheckpoint {
  final Map<String, SyncCheckpointConversation> conversations;
  final Map<String, Map<String, SyncCheckpointEntry>> entities;
  final Map<String, SyncCheckpointEntry> preferences;

  const SyncCheckpoint(
    this.conversations, {
    this.entities = const {},
    this.preferences = const {},
  });

  Map<String, dynamic> toJson() => {
    'version': 1,
    'conversations': conversations.map(
      (id, entry) => MapEntry(id, entry.toJson()),
    ),
    'entities': entities.map(
      (kind, rows) =>
          MapEntry(kind, rows.map((id, entry) => MapEntry(id, entry.toJson()))),
    ),
    'preferences': preferences.map(
      (key, entry) => MapEntry(key, entry.toJson()),
    ),
  };

  static SyncCheckpoint fromJson(Map<String, dynamic> json) => SyncCheckpoint(
    {
      for (final entry
          in ((json['conversations'] as Map?)?.cast<String, dynamic>() ??
                  const <String, dynamic>{})
              .entries)
        entry.key: SyncCheckpointConversation.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        ),
    },
    entities: {
      for (final kind
          in ((json['entities'] as Map?)?.cast<String, dynamic>() ??
                  const <String, dynamic>{})
              .entries)
        kind.key: {
          for (final row in ((kind.value as Map?) ?? const {}).entries)
            row.key.toString(): SyncCheckpointEntry.fromJson(
              (row.value as Map).cast<String, dynamic>(),
            ),
        },
    },
    preferences: {
      for (final entry
          in ((json['preferences'] as Map?)?.cast<String, dynamic>() ??
                  const <String, dynamic>{})
              .entries)
        entry.key: SyncCheckpointEntry.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        ),
    },
  );

  static const empty = SyncCheckpoint({});
}

/// What this peer last had for one business row: its mutation clock and the
/// content hash that was current then.
class SyncCheckpointEntry {
  final int updatedAtUs;
  final String digest;

  const SyncCheckpointEntry({required this.updatedAtUs, required this.digest});

  Map<String, dynamic> toJson() => {'u': updatedAtUs, 'd': digest};

  static SyncCheckpointEntry fromJson(Map<String, dynamic> json) =>
      SyncCheckpointEntry(
        updatedAtUs: (json['u'] as num).toInt(),
        digest: json['d'] as String,
      );
}

class SyncCheckpointConversation {
  final int updatedAtUs;
  final String digest;
  final Map<String, int> rows;

  const SyncCheckpointConversation({
    required this.updatedAtUs,
    required this.digest,
    required this.rows,
  });

  Map<String, dynamic> toJson() => {'u': updatedAtUs, 'd': digest, 'r': rows};

  static SyncCheckpointConversation fromJson(Map<String, dynamic> json) =>
      SyncCheckpointConversation(
        updatedAtUs: (json['u'] as num).toInt(),
        digest: json['d'] as String,
        rows: {
          for (final entry
              in ((json['r'] as Map).cast<String, dynamic>()).entries)
            entry.key: (entry.value as num).toInt(),
        },
      );
}

/// Post-apply state of one conversation, returned by the repository so the
/// engine can build the next checkpoint without re-reading the database.
class SyncSubtreeApplyOutcome {
  /// True when the apply was skipped because a generation is writing to this
  /// conversation (ADR-0002: apply yields to generation). The checkpoint entry
  /// for this conversation must then be left untouched so the next session
  /// retries it.
  final bool deferred;

  /// Post-merge conversation row, or null when the conversation does not exist
  /// here (nothing was applied).
  final Map<String, dynamic>? conversationRow;

  /// Post-merge message rows (`id`, `timestamp`, `updated_at`, `message_order`).
  final List<Map<String, dynamic>> messageRows;

  final int upsertedMessages;
  final int deletedMessages;
  final bool conversationRowChanged;

  const SyncSubtreeApplyOutcome({
    this.deferred = false,
    this.conversationRow,
    this.messageRows = const [],
    this.upsertedMessages = 0,
    this.deletedMessages = 0,
    this.conversationRowChanged = false,
  });

  static const deferredOutcome = SyncSubtreeApplyOutcome(deferred: true);
}

/// Result of applying a business payload (entities + preferences). Deferred
/// means nothing was written — a restore holds the write fence, so the session
/// must keep the previous checkpoint entries and retry next time.
class SyncBusinessApplyOutcome {
  final bool deferred;
  final int entityRowsWritten;
  final int entityRowsDeleted;
  final int preferencesWritten;
  final int preferencesDeleted;
  final bool changed;

  const SyncBusinessApplyOutcome({
    this.deferred = false,
    this.entityRowsWritten = 0,
    this.entityRowsDeleted = 0,
    this.preferencesWritten = 0,
    this.preferencesDeleted = 0,
    this.changed = false,
  });

  static const deferredOutcome = SyncBusinessApplyOutcome(deferred: true);

  static const nothing = SyncBusinessApplyOutcome();
}
