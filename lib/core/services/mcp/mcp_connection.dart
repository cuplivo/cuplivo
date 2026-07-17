// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

import '../../providers/mcp_provider.dart';
import 'kelivo_fetch/kelivo_fetch_server.dart';
import 'mcp_connection_state.dart';
import 'stdio_command_resolver.dart';

/// Manages the full lifecycle of a single MCP server connection.
///
/// Owns the [mcp.Client], transport creation, and exposes a
/// [stateStream] as the single source of truth for connection health.
/// No heartbeat — SSE disconnect propagates through the transport layer.
class McpConnection {
  final String id;
  final McpServerConfig _config;
  final Duration _requestTimeout;
  final McpStdioCommandResolver _stdioCommandResolver =
      McpStdioCommandResolver();

  mcp.Client? _client;

  final _stateController = StreamController<McpConnectionState>.broadcast();
  McpConnectionState _state = const McpConnectionIdle();

  Stream<McpConnectionState> get stateStream => _stateController.stream;
  McpConnectionState get state => _state;
  bool get isConnected => _state is McpConnectionConnected;
  String? get errorMessage => _state is McpConnectionError
      ? (_state as McpConnectionError).message
      : null;

  McpConnection({
    required this.id,
    required McpServerConfig config,
    required Duration requestTimeout,
  })  : _config = config,
        _requestTimeout = requestTimeout;

  void _emit(McpConnectionState s) {
    _state = s;
    _stateController.add(s);
  }

  /// Connect to the MCP server. No-op if already connected or connecting.
  Future<void> connect() async {
    if (_state is McpConnectionConnected || _state is McpConnectionConnecting) {
      return;
    }

    _emit(const McpConnectionConnecting());

    try {
      final clientConfig = mcp.McpClient.simpleConfig(
        name: 'Kelivo MCP',
        version: '1.0.0',
        requestTimeout: _requestTimeout,
      );

      // In-memory builtin server path
      if (_config.transport == McpTransportType.inmemory) {
        final engine = KelivoFetchMcpServerEngine();
        final transport = KelivoInMemoryClientTransport(engine);
        final client = mcp.McpClient.createClient(clientConfig);
        await client.connect(transport);
        _client = client;
        _listenTransportClose(client);
        _emit(const McpConnectionConnected());
        return;
      }

      final mergedHeaders = <String, String>{..._config.headers};
      final transportConfig = await _buildTransportConfig(mergedHeaders);
      final clientResult = await mcp.McpClient.createAndConnect(
        config: clientConfig,
        transportConfig: transportConfig,
      );

      final client = clientResult.fold((c) => c, (err) => throw err);
      _client = client;
      _listenTransportClose(client);
      _emit(const McpConnectionConnected());
    } catch (e) {
      _emit(McpConnectionError(e.toString()));
      rethrow;
    }
  }

  /// Listen for transport disconnect and propagate as connection error.
  void _listenTransportClose(mcp.Client client) {
    client.onDisconnect.listen((reason) {
      if (_state is McpConnectionConnected) {
        _emit(McpConnectionError('Disconnected: ${reason.name}'));
      }
      _client = null;
    });
  }

  Future<mcp.TransportConfig> _buildTransportConfig(
    Map<String, String> headers,
  ) async {
    switch (_config.transport) {
      case McpTransportType.sse:
        return mcp.TransportConfig.sse(
          serverUrl: _config.url,
          headers: headers.isEmpty ? null : headers,
        );
      case McpTransportType.http:
        return mcp.TransportConfig.streamableHttp(
          baseUrl: _config.url,
          headers: headers.isEmpty ? null : headers,
          timeout: _requestTimeout,
        );
      case McpTransportType.stdio:
        if (!_isDesktopPlatform()) {
          throw StateError('STDIO transport not supported on this platform');
        }
        final cmd = _config.command;
        if (cmd == null || cmd.isEmpty) {
          throw StateError('STDIO command is empty');
        }
        final mergedEnv = await _stdioCommandResolver
            .resolveEnvironmentWithPath(_config.env);
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
          arguments: _config.args,
          workingDirectory: _config.workingDirectory,
          environment: mergedEnv.isEmpty ? null : mergedEnv,
        );
      case McpTransportType.inmemory:
        throw StateError('Inmemory should be handled before transport config');
    }
  }

  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    try {
      client?.disconnect();
    } catch (_) {}
    _emit(const McpConnectionIdle());
  }

  /// Call a tool. Handles reconnect + single retry on failure.
  Future<mcp.CallToolResult?> callTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    try {
      return await _callToolInternal(toolName, args);
    } catch (e) {
      // Don't retry on validation errors (-32602)
      if (e is mcp.McpError && e.code == -32602) {
        return null;
      }
      // Reconnect and retry once
      await disconnect();
      try {
        await connect();
        return await _callToolInternal(toolName, args);
      } catch (_) {
        return null;
      }
    }
  }

  Future<mcp.CallToolResult> _callToolInternal(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    return await client.callTool(toolName, args);
  }

  Future<List<mcp.Tool>> listTools() async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    return await client.listTools();
  }

  void dispose() {
    disconnect();
    _stateController.close();
  }

  static bool _isDesktopPlatform() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }
}
