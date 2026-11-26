import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/harness_tailcat_endpoint.dart';
import 'harness_connection_probe.dart';
import 'harness_http_cookies.dart';
import 'harness_tailcat_dialer.dart';
import 'harness_tailcat_tunnels.dart';

/// Proves a DeepSeek Harness reached the ds-hu remote-access way, by opening
/// its tunnel and loading the page through it — the same path the embedded
/// WebView takes.
///
/// The public-link probe has to redeem a token in three steps. Here the
/// credential is the tailnet address itself, and the door the plugin puts in
/// front of the Harness mints its cookie on the first bare `GET /`: a 303 with
/// `Set-Cookie`, then the WebUI's index page on the replayed cookie. Checking
/// both means "已连接" describes a tunnel that actually carries the WebUI, not
/// merely a dial that completed.
///
/// Failures are reported through the connection failure enum so the settings
/// page can show one message per cause without knowing which transport failed.
class HarnessTailcatProbe {
  HarnessTailcatProbe({
    required HarnessTailcatTunnels tunnels,
    this.timeout = const Duration(seconds: 60),
  }) : // Public injection name intentionally omits the private-field prefix
       // (same convention as HarnessConnectionProvider's dependencies).
       // ignore: prefer_initializing_formals
       _tunnels = tunnels;

  /// Bounds the whole exchange: the tailcat handshake itself may take tens of
  /// seconds, and a page that never answers must not leave the user waiting.
  final Duration timeout;

  final HarnessTailcatTunnels _tunnels;

  /// Proves that [rawInput] reaches the WebUI.
  ///
  /// [remotePort] is the stored peer port for a saved assistant, whose stored
  /// credential is the bare address; the settings page validates a freshly
  /// pasted pairing command without it, so the command's own port mapping
  /// wins there.
  Future<HarnessConnectionResult> check(
    String rawInput, {
    int? remotePort,
  }) async {
    final parsed = parseHarnessTailcatInput(rawInput);
    if (parsed == null) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.invalidTailcatAddress,
      );
    }
    final endpoint = remotePort == null
        ? parsed
        : HarnessTailcatEndpoint(address: parsed.address, port: remotePort);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      return await _exchange(client, endpoint).timeout(timeout);
    } on HarnessTailcatTunnelException catch (error) {
      return HarnessConnectionResult.failed(switch (error.failure) {
        HarnessTailcatTunnelFailure.invalidAddress =>
          HarnessConnectionFailure.invalidTailcatAddress,
        HarnessTailcatTunnelFailure.unsupportedPlatform =>
          HarnessConnectionFailure.tailcatUnsupported,
        HarnessTailcatTunnelFailure.tunnelUnavailable =>
          HarnessConnectionFailure.tailcatUnavailable,
      });
    } on TimeoutException {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.tailcatUnavailable,
      );
    } on SocketException {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.tailcatUnavailable,
      );
    } on HttpException {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.tailcatUnavailable,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<HarnessConnectionResult> _exchange(
    HttpClient client,
    HarnessTailcatEndpoint endpoint,
  ) async {
    final origin = await _tunnels.ensureOpen(
      endpoint.address,
      remotePort: endpoint.port,
    );
    // The tunnel serves the WebUI at the loopback origin's root; `origin`
    // itself carries no path.
    final uri = origin.replace(path: '/');
    final first = await _get(client, uri);
    final firstStatus = first.statusCode;
    final cookies = harnessResponseCookies(first);
    await first.drain<void>();

    if (_rejected(firstStatus)) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.rejected,
      );
    }
    if (firstStatus == HttpStatus.ok) {
      // A door that no longer needs the claim still serves the WebUI.
      return const HarnessConnectionResult.connected();
    }
    if (firstStatus != HttpStatus.seeOther &&
        firstStatus != HttpStatus.found &&
        firstStatus != HttpStatus.temporaryRedirect &&
        firstStatus != HttpStatus.permanentRedirect) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.apiUnavailable,
      );
    }

    // The claim: the door minted the WebUI cookie for this loopback origin.
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    final cookieHeader = harnessCookieHeader(cookies);
    if (cookieHeader != null) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    request.headers.set(HttpHeaders.acceptHeader, 'text/html');
    final second = await request.close();
    final status = second.statusCode;
    if (_rejected(status)) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.rejected,
      );
    }
    if (status != HttpStatus.ok) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.apiUnavailable,
      );
    }
    final body = await second.transform(utf8.decoder).join();
    if (body.trim().isEmpty) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.apiUnavailable,
      );
    }
    return const HarnessConnectionResult.connected();
  }

  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/json');
    return request.close();
  }

  static bool _rejected(int status) =>
      status == HttpStatus.unauthorized || status == HttpStatus.forbidden;
}
