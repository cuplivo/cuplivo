import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libtailcat/libtailcat.dart';

import 'sync_transport.dart';

/// How long the local relay waits for the tailcat dial to come up. The tunnel
/// may need a DERP round trip and a NAT traversal attempt before its first
/// byte, which is why this is not the LAN dial budget.
const Duration kTailcatTransportTimeout = Duration(seconds: 45);

/// How long an inbound tunnel connection waits for the LAN sync listener to
/// accept the relayed connection. Loopback only: it is milliseconds or the
/// listener is gone.
const Duration kTailcatRelayConnectTimeout = Duration(seconds: 10);

/// The remote half of sync (ADR-0020): a tailcat server whose address is this
/// device's remote address, plus the client side that dials other devices'
/// addresses.
///
/// The tailcat tunnel is a byte pipe, not the sync protocol: an inbound tunnel
/// connection is relayed to the existing LAN sync listener on loopback, and an
/// outbound remote endpoint is relayed into a tunnel. The TLS session, the
/// pinned certificate, the pairing secret and the protocol version are exactly
/// the LAN ones, so nothing above the socket knows the difference.
///
/// A remote session is reachable only while this service runs. It starts with
/// the app once a key file exists (the device has used remote sync before),
/// and on demand when the remote tab is opened for the first time.
class TailcatRemoteService {
  TailcatRemoteService({required this.directory});

  /// The sync directory the fixed key file lives in.
  ///
  /// Deliberately the same directory as the device identity: both are
  /// device-local secrets that must not leave through a backup, and the sync
  /// directory is already excluded from backups.
  final Directory directory;

  /// The client side, shared with [SyncClient] through the engine.
  final TailcatClientTransport transport = TailcatClientTransport();

  TailcatServer? _server;
  TailcatServerSocket? _listener;
  String? _address;
  bool _starting = false;
  String? _startError;
  Future<void>? _startFuture;
  int? _localSyncPort;

  /// Set by [stop]. A start that is already awaiting a relay round trip when
  /// the service stops must not resurrect the listener afterwards: the checks
  /// after each await close whatever it managed to open.
  bool _stopped = false;

  bool get isStarting => _starting;

  bool get isRunning => _server != null && _address != null;

  /// The address text clients dial, or null while stopped. Secret: reveal it
  /// only into the pairing dialog.
  String? get address => isRunning ? _address : null;

  /// The endpoint host peers store for this device, or null while stopped.
  String? get advertisedHost {
    final address = this.address;
    return address == null ? null : tailcatHost(address);
  }

  /// Why the last start attempt failed, or null.
  String? get startError => _startError;

  File get _identityFile =>
      File('${directory.path}${Platform.pathSeparator}tailcat-identity.json');

  /// Whether this device has ever started remote sync (its fixed keys exist).
  ///
  /// The app uses this to decide whether to bring the listener up at launch:
  /// a device that has paired remotely must be reachable without the user
  /// opening the remote tab first, while a device that never did should not pay
  /// for a relay registration on every launch.
  Future<bool> hasIdentity() => _identityFile.exists();

  /// Starts the server and its relay to [localSyncPort] (the LAN sync
  /// listener's bound port). Idempotent; concurrent callers share one attempt.
  Future<void> start({required int localSyncPort}) {
    final pending = _startFuture;
    if (pending != null) return pending;
    final future = _start(localSyncPort);
    _startFuture = future;
    return future.whenComplete(() {
      if (identical(_startFuture, future)) _startFuture = null;
    });
  }

  Future<void> _start(int localSyncPort) async {
    if (isRunning) {
      _localSyncPort = localSyncPort;
      return;
    }
    _starting = true;
    _startError = null;
    _stopped = false;
    _TailcatIdentity? identity;
    try {
      identity = await _loadOrCreateIdentity();
      if (_stopped) return;
      final server = await TailcatServer.start(
        TailcatServerConfig(
          privateKey: TailcatPrivateKey(identity.privateKey),
          presharedKey: TailcatPresharedKey(identity.presharedKey),
        ),
      );
      if (_stopped) {
        await server.close(drain: false);
        return;
      }
      _server = server;
      _address = server.address.reveal();
      _localSyncPort = localSyncPort;
      _listener = await server.listen(port: kTailcatRemotePort);
      if (_stopped) {
        await server.close(drain: false);
        return;
      }
      unawaited(_serve(_listener!));
      debugPrint('sync: tailcat remote listener is up');
    } catch (error) {
      final reason = _scrubError(error, identity);
      _startError = reason;
      debugPrint('sync: tailcat remote start failed: $reason');
      final server = _server;
      _server = null;
      _listener = null;
      _address = null;
      try {
        await server?.close(drain: false);
      } catch (_) {
        // The failure being reported is the start attempt's, not this cleanup's.
      }
      // The original exception can carry a key it tried to parse; the caller
      // and the panel get the scrubbed reason instead.
      throw StateError(reason);
    } finally {
      _starting = false;
    }
  }

  /// One-line failure reason that cannot carry a secret.
  ///
  /// `startError` is rendered by the remote panel, and a tailcat exception may
  /// echo the key or address it rejected. The device's own secrets are replaced
  /// with a placeholder; the type is kept so a bug report still says what kind
  /// of failure it was.
  String _scrubError(Object error, _TailcatIdentity? identity) {
    var text = '$error';
    for (final secret in [
      identity?.privateKey,
      identity?.presharedKey,
      _address,
    ]) {
      if (secret != null && secret.isNotEmpty) {
        text = text.replaceAll(secret, '<redacted>');
      }
    }
    return text;
  }

  /// Stops the server, its listener and every outbound tunnel. Idempotent.
  Future<void> stop() async {
    _stopped = true;
    final server = _server;
    _server = null;
    _listener = null;
    _address = null;
    _localSyncPort = null;
    try {
      await server?.close(drain: false);
    } catch (error) {
      debugPrint('sync: tailcat server close failed: $error');
    }
    await transport.close();
  }

  /// Replaces the fixed keys; the remote address changes.
  ///
  /// The caller is responsible for what that means to peers (their remote
  /// endpoints no longer reach this device): the service only owns the keys.
  Future<void> resetKeys({required int localSyncPort}) async {
    await stop();
    final file = _identityFile;
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('sync: unable to delete tailcat identity: $error');
    }
    await start(localSyncPort: localSyncPort);
  }

  Future<void> _serve(TailcatServerSocket listener) async {
    try {
      await for (final socket in listener) {
        unawaited(_relayInbound(socket));
      }
    } catch (error) {
      // A listener error is the listener ending (server close) or a rejected
      // connection; neither is a reason to tear down the service.
      debugPrint('sync: tailcat accept loop ended: $error');
    }
  }

  /// Relays one inbound tunnel connection to the LAN sync listener.
  ///
  /// The tunneled socket is just bytes: handing them to the loopback listener
  /// makes the existing HTTP/TLS server answer exactly as if the peer were on
  /// the LAN.
  Future<void> _relayInbound(Socket inbound) async {
    final port = _localSyncPort;
    if (port == null) {
      inbound.destroy();
      return;
    }
    Socket? local;
    try {
      local = await _connectLocalSyncListener(port);
    } catch (error) {
      debugPrint(
        'sync: tailcat relay could not reach the LAN listener: $error',
      );
      inbound.destroy();
      return;
    }
    _pipeSockets(inbound, local);
  }

  /// Connects to the LAN sync listener on loopback.
  ///
  /// Both loopbacks are tried because the listener prefers an IPv6 bind and
  /// falls back to IPv4: the relay must follow whichever one actually bound.
  Future<Socket> _connectLocalSyncListener(int port) async {
    SocketException? last;
    for (final address in [
      InternetAddress.loopbackIPv4,
      InternetAddress.loopbackIPv6,
    ]) {
      try {
        return await Socket.connect(
          address,
          port,
          timeout: kTailcatRelayConnectTimeout,
        );
      } on SocketException catch (error) {
        last = error;
      }
    }
    throw last ?? const SocketException('sync listener unreachable');
  }

  Future<_TailcatIdentity> _loadOrCreateIdentity() async {
    final file = _identityFile;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final privateKey = decoded['privateKey'];
          final presharedKey = decoded['presharedKey'];
          if (privateKey is String &&
              privateKey.isNotEmpty &&
              presharedKey is String &&
              presharedKey.isNotEmpty) {
            return _TailcatIdentity(
              privateKey: privateKey,
              presharedKey: presharedKey,
            );
          }
        }
        debugPrint('sync: tailcat identity is malformed; replacing it');
      } catch (_) {
        // Deliberately not the exception: a `FormatException` from
        // `jsonDecode` carries the file text — the private key — as its source,
        // and this log is not the place for it.
        debugPrint('sync: tailcat identity is unreadable; replacing it');
      }
      // A malformed identity cannot be repaired into the old address: the
      // keys are the address. Minting a new one is the only way to a working
      // listener, and peers are told exactly what a reset means in the panel.
      try {
        await file.delete();
      } catch (_) {
        // The write below still fails loudly if the file cannot be replaced.
      }
    }
    final keys = TailcatKeys.generate();
    final identity = _TailcatIdentity(
      privateKey: keys.privateKey.reveal(),
      presharedKey: keys.presharedKey.reveal(),
    );
    await directory.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'privateKey': identity.privateKey,
        'presharedKey': identity.presharedKey,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
    return identity;
  }
}

class _TailcatIdentity {
  const _TailcatIdentity({
    required this.privateKey,
    required this.presharedKey,
  });

  final String privateKey;
  final String presharedKey;
}

/// The client half of the tunnel: turns a remote peer's stored endpoint into a
/// real socket through [TailcatClient].
class TailcatClientTransport implements SyncTransport {
  /// The URI host each address is dialed under, and the inverse.
  ///
  /// An address cannot be used as-is: `Uri.host` lowercases its host (host
  /// names are case-insensitive), while the address text is base64url and
  /// therefore case-sensitive. Dialing the lowercased form would dial a
  /// different address. The transport remembers the lowercase-to-original
  /// mapping instead; on the vanishingly unlikely two-addresses-same-lowercase
  /// collision it disambiguates the second with a suffix rather than collapsing
  /// them into one tunnel.
  final Map<String, String> _hostByAddress = <String, String>{};
  final Map<String, String> _addressByHost = <String, String>{};

  /// One client per address: the tunnel and its NAT traversal state are worth
  /// keeping for the next session, and a dial creates them either way.
  final Map<String, TailcatClient> _clients = <String, TailcatClient>{};

  @override
  SyncUriEndpoint uriEndpointFor(String host, int port) {
    final address = tailcatAddressFromHost(host);
    if (address == null) return (host: host, port: port);
    return (host: _uriHostFor(address), port: kTailcatRemotePort);
  }

  /// The address [uriHost] names, or null when it is not one of this
  /// transport's remote hosts.
  @visibleForTesting
  String? remoteAddressForUriHost(String uriHost) => _addressByHost[uriHost];

  String _uriHostFor(String address) {
    final cached = _hostByAddress[address];
    if (cached != null) return cached;
    final lower = address.toLowerCase();
    var candidate = lower;
    var suffix = 0;
    while (_addressByHost.containsKey(candidate) &&
        _addressByHost[candidate] != address) {
      suffix++;
      candidate = '$lower~$suffix';
    }
    _hostByAddress[address] = candidate;
    _addressByHost[candidate] = address;
    return candidate;
  }

  @override
  Future<ConnectionTask<Socket>> Function(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  )
  get connectionFactory => _connect;

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final address = _addressByHost[uri.host];
    if (address == null) {
      // Only a URI the sync client did not build (a redirect, or a request that
      // outlived [close]) can get here: there is no tunnel to dial, and the URI
      // host is a redacted placeholder now, so name no host in the error.
      throw const SocketException('remote endpoint is not resolved');
    }
    return _openTunnel(address, uri.port);
  }

  /// Opens a loopback pipe whose other end is the tailcat tunnel to [address].
  ///
  /// The sync client sees an ordinary socket and performs its own TLS handshake
  /// over it (`HttpClient.connectionFactory` sockets are not wrapped by the
  /// client); the peer's server terminates that handshake exactly as it does on
  /// the LAN. TLS therefore stays end-to-end between the two sync servers while
  /// the bytes cross the tunnel.
  Future<ConnectionTask<Socket>> _openTunnel(String address, int port) async {
    final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Socket? local;
    Socket? tunneled;
    try {
      local = await Socket.connect(
        InternetAddress.loopbackIPv4,
        relay.port,
        timeout: kTailcatRelayConnectTimeout,
      );
      tunneled = await relay.first.timeout(kTailcatRelayConnectTimeout);
      unawaited(relay.close());
      final client = _clientFor(address);
      final tunnel = await client.connect(
        port: port,
        timeout: kTailcatTransportTimeout,
      );
      _pipeSockets(tunneled, tunnel);
      tunneled = tunnel;
      final socket = local;
      return ConnectionTask.fromSocket(Future<Socket>.value(socket), () {
        socket.destroy();
        tunnel.destroy();
      });
    } catch (error) {
      tunneled?.destroy();
      local?.destroy();
      unawaited(relay.close());
      rethrow;
    }
  }

  TailcatClient _clientFor(String address) {
    final existing = _clients[address];
    if (existing != null && !existing.isClosed) return existing;
    final client = TailcatClient(
      TailcatClientConfig(address: TailcatAddress(address)),
    );
    _clients[address] = client;
    return client;
  }

  /// Closes every tunnel. Called when remote sync stops: the sessions they were
  /// carrying are gone with the listener anyway.
  Future<void> close() async {
    final clients = _clients.values.toList(growable: false);
    _clients.clear();
    _hostByAddress.clear();
    _addressByHost.clear();
    for (final client in clients) {
      try {
        await client.close(drain: false);
      } catch (error) {
        debugPrint('sync: tailcat client close failed: $error');
      }
    }
  }
}

/// Runs a byte pipe in both directions until either side ends.
///
/// Deliberately two [IOSink.addStream] calls and not two `listen`/`add` pumps:
/// `add` never applies backpressure, and a relay that ignores a slow peer would
/// buffer a whole push — the sync body cap is 256 MB — in memory on a phone
/// before the socket drains. `addStream` pauses the source while the
/// destination cannot take more, so a relayed transfer uses the same bounded
/// buffering as a direct one.
void _pipeSockets(Socket a, Socket b) {
  unawaited(_pipeOneWay(a, b));
  unawaited(_pipeOneWay(b, a));
}

Future<void> _pipeOneWay(Socket from, Socket to) async {
  try {
    await to.addStream(from);
    // The source ended, so this direction has nothing more to say: closing the
    // sink sends FIN and lets the other direction drain its own bytes.
    await to.close();
  } catch (_) {
    from.destroy();
    to.destroy();
  }
}
