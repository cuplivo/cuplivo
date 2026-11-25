import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:Cuplivo/core/dsh/dsh_client.dart';
import 'package:Cuplivo/core/dsh/dsh_session.dart';
import 'package:Cuplivo/core/dsh/dsh_terminal.dart';
import 'package:Cuplivo/core/services/workspace/workspace_runtime.dart';

/// The gateway seam that hands out one remote-terminal runtime per session.
///
/// Implemented by the DSH gateway adapter (the only layer that owns a live
/// `DshClient`); a fake gateway simply does not implement it and the rail
/// renders its honest unavailable state.
abstract interface class DshTerminalRuntimeHost {
  /// Null when the link is not ready; otherwise a fresh runtime over the
  /// session's terminal endpoints.
  DshWorkspaceRuntime? terminalRuntimeFor(String sessionId);
}

/// [WorkspaceRuntime] over a DeepSeek Harness session's `terminal/*` endpoints.
///
/// DSH terminals are server-side processes anchored at the session workspace:
/// the Host decides the cwd/shell/env, so the local [openPty] arguments are
/// deliberately ignored (the panel reads `terminal/environment` once for the
/// cwd it displays). Everything that needs a local desktop shell is
/// unsupported.
class DshWorkspaceRuntime implements WorkspaceRuntime {
  DshWorkspaceRuntime({required DshClient client, required String sessionId})
    // ignore: prefer_initializing_formals
    : _client = client,
      // ignore: prefer_initializing_formals
      _sessionId = sessionId;

  final DshClient _client;
  final String _sessionId;

  /// Lazily cached so the panel can read it once and reuse the same cwd.
  DshTerminalEnvironment? _environment;

  /// Terminals this runtime created; closed on dispose so a rail page rebuild
  /// does not leave orphan bash processes on the Host.
  final Set<String> _createdTerminalIds = <String>{};

  String get sessionId => _sessionId;

  /// `terminal/environment` — cwd plus the input/output bounds.
  Future<DshTerminalEnvironment> environment() async {
    final cached = _environment;
    if (cached != null) return cached;
    final value = await _session.terminalEnvironment();
    _environment = value;
    return value;
  }

  DshSession get _session => _client.openSession(_sessionId);

  @override
  bool get supportsPty => true;

  @override
  bool get supportsSystemTerminal => false;

  @override
  bool get supportsFileManager => false;

  @override
  Future<RuntimeStatus> status() async {
    final environmentInfo = await environment();
    return RuntimeStatus(
      ready: true,
      reason: environmentInfo.cwd == null
          ? 'the Host did not report a terminal working directory'
          : null,
      engine: 'dsh',
      sandboxed: false,
    );
  }

  @override
  Future<PtySession> openPty({
    required List<Mount> mounts,
    required String cwd,
    required Map<String, String> env,
    required int cols,
    required int rows,
  }) async {
    final environmentInfo = await environment();
    final session = _session;
    final info = await session.createTerminal(cols: cols, rows: rows);
    _createdTerminalIds.add(info.id);
    final attachment = await session.attachTerminal(info.id);
    return DshPtySession(
      attachment: attachment,
      initialInfo: info,
      environment: environmentInfo,
    );
  }

  /// `terminal/close` for every terminal this runtime created. Best effort:
  /// a link that dropped must not turn a navigation into an error.
  Future<void> closeCreatedTerminals() async {
    final ids = List<String>.of(_createdTerminalIds);
    _createdTerminalIds.clear();
    for (final id in ids) {
      try {
        await _session.closeTerminal(id);
      } catch (_) {
        // The Host may already have reaped it (session ended, server restart).
      }
    }
  }

  @override
  Stream<CommandEvent> run(CommandRequest request) {
    throw UnsupportedError(
      'Commands run through the assistant, not the remote terminal runtime',
    );
  }

  @override
  Future<void> cancel(String runId) async {}

  @override
  Future<void> openInSystemTerminal(String hostDir) {
    throw UnsupportedError(
      'A remote terminal has no local system-terminal equivalent',
    );
  }

  @override
  Future<void> revealInFileManager(String hostPath) {
    throw UnsupportedError('Remote files are not on this device’s file system');
  }
}

/// One attached `terminal/attach` stream bridged into a [PtySession].
///
/// The Host sends `snapshot` (the whole screen), then ordered `output`, `state`
/// and `ack` items. This class translates them into the byte stream the
/// `terminal_view` emulator consumes and the write/resize uplink the manager
/// drives, with the Host's bounds honored:
///
/// * `writable: false` in a snapshot/state/ack means input is refused; the
///   value is published through [writable] and the key bar disappears;
/// * `write` is split at `environment.maxInputBytes` so one paste cannot be
///   rejected as an oversized uplink;
/// * uplink sequences are consecutive from 1 across both write and resize
///   items (the Host acks each one).
class DshPtySession implements PtySession {
  DshPtySession({
    required this.attachment,
    required DshTerminalInfo initialInfo,
    required this.environment,
  }) : _info = ValueNotifier<DshTerminalInfo?>(initialInfo) {
    _writable = ValueNotifier<bool>(true);
    _frames = attachment.frames.listen(
      _onFrame,
      onError: (Object error, StackTrace stack) {
        debugPrint('DSH terminal stream error: $error');
        _completeExit(1);
      },
      onDone: () => _completeExit(_lastExitCode ?? 0),
    );
  }

  /// The Host-side terminal this session drives (frames down, write/resize up).
  final DshTerminalAttachment attachment;

  /// Host-reported limits (input chunking) and cwd/shell metadata.
  final DshTerminalEnvironment environment;

  final ValueNotifier<DshTerminalInfo?> _info;

  /// Last process state the Host reported; used for the state banner.
  ValueListenable<DshTerminalInfo?> get info => _info;

  late final ValueNotifier<bool> _writable;

  /// False once the Host refused input (`read-only`/`not-running`) or the
  /// process exited.
  ValueListenable<bool> get writable => _writable;

  final StreamController<Uint8List> _output = StreamController<Uint8List>(
    sync: true,
  );
  final Completer<int> _exit = Completer<int>();
  StreamSubscription<DshTerminalFrame>? _frames;
  int _sequence = 0;
  bool _closed = false;
  int? _lastExitCode;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  void _onFrame(DshTerminalFrame frame) {
    if (_closed) return;
    switch (frame) {
      case DshTerminalSnapshotFrame():
        _writable.value = frame.writable;
        if (frame.info != null) _info.value = frame.info;
        if (frame.screen.isNotEmpty) _emit(frame.screen);
      case DshTerminalOutputFrame():
        if (frame.data.isNotEmpty) _emit(frame.data);
      case DshTerminalStateFrame():
        _writable.value = frame.writable;
        if (frame.info != null) {
          _info.value = frame.info;
          _lastExitCode = frame.info?.exitCode;
          if (frame.info?.processState == DshTerminalProcessState.exited ||
              frame.info?.processState == DshTerminalProcessState.failed) {
            _completeExit(frame.info?.exitCode ?? 0);
          }
        }
      case DshTerminalAckFrame():
        if (!frame.accepted) _writable.value = false;
      case DshTerminalUnknownFrame():
        // Tolerant: a frame this client version does not know must not kill
        // the terminal.
        break;
    }
  }

  void _emit(String text) {
    if (_output.isClosed) return;
    _output.add(Uint8List.fromList(utf8.encode(text)));
  }

  void _completeExit(int code) {
    if (_closed) return;
    _closed = true;
    _lastExitCode = code;
    _writable.value = false;
    if (!_exit.isCompleted) _exit.complete(code);
    unawaited(_frames?.cancel());
    _frames = null;
    if (!_output.isClosed) unawaited(_output.close());
  }

  @override
  Future<void> write(Uint8List data) async {
    if (_closed || !_writable.value || data.isEmpty) return;
    final text = utf8.decode(data, allowMalformed: true);
    for (final chunk in _chunks(text, environment.maxInputBytes)) {
      if (_closed || !_writable.value) return;
      attachment.write(sequence: ++_sequence, data: chunk);
    }
  }

  @override
  Future<void> resize(int cols, int rows) async {
    if (_closed || !_writable.value) return;
    attachment.resize(sequence: ++_sequence, cols: cols, rows: rows);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _writable.value = false;
    // Detach first: cancelling the frame subscription while the Host keeps the
    // stream open leaves the subscription waiting for an end that never comes.
    // A detach that fails (a dead socket) must not keep the panel alive.
    try {
      await attachment.close();
    } on Object {
      // The Host stream may already be gone; local teardown still completes.
    }
    final frames = _frames;
    _frames = null;
    await frames?.cancel();
    if (!_exit.isCompleted) _exit.complete(0);
    // Same trap as the mux stream: a never-listened single-subscription
    // controller never completes close(), so teardown must not await it.
    if (!_output.isClosed) unawaited(_output.close());
  }

  /// Splits [text] into chunks whose UTF-8 encoding fits [maxBytes].
  ///
  /// A single code point always fits in any useful Host limit (the maximum
  /// encoded length is 4 bytes); the fallback keeps a pathological limit from
  /// looping forever.
  static List<String> _chunks(String text, int? maxBytes) {
    final limit = (maxBytes == null || maxBytes <= 0) ? text.length : maxBytes;
    if (utf8.encode(text).length <= limit) return <String>[text];
    final chunks = <String>[];
    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in text.runes) {
      final encoded = utf8.encode(String.fromCharCode(rune)).length;
      if (bytes + encoded > limit && buffer.isNotEmpty) {
        chunks.add(buffer.toString());
        buffer.clear();
        bytes = 0;
      }
      buffer.writeCharCode(rune);
      bytes += encoded;
    }
    if (buffer.isNotEmpty) chunks.add(buffer.toString());
    return chunks;
  }
}
