import 'dart:async';

import '../../models/harness_tailcat_endpoint.dart';
import 'harness_tailcat_dialer.dart';
import 'harness_tailcat_tunnel.dart';

/// The lifespan of every tailcat tunnel the app currently has open, one per
/// remote-access assistant address.
///
/// A tunnel is expensive to build (a DERP round trip, then path discovery) and
/// cheap to keep, so it outlives one WebView visit: the settings page probes it,
/// the WebUI page loads through it, and reopening the WebUI does not pay the
/// handshake again. It is closed when the assistant stops using the address
/// ([prune]), when that address changes ([ensureOpen] with a new port closes the
/// old tunnel first), or when the app leaves.
///
/// The manager deliberately owns no connection state: [HarnessConnectionProbe]
/// results are the answer to "is it connected", while this map is only "what is
/// running".
class HarnessTailcatTunnels {
  HarnessTailcatTunnels({HarnessTailcatDialer Function(String address)? dialer})
    : _dialerFactory = dialer;

  /// Test seam: the dialer a new tunnel should use (production: libtailcat).
  final HarnessTailcatDialer Function(String address)? _dialerFactory;

  final Map<String, HarnessTailcatTunnel> _open =
      <String, HarnessTailcatTunnel>{};
  final Map<String, Future<HarnessTailcatTunnel>> _opening =
      <String, Future<HarnessTailcatTunnel>>{};
  bool _closed = false;

  /// Makes sure a live tunnel exists for [address], and returns its loopback
  /// HTTP origin.
  ///
  /// Concurrent callers for the same address share one handshake. A failure is
  /// not cached: the next call retries, because the usual causes (the peer was
  /// offline for a moment, the phone had no network) are transient.
  Future<Uri> ensureOpen(
    String address, {
    int remotePort = kHarnessTailcatDefaultPort,
  }) async {
    if (_closed) {
      throw const HarnessTailcatTunnelException(
        HarnessTailcatTunnelFailure.tunnelUnavailable,
      );
    }
    if (!looksLikeHarnessTailcatAddress(address)) {
      throw const HarnessTailcatTunnelException(
        HarnessTailcatTunnelFailure.invalidAddress,
      );
    }

    final existing = _open[address];
    if (existing != null &&
        !existing.isClosed &&
        existing.remotePort == remotePort) {
      return existing.localUri;
    }
    final opening = _opening[address];
    if (opening != null) {
      final tunnel = await opening;
      if (tunnel.remotePort == remotePort) return tunnel.localUri;
    }

    await closeAddress(address);
    final future = HarnessTailcatTunnel.open(
      address,
      remotePort: remotePort,
      dialerFactory: _dialerFactory,
    );
    _opening[address] = future;
    try {
      final tunnel = await future;
      if (_closed) {
        await tunnel.close();
        throw const HarnessTailcatTunnelException(
          HarnessTailcatTunnelFailure.tunnelUnavailable,
        );
      }
      _open[address] = tunnel;
      return tunnel.localUri;
    } finally {
      if (identical(_opening[address], future)) _opening.remove(address);
    }
  }

  /// The loopback origin of an already open tunnel, for surfaces that only
  /// render a link; `null` until [ensureOpen] succeeded.
  Uri? localUriFor(String address) => _open[address]?.localUri;

  /// Closes [address]'s tunnel, if one is open or opening.
  Future<void> closeAddress(String address) async {
    final opening = _opening.remove(address);
    if (opening != null) {
      unawaited(opening.then((tunnel) => tunnel.close(), onError: (_) {}));
    }
    final tunnel = _open.remove(address);
    if (tunnel != null) await tunnel.close();
  }

  /// Closes every tunnel whose address is not in [liveAddresses].
  ///
  /// Called when the assistant list changes: an edited or deleted assistant
  /// must not leave a client and its DERP connection running for an address
  /// nothing can open any more.
  Future<void> prune(Set<String> liveAddresses) async {
    final stale = <String>{
      ..._open.keys,
      ..._opening.keys,
    }.where((address) => !liveAddresses.contains(address)).toList();
    await Future.wait(<Future<void>>[
      for (final address in stale) closeAddress(address),
    ]);
  }

  /// Closes every tunnel. Called when the app leaves the foreground for good.
  Future<void> closeAll() async {
    _closed = true;
    final addresses = <String>{..._open.keys, ..._opening.keys};
    for (final address in addresses) {
      await closeAddress(address);
    }
  }
}
