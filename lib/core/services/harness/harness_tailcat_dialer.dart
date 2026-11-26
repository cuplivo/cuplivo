import 'dart:async';
import 'dart:io';

import 'package:libtailcat/libtailcat.dart';

import '../../models/harness_tailcat_endpoint.dart';

/// A failure while opening or relaying a tailcat tunnel.
enum HarnessTailcatTunnelFailure {
  /// The pasted text is not a tailcat address (or command).
  invalidAddress,

  /// This build has no tailcat client (a target the native library does not
  /// cover).
  unsupportedPlatform,

  /// The address is well-formed but the tunnel could not be established
  /// (DERP unreachable, peer offline, address rotated).
  tunnelUnavailable,
}

class HarnessTailcatTunnelException implements Exception {
  const HarnessTailcatTunnelException(this.failure, [this.cause]);

  final HarnessTailcatTunnelFailure failure;

  /// The underlying error, kept out of [toString] unless it can be redacted:
  /// tailcat errors name the address.
  final Object? cause;

  @override
  String toString() =>
      'HarnessTailcatTunnelException($failure, '
      '${cause == null ? 'no cause' : redactHarnessTailcatAddresses('$cause')})';
}

/// Opens TCP sockets to one tailcat peer.
///
/// The bindings sit behind this seam so the tunnel and its tests never touch
/// `dart:ffi`: the native implementation wraps one tailcat client, and unit
/// tests drive a fake. One dialer serves every forwarded connection of one
/// tunnel — the tailcat client keeps the relay/NAT state that makes the next
/// dial cheaper.
abstract interface class HarnessTailcatDialer {
  /// Opens one TCP connection to [port] on the peer.
  Future<Socket> connect(int port);

  /// Releases the client and its cached tunnel state.
  Future<void> close();
}

/// Builds the dialer for one tunnel.
///
/// Production supplies the install's stable identity so a server allow-list can
/// name it; tests supply a fake returning without `dart:ffi`. A future is
/// allowed because loading the persisted identity is I/O.
typedef HarnessTailcatDialerFactory =
    FutureOr<HarnessTailcatDialer> Function(String address);

/// Creates the production dialer for [address]: one libtailcat client that
/// presents [privateKey].
///
/// Throws [HarnessTailcatTunnelException] when the address turns out to be
/// malformed at the library level (the shape check before this only rejects
/// obvious non-addresses).
HarnessTailcatDialer createHarnessTailcatDialer(
  String address, {
  required TailcatPrivateKey privateKey,
}) {
  try {
    return _LibTailcatDialer(
      TailcatClient(
        TailcatClientConfig(
          address: TailcatAddress(address),
          privateKey: privateKey,
        ),
      ),
    );
  } on HarnessTailcatTunnelException {
    rethrow;
  } catch (error) {
    throw HarnessTailcatTunnelException(
      HarnessTailcatTunnelFailure.invalidAddress,
      error,
    );
  }
}

class _LibTailcatDialer implements HarnessTailcatDialer {
  _LibTailcatDialer(this._client);

  final TailcatClient _client;
  bool _closed = false;

  @override
  Future<Socket> connect(int port) => _client.connect(port: port);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _client.close(drain: false);
    } catch (_) {
      // Closing is best effort: the socket layer reports what mattered.
    }
  }
}
