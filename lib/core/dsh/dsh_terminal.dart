/// Stage-1 terminal surface: request/response metadata plus the read-only
/// `terminal/attach` frame decoder.
///
/// The wire facts come from the Host's `terminal` controller types (frame field
/// names are code-read, not captured live), so every decoder here is tolerant:
/// unknown frame types and missing fields are kept as raw maps instead of
/// failing the stream. Upload of `write`/`resize` is exposed on
/// [DshTerminalAttachment] but the stage-1 UI stays read-only until a live
/// attach confirms the sequence/ack behaviour.
library;

import 'dsh_models.dart';
import 'dsh_mux.dart';

const String dshTerminalEnvironmentEndpoint = 'terminal/environment';
const String dshTerminalShellsEndpoint = 'terminal/shells';
const String dshTerminalCreateEndpoint = 'terminal/create';
const String dshTerminalListEndpoint = 'terminal/list';
const String dshTerminalAttachEndpoint = 'terminal/attach';
const String dshTerminalRetainEndpoint = 'terminal/retain';
const String dshTerminalRenameEndpoint = 'terminal/rename';
const String dshTerminalCloseEndpoint = 'terminal/close';

/// Process lifecycle reported by `WebTerminalInfo.state`.
enum DshTerminalProcessState { running, exited, failed, unknown }

DshTerminalProcessState _processState(String? value) => switch (value) {
  'running' => DshTerminalProcessState.running,
  'exited' => DshTerminalProcessState.exited,
  'failed' => DshTerminalProcessState.failed,
  _ => DshTerminalProcessState.unknown,
};

/// One shell row from `terminal/shells`.
class DshTerminalShell {
  const DshTerminalShell({
    required this.path,
    this.args = const [],
    this.name = '',
    this.raw = const {},
  });

  factory DshTerminalShell.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshTerminalShell(
      path: jsonString(map['path']) ?? '',
      args: jsonStringList(map['args']),
      name: jsonString(map['name']) ?? '',
      raw: map,
    );
  }

  final String path;
  final List<String> args;
  final String name;
  final Map<String, Object?> raw;
}

/// `terminal/environment` value.
class DshTerminalEnvironment {
  const DshTerminalEnvironment({
    this.cwd,
    this.maxInputBytes,
    this.maxBufferedBytes,
    this.maxCols,
    this.maxRows,
    this.scrollback,
    this.raw = const {},
  });

  factory DshTerminalEnvironment.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshTerminalEnvironment(
      cwd: jsonString(map['cwd']),
      maxInputBytes: jsonInt(map['maxInputBytes']),
      maxBufferedBytes: jsonInt(map['maxBufferedBytes']),
      maxCols: jsonInt(map['maxCols']),
      maxRows: jsonInt(map['maxRows']),
      scrollback: jsonInt(map['scrollback']),
      raw: map,
    );
  }

  final String? cwd;
  final int? maxInputBytes;
  final int? maxBufferedBytes;
  final int? maxCols;
  final int? maxRows;
  final int? scrollback;
  final Map<String, Object?> raw;
}

/// `WebTerminalInfo` as returned by `terminal/create`/`terminal/list`, and
/// embedded in the `snapshot`/`state` attach frames.
class DshTerminalInfo {
  const DshTerminalInfo({
    required this.id,
    this.title = '',
    this.shell,
    this.cwd,
    this.cols,
    this.rows,
    this.processState = DshTerminalProcessState.unknown,
    this.exitCode,
    this.error,
    this.raw = const {},
  });

  factory DshTerminalInfo.fromJson(Object? json) {
    final map = jsonMap(json);
    final shell = map['shell'];
    final state = jsonString(map['state']);
    return DshTerminalInfo(
      id: jsonString(map['id']) ?? '',
      title: jsonString(map['title']) ?? '',
      shell: shell == null ? null : DshTerminalShell.fromJson(shell),
      cwd: jsonString(map['cwd']),
      cols: jsonInt(map['cols']),
      rows: jsonInt(map['rows']),
      processState: _processState(state),
      exitCode: jsonInt(map['exitCode']),
      error: jsonString(map['error']),
      raw: map,
    );
  }

  final String id;
  final String title;
  final DshTerminalShell? shell;
  final String? cwd;
  final int? cols;
  final int? rows;
  final DshTerminalProcessState processState;
  final int? exitCode;
  final String? error;
  final Map<String, Object?> raw;

  bool get isRunning => processState == DshTerminalProcessState.running;

  /// The original state string, for diagnostics when this client is older.
  String? get stateRaw => jsonString(raw['state']);
}

/// One decoded `terminal/attach` item frame.
///
/// Every attachment starts with a [DshTerminalSnapshotFrame] (full bounded
/// screen), then ordered [DshTerminalOutputFrame]s; [DshTerminalStateFrame]s
/// report process changes and [DshTerminalAckFrame]s answer uplink input.
sealed class DshTerminalFrame {
  const DshTerminalFrame({this.sequence});

  factory DshTerminalFrame.fromJson(Object? json) {
    final map = jsonMap(json);
    final type = jsonString(map['type']) ?? '';
    final sequence = jsonInt(map['sequence']);
    switch (type) {
      case 'snapshot':
        final info = map['info'];
        return DshTerminalSnapshotFrame(
          sequence: sequence,
          screen:
              jsonString(map['screen']) ??
              jsonString(map['data']) ??
              jsonString(map['text']) ??
              '',
          info: info == null ? null : DshTerminalInfo.fromJson(info),
          writable: map['writable'] == true,
          inputWindow: map['inputWindow'],
          raw: map,
        );
      case 'output':
        return DshTerminalOutputFrame(
          sequence: sequence,
          data:
              jsonString(map['data']) ??
              jsonString(map['text']) ??
              jsonString(map['output']) ??
              '',
          raw: map,
        );
      case 'state':
        final info = map['info'];
        return DshTerminalStateFrame(
          info: info == null ? null : DshTerminalInfo.fromJson(info),
          writable: map['writable'] == true,
          raw: map,
        );
      case 'ack':
        return DshTerminalAckFrame(
          sequence: sequence,
          refusal: jsonString(map['refusal']),
          raw: map,
        );
      default:
        return DshTerminalUnknownFrame(raw: map, sequence: sequence);
    }
  }

  /// Last consumed uplink sequence (null for frames without one).
  final int? sequence;
}

final class DshTerminalSnapshotFrame extends DshTerminalFrame {
  const DshTerminalSnapshotFrame({
    super.sequence,
    this.screen = '',
    this.info,
    this.writable = false,
    this.inputWindow,
    this.raw = const {},
  });

  /// The bounded screen text the Host replayed for this attachment.
  final String screen;
  final DshTerminalInfo? info;

  /// False means the Host will refuse `write`/`resize` (`read-only`).
  final bool writable;

  /// Opaque `RemoteUplinkWindow` (abs its own shape is not on this wire yet).
  final Object? inputWindow;
  final Map<String, Object?> raw;
}

final class DshTerminalOutputFrame extends DshTerminalFrame {
  const DshTerminalOutputFrame({
    super.sequence,
    this.data = '',
    this.raw = const {},
  });

  /// Raw terminal output for the VT renderer.
  final String data;
  final Map<String, Object?> raw;
}

final class DshTerminalStateFrame extends DshTerminalFrame {
  const DshTerminalStateFrame({
    this.info,
    this.writable = false,
    this.raw = const {},
  });

  final DshTerminalInfo? info;
  final bool writable;
  final Map<String, Object?> raw;
}

final class DshTerminalAckFrame extends DshTerminalFrame {
  const DshTerminalAckFrame({
    super.sequence,
    this.refusal,
    this.raw = const {},
  });

  /// `'read-only'` / `'not-running'`; null means the input was accepted.
  final String? refusal;
  final Map<String, Object?> raw;

  bool get accepted => refusal == null;
}

final class DshTerminalUnknownFrame extends DshTerminalFrame {
  const DshTerminalUnknownFrame({required this.raw, super.sequence});
  final Map<String, Object?> raw;
}

/// One followed `terminal/attach` stream with its decoded frame view.
class DshTerminalAttachment {
  DshTerminalAttachment({required this.id, required this.stream});

  final String id;
  final DshStream stream;

  bool get isClosed => stream.isClosed;

  /// Decoded frames; single-subscription like the underlying mux stream.
  ///
  /// Deliberately `map` instead of an `async*` generator: cancelling a
  /// subscription to an `async*` stream that is suspended on `await for` waits
  /// for the source stream to end, which a long-lived attach stream never does
  /// (the detach would deadlock). `map` cancels through immediately.
  Stream<DshTerminalFrame> get frames =>
      stream.items.map(DshTerminalFrame.fromJson);

  /// Stage-2 uplink: `{type:'write',sequence,data}` item frame.
  ///
  /// Sequences start at 1 and must be consecutive within one attachment; the
  /// Host answers with a [DshTerminalAckFrame] and may refuse (`read-only`).
  void write({required int sequence, required String data}) {
    stream.sendItem({'type': 'write', 'sequence': sequence, 'data': data});
  }

  /// Stage-2 uplink: `{type:'resize',sequence,cols,rows}` item frame.
  void resize({required int sequence, required int cols, required int rows}) {
    stream.sendItem({
      'type': 'resize',
      'sequence': sequence,
      'cols': cols,
      'rows': rows,
    });
  }

  /// Client-side detach; the Host keeps the process (use `terminal/retain` to
  /// keep it without the screen, `terminal/close` to end it).
  Future<void> close() => stream.cancel();
}
