import 'dart:async';
import 'dart:io';

/// The port a remote sync device's tailcat listener accepts tunnels on.
///
/// Every device listens on the same number: a tunnel is addressed by the
/// device's tailcat address, not by the listener port, so no two devices can
/// collide and the port is a protocol constant rather than a setting.
const int kTailcatRemotePort = 9527;

/// The prefix that marks a peer endpoint's host as a tailcat address instead
/// of a network address.
///
/// The marker lives in the persisted endpoint itself rather than in a side
/// table: it has to survive restarts with the rest of the peer record, and a
/// peer that moves between networks keeps its LAN and remote memories in the
/// same endpoint list.
const String kTailcatHostPrefix = 'tcat:';

/// The endpoint host that names [address] for the sync transport — the stored
/// form remote pairing advertises and remembers.
String tailcatHost(String address) => '$kTailcatHostPrefix$address';

/// Whether [host] is a tailcat remote endpoint rather than a network address.
bool isTailcatEndpointHost(String host) => host.startsWith(kTailcatHostPrefix);

/// The tailcat address inside a [tailcatHost] endpoint, or null for a LAN one.
String? tailcatAddressFromHost(String host) => isTailcatEndpointHost(host)
    ? host.substring(kTailcatHostPrefix.length)
    : null;

/// Strips whitespace a pasted address may carry: phone keyboards and chat
/// clients insert newlines and spaces mid-string, and neither is part of the
/// encoding.
String normalizeTailcatAddress(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), '');

/// Whether [raw] can be a tailcat address text.
///
/// Deliberately permissive about the alphabet — the address is an opaque
/// encoding owned by tailcat, and the authoritative parser is
/// `TailcatAddress.parse()`. This only rules out values that cannot be a URI
/// reg-name (the sync client puts the address in a URL host) or that are
/// obviously truncated, so the pair dialog can say "that doesn't look like an
/// address" before a tunnel dial times out.
bool looksLikeTailcatAddress(String raw) {
  final address = normalizeTailcatAddress(raw);
  if (address.length < 16 || address.length > 2048) return false;
  return RegExp(r'^[A-Za-z0-9_\-+=.~]+$').hasMatch(address);
}

/// The port an endpoint host implies.
///
/// A tailcat endpoint's port is the protocol constant, not the peer's sync
/// listener port: the tunnel is addressed by the address, so remembering a
/// per-device port for one would create duplicate endpoints for the same
/// address and outlive a port change. LAN hosts keep [fallback] (the port the
/// peer advertised with this address).
int endpointPortForHost(String host, int fallback) =>
    isTailcatEndpointHost(host) ? kTailcatRemotePort : fallback;

/// A host safe to put in a log line or a progress label.
///
/// A tailcat endpoint's host is the device's address text, which is a secret
/// (it is the capability to reach the device). Diagnostics name its kind and
/// never the value; the marker prefix is kept so a reader can still tell the
/// endpoint is remote.
String redactEndpointHost(String host) =>
    isTailcatEndpointHost(host) ? '${kTailcatHostPrefix}remote' : host;

/// The URI endpoint a stored peer endpoint corresponds to.
typedef SyncUriEndpoint = ({String host, int port});

/// The seam between the LAN sync client (ADR-0003) and the tailcat tunnel
/// (ADR-0020).
///
/// The sync client keeps speaking HTTPS to `host:port`; a remote endpoint is
/// the one case whose stored host is not a network address. The transport maps
/// that host to a URI host a `HttpClient` accepts (the opaque tailcat address,
/// which is a legal reg-name) and supplies a `connectionFactory` that dials a
/// tunnel instead of a direct socket. The sync client then completes the TLS
/// handshake over that socket itself, because dart:io does not wrap a
/// `connectionFactory` socket in TLS. Everything above the socket — the pinned
/// certificate, the pairing secret, the protocol version — is unchanged, so a
/// remote session is exactly a LAN session with a different pipe underneath.
abstract interface class SyncTransport {
  /// The endpoint an HTTP client should dial for a stored peer endpoint. LAN
  /// endpoints come back unchanged; a tailcat one becomes its address on
  /// [kTailcatRemotePort].
  SyncUriEndpoint uriEndpointFor(String host, int port);

  /// The factory that turns a remote URI into a tunneled **plain** socket.
  ///
  /// Only clients created for a remote endpoint set this; LAN clients keep the
  /// plain `HttpClient` the sync code has always used. The socket this returns
  /// is not TLS-terminated: the sync client establishes TLS over it, since a
  /// `HttpClient` does not do that when a `connectionFactory` is installed.
  Future<ConnectionTask<Socket>> Function(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  )
  get connectionFactory;
}
