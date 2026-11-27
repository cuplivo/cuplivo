/// The tailcat address the ds-hu remote-access plugin hands out, and the
/// parsing rules for the text a user pastes to reach a DeepSeek Harness that
/// way.
///
/// This lives with the models rather than with the tunnel so the assistant
/// model and the WebUI/settings surfaces can validate and store the address
/// without importing `dart:io` or the native client.
library;

/// The port the remote-access plugin maps inside the tailnet.
///
/// The plugin serves DSH's own Web listener over a `tailcat serve` tunnel on
/// this virtual port (`port` in its config, `13080` by default), and the client
/// side reaches it with `tailcat forward <address> <local>:13080`. Cuplivo does
/// that forward in-process, so this is the peer port every tailcat connection
/// dials unless the pairing command named another one.
const int kHarnessTailcatDefaultPort = 13080;

/// The tailcat address length floor, in characters.
///
/// A tailcat address is `tc` followed by an opaque base64url-ish encoding; the
/// real ones are 150+ characters. The floor only rejects text that cannot be
/// one (a truncated paste); the authoritative parser is the tailcat library.
const int kHarnessTailcatMinAddressLength = 16;

/// The longest address text worth trying to parse, in characters.
const int kHarnessTailcatMaxAddressLength = 2048;

final RegExp _tailcatAddressShape = RegExp(r'^tc[A-Za-z0-9_\-+=.~]+$');

/// One address/port pair a pasted tailcat input describes.
class HarnessTailcatEndpoint {
  const HarnessTailcatEndpoint({required this.address, required this.port});

  /// The tailcat address of the peer, without surrounding command text.
  final String address;

  /// The peer port to dial through the tunnel.
  final int port;

  @override
  bool operator ==(Object other) =>
      other is HarnessTailcatEndpoint &&
      other.address == address &&
      other.port == port;

  @override
  int get hashCode => Object.hash(address, port);

  @override
  String toString() =>
      'HarnessTailcatEndpoint(port: $port, address: <redacted>)';
}

/// Whether [token] can be a tailcat address.
bool looksLikeHarnessTailcatAddress(String token) {
  final length = token.length;
  if (length < kHarnessTailcatMinAddressLength ||
      length > kHarnessTailcatMaxAddressLength) {
    return false;
  }
  return _tailcatAddressShape.hasMatch(token);
}

/// Parses what the user pasted into the tailcat field.
///
/// The plugin's pairing page offers a bare address *and* a ready-to-run
/// `tailcat forward <address> <local>:<remote>` command, and people copy
/// whichever is closer to hand. Both are accepted: the address is the first
/// token that has the address shape, and the peer port is taken from the
/// command's port mapping when there is one. A bare address keeps the plugin's
/// default port.
///
/// Returns `null` when no token can be an address — the caller reports the
/// invalid input instead of dialing something malformed.
HarnessTailcatEndpoint? parseHarnessTailcatInput(String raw) {
  final tokens = raw
      .trim()
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
  if (tokens.isEmpty) return null;
  String? address;
  var addressIndex = -1;
  for (var i = 0; i < tokens.length; i++) {
    // Argument tokens may carry shell punctuation around the address when a
    // command is pasted with quotes; the address itself never does.
    final candidate = tokens[i].replaceAll(RegExp(r'''^["']+|["']+$'''), '');
    if (looksLikeHarnessTailcatAddress(candidate)) {
      address = candidate;
      addressIndex = i;
      break;
    }
  }
  if (address == null) return null;

  var port = kHarnessTailcatDefaultPort;
  for (final token in tokens.skip(addressIndex + 1)) {
    final parsed = _portOfMapping(token);
    if (parsed != null) {
      port = parsed;
      break;
    }
  }
  return HarnessTailcatEndpoint(address: address, port: port);
}

/// The peer port named by one `tailcat forward` port argument, if it names one.
///
/// Accepts `local:remote` and `local:host:remote`; a single port is both ends.
int? _portOfMapping(String token) {
  final parts = token.split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  int? portOf(String part) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 65535) return null;
    return value;
  }

  int? remote;
  switch (parts.length) {
    case 1:
      remote = portOf(parts[0]);
    case 2:
      remote = portOf(parts[1]);
    case 3:
      // `local:host:remote` names an exit node by host; only the ports are
      // numeric, so the middle part is deliberately not parsed as one.
      if (portOf(parts[0]) == null) return null;
      remote = portOf(parts[2]);
  }
  if (remote == null || remote < 1) return null;
  return remote;
}

/// Replaces every tailcat address in [text] with a redacted placeholder.
///
/// A tailcat address is a credential: whoever holds it can open the plugin's
/// door. Diagnostics (log lines, exception text) therefore go through this
/// before they are printed or shown to a third party.
String redactHarnessTailcatAddresses(String text) =>
    text.replaceAll(RegExp(r'tc[A-Za-z0-9_\-+=.~]{16,2048}'), 'tc<redacted>');
