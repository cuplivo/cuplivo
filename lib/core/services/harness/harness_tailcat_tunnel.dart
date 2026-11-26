import 'dart:async';
import 'dart:io';

import '../../models/harness_tailcat_endpoint.dart';
import 'harness_tailcat_dialer.dart';

/// How long a forwarded connection may wait for the tailcat dial.
///
/// The tunnel may need a DERP round trip and a NAT traversal attempt before its
/// first byte, which is why this is not an HTTP timeout: the WebView's request
/// is waiting on a connection that has not started carrying bytes yet.
const Duration kHarnessTailcatConnectTimeout = Duration(seconds: 45);

/// The remote-access tunnel of one DeepSeek Harness, as a loopback HTTP origin.
///
/// The ds-hu plugin publishes the Harness Web listener on a tailnet address,
/// and the embedded WebView cannot speak tailcat: it needs an HTTP origin. So
/// the app does what the plugin's instructions have a desktop client do with
/// `tailcat forward` — it listens on `127.0.0.1`, dials the peer through one
/// tailcat client, and copies bytes between each accepted socket and a tunnel
/// connection.
///
/// Byte copying, not an HTTP proxy, is deliberate: the Harness WebUI sets
/// cookies and upgrades to WebSockets, and both survive a raw pipe. The door
/// that answers the first `GET /` mints the cookie for whatever `Host` header
/// it sees, so serving this on loopback gives the WebView a plain
/// `http://127.0.0.1:<port>/` origin whose cookies belong to it alone.
class HarnessTailcatTunnel {
  HarnessTailcatTunnel._(
    this.localUri,
    this.connectTimeout,
    this._remotePort,
    this._server,
    this._dialer,
  );

  /// Opens [address]'s tunnel and starts accepting local connections.
  ///
  /// [dialerFactory] is the seam between the tunnel and libtailcat: production
  /// builds a client presenting this install's identity, tests build a fake.
  /// Throws [HarnessTailcatTunnelException] when the address is not one, the
  /// platform has no client, or loopback cannot be bound.
  static Future<HarnessTailcatTunnel> open(
    String address, {
    int remotePort = kHarnessTailcatDefaultPort,
    Duration connectTimeout = kHarnessTailcatConnectTimeout,
    required HarnessTailcatDialerFactory dialerFactory,
  }) async {
    if (!looksLikeHarnessTailcatAddress(address)) {
      throw const HarnessTailcatTunnelException(
        HarnessTailcatTunnelFailure.invalidAddress,
      );
    }
    if (remotePort < 1 || remotePort > 65535) {
      throw const HarnessTailcatTunnelException(
        HarnessTailcatTunnelFailure.invalidAddress,
      );
    }

    HarnessTailcatDialer? dialer;
    ServerSocket? server;
    try {
      dialer = await dialerFactory(address);
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    } catch (error) {
      await dialer?.close();
      if (error is HarnessTailcatTunnelException) rethrow;
      throw HarnessTailcatTunnelException(
        HarnessTailcatTunnelFailure.tunnelUnavailable,
        error,
      );
    }

    final tunnel = HarnessTailcatTunnel._(
      Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
      ),
      connectTimeout,
      remotePort,
      server,
      dialer,
    );
    server.listen(
      tunnel._accept,
      onError: (Object _) {
        // A failed accept drops that connection only; the listener stays up
        // and the next WebView request retries.
      },
    );
    return tunnel;
  }

  /// The loopback URL the embedded WebView loads.
  final Uri localUri;

  /// How long one forwarded connection may wait for its tailcat dial.
  final Duration connectTimeout;

  final int _remotePort;
  final ServerSocket _server;
  final HarnessTailcatDialer _dialer;

  /// Every socket still owned by a forwarded connection, so [close] can tear
  /// down connections whose pipes have not unwound yet.
  final Set<Socket> _open = <Socket>{};

  /// One entry per forwarded connection, completed when both directions have
  /// unwound: that is what ownership of a socket pair ends.
  final Set<Future<void>> _bridges = <Future<void>>{};
  bool _closed = false;

  /// Whether [close] has run.
  bool get isClosed => _closed;

  /// The remote peer port this tunnel forwards to.
  int get remotePort => _remotePort;

  void _accept(Socket local) {
    if (_closed) {
      local.destroy();
      return;
    }
    _open.add(local);
    unawaited(_relay(local));
  }

  Future<void> _relay(Socket local) async {
    Socket? remote;
    try {
      remote = await _dialer.connect(_remotePort).timeout(connectTimeout);
    } on TimeoutException {
      _drop(local);
      return;
    } catch (_) {
      _drop(local);
      return;
    }
    if (_closed) {
      remote.destroy();
      _drop(local);
      return;
    }
    _open.add(remote);
    final bridge =
        Future.wait(<Future<void>>[
          _pipeOneWay(local, remote),
          _pipeOneWay(remote, local),
        ]).whenComplete(() {
          // Both directions are done, so this pair is no longer owned here.
          _open.remove(local);
          _open.remove(remote);
        });
    _bridges.add(bridge);
    unawaited(bridge.whenComplete(() => _bridges.remove(bridge)));
  }

  void _drop(Socket socket) {
    _open.remove(socket);
    socket.destroy();
  }

  Future<void> _pipeOneWay(Socket from, Socket to) async {
    try {
      await to.addStream(from);
      // The source ended, so this direction has nothing more to say: closing
      // the sink sends FIN and lets the other direction drain its own bytes.
      await to.close();
    } catch (_) {
      from.destroy();
      to.destroy();
    }
  }

  /// Stops accepting and tears down every forwarded connection and the client.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    for (final socket in _open.toList(growable: false)) {
      socket.destroy();
    }
    _open.clear();
    await _dialer.close();
    // The destroyed sockets end every pipe; the timeout is only a guard so a
    // stream that refuses to unwind cannot hold up the page that closed us.
    await Future.wait<void>(
      _bridges.toList(growable: false),
    ).timeout(const Duration(seconds: 2), onTimeout: () => const <void>[]);
  }

  @override
  String toString() =>
      'HarnessTailcatTunnel(local: ${localUri.port}, '
      'remote: <redacted>:$remotePort)';
}
