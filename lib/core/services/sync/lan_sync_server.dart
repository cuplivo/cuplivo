import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_service.dart';
import '../backup/data_sync.dart';
import '../../models/backup.dart';
import '../../models/conversation.dart';
import '../../models/incremental_backup.dart';
import 'lan_sync_logic.dart';
import 'lan_sync_models.dart';

/// Callback for delivering the received zip file to the UI for restore + restart.
typedef SyncServerZipReceivedCallback = Future<void> Function(File zipFile);

/// Keeps unique non-loopback IPv4 address strings (e.g. from
/// `NetworkInterface.list`), preserving order.
List<String> filterLanIps(Iterable<String> addresses) {
  final seen = <String>{};
  return [
    for (final address in addresses)
      if (!address.startsWith('127.') && seen.add(address)) address,
  ];
}

/// HTTP server for LAN sync. Single-use lifecycle.
///
/// Protocol (two round trips):
/// 1. POST /sync/plan  → initiator sends SyncIndex, server returns SyncPlan.
/// 2. POST /sync/exchange → initiator sends its incremental zip, server
///    responds with its own incremental zip. Both sides then apply + restart.
class LanSyncServer extends ChangeNotifier {
  final ChatService _chatService;
  final DataSync _dataSync;

  HttpServer? _server;
  String? _pin;

  /// The port requested at [start]. Null when not running.
  int? _preferredPort;

  /// All non-loopback IPv4 addresses of this device (LAN candidates).
  List<String> _addresses = const [];
  List<String> get addresses => _addresses;

  int? _port;

  /// Whether the server is listening.
  bool _running = false;
  bool get running => _running;

  /// The 4-digit PIN for this session. Null when not running.
  String? get pin => _pin;

  int? get port => _port;

  /// Whether the bound port is the one requested at [start] (true) or a
  /// random fallback because the preferred port was busy (false).
  bool get usedPreferredPort =>
      _running && _port != null && _port == _preferredPort;

  /// Current protocol phase for UI display.
  LanSyncPhase _phase = LanSyncPhase.idle;
  LanSyncPhase get phase => _phase;

  /// Restore progress snapshot, non-null only while this device is
  /// merge-restoring a received zip (the mask content in the UI).
  RestoreProgress? _restoreProgress;
  RestoreProgress? get restoreProgress => _restoreProgress;

  /// Non-null when a received-zip restore failed; the UI shows the failed
  /// state (with a close action) instead of the progress mask.
  String? _restoreError;
  String? get restoreError => _restoreError;

  /// Called when the initiator's zip arrives and has been saved to disk.
  /// The UI is responsible for merge-restoring and restarting.
  SyncServerZipReceivedCallback? onZipReceived;

  /// The received zip file path, for the UI to restore after sending the
  /// response back.
  File? _receivedZip;
  File? get receivedZip => _receivedZip;

  // -------------------------------------------------------------------------
  // Retained plan state for the round-2 zip build (single-use lifecycle).
  // Populated by `_computePlan` in round 1, consumed by `_handleExchange`.
  // This assumes ONE initiator per server instance: a second device running
  // `/sync/plan` between the first device's round 1 and round 2 would
  // overwrite these fields, and the first device's exchange would then build
  // the second device's delta. The server dialog is modal (one sync session
  // per launch) so this is unreachable in practice.
  // -------------------------------------------------------------------------

  /// The global `since` (earliest fork-point timestamp). Null when all
  /// conversations are identical — in which case a file delta may still drive
  /// the exchange.
  DateTime? _exchangeSince;

  /// Per-conversation fork-point timestamps for the chat export. Presence of a
  /// key = the conversation has a delta; null value = one-sided (whole
  /// conversation). Null when the initiator is an old peer (no manifest) —
  /// the zip then falls back to the single global `since`.
  Map<String, DateTime?>? _exchangeConversationSince;

  /// The server's outbound file delta (zip-entry paths to pack). Null when the
  /// initiator is an old peer → `since`-based file packing.
  Set<String>? _serverOutboundDelta;

  /// The initiator's chosen conflict direction for this session (issue #615).
  /// Read from the plan request; null = auto / old peer.
  SyncPriority? _initiatorPriority;
  SyncPriority? get initiatorPriority => _initiatorPriority;

  LanSyncServer({required this._chatService, required this._dataSync});

  /// Starts the HTTP server. Throws on failure.
  Future<void> start({int preferredPort = 9527}) async {
    if (_running) throw Exception('Server already running');

    _pin = _generatePin();
    _preferredPort = preferredPort;

    // Bind to all interfaces (0.0.0.0) so LAN peers can connect.
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      // Port in use → fallback to random port.
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    _port = server.port;
    // May be empty when the machine has no non-loopback IPv4 — the UI
    // shows a dedicated empty state instead of a bogus connect address.
    _addresses = await _getLocalIps();
    _running = true;
    _phase = LanSyncPhase.waiting;
    notifyListeners();

    _handleRequests(server);
  }

  /// Stops the server and cleans up.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _running = false;
    _pin = null;
    _addresses = const [];
    _port = null;
    _phase = LanSyncPhase.idle;
    _receivedZip = null;
    _restoreProgress = null;
    _restoreError = null;
    _initiatorPriority = null;
    notifyListeners();
  }

  /// Sets the restore progress snapshot for the mask UI. Passing null clears
  /// it (and any error). Notifies listeners so the dialog rebuilds.
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

  Future<void> _handleRequests(HttpServer server) async {
    await for (final request in server) {
      try {
        final peer = request.connectionInfo?.remoteAddress.address;
        debugPrint(
          'LanSyncServer ${request.method} ${request.uri.path} from $peer',
        );
        final path = request.uri.path;
        // PIN validation on every request.
        if (!validatePin(request.headers.value('X-Sync-Pin'))) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..write('Invalid PIN');
          await request.response.close();
          continue;
        }

        if (path == '/sync/plan' && request.method == 'POST') {
          await _handlePlan(request);
        } else if (path == '/sync/exchange' && request.method == 'POST') {
          await _handleExchange(request);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not found');
          await request.response.close();
        }
      } catch (e) {
        debugPrint('LanSyncServer request error: $e');
        try {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('Server error: $e');
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  /// Round 1: Receive the initiator's index, compute sync plan, return it.
  Future<void> _handlePlan(HttpRequest request) async {
    final body = await _readBody(request);
    final index = SyncIndex.fromJsonString(body);

    _initiatorPriority = index.syncPriority;

    // Build the server's own index.
    final myConversations = _chatService.getAllCompleteConversations();
    final myAssistantIds = (await _chatService.getAllAssistants())
        .map((a) => a.id)
        .toList();

    final plan = await _computePlan(
      initiatorIndex: index,
      myConversations: myConversations,
      myAssistantIds: myAssistantIds,
    );

    _phase = LanSyncPhase.planSent;
    notifyListeners();

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(plan.toJsonString());
    await request.response.close();
  }

  /// Round 2: Receive the initiator's zip, save it, then build and return
  /// the server's own zip.
  Future<void> _handleExchange(HttpRequest request) async {
    final contentType = request.headers.contentType;
    if (contentType == null ||
        contentType.mimeType != 'multipart/form-data' ||
        contentType.parameters['boundary'] == null) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Expected multipart/form-data');
      await request.response.close();
      return;
    }

    final boundary = contentType.parameters['boundary']!;
    final parts = await _parseMultipart(request, boundary);
    final zipPart = parts['zip'];

    // zipPart may be null when the initiator has no increments to send
    // (all conversations are identical or server-only). This is not an
    // error — proceed without a received zip.
    File? receivedFile;
    if (zipPart != null) {
      // Save the received zip to a temp file.
      final tmpDir = await _getTempDir();
      final receivedPath = p.join(
        tmpDir.path,
        'lan_sync_received_'
        '${DateTime.now().microsecondsSinceEpoch}_'
        '${Random().nextInt(0xFFFFFF).toRadixString(16)}.zip',
      );
      receivedFile = File(receivedPath);
      await receivedFile.writeAsBytes(zipPart);
    }

    _phase = LanSyncPhase.exchanging;
    notifyListeners();

    // Determine the `since` for building our zip.
    // Re-parse the plan from the request body if available, otherwise
    // we need the initiator to send the plan's `since` along with the zip.
    final planSinceStr = parts['since'];
    DateTime? since;
    if (planSinceStr != null) {
      try {
        since = DateTime.parse(utf8.decode(planSinceStr));
      } catch (e) {
        debugPrint('Failed to parse since: $e');
      }
    }

    // Build the server's incremental zip.
    // Modern peer (manifest present): exact per-file delta + per-conversation
    // chat window from the retained plan. Old peer: legacy single-`since`
    // mtime/chat filter. No zip at all when there is nothing to send —
    // EXCEPT a non-auto sync priority session (the initiator accepted a
    // conflict direction): the CONFIRMED session ships settings/assistants
    // on BOTH sides, so the chosen direction actually reaches the merge
    // (issue #615 P1). Our own delta carries settings; no delta of ours
    // still builds a settings-only payload. Whether the INITIATOR has a
    // delta is never a reason to suppress our side.
    final cfg = const WebDavConfig();
    File? myZip;
    final outboundDelta = _serverOutboundDelta;
    // THIS side's delta only (server chat window / server file delta).
    final hasChatOrFileDelta =
        _exchangeSince != null ||
        (outboundDelta != null && outboundDelta.isNotEmpty);
    final forceSettingsExchange =
        !hasChatOrFileDelta && _initiatorPriority != null;
    if (hasChatOrFileDelta || forceSettingsExchange) {
      final incremental = forceSettingsExchange
          ? IncrementalBackupConfig(
              since: DateTime(2000),
              // Settings (and assistants — they ride the chats bit) are the
              // whole payload; no chats (empty per-conversation window) and
              // no file trees have anything to send in this session.
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
              since: _exchangeSince ?? since ?? DateTime(2000),
              // Settings (including assistants and providers) ride
              // settings.json; merge restore unions them on the receiving
              // side (issue #476).
              includeSettings: true,
              includeFiles: true,
              updateBackupTime: false,
              conversationSince: _exchangeConversationSince,
              includeFilePaths: outboundDelta,
            );
      myZip = await _dataSync.exportToFile(cfg, incremental: incremental);
    }

    _receivedZip = receivedFile;
    _phase = LanSyncPhase.done;
    notifyListeners();

    // Send our zip as the response.
    if (myZip != null && await myZip.exists()) {
      final zipBytes = await myZip.readAsBytes();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set('Content-Type', 'application/zip')
        ..add(zipBytes);
      await request.response.close();
      // Clean up our zip temp file.
      try {
        await myZip.delete();
      } catch (_) {}
    } else {
      // No increment to send — respond with empty body.
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{"empty":true}');
      await request.response.close();
    }

    // Notify the UI that a zip was received and should be restored.
    // Only restore if we actually received a zip from the initiator.
    if (receivedFile != null && onZipReceived != null) {
      await onZipReceived!(receivedFile);
    }
  }

  /// Computes the sync plan by comparing the initiator's index with our data.
  ///
  /// Also retains the round-2 zip inputs on this single-use instance:
  /// [_exchangeSince], [_exchangeConversationSince] (per-conversation chat
  /// windows) and [_serverOutboundDelta] (exact file delta for modern peers).
  Future<SyncPlan> _computePlan({
    required SyncIndex initiatorIndex,
    required List<Conversation> myConversations,
    required List<String> myAssistantIds,
  }) async {
    final plans = <SyncConvPlan>[];

    final myConvsById = <String, Conversation>{};
    for (final c in myConversations) {
      myConvsById[c.id] = c;
    }

    // Check conversations that the initiator has.
    for (final entry in initiatorIndex.conversations.entries) {
      final convId = entry.key;
      final theirMsgIds = entry.value;
      final myConv = myConvsById[convId];

      if (myConv == null) {
        // Conversation doesn't exist on our side — initiator-only.
        plans.add(
          SyncConvPlan(
            conversationId: convId,
            conversationTitle: null,
            state: SyncConvState.initiatorOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: theirMsgIds.length,
            serverIncrementCount: 0,
          ),
        );
        continue;
      }

      // Get our message IDs for this conversation.
      final myMsgIds = _chatService.repo.getMessageIdsSync(convId);
      plans.add(
        computeConvPlan(
          ConvPlanInput(
            conversationId: convId,
            conversationTitle: myConv.title,
            initiatorMsgIds: theirMsgIds,
            serverMsgIds: myMsgIds,
          ),
        ),
      );
    }

    // Check conversations that only we have (server-only, no fork point).
    for (final c in myConversations) {
      final convId = c.id;
      if (!initiatorIndex.conversations.containsKey(convId)) {
        final myMsgIds = _chatService.repo.getMessageIdsSync(convId);
        plans.add(
          SyncConvPlan(
            conversationId: convId,
            conversationTitle: c.title,
            state: SyncConvState.serverOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: 0,
            serverIncrementCount: myMsgIds.length,
          ),
        );
      }
    }

    // Resolve each conversation's fork-point timestamp once (cached), then
    // derive the global `since` and the per-conversation chat windows. The
    // timestamp lookup accesses our local DB for fork-point messages.
    final forkTsCache = <String, DateTime?>{};
    DateTime? resolveFork(String convId, String forkId) =>
        forkTsCache.putIfAbsent(
          convId,
          () => _chatService.repo.getMessageSync(forkId)?.timestamp,
        );
    final since = computeEarliestSince(plans, resolveFork);

    // Attach each conversation's own since for the per-conversation chat
    // export (null = one-sided conversation, exported in full; identical
    // conversations are skipped by the transport).
    final conversationSince = <String, DateTime?>{};
    final plansWithSince = <SyncConvPlan>[];
    for (final plan in plans) {
      final forkId = plan.forkPointMessageId;
      final convSince = plan.state == SyncConvState.identical || forkId == null
          ? null
          : forkTsCache[plan.conversationId];
      if (plan.state != SyncConvState.identical) {
        conversationSince[plan.conversationId] = convSince;
      }
      plansWithSince.add(
        SyncConvPlan(
          conversationId: plan.conversationId,
          conversationTitle: plan.conversationTitle,
          state: plan.state,
          forkPointMessageId: plan.forkPointMessageId,
          initiatorIncrementCount: plan.initiatorIncrementCount,
          serverIncrementCount: plan.serverIncrementCount,
          since: convSince,
        ),
      );
    }

    // What the server would pack in round 2. Modern peer (manifest present):
    // exact per-file delta against the initiator's manifest (one stat walk).
    // Old peer: legacy `since`-based stat preview. Mirrors `_packZipSync`
    // rules so the preview never drifts from the actual zip payload.
    final peerManifest = initiatorIndex.fileManifest;
    Map<String, FileManifestEntry>? localManifest;
    Set<String>? outboundDelta;
    int? serverFileCount;
    int? serverFileSizeBytes;
    if (peerManifest != null) {
      localManifest = await _dataSync.buildFileManifest();
      outboundDelta = computeFileDelta(localManifest, peerManifest);
      serverFileCount = outboundDelta.length;
      serverFileSizeBytes = sumDeltaBytes(localManifest, outboundDelta);
    } else if (since != null) {
      final fileStats = await _dataSync.countFilesForSince(since);
      serverFileCount = fileStats.fileCount;
      serverFileSizeBytes = fileStats.totalBytes;
    }

    // Retain the round-2 zip inputs. Old-peer fallback: no per-conversation
    // window and no file delta → the exchange rebuilds the legacy single-since
    // zip.
    _exchangeSince = since;
    _exchangeConversationSince = peerManifest != null
        ? conversationSince
        : null;
    _serverOutboundDelta = peerManifest != null ? outboundDelta : null;

    // Assistant set differences.
    final theirSet = initiatorIndex.assistantIds.toSet();
    final mySet = myAssistantIds.toSet();
    final missingOnServer = theirSet.difference(mySet).toList();
    final missingOnInitiator = mySet.difference(theirSet).toList();

    return SyncPlan(
      conversations: plansWithSince,
      missingAssistantIds: missingOnServer,
      remoteMissingAssistantIds: missingOnInitiator,
      since: since,
      serverFileCount: serverFileCount,
      serverFileSizeBytes: serverFileSizeBytes,
      serverFileManifest: peerManifest != null ? localManifest : null,
      // Echo the accepted direction (issue #615 mixed-version symmetry):
      // the initiator only applies its choice when the server echoes an
      // identical non-null value — an old server (or an unknown value that
      // degraded to auto) echoes null and both sides fall back to auto.
      syncPriority: initiatorIndex.syncPriority,
    );
  }

  bool validatePin(String? provided) {
    if (_pin == null) return false;
    return provided == _pin;
  }

  static String _generatePin() {
    final rng = DateTime.now().microsecondsSinceEpoch;
    final code = rng % 10000;
    return code.toString().padLeft(4, '0');
  }

  /// All unique non-loopback IPv4 addresses, in interface order.
  static Future<List<String>> _getLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return filterLanIps([
        for (final iface in interfaces)
          for (final addr in iface.addresses) addr.address,
      ]);
    } catch (e) {
      debugPrint('Failed to get local IPs: $e');
    }
    return const [];
  }

  Future<Directory> _getTempDir() async {
    final tmp = Directory.systemTemp;
    final dir = Directory(p.join(tmp.path, 'cuplivo_lan_sync'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _readBody(HttpRequest request) async {
    final completer = Completer<String>();
    final buffer = <int>[];
    await for (final chunk in request) {
      buffer.addAll(chunk);
    }
    completer.complete(utf8.decode(buffer));
    return completer.future;
  }

  Future<Map<String, List<int>>> _parseMultipart(
    HttpRequest request,
    String boundary,
  ) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    return parseMultipartBytes(bytes, boundary);
  }
}
