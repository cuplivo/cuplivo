/// Typed unary Remote calls: `POST /api/<endpoint>` with the DSH envelope.
///
/// Wire form (0.2.2-rc.1):
///
/// ```text
/// -> {"type":"client-request","rpcId":"<uuid>","method":"session/list",
///     "payload":{"args":{"_request":{}}}}
/// <- 200 {"type":"server-response","rpcId":"<uuid>",
///         "result":{"ok":true,"value":{…}}}
/// <- 200 {"type":"server-response","rpcId":"<uuid>",
///         "result":{"ok":false,"error":{"code","message","details":{…}}}}
/// ```
///
/// A business failure is an HTTP 200 with `ok:false`; a carrier rejection is a
/// 4xx status (mapped by [httpStatusException]). The two never get confused.
library;

import 'dart:async';
import 'dart:math';

import 'dsh_errors.dart';
import 'dsh_models.dart' show jsonMap, tryDecodeJson;
import 'dsh_transport.dart';

/// RFC 4122 version-4 UUID used for rpc ids, stream ids and prompt request ids.
String dshUuidV4() {
  final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final Random _secureRandom = Random.secure();

/// Sends one endpoint request at a time; safe to call concurrently.
class DshRpc {
  DshRpc(this.transport, {this.timeout = const Duration(seconds: 30)});

  final DshTransport transport;

  /// Default budget per call. A call that is expected to be slow passes its own.
  final Duration timeout;

  /// Calls `endpoint` with `args` and returns the business `value`.
  ///
  /// [idempotent] retries once on a retryable transport failure. Use it for
  /// reads (`list`, `page`, `state`, `modelCatalog`, `describe`, …) and never
  /// for `session/prompt` (the inbox admission may have landed).
  Future<Object?> call(
    String endpoint, {
    Map<String, Object?> args = const {},
    Duration? timeout,
    bool idempotent = false,
  }) {
    Future<Object?> attempt() =>
        _attempt(endpoint, args, timeout ?? this.timeout);
    if (!idempotent) return attempt();
    return attempt().catchError((Object error) async {
      if (error is DshTransportException && error.retryable) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return attempt();
      }
      throw error;
    });
  }

  Future<Object?> _attempt(
    String endpoint,
    Map<String, Object?> args,
    Duration budget,
  ) async {
    final rpcId = dshUuidV4();
    final envelope = <String, Object?>{
      'type': 'client-request',
      'rpcId': rpcId,
      'method': endpoint,
      'payload': {'args': args},
    };

    final DshHttpResponse response;
    try {
      response = await transport.post(endpoint, envelope).timeout(budget);
    } on TimeoutException catch (error) {
      throw DshTransportException(
        'The Host did not answer $endpoint in time',
        cause: error,
      );
    }
    if (response.statusCode != 200) {
      throw httpStatusException(
        response.statusCode,
        endpoint,
        body: response.body,
      );
    }
    if (response.body.trim().isEmpty) {
      throw DshProtocolException('Empty response body from $endpoint');
    }

    final decoded = tryDecodeJson(response.body);
    if (decoded is! Map) {
      throw DshProtocolException('Non-object response from $endpoint');
    }
    final map = jsonMap(decoded);
    if (map['type'] != 'server-response') {
      throw DshProtocolException(
        'Unexpected response type "${map['type']}" from $endpoint',
      );
    }
    final responseId = map['rpcId'];
    if (responseId is String &&
        responseId != rpcId &&
        responseId != 'invalid-request') {
      throw DshProtocolException(
        'Response rpcId does not match the request (${map['rpcId']} != $rpcId)',
      );
    }
    final result = map['result'];
    if (result is! Map) {
      throw DshProtocolException('Missing result envelope from $endpoint');
    }
    final resultMap = jsonMap(result);
    if (resultMap['ok'] == true) {
      return resultMap['value'];
    }
    final error = resultMap['error'];
    if (error is Map) {
      final errorMap = jsonMap(error);
      throw DshRemoteException(
        errorMap['code'] is String
            ? errorMap['code']! as String
            : 'gateway/internal',
        errorMap['message'] is String
            ? errorMap['message']! as String
            : 'The Host rejected $endpoint',
        jsonMap(errorMap['details']),
      );
    }
    throw DshProtocolException(
      'The Host answered $endpoint without a value or an error',
    );
  }
}
