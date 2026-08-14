import 'dart:async';
import 'dart:convert';

import 'web_transcript_models.dart';

typedef WebTranscriptCommandSender = Future<void> Function(String encoded);

class WebTranscriptSession {
  WebTranscriptSession({
    required this._sendEncoded,
    required this.onEvent,
    required this.onFatal,
    this.ackTimeout = const Duration(seconds: 5),
  });

  final WebTranscriptCommandSender _sendEncoded;
  final void Function(WebTranscriptBridgeEvent event) onEvent;
  final void Function(Object error) onFatal;
  final Duration ackTimeout;

  final Map<String, _PendingCommand> _pending = <String, _PendingCommand>{};
  var _epoch = 0;
  var _sequence = 0;
  var _failureCount = 0;
  var _disposed = false;

  int get epoch => _epoch;

  void startNewEpoch() {
    _epoch++;
    _sequence = 0;
    _failureCount = 0;
    _failPending(StateError('Web transcript epoch changed'));
  }

  Future<void> send(
    String type,
    Map<String, Object?> payload, {
    bool fatalOnFailure = false,
  }) async {
    if (_disposed) throw StateError('Web transcript session is disposed');
    final id = '$_epoch:${++_sequence}';
    final command = <String, Object?>{
      'version': webTranscriptProtocolVersion,
      'epoch': _epoch,
      'sequence': _sequence,
      'id': id,
      'type': type,
      'payload': payload,
    };
    final completer = Completer<void>();
    final timer = Timer(ackTimeout, () {
      final pending = _pending.remove(id);
      if (pending == null) return;
      final error = TimeoutException('Web transcript command timed out: $type');
      pending.completer.completeError(error);
      _recordFailure(error, fatal: pending.fatalOnFailure);
    });
    _pending[id] = _PendingCommand(
      completer: completer,
      timer: timer,
      fatalOnFailure: fatalOnFailure,
    );
    final encoded = base64Encode(utf8.encode(jsonEncode(command)));
    try {
      await _sendEncoded(encoded);
    } catch (error, stackTrace) {
      final pending = _pending.remove(id);
      pending?.timer.cancel();
      _recordFailure(error, fatal: fatalOnFailure);
      Error.throwWithStackTrace(error, stackTrace);
    }
    return completer.future;
  }

  void receive(String raw) {
    if (_disposed) return;
    try {
      final event = WebTranscriptBridgeEvent.parse(raw);
      if (event.version != webTranscriptProtocolVersion) {
        throw StateError('Unsupported Web transcript protocol version');
      }
      if (event.type != 'ready' && event.epoch != _epoch) {
        return;
      }
      if (event.type == 'ack' || event.type == 'error') {
        final commandId = event.commandId;
        if (commandId != null) {
          final pending = _pending.remove(commandId);
          if (pending != null) {
            pending.timer.cancel();
            if (event.type == 'ack') {
              _failureCount = 0;
              pending.completer.complete();
            } else {
              final code = event.payload['code'];
              final error = StateError('Web transcript command failed: $code');
              pending.completer.completeError(error);
              _recordFailure(error, fatal: pending.fatalOnFailure);
            }
          }
        }
      }
      onEvent(event);
    } catch (error) {
      _recordFailure(error, fatal: true);
    }
  }

  void _recordFailure(Object error, {required bool fatal}) {
    _failureCount++;
    if (fatal || _failureCount >= 3) onFatal(error);
  }

  void _failPending(Object error) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final command in pending) {
      command.timer.cancel();
      if (!command.completer.isCompleted) {
        command.completer.completeError(error);
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _failPending(StateError('Web transcript session disposed'));
  }
}

class _PendingCommand {
  const _PendingCommand({
    required this.completer,
    required this.timer,
    required this.fatalOnFailure,
  });

  final Completer<void> completer;
  final Timer timer;
  final bool fatalOnFailure;
}
