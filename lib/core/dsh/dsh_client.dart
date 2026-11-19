/// The app-facing entry point for one DeepSeek Harness: pairing, the mux
/// connection, the catalog batch and the session handles.
///
/// A client is one remote. Pairing is `login(token)` (only when a fresh WebUI
/// URL is pasted) or `useCookie(stored)` (resume); both are followed by
/// [connect], which completes on the first `$events` ready generation.
library;

import 'dart:async';

import 'dsh_catalog.dart';
import 'dsh_endpoint.dart';
import 'dsh_errors.dart';
import 'dsh_events.dart';
import 'dsh_mux.dart';
import 'dsh_projection.dart';
import 'dsh_rpc.dart';
import 'dsh_session.dart';
import 'dsh_transport.dart';

class DshClient {
  DshClient(
    this.endpoint, {
    DshTransport? transport,
    DshHttpClient? httpClient,
    this.muxOptions = const DshMuxOptions(),
    Duration connectTimeout = const Duration(seconds: 10),
    Duration requestTimeout = const Duration(seconds: 30),
  }) : transport =
           transport ??
           DshHttpTransport(
             endpoint,
             httpClient: httpClient,
             connectTimeout: connectTimeout,
             requestTimeout: requestTimeout,
           );

  final DshEndpoint endpoint;
  final DshTransport transport;
  final DshMuxOptions muxOptions;

  late final DshRpc rpc = DshRpc(transport);
  late final DshMux mux = DshMux(transport, options: muxOptions, rpc: rpc);
  late final DshCatalog catalog = DshCatalog(rpc, mux);

  final Map<String, DshSession> _sessions = {};
  DshCatalogSnapshot? _catalogSnapshot;
  bool _closed = false;

  /// The v1 browser cookie, for secure storage. Never send it anywhere but its
  /// own [DshEndpoint.authority].
  DshCookie? get cookie => transport.cookie;

  DshConnectionState get state => mux.state;

  DshException? get lastError => mux.lastError;

  Stream<DshConnectionState> get states => mux.states;

  Stream<DshHostEvent> get hostEvents => mux.hostEvents;

  /// Last [loadCatalog] result, if any.
  DshCatalogSnapshot? get catalogSnapshot => _catalogSnapshot;

  bool get isClosed => _closed;

  // ---------------------------------------------------------------------------
  // Pairing

  /// Mints the v1 cookie from a launch token and verifies it. The token is not
  /// retained: the client keeps only the cookie in [transport].
  Future<DshCookie> login(String token) async {
    final cookie = await transport.login(token);
    await transport.verify();
    return cookie;
  }

  /// Adopts a cookie restored from secure storage (no login, no token).
  void useCookie(DshCookie cookie) {
    transport.useCookie(cookie);
  }

  /// Verifies the current cookie against `GET /`.
  Future<void> verify() => transport.verify();

  /// Opens the mux and waits for the first ready generation.
  Future<DshMuxGeneration> connect() {
    if (_closed) {
      return Future<DshMuxGeneration>.error(
        const DshClosedException('This client was closed'),
      );
    }
    return mux.ready;
  }

  /// One-call pairing helper: parse the pasted URL, login if it carries a
  /// token, otherwise resume [storedCookie], verify, then connect.
  static Future<DshClient> pair(
    String input, {
    DshCookie? storedCookie,
    DshHttpClient? httpClient,
    DshMuxOptions muxOptions = const DshMuxOptions(),
  }) async {
    final endpoint = DshEndpoint.parse(input);
    if (!endpoint.hasToken && storedCookie == null) {
      throw const DshAuthException(
        'Paste the full dsh web URL including its ?token=',
      );
    }
    final transport = DshHttpTransport(endpoint, httpClient: httpClient);
    if (endpoint.hasToken) {
      // Login, verify, then drop the launch token from the client's endpoint:
      // only the cookie is retained.
      await transport.login(endpoint.token!);
      await transport.verify();
    } else {
      transport.useCookie(storedCookie!);
      await transport.verify();
    }
    final client = DshClient(
      endpoint.withoutToken(),
      transport: transport,
      muxOptions: muxOptions,
    );
    await client.connect();
    return client;
  }

  // ---------------------------------------------------------------------------
  // Catalog

  /// Reads the catalog batch once; call it again after a reconnect.
  Future<DshCatalogSnapshot> loadCatalog({
    bool includePlugins = true,
    bool includeSettings = true,
    bool includeAccount = true,
  }) async {
    final snapshot = await catalog.load(
      includePlugins: includePlugins,
      includeSettings: includeSettings,
      includeAccount: includeAccount,
    );
    _catalogSnapshot = snapshot;
    return snapshot;
  }

  // ---------------------------------------------------------------------------
  // Sessions

  /// Creates a session on the Host and returns its handle (not yet followed).
  Future<DshSession> createSession({
    String? cwd,
    String? workspaceId,
    String? agentPreset,
  }) async {
    final created = await catalog.createSession(
      cwd: cwd,
      workspaceId: workspaceId,
      agentPreset: agentPreset,
    );
    return openSession(created.sessionId);
  }

  /// Returns the cached handle or creates one. The caller starts following with
  /// `DshSession.watch()` (or `DshSessionStore.start()`); a cold session must be
  /// activated through `watch(activate: true)` before it can be prompted.
  DshSession openSession(
    String sessionId, {
    DshSessionOptions options = const DshSessionOptions(),
  }) {
    final existing = _sessions[sessionId];
    if (existing != null) return existing;
    final session = DshSession(
      sessionId: sessionId,
      mux: mux,
      rpc: rpc,
      transport: transport,
      options: options,
    );
    _sessions[sessionId] = session;
    return session;
  }

  /// Creates a ready-to-use chat store: creates the handle if needed, follows
  /// the session, folds it into a transcript, and forwards changes.
  ///
  /// [activate] promotes a cold session; pass false for a background/preview
  /// view.
  Future<DshSessionStore> store(
    String sessionId, {
    bool activate = true,
    DshSessionOptions options = const DshSessionOptions(),
    DshTranscript? transcript,
  }) async {
    final session = openSession(sessionId, options: options);
    final store = DshSessionStore(
      session: session,
      transcript: transcript ?? DshTranscript(),
    );
    await store.start(activate: activate);
    return store;
  }

  /// Closes and forgets a followed session.
  Future<void> closeSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    await session?.dispose();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final sessions = List<DshSession>.of(_sessions.values);
    _sessions.clear();
    for (final session in sessions) {
      await session.dispose();
    }
    await mux.close();
    await transport.close(force: true);
  }
}
