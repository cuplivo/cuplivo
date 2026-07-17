/// SSE Transport with heartbeat mechanism for connection monitoring
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show ContentType, HttpClient, HttpClientRequest, HttpClientResponse;

import '../../logger.dart';
import '../models/models.dart';
import 'transport.dart';

final Logger _logger = Logger('mcp_client.sse_heartbeat_transport');

/// Connection health status
enum ConnectionHealth { healthy, degraded, unhealthy, disconnected }

/// Heartbeat configuration
class HeartbeatConfig {
  /// Interval between heartbeat checks
  final Duration interval;

  /// Timeout for heartbeat response
  final Duration timeout;

  /// Number of missed heartbeats before marking connection as unhealthy
  final int maxMissedBeats;

  /// Whether to automatically reconnect on connection failure
  final bool autoReconnect;

  /// Maximum number of reconnection attempts
  final int maxReconnectAttempts;

  /// Delay between reconnection attempts
  final Duration reconnectDelay;

  const HeartbeatConfig({
    this.interval = const Duration(seconds: 30),
    this.timeout = const Duration(seconds: 10),
    this.maxMissedBeats = 3,
    this.autoReconnect = true,
    this.maxReconnectAttempts = 5,
    this.reconnectDelay = const Duration(seconds: 5),
  });
}

/// Heartbeat statistics
class HeartbeatStats {
  final int totalHeartbeats;
  final int missedHeartbeats;
  final int reconnectionAttempts;
  final Duration averageLatency;
  final ConnectionHealth currentHealth;
  final DateTime? lastHeartbeat;
  final DateTime? lastMissedHeartbeat;

  const HeartbeatStats({
    required this.totalHeartbeats,
    required this.missedHeartbeats,
    required this.reconnectionAttempts,
    required this.averageLatency,
    required this.currentHealth,
    this.lastHeartbeat,
    this.lastMissedHeartbeat,
  });

  Map<String, dynamic> toJson() => {
    'totalHeartbeats': totalHeartbeats,
    'missedHeartbeats': missedHeartbeats,
    'reconnectionAttempts': reconnectionAttempts,
    'averageLatencyMs': averageLatency.inMilliseconds,
    'currentHealth': currentHealth.name,
    'lastHeartbeat': lastHeartbeat?.toIso8601String(),
    'lastMissedHeartbeat': lastMissedHeartbeat?.toIso8601String(),
    'successRate':
        totalHeartbeats > 0
            ? (totalHeartbeats - missedHeartbeats) / totalHeartbeats
            : 0.0,
  };
}

/// SSE Transport with heartbeat monitoring
class SseHeartbeatClientTransport implements ClientTransport {
  final String serverUrl;
  final Map<String, String> _baseHeaders;
  final HeartbeatConfig _heartbeatConfig;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  final _healthController = StreamController<ConnectionHealth>.broadcast();

  late HeartbeatEventSource _eventSource;
  String? _messageEndpoint;
  bool _isClosed = false;

  // Heartbeat state
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  Timer? _reconnectTimer;
  int _missedHeartbeats = 0;
  int _totalHeartbeats = 0;
  int _reconnectionAttempts = 0;
  final List<Duration> _latencyHistory = [];
  ConnectionHealth _currentHealth = ConnectionHealth.disconnected;
  DateTime? _lastHeartbeat;
  DateTime? _lastMissedHeartbeat;

  SseHeartbeatClientTransport._internal({
    required this.serverUrl,
    Map<String, String>? headers,
    HeartbeatConfig? heartbeatConfig,
  }) : _baseHeaders = headers ?? {},
       _heartbeatConfig = heartbeatConfig ?? const HeartbeatConfig() {
    _eventSource = HeartbeatEventSource();
  }

  /// Create SSE transport with heartbeat monitoring
  static Future<SseHeartbeatClientTransport> create({
    required String serverUrl,
    Map<String, String>? headers,
    HeartbeatConfig? heartbeatConfig,
  }) async {
    final transport = SseHeartbeatClientTransport._internal(
      serverUrl: serverUrl,
      headers: headers,
      heartbeatConfig: heartbeatConfig,
    );

    try {
      await transport._establishConnection();
      return transport;
    } catch (e) {
      transport.close();
      throw McpError('Failed to establish heartbeat SSE connection: $e');
    }
  }

  /// Establish initial connection
  Future<void> _establishConnection() async {
    // Set up connection headers
    final connectionHeaders = Map<String, String>.from(_baseHeaders);
    connectionHeaders['Accept'] = 'text/event-stream';
    connectionHeaders['Cache-Control'] = 'no-cache';
    connectionHeaders['Connection'] = 'keep-alive';
    connectionHeaders['X-Heartbeat-Interval'] =
        _heartbeatConfig.interval.inSeconds.toString();

    _logger.debug('Establishing heartbeat connection to: $serverUrl');

    // Set up event handlers
    final endpointCompleter = Completer<String>();

    await _eventSource.connect(
      serverUrl,
      headers: connectionHeaders,
      onOpen: (endpoint) {
        if (!endpointCompleter.isCompleted && endpoint != null) {
          endpointCompleter.complete(endpoint);
        }
      },
      onMessage: (data) {
        _handleMessage(data);
      },
      onError: (e) {
        _logger.debug('SSE heartbeat error: $e');
        if (!endpointCompleter.isCompleted) {
          endpointCompleter.completeError(e);
        }
        _handleConnectionError(e);
      },
      onHeartbeat: (latency) {
        _handleHeartbeatResponse(latency);
      },
      onClose: () {
        _handleClose();
      },
    );

    // Wait for endpoint
    final endpointPath = await endpointCompleter.future.timeout(
      Duration(seconds: 15),
      onTimeout:
          () => throw McpError('Timed out waiting for heartbeat endpoint'),
    );

    _messageEndpoint =
        endpointPath.startsWith('http')
            ? endpointPath
            : _constructEndpointUrl(Uri.parse(serverUrl), endpointPath);

    // Update health and start heartbeat
    _updateHealth(ConnectionHealth.healthy);
    _startHeartbeat();

    _logger.debug('Heartbeat SSE transport ready: $_messageEndpoint');
  }

  void _handleMessage(dynamic data) {
    if (!_messageController.isClosed) {
      _messageController.add(data);
    }
  }

  void _handleConnectionError(dynamic error) {
    _logger.debug('Connection error: $error');
    _updateHealth(ConnectionHealth.disconnected);

    if (_heartbeatConfig.autoReconnect &&
        _reconnectionAttempts < _heartbeatConfig.maxReconnectAttempts) {
      _scheduleReconnect();
    } else {
      _handleError(error);
    }
  }

  void _handleHeartbeatResponse(Duration latency) {
    _totalHeartbeats++;
    _lastHeartbeat = DateTime.now();
    _latencyHistory.add(latency);

    // Keep only recent latency data (last 10 measurements)
    if (_latencyHistory.length > 10) {
      _latencyHistory.removeAt(0);
    }

    // Reset missed heartbeats counter
    _missedHeartbeats = 0;

    // Update health based on latency
    _updateHealthBasedOnLatency(latency);

    _logger.debug('Heartbeat received (latency: ${latency.inMilliseconds}ms)');
  }

  void _updateHealthBasedOnLatency(Duration latency) {
    final health =
        latency.inMilliseconds < 1000
            ? ConnectionHealth.healthy
            : latency.inMilliseconds < 3000
            ? ConnectionHealth.degraded
            : ConnectionHealth.unhealthy;

    _updateHealth(health);
  }

  void _updateHealth(ConnectionHealth newHealth) {
    if (_currentHealth != newHealth) {
      _currentHealth = newHealth;
      _logger.debug('Connection health changed to: ${newHealth.name}');

      if (!_healthController.isClosed) {
        _healthController.add(newHealth);
      }
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();

    _heartbeatTimer = Timer.periodic(_heartbeatConfig.interval, (timer) {
      _sendHeartbeat();
    });

    _logger.debug(
      'Heartbeat started (interval: ${_heartbeatConfig.interval.inSeconds}s)',
    );
  }

  void _sendHeartbeat() {
    if (_isClosed) return;

    _logger.debug('Sending heartbeat...');

    // Send heartbeat message
    try {
      _eventSource.sendHeartbeat();

      // Set timeout for heartbeat response
      _heartbeatTimeoutTimer?.cancel();
      _heartbeatTimeoutTimer = Timer(_heartbeatConfig.timeout, () {
        _handleMissedHeartbeat();
      });
    } catch (e) {
      _logger.debug('Failed to send heartbeat: $e');
      _handleMissedHeartbeat();
    }
  }

  void _handleMissedHeartbeat() {
    _missedHeartbeats++;
    _lastMissedHeartbeat = DateTime.now();

    _logger.debug(
      'Missed heartbeat ($_missedHeartbeats/${_heartbeatConfig.maxMissedBeats})',
    );

    if (_missedHeartbeats >= _heartbeatConfig.maxMissedBeats) {
      _logger.debug('Connection unhealthy due to missed heartbeats');
      _updateHealth(ConnectionHealth.unhealthy);

      if (_heartbeatConfig.autoReconnect) {
        _scheduleReconnect();
      }
    } else {
      _updateHealth(ConnectionHealth.degraded);
    }
  }

  void _scheduleReconnect() {
    if (_isClosed) return;

    _reconnectTimer?.cancel();
    _reconnectionAttempts++;

    _logger.debug(
      'Scheduling reconnection attempt $_reconnectionAttempts/${_heartbeatConfig.maxReconnectAttempts}',
    );

    _reconnectTimer = Timer(_heartbeatConfig.reconnectDelay, () {
      _attemptReconnection();
    });
  }

  Future<void> _attemptReconnection() async {
    if (_isClosed) return;

    _logger.debug('Attempting reconnection...');

    try {
      // Close existing connection
      _eventSource.close();
      _eventSource = HeartbeatEventSource();

      // Re-establish connection
      await _establishConnection();

      // Reset reconnection counter on success
      _reconnectionAttempts = 0;

      _logger.debug('Reconnection successful');
    } catch (e) {
      _logger.debug('Reconnection failed: $e');

      if (_reconnectionAttempts < _heartbeatConfig.maxReconnectAttempts) {
        _scheduleReconnect();
      } else {
        _logger.debug('Max reconnection attempts reached');
        _handleError(
          'Connection lost after ${_heartbeatConfig.maxReconnectAttempts} attempts',
        );
      }
    }
  }

  String _constructEndpointUrl(Uri baseUrl, String endpointPath) {
    try {
      final Uri endpointUri;
      if (endpointPath.contains('?')) {
        final parts = endpointPath.split('?');
        endpointUri = Uri(
          path: parts[0],
          query: parts.length > 1 ? parts[1] : null,
        );
      } else {
        endpointUri = Uri(path: endpointPath);
      }

      return Uri(
        scheme: baseUrl.scheme,
        host: baseUrl.host,
        port: baseUrl.port,
        path: endpointUri.path,
        query: endpointUri.query,
      ).toString();
    } catch (e) {
      _logger.debug('Error parsing endpoint URL: $e');
      return '${baseUrl.origin}$endpointPath';
    }
  }

  void _handleError(dynamic error) {
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.completeError(error);
    }
  }

  void _handleClose() {
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }

  /// Get current connection health
  ConnectionHealth get connectionHealth => _currentHealth;

  /// Stream of health status changes
  Stream<ConnectionHealth> get onHealthChange => _healthController.stream;

  /// Get heartbeat statistics
  HeartbeatStats getHeartbeatStats() {
    final avgLatency =
        _latencyHistory.isNotEmpty
            ? Duration(
              milliseconds:
                  (_latencyHistory
                              .map((d) => d.inMilliseconds)
                              .reduce((a, b) => a + b) /
                          _latencyHistory.length)
                      .round(),
            )
            : Duration.zero;

    return HeartbeatStats(
      totalHeartbeats: _totalHeartbeats,
      missedHeartbeats: _missedHeartbeats,
      reconnectionAttempts: _reconnectionAttempts,
      averageLatency: avgLatency,
      currentHealth: _currentHealth,
      lastHeartbeat: _lastHeartbeat,
      lastMissedHeartbeat: _lastMissedHeartbeat,
    );
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) async {
    if (_isClosed) {
      _logger.debug('Attempted to send on closed heartbeat transport');
      return;
    }

    if (_messageEndpoint == null) {
      throw McpError(
        'Cannot send message: Heartbeat SSE connection not established',
      );
    }

    // Check connection health before sending
    if (_currentHealth == ConnectionHealth.disconnected) {
      throw McpError('Cannot send message: Connection is disconnected');
    }

    try {
      final jsonMessage = jsonEncode(message);
      _logger.debug(
        'Sending heartbeat message: ${jsonMessage.substring(0, 100)}...',
      );

      final url = Uri.parse(_messageEndpoint!);
      final client = HttpClient();
      final request = await client.postUrl(url);

      // Set content type
      request.headers.contentType = ContentType.json;

      // Add base headers
      _baseHeaders.forEach((name, value) {
        request.headers.add(name, value);
      });

      // Send the request
      request.write(jsonMessage);
      final response = await request.close();

      // Handle response
      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        _logger.debug('Heartbeat message delivery confirmation: $responseBody');
      } else {
        final responseBody = await response.transform(utf8.decoder).join();
        _logger.debug('Error response: $responseBody');
        throw McpError(
          'Error sending heartbeat message: ${response.statusCode}',
        );
      }

      client.close();
      _logger.debug('Heartbeat message sent successfully');
    } catch (e) {
      _logger.debug('Error sending heartbeat message: $e');

      // Connection issue might affect health
      if (e.toString().contains('Connection') ||
          e.toString().contains('Network')) {
        _updateHealth(ConnectionHealth.degraded);
      }

      rethrow;
    }
  }

  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;

    _logger.debug('Closing SseHeartbeatClientTransport');

    // Cancel all timers
    _heartbeatTimer?.cancel();
    _heartbeatTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();

    // Close event source
    _eventSource.close();

    // Close streams
    if (!_messageController.isClosed) {
      _messageController.close();
    }
    if (!_healthController.isClosed) {
      _healthController.close();
    }
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }

    _updateHealth(ConnectionHealth.disconnected);
  }
}

/// Heartbeat-enabled EventSource implementation
class HeartbeatEventSource {
  HttpClient? _client;
  HttpClientRequest? _request;
  HttpClientResponse? _response;
  StreamSubscription? _subscription;
  final _buffer = StringBuffer();
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  Future<void> connect(
    String url, {
    Map<String, String>? headers,
    Function(String?)? onOpen,
    Function(dynamic)? onMessage,
    Function(dynamic)? onError,
    Function(Duration)? onHeartbeat,
    Function()? onClose,
  }) async {
    _logger.debug('HeartbeatEventSource connecting to: $url');
    if (_isConnected) {
      throw McpError('HeartbeatEventSource is already connected');
    }

    try {
      _client = HttpClient();
      _request = await _client!.getUrl(Uri.parse(url));

      // Set heartbeat and SSE headers
      if (headers != null) {
        headers.forEach((key, value) {
          _request!.headers.set(key, value);
        });
      }

      _response = await _request!.close();

      if (_response!.statusCode != 200) {
        final body = await _response!.transform(utf8.decoder).join();
        throw McpError(
          'Failed to connect to heartbeat SSE endpoint: ${_response!.statusCode} - $body',
        );
      }

      _isConnected = true;
      _logger.debug('Heartbeat EventSource connection established');

      // Set up subscription to process heartbeat events
      _subscription = _response!.listen(
        (List<int> data) {
          try {
            final chunk = utf8.decode(data, allowMalformed: true);
            _logger.debug('Raw heartbeat SSE data: [$chunk]');
            _buffer.write(chunk);

            // Process all events in buffer
            final content = _buffer.toString();

            // Check for heartbeat responses
            if (content.contains('event: heartbeat') ||
                content.contains('event:heartbeat')) {
              _logger.debug('Detected heartbeat event in SSE stream');

              final event = _processBuffer();
              if (event.event == 'heartbeat' && onHeartbeat != null) {
                final latency = _calculateLatency(event.data);
                onHeartbeat(latency);
                return;
              }
            }

            // Check for JSON-RPC responses
            if (content.contains('"jsonrpc":"2.0"') ||
                content.contains('"jsonrpc": "2.0"')) {
              _logger.debug('Detected JSON-RPC data in heartbeat SSE stream');

              try {
                final jsonStart = content.indexOf('{');
                final jsonEnd = content.lastIndexOf('}') + 1;

                if (jsonStart >= 0 && jsonEnd > jsonStart) {
                  final jsonStr = content.substring(jsonStart, jsonEnd);
                  _logger.debug(
                    'Extracted heartbeat JSON: ${jsonStr.substring(0, 100)}...',
                  );

                  try {
                    final jsonData = jsonDecode(jsonStr);
                    _logger.debug('Parsed heartbeat JSON-RPC data');

                    // Clear processed data from buffer
                    if (jsonEnd < content.length) {
                      _buffer.clear();
                      _buffer.write(content.substring(jsonEnd));
                    } else {
                      _buffer.clear();
                    }

                    // Forward to message handler
                    if (onMessage != null) {
                      onMessage(jsonData);
                    }
                    return;
                  } catch (e) {
                    _logger.debug('JSON parse error in heartbeat stream: $e');
                  }
                }
              } catch (e) {
                _logger.debug(
                  'Error extracting JSON from heartbeat stream: $e',
                );
              }
            }

            // Process regular SSE events
            final event = _processBuffer();
            _logger.debug(
              'Processed heartbeat SSE event: ${event.event}, data: ${event.data}',
            );

            if (event.event == 'endpoint' && event.data != null) {
              _logger.debug('Received heartbeat endpoint event: ${event.data}');
              if (onOpen != null) {
                onOpen(event.data);
              }
            } else if (event.data != null && onMessage != null) {
              onMessage(event.data);
            }
          } catch (e) {
            _logger.debug('Error processing heartbeat SSE data: $e');
          }
        },
        onError: (e) {
          _logger.debug('Heartbeat EventSource error: $e');
          _isConnected = false;
          if (onError != null) {
            onError(e);
          }
        },
        onDone: () {
          _logger.debug('Heartbeat EventSource stream closed');
          _isConnected = false;
          if (onClose != null) {
            onClose();
          }
        },
      );
    } catch (e) {
      _logger.debug('Heartbeat EventSource connection error: $e');
      _isConnected = false;
      if (onError != null) {
        onError(e);
      }
      rethrow;
    }
  }

  Duration _calculateLatency(String? data) {
    try {
      if (data != null) {
        // Parse timestamp from heartbeat data
        final timestamp = int.tryParse(data);
        if (timestamp != null) {
          final sentTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
          return DateTime.now().difference(sentTime);
        }
      }
    } catch (e) {
      _logger.debug('Error calculating heartbeat latency: $e');
    }

    // Default latency if parsing fails
    return Duration(milliseconds: 100);
  }

  void sendHeartbeat() {
    // In a real implementation, this would send a heartbeat message
    // through the message endpoint or a separate heartbeat endpoint
    _logger.debug('Heartbeat sent (placeholder implementation)');
  }

  _SseEvent _processBuffer() {
    final content = _buffer.toString();
    _logger.debug('_processBuffer heartbeat content: [$content]');

    if (content.isEmpty) {
      return _SseEvent('', null);
    }

    final eventBlocks = content.split('\n\n');
    _logger.debug(
      '_processBuffer heartbeat event blocks count: ${eventBlocks.length}',
    );

    if (eventBlocks.length < 2) {
      return _SseEvent('', null);
    }

    final eventBlock = eventBlocks[0];
    final lines = eventBlock.split('\n');

    String currentEvent = '';
    String? currentData;

    for (final line in lines) {
      final trimmedLine = line.trim();
      _logger.debug('Processing heartbeat line: [$trimmedLine]');

      if (trimmedLine.startsWith('event:')) {
        currentEvent = trimmedLine.substring(6).trim();
        _logger.debug('Found heartbeat event type: $currentEvent');
      } else if (trimmedLine.startsWith('data:')) {
        currentData = trimmedLine.substring(5).trim();
        _logger.debug('Found heartbeat event data: $currentData');
      }
    }

    // Clear processed event from buffer
    final remaining = eventBlocks.skip(1).join('\n\n');
    _buffer.clear();
    if (remaining.isNotEmpty) {
      _buffer.write(remaining);
    }

    _logger.debug(
      'Complete heartbeat event found: $currentEvent, data: $currentData',
    );
    return _SseEvent(currentEvent, currentData);
  }

  void close() {
    _logger.debug('Closing HeartbeatEventSource');

    _subscription?.cancel();

    try {
      _response?.detachSocket().then((socket) {
        _logger.debug('Detached heartbeat socket - destroying...');
        socket.destroy();
      });
    } catch (e) {
      _logger.debug('Error detaching heartbeat socket: $e');
    }

    try {
      _request?.abort();
    } catch (_) {}

    try {
      _client?.close(force: true);
    } catch (_) {}

    _isConnected = false;
  }
}

class _SseEvent {
  final String event;
  final String? data;

  _SseEvent(this.event, this.data);
}
