import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_service.dart';
import '../backup/data_sync.dart';
import '../../models/backup.dart';
import '../../models/incremental_backup.dart';
import 'lan_sync_logic.dart';
import 'lan_sync_models.dart';

/// Callback for delivering the received zip file to the UI for restore + restart.
typedef SyncClientZipReceivedCallback = Future<void> Function(File zipFile);

/// LAN sync targets are always LAN IPs typed by the user — never route
/// through the environment proxy. dart:io's [HttpClient] defaults to
/// [HttpClient.findProxyFromEnvironment], which silently hijacks LAN
/// requests when `HTTP_PROXY`/`http_proxy` is set (and `NO_PROXY` cannot
/// express plain-IP exclusions reliably). Always DIRECT.
String lanSyncFindProxy(Uri url) => 'DIRECT';

/// Builds the [http.Client] used by [LanSyncClient]: a dart:io [HttpClient]
/// forced to direct connections (see [lanSyncFindProxy]).
http.Client buildLanSyncHttpClient() {
  return IOClient(HttpClient()..findProxy = lanSyncFindProxy);
}

/// Client-side logic for the LAN sync initiator (device A).
///
/// Protocol (two round trips):
/// 1. POST /sync/plan  → send our index, receive sync plan.
/// 2. POST /sync/exchange → send our incremental zip, receive server's zip.
/// Both sides then apply + restart independently.
class LanSyncClient extends ChangeNotifier {
  final ChatService _chatService;
  final DataSync _dataSync;
  final http.Client _http;
  final bool _ownsHttpClient;

  /// Current protocol phase for UI display.
  LanSyncPhase _phase = LanSyncPhase.idle;
  LanSyncPhase get phase => _phase;

  /// The last computed sync plan (null until round 1 completes).
  SyncPlan? _plan;
  SyncPlan? get plan => _plan;

  /// Outbound file payload for the current plan (mirrors `_packZipSync`),
  /// computed from the plan's `since`. Null until [negotiate] completes or
  /// when `since` is null (nothing will be packed).
  int? _outboundFileCount;
  int? _outboundFileSizeBytes;
  int? get outboundFileCount => _outboundFileCount;
  int? get outboundFileSizeBytes => _outboundFileSizeBytes;

  /// The exact zip-entry paths this device must pack in round 2 (modern-peer
  /// file delta). Null for old peers / when nothing differs — the zip then
  /// falls back to the `since`-based filter (or is skipped entirely).
  Set<String>? _outboundDelta;

  /// This device's file manifest, built once in [_buildIndex] and reused for
  /// the round-2 delta computation so the tree is only walked once per sync.
  Map<String, FileManifestEntry>? _localManifest;

  /// Restore progress snapshot, non-null only while this device is
  /// merge-restoring a received zip (the mask content in the UI).
  RestoreProgress? _restoreProgress;
  RestoreProgress? get restoreProgress => _restoreProgress;

  /// Non-null when a received-zip restore failed; the UI shows the failed
  /// state (with a close action) instead of the progress mask.
  String? _restoreError;
  String? get restoreError => _restoreError;

  /// Whether a sync operation is in progress.
  bool _busy = false;
  bool get busy => _busy;

  /// The conflict direction chosen for THIS session by the initiator.
  /// Null = auto. Reset by [reset].
  SyncPriority? _chosenPriority;
  SyncPriority? get chosenPriority => _chosenPriority;

  /// Whether the server echoed an identical, non-null [SyncPriority] in the
  /// plan (issue #615 mixed-version symmetry). Only then does this device
  /// apply the chosen direction; otherwise both sides fall back to auto.
  bool _priorityConfirmed = false;

  /// The direction this device should apply: the chosen priority when the
  /// server confirmed it, otherwise null (auto).
  SyncPriority? get effectivePriority =>
      _priorityConfirmed ? _chosenPriority : null;

  /// Whether a non-auto session must force a settings-only exchange (issue
  /// #615): no chat delta, no file delta, but a CONFIRMED conflict direction
  /// was chosen — identical message IDs with different system
  /// prompts/settings would otherwise produce NO zip and the chosen
  /// direction would never reach the merge. Unconfirmed choices (old peers)
  /// never force anything: mixed-version sessions keep today's semantics.
  bool get forceSettingsExchange {
    final plan = _plan;
    if (plan == null) return false;
    if (effectivePriority == null) return false;
    if (plan.since != null) return false;
    if ((_outboundDelta?.isNotEmpty ?? false)) return false;
    if ((plan.serverFileCount ?? 0) > 0) return false;
    return true;
  }

  /// Called when the server's zip arrives and has been saved to disk.
  SyncClientZipReceivedCallback? onZipReceived;

  LanSyncClient({
    required this._chatService,
    required this._dataSync,
    http.Client? httpClient,
  }) : _http = httpClient ?? buildLanSyncHttpClient(),
       _ownsHttpClient = httpClient == null;

  /// Releases the internally-created HTTP client. Never closes an injected
  /// one (the caller owns it).
  void close() {
    if (_ownsHttpClient) {
      _http.close();
    }
  }

  /// Builds an HTTP URI, wrapping IPv6 hosts in brackets as required by RFC 3986.
  static String _buildUri(String host, int port, String path) {
    final wrappedHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return 'http://$wrappedHost:$port$path';
  }

  /// Round 1: Connect to the server, send our index, get back the sync plan.
  ///
  /// Returns the plan for the UI to display. The user confirms before
  /// proceeding to [exchange]. [syncPriority] is this device's chosen
  /// conflict direction (issue #615); null = auto (current behavior), and old
  /// peers ignore the field entirely.
  Future<SyncPlan> negotiate({
    required String host,
    required int port,
    required String pin,
    SyncPriority? syncPriority,
  }) async {
    _busy = true;
    _chosenPriority = syncPriority;
    _phase = LanSyncPhase.waiting;
    notifyListeners();

    try {
      final index = await _buildIndex();

      final uri = Uri.parse(_buildUri(host, port, '/sync/plan'));
      final response = await _http
          .post(
            uri,
            headers: {'Content-Type': 'application/json', 'X-Sync-Pin': pin},
            body: index.toJsonString(),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 401) {
        throw Exception('Invalid PIN');
      }
      if (response.statusCode != 200) {
        throw Exception(
          'Plan request failed: ${response.statusCode} ${response.body}',
        );
      }

      final plan = SyncPlan.fromJsonString(response.body);
      _plan = plan;
      // Mixed-version gate (issue #615): apply the chosen direction only
      // when the server echoed an identical value. Old servers (and unknown
      // modes that degraded to auto server-side) echo null → this device
      // falls back to auto too, keeping both sides symmetric.
      final chosen = _chosenPriority;
      _priorityConfirmed = chosen != null && plan.syncPriority == chosen;
      if (chosen != null && !_priorityConfirmed) {
        debugPrint(
          'lan sync: server did not confirm syncPriority "${chosen.name}" '
          '(unknown, old peer or degraded) — using auto',
        );
      }
      // Compute our own outbound file payload so the plan preview can show
      // "will send N files". Modern peer: exact per-file delta against the
      // server's manifest. Old peer: stat-only `since`-based count.
      if (plan.serverFileManifest != null) {
        final localManifest =
            _localManifest ?? await _dataSync.buildFileManifest();
        final delta = computeFileDelta(localManifest, plan.serverFileManifest!);
        _outboundDelta = delta;
        _outboundFileCount = delta.length;
        _outboundFileSizeBytes = sumDeltaBytes(localManifest, delta);
      } else if (plan.since != null) {
        final outboundStats = await _dataSync.countFilesForSince(plan.since!);
        _outboundFileCount = outboundStats.fileCount;
        _outboundFileSizeBytes = outboundStats.totalBytes;
        _outboundDelta = null;
      } else {
        _outboundDelta = null;
        _outboundFileCount = null;
        _outboundFileSizeBytes = null;
      }
      _phase = LanSyncPhase.planReceived;
      notifyListeners();
      return plan;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Round 2: Build our incremental zip, send it, receive the server's zip.
  /// Both sides then apply independently.
  Future<void> exchange({
    required String host,
    required int port,
    required String pin,
  }) async {
    final plan = _plan;
    if (plan == null) {
      throw Exception('No sync plan available. Run negotiate first.');
    }

    _busy = true;
    _phase = LanSyncPhase.exchanging;
    notifyListeners();

    try {
      // Build our incremental zip. Triggered by a conversation delta
      // (`plan.since`), OUR OWN outbound file delta (modern peer), or a
      // forced settings-only exchange when the user picked a non-auto
      // conflict direction and nothing else has a delta (issue #615 P1:
      // system-prompt/settings-only conflicts would otherwise never
      // exchange any payload). A server-only delta still requires the
      // exchange (to receive the server's zip) but must not ship our
      // settings for nothing.
      File? myZip;
      final hasConversationDelta = plan.since != null;
      final outboundDelta = _outboundDelta;
      final hasFileDelta = outboundDelta?.isNotEmpty ?? false;
      final forceSettings = forceSettingsExchange;
      if (hasConversationDelta || hasFileDelta || forceSettings) {
        // cfg content is irrelevant whenever a contentScope is present
        // (incremental.effectiveScope wins); the legacy mapped scope is
        // the pre-#595 behavior (chats+settings+files, skills always).
        final cfg = const WebDavConfig();
        final incremental = forceSettings
            ? IncrementalBackupConfig(
                since: DateTime(2000),
                // Settings/assistants-only payload: chats are excluded via an
                // empty per-conversation window, file trees are off.
                includeSettings: true,
                includeFiles: false,
                updateBackupTime: false,
                contentScope: const BackupContentScope(
                  chatsAndAssistants: true,
                  settings: true,
                  attachments: false,
                  workspaces: false,
                  skills: false,
                  fontsAndAvatars: false,
                ),
                conversationSince: const {},
                includeFilePaths: null,
              )
            : IncrementalBackupConfig(
                since: plan.since ?? DateTime(2000),
                // Settings (including assistants and providers) ride
                // settings.json. Merge restore fills absent slots + unions
                // mergeable lists, so both peers converge on the union of
                // their configuration.
                includeSettings: true,
                includeFiles: true,
                updateBackupTime: false,
                conversationSince: _buildConversationSince(plan),
                includeFilePaths: outboundDelta,
              );
        myZip = await _dataSync.exportToFile(cfg, incremental: incremental);
      }

      final uri = Uri.parse(_buildUri(host, port, '/sync/exchange'));
      final request = http.MultipartRequest('POST', uri)
        ..headers['X-Sync-Pin'] = pin;

      if (myZip != null && await myZip.exists()) {
        request.files.add(await http.MultipartFile.fromPath('zip', myZip.path));
      }
      if (plan.since != null) {
        request.fields['since'] = plan.since!.toIso8601String();
      }

      final streamedResponse = await _http
          .send(request)
          .timeout(const Duration(minutes: 10));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 401) {
        throw Exception('Invalid PIN');
      }
      if (response.statusCode != 200) {
        throw Exception(
          'Exchange failed: ${response.statusCode} ${response.body}',
        );
      }

      // Check if the response is an empty marker.
      final contentType = response.headers['content-type'] ?? '';
      if (contentType.contains('application/json') &&
          response.body.contains('"empty"')) {
        _phase = LanSyncPhase.noData;
        notifyListeners();
      } else {
        // Save the server's zip to a temp file.
        final tmpDir = await _getTempDir();
        final receivedPath = p.join(
          tmpDir.path,
          'lan_sync_received_${DateTime.now().millisecondsSinceEpoch}.zip',
        );
        final receivedFile = File(receivedPath);
        await receivedFile.writeAsBytes(response.bodyBytes);

        _phase = LanSyncPhase.done;
        notifyListeners();

        // Notify the UI to restore.
        if (onZipReceived != null) {
          await onZipReceived!(receivedFile);
        }
      }

      // Clean up our zip temp file.
      if (myZip != null) {
        try {
          await myZip.delete();
        } catch (_) {}
      }
    } on Object {
      // Back to the confirm state so the UI shows the plan again and the
      // user can retry. Not applied when the error came from the restore
      // flow (phase was already `done` — the sheet was popped there).
      if (_phase == LanSyncPhase.exchanging) {
        _phase = LanSyncPhase.planReceived;
        notifyListeners();
      }
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Builds our SyncIndex from the current data.
  Future<SyncIndex> _buildIndex() async {
    final conversations = _chatService.getAllCompleteConversations();
    final convMap = <String, List<String>>{};
    for (final conv in conversations) {
      convMap[conv.id] = _chatService.repo.getMessageIdsSync(conv.id);
    }
    final assistantIds = (await _chatService.getAllAssistants())
        .map((a) => a.id)
        .toList();
    final manifest = await _dataSync.buildFileManifest();
    _localManifest = manifest;
    return SyncIndex(
      conversations: convMap,
      assistantIds: assistantIds,
      fileManifest: manifest,
      syncPriority: _chosenPriority,
    );
  }

  /// Per-conversation chat export windows derived from the plan: every
  /// non-identical conversation is exported, scoped to its own fork-point
  /// timestamp (null = one-sided → whole transcript); identical conversations
  /// are absent → skipped by the transport.
  ///
  /// Returns null against an old peer (no `serverFileManifest` in the plan,
  /// hence no per-conversation `since` either) so the zip falls back to the
  /// single global `since` — exactly the pre-delta chat filtering. Exporting
  /// full transcripts there would only bloat the payload, not break anything.
  static Map<String, DateTime?>? _buildConversationSince(SyncPlan plan) {
    if (plan.serverFileManifest == null) return null;
    final sinceByConv = <String, DateTime?>{};
    for (final convPlan in plan.conversations) {
      if (convPlan.state == SyncConvState.identical) continue;
      sinceByConv[convPlan.conversationId] = convPlan.since;
    }
    return sinceByConv;
  }

  Future<Directory> _getTempDir() async {
    final tmp = Directory.systemTemp;
    final dir = Directory(p.join(tmp.path, 'cuplivo_lan_sync'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Resets the client state for a new sync session.
  void reset() {
    _plan = null;
    _outboundFileCount = null;
    _outboundFileSizeBytes = null;
    _outboundDelta = null;
    _localManifest = null;
    _chosenPriority = null;
    _priorityConfirmed = false;
    _restoreProgress = null;
    _restoreError = null;
    _phase = LanSyncPhase.idle;
    _busy = false;
    notifyListeners();
  }

  /// Sets the restore progress snapshot for the mask UI. Passing null clears
  /// it (and any error). Notifies listeners so the dialog/sheet rebuilds.
  void setRestoreProgress(RestoreProgress? progress) {
    _restoreProgress = progress;
    if (progress == null) _restoreError = null;
    notifyListeners();
  }

  /// Marks the received-zip restore as failed with [message]. The UI shows
  /// the failed state (close action) instead of the progress mask.
  void setRestoreError(String message) {
    _restoreError = message;
    _restoreProgress = null;
    notifyListeners();
  }
}
