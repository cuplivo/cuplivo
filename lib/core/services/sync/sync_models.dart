import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'sync_limits.dart';

/// Wire vocabulary for LAN sync slice 1 (ADR-0003).
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
///
/// v3: blob carriage (slice 3). The session batch gained an asset manifest and
/// the skill directory hashes; hello gained the initiator's listen port so the
/// responder can pull blobs back. A v2 peer would apply rows whose blobs it
/// never received — the exact broken-skill case the record holdback guards —
/// so v2 peers are refused at hello too.
///
/// v4: clock readings (slice 5). Hello gained `clockUs` so each side can flag
/// a divergent wall clock; the reading is informational (sync proceeds, only
/// the report warns), but a v3 peer would silently never warn, so it is
/// refused rather than half-spoken to. This revision also adds the
/// `/sync/revoke` route (unpair propagation).
///
/// v5: workspace records. The `workspace` entity kind is no longer excluded
/// wholesale — managed workspaces ride the ordinary business sections, and only
/// *linked* folders stay behind, filtered per row. A v4 peer ignores a kind it
/// does not sync, so it would never answer for those rows: its manifest would
/// look like "the peer deleted every workspace", and a session against it would
/// silently half-sync instead of refusing. The shape of the messages did not
/// change, so nothing else has to.
///
/// v6: the files a responder cannot pull (slice 23). The push acknowledgement
/// gained `workspaceRequests` and `/sync/wsfile` gained a write verb, so a
/// responder that cannot dial the initiator back asks for the files it planned
/// and did not land, and the initiator pushes them over the connection it
/// already holds. A v5 peer reads that request list as "nothing owed" and has
/// no reverse connection to fetch over either, so a whole workspace's files
/// would silently never move in that direction while both reports claimed
/// success. Refused at hello like every other shape change.
///
/// v7: the blobs a responder cannot pull (slice 24). The same acknowledgement
/// gained `blobRequests` and the blob route gained a write verb, so the
/// attachment, avatar, font and skill-body plane gets the fallback slice 23
/// gave the workspace plane. A v6 peer would read the blob list as "nothing
/// owed" and had no reverse connection to fetch over either, so an undiallable
/// peer's images would keep failing while both reports claimed success.
///
/// v8: the deletion announcement carries the conversation row's clock beside the
/// digest ([SyncAnnouncedDeletion]). The digest is computed from the message
/// rows, so it cannot see a row write that left every message untouched — which
/// is exactly what a restore from the recycle bin is: the row goes back with
/// `now()` while the messages come back byte-identical. Without the clock, the
/// announcing peer deletes the restored conversation again at the next session.
/// A v7 peer would read the pair as a digest string (`toString`), match nothing,
/// and silently stop honouring announced deletions, so this is refused at hello
/// like every other shape change.
const int kSyncProtocolVersion = 8;

/// Wall-clock divergence (milliseconds) beyond which a session report carries
/// a clock-skew warning. Kerberos-style tolerance: below it, LWW comparisons
/// stay honest for any realistic edit rhythm; above it, timestamps start
/// lying systematically and the user should fix a device clock. Hardcoded on
/// purpose — it is a health threshold, not a preference.
const int kClockSkewWarnMs = 5 * 60 * 1000;

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

/// One file's version identity inside a workspace: its size and its mtime in
/// milliseconds. Sync compares this pair and nothing else — planning never
/// reads a byte of a workspace file (ADR-0003 slice 18), which is what lets a
/// gigabyte workspace be planned in the time it takes to `stat` its files.
class WorkspaceFileStamp {
  final int size;
  final int mtimeMs;

  const WorkspaceFileStamp({required this.size, required this.mtimeMs});

  /// `[size, mtimeMs]` — an array rather than an object: a workspace table is
  /// thousands of these and the field names would be most of the bytes.
  List<int> toJson() => [size, mtimeMs];

  /// Lenient: a malformed entry is dropped by the caller rather than failing
  /// the whole session (a peer's table is data, not a contract).
  static WorkspaceFileStamp? tryParse(Object? raw) {
    if (raw is! List || raw.length < 2) return null;
    final size = raw[0];
    final mtime = raw[1];
    if (size is! num || mtime is! num) return null;
    return WorkspaceFileStamp(size: size.toInt(), mtimeMs: mtime.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is WorkspaceFileStamp &&
      other.size == size &&
      other.mtimeMs == mtimeMs;

  @override
  int get hashCode => Object.hash(size, mtimeMs);

  @override
  String toString() => '${size}B@${mtimeMs}ms';
}

/// What this device and one peer last demonstrably agreed a file's version is,
/// from each side's own point of view.
///
/// Two stamps rather than one because the two devices' mtimes for the same
/// bytes need not be identical — a filesystem with coarse mtime granularity
/// rounds whatever the receiver sets, and the receiver cannot make the
/// sender's filesystem agree. Storing both keeps "we already agree" an exact
/// test instead of a tolerance, and an entry that is *absent* is always read
/// conservatively (the file is offered or fetched again, never deleted).
class SyncAgreedFile {
  final WorkspaceFileStamp mine;
  final WorkspaceFileStamp peer;

  const SyncAgreedFile(this.mine, this.peer);

  List<int> toJson() => [mine.size, mine.mtimeMs, peer.size, peer.mtimeMs];

  static SyncAgreedFile? tryParse(Object? raw) {
    if (raw is! List || raw.length < 4) return null;
    final values = <int>[];
    for (final value in raw.take(4)) {
      if (value is! num) return null;
      values.add(value.toInt());
    }
    return SyncAgreedFile(
      WorkspaceFileStamp(size: values[0], mtimeMs: values[1]),
      WorkspaceFileStamp(size: values[2], mtimeMs: values[3]),
    );
  }
}

/// One workspace's file table on the wire: relative path → version stamp.
///
/// A workspace *absent* from a batch's table map is one this device does not
/// share content for (turned off, over the caps, linked, or unknown here); a
/// workspace present with an empty table is one this device shares and holds
/// no files for. The two mean opposite things to the deletion rule — absence
/// is "no opinion", emptiness is "nothing" — so the distinction is part of the
/// shape rather than a convention.
typedef SyncWorkspaceFileTable = Map<String, WorkspaceFileStamp>;

/// Every workspace's file table in one direction, by workspace id.
typedef SyncWorkspaceFileTables = Map<String, SyncWorkspaceFileTable>;

/// One file a responder planned to fetch, could not land, and is asking the
/// initiator to push instead (slice 23).
///
/// [stamp] is the version the *initiator* advertised in its push, so a request
/// can only ever name a version this device has already been offered — the
/// request set is the write authorization on the receiving side, and the bytes
/// that arrive must match the stamp that was asked for.
class SyncWorkspaceFileRequest {
  final String workspaceId;
  final String relPath;
  final WorkspaceFileStamp stamp;

  const SyncWorkspaceFileRequest({
    required this.workspaceId,
    required this.relPath,
    required this.stamp,
  });

  Map<String, dynamic> toJson() => {
    'ws': workspaceId,
    'path': relPath,
    'stamp': stamp.toJson(),
  };

  /// Lenient, like every other peer-supplied shape: one malformed entry is
  /// dropped rather than failing the session, and a dropped one only means a
  /// file stays owed to the next session.
  static SyncWorkspaceFileRequest? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final workspaceId = raw['ws'];
    final relPath = raw['path'];
    final stamp = WorkspaceFileStamp.tryParse(raw['stamp']);
    if (workspaceId is! String ||
        workspaceId.isEmpty ||
        relPath is! String ||
        relPath.isEmpty ||
        stamp == null) {
      return null;
    }
    return SyncWorkspaceFileRequest(
      workspaceId: workspaceId,
      relPath: relPath,
      stamp: stamp,
    );
  }
}

/// One conversation the announcing device deleted, as its hello states it.
///
/// [digest] is the state both sides last agreed on, and [updatedAtUs] is the
/// conversation row's clock at that moment. Both halves are needed: the digest
/// is computed from the *message* rows, so it cannot see a row write that left
/// every message untouched — a restore from the recycle bin is exactly that,
/// writing the row back with `now()` and the messages back byte-identical. The
/// receiver treats a copy whose digest matches but whose row clock is newer as
/// something it wrote since, and an edit beats a delete (the same rule the plan
/// table's equal-digest branch applies).
///
/// [updatedAtUs] is null only when the announcement came off the wire without
/// one, which a v8 pair never does: the version gate refuses a v7 peer, and this
/// stays parseable so that refusal is a gate verdict rather than a parse error.
class SyncAnnouncedDeletion {
  const SyncAnnouncedDeletion({required this.digest, this.updatedAtUs});

  final String digest;
  final int? updatedAtUs;

  /// `[digest, clock]`, the compact shape [WorkspaceFileStamp] uses too.
  List<Object?> toJson() => [digest, if (updatedAtUs != null) updatedAtUs];

  /// Lenient: a bare string is a digest with no clock (the v7 shape), and
  /// anything that is not a list or a string is not an announcement.
  static SyncAnnouncedDeletion? tryParse(Object? raw) {
    if (raw is String) return SyncAnnouncedDeletion(digest: raw);
    if (raw is! List || raw.isEmpty) return null;
    final digest = raw.first;
    if (digest is! String) return null;
    return SyncAnnouncedDeletion(
      digest: digest,
      updatedAtUs: raw.length > 1 && raw[1] is num
          ? (raw[1] as num).toInt()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncAnnouncedDeletion &&
      other.digest == digest &&
      other.updatedAtUs == updatedAtUs;

  @override
  int get hashCode => Object.hash(digest, updatedAtUs);

  @override
  String toString() => 'SyncAnnouncedDeletion($digest @ $updatedAtUs)';
}

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

  /// This device's own sync listener port (slice 3). The responder uses it,
  /// together with the request's remote address and the pairing it already
  /// holds, to pull blobs back from the initiator over its own listener.
  final int? listenPort;

  /// This device's own addresses, beside [listenPort] (slice 23).
  ///
  /// The address the responder *sees* the caller connect from is not always the
  /// caller's own — a NAT rewrite can make it the responder's own address — so
  /// the responder needs somewhere else to try when it has to dial back. Empty
  /// on a device that has not enumerated its addresses yet, which leaves the
  /// observed address as the only candidate, exactly as before.
  final List<String> candidateHosts;

  /// This device's wall clock when the hello was built, in µs since epoch —
  /// the same unit row clocks use, so the peer can flag divergence (slice 5).
  /// Purely informational: sync proceeds regardless; only the report warns.
  /// Parsed leniently (null when absent) so a truncated body degrades to "no
  /// reading" rather than a parse error.
  final int? clockUs;

  /// Conversations this device could not apply last session (a generation was
  /// writing there), so the peer must assume its copy never arrived and send
  /// it again rather than read this device's silence as a deletion. Carried on
  /// both hellos: whichever side plans next needs it.
  final List<String> unappliedConversations;

  /// Whether this device's business apply was deferred last session (a restore
  /// held the write fence). A peer must then treat every row this device lacks
  /// as "never delivered", not as deleted here.
  final bool unappliedBusiness;

  /// This device's data epoch: bumped whenever the local database is
  /// bulk-replaced (a restore, an overwrite import). A peer that last synced
  /// under a different epoch must treat everything it lacks here as "never
  /// delivered" rather than "deleted here", because a replacement's dropped
  /// rows were never deletions.
  final int epoch;

  /// Conversations this device shared with the peer and no longer holds — a
  /// deletion the peer has not confirmed yet — with the digest *and the row
  /// clock* both sides last agreed on. A deletion is otherwise inferred from the
  /// peer's absence, which cannot be told apart from "the peer never received
  /// it": this list says which of the two it is, and the pair lets the receiver
  /// keep a copy it wrote since (`edit beats delete`), exactly as the plan table
  /// does — the clock is what makes a restore from the recycle bin count as one.
  ///
  /// Derived from the checkpoint rather than a separate table, so an entry
  /// survives exactly as long as the peer has not caught up.
  final Map<String, SyncAnnouncedDeletion> deletedConversations;

  const SyncHello({
    required this.protocolVersion,
    required this.schemaVersion,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.manifest,
    this.listenPort,
    this.candidateHosts = const [],
    this.clockUs,
    this.unappliedConversations = const [],
    this.unappliedBusiness = false,
    this.deletedConversations = const {},
    this.epoch = 0,
  });

  Map<String, dynamic> toJson() => {
    'protocolVersion': protocolVersion,
    'schemaVersion': schemaVersion,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'manifest': manifest.toJson(),
    if (listenPort != null) 'listenPort': listenPort,
    if (candidateHosts.isNotEmpty) 'candidateHosts': candidateHosts,
    if (clockUs != null) 'clockUs': clockUs,
    if (unappliedConversations.isNotEmpty) 'unapplied': unappliedConversations,
    if (unappliedBusiness) 'unappliedBusiness': true,
    if (deletedConversations.isNotEmpty)
      'deleted': {
        for (final entry in deletedConversations.entries)
          entry.key: entry.value.toJson(),
      },
    if (epoch != 0) 'epoch': epoch,
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
    listenPort: (json['listenPort'] as num?)?.toInt(),
    candidateHosts: [
      for (final host in (json['candidateHosts'] as List? ?? const []))
        if (host is String && host.isNotEmpty) host,
    ],
    clockUs: (json['clockUs'] as num?)?.toInt(),
    unappliedConversations: [
      for (final id in (json['unapplied'] as List? ?? const [])) id.toString(),
    ],
    unappliedBusiness: json['unappliedBusiness'] == true,
    deletedConversations: {
      for (final entry
          in ((json['deleted'] as Map?)?.cast<String, dynamic>() ??
                  const <String, dynamic>{})
              .entries)
        if (SyncAnnouncedDeletion.tryParse(entry.value) case final deletion?)
          entry.key: deletion,
    },
    epoch: (json['epoch'] as num?)?.toInt() ?? 0,
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

  /// The hello's body identity is not the authenticated caller. The pairing
  /// secret authenticates exactly one device id; a body naming another paired
  /// device must not build a session under that device's name.
  identityMismatch('identity_mismatch'),

  /// A session for this pair is already running on the answering side, in
  /// either role: one session per pair at a time. The refused round is retried
  /// by the next trigger — a launch, a resume, or the manual button.
  busy('busy'),

  /// This round yielded to the peer's own session with this device, and that
  /// session is the one that runs. Not a failure of the peer and not a
  /// refusal *by* it: the round is recorded nowhere, because the pair's real
  /// outcome arrives from the answered side. A round that had not heard the
  /// peer's hello yet when the peer's hello arrived is the one that yields —
  /// on a LAN that only works one way, refusing it instead left both devices
  /// failing forever while the reachable direction sat idle.
  superseded('superseded');

  final String wire;
  const SyncRefusalReason(this.wire);

  static SyncRefusalReason? tryParse(String? raw) => switch (raw) {
    'peer_schema_newer' => peerSchemaNewer,
    'protocol_unknown' => protocolUnknown,
    'not_paired' => notPaired,
    'identity_mismatch' => identityMismatch,
    'busy' => busy,
    'superseded' => superseded,
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

/// Why a session failed when it was not a refusal. Structured rather than a
/// rendered string for the same reason as [SyncRefusalReason]: the panel
/// localizes it, and a raw exception — which carries the peer's address and
/// port — never reaches the card or a snackbar.
enum SyncFailureReason {
  /// The peer record carries no endpoint at all: there is nothing to dial, so
  /// the fix is a new address (rescan the peer's QR, or edit its card), not a
  /// retry.
  noEndpoint('no_endpoint'),

  /// The peer could not be reached: a refused connection, a dead address.
  unreachable('unreachable'),

  /// A beat stopped answering mid-session.
  timeout('timeout'),

  /// The peer answered, and answered with a failure of its own.
  peerError('peer_error'),

  /// Anything else: a database error, a corrupt payload, a bug.
  internal('internal');

  final String wire;
  const SyncFailureReason(this.wire);

  static SyncFailureReason? tryParse(String? raw) => switch (raw) {
    'no_endpoint' => noEndpoint,
    'unreachable' => unreachable,
    'timeout' => timeout,
    'peer_error' => peerError,
    'internal' => internal,
    _ => null,
  };
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

  /// Blobs exchanged in either direction (slice 3): files landed, total bytes,
  /// skills whose directory body converged, skills where this device's content
  /// lost the deterministic conflict rule, and blobs that could not be fetched.
  final int blobsMoved;
  final int blobBytes;
  final int skillsUpdated;
  final int skillConflicts;
  final int blobsMissing;

  /// Workspace content in either direction (slice 18): files this device
  /// landed, the bytes they carried, files it deleted because the peer deleted
  /// them, its own edits the peer's version replaced, and files it wanted but
  /// could not fetch (they stay owed and are retried next session).
  ///
  /// A file this device *pushed* counts here too (slice 23): what the figure
  /// answers is "what did this session move for me", and the side that pushed a
  /// file is the side that watched it arrive — the asset-cache rule is what
  /// decides which side that is, not which direction the bytes travelled. What
  /// is *not* counted is a file the peer moved on its own account: that lands in
  /// the peer's report, and inventing a "sent" figure this device cannot see
  /// would be a claim it cannot make.
  final int workspaceFiles;
  final int workspaceBytes;
  final int workspaceFilesRemoved;
  final int workspaceConflicts;
  final int workspaceFilesMissing;

  /// Workspace *folders* this device deliberately did not remove after the peer
  /// deleted the workspace's row, because the user had switched content sync off
  /// for it. Counted so the protection is visible rather than inferred: the row
  /// really is gone, and the folder really is still on disk, and the only place
  /// that can say so is this report.
  final int workspaceFoldersKept;

  /// Workspaces this device shared no content for this session: turned off, or
  /// over the file/byte caps. Counted because silence about a workspace the
  /// user believes is syncing is the one failure mode this face must never
  /// have.
  final int workspacesOmitted;

  /// Business rows whose local version was replaced by the peer's newer row
  /// (slice 5): entities and synced preferences counted separately. "One
  /// number per face" — which row lost lives in the logs, not on the card.
  final int entityRowsLost;
  final int preferencesLost;

  /// Signed clock divergence against this peer in milliseconds, present only
  /// when it exceeded [kClockSkewWarnMs] (positive: this device ran ahead).
  /// The session still succeeded — this is the yellow flag, not a failure.
  final int? clockSkewMs;
  final SyncRefusalReason? refusal;

  /// Why the session failed, when it was not a refusal. Null on success, and
  /// on records written before the reason was structured — the panel falls
  /// back to a generic line rather than showing a stored exception text.
  final SyncFailureReason? failure;

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
    this.blobsMoved = 0,
    this.blobBytes = 0,
    this.skillsUpdated = 0,
    this.skillConflicts = 0,
    this.blobsMissing = 0,
    this.workspaceFiles = 0,
    this.workspaceBytes = 0,
    this.workspaceFilesRemoved = 0,
    this.workspaceConflicts = 0,
    this.workspaceFilesMissing = 0,
    this.workspaceFoldersKept = 0,
    this.workspacesOmitted = 0,
    this.entityRowsLost = 0,
    this.preferencesLost = 0,
    this.clockSkewMs,
    this.refusal,
    this.failure,
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
    'blobsMoved': blobsMoved,
    'blobBytes': blobBytes,
    'skillsUpdated': skillsUpdated,
    'skillConflicts': skillConflicts,
    'blobsMissing': blobsMissing,
    'workspaceFiles': workspaceFiles,
    'workspaceBytes': workspaceBytes,
    'workspaceFilesRemoved': workspaceFilesRemoved,
    'workspaceConflicts': workspaceConflicts,
    'workspaceFilesMissing': workspaceFilesMissing,
    'workspaceFoldersKept': workspaceFoldersKept,
    'workspacesOmitted': workspacesOmitted,
    'entityRowsLost': entityRowsLost,
    'preferencesLost': preferencesLost,
    if (clockSkewMs != null) 'clockSkewMs': clockSkewMs,
    if (refusal != null) 'refusal': refusal!.wire,
    if (failure != null) 'failure': failure!.wire,
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
    blobsMoved: (json['blobsMoved'] as num?)?.toInt() ?? 0,
    blobBytes: (json['blobBytes'] as num?)?.toInt() ?? 0,
    skillsUpdated: (json['skillsUpdated'] as num?)?.toInt() ?? 0,
    skillConflicts: (json['skillConflicts'] as num?)?.toInt() ?? 0,
    blobsMissing: (json['blobsMissing'] as num?)?.toInt() ?? 0,
    workspaceFiles: (json['workspaceFiles'] as num?)?.toInt() ?? 0,
    workspaceBytes: (json['workspaceBytes'] as num?)?.toInt() ?? 0,
    workspaceFilesRemoved:
        (json['workspaceFilesRemoved'] as num?)?.toInt() ?? 0,
    workspaceConflicts: (json['workspaceConflicts'] as num?)?.toInt() ?? 0,
    workspaceFilesMissing:
        (json['workspaceFilesMissing'] as num?)?.toInt() ?? 0,
    workspaceFoldersKept: (json['workspaceFoldersKept'] as num?)?.toInt() ?? 0,
    workspacesOmitted: (json['workspacesOmitted'] as num?)?.toInt() ?? 0,
    entityRowsLost: (json['entityRowsLost'] as num?)?.toInt() ?? 0,
    preferencesLost: (json['preferencesLost'] as num?)?.toInt() ?? 0,
    clockSkewMs: (json['clockSkewMs'] as num?)?.toInt(),
    refusal: SyncRefusalReason.tryParse(json['refusal'] as String?),
    failure: SyncFailureReason.tryParse(json['failure'] as String?),
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

/// A well-formed blob hash: the sha256 hex digest a manifest publishes and a
/// blob route names.
final RegExp _blobHashPattern = RegExp(r'^[0-9a-f]{64}$');

/// Whether [value] is a blob hash — one spelling for the wire parser and the
/// server's route check, so "a hash" cannot mean two things on the two sides of
/// a request.
bool isBlobHash(String value) => _blobHashPattern.hasMatch(value);

/// One blob the sender can serve, discovered from the payloads it is sending:
/// every `kelivo-file` URI that appears in a travelling row (message part,
/// entity payload, preference value) becomes a file entry; a skill whose
/// record travels becomes a skill-directory entry keyed by the directory hash.
///
/// The GET path is always `/sync/blob/<contentHash>`; [kind] tells the
/// receiver how to apply the bytes, and [key] is the placement target (the
/// canonical URI for a file, the skill id for a directory).
class SyncBlobEntry {
  static const String kindFile = 'file';
  static const String kindSkillDir = 'skill-dir';

  /// The two kinds the wire accepts, and the only values a parsed entry may
  /// carry: everything downstream branches on [kind], so an unknown one is a
  /// dropped entry rather than a third behaviour nobody wrote.
  static const Set<String> kinds = {kindFile, kindSkillDir};

  final String kind;
  final String key;
  final String contentHash;
  final int byteSize;

  const SyncBlobEntry({
    required this.kind,
    required this.key,
    required this.contentHash,
    this.byteSize = 0,
  });

  /// Stable identity of what this entry wants, independent of content: used
  /// to key pending-blob retries (a new hash for the same target supersedes).
  String get target => targetOf(kind, key);

  /// The same identity from its two halves, for a caller that has them without
  /// an entry to hand (the push route reads them off the request headers).
  static String targetOf(String kind, String key) => '$kind\u0000$key';

  /// Lenient parse of one entry off the wire, or null when it is not one. The
  /// entries arrive from a peer (a manifest, a checkpoint that travelled, an
  /// acknowledgement), and a malformed one is a blob that stays owed — never a
  /// session that throws.
  static SyncBlobEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['k'];
    final key = raw['t'];
    final hash = raw['h'];
    final size = raw['s'];
    if (kind is! String || !kinds.contains(kind)) return null;
    if (key is! String || key.isEmpty) return null;
    if (hash is! String || !isBlobHash(hash)) return null;
    final bytes = size is num ? size.toInt() : 0;
    if (bytes < 0) return null;
    return SyncBlobEntry(
      kind: kind,
      key: key,
      contentHash: hash,
      byteSize: bytes,
    );
  }

  /// The same entry with the byte size actually landed (the manifest may not
  /// know it — a skill zip is produced on demand).
  SyncBlobEntry withSize(int bytes) => SyncBlobEntry(
    kind: kind,
    key: key,
    contentHash: contentHash,
    byteSize: bytes,
  );

  Map<String, dynamic> toJson() => {
    'k': kind,
    't': key,
    'h': contentHash,
    's': byteSize,
  };

  static SyncBlobEntry fromJson(Map<String, dynamic> json) => SyncBlobEntry(
    kind: (json['k'] as String?) ?? kindFile,
    key: json['t'] as String,
    contentHash: json['h'] as String,
    byteSize: (json['s'] as num?)?.toInt() ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is SyncBlobEntry &&
      other.kind == kind &&
      other.key == key &&
      other.contentHash == contentHash;

  @override
  int get hashCode => Object.hash(kind, key, contentHash);
}

/// Digest that makes a skill's content edits visible in the business
/// manifest: the record payload digest combined with the directory hash. A
/// content-only edit leaves `updated_at` alone, so without this combination
/// the plan would say "same clock, same content" and never transfer the body.
String combineSkillDigest(String payloadDigest, String dirHash) =>
    crypto.sha256.convert(utf8.encode('$payloadDigest\n$dirHash')).toString();

/// A batch of changes travelling in one direction: conversation subtrees,
/// the business rows (entities + preferences) that changed, and since slice 3
/// the blob manifest for everything these rows reference — the file blobs the
/// receiver may need plus the directory hashes of travelling skill records.
class SyncDeltaBatch {
  final List<SyncSubtreePayload> subtrees;
  final SyncBusinessPayload business;
  final List<SyncBlobEntry> assets;
  final Map<String, String> skillHashes;

  /// Every workspace this device shares content for, with its file table
  /// (slice 18). Sent on both beats — the push and the fetch response — because
  /// each direction's receiver is the one that pulls, and a session that
  /// skipped one of them would leave that direction's files unplanned.
  final SyncWorkspaceFileTables workspaceFiles;

  const SyncDeltaBatch(
    this.subtrees, {
    this.business = const SyncBusinessPayload(),
    this.assets = const [],
    this.skillHashes = const {},
    this.workspaceFiles = const {},
  });

  Map<String, dynamic> toJson() => {
    'subtrees': subtrees.map((s) => s.toJson()).toList(),
    'business': business.toJson(),
    'assets': [for (final entry in assets) entry.toJson()],
    'skillHashes': skillHashes,
    'workspaceFiles': {
      for (final entry in workspaceFiles.entries)
        entry.key: {
          for (final file in entry.value.entries) file.key: file.value.toJson(),
        },
    },
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
    assets: [
      for (final entry in (json['assets'] as List? ?? const []))
        SyncBlobEntry.fromJson((entry as Map).cast<String, dynamic>()),
    ],
    skillHashes: {
      if (json['skillHashes'] is Map)
        for (final entry in (json['skillHashes'] as Map).entries)
          entry.key.toString(): entry.value.toString(),
    },
    workspaceFiles: _fileTablesFromJson(json['workspaceFiles']),
  );

  /// Reads a batch's workspace tables. A table whose entries all fail to parse
  /// stays present and empty rather than disappearing: "the peer shares this
  /// workspace and has nothing that rides" and "the peer does not share it" are
  /// opposite statements to the deletion rule, and a dropped key would turn the
  /// first into the second.
  static SyncWorkspaceFileTables _fileTablesFromJson(Object? raw) {
    if (raw is! Map) return const {};
    final tables = <String, SyncWorkspaceFileTable>{};
    for (final entry in raw.entries) {
      final workspaceId = entry.key.toString();
      if (workspaceId.isEmpty) continue;
      final table = <String, WorkspaceFileStamp>{};
      if (entry.value is Map) {
        for (final file in (entry.value as Map).entries) {
          final path = file.key.toString();
          final stamp = WorkspaceFileStamp.tryParse(file.value);
          if (path.isEmpty || stamp == null) continue;
          table[path] = stamp;
        }
      }
      tables[workspaceId] = table;
    }
    return tables;
  }

  String encodeJson() => jsonEncode(toJson());

  static SyncDeltaBatch decodeJson(String source) =>
      fromJson(jsonDecode(source) as Map<String, dynamic>);
}

/// The responder's answer to the push beat. Sending is not receipt: a
/// conversation the responder deferred (a generation was writing there) and a
/// business apply it deferred (a restore held its write fence) must not advance
/// the initiator's checkpoint, or the next session reads "the peer no longer
/// has this" and deletes the sender's own rows.
class SyncApplyAck {
  final int applied;

  /// Conversation ids the responder accepted the push for but did not apply.
  final Set<String> deferred;

  /// Whether the responder deferred the whole business apply.
  final bool businessDeferred;

  /// Skill records the responder received but did not apply because the body
  /// did not land. A skill is a record *plus* its directory, and the receiver
  /// strips the record when the body is missing — so the push delivered
  /// nothing for it and the sender must not record it as peer-seen.
  final Set<String> deferredSkills;

  /// Workspace files the responder planned to fetch and could not land —
  /// because it could not dial the initiator back, or because the transfer
  /// failed. The initiator pushes exactly these before the fetch beat, so the
  /// file moves over the one direction that is known to work (slice 23).
  ///
  /// Empty on every session where the reverse direction works, which is what
  /// keeps the ordinary LAN pair on the original path.
  final List<SyncWorkspaceFileRequest> workspaceRequests;

  /// Blobs the responder planned to fetch and could not land, for the same
  /// reason and with the same shape as [workspaceRequests] (slice 24).
  ///
  /// Each entry is one the *initiator itself* advertised in this session's
  /// manifest (or asked for in an earlier one), so the list is not a wish: it
  /// is exactly the set of writes the responder's own plan can justify. The
  /// initiator pushes the ones it can still serve at that hash, before its
  /// fetch beat.
  final List<SyncBlobEntry> blobRequests;

  const SyncApplyAck({
    required this.applied,
    this.deferred = const {},
    this.businessDeferred = false,
    this.deferredSkills = const {},
    this.workspaceRequests = const [],
    this.blobRequests = const [],
  });

  Map<String, dynamic> toJson() => {
    'applied': applied,
    if (deferred.isNotEmpty) 'deferred': deferred.toList(growable: false),
    if (businessDeferred) 'businessDeferred': true,
    if (deferredSkills.isNotEmpty)
      'deferredSkills': deferredSkills.toList(growable: false),
    if (workspaceRequests.isNotEmpty)
      'workspaceRequests': [
        for (final request in workspaceRequests) request.toJson(),
      ],
    if (blobRequests.isNotEmpty)
      'blobRequests': [for (final entry in blobRequests) entry.toJson()],
  };

  static SyncApplyAck fromJson(Map<String, dynamic> json) => SyncApplyAck(
    applied: (json['applied'] as num?)?.toInt() ?? 0,
    deferred: {
      for (final id in (json['deferred'] as List? ?? const [])) id.toString(),
    },
    businessDeferred: json['businessDeferred'] == true,
    deferredSkills: {
      for (final id in (json['deferredSkills'] as List? ?? const []))
        id.toString(),
    },
    workspaceRequests: _requestsFromJson(json['workspaceRequests']),
    blobRequests: _blobRequestsFromJson(json['blobRequests']),
  );

  /// One malformed entry is dropped, not a session: a request that cannot be
  /// read is a file that stays owed and is asked for again next time.
  static List<SyncWorkspaceFileRequest> _requestsFromJson(Object? raw) {
    if (raw is! List) return const [];
    final requests = <SyncWorkspaceFileRequest>[];
    for (final entry in raw) {
      final request = SyncWorkspaceFileRequest.tryParse(entry);
      if (request != null) requests.add(request);
    }
    return requests;
  }

  /// The same rule for blobs, plus the one bound the blob list needs: past
  /// [kMaxBlobRequestsPerSession] each further entry would cost the initiator a
  /// registry query and a skill-directory scan, so the list is cut there. The
  /// cut entries stay in the receiver's pending set and are asked for again.
  static List<SyncBlobEntry> _blobRequestsFromJson(Object? raw) {
    if (raw is! List) return const [];
    final requests = <SyncBlobEntry>[];
    for (final entry in raw) {
      if (requests.length >= kMaxBlobRequestsPerSession) break;
      final request = SyncBlobEntry.tryParse(entry);
      if (request != null) requests.add(request);
    }
    return requests;
  }
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

  /// Blobs this device still owes from the peer, keyed by entry identity:
  /// a fetch that failed (peer GC'd the file, IO error, reverse connection
  /// refused) is retried at the start of the next session. Entries are
  /// removed on success and superseded when a newer hash arrives for the
  /// same target (slice 3).
  final Map<String, SyncBlobEntry> pendingBlobs;

  /// The directory hash of each skill at the moment both sides last agreed
  /// on it — the baseline for content-conflict detection (slice 3).
  final Map<String, String> skillHashes;

  /// Per workspace, the file versions both sides last demonstrably held, keyed
  /// by relative path (slice 18). This is the ledger the workspace content
  /// plan reads: it is what tells "the peer deleted this file" from "the peer
  /// never had it", and what keeps a conflict from being re-decided every
  /// session.
  ///
  /// It lives inside the checkpoint rather than in a file of its own because
  /// it is per-peer state advanced by the same session, saved at the same
  /// moment, and covered by the same "one atomic write per session" rule —
  /// two files could only disagree with each other. A checkpoint an entry
  /// cannot be recovered from is resettable exactly like every other entry
  /// here: absent means "nothing was ever agreed", which the plan reads
  /// conservatively.
  final Map<String, Map<String, SyncAgreedFile>> workspaceFiles;

  /// What this device still owes itself: conversations and the business face
  /// whose *apply* it deferred (a generation writing there, or a restore
  /// holding the write fence). Advertised in the next hello so the peer knows
  /// its earlier send never landed and re-sends instead of reading the
  /// absence as a deletion — the receive-side half of "sending is not
  /// receipt".
  final List<String> unappliedConversations;
  final bool unappliedBusiness;

  /// The peer's data epoch at the last session. A different value on the next
  /// hello means the peer's database was bulk-replaced since, so its missing
  /// rows prove nothing and every plan must be computed as if nothing had ever
  /// been shared (see [SyncStore.readDataEpoch]).
  final int peerEpoch;

  const SyncCheckpoint(
    this.conversations, {
    this.entities = const {},
    this.preferences = const {},
    this.pendingBlobs = const {},
    this.skillHashes = const {},
    this.workspaceFiles = const {},
    this.unappliedConversations = const [],
    this.unappliedBusiness = false,
    this.peerEpoch = 0,
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
    'pendingBlobs': pendingBlobs.map(
      (target, entry) => MapEntry(target, entry.toJson()),
    ),
    'skillHashes': skillHashes,
    if (workspaceFiles.isNotEmpty)
      'workspaceFiles': {
        for (final workspace in workspaceFiles.entries)
          if (workspace.value.isNotEmpty)
            workspace.key: {
              for (final file in workspace.value.entries)
                file.key: file.value.toJson(),
            },
      },
    if (unappliedConversations.isNotEmpty) 'unapplied': unappliedConversations,
    if (unappliedBusiness) 'unappliedBusiness': true,
    if (peerEpoch != 0) 'peerEpoch': peerEpoch,
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
    pendingBlobs: {
      if (json['pendingBlobs'] is Map)
        for (final entry
            in (json['pendingBlobs'] as Map).cast<String, dynamic>().entries)
          entry.key.toString(): SyncBlobEntry.fromJson(
            (entry.value as Map).cast<String, dynamic>(),
          ),
    },
    skillHashes: {
      if (json['skillHashes'] is Map)
        for (final entry
            in (json['skillHashes'] as Map).cast<String, dynamic>().entries)
          entry.key.toString(): entry.value.toString(),
    },
    workspaceFiles: {
      if (json['workspaceFiles'] is Map)
        for (final workspace
            in (json['workspaceFiles'] as Map).cast<String, dynamic>().entries)
          if (workspace.value is Map)
            workspace.key.toString(): {
              for (final file in (workspace.value as Map).entries)
                if (SyncAgreedFile.tryParse(file.value)
                    case final SyncAgreedFile agreed)
                  file.key.toString(): agreed,
            },
    },
    unappliedConversations: [
      for (final id in (json['unapplied'] as List? ?? const [])) id.toString(),
    ],
    unappliedBusiness: json['unappliedBusiness'] == true,
    peerEpoch: (json['peerEpoch'] as num?)?.toInt() ?? 0,
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
  /// conversation (ADR-0003: apply yields to generation). The checkpoint entry
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

  /// True when the apply repaired a message order that disagreed with the order
  /// the re-derivation produced — a conversation an earlier build left shifted,
  /// or one whose rows arrived out of order.
  ///
  /// It rides beside the counters instead of inside them because no row's
  /// *content* changed: every other field here reports nothing while the
  /// timeline the user is reading is not the one the database now holds. Without
  /// this flag such an apply reloads nothing, and a window open on the
  /// conversation keeps rendering the pre-sync order until the user leaves and
  /// comes back.
  final bool reordered;

  /// The revisions this apply actually wrote (the incoming rows that survived
  /// the merge). Asset registration keys off this set: a revision that never
  /// landed here (a deferred conversation, a resolved version-group loser)
  /// would dangle against the revision foreign key, and the wire parts of a
  /// row the local copy beat describe references this device does not hold.
  final Set<String> appliedRevisionIds;

  const SyncSubtreeApplyOutcome({
    this.deferred = false,
    this.conversationRow,
    this.messageRows = const [],
    this.upsertedMessages = 0,
    this.deletedMessages = 0,
    this.conversationRowChanged = false,
    this.reordered = false,
    this.appliedRevisionIds = const {},
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

  /// Business rows the incoming payload replaced: a local row existed, the
  /// peer's row won the LWW comparison, and the content actually differed, so
  /// the local version is gone (slice 5). Counted, not named — the report shows
  /// the number, logs hold the ids. A winning row that carried the same content
  /// back (a bothSend echo) is not a loss and is not counted.
  final int entityRowsLost;
  final int preferencesLost;

  const SyncBusinessApplyOutcome({
    this.deferred = false,
    this.entityRowsWritten = 0,
    this.entityRowsDeleted = 0,
    this.preferencesWritten = 0,
    this.preferencesDeleted = 0,
    this.changed = false,
    this.entityRowsLost = 0,
    this.preferencesLost = 0,
  });

  static const deferredOutcome = SyncBusinessApplyOutcome(deferred: true);

  static const nothing = SyncBusinessApplyOutcome();
}
