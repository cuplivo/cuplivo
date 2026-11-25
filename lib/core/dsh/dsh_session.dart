/// One followed session: the `session/follow` stream, prompt/cancel, approval
/// and question answers, history paging, and the pure-Dart state store the
/// Flutter layer binds to.
///
/// The stream is **snapshot-first and not resumable**: every generation opens a
/// fresh snapshot and continues with contiguous committed events. Gaps (a live
/// event jumping ahead of the last seen `seq`) are filled with `session/page`
/// before the live event is forwarded, so the transcript never observes a hole.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'dsh_errors.dart';
import 'dsh_events.dart';
import 'dsh_models.dart';
import 'dsh_mux.dart';
import 'dsh_projection.dart';
import 'dsh_rpc.dart';
import 'dsh_terminal.dart';
import 'dsh_transport.dart';

class DshSessionOptions {
  const DshSessionOptions({
    this.maxMessages = 100,
    this.turnWindowMinMessages = 100,
    this.turnWindowMinTurns = 10,
    this.historyPageMessages = 60,
    this.snapshotTimeout = const Duration(seconds: 20),
    this.promptTimeout = const Duration(seconds: 30),
    this.assistantStream = true,
  });

  /// Durable events requested in the opening snapshot.
  final int maxMessages;
  final int turnWindowMinMessages;
  final int turnWindowMinTurns;

  /// Messages per older-history page.
  final int historyPageMessages;
  final Duration snapshotTimeout;
  final Duration promptTimeout;

  /// Request transient assistant frames for the running step.
  final bool assistantStream;

  Map<String, Object?> followRequest(
    String sessionId, {
    required bool activate,
  }) => {
    'address': {'kind': 'session', 'sessionId': sessionId},
    if (activate) 'activate': true,
    if (assistantStream) 'assistantStream': true,
    'maxMessages': maxMessages,
    'turnWindow': {
      'minMessages': turnWindowMinMessages,
      'minTurns': turnWindowMinTurns,
    },
  };
}

/// One inline image for `session/prompt` (`content[].data` is base64 there).
class DshImageInput {
  const DshImageInput({
    required this.bytes,
    required this.mediaType,
    this.name,
  });

  final Uint8List bytes;
  final String mediaType;
  final String? name;
}

/// One uploaded file reference (receipt id from `uploadFileBinary`).
class DshFileInput {
  const DshFileInput(this.receiptId);
  final String receiptId;
}

/// The content of one prompt. Text, images or files — at least one.
class DshPrompt {
  const DshPrompt({this.text, this.images = const [], this.files = const []});

  final String? text;
  final List<DshImageInput> images;
  final List<DshFileInput> files;

  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) && images.isEmpty && files.isEmpty;
}

class DshPromptReceipt {
  const DshPromptReceipt({required this.requestId, required this.accepted});

  /// Matches the stored user message's `source.rpcId`; reconcile optimistic
  /// rows by this id.
  final String requestId;

  /// `accepted:false` only when the Host did not admit the prompt at all.
  final bool accepted;
}

/// One page of older history, ascending `seq`.
class DshSessionHistoryPage {
  const DshSessionHistoryPage({required this.events, required this.hasMore});
  final List<DshSessionEvent> events;
  final bool hasMore;
}

/// A followed session.
class DshSession {
  DshSession({
    required this.sessionId,
    required this.mux,
    required this.rpc,
    required this.transport,
    this.options = const DshSessionOptions(),
  });

  /// Creates the session and waits for its first snapshot.
  static Future<DshSession> open({
    required DshMux mux,
    required DshRpc rpc,
    required DshTransport transport,
    required String sessionId,
    bool activate = false,
    DshSessionOptions options = const DshSessionOptions(),
  }) async {
    final session = DshSession(
      sessionId: sessionId,
      mux: mux,
      rpc: rpc,
      transport: transport,
      options: options,
    );
    await session.watch(activate: activate);
    return session;
  }

  final String sessionId;
  final DshMux mux;
  final DshRpc rpc;
  final DshTransport transport;
  final DshSessionOptions options;

  final StreamController<DshSessionUpdate> _updates =
      StreamController<DshSessionUpdate>.broadcast();
  DshStream? _stream;
  StreamSubscription<Object?>? _itemSub;
  StreamSubscription<DshConnectionState>? _stateSub;
  StreamSubscription<DshHostEvent>? _hostSub;
  Completer<void>? _firstSnapshot;
  Future<void> _queue = Future<void>.value();

  DshSessionSnapshot? _snapshot;
  int _lastSeq = -1;
  int? _oldestLoadedSeq;
  bool _hasMoreHistory = false;
  bool _watching = false;
  bool _disposed = false;
  final Set<String> _hostEventIds = {};

  /// Snapshot, durable events, live assistant frames, host requests and
  /// connection transitions. Broadcast; consumers replay from [snapshot].
  Stream<DshSessionUpdate> get updates => _updates.stream;

  /// Latest snapshot (a new generation replaces it wholesale).
  DshSessionSnapshot? get snapshot => _snapshot;

  DshSessionHeader? get header => _snapshot?.header;

  DshSessionProjections get projections =>
      _snapshot?.projections ?? DshSessionProjections.empty;

  /// Highest committed `seq` observed; -1 before the snapshot.
  int get lastEventSeq => _lastSeq;

  bool get hasMoreHistory => _hasMoreHistory;

  bool get isDisposed => _disposed;

  Future<void> get ready => _firstSnapshot?.future ?? watch(activate: false);

  Map<String, Object?> get _address => {
    'kind': 'session',
    'sessionId': sessionId,
  };

  /// Starts the follow stream (idempotent). Completes with the first snapshot.
  ///
  /// [activate] makes a cold session executable/writable; the chat page passes
  /// `true`, background list views leave it false.
  Future<void> watch({bool activate = false}) {
    if (_disposed) {
      throw const DshClosedException('This session view was closed');
    }
    if (_watching) {
      return _firstSnapshot?.future ?? Future<void>.value();
    }
    _watching = true;
    _firstSnapshot = Completer<void>();
    _stateSub = mux.states.listen((state) {
      _emit(DshSessionConnectionUpdate(state, mux.lastError));
      if (state == DshConnectionState.unauthorized &&
          !(_firstSnapshot?.isCompleted ?? true)) {
        _firstSnapshot?.completeError(
          mux.lastError ??
              const DshAuthException('The Host rejected this connection'),
        );
      }
    });
    _hostSub = mux.hostEvents.listen(_onHostEvent);
    _connectStream(activate);
    return _firstSnapshot!.future.timeout(
      options.snapshotTimeout,
      onTimeout: () => throw DshTransportException(
        'session/follow for $sessionId did not deliver a snapshot in time',
      ),
    );
  }

  Future<void> _connectStream(bool activate) async {
    try {
      final stream = await mux.open(
        'session/follow',
        args: {'request': options.followRequest(sessionId, activate: activate)},
        autoReopen: true,
      );
      if (_disposed) {
        await stream.cancel();
        return;
      }
      _stream = stream;
      _itemSub = stream.items.listen(
        _onItem,
        onError: _onStreamError,
        onDone: () => _onStreamLost(
          const DshTransportException('The Host ended the session stream'),
        ),
      );
    } on DshException catch (error, stack) {
      if (!_disposed) {
        _emitError(error, stack);
        final completer = _firstSnapshot;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(error);
        }
      }
    }
  }

  void _onStreamError(Object error) {
    final typed = error is DshException
        ? error
        : DshTransportException('The session stream failed', cause: error);
    _onStreamLost(typed);
  }

  void _onStreamLost(DshException error) {
    if (_disposed) return;
    // A lost generation voids this stream; the mux reopens it and the Host
    // sends a fresh snapshot (same stream object). Nothing to do but surface
    // the state; event handling continues on the reopened stream.
    _emit(DshSessionConnectionUpdate(DshConnectionState.reconnecting, error));
  }

  void _onItem(Object? item) {
    _queue = _queue.then((_) => _handleItem(item)).catchError((Object error) {
      if (!_disposed) {
        _emitError(
          error is DshException
              ? error
              : DshProtocolException('Failed to apply a session frame: $error'),
          StackTrace.current,
        );
      }
    });
  }

  Future<void> _handleItem(Object? item) async {
    if (_disposed) return;
    final map = jsonMap(item);
    switch (jsonString(map['type'])) {
      case 'snapshot':
        _applySnapshot(DshSessionSnapshot.fromJson(map));
      case 'event':
        await _applyEvent(DshSessionEvent.fromJson(map['event']));
      case 'assistant-stream':
        _emit(
          DshSessionAssistantFrameUpdate(
            DshAssistantStreamFrame.fromJson(map['frame']),
          ),
        );
      default:
        // Forward-compatible: ignore frame types this client does not know.
        break;
    }
  }

  void _applySnapshot(DshSessionSnapshot snapshot) {
    _snapshot = snapshot;
    _hasMoreHistory = snapshot.hasMore;
    _lastSeq = max(_lastSeq, snapshot.cursor);
    for (final event in snapshot.records) {
      _lastSeq = max(_lastSeq, event.seq);
    }
    _oldestLoadedSeq = snapshot.records.isEmpty
        ? null
        : snapshot.records.map((event) => event.seq).reduce(min);
    _emit(DshSessionSnapshotUpdate(snapshot));
    final completer = _firstSnapshot;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _applyEvent(DshSessionEvent event) async {
    if (event.seq <= _lastSeq) {
      // Duplicate delivery (snapshot overlap or reconnect redelivery).
      return;
    }
    if (_lastSeq >= 0 && event.seq > _lastSeq + 1) {
      await _fillGap(_lastSeq, event.seq);
    }
    _lastSeq = event.seq;
    _emit(DshSessionEventUpdate(event));
  }

  /// Fills `(_afterSeq, beforeSeq)` from the durable log before the live event
  /// is forwarded, so a consumer sees contiguous committed events.
  Future<void> _fillGap(int afterSeq, int beforeSeq) async {
    var cursor = beforeSeq;
    var pages = 0;
    final forwardable = <DshSessionEvent>[];
    while (pages < 20) {
      pages += 1;
      final page = await _loadPage(beforeSeq: cursor, throughSeq: null);
      final events =
          page.records
              .map(
                (record) => DshSessionEvent.fromJson(jsonMap(record)['event']),
              )
              .where((event) => event.seq > afterSeq && event.seq < beforeSeq)
              .toList()
            ..sort((a, b) => a.seq.compareTo(b.seq));
      if (events.isEmpty) break;
      forwardable.insertAll(0, events);
      cursor = events.first.seq;
      if (!page.hasMore) break;
      if (cursor <= afterSeq + 1) break;
    }
    for (final event in forwardable) {
      if (event.seq > _lastSeq) {
        _lastSeq = event.seq;
        _emit(DshSessionEventUpdate(event));
      }
    }
  }

  void _onHostEvent(DshHostEvent event) {
    if (_disposed) return;
    switch (event) {
      case final DshHostRequest request:
        if (request.sessionId != sessionId) return;
        _hostEventIds.add(request.eventId);
        _emit(DshSessionHostRequestUpdate(request));
      case DshHostRequestCancelled(:final eventId):
        if (!_hostEventIds.remove(eventId)) return;
        _emit(DshSessionHostRequestUpdate(event));
      default:
        return;
    }
  }

  void _emit(DshSessionUpdate update) {
    if (!_updates.isClosed) _updates.add(update);
  }

  void _emitError(DshException error, StackTrace stack) {
    if (!_updates.isClosed) _updates.addError(error, stack);
  }

  // ---------------------------------------------------------------------------
  // Turns

  /// Admits a prompt into the inbox. `mode:'steer'` injects into the running
  /// turn; the returned [DshPromptReceipt.requestId] matches the stored user
  /// message (`source.rpcId`).
  Future<DshPromptReceipt> prompt(
    DshPrompt prompt, {
    String? requestId,
    String mode = 'queue',
  }) async {
    if (prompt.isEmpty) {
      throw ArgumentError('A prompt needs text, an image or a file');
    }
    final content = <Map<String, Object?>>[];
    final text = prompt.text;
    if (text != null && text.trim().isNotEmpty) {
      content.add({'type': 'text', 'text': text});
    }
    for (final image in prompt.images) {
      content.add({
        'type': 'image',
        'mediaType': image.mediaType,
        if (image.name != null) 'name': image.name,
        'data': base64Encode(image.bytes),
      });
    }
    for (final file in prompt.files) {
      content.add({'type': 'file', 'receiptId': file.receiptId});
    }
    final id = requestId ?? dshUuidV4();
    final value = jsonMap(
      await rpc.call(
        'session/prompt',
        args: {
          'request': {
            'requestId': id,
            'sessionId': sessionId,
            'mode': mode,
            'clientTimeZone': 'UTC',
            'content': content,
          },
        },
        timeout: options.promptTimeout,
      ),
    );
    return DshPromptReceipt(
      requestId: id,
      accepted: value['accepted'] != false,
    );
  }

  /// Interrupts the running turn; wait for `turn/end` to observe the stop.
  Future<void> cancel() async {
    await rpc.call(
      'session/cancel',
      args: {
        'request': {'sessionId': sessionId},
      },
    );
  }

  /// Edits/removes/steers one queued inbox item (`session/updateQueue`).
  Future<void> updateQueue(
    String itemId, {
    required String action,
    DshPrompt? edit,
  }) async {
    final Map<String, Object?> wireAction = switch (action) {
      'remove' => {'kind': 'remove'},
      'steer' => {'kind': 'steer'},
      'edit' => {
        'kind': 'edit',
        'content': [
          if (edit?.text != null && edit!.text!.trim().isNotEmpty)
            {'type': 'text', 'text': edit.text},
        ],
      },
      _ => throw ArgumentError('Unknown queue action "$action"'),
    };
    await rpc.call(
      'session/updateQueue',
      args: {
        'request': {
          'sessionId': sessionId,
          'itemId': itemId,
          'action': wireAction,
        },
      },
    );
  }

  /// Answers one `approval/request` waterfall.
  ///
  /// [DshApprovalDecision.pass] sends `{kind:'next'}` (fails closed if no other
  /// client answers).
  Future<void> answerApproval(String eventId, DshApprovalDecision decision) {
    final outcome = decision == DshApprovalDecision.pass
        ? <String, Object?>{'kind': 'next'}
        : <String, Object?>{'kind': 'result', 'value': decision.wire};
    return mux.answerHostRequest(eventId, outcome);
  }

  /// Answers one `user-questions/request` waterfall.
  Future<void> answerQuestions(
    String eventId,
    List<DshQuestionAnswer> answers,
  ) {
    return mux.answerHostRequest(eventId, {
      'kind': 'result',
      'value': {
        'answers': answers
            .map((answer) => answer.toJson())
            .toList(growable: false),
      },
    });
  }

  // ---------------------------------------------------------------------------
  // Models, permissions, attachments, history

  Future<DshModelSelection> setModel(DshModelSelection selection) async {
    final value = jsonMap(
      await rpc.call(
        'session/selectModel',
        args: {
          'request': {'sessionId': sessionId, ...selection.toJson()},
        },
      ),
    );
    final selected = jsonMap(value['selected']);
    return selected.isEmpty ? selection : DshModelSelection.fromJson(selected);
  }

  /// Executes one slash-command line through `commands/execute` and returns the
  /// Host's in-band outcome.
  ///
  /// This is the same wire call the permission path uses; a command's durable
  /// events/projections are what confirm any resulting state change.
  Future<DshCommandExecution> executeCommand(String line) async {
    final value = jsonMap(
      await rpc.call(
        'commands/execute',
        args: {
          'agentId': sessionId,
          'line': line,
          'submittedAttachments': const <Object?>[],
        },
      ),
    );
    return DshCommandExecution.fromJson(value);
  }

  /// Changes the current permission preset through the `/permission` command.
  /// The durable `permission/preset` event and the projection frame confirm it.
  Future<DshCommandExecution> setPermission(String preset) =>
      executeCommand('/permission $preset');

  Future<DshSessionState> currentState() async {
    final value = await rpc.call(
      'session/state',
      args: {
        'request': {'sessionId': sessionId},
      },
      idempotent: true,
    );
    return DshSessionState.fromJson(value);
  }

  /// Uploads raw bytes through `POST /api/session/uploadFileBinary` and returns
  /// the receipt for a `file` prompt part.
  ///
  /// The route stores a plain file only when the request omits the `mediaType`
  /// query; sending a document mime there makes the Host parse the bytes as an
  /// upload image and refuse a non-image type, so this path never sends it
  /// (images travel inline in `session/prompt` instead).
  Future<DshUploadReceipt> uploadAttachment(
    Uint8List bytes, {
    String? name,
  }) async {
    final response = await transport.postBytes(
      transport.endpoint.uploadUri(sessionId, name: name),
      bytes,
      contentType: 'application/octet-stream',
    );
    if (response.statusCode != 200) {
      throw httpStatusException(
        response.statusCode,
        'session/uploadFileBinary',
        body: response.body,
      );
    }
    final decoded = tryDecodeJson(response.body);
    if (decoded is! Map) {
      throw const DshProtocolException('Upload answered a non-object body');
    }
    final map = jsonMap(decoded);
    if (map['ok'] != true) {
      final error = jsonMap(map['error']);
      throw DshRemoteException(
        jsonString(error['code']) ?? 'gateway/internal',
        jsonString(error['message']) ?? 'The upload failed',
        jsonMap(error['details']),
      );
    }
    return DshUploadReceipt.fromJson(map['value']);
  }

  /// Fetches one stored attachment's bytes for rendering.
  Future<Uint8List> attachmentBytes(DshImageAttachment attachment) async {
    final value = jsonMap(
      await rpc.call(
        'session/attachment',
        args: {
          'request': {'attachment': attachment.toJson()},
        },
        idempotent: true,
      ),
    );
    final data = jsonString(value['data']) ?? '';
    try {
      return base64Decode(data);
    } on FormatException {
      throw const DshProtocolException(
        'session/attachment returned bad base64',
      );
    }
  }

  /// Loads one page of older history before the oldest loaded event.
  Future<DshSessionHistoryPage> loadOlder() async {
    final before = _oldestLoadedSeq;
    if (before == null) {
      return const DshSessionHistoryPage(events: [], hasMore: false);
    }
    final page = await _loadPage(beforeSeq: before, throughSeq: null);
    final events =
        page.records
            .map((record) => DshSessionEvent.fromJson(jsonMap(record)['event']))
            .toList()
          ..sort((a, b) => a.seq.compareTo(b.seq));
    if (events.isNotEmpty) {
      _oldestLoadedSeq = events.first.seq;
    }
    _hasMoreHistory = page.hasMore;
    return DshSessionHistoryPage(events: events, hasMore: page.hasMore);
  }

  // ---------------------------------------------------------------------------
  // Terminal stage 1 (read-only attach)

  /// `terminal/shells` — executables the Host verified for this session.
  Future<List<DshTerminalShell>> terminalShells() async {
    final value = await rpc.call(
      dshTerminalShellsEndpoint,
      args: {'agentId': sessionId},
      idempotent: true,
    );
    return jsonList(
      value,
    ).map(DshTerminalShell.fromJson).toList(growable: false);
  }

  /// `terminal/environment` — the session workspace, caps and shell defaults.
  Future<DshTerminalEnvironment> terminalEnvironment() async {
    final value = await rpc.call(
      dshTerminalEnvironmentEndpoint,
      args: {'agentId': sessionId},
      idempotent: true,
    );
    return DshTerminalEnvironment.fromJson(value);
  }

  /// `terminal/list` — terminals owned by this session on this Host lifetime.
  Future<List<DshTerminalInfo>> listTerminals() async {
    final value = await rpc.call(
      dshTerminalListEndpoint,
      args: {'sessionId': sessionId},
      idempotent: true,
    );
    return jsonList(
      value,
    ).map(DshTerminalInfo.fromJson).toList(growable: false);
  }

  /// `terminal/create` — idempotent for an open identity; `id` defaults to a
  /// fresh uuid so the caller does not have to manage identity.
  Future<DshTerminalInfo> createTerminal({
    required int cols,
    required int rows,
    String? shellPath,
    String? id,
  }) async {
    final terminalId = id ?? dshUuidV4();
    final value = await rpc.call(
      dshTerminalCreateEndpoint,
      args: {
        'agentId': sessionId,
        'request': {
          'id': terminalId,
          'cols': cols,
          'rows': rows,
          if (shellPath != null && shellPath.isNotEmpty) 'shellPath': shellPath,
        },
      },
    );
    return DshTerminalInfo.fromJson(value);
  }

  /// `terminal/attach` — one mux stream; frames are decoded by
  /// [DshTerminalAttachment.frames]. The first frame is a snapshot.
  Future<DshTerminalAttachment> attachTerminal(String terminalId) async {
    final stream = await mux.open(
      dshTerminalAttachEndpoint,
      args: {'agentId': sessionId, 'id': terminalId},
    );
    return DshTerminalAttachment(id: terminalId, stream: stream);
  }

  /// `terminal/close` — ends the process behind one terminal.
  Future<void> closeTerminal(String terminalId) async {
    await rpc.call(
      dshTerminalCloseEndpoint,
      args: {'agentId': sessionId, 'id': terminalId},
    );
  }

  Future<DshHistoryPage> _loadPage({
    required int? beforeSeq,
    required int? throughSeq,
  }) async {
    final value = jsonMap(
      await rpc.call(
        'session/page',
        args: {
          'request': {
            'address': _address,
            if (beforeSeq != null) 'beforeSeq': beforeSeq,
            if (throughSeq != null) 'throughSeq': throughSeq,
            'maxMessages': options.historyPageMessages,
            'turnWindow': {
              'minMessages': options.turnWindowMinMessages,
              'minTurns': options.turnWindowMinTurns,
            },
          },
        },
        idempotent: true,
      ),
    );
    return DshHistoryPage.fromJson(value);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _itemSub?.cancel();
    _itemSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    await _hostSub?.cancel();
    _hostSub = null;
    final stream = _stream;
    _stream = null;
    await stream?.cancel();
    final completer = _firstSnapshot;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        const DshClosedException('This session view was closed'),
      );
    }
    await _updates.close();
  }
}

/// Pure-Dart state layer for one chat surface: consumes [DshSession] updates,
/// folds them into a [DshTranscript], and notifies listeners.
///
/// The Flutter controller is expected to be a thin `ChangeNotifier` wrapper:
/// `store.changes.listen((_) => notifyListeners())`.
class DshSessionStore {
  DshSessionStore({required this.session, DshTranscript? transcript})
    : transcript = transcript ?? DshTranscript();

  final DshSession session;
  final DshTranscript transcript;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<DshSessionUpdate>? _subscription;
  bool _started = false;
  bool _disposed = false;

  /// Fires after every folded update (coalesce with a scheduled frame).
  Stream<void> get changes => _changes.stream;

  DshTranscript get state => transcript;

  bool get isRunning => transcript.isRunning;

  Future<void> start({bool activate = true}) async {
    if (_disposed) {
      throw const DshClosedException('This session store was closed');
    }
    if (_started) return;
    _started = true;
    _subscription = session.updates.listen(
      (update) {
        switch (update) {
          case DshSessionSnapshotUpdate(:final snapshot):
            transcript.applySnapshot(snapshot);
          case DshSessionEventUpdate(:final event):
            transcript.applyEvent(event);
          case DshSessionAssistantFrameUpdate(:final frame):
            transcript.applyAssistantFrame(frame);
          case DshSessionHostRequestUpdate(:final event):
            transcript.applyHostEvent(event);
          case DshSessionConnectionUpdate(:final state, :final error):
            transcript.setConnection(state, error: error);
        }
        _notify();
      },
      onError: (Object error) {
        transcript.setConnection(
          DshConnectionState.reconnecting,
          error: error is DshException
              ? error
              : DshTransportException(
                  'The session stream failed',
                  cause: error,
                ),
        );
        _notify();
      },
    );
    await session.watch(activate: activate);
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<DshPromptReceipt> prompt(DshPrompt prompt, {String mode = 'queue'}) =>
      session.prompt(prompt, mode: mode);

  Future<void> cancel() => session.cancel();

  Future<void> answerApproval(String eventId, DshApprovalDecision decision) =>
      session.answerApproval(eventId, decision);

  Future<void> answerQuestions(
    String eventId,
    List<DshQuestionAnswer> answers,
  ) => session.answerQuestions(eventId, answers);

  Future<DshSessionHistoryPage> loadOlder() async {
    final page = await session.loadOlder();
    transcript.prepend(page.events);
    if (page.events.isNotEmpty) _notify();
    return page;
  }

  Future<void> setModel(DshModelSelection selection) async {
    await session.setModel(selection);
    _notify();
  }

  Future<void> setPermission(String preset) async {
    await session.setPermission(preset);
    _notify();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _changes.close();
  }
}
