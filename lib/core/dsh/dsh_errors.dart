/// Typed failures raised by the DeepSeek Harness protocol client.
///
/// Two questions a caller must be able to answer without reading the wire:
///
/// * is the *pipe* broken ([DshTransportException], [DshAuthException]) — a
///   reconnect, a fresh launch token or a retry can fix it; or
/// * did the *Host* answer ([DshRemoteException], [DshUnsupportedException]) —
///   show the business error or hide the capability.
///
/// [DshProtocolException] means the client cannot interpret what arrived: a bug
/// or a newer/older protocol, never something to retry in a loop.
library;

/// Base of every failure this client throws. No raw socket/JSON exceptions
/// cross the client boundary.
sealed class DshException implements Exception {
  const DshException(this.message);

  /// Human-readable diagnostic. Safe to log; never contains a credential.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The pasted WebUI URL or launch token cannot be used.
///
/// Raised by endpoint parsing before any network operation; show it next to the
/// connection form field named by [field].
final class DshEndpointException extends DshException {
  const DshEndpointException(super.message, {this.field});

  /// `'url'` or `'token'`.
  final String? field;

  @override
  String toString() => 'DshEndpointException(${field ?? 'url'}): $message';
}

/// The carrier refused this peer: HTTP 401/403 (and 409 on the mux upgrade).
///
/// The cookie is missing, expired, bound to another authority, or the Host does
/// not trust this address (`--trusted-host`). Retrying with the same cookie
/// cannot succeed: ask the user for a fresh WebUI URL.
final class DshAuthException extends DshException {
  const DshAuthException(super.message, {this.statusCode});

  final int? statusCode;

  @override
  String toString() => 'DshAuthException(${statusCode ?? '?'}): $message';
}

/// The Host answered `result.ok: false`, or a logical stream ended with an
/// `error` frame.
///
/// [code] is the stable contract (for example `session/not-found`,
/// `gateway/arguments-invalid`, `settings/conflict`); branch on it, not on
/// [message], which is diagnostic English. [details] is the per-code object.
final class DshRemoteException extends DshException {
  const DshRemoteException(this.code, super.message, [this.details = const {}]);

  final String code;
  final Map<String, Object?> details;

  /// Failures owned by the Remote gateway rather than a domain service.
  bool get isGatewayError => code.startsWith('gateway/');

  /// The addressed entity (session, workspace, job, …) does not exist.
  bool get isNotFound => code.endsWith('/not-found');

  /// The client sent the wrong argument names/shape — always a client bug.
  bool get isBadRequest =>
      code == 'gateway/arguments-invalid' ||
      code == 'gateway/input-invalid' ||
      code == 'gateway/bad-request' ||
      code == 'gateway/protocol';

  @override
  String toString() => 'DshRemoteException($code): $message';
}

/// DNS, TCP, TLS, timeout, or a lost WebSocket.
///
/// [retryable] is true when retrying the operation may succeed (the usual case
/// for a network fault and for a lost mux generation).
final class DshTransportException extends DshException {
  const DshTransportException(
    super.message, {
    this.cause,
    this.retryable = true,
  });

  final Object? cause;
  final bool retryable;
}

/// The client could not interpret a response: bad envelope, mismatched `rpcId`,
/// malformed frame. Log it, fail the operation, do not loop.
final class DshProtocolException extends DshException {
  const DshProtocolException(super.message);
}

/// The endpoint is not mounted on this DSH version (HTTP 404 `not found`).
///
/// Capability parity: hide the corresponding control instead of failing the
/// surface. [DshCatalog.supports] caches this per connection.
final class DshUnsupportedException extends DshException {
  const DshUnsupportedException(this.endpoint)
    : super('The Host does not expose $endpoint');

  final String endpoint;

  @override
  String toString() => 'DshUnsupportedException($endpoint)';
}

/// The caller closed the client, the stream, or the session.
final class DshClosedException extends DshException {
  const DshClosedException([super.message = 'closed']);
}
