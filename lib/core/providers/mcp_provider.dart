import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_client/mcp_client.dart' as mcp;
import '../services/mcp/kelivo_fetch/kelivo_fetch_server.dart';
import '../services/mcp/stdio_command_resolver.dart';
import '../services/network/mcp_log_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../services/chat/chat_service.dart';
import '../services/deleted_records_store.dart';
import '../services/headless_generation_service.dart';
import '../services/oauth/oauth_flow_service.dart';
import 'assistant_provider.dart';
import '../services/mcp/kelivo_subagent/kelivo_subagent_server.dart';

/// Transport type: SSE, Streamable HTTP, and STDIO (desktop-only).
enum McpTransportType { sse, http, stdio, inmemory }

/// Connection status for an MCP server.
enum McpStatus { idle, connecting, connected, error }

class McpParamSpec {
  final String name;
  final bool required;
  final String? type;
  final dynamic defaultValue;

  McpParamSpec({
    required this.name,
    required this.required,
    this.type,
    this.defaultValue,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'required': required,
    'type': type,
    'default': defaultValue,
  };

  factory McpParamSpec.fromJson(Map<String, dynamic> json) => McpParamSpec(
    name: json['name'] as String? ?? '',
    required: json['required'] as bool? ?? false,
    type: json['type'] as String?,
    defaultValue: json['default'],
  );
}

class McpToolConfig {
  final bool enabled;
  final String name;
  final String? description;
  final List<McpParamSpec> params;
  // Raw JSON schema for parameters, if provided by the server
  final Map<String, dynamic>? schema;

  /// Whether this tool requires user approval before execution.
  final bool needsApproval;

  McpToolConfig({
    required this.enabled,
    required this.name,
    this.description,
    this.params = const [],
    this.schema,
    this.needsApproval = false,
  });

  McpToolConfig copyWith({
    bool? enabled,
    String? name,
    String? description,
    List<McpParamSpec>? params,
    Map<String, dynamic>? schema,
    bool? needsApproval,
  }) => McpToolConfig(
    enabled: enabled ?? this.enabled,
    name: name ?? this.name,
    description: description ?? this.description,
    params: params ?? this.params,
    schema: schema ?? this.schema,
    needsApproval: needsApproval ?? this.needsApproval,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'name': name,
    'description': description,
    'params': params.map((e) => e.toJson()).toList(),
    if (schema != null) 'schema': schema,
    if (needsApproval) 'needsApproval': true,
  };

  factory McpToolConfig.fromJson(Map<String, dynamic> json) => McpToolConfig(
    enabled: json['enabled'] as bool? ?? true,
    name: json['name'] as String? ?? '',
    description: json['description'] as String?,
    params:
        (json['params'] as List?)
            ?.map(
              (e) => McpParamSpec.fromJson((e as Map).cast<String, dynamic>()),
            )
            .toList() ??
        const [],
    schema: (json['schema'] is Map)
        ? (json['schema'] as Map).cast<String, dynamic>()
        : null,
    needsApproval: json['needsApproval'] as bool? ?? false,
  );
}

/// Static OAuth 2.1 configuration for a remote MCP server.
///
/// This is an app-level DTO; the library's `mcp.OAuthConfig` is built from
/// it at connection time via [toLibraryConfig]. Empty endpoint fields are
/// legal — the flow auto-discovers (RFC 8414) and auto-registers a client
/// (RFC 7591) at authorization time.
class McpOAuthConfig {
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String clientId;
  final String? clientSecret;
  final String scopes; // space-separated, optional
  final String? redirectUri;

  /// Registration provenance of [clientId]:
  /// - 0: unregistered or user-provided (never auto-replaced)
  /// - 1: auto-registered by an older build (127.0.0.1 loopback variant
  ///   only) — re-registered on the next flow so `localhost` redirects work
  /// - 2: auto-registered with both loopback variants (current)
  final int clientRegistrationVersion;

  const McpOAuthConfig({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    this.clientSecret,
    this.scopes = '',
    this.redirectUri,
    this.clientRegistrationVersion = 0,
  });

  McpOAuthConfig copyWith({
    String? authorizationEndpoint,
    String? tokenEndpoint,
    String? clientId,
    String? clientSecret,
    bool clearClientSecret = false,
    String? scopes,
    String? redirectUri,
    bool clearRedirectUri = false,
    int? clientRegistrationVersion,
  }) => McpOAuthConfig(
    authorizationEndpoint: authorizationEndpoint ?? this.authorizationEndpoint,
    tokenEndpoint: tokenEndpoint ?? this.tokenEndpoint,
    clientId: clientId ?? this.clientId,
    clientSecret: clearClientSecret
        ? null
        : (clientSecret ?? this.clientSecret),
    scopes: scopes ?? this.scopes,
    redirectUri: clearRedirectUri ? null : (redirectUri ?? this.redirectUri),
    clientRegistrationVersion:
        clientRegistrationVersion ?? this.clientRegistrationVersion,
  );

  Map<String, dynamic> toJson() {
    final secret = clientSecret;
    final redirect = redirectUri;
    return {
      'authorizationEndpoint': authorizationEndpoint,
      'tokenEndpoint': tokenEndpoint,
      'clientId': clientId,
      if (secret != null && secret.isNotEmpty) 'clientSecret': secret,
      if (scopes.trim().isNotEmpty) 'scopes': scopes,
      if (redirect != null && redirect.isNotEmpty) 'redirectUri': redirect,
      if (clientRegistrationVersion != 0)
        'clientRegistrationVersion': clientRegistrationVersion,
    };
  }

  factory McpOAuthConfig.fromJson(Map<String, dynamic> json) => McpOAuthConfig(
    authorizationEndpoint: (json['authorizationEndpoint'] as String?) ?? '',
    tokenEndpoint: (json['tokenEndpoint'] as String?) ?? '',
    clientId: (json['clientId'] as String?) ?? '',
    clientSecret: json['clientSecret'] as String?,
    scopes: (json['scopes'] as String?) ?? '',
    redirectUri: json['redirectUri'] as String?,
    clientRegistrationVersion: (json['clientRegistrationVersion'] as int?) ?? 0,
  );

  /// Builds the library-level OAuth configuration for connection time.
  mcp.OAuthConfig toLibraryConfig() {
    final secret = clientSecret;
    final redirect = redirectUri;
    final scopeList = scopes
        .split(' ')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return mcp.OAuthConfig(
      authorizationEndpoint: authorizationEndpoint.trim(),
      tokenEndpoint: tokenEndpoint.trim(),
      clientId: clientId.trim(),
      clientSecret: (secret == null || secret.isEmpty) ? null : secret,
      redirectUri: (redirect == null || redirect.isEmpty) ? null : redirect,
      scopes: scopeList,
      grantType: mcp.OAuthGrantType.authorizationCode,
      codeChallengeMethod: 'S256',
    );
  }
}

class McpServerConfig {
  final String id; // stable id
  final bool enabled;
  final String name;
  final McpTransportType transport;
  // For SSE/HTTP
  final String url; // SSE endpoint or HTTP base URL
  final List<McpToolConfig> tools;
  final Map<String, String> headers; // custom HTTP headers
  // For STDIO (desktop-only)
  final String? command;
  final List<String> args;
  final Map<String, String> env;
  final String? workingDirectory;
  final int? heartbeatIntervalSeconds; // null = use default (12s)
  final String
  toolPrefix; // optional prefix prepended to all tool names from this server
  // OAuth (HTTP/SSE only). Null = no OAuth, static headers apply.
  final McpOAuthConfig? oauth;
  // Persisted OAuth token. Null = never authorized or cleared.
  final mcp.OAuthToken? oauthToken;

  McpServerConfig({
    required this.id,
    required this.enabled,
    required this.name,
    required this.transport,
    this.url = '',
    this.tools = const [],
    this.headers = const {},
    this.command,
    this.args = const [],
    this.env = const {},
    this.workingDirectory,
    this.heartbeatIntervalSeconds,
    this.toolPrefix = '',
    this.oauth,
    this.oauthToken,
  });

  McpServerConfig copyWith({
    String? id,
    bool? enabled,
    String? name,
    McpTransportType? transport,
    String? url,
    List<McpToolConfig>? tools,
    Map<String, String>? headers,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? workingDirectory,
    bool clearWorkingDirectory = false,
    int? heartbeatIntervalSeconds,
    bool clearHeartbeatIntervalSeconds = false,
    String? toolPrefix,
    McpOAuthConfig? oauth,
    bool clearOauth = false,
    mcp.OAuthToken? oauthToken,
    bool clearOauthToken = false,
  }) => McpServerConfig(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    name: name ?? this.name,
    transport: transport ?? this.transport,
    url: url ?? this.url,
    tools: tools ?? this.tools,
    headers: headers ?? this.headers,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    workingDirectory: clearWorkingDirectory
        ? null
        : (workingDirectory ?? this.workingDirectory),
    heartbeatIntervalSeconds: clearHeartbeatIntervalSeconds
        ? null
        : (heartbeatIntervalSeconds ?? this.heartbeatIntervalSeconds),
    toolPrefix: toolPrefix ?? this.toolPrefix,
    oauth: clearOauth ? null : (oauth ?? this.oauth),
    oauthToken: clearOauthToken ? null : (oauthToken ?? this.oauthToken),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'enabled': enabled,
    'name': name,
    'transport': transport.name,
    if (transport != McpTransportType.stdio &&
        transport != McpTransportType.inmemory)
      'url': url,
    'tools': tools.map((e) => e.toJson()).toList(),
    if (transport != McpTransportType.stdio &&
        transport != McpTransportType.inmemory)
      'headers': headers,
    if (transport == McpTransportType.stdio) 'command': command,
    if (transport == McpTransportType.stdio) 'args': args,
    if (transport == McpTransportType.stdio) 'env': env,
    if (transport == McpTransportType.stdio && workingDirectory != null)
      'workingDirectory': workingDirectory,
    if (heartbeatIntervalSeconds != null)
      'heartbeatIntervalSeconds': heartbeatIntervalSeconds,
    if (toolPrefix.isNotEmpty) 'toolPrefix': toolPrefix,
    if (oauth != null) 'oauth': oauth!.toJson(),
    if (oauthToken != null) 'oauthToken': oauthToken!.toJson(),
  };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final tRaw = (json['transport'] as String?) ?? '';
    final t = tRaw == 'http'
        ? McpTransportType.http
        : (tRaw == 'stdio'
              ? McpTransportType.stdio
              : (tRaw == 'inmemory'
                    ? McpTransportType.inmemory
                    : McpTransportType.sse));
    final tools =
        (json['tools'] as List?)
            ?.map(
              (e) => McpToolConfig.fromJson((e as Map).cast<String, dynamic>()),
            )
            .toList() ??
        const <McpToolConfig>[];
    final heartbeatIntervalSeconds = json['heartbeatIntervalSeconds'] as int?;
    final toolPrefix = (json['toolPrefix'] as String?) ?? '';
    final oauth = json['oauth'] is Map
        ? McpOAuthConfig.fromJson(
            (json['oauth'] as Map).cast<String, dynamic>(),
          )
        : null;
    final oauthToken = json['oauthToken'] is Map
        ? _oauthTokenFromJson(json['oauthToken'])
        : null;
    if (t == McpTransportType.stdio) {
      final argsAny = json['args'];
      final envAny = json['env'];
      return McpServerConfig(
        id: json['id'] as String? ?? const Uuid().v4(),
        enabled: json['enabled'] as bool? ?? true,
        name: json['name'] as String? ?? '',
        transport: McpTransportType.stdio,
        tools: tools,
        command: (json['command'] as String?)?.trim(),
        args: argsAny is List
            ? argsAny.map((e) => e.toString()).toList()
            : const <String>[],
        env: envAny is Map
            ? envAny.map((k, v) => MapEntry(k.toString(), v.toString()))
            : const <String, String>{},
        workingDirectory: (json['workingDirectory'] as String?)?.trim(),
        heartbeatIntervalSeconds: heartbeatIntervalSeconds,
        toolPrefix: toolPrefix,
        oauth: oauth,
        oauthToken: oauthToken,
      );
    } else if (t == McpTransportType.inmemory) {
      return McpServerConfig(
        id: json['id'] as String? ?? const Uuid().v4(),
        enabled: json['enabled'] as bool? ?? true,
        name: json['name'] as String? ?? '',
        transport: McpTransportType.inmemory,
        tools: tools,
        heartbeatIntervalSeconds: heartbeatIntervalSeconds,
        toolPrefix: toolPrefix,
        oauth: oauth,
        oauthToken: oauthToken,
      );
    } else {
      return McpServerConfig(
        id: json['id'] as String? ?? const Uuid().v4(),
        enabled: json['enabled'] as bool? ?? true,
        name: json['name'] as String? ?? '',
        transport: t,
        url: json['url'] as String? ?? '',
        tools: tools,
        headers:
            ((json['headers'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            )) ??
            const {},
        heartbeatIntervalSeconds: heartbeatIntervalSeconds,
        toolPrefix: toolPrefix,
        oauth: oauth,
        oauthToken: oauthToken,
      );
    }
  }

  static mcp.OAuthToken? _oauthTokenFromJson(dynamic raw) {
    try {
      return mcp.OAuthToken.fromJson((raw as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}

class McpProvider extends ChangeNotifier {
  static const String _prefsKey = 'mcp_servers_v1';
  static const String _prefsTimeoutKey = 'mcp_request_timeout_ms_v1';

  McpProvider({
    this.chatService,
    this.assistantProvider,
    this.headlessGen,
    required this.contextProvider,
    http.Client Function()? oauthClientFactory,
    OAuthFlowService? oauthFlowService,
  }) : oauthFlowService =
           oauthFlowService ??
           OAuthFlowService(clientFactory: oauthClientFactory) {
    _load();
  }

  final ChatService? chatService;
  final AssistantProvider? assistantProvider;
  final HeadlessGenerationService? headlessGen;
  final BuildContext Function() contextProvider;

  /// Provider-agnostic OAuth flow orchestration (see ADR-0016).
  final OAuthFlowService oauthFlowService;

  final Map<String, mcp.Client> _clients = {};
  final Map<String, McpStatus> _status = {}; // id -> status
  final Map<String, String> _errors = {}; // id -> last error
  List<McpServerConfig> _servers = [];
  // Reconnect bookkeeping to avoid duplicate concurrent retries
  final Set<String> _reconnecting = <String>{};
  // Heartbeat timers for live-connection health checks
  final Map<String, Timer> _heartbeats = <String, Timer>{};
  Duration _requestTimeout = const Duration(seconds: 30);
  final McpStdioCommandResolver _stdioCommandResolver =
      McpStdioCommandResolver();

  List<McpServerConfig> get servers => List.unmodifiable(_servers);
  McpStatus statusFor(String id) => _status[id] ?? McpStatus.idle;
  String? errorFor(String id) => _errors[id];
  bool get hasAnyEnabled => _servers.any((s) => s.enabled);
  bool isConnected(String id) =>
      _clients.containsKey(id) && statusFor(id) == McpStatus.connected;
  List<McpServerConfig> get connectedServers => _servers
      .where((s) => statusFor(s.id) == McpStatus.connected)
      .toList(growable: false);
  Duration get requestTimeout => _requestTimeout;
  int get requestTimeoutSeconds => _requestTimeout.inSeconds;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final timeoutMs = prefs.getInt(_prefsTimeoutKey);
    if (timeoutMs != null && timeoutMs > 0) {
      _requestTimeout = Duration(milliseconds: timeoutMs);
    }
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List)
            .map(
              (e) =>
                  McpServerConfig.fromJson((e as Map).cast<String, dynamic>()),
            )
            .toList();
        _servers = list;
      } catch (_) {}
    }
    // Ensure built-in MCP servers are present by default
    _ensureBuiltinFetchServerPresent();
    _ensureBuiltinSubagentServerPresent();
    // initialize statuses
    for (final s in _servers) {
      _status[s.id] = McpStatus.idle;
      _errors.remove(s.id);
    }
    notifyListeners();

    // Auto-connect enabled servers. Skip OAuth servers that have not been
    // authorized yet — connecting them would fail with "no token yet" and
    // leave a stale error state (the connect happens after authorization).
    for (final s in _servers.where((e) => e.enabled)) {
      final needsOAuth = s.oauth != null && s.oauthToken == null;
      if (needsOAuth) continue;
      // fire and forget
      unawaited(connect(s.id));
    }

    // Refresh @kelivo/subagent tool definitions when assistants change
    assistantProvider?.addListener(_onAssistantsChanged);
  }

  void _onAssistantsChanged() {
    unawaited(refreshTools('kelivo_subagent'));
  }

  void _ensureBuiltinSubagentServerPresent() {
    if (assistantProvider == null ||
        chatService == null ||
        headlessGen == null) {
      return;
    }
    final exists = _servers.any(
      (s) => s.id == 'kelivo_subagent' || s.name == '@kelivo/subagent',
    );
    if (exists) return;
    _servers = [
      ..._servers,
      McpServerConfig(
        id: 'kelivo_subagent',
        enabled: true,
        name: '@kelivo/subagent',
        transport: McpTransportType.inmemory,
        tools: const <McpToolConfig>[],
      ),
    ];
  }

  void _ensureBuiltinFetchServerPresent() {
    final exists = _servers.any(
      (s) => s.name == '@kelivo/fetch' || s.id == 'kelivo_fetch',
    );
    if (exists) return;
    final cfg = McpServerConfig(
      id: 'kelivo_fetch',
      enabled: true,
      name: '@kelivo/fetch',
      transport: McpTransportType.inmemory,
      tools: const <McpToolConfig>[], // will refresh on connect
    );
    _servers = [..._servers, cfg];
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_servers.map((e) => e.toJson()).toList()),
    );
    await prefs.setInt(_prefsTimeoutKey, _requestTimeout.inMilliseconds);
  }

  Future<void> _persistTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsTimeoutKey, _requestTimeout.inMilliseconds);
  }

  /// Export current MCP servers as a user-friendly JSON structure.
  ///
  /// Shape:
  /// {
  ///   "mcpServers": {
  ///     "serverId": {
  ///       "name": "...",
  ///       "type": "streamableHttp" | "sse",
  ///       "description": "",
  ///       "isActive": true/false,
  ///       "baseUrl": "...",
  ///       "headers": { ... }
  ///     },
  ///     ...
  ///   }
  /// }
  String exportServersAsUiJson() {
    // On mobile, skip stdio entries in exported JSON.
    final isDesktop = _isDesktopPlatform();
    final map = <String, dynamic>{
      'mcpServers': {
        for (final s in _servers)
          if (s.transport != McpTransportType.stdio || isDesktop)
            s.id: {
              'name': s.name,
              if (s.transport == McpTransportType.http)
                'type': 'streamableHttp',
              if (s.transport == McpTransportType.sse) 'type': 'sse',
              if (s.transport == McpTransportType.inmemory) 'type': 'inmemory',
              'description': '',
              'isActive': s.enabled,
              if (s.transport != McpTransportType.stdio &&
                  s.transport != McpTransportType.inmemory)
                'baseUrl': s.url,
              if (s.transport != McpTransportType.stdio &&
                  s.transport != McpTransportType.inmemory &&
                  s.headers.isNotEmpty)
                'headers': s.headers,
              // For stdio, include an optional type for compatibility
              if (s.transport == McpTransportType.stdio) 'type': 'stdio',
              // Include command/args/env
              if (s.transport == McpTransportType.stdio &&
                  (s.command ?? '').isNotEmpty)
                'command': s.command,
              if (s.transport == McpTransportType.stdio && s.args.isNotEmpty)
                'args': s.args,
              if (s.transport == McpTransportType.stdio && s.env.isNotEmpty)
                'env': s.env,
              if (s.transport == McpTransportType.stdio)
                ...() {
                  final reg =
                      s.env['NPM_CONFIG_REGISTRY'] ??
                      s.env['npm_config_registry'];
                  return reg != null && reg.isNotEmpty
                      ? {'registryUrl': reg}
                      : <String, dynamic>{};
                }(),
              if (s.transport == McpTransportType.stdio &&
                  (s.workingDirectory ?? '').isNotEmpty)
                'workingDirectory': s.workingDirectory,
            },
      },
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  /// Replace all MCP servers from a JSON string.
  /// Accepts either the UI JSON (with top-level `mcpServers`) or the internal list format.
  Future<void> replaceAllFromJson(String rawJson) async {
    dynamic data;
    try {
      data = jsonDecode(rawJson);
    } catch (e) {
      throw FormatException('Invalid JSON: ${e.toString()}');
    }

    List<McpServerConfig> next = [];
    try {
      Map<String, dynamic>? serversFromMap;
      if (data is Map && data.containsKey('mcpServers')) {
        serversFromMap = (data['mcpServers'] as Map).cast<String, dynamic>();
      } else if (data is Map && data.isNotEmpty) {
        // Allow raw map format: { id: { ... } }
        // Heuristically treat it as mcpServers format when values are maps.
        final ok = data.values.every((v) => v is Map);
        if (ok) serversFromMap = data.cast<String, dynamic>();
      }

      if (serversFromMap != null) {
        final isDesktop = _isDesktopPlatform();
        bool builtinSeen = false;
        bool builtinEnabled = true;
        serversFromMap.forEach((id, cfgAny) {
          if (cfgAny is! Map) return;
          final cfg = cfgAny.cast<String, dynamic>();
          final typeLower = (cfg['type'] ?? '').toString().toLowerCase();
          if (typeLower == 'inmemory') {
            // Built-in @kelivo/fetch control via isActive; ignore name mismatches silently
            builtinSeen = true;
            builtinEnabled = (cfg['isActive'] as bool?) ?? true;
            return;
          }
          final hasStdioShape =
              cfg.containsKey('command') ||
              cfg.containsKey('args') ||
              cfg.containsKey('env') ||
              (cfg['type']?.toString().toLowerCase() == 'stdio');
          if (hasStdioShape) {
            if (!isDesktop) {
              // Mobile: skip stdio entries entirely
              return;
            }
            final enabled = (cfg['isActive'] as bool?) ?? true;
            final name = (cfg['name'] as String?)?.trim();
            final cmd = (cfg['command'] as String?)?.trim();
            if (cmd == null || cmd.isEmpty) {
              // invalid stdio entry without command
              return;
            }
            final argsAny = cfg['args'];
            final envAny = cfg['env'];
            final wd = (cfg['workingDirectory'] as String?)?.trim();
            final registryUrl = (cfg['registryUrl'] as String?)?.trim();
            Map<String, String> env = envAny is Map
                ? envAny.map((k, v) => MapEntry(k.toString(), v.toString()))
                : const <String, String>{};
            if ((registryUrl != null) && registryUrl.isNotEmpty) {
              if (!env.containsKey('NPM_CONFIG_REGISTRY') &&
                  !env.containsKey('npm_config_registry')) {
                env = {...env, 'NPM_CONFIG_REGISTRY': registryUrl};
              }
            }
            next.add(
              McpServerConfig(
                id: id,
                enabled: enabled,
                name: (name == null || name.isEmpty) ? id : name,
                transport: McpTransportType.stdio,
                command: cmd,
                args: argsAny is List
                    ? argsAny.map((e) => e.toString()).toList()
                    : const <String>[],
                env: env,
                workingDirectory: (wd != null && wd.isNotEmpty) ? wd : null,
              ),
            );
            return;
          }

          // SSE/HTTP branch using legacy fields
          final typeRaw = (cfg['type'] ?? '').toString().toLowerCase();
          final transport = (typeRaw.contains('http'))
              ? McpTransportType.http
              : McpTransportType.sse;
          final enabled = (cfg['isActive'] as bool?) ?? true;
          final name = (cfg['name'] as String?)?.trim();
          final url = (cfg['baseUrl'] as String?)?.trim();
          final headersAny = cfg['headers'];
          Map<String, String> headers = const {};
          if (headersAny is Map) {
            headers = headersAny.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            );
          }
          if ((url ?? '').isEmpty) {
            // Skip invalid entries with empty URL
            return;
          }
          next.add(
            McpServerConfig(
              id: id,
              enabled: enabled,
              name: (name == null || name.isEmpty) ? id : name,
              transport: transport,
              url: url!,
              headers: headers,
            ),
          );
        });
        if (builtinSeen) {
          // Append single built-in server with fixed id/name
          next.add(
            McpServerConfig(
              id: 'kelivo_fetch',
              enabled: builtinEnabled,
              name: '@kelivo/fetch',
              transport: McpTransportType.inmemory,
            ),
          );
        }
      } else if (data is List) {
        // Attempt to parse internal list format. Be tolerant to transport string variants.
        for (final item in data) {
          if (item is! Map) continue;
          final m = item.cast<String, dynamic>();
          final t = (m['transport'] ?? '').toString().toLowerCase();
          if (t == 'streamablehttp' || t.contains('http')) {
            m['transport'] = 'http';
          } else if (t == 'sse') {
            m['transport'] = 'sse';
          } else if (t == 'stdio') {
            m['transport'] = 'stdio';
          }
          try {
            final s = McpServerConfig.fromJson(m);
            if (s.transport != McpTransportType.stdio &&
                s.transport != McpTransportType.inmemory &&
                s.url.trim().isEmpty) {
              continue;
            }
            next.add(s);
          } catch (_) {}
        }
      } else if (data is Map && data.containsKey('servers')) {
        final list = data['servers'];
        if (list is List) {
          for (final item in list) {
            if (item is! Map) continue;
            final m = item.cast<String, dynamic>();
            final t = (m['transport'] ?? '').toString().toLowerCase();
            if (t == 'streamablehttp' || t.contains('http')) {
              m['transport'] = 'http';
            } else if (t == 'sse') {
              m['transport'] = 'sse';
            } else if (t == 'stdio') {
              m['transport'] = 'stdio';
            }
            try {
              final s = McpServerConfig.fromJson(m);
              if (s.transport != McpTransportType.stdio &&
                  s.transport != McpTransportType.inmemory &&
                  s.url.trim().isEmpty) {
                continue;
              }
              next.add(s);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      throw FormatException('Unrecognized or invalid MCP JSON');
    }

    if (next.isEmpty) {
      throw FormatException('No valid MCP servers found in JSON');
    }

    // Disconnect all current
    for (final s in _servers) {
      try {
        await disconnect(s.id);
      } catch (_) {}
    }

    // Replace and reset statuses
    _servers = next;
    _status.clear();
    _errors.clear();
    for (final s in _servers) {
      _status[s.id] = McpStatus.idle;
    }

    await _persist();
    notifyListeners();

    // Auto-connect enabled servers
    for (final s in _servers.where((e) => e.enabled)) {
      // fire and forget
      unawaited(connect(s.id));
    }
  }

  McpServerConfig? getById(String id) {
    for (final s in _servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<String> addServer({
    required bool enabled,
    required String name,
    required McpTransportType transport,
    String url = '',
    Map<String, String> headers = const {},
    String? command,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
    String? workingDirectory,
    int? heartbeatIntervalSeconds,
    String toolPrefix = '',
    McpOAuthConfig? oauth,
  }) async {
    final id = const Uuid().v4();
    final cfg = McpServerConfig(
      id: id,
      enabled: enabled,
      name: name.trim().isEmpty ? 'MCP' : name.trim(),
      transport: transport,
      url: url.trim(),
      headers: headers,
      command: command?.trim(),
      args: args,
      env: env,
      workingDirectory: (workingDirectory?.trim().isNotEmpty ?? false)
          ? workingDirectory!.trim()
          : null,
      heartbeatIntervalSeconds: heartbeatIntervalSeconds,
      toolPrefix: toolPrefix,
      oauth: oauth,
    );
    _servers = [..._servers, cfg];
    _status[id] = McpStatus.idle;
    await _persist();
    notifyListeners();
    // Skip the automatic connect when OAuth is configured but not yet
    // authorized — it would fail with "no token yet" and leave a stale
    // error state. The connection happens after authorization completes.
    final needsOAuth = cfg.oauth != null && cfg.oauthToken == null;
    if (enabled && !needsOAuth) {
      unawaited(connect(id));
    }
    return id;
  }

  /// Restores a previously-deleted server from trash. Adds it back to the
  /// list and persists. Used by [TrashRestoreCoordinator].
  void restoreServer(McpServerConfig config) {
    _servers = [..._servers, config];
    _status[config.id] = McpStatus.idle;
    _persist();
    notifyListeners();
  }

  Future<void> updateServer(McpServerConfig updated) async {
    final idx = _servers.indexWhere((e) => e.id == updated.id);
    if (idx < 0) return;
    _servers = List<McpServerConfig>.of(_servers)..[idx] = updated;
    await _persist();
    notifyListeners();
    if (!updated.enabled) {
      await disconnect(updated.id);
    } else {
      // Always reconnect after saving to apply changes (url/transport/name)
      await disconnect(updated.id);
      unawaited(connect(updated.id));
    }
  }

  /// Starts the OAuth authorization flow for [serverId].
  ///
  /// Auto-discovers missing endpoints (RFC 8414), dynamically registers a
  /// public client when no Client ID is set (RFC 7591), and starts a
  /// loopback callback server. Any discovered/registered values are
  /// persisted back into the server config. Returns the flow start result.
  ///
  /// [configOverride] supplies the form's current OAuth configuration.
  /// Without it (and when the server has no persisted config) the flow
  /// fails — the edit form is the source of truth, e.g. the OAuth switch
  /// may have just been turned on and never saved.
  ///
  /// Throws [StateError] when neither the override nor the server has an
  /// OAuth configuration.
  Future<OAuthFlowStartResult> beginOAuthFlow(
    String serverId, {
    McpOAuthConfig? configOverride,
  }) async {
    final server = getById(serverId);
    if (server == null) {
      throw StateError('MCP server not found: $serverId');
    }
    final oauth = configOverride ?? server.oauth;
    if (oauth == null) {
      throw StateError(
        'OAuth is not configured for server "${server.name}". '
        'Enable OAuth in the server edit page first.',
      );
    }
    // Client IDs auto-registered by older builds only carry the
    // `127.0.0.1` loopback variant, which breaks `localhost` redirects.
    // The feature is unreleased, so such clients are discarded and
    // re-registered (fresh client ID with both loopback variants).
    var config = oauth.toLibraryConfig();
    if (oauth.clientRegistrationVersion == 1) {
      config = config.copyWith(clientId: '');
    }
    final result = await oauthFlowService.beginFlow(
      key: serverId,
      config: config,
      serverUrl: server.url,
    );
    // Persist discovered/registered values so the next run starts
    // fully configured. Persist only the deltas to avoid clobbering
    // user-edited fields with identical values. When the server never
    // had an OAuth config (switch just turned on in the edit form),
    // the override becomes the persisted base.
    if (result.usedDiscovery || result.usedDcr) {
      final idx = _servers.indexWhere((e) => e.id == serverId);
      if (idx >= 0) {
        final current = _servers[idx];
        final existing = current.oauth ?? oauth;
        final updated = existing.copyWith(
          authorizationEndpoint:
              result.discoveredAuthorizationEndpoint ??
              existing.authorizationEndpoint,
          tokenEndpoint:
              result.discoveredTokenEndpoint ?? existing.tokenEndpoint,
          clientId: result.discoveredClientId ?? existing.clientId,
          // A fresh DCR registration carries both loopback variants.
          clientRegistrationVersion: result.usedDcr
              ? 2
              : existing.clientRegistrationVersion,
        );
        _servers = List<McpServerConfig>.of(_servers)
          ..[idx] = current.copyWith(oauth: updated);
        await _persist();
        notifyListeners();
      }
    }
    return result;
  }

  /// Completes the OAuth flow for [serverId] with the pasted content
  /// (raw code or full redirect URL). Persists the obtained token and
  /// reconnects the server so the pre-authorization error state clears.
  Future<void> completeOAuthFlow(
    String serverId,
    String pasted, {
    Duration callbackTimeout = const Duration(minutes: 2),
  }) async {
    final token = await oauthFlowService.completeFlow(
      key: serverId,
      pasted: pasted,
      callbackTimeout: callbackTimeout,
    );
    final idx = _servers.indexWhere((e) => e.id == serverId);
    if (idx < 0) {
      oauthFlowService.cancelFlow(serverId);
      return;
    }
    final server = _servers[idx];
    _servers = List<McpServerConfig>.of(_servers)
      ..[idx] = server.copyWith(oauthToken: token);
    await _persist();
    notifyListeners();
    if (server.enabled) {
      // The connection may have failed earlier with "no token yet" —
      // reconnect now that the token is persisted.
      await disconnect(serverId);
      unawaited(connect(serverId));
    }
  }

  /// Clears the persisted OAuth token for [serverId] (logout).
  Future<void> clearOAuthToken(String serverId) async {
    final idx = _servers.indexWhere((e) => e.id == serverId);
    if (idx < 0) return;
    _servers = List<McpServerConfig>.of(_servers)
      ..[idx] = _servers[idx].copyWith(clearOauthToken: true);
    await _persist();
    notifyListeners();
  }

  /// Cancels an in-flight OAuth flow (PKCE verifier discarded).
  void cancelOAuthFlow(String serverId) {
    oauthFlowService.cancelFlow(serverId);
  }

  /// Persists a refreshed OAuth token without bouncing the connection.
  /// Invoked from the transport's `onTokenRefreshed` hook.
  void _persistOAuthToken(String serverId, mcp.OAuthToken token) {
    final idx = _servers.indexWhere((e) => e.id == serverId);
    if (idx < 0) return;
    _servers = List<McpServerConfig>.of(_servers)
      ..[idx] = _servers[idx].copyWith(oauthToken: token);
    unawaited(_persist());
    notifyListeners();
  }

  Future<void> removeServer(String id) async {
    // Write trash bundle before deleting.
    final store = chatService?.deletedRecordsStore;
    if (store != null) {
      final server = _servers.where((e) => e.id == id).firstOrNull;
      if (server != null) {
        try {
          await store.recordDeletion(
            id: id,
            type: DeletionEntityType.mcpServer,
            recoveryJson: jsonEncode(server.toJson()),
            batchId: const Uuid().v4(),
            deletedAt: DateTime.now(),
          );
        } catch (e) {
          debugPrint('McpProvider.removeServer: failed to write trash: $e');
        }
      }
    }
    await disconnect(id);
    _servers = _servers.where((e) => e.id != id).toList(growable: false);
    _status.remove(id);
    await _persist();
    notifyListeners();
  }

  Future<void> reorderServers(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _servers.length) return;
    if (newIndex < 0 || newIndex >= _servers.length) return;
    final moved = _servers.removeAt(oldIndex);
    _servers.insert(newIndex, moved);
    notifyListeners();
    await _persist();
  }

  Future<void> setToolEnabled(
    String serverId,
    String toolName,
    bool enabled,
  ) async {
    final idx = _servers.indexWhere((e) => e.id == serverId);
    if (idx < 0) return;
    final server = _servers[idx];
    final tools = server.tools
        .map((t) => t.name == toolName ? t.copyWith(enabled: enabled) : t)
        .toList();
    _servers[idx] = server.copyWith(tools: tools);
    await _persist();
    notifyListeners();
  }

  /// Set whether a tool requires user approval before execution.
  Future<void> setToolNeedsApproval(
    String serverId,
    String toolName,
    bool needsApproval,
  ) async {
    final idx = _servers.indexWhere((e) => e.id == serverId);
    if (idx < 0) return;
    final server = _servers[idx];
    final tools = server.tools
        .map(
          (t) =>
              t.name == toolName ? t.copyWith(needsApproval: needsApproval) : t,
        )
        .toList();
    _servers[idx] = server.copyWith(tools: tools);
    await _persist();
    notifyListeners();
  }

  /// Check if a tool (by name) requires approval across all connected servers.
  /// Conservative: returns true if ANY connected server marks the tool as needing approval.
  bool toolNeedsApproval(String toolName) {
    for (final s in _servers) {
      if (statusFor(s.id) != McpStatus.connected) continue;
      if (!s.enabled) continue;
      for (final t in s.tools) {
        if (t.name == toolName && t.enabled && t.needsApproval) return true;
      }
    }
    return false;
  }

  Future<void> connect(String id) async {
    final server = _servers.firstWhere(
      (e) => e.id == id,
      orElse: () => throw StateError('Server not found'),
    );
    // If already connected, try a ping by listing tools quickly; else return
    if (_clients.containsKey(id)) {
      // Already connected; update status just in case
      _status[id] = McpStatus.connected;
      _errors.remove(id);
      notifyListeners();
      return;
    }
    _status[id] = McpStatus.connecting;
    _errors.remove(id);
    notifyListeners();

    try {
      // Log connect intent and parameters
      // debugPrint('[MCP/Connect] id=$id name=${server.name} transport=${server.transport.name}');
      // debugPrint('[MCP/Connect] url=${server.url}');
      // if (server.headers.isNotEmpty) {
      //   debugPrint('[MCP/Headers] ${server.headers.length} headers:');
      //   server.headers.forEach((k, v) {
      //     final masked = _maskIfSensitive(k, v);
      //     debugPrint('  - $k: $masked');
      //   });
      // } else {
      //   debugPrint('[MCP/Headers] (none)');
      // }

      final clientConfig = mcp.McpClient.simpleConfig(
        name: 'Kelivo MCP',
        version: '1.0.0',
        // Turn on library-internal verbose logs
        enableDebugLogging: false,
        requestTimeout: _requestTimeout,
        logListener: McpLogBridge.onEvent,
        logServerLabel: server.name,
      );

      // In-memory builtin server path
      if (server.transport == McpTransportType.inmemory) {
        final engine = switch (server.id) {
          'kelivo_subagent' => KelivoSubagentMcpServerEngine(
            assistants: assistantProvider!,
            chatService: chatService!,
            headlessGen: headlessGen!,
            contextProvider: contextProvider,
          ),
          _ => KelivoFetchMcpServerEngine(),
        };
        final transport = switch (engine) {
          KelivoSubagentMcpServerEngine e =>
            KelivoSubagentInMemoryClientTransport(e),
          _ => KelivoInMemoryClientTransport(
            engine as KelivoFetchMcpServerEngine,
          ),
        };
        final client = mcp.McpClient.createClient(clientConfig);
        await client.connect(transport);
        _clients[id] = client;
        _status[id] = McpStatus.connected;
        _errors.remove(id);
        notifyListeners();
        await refreshTools(id);
        _startHeartbeat(
          id,
          interval: Duration(seconds: server.heartbeatIntervalSeconds ?? 12),
        );
        return;
      }

      final mergedHeaders = <String, String>{...server.headers};
      final oauthConfig = server.oauth?.toLibraryConfig();
      final transportConfig = await () async {
        if (server.transport == McpTransportType.sse) {
          if (oauthConfig != null && server.oauthToken == null) {
            throw StateError(
              'OAuth server "${server.name}" has no token yet. '
              'Authorize it first (edit → OAuth section → 开始授权).',
            );
          }
          return mcp.TransportConfig.sse(
            serverUrl: server.url,
            headers: mergedHeaders.isEmpty ? null : mergedHeaders,
            oauthConfig: oauthConfig,
            oauthToken: server.oauthToken,
            onTokenRefreshed: (token) => _persistOAuthToken(id, token),
          );
        } else if (server.transport == McpTransportType.http) {
          if (oauthConfig != null && server.oauthToken == null) {
            throw StateError(
              'OAuth server "${server.name}" has no token yet. '
              'Authorize it first (edit → OAuth section → 开始授权).',
            );
          }
          return mcp.TransportConfig.streamableHttp(
            baseUrl: server.url,
            headers: mergedHeaders.isEmpty ? null : mergedHeaders,
            timeout: _requestTimeout,
            oauthConfig: oauthConfig,
            oauthToken: server.oauthToken,
            onTokenRefreshed: (token) => _persistOAuthToken(id, token),
          );
        } else {
          // STDIO; only supported on desktop
          if (!_isDesktopPlatform()) {
            throw StateError('STDIO transport not supported on this platform');
          }
          final cmd = server.command;
          if (cmd == null || cmd.isEmpty) {
            throw StateError('STDIO command is empty');
          }
          final mergedEnv = await _stdioCommandResolver
              .resolveEnvironmentWithPath(server.env);
          final commandExists = await _stdioCommandResolver.commandExists(
            cmd,
            mergedEnv,
          );
          if (!commandExists) {
            throw StateError(
              'Command "$cmd" not found in PATH. '
              'Ensure the command is installed and accessible.',
            );
          }
          return mcp.TransportConfig.stdio(
            command: cmd,
            arguments: server.args,
            workingDirectory: server.workingDirectory,
            environment: mergedEnv.isEmpty ? null : mergedEnv,
          );
        }
      }();

      // debugPrint('[MCP/Connect] creating client (enableDebugLogging=true) ...');
      final clientResult = await mcp.McpClient.createAndConnect(
        config: clientConfig,
        transportConfig: transportConfig,
      );

      final client = clientResult.fold((c) => c, (err) => throw err);
      _clients[id] = client;
      _status[id] = McpStatus.connected;
      _errors.remove(id);
      // debugPrint('[MCP/Connected] id=$id (${server.name})');
      notifyListeners();

      // Try to refresh tools once connected
      // debugPrint('[MCP/Tools] refreshing tools for id=$id ...');
      await refreshTools(id);
      // debugPrint('[MCP/Tools] refresh done for id=$id');

      // Start/refresh heartbeat for this connection
      _startHeartbeat(
        id,
        interval: Duration(seconds: server.heartbeatIntervalSeconds ?? 12),
      );
    } catch (e) {
      // debugPrint('[MCP/Error] connect failed for id=$id (${server.name})');
      // _logMcpException('connect', serverId: id, error: e, stack: st);
      _status[id] = McpStatus.error;
      _errors[id] = e.toString();
      notifyListeners();
    }
  }

  Future<void> updateRequestTimeout(
    Duration duration, {
    bool reconnectActive = true,
  }) async {
    if (duration.inMilliseconds <= 0) return;
    if (duration == _requestTimeout) return;
    _requestTimeout = duration;
    await _persistTimeout();
    notifyListeners();
    if (reconnectActive) {
      for (final id in _clients.keys.toList()) {
        if (_servers.any((s) => s.id == id && s.enabled)) {
          unawaited(reconnect(id));
        }
      }
    }
  }

  Future<void> disconnect(String id) async {
    final client = _clients.remove(id);
    try {
      // debugPrint('[MCP/Disconnect] id=$id ...');
      client?.disconnect();
      // debugPrint('[MCP/Disconnect] id=$id done');
    } catch (e) {
      // debugPrint('[MCP/Error] disconnect failed for id=$id');
      // _logMcpException('disconnect', serverId: id, error: e, stack: st);
    }
    _status[id] = McpStatus.idle;
    _errors.remove(id);
    _stopHeartbeat(id);
    notifyListeners();
  }

  Future<void> reconnect(String id) async {
    await disconnect(id);
    await connect(id);
  }

  Future<void> _reconnectWithBackoff(String id, {int maxAttempts = 3}) async {
    if (_reconnecting.contains(id)) return;
    _reconnecting.add(id);
    try {
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        await reconnect(id);
        if (isConnected(id)) return;
        // progressive backoff: 600ms, 1200ms, 2400ms
        final delayMs = 600 * (1 << (attempt - 1));
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    } finally {
      _reconnecting.remove(id);
    }
  }

  void _startHeartbeat(
    String id, {
    Duration interval = const Duration(seconds: 12),
  }) {
    _stopHeartbeat(id);
    _heartbeats[id] = Timer.periodic(interval, (t) async {
      // Heartbeat only when we think we're connected
      if (!isConnected(id)) return;
      final client = _clients[id];
      if (client == null) return;
      try {
        // A lightweight call to verify liveness
        // listTools is relatively cheap and available
        final fut = client.listTools(logTags: {'reason': 'heartbeat'});
        // Add a soft timeout to avoid piling up
        await fut.timeout(const Duration(seconds: 6));
      } catch (e) {
        // Rate-limited? Server is alive — skip this tick, don't reconnect.
        if (_isRateLimitError(e)) return;
        // debugPrint('[MCP/Heartbeat] liveness check failed id=$id');
        // Consider connection lost; mark error and try auto-reconnect
        _status[id] = McpStatus.error;
        _errors[id] = e.toString();
        notifyListeners();
        await _reconnectWithBackoff(id, maxAttempts: 3);
        // If reconnected, restart heartbeat (connect() also starts it)
        if (!isConnected(id)) {
          // keep error state; next heartbeat tick will be a no-op
        }
      }
    });
  }

  void _stopHeartbeat(String id) {
    _heartbeats.remove(id)?.cancel();
  }

  /// Returns true if the error indicates rate-limiting (429, MCP -32106).
  /// Rate-limited responses prove the server is alive — skip heartbeat retry.
  bool _isRateLimitError(Object e) {
    if (e is mcp.McpError && e.code == -32106) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('429') || msg.contains('rate limit');
  }

  McpToolConfig? _toolConfig(String serverId, String toolName) {
    final idx = _servers.indexWhere((e) => e.id == serverId);
    if (idx < 0) return null;
    final s = _servers[idx];
    for (final t in s.tools) {
      if (t.name == toolName) return t;
    }
    return null;
  }

  Map<String, dynamic> _normalizeArgsForTool(
    String serverId,
    String toolName,
    Map<String, dynamic> args,
  ) {
    try {
      final cfg = _toolConfig(serverId, toolName);
      final schema = cfg?.schema;
      if (schema == null || schema.isEmpty) return args;
      final cloned = jsonDecode(jsonEncode(args)) as Map<String, dynamic>;
      var normalized = _normalizeBySchema(cloned, schema, propertyName: null);
      if (normalized is! Map<String, dynamic>) return args;
      normalized = _normalizeSpecialCases(toolName, normalized);
      return normalized;
    } catch (_) {
      return args;
    }
  }

  Map<String, dynamic> _normalizeSpecialCases(
    String toolName,
    Map<String, dynamic> args,
  ) {
    try {
      if (toolName == 'firecrawl_search') {
        // sources: ["web"] -> [{"type":"web"}]
        final rawSources = args['sources'];
        if (rawSources is List &&
            rawSources.isNotEmpty &&
            rawSources.every((e) => e is String)) {
          args['sources'] = rawSources.map((e) => {'type': e}).toList();
        }
        // Provide pragmatic defaults for commonly required fields if absent
        args.putIfAbsent('tbs', () => '0');
        args.putIfAbsent('filter', () => '0');
        args.putIfAbsent('location', () => 'us');
        // If tbs/filter are present but empty, coerce to '0'
        if ((args['tbs'] is String) && (args['tbs'] as String).isEmpty) {
          args['tbs'] = '0';
        }
        if ((args['filter'] is String) && (args['filter'] as String).isEmpty) {
          args['filter'] = '0';
        }
        if ((args['location'] is String) &&
            (args['location'] as String).toLowerCase() == 'global') {
          args['location'] = 'us';
        }
        final so = (args['scrapeOptions'] is Map)
            ? (args['scrapeOptions'] as Map).cast<String, dynamic>()
            : <String, dynamic>{};
        so.putIfAbsent('waitFor', () => 0);
        // formats normalization: server expects union of simple literals ["markdown"|"html"|"rawHtml"] OR an object only when type=="json"
        final fm = so['formats'];
        if (fm is List) {
          final norm = <dynamic>[];
          for (final f in fm) {
            if (f is Map) {
              final t = (f['type'] ?? '').toString();
              if (t == 'markdown' || t == 'html' || t == 'rawHtml') {
                norm.add(t);
              } else if (t == 'json') {
                norm.add(f); // keep object form for json
              } else if (t.isNotEmpty) {
                norm.add(t);
              }
            } else if (f is String) {
              if (f == 'json') {
                norm.add({'type': 'json'});
              } else {
                norm.add(f);
              }
            } else {
              norm.add(f);
            }
          }
          so['formats'] = norm;
        }
        args['scrapeOptions'] = so;
      }
    } catch (_) {}
    return args;
  }

  dynamic _normalizeBySchema(
    dynamic value,
    Map<String, dynamic> schema, {
    String? propertyName,
  }) {
    try {
      // Handle anyOf/oneOf by choosing first matching branch; if value is null, attempt defaults
      final List<Map<String, dynamic>> unions = _schemaUnions(schema);
      if (unions.isNotEmpty) {
        // Heuristic only for certain fields (e.g., sources) — DO NOT apply globally.
        if (value is String && propertyName == 'sources') {
          final objBranch = unions.firstWhere(
            (m) =>
                _schemaTypes(m).contains('object') &&
                ((m['properties'] as Map?)?.containsKey('type') ?? false),
            orElse: () => const {},
          );
          if (objBranch.isNotEmpty) {
            return _normalizeBySchema(
              {'type': value},
              objBranch,
              propertyName: propertyName,
            );
          }
        }
        for (final branch in unions) {
          try {
            return _normalizeBySchema(
              value,
              branch,
              propertyName: propertyName,
            );
          } catch (_) {
            // try next branch
          }
        }
        // fallthrough to first branch
        return _normalizeBySchema(
          value,
          unions.first,
          propertyName: propertyName,
        );
      }

      final declaredTypes = _schemaTypes(schema);
      if (declaredTypes.contains('object')) {
        final props =
            (schema['properties'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        final req =
            (schema['required'] as List?)?.map((e) => e.toString()).toSet() ??
            const <String>{};
        final out = <String, dynamic>{};
        final input = (value is Map)
            ? value.cast<String, dynamic>()
            : const <String, dynamic>{};
        // copy passthrough unknowns
        input.forEach((k, v) {
          if (!props.containsKey(k)) out[k] = v;
        });
        for (final entry in props.entries) {
          final key = entry.key;
          final propSchema = (entry.value is Map)
              ? (entry.value as Map).cast<String, dynamic>()
              : const <String, dynamic>{};
          dynamic v = input.containsKey(key) ? input[key] : null;
          if (v == null) {
            if (propSchema.containsKey('default')) {
              v = propSchema['default'];
            } else if (req.contains(key)) {
              // Only synthesize enum / waitFor defaults for required fields; optional
              // omitted keys should stay absent (do not pick enum.first).
              final enumVals = _schemaEnum(propSchema);
              if (enumVals.isNotEmpty) {
                v = enumVals.first;
              } else if (key == 'waitFor' &&
                  _schemaTypes(
                    propSchema,
                  ).any((t) => t == 'number' || t == 'integer')) {
                v = 0; // pragmatic default often acceptable for waitFor
              }
            }
          }
          if (v != null) {
            out[key] = _normalizeBySchema(v, propSchema, propertyName: key);
          } else if (!req.contains(key)) {
            // omit optional nulls
          } else {
            // keep as null for required to let server validate if still missing
          }
        }
        return out;
      }

      if (declaredTypes.contains('array')) {
        final items =
            (schema['items'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        final list = (value is List) ? value : [value];
        final out = [];
        for (final item in list) {
          dynamic iv = item;
          // Heuristic only for sources array, not for other arrays like formats
          final itemTypes = _schemaTypes(items);
          if (propertyName == 'sources' &&
              item is String &&
              itemTypes.contains('object')) {
            final itemProps =
                (items['properties'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{};
            if (itemProps.containsKey('type')) {
              iv = {'type': item};
            }
          }
          out.add(_normalizeBySchema(iv, items, propertyName: propertyName));
        }
        return out;
      }

      if (declaredTypes.contains('boolean')) {
        if (value is bool) return value;
        if (value is String) {
          final s = value.toLowerCase();
          if (s == 'true' || s == '1' || s == 'yes') return true;
          if (s == 'false' || s == '0' || s == 'no') return false;
        }
        return value;
      }

      if (declaredTypes.contains('integer')) {
        if (value is int) return value;
        if (value is num) return value.toInt();
        if (value is String) {
          final p = int.tryParse(value);
          if (p != null) return p;
        }
        return value;
      }

      if (declaredTypes.contains('number')) {
        if (value is num) return value;
        if (value is String) {
          final p = double.tryParse(value);
          if (p != null) return p;
        }
        return value;
      }

      if (declaredTypes.contains('string')) {
        if (value == null) return value;
        if (value is String) {
          final enums = _schemaEnum(schema);
          if (enums.isNotEmpty && !enums.contains(value)) {
            // keep original; server will validate
          }
          return value;
        }
        return value.toString();
      }

      // no declared type: return as-is
      return value;
    } catch (_) {
      return value;
    }
  }

  List<Map<String, dynamic>> _schemaUnions(Map<String, dynamic> schema) {
    final out = <Map<String, dynamic>>[];
    final anyOf = schema['anyOf'];
    final oneOf = schema['oneOf'];
    if (anyOf is List) {
      out.addAll(anyOf.whereType<Map>().map((e) => e.cast<String, dynamic>()));
    }
    if (oneOf is List) {
      out.addAll(oneOf.whereType<Map>().map((e) => e.cast<String, dynamic>()));
    }
    return out;
  }

  List<String> _schemaTypes(Map<String, dynamic> schema) {
    final t = schema['type'];
    if (t is String) return [t];
    if (t is List) return t.map((e) => e.toString()).toList();
    return const [];
  }

  List<dynamic> _schemaEnum(Map<String, dynamic> schema) {
    final e = schema['enum'];
    if (e is List) return e;
    return const [];
  }

  Future<void> refreshTools(String id) async {
    final client = _clients[id];
    if (client == null) return;
    try {
      // debugPrint('[MCP/Tools] listTools() ...');
      final tools = await client.listTools();
      // debugPrint('[MCP/Tools] listTools() returned ${tools.length} tools');
      // Preserve enabled state from existing config
      final idx = _servers.indexWhere((e) => e.id == id);
      if (idx < 0) return;
      final existing = _servers[idx].tools;
      final existingMap = {for (final t in existing) t.name: t};

      List<McpToolConfig> merged = [];
      for (final t in tools) {
        final prior = existingMap[t.name];
        // Extract params from inputSchema if present
        final params = <McpParamSpec>[];
        Map<String, dynamic>? schemaJson;
        try {
          final js = t.inputSchema;
          schemaJson = js;
          final props =
              (js['properties'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          final req =
              (js['required'] as List?)?.map((e) => e.toString()).toSet() ??
              const <String>{};
          props.forEach((key, val) {
            String? ty;
            dynamic defVal;
            try {
              final v = (val as Map).cast<String, dynamic>();
              final ttype = v['type'];
              if (ttype is String) {
                ty = ttype;
              } else if (ttype is List) {
                ty = ttype.map((e) => e.toString()).join('|');
              }
              defVal = v['default'];
            } catch (_) {}
            params.add(
              McpParamSpec(
                name: key,
                required: req.contains(key),
                type: ty,
                defaultValue: defVal,
              ),
            );
          });
        } catch (_) {}

        merged.add(
          McpToolConfig(
            enabled: prior?.enabled ?? true,
            name: t.name,
            description: t.description,
            params: params,
            schema: schemaJson,
            needsApproval: prior?.needsApproval ?? false,
          ),
        );
      }

      _servers[idx] = _servers[idx].copyWith(tools: merged);
      await _persist();
      notifyListeners();
    } catch (e) {
      // debugPrint('[MCP/Tools] listTools() failed for id=$id');
      // ignore tool refresh errors; status stays connected
    }
  }

  Future<void> ensureConnected(String id) async {
    // Do not attempt to connect if the server is disabled
    final cfg = getById(id);
    if (cfg == null || !cfg.enabled) return;
    if (isConnected(id)) return;
    // Try a few times with short backoff in case server blips
    await _reconnectWithBackoff(id, maxAttempts: 3);
  }

  Future<mcp.CallToolResult?> callTool(
    String serverId,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    try {
      await ensureConnected(serverId);
      var client = _clients[serverId];
      if (client == null) return null;
      // Normalize arguments based on tool schema (best-effort)
      final normalized = _normalizeArgsForTool(serverId, toolName, args);
      // if (normalized != args) {
      //   debugPrint('[MCP/Call] serverId=$serverId tool=$toolName args(normalized)=${jsonEncode(normalized)}');
      // } else {
      //   debugPrint('[MCP/Call] serverId=$serverId tool=$toolName args=${jsonEncode(args)}');
      // }
      final result = await client.callTool(toolName, normalized);
      // Detailed call timing/content logging disabled
      return result;
    } catch (e) {
      // debugPrint('[MCP/Call/Error] serverId=$serverId tool=$toolName');

      // If this is a parameter validation error from the server, do NOT disconnect.
      try {
        if (e is mcp.McpError && (e.code == -32602)) {
          // Keep connection healthy status; surface error to caller via null
          _errors[serverId] = e.toString();
          // debugPrint('[MCP/Call] invalid arguments; skipping reconnect');
          return null;
        }
      } catch (_) {}

      _status[serverId] = McpStatus.error;
      _errors[serverId] = e.toString();
      notifyListeners();
      // Auto-reconnect a few times and try once more
      try {
        await _reconnectWithBackoff(serverId, maxAttempts: 3);
        if (!isConnected(serverId)) return null;
        final client = _clients[serverId];
        if (client == null) return null;
        // debugPrint('[MCP/Call] retry serverId=$serverId tool=$toolName');
        final normalized = _normalizeArgsForTool(serverId, toolName, args);
        final result = await client.callTool(toolName, normalized);
        // Detailed retry logging disabled
        // Mark healthy again
        _status[serverId] = McpStatus.connected;
        _errors.remove(serverId);
        notifyListeners();
        return result;
      } catch (e2) {
        // debugPrint('[MCP/Call/RetryError] serverId=$serverId tool=$toolName');
        // Keep error state; give up
        return null;
      }
    }
  }

  List<McpToolConfig> getEnabledToolsForServers(Set<String> serverIds) {
    // Only expose tools for servers that are both selected AND currently connected
    final tools = <McpToolConfig>[];
    for (final s in _servers.where((s) => serverIds.contains(s.id))) {
      if (statusFor(s.id) != McpStatus.connected) continue;
      if (!s.enabled) continue;
      tools.addAll(s.tools.where((t) => t.enabled));
    }
    return tools;
  }

  @override
  void dispose() {
    assistantProvider?.removeListener(_onAssistantsChanged);
    // Clean up timers
    for (final t in _heartbeats.values) {
      t.cancel();
    }
    _heartbeats.clear();
    super.dispose();
  }

  bool _isDesktopPlatform() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }
}
