/// The `/api/remote.mux` WebSocket: many logical streams over one socket.
///
/// ## Frames (JSON text, one per WebSocket message)
///
/// ```text
/// client -> host  {"type":"open","streamId":"<uuid>","endpoint":"session/follow",
///                  "payload":{"args":{…}}}
///                 {"type":"item","streamId":"…","value":…}   uplink item
///                 {"type":"end","streamId":"…"}                uplink half-close
///                 {"type":"cancel","streamId":"…"}
/// host -> client  {"type":"item","streamId":"…","value":…}
///                 {"type":"end","streamId":"…"}
///                 {"type":"error","streamId":"…","error":{"code","message","details"}}
/// ```
///
/// ## Generations
///
/// Every successful socket carries one `$events` stream whose first item must
/// be `{"type":"ready","clientId":…,"host":{"home":…}}`. That ready handshake
/// defines a connection *generation*: losing the socket voids every logical
/// stream and **nothing is replayed**. Streams with `autoReopen` are re-opened
/// on the next generation and their fresh baseline is fed into the same item
/// stream, so consumers must treat a new baseline as a full replacement.
/// Pending waterfalls (approvals/questions) are redelivered by the Host with
/// the same `eventId`; they are kept for [DshMuxOptions.hostRequestGrace] after
/// a new ready so the UI does not flicker, then retracted.
library;

import 'dart:async';
import 'dart:math';

import 'dsh_errors.dart';
import 'dsh_events.dart';
import 'dsh_rpc.dart';
import 'dsh_transport.dart';

/// Exact WebSocket route carrying every Remote stream.
const String dshRemoteMuxPath = '/api/remote.mux';

/// Gateway-internal stream carrying application-selected Cordis events.
const String dshHostEventsEndpoint = r'$events';

/// Gateway-internal unary endpoint answering one Host waterfall.
const String dshHostEventResultEndpoint = r'$events/result';

/// One established generation: a socket whose `$events` stream delivered ready.
class DshMuxGeneration {
  const DshMuxGeneration({
    required this.number,
    required this.clientId,
    required this.home,
  });

  /// Increments on every successful (re)connect, starting at 1.
  final int number;

  /// Must accompany every `$events/result` answer sent in this generation.
  final String clientId;

  /// Host account home, for abbreviating displayed paths.
  final String home;

  @override
  String toString() => 'DshMuxGeneration($number, $clientId)';
}

class DshMuxOptions {
  const DshMuxOptions({
    this.readyTimeout = const Duration(seconds: 15),
    this.pingInterval = const Duration(seconds: 15),
    this.retryCaps = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 10),
    ],
    this.autoReconnect = true,
    this.maxAttempts,
    this.retryDelay,
    this.hostRequestGrace = const Duration(seconds: 3),
  });

  /// Deadline for `$events` ready after the socket opens (Host recovery config).
  final Duration readyTimeout;

  /// Client ping cadence on the physical socket.
  final Duration pingInterval;

  /// Exponential backoff caps. The delay is `cap · (0.5…1.0)` (50–100 % jitter).
  final List<Duration> retryCaps;
  final bool autoReconnect;

  /// Stop after this many consecutive failures (null = retry forever).
  final int? maxAttempts;

  /// Test hook: overrides [retryCaps] entirely.
  final Duration Function(int attempt)? retryDelay;

  /// How long redelivered Host requests are kept before stale ones retract.
  final Duration hostRequestGrace;
}

/// Owns one mux socket and everything multiplexed over it.
class DshMux {
  DshMux(this.transport, {this.options = const DshMuxOptions(), DshRpc? rpc})
    : rpc = rpc ?? DshRpc(transport);

  final DshTransport transport;
  final DshMuxOptions options;
  final DshRpc rpc;

  DshConnectionState _state = DshConnectionState.idle;
  DshMuxGeneration? _generation;
  DshException? _lastError;
  DshSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  Timer? _reconnectTimer;
  Timer? _readyTimer;
  Timer? _graceTimer;
  bool _closed = false;
  bool _handlingLoss = false;
  int _attempt = 0;
  int _generationNumber = 0;

  final Map<String, DshStream> _streams = {};
  final Map<String, DshHostEvent> _pending = {};
  final Set<String> _redeliveredThisGeneration = {};
  final List<Completer<DshMuxGeneration>> _generationWaiters = [];
  final StreamController<DshConnectionState> _states =
      StreamController<DshConnectionState>.broadcast();
  final StreamController<DshHostEvent> _hostEvents =
      StreamController<DshHostEvent>.broadcast();

  DshConnectionState get state => _state;

  /// The current generation, or null while connecting/reconnecting.
  DshMuxGeneration? get generation => _generation;

  DshException? get lastError => _lastError;

  /// Connection state transitions (broadcast; replays nothing).
  Stream<DshConnectionState> get states => _states.stream;

  /// Application events and waterfalls; the ready frame is not included.
  Stream<DshHostEvent> get hostEvents => _hostEvents.stream;

  /// Pending approvals/questions/plugin waterfalls, keyed by `eventId`.
  List<DshHostRequest> get pendingRequests =>
      _pending.values.whereType<DshHostRequest>().toList(growable: false);

  /// Resolves with the first (or next) ready generation, starting the socket.
  Future<DshMuxGeneration> get ready => _waitForGeneration();

  Future<DshMuxGeneration> _waitForGeneration() {
    final current = _generation;
    if (current != null) return Future<DshMuxGeneration>.value(current);
    if (_closed) {
      return Future<DshMuxGeneration>.error(
        const DshClosedException('The client was closed'),
      );
    }
    final completer = Completer<DshMuxGeneration>();
    _generationWaiters.add(completer);
    _scheduleConnect();
    return completer.future;
  }

  /// Opens one logical stream.
  ///
  /// The stream starts receiving items once a generation is ready; with
  /// [autoReopen] it survives reconnects (the Host re-sends its baseline).
  Future<DshStream> open(
    String endpoint, {
    Map<String, Object?> args = const {},
    bool autoReopen = true,
  }) async {
    if (_closed) throw const DshClosedException('The client was closed');
    final stream = DshStream._(
      this,
      id: dshUuidV4(),
      endpoint: endpoint,
      args: args,
      autoReopen: autoReopen,
    );
    _streams[stream.id] = stream;
    if (_generation != null) {
      stream._open();
    } else {
      _scheduleConnect();
    }
    return stream;
  }

  /// Answers one pending Host waterfall through `$events/result`.
  Future<void> answerHostRequest(
    String eventId,
    Map<String, Object?> outcome,
  ) async {
    final generation = _generation;
    if (generation == null) {
      throw const DshTransportException(
        'Cannot answer a Host request while disconnected',
      );
    }
    final args = <String, Object?>{
      'clientId': generation.clientId,
      'eventId': eventId,
      'outcome': outcome,
    };
    try {
      await rpc.call(dshHostEventResultEndpoint, args: args);
    } on DshRemoteException catch (error) {
      final message = error.message.toLowerCase();
      final staleClient =
          message.contains('client') &&
          (message.contains('identif') ||
              message.contains('stale') ||
              message.contains('no active') ||
              message.contains('unknown'));
      final current = _generation;
      if (staleClient && current != null && !identical(current, generation)) {
        await rpc.call(
          dshHostEventResultEndpoint,
          args: {...args, 'clientId': current.clientId},
        );
      } else {
        rethrow;
      }
    }
    _settleRequest(eventId);
  }

  void _settleRequest(String eventId) {
    if (_pending.remove(eventId) != null) {
      _emitHostEvent(DshHostRequestCancelled(eventId: eventId));
    }
  }

  /// Manual reconnect after `unauthorized` or exhausted attempts.
  Future<DshMuxGeneration> reconnect() {
    if (_closed) {
      return Future<DshMuxGeneration>.error(
        const DshClosedException('The client was closed'),
      );
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _attempt = 0;
    if (_socket == null && _state != DshConnectionState.connected) {
      _state = DshConnectionState.idle;
      _scheduleConnect();
    }
    return _waitForGeneration();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reconnectTimer?.cancel();
    _readyTimer?.cancel();
    _graceTimer?.cancel();
    final error = const DshClosedException('The client was closed');
    for (final waiter in _generationWaiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _generationWaiters.clear();
    final streams = _streams.values.toList(growable: false);
    _streams.clear();
    for (final stream in streams) {
      await stream._closeLocal();
    }
    final socket = _socket;
    _socket = null;
    _generation = null;
    await _subscription?.cancel();
    _subscription = null;
    await socket?.close(1000, 'client closed');
    _setState(DshConnectionState.closed);
    await _states.close();
    await _hostEvents.close();
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle

  void _scheduleConnect() {
    if (_closed || _socket != null || _reconnectTimer != null) return;
    if (_state == DshConnectionState.connected ||
        _state == DshConnectionState.connecting) {
      return;
    }
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_closed || _socket != null) return;
    _handlingLoss = false;
    _redeliveredThisGeneration.clear();
    _setState(
      _generationNumber == 0
          ? DshConnectionState.connecting
          : DshConnectionState.reconnecting,
    );

    final DshSocket socket;
    try {
      socket = await transport.openMux();
    } on DshAuthException catch (error) {
      _lastError = error;
      _setState(DshConnectionState.unauthorized);
      _failWaiters(error);
      return;
    } on DshException catch (error) {
      _scheduleRetry(error);
      return;
    }

    if (_closed) {
      await socket.close(1000, 'client closed');
      return;
    }

    _socket = socket;
    _readyTimer = Timer(options.readyTimeout, () {
      if (_closed || _generation != null) return;
      _lastError = DshTransportException(
        'The Host did not complete the $dshHostEventsEndpoint handshake',
      );
      final current = _socket;
      if (current != null && identical(current, socket)) {
        unawaited(current.close(1001, 'ready timeout'));
      }
    });

    _subscription = socket.frames.listen(
      _onFrame,
      onError: (Object error) => _onSocketLost(
        error is DshException
            ? error
            : DshTransportException('The mux socket failed', cause: error),
      ),
      onDone: () =>
          _onSocketLost(const DshTransportException('The mux socket closed')),
      cancelOnError: false,
    );

    _sendFrame({
      'type': 'open',
      'streamId': 'events',
      'endpoint': dshHostEventsEndpoint,
      'payload': {'args': <String, Object?>{}},
    });
  }

  void _onFrame(Object? decoded) {
    if (_closed) return;
    switch (decoded) {
      case String() || num() || bool() || null:
        _onSocketLost(
          const DshProtocolException('The mux sent a non-object frame'),
        );
      case final Map<Object?, Object?> map:
        final frame = DshMuxFrame.parse(map);
        switch (frame) {
          case DshMuxItem(:final streamId, :final value):
            if (streamId == 'events') {
              _onHostEventFrame(value);
            } else {
              _streams[streamId]?._deliverItem(value);
            }
          case DshMuxEnd(:final streamId):
            if (streamId == 'events') {
              _onSocketLost(
                const DshTransportException('The Host ended the event stream'),
              );
            } else {
              _streams[streamId]?._deliverEnd();
            }
          case DshMuxError(
            :final streamId,
            :final code,
            :final message,
            :final details,
          ):
            if (streamId == 'events') {
              _onSocketLost(DshRemoteException(code, message, details));
            } else {
              _streams[streamId]?._deliverError(
                DshRemoteException(code, message, details),
              );
            }
          case DshMuxUnknown():
            // Forward compatibility: ignore unknown gateway frames.
            break;
        }
      default:
        _onSocketLost(
          const DshProtocolException('The mux sent an unreadable frame'),
        );
    }
  }

  void _onHostEventFrame(Object? value) {
    final event = DshHostEvent.fromJson(value);
    switch (event) {
      case DshHostReady():
        _onReady(event);
      case final DshHostRequest request:
        _pending[request.eventId] = request;
        _redeliveredThisGeneration.add(request.eventId);
        _emitHostEvent(request);
      case DshHostRequestCancelled(:final eventId):
        _pending.remove(eventId);
        _emitHostEvent(event);
      case DshHostEmit():
        _emitHostEvent(event);
      case DshHostUnknown():
        // Forward compatibility: a frame shape this client does not know.
        break;
    }
  }

  void _onReady(DshHostReady ready) {
    _readyTimer?.cancel();
    _readyTimer = null;
    _graceTimer?.cancel();
    _generationNumber += 1;
    _generation = DshMuxGeneration(
      number: _generationNumber,
      clientId: ready.clientId,
      home: ready.home,
    );
    _attempt = 0;
    _lastError = null;
    _setState(DshConnectionState.connected);
    final completed = List<Completer<DshMuxGeneration>>.of(_generationWaiters);
    _generationWaiters.clear();
    for (final waiter in completed) {
      if (!waiter.isCompleted) waiter.complete(_generation!);
    }
    final streams = _streams.values.toList(growable: false);
    for (final stream in streams) {
      stream._open();
    }
    // The Host redelivers still-pending requests with the same eventId. Keep
    // the previous generation's cards for a grace period, then retract the ones
    // that did not reappear (they were answered elsewhere while we were away).
    _graceTimer = Timer(options.hostRequestGrace, () {
      _pending.removeWhere(
        (eventId, _) => !_redeliveredThisGeneration.contains(eventId),
      );
    });
  }

  void _onSocketLost(DshException error) {
    if (_closed || _handlingLoss) return;
    _handlingLoss = true;
    _readyTimer?.cancel();
    _readyTimer = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final socket = _socket;
    _socket = null;
    final generation = _generation;
    _generation = null;
    _lastError = error;
    unawaited(socket?.close(1001, 'connection lost'));
    if (generation != null) {
      _setState(DshConnectionState.reconnecting);
    }
    final streams = _streams.values.toList(growable: false);
    for (final stream in streams) {
      stream._generationLost(error);
    }
    _scheduleRetry(error, wasConnected: generation != null);
  }

  void _scheduleRetry(DshException error, {bool wasConnected = false}) {
    _lastError = error;
    if (_closed) return;
    if (!options.autoReconnect) {
      _setState(DshConnectionState.idle);
      _failWaiters(error);
      return;
    }
    final maxAttempts = options.maxAttempts;
    if (maxAttempts != null && _attempt + 1 >= maxAttempts) {
      _setState(DshConnectionState.idle);
      _failWaiters(error);
      return;
    }
    if (!wasConnected && _state != DshConnectionState.reconnecting) {
      _setState(DshConnectionState.reconnecting);
    }
    final delay = _delayFor(_attempt);
    _attempt += 1;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connect());
    });
  }

  Duration _delayFor(int attempt) {
    final override = options.retryDelay;
    if (override != null) return override(attempt);
    if (options.retryCaps.isEmpty) return Duration.zero;
    final cap = options.retryCaps[min(attempt, options.retryCaps.length - 1)];
    final jitter = 0.5 + _random.nextDouble() * 0.5;
    return Duration(microseconds: (cap.inMicroseconds * jitter).round());
  }

  void _failWaiters(DshException error) {
    final waiters = List<Completer<DshMuxGeneration>>.of(_generationWaiters);
    _generationWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
  }

  void _sendFrame(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(frame);
    } on Object {
      // A send on a dying socket must not throw into callers; the socket's
      // done/error path schedules the reconnect.
    }
  }

  void _setState(DshConnectionState state) {
    if (_state == state) return;
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  void _emitHostEvent(DshHostEvent event) {
    if (!_hostEvents.isClosed) _hostEvents.add(event);
  }
}

/// One logical stream over the mux.
class DshStream {
  DshStream._(
    this._mux, {
    required this.id,
    required this.endpoint,
    required this.args,
    required this.autoReopen,
  });

  final DshMux _mux;
  final String id;
  final String endpoint;
  final Map<String, Object?> args;
  final bool autoReopen;
  final StreamController<Object?> _controller = StreamController<Object?>();
  bool _opened = false;
  bool _closed = false;

  /// Decoded `value` of every item frame.
  Stream<Object?> get items => _controller.stream;

  bool get isClosed => _closed;

  void _open() {
    if (_closed || _opened) return;
    _opened = true;
    _mux._sendFrame({
      'type': 'open',
      'streamId': id,
      'endpoint': endpoint,
      'payload': {'args': args},
    });
  }

  void _deliverItem(Object? value) {
    if (_closed) return;
    _controller.add(value);
  }

  void _deliverEnd() {
    if (_closed) return;
    _closed = true;
    _mux._streams.remove(id);
    unawaited(_controller.close());
  }

  void _deliverError(DshRemoteException error) {
    if (_closed) return;
    _closed = true;
    _mux._streams.remove(id);
    _controller.addError(error);
    unawaited(_controller.close());
  }

  void _generationLost(DshException error) {
    if (_closed) return;
    if (autoReopen) {
      _opened = false;
    } else {
      _closed = true;
      _mux._streams.remove(id);
      _controller.addError(error);
      unawaited(_controller.close());
    }
  }

  /// Local shutdown: complete silently. Caller-initiated `close()` is not an
  /// error for a consumer that is merely being torn down.
  Future<void> _closeLocal() async {
    if (_closed) return;
    _closed = true;
    _mux._streams.remove(id);
    await _controller.close();
  }

  /// Half-closes the uplink and releases the stream locally.
  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    _mux._streams.remove(id);
    _mux._sendFrame({'type': 'cancel', 'streamId': id});
    await _controller.close();
  }
}

final Random _random = Random();
