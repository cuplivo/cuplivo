/// Test doubles for the DSH transport. No test in this directory opens a
/// socket or touches the network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_errors.dart';
import 'package:Cuplivo/core/dsh/dsh_transport.dart';

/// One in-memory WebSocket carrying decoded JSON frames.
class FakeDshSocket implements DshSocket {
  FakeDshSocket({this.onSend});

  void Function(Object? frame)? onSend;
  final StreamController<Object?> _frames = StreamController<Object?>();
  final Completer<void> _done = Completer<void>();
  final List<Object?> sent = [];
  bool closed = false;

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Object? frame) {
    sent.add(frame);
    onSend?.call(frame);
  }

  @override
  Future<void> close([int code = 1000, String? reason]) async {
    if (closed) return;
    closed = true;
    if (!_frames.isClosed) await _frames.close();
    if (!_done.isCompleted) _done.complete();
  }

  /// Drops the socket as if the network failed.
  void drop() {
    unawaited(close());
  }

  void push(Object? frame) {
    if (!_frames.isClosed) _frames.add(frame);
  }

  void pushItem(String streamId, Object? value) {
    push({'type': 'item', 'streamId': streamId, 'value': value});
  }

  void pushEnd(String streamId) {
    push({'type': 'end', 'streamId': streamId});
  }

  void pushError(String streamId, String code, String message) {
    push({
      'type': 'error',
      'streamId': streamId,
      'error': {
        'code': code,
        'message': message,
        'details': <String, Object?>{},
      },
    });
  }
}

/// Byte-level HTTP client double.
class FakeDshHttpClient implements DshHttpClient {
  FakeDshHttpClient({this.handler, this.onUpgrade});

  /// Returns the response for one exchange; defaults to an empty 200.
  Future<DshHttpResponse> Function(DshHttpRequest request)? handler;

  /// Builds the upgraded socket; defaults to a socket that answers ready.
  FakeDshSocket Function(DshHttpRequest request)? onUpgrade;

  final List<DshHttpRequest> requests = [];
  bool closed = false;

  @override
  Future<DshHttpResponse> send(DshHttpRequest request) async {
    requests.add(request);
    final custom = handler;
    if (custom != null) return custom(request);
    return const DshHttpResponse(
      statusCode: 200,
      headers: {'content-type': 'application/json'},
      setCookie: [],
      body: '{"ok":true,"value":{}}',
    );
  }

  @override
  Future<DshSocket> upgrade(DshHttpRequest request) async {
    requests.add(request);
    final custom = onUpgrade;
    if (custom != null) return custom(request);
    final socket = FakeDshSocket();
    socket.onSend = (frame) {
      if (frame is! Map || frame['type'] != 'open') return;
      socket.pushItem('${frame['streamId']}', {
        'type': 'ready',
        'clientId': 'client-1',
        'host': {'home': '/home/demo'},
      });
    };
    return socket;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

/// A full [DshTransport] double for RPC/mux/session/catalog tests.
///
/// * RPC responses come from [values] (ok), [remoteErrors] (ok:false) or
///   [statuses] (carrier rejection); unknown endpoints answer 404, which the
///   catalog reads as "capability absent".
/// * Mux sockets auto-answer each `open` frame with [streamOpening] items, and
///   `$events` with ready plus [hostFrames].
class FakeDshTransport implements DshTransport {
  FakeDshTransport({required this.endpoint, DshCookie? cookie}) {
    _cookie = cookie;
  }

  @override
  final DshEndpoint endpoint;

  DshCookie? _cookie;

  @override
  DshCookie? get cookie => _cookie;

  @override
  String get authority => endpoint.authority;

  @override
  bool get secure => endpoint.secure;

  /// endpoint -> business value.
  final Map<String, Object?> values = {};

  /// endpoint -> RemoteError (ok:false).
  final Map<String, DshRemoteException> remoteErrors = {};

  /// endpoint -> queued RemoteErrors consumed before [remoteErrors]/[values].
  final Map<String, List<DshRemoteException>> remoteErrorQueues = {};

  /// endpoint -> HTTP status to answer instead of 200.
  final Map<String, int> statuses = {};

  /// endpoint -> number of transport failures still to inject.
  final Map<String, int> transportFailures = {};

  /// endpoint -> items pushed after the `open` frame is seen.
  final Map<String, List<Object?>> streamOpening = {};

  final List<DshHttpRequest> requests = [];
  final List<Map<String, Object?>> posted = [];
  final List<FakeDshSocket> sockets = [];
  final List<String> openedEndpoints = [];

  /// Frames pushed first on `$events` (ready is added automatically).
  List<Object?> hostFrames = [];

  bool autoReady = true;
  bool verifySucceeds = true;

  /// Optional interceptor for RPC calls; return an error to answer with ok:false.
  Future<DshRemoteException?> Function(
    String endpoint,
    Map<String, Object?> envelope,
  )?
  interceptPost;

  /// Increments per ready handshake so reconnect tests can tell generations apart.
  int readyCount = 0;

  /// Errors thrown by [openMux] before it succeeds; used for auth/backoff tests.
  final List<DshException> openMuxFailures = [];
  int loginCalls = 0;
  String? lastLoginToken;
  bool closed = false;

  @override
  Future<DshCookie> login(String token) async {
    loginCalls += 1;
    lastLoginToken = token;
    final cookie = DshCookie(
      name: 'dsh-auth-test',
      value: 'v1.payload.signature',
      authority: endpoint.authority,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
    );
    _cookie = cookie;
    return cookie;
  }

  @override
  Future<void> verify() async {
    if (!verifySucceeds) {
      throw const DshAuthException('stored session rejected', statusCode: 401);
    }
  }

  @override
  void useCookie(DshCookie cookie) {
    if (cookie.authority != endpoint.authority) {
      throw DshEndpointException(
        'cookie bound to ${cookie.authority}',
        field: 'url',
      );
    }
    _cookie = cookie;
  }

  @override
  Future<DshHttpResponse> post(String endpoint, Object? envelope) async {
    final map = envelope is Map
        ? envelope.cast<String, Object?>()
        : <String, Object?>{};
    posted.add({'endpoint': endpoint, ...map});
    final failures = transportFailures[endpoint] ?? 0;
    if (failures > 0) {
      transportFailures[endpoint] = failures - 1;
      throw const DshTransportException(
        'injected transport failure',
        retryable: true,
      );
    }
    final status = statuses[endpoint];
    if (status != null) {
      return DshHttpResponse(
        statusCode: status,
        headers: const {},
        setCookie: const [],
        body: '{"error":"carrier"}',
      );
    }
    final rid = map['rpcId'];
    final interceptor = interceptPost;
    if (interceptor != null) {
      final intercepted = await interceptor(endpoint, map);
      if (intercepted != null) {
        return _json(200, {
          'type': 'server-response',
          'rpcId': rid,
          'result': {
            'ok': false,
            'error': {
              'code': intercepted.code,
              'message': intercepted.message,
              'details': intercepted.details,
            },
          },
        });
      }
    }
    final queued = remoteErrorQueues[endpoint];
    final error = (queued != null && queued.isNotEmpty)
        ? queued.removeAt(0)
        : remoteErrors[endpoint];
    if (error != null) {
      return _json(200, {
        'type': 'server-response',
        'rpcId': rid,
        'result': {
          'ok': false,
          'error': {
            'code': error.code,
            'message': error.message,
            'details': error.details,
          },
        },
      });
    }
    final value = values[endpoint];
    if (value == null && !values.containsKey(endpoint)) {
      return _json(404, '{"error":"not found"}');
    }
    return _json(200, {
      'type': 'server-response',
      'rpcId': rid,
      'result': {'ok': true, 'value': value},
    });
  }

  DshHttpResponse _json(int status, Object body) {
    return DshHttpResponse(
      statusCode: status,
      headers: const {'content-type': 'application/json'},
      setCookie: const [],
      body: body is String ? body : jsonEncode(body),
    );
  }

  @override
  Future<DshHttpResponse> get(Uri uri) async {
    return _json(200, '{"ok":true}');
  }

  @override
  Future<DshHttpResponse> postBytes(
    Uri uri,
    List<int> bytes, {
    required String contentType,
  }) async {
    requests.add(
      DshHttpRequest(
        method: 'POST',
        uri: uri,
        authority: endpoint.authority,
        body: bytes,
      ),
    );
    final receipt =
        values['session/uploadFileBinary'] ??
        {
          'receiptId': 'receipt-1',
          'file': {
            'attachmentId': 'sha256:00',
            'name': 'notes.txt',
            'bytes': bytes.length,
          },
        };
    return _json(200, {'ok': true, 'value': receipt});
  }

  @override
  Future<DshSocket> openMux() async {
    if (openMuxFailures.isNotEmpty) {
      throw openMuxFailures.removeAt(0);
    }
    final socket = FakeDshSocket();
    socket.onSend = (frame) => _handleOpen(socket, frame);
    sockets.add(socket);
    return socket;
  }

  void _handleOpen(FakeDshSocket socket, Object? frame) {
    if (frame is! Map || frame['type'] != 'open') return;
    final endpointName = frame['endpoint'];
    if (endpointName is! String) return;
    openedEndpoints.add(endpointName);
    final streamId = '${frame['streamId']}';
    scheduleMicrotask(() {
      if (socket.closed) return;
      if (endpointName == r'$events') {
        if (autoReady) {
          readyCount += 1;
          socket.pushItem(streamId, {
            'type': 'ready',
            'clientId': 'client-$readyCount',
            'host': {'home': '/home/demo'},
          });
        }
        for (final item in hostFrames) {
          socket.pushItem(streamId, item);
        }
      }
      for (final item in streamOpening[endpointName] ?? const <Object?>[]) {
        socket.pushItem(streamId, item);
      }
    });
  }

  @override
  Future<void> close({bool force = false}) async {
    closed = true;
    for (final socket in sockets) {
      await socket.close();
    }
  }
}

/// Marker used by tests to assert on uploaded bytes without exposing them.
Uint8List bytes(List<int> values) => Uint8List.fromList(values);
