import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_client/mcp_client.dart' as mcp;

import 'oauth_loopback_server.dart';

/// Result of [OAuthFlowService.beginFlow].
///
/// When [loopbackCallbackUrl] is non-null the flow runs in AUTO mode: the
/// browser will redirect back to the app and no paste is needed. When null
/// the flow runs in MANUAL mode (fallback): the user pastes the code.
///
/// [discoveredAuthorizationEndpoint], [discoveredTokenEndpoint] and
/// [discoveredClientId] are non-null when the flow auto-filled those values
/// (RFC 8414 discovery / RFC 7591 dynamic client registration); the caller
/// persists them so the next run starts fully configured.
class OAuthFlowStartResult {
  final Uri authorizationUrl;

  /// Non-null when the flow is waiting for a loopback callback.
  final Uri? loopbackCallbackUrl;
  final bool usedDiscovery;
  final bool usedDcr;
  final String? discoveredAuthorizationEndpoint;
  final String? discoveredTokenEndpoint;
  final String? discoveredClientId;

  const OAuthFlowStartResult({
    required this.authorizationUrl,
    this.loopbackCallbackUrl,
    this.usedDiscovery = false,
    this.usedDcr = false,
    this.discoveredAuthorizationEndpoint,
    this.discoveredTokenEndpoint,
    this.discoveredClientId,
  });
}

/// A single in-memory OAuth authorization session (PKCE verifier + CSRF
/// state). Holds the library OAuth client so the code verifier survives
/// from URL generation to code exchange.
class OAuthFlowSession {
  final String key;
  final mcp.HttpOAuthClient client;
  final String state;
  final OAuthLoopbackServer? loopbackServer;

  /// The redirect URI sent with the authorize request; must be repeated in
  /// the token exchange unless it is OOB-style.
  final String? actualRedirectUri;

  /// Set when an in-flight automatic callback wait is overridden by a
  /// pasted code (see [OAuthFlowService.completeFlow]). The overridden
  /// waiter exits silently instead of surfacing a timeout error.
  bool interrupted = false;

  OAuthFlowSession({
    required this.key,
    required this.client,
    required this.state,
    this.loopbackServer,
    this.actualRedirectUri,
  });
}

/// Provider-agnostic OAuth 2.1 authorization flow orchestration.
///
/// AUTO mode (default): the flow discovers the authorization server metadata
/// (RFC 8414) when endpoints are missing, registers a public client (RFC
/// 7591) when no client ID is set, and starts a loopback server so the
/// browser redirect lands back in the app. The user only logs in and clicks
/// allow.
///
/// MANUAL mode (fallback): when discovery/registration/loopback is
/// unavailable, the app returns the authorization URL and the user pastes
/// the code back (raw code or full redirect URL, CSRF `state` validated).
///
/// Flow state lives in memory only — an app restart mid-flow invalidates the
/// session and the user restarts the flow. Deliberate v1 trade-off (see
/// `docs/adr/0015-mcp-oauth-auto-flow.md`).
class OAuthFlowService {
  final Map<String, OAuthFlowSession> _sessions = {};
  final Set<String> _inFlight = {};
  final http.Client Function() _clientFactory;

  /// Loopback redirect URI used at client registration (RFC 8252 portless
  /// forms). Both `127.0.0.1` and `localhost` variants are registered so the
  /// authorization redirect can use either; at authorize time the port is
  /// random and the server must accept the loopback port-wildcard rule.
  static const String loopbackRedirectUri = 'http://127.0.0.1/callback';

  /// The `localhost` twin of [loopbackRedirectUri]. The browser redirect
  /// uses this form because browsers race `::1` and `127.0.0.1`, which also
  /// bypasses setups that intercept the IPv4 loopback (verified against
  /// Tavily: both variants must be registered for `localhost` to be
  /// accepted).
  static const String loopbackRedirectUriLocalhost =
      'http://localhost/callback';

  static const String oobRedirectUri = 'urn:ietf:wg:oauth:2.0:oob';

  OAuthFlowService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  /// Starts an authorization flow for [key].
  ///
  /// [serverUrl] is the MCP resource server URL, used as the base for
  /// RFC 8414 metadata discovery. [allowLoopback] enables the auto-callback
  /// path (disable on platforms where the loopback port is unreachable).
  Future<OAuthFlowStartResult> beginFlow({
    required String key,
    required mcp.OAuthConfig config,
    required String serverUrl,
    bool allowLoopback = true,
  }) async {
    _cancel(key);

    var effectiveConfig = config;
    var usedDiscovery = false;
    var usedDcr = false;
    String? discoveredAuthEndpoint;
    String? discoveredTokenEndpoint;
    String? discoveredClientId;

    final httpClient = _clientFactory();
    OAuthLoopbackServer? loopbackServer;
    try {
      // 1. Discover the authorization server when endpoints are missing.
      mcp.AuthServerMetadata? metadata;
      if (effectiveConfig.authorizationEndpoint.isEmpty ||
          effectiveConfig.tokenEndpoint.isEmpty ||
          effectiveConfig.clientId.isEmpty) {
        metadata = await mcp.HttpOAuthClient.discoverAuthServerMetadata(
          serverUrl,
          client: httpClient,
        );
        if (metadata != null) {
          effectiveConfig = effectiveConfig.copyWith(
            authorizationEndpoint: effectiveConfig.authorizationEndpoint.isEmpty
                ? metadata.authorizationEndpoint
                : null,
            tokenEndpoint: effectiveConfig.tokenEndpoint.isEmpty
                ? metadata.tokenEndpoint
                : null,
          );
          if (metadata.authorizationEndpoint != config.authorizationEndpoint) {
            discoveredAuthEndpoint = metadata.authorizationEndpoint;
          }
          if (metadata.tokenEndpoint != config.tokenEndpoint) {
            discoveredTokenEndpoint = metadata.tokenEndpoint;
          }
          usedDiscovery = true;
        }
      }

      // 2. Dynamically register a public client when no client ID is set.
      if (effectiveConfig.clientId.isEmpty) {
        // Re-probe metadata if step 1 was skipped (endpoints were filled in
        // manually) but registration is still needed.
        metadata ??= await mcp.HttpOAuthClient.discoverAuthServerMetadata(
          serverUrl,
          client: httpClient,
        );
        if (metadata?.registrationEndpoint != null) {
          final registrationEndpoint = metadata!.registrationEndpoint!;
          final redirectUris = <String>{
            loopbackRedirectUri,
            loopbackRedirectUriLocalhost,
            oobRedirectUri,
            if (effectiveConfig.redirectUri != null &&
                effectiveConfig.redirectUri!.isNotEmpty)
              effectiveConfig.redirectUri!,
          }.toList();
          final httpOAuth = mcp.HttpOAuthClient(
            config: effectiveConfig,
            httpClient: httpClient,
          );
          try {
            final registered = await httpOAuth.registerClient(
              redirectUris: redirectUris,
              clientName: 'Cuplivo',
              tokenEndpointAuthMethod: 'none',
              registrationEndpoint: registrationEndpoint,
            );
            effectiveConfig = effectiveConfig.copyWith(
              clientId: registered.clientId,
              clientSecret: registered.clientSecret,
            );
            discoveredClientId = registered.clientId;
            usedDcr = true;
          } on mcp.OAuthError {
            // Registration failed (unsupported auth method, rejected
            // redirect URIs...) — fall through to manual mode with the
            // user-configured client ID (empty = manual client ID needed).
          }
        }
      }

      // 3. Start the loopback server (auto-callback).
      if (allowLoopback) {
        final candidate = OAuthLoopbackServer();
        try {
          await candidate.start();
          loopbackServer = candidate;
        } catch (e) {
          // Port binding failed — fall back to manual paste.
          debugPrint('[OAuthFlowService] loopback start failed: $e');
        }
      }

      // 4. Build the authorize URL. The redirect URI decides the mode:
      //    auto → loopback URL with the random port (localhost host —
      //    browsers race ::1/127.0.0.1, and the client was registered with
      //    both loopback variants);
      //    manual → user-configured redirect URI, or none (OOB-style).
      // Fail loudly when discovery produced no authorization endpoint —
      // continuing would build a malformed relative URL that only fails
      // later at launch time with a misleading error.
      if (effectiveConfig.authorizationEndpoint.isEmpty) {
        throw const OAuthFlowException(
          OAuthFlowErrorCode.noAuthEndpoint,
          'Authorization endpoint is empty and could not be discovered '
          '(RFC 8414 discovery returned no metadata).',
        );
      }
      String? actualRedirectUri;
      final additionalParams = <String, String>{};
      final loopbackUrl = loopbackServer?.callbackUrl;
      if (loopbackUrl != null) {
        actualRedirectUri = loopbackUrl.toString();
        additionalParams['redirect_uri'] = actualRedirectUri;
      } else if (effectiveConfig.redirectUri != null &&
          effectiveConfig.redirectUri!.isNotEmpty) {
        actualRedirectUri = effectiveConfig.redirectUri;
      }

      final state = _generateState();
      final client = mcp.HttpOAuthClient(
        config: effectiveConfig,
        httpClient: httpClient,
      );
      final authUrl = await client.getAuthorizationUrl(
        scopes: effectiveConfig.scopes,
        state: state,
        additionalParams: additionalParams,
      );

      final session = OAuthFlowSession(
        key: key,
        client: client,
        state: state,
        loopbackServer: loopbackServer,
        actualRedirectUri: actualRedirectUri,
      );
      _sessions[key] = session;

      return OAuthFlowStartResult(
        authorizationUrl: Uri.parse(authUrl),
        loopbackCallbackUrl: loopbackServer?.callbackUrl,
        usedDiscovery: usedDiscovery,
        usedDcr: usedDcr,
        discoveredAuthorizationEndpoint: discoveredAuthEndpoint,
        discoveredTokenEndpoint: discoveredTokenEndpoint,
        discoveredClientId: discoveredClientId,
      );
    } catch (e) {
      httpClient.close();
      // The loopback server may already be bound (e.g. the authorize-URL
      // step failed) but the session was never registered — release the
      // port so failed starts do not leak listeners.
      await loopbackServer?.close();
      rethrow;
    }
  }

  /// Completes the flow for [key].
  ///
  /// When [pasted] is non-empty the user provided the code manually
  /// (MANUAL mode or fallback). When [pasted] is empty and the session runs
  /// in AUTO mode, waits up to [callbackTimeout] for the loopback callback.
  ///
  /// The session is only destroyed on success; on failure it stays alive so
  /// the user can retry (re-authorize and paste, or paste a fresh code).
  /// Concurrent completions for the same key are rejected.
  Future<mcp.OAuthToken> completeFlow({
    required String key,
    String? pasted,
    Duration callbackTimeout = const Duration(minutes: 2),
  }) async {
    final session = _sessions[key];
    if (session == null) {
      throw const OAuthFlowException(
        OAuthFlowErrorCode.noSession,
        'No active OAuth flow. Restart the flow.',
      );
    }
    if (!_inFlight.add(key)) {
      // An automatic completion is already waiting on the loopback
      // callback. A non-empty paste overrides it (the user chose the
      // manual path); an empty paste is a duplicate call and is rejected.
      final overrides = pasted != null && pasted.trim().isNotEmpty;
      if (!overrides) {
        throw const OAuthFlowException(
          OAuthFlowErrorCode.noSession,
          'The flow is already completing.',
        );
      }
      session.interrupted = true;
      session.loopbackServer?.cancelWait();
      // The overridden waiter keeps its `_inFlight` slot clean-up to the
      // overriding call, which removes the key on success/failure.
    }

    try {
      String? code;
      String? returnedState;
      if (pasted != null && pasted.trim().isNotEmpty) {
        (code, returnedState) = _extractCodeAndState(pasted);
      } else if (session.loopbackServer != null) {
        final callback = await session.loopbackServer!.waitForCallback(
          callbackTimeout,
        );
        if (callback == null) {
          if (session.interrupted) {
            // Overridden by a pasted code: exit silently — the overriding
            // call owns the flow outcome now.
            throw const OAuthFlowException(
              OAuthFlowErrorCode.interrupted,
              'The automatic callback wait was overridden by a pasted code.',
            );
          }
          throw const OAuthFlowException(
            OAuthFlowErrorCode.callbackTimeout,
            'No authorization callback received.',
          );
        }
        debugPrint('[OAuthFlowService] callback received: $callback');
        (code, returnedState) = _extractCodeAndState(callback.toString());
        if (callback.queryParameters.containsKey('error')) {
          final error = callback.queryParameters['error'] ?? 'unknown';
          final description =
              callback.queryParameters['error_description'] ??
              'Authorization was denied.';
          throw OAuthFlowException(
            OAuthFlowErrorCode.authorizationDenied,
            'Authorization error: $error — $description',
          );
        }
      } else {
        throw const OAuthFlowException(
          OAuthFlowErrorCode.noCode,
          'No pasted code and no loopback callback available.',
        );
      }

      if (code.isEmpty) {
        throw const OAuthFlowException(
          OAuthFlowErrorCode.noCode,
          'No authorization code found in the pasted content.',
        );
      }
      if (returnedState != null && returnedState != session.state) {
        throw const OAuthFlowException(
          OAuthFlowErrorCode.stateMismatch,
          'CSRF state mismatch: the pasted content does not belong to '
          'this authorization request.',
        );
      }
      final verifier = session.client.codeVerifier;
      if (verifier == null) {
        throw const OAuthFlowException(
          OAuthFlowErrorCode.verifierLost,
          'PKCE verifier lost. Restart the flow.',
        );
      }
      // Token exchange with redirect_uri fallback variants. Some servers
      // accept any loopback port at authorize time but validate the token
      // request against the REGISTERED (portless) redirect URI, or reject
      // the parameter entirely — so retry the variants on failure. The OOB
      // variants matter for proxy-style servers (e.g. Tavily) whose token
      // endpoint treats codes as OOB-bound.
      final redirectVariants = <String?>{
        session.actualRedirectUri,
        'http://localhost/callback',
        'http://127.0.0.1/callback',
        session.client.config.redirectUri,
        oobRedirectUri,
        null,
      }.toList();
      Object? lastError;
      for (final redirect in redirectVariants) {
        try {
          debugPrint(
            '[OAuthFlowService] exchanging code: clientId='
            '${session.client.config.clientId} '
            'redirectUri=${redirect ?? '(none)'} '
            'tokenEndpoint=${session.client.config.tokenEndpoint}',
          );
          final token = await session.client.exchangeCodeForToken(
            code: code,
            codeVerifier: verifier,
            redirectUri: redirect,
          );
          // Success: fully clean up and drop the session.
          _sessions.remove(key);
          _inFlight.remove(key);
          session.client.close();
          await session.loopbackServer?.close();
          return token;
        } catch (e) {
          lastError = e;
          debugPrint(
            '[OAuthFlowService] exchange variant "$redirect" failed: $e',
          );
        }
      }
      debugPrint('[OAuthFlowService] token exchange FAILED: $lastError');
      // Failure: keep the session alive (PKCE verifier reusable for a
      // re-authorize + paste retry). The loopback callback is consumed or
      // timed out, so it is closed.
      _inFlight.remove(key);
      await session.loopbackServer?.close();
      throw OAuthFlowException(
        OAuthFlowErrorCode.exchangeFailed,
        'Token exchange failed: $lastError',
      );
    } catch (e) {
      // Validation failures (noCode, stateMismatch, callbackTimeout, ...):
      // keep the session for a retry, close the consumed/timed-out loopback.
      if (e is OAuthFlowException && e.code == OAuthFlowErrorCode.interrupted) {
        // Overridden by a paste — the overriding call owns the `_inFlight`
        // slot and cleans it up on completion. Do not remove it here.
        await session.loopbackServer?.close();
        rethrow;
      }
      _inFlight.remove(key);
      await session.loopbackServer?.close();
      rethrow;
    }
  }

  /// Discards an in-flight flow without exchanging (e.g. user cancelled).
  void cancelFlow(String key) {
    _cancel(key);
  }

  void _cancel(String key) {
    final existing = _sessions.remove(key);
    existing?.client.close();
    // Interrupt any pending callback wait so the waiter exits promptly.
    existing?.loopbackServer?.cancelWait();
    if (existing?.loopbackServer != null) {
      unawaited(existing!.loopbackServer!.close());
    }
  }

  /// Extracts `code` (and optionally `state`) from pasted content that is
  /// either a raw code or a redirect URL. URL-shaped content — absolute
  /// (scheme + host) or relative (`/callback?code=...`, which is what the
  /// loopback server sees in `request.uri`) — must carry the code in its
  /// query parameters; anything else is treated as a raw code.
  (String, String?) _extractCodeAndState(String pasted) {
    final trimmed = pasted.trim();
    final uri = Uri.tryParse(trimmed);
    final isUrlLike =
        uri != null &&
        ((uri.hasScheme && uri.host.isNotEmpty) || trimmed.startsWith('/'));
    if (isUrlLike) {
      final params = uri.queryParameters;
      return (params['code'] ?? '', params['state']);
    }
    return (trimmed, null);
  }

  String _generateState() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(24, (i) => random.nextInt(256)),
    ).replaceAll('=', '');
  }
}

/// Error categories surfaced by [OAuthFlowService]. The UI maps each code
/// to a localized message.
enum OAuthFlowErrorCode {
  noSession,
  noCode,
  stateMismatch,
  verifierLost,
  exchangeFailed,
  callbackTimeout,
  authorizationDenied,
  noAuthEndpoint,

  /// Internal signal: an automatic loopback wait was overridden by a
  /// pasted code. Not shown to the user.
  interrupted,
}

/// A user-recoverable error in the OAuth flow (bad paste, state mismatch,
/// flow expired). [code] drives localization; [message] is a debug detail.
class OAuthFlowException implements Exception {
  final OAuthFlowErrorCode code;
  final String message;
  const OAuthFlowException(this.code, this.message);

  @override
  String toString() => message;
}
