/// SSE Transport with OAuth 2.1 Bearer Token Authentication
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show HttpClient, HttpClientRequest, HttpClientResponse, ContentType;

import '../../logger.dart';
import '../auth/oauth.dart';
import '../models/models.dart';
import 'transport.dart';
import 'event_source.dart';

final Logger _logger = Logger('mcp_client.sse_auth_transport');

/// SSE Transport with Bearer Token Authentication
class SseAuthClientTransport implements ClientTransport {
  final String serverUrl;
  final Map<String, String> _baseHeaders;
  final OAuthToken? _oauthToken;
  final OAuthClient? _oauthClient;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  late AuthenticatedEventSource _eventSource;
  String? _messageEndpoint;
  bool _isClosed = false;

  // Token refresh management
  Timer? _tokenRefreshTimer;
  bool _isRefreshingToken = false;

  SseAuthClientTransport._internal({
    required this.serverUrl,
    Map<String, String>? headers,
    OAuthToken? oauthToken,
    OAuthClient? oauthClient,
  }) : _baseHeaders = headers ?? {},
       _oauthToken = oauthToken,
       _oauthClient = oauthClient {
    _eventSource = AuthenticatedEventSource();
  }

  /// Create SSE transport with Bearer Token authentication
  static Future<SseAuthClientTransport> create({
    required String serverUrl,
    Map<String, String>? headers,
    OAuthToken? oauthToken,
    OAuthClient? oauthClient,
    String? bearerToken,
  }) async {
    final transport = SseAuthClientTransport._internal(
      serverUrl: serverUrl,
      headers: headers,
      oauthToken: oauthToken,
      oauthClient: oauthClient,
    );

    try {
      // Set up authentication headers
      final authHeaders = Map<String, String>.from(transport._baseHeaders);

      if (bearerToken != null) {
        authHeaders['Authorization'] = 'Bearer $bearerToken';
      } else if (oauthToken != null) {
        authHeaders['Authorization'] = 'Bearer ${oauthToken.accessToken}';

        // Set up automatic token refresh if needed
        transport._scheduleTokenRefresh();
      }

      // Add standard SSE headers
      authHeaders['Accept'] = 'text/event-stream';
      authHeaders['Cache-Control'] = 'no-cache';
      authHeaders['Connection'] = 'keep-alive';

      _logger.debug(
        'Connecting with authentication headers: ${authHeaders.keys.toList()}',
      );

      // Set up event handlers
      final endpointCompleter = Completer<String>();

      await transport._eventSource.connect(
        serverUrl,
        headers: authHeaders,
        onOpen: (endpoint) {
          if (!endpointCompleter.isCompleted && endpoint != null) {
            endpointCompleter.complete(endpoint);
          }
        },
        onMessage: (data) {
          if (!transport._messageController.isClosed) {
            transport._messageController.add(data);
          }
        },
        onError: (e) {
          _logger.debug('SSE authentication error: $e');
          if (!endpointCompleter.isCompleted) {
            endpointCompleter.completeError(e);
          }
          transport._handleError(e);
        },
        onAuthFailure: (statusCode, body) {
          transport._handleAuthFailure(statusCode, body);
        },
        onClose: () {
          transport._handleClose();
        },
      );

      // Wait for endpoint
      final endpointPath = await endpointCompleter.future.timeout(
        Duration(seconds: 15),
        onTimeout:
            () =>
                throw McpError('Timed out waiting for authenticated endpoint'),
      );

      transport._messageEndpoint =
          endpointPath.startsWith('http')
              ? endpointPath
              : transport._constructEndpointUrl(
                Uri.parse(serverUrl),
                endpointPath,
              );

      _logger.debug(
        'Authenticated SSE transport ready: ${transport._messageEndpoint}',
      );

      return transport;
    } catch (e) {
      transport.close();
      if (e.toString().contains('401') || e.toString().contains('403')) {
        throw McpError('Authentication failed: Invalid or expired token');
      }
      throw McpError('Failed to establish authenticated SSE connection: $e');
    }
  }

  /// Schedule automatic token refresh
  void _scheduleTokenRefresh() {
    if (_oauthToken?.remainingLifetime == null || _oauthClient == null) return;

    final refreshTime =
        (_oauthToken!.remainingLifetime! * 0.8)
            .round(); // Refresh at 80% of lifetime
    if (refreshTime > 60) {
      // Only schedule if more than 1 minute remaining
      _tokenRefreshTimer = Timer(Duration(seconds: refreshTime), () {
        _refreshTokenIfNeeded();
      });
      _logger.debug('Token refresh scheduled in $refreshTime seconds');
    }
  }

  /// Refresh OAuth token if needed
  Future<void> _refreshTokenIfNeeded() async {
    if (_isRefreshingToken ||
        _oauthClient == null ||
        _oauthToken?.refreshToken == null) {
      return;
    }

    _isRefreshingToken = true;
    _logger.debug('Refreshing OAuth token...');

    try {
      final newToken = await _oauthClient.refreshToken(
        refreshToken: _oauthToken!.refreshToken!,
      );

      // Update headers with new token
      final newHeaders = Map<String, String>.from(_baseHeaders);
      newHeaders['Authorization'] = 'Bearer ${newToken.accessToken}';
      newHeaders['Accept'] = 'text/event-stream';
      newHeaders['Cache-Control'] = 'no-cache';
      newHeaders['Connection'] = 'keep-alive';

      // Reconnect with new token
      await _reconnectWithNewToken(newHeaders);

      // Schedule next refresh
      _scheduleTokenRefresh();

      _logger.debug('Token refreshed successfully');
    } catch (e) {
      _logger.debug('Token refresh failed: $e');
      _handleAuthFailure(401, 'Token refresh failed');
    } finally {
      _isRefreshingToken = false;
    }
  }

  /// Reconnect SSE with new authentication token
  Future<void> _reconnectWithNewToken(Map<String, String> newHeaders) async {
    _logger.debug('Reconnecting SSE with refreshed token...');

    // Close current connection
    _eventSource.close();

    // Create new EventSource
    _eventSource = AuthenticatedEventSource();

    // Reconnect
    final endpointCompleter = Completer<String>();

    await _eventSource.connect(
      serverUrl,
      headers: newHeaders,
      onOpen: (endpoint) {
        if (!endpointCompleter.isCompleted && endpoint != null) {
          endpointCompleter.complete(endpoint);
        }
      },
      onMessage: (data) {
        if (!_messageController.isClosed) {
          _messageController.add(data);
        }
      },
      onError: (e) {
        _logger.debug('SSE reconnection error: $e');
        _handleError(e);
      },
      onAuthFailure: (statusCode, body) {
        _handleAuthFailure(statusCode, body);
      },
      onClose: () {
        _handleClose();
      },
    );

    // Update message endpoint
    final endpointPath = await endpointCompleter.future.timeout(
      Duration(seconds: 10),
      onTimeout:
          () => throw McpError('Timed out during token refresh reconnection'),
    );

    _messageEndpoint =
        endpointPath.startsWith('http')
            ? endpointPath
            : _constructEndpointUrl(Uri.parse(serverUrl), endpointPath);
  }

  void _handleAuthFailure(int statusCode, String body) {
    final errorMessage = 'Authentication failed: HTTP $statusCode - $body';
    _logger.debug(errorMessage);

    if (!_closeCompleter.isCompleted) {
      _closeCompleter.completeError(McpError(errorMessage));
    }

    // Add auth failure to message stream for higher-level handling
    if (!_messageController.isClosed) {
      _messageController.addError(McpError(errorMessage));
    }
  }

  void _handleClose() {
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
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

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) async {
    if (_isClosed) {
      _logger.debug('Attempted to send on closed authenticated transport');
      return;
    }

    if (_messageEndpoint == null) {
      throw McpError(
        'Cannot send message: Authenticated SSE connection not established',
      );
    }

    try {
      final jsonMessage = jsonEncode(message);
      _logger.debug('Sending authenticated message: $jsonMessage');

      final url = Uri.parse(_messageEndpoint!);
      final client = HttpClient();
      final request = await client.postUrl(url);

      // Set content type
      request.headers.contentType = ContentType.json;

      // Add authentication headers
      _baseHeaders.forEach((name, value) {
        request.headers.add(name, value);
      });

      // Add current OAuth token if available
      if (_oauthToken != null) {
        request.headers.set(
          'Authorization',
          'Bearer ${_oauthToken.accessToken}',
        );
      }

      // Send the request
      request.write(jsonMessage);
      final response = await request.close();

      // Handle response
      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        _logger.debug(
          'Authenticated message delivery confirmation: $responseBody',
        );
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        final responseBody = await response.transform(utf8.decoder).join();
        _logger.debug(
          'Authentication error during send: ${response.statusCode} - $responseBody',
        );

        // Try to refresh token if possible
        if (_oauthClient != null &&
            _oauthToken?.refreshToken != null &&
            !_isRefreshingToken) {
          await _refreshTokenIfNeeded();
          // Retry the send operation
          return send(message);
        } else {
          throw McpError(
            'Authentication failed during send: ${response.statusCode}',
          );
        }
      } else {
        final responseBody = await response.transform(utf8.decoder).join();
        _logger.debug('Error response: $responseBody');
        throw McpError(
          'Error sending authenticated message: ${response.statusCode}',
        );
      }

      client.close();
      _logger.debug('Authenticated message sent successfully');
    } catch (e) {
      _logger.debug('Error sending authenticated message: $e');
      rethrow;
    }
  }

  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;

    _logger.debug('Closing SseAuthClientTransport');

    // Cancel token refresh timer
    _tokenRefreshTimer?.cancel();

    // Close event source
    _eventSource.close();

    // Close streams
    if (!_messageController.isClosed) {
      _messageController.close();
    }
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
}

/// Authenticated EventSource implementation
class AuthenticatedEventSource implements EventSource {
  HttpClient? _client;
  HttpClientRequest? _request;
  HttpClientResponse? _response;
  StreamSubscription? _subscription;
  final _buffer = StringBuffer();
  bool _isConnected = false;

  @override
  bool get isConnected => _isConnected;

  @override
  HttpClientResponse? get response => _response;

  @override
  Future<void> connect(
    String url, {
    Map<String, String>? headers,
    Function(String?)? onOpen,
    Function(dynamic)? onMessage,
    Function(dynamic)? onError,
    Function(String?)? onEndpoint,
    Function(int, String)? onAuthFailure,
    Function()? onClose,
  }) async {
    _logger.debug('AuthenticatedEventSource connecting to: $url');
    if (_isConnected) {
      throw McpError('AuthenticatedEventSource is already connected');
    }

    try {
      _client = HttpClient();
      _request = await _client!.getUrl(Uri.parse(url));

      // Set authentication and SSE headers
      if (headers != null) {
        headers.forEach((key, value) {
          _request!.headers.set(key, value);
        });
      }

      _response = await _request!.close();

      // Handle authentication failures
      if (_response!.statusCode == 401 || _response!.statusCode == 403) {
        final body = await _response!.transform(utf8.decoder).join();
        _logger.debug(
          'Authentication failed: ${_response!.statusCode} - $body',
        );

        if (onAuthFailure != null) {
          onAuthFailure(_response!.statusCode, body);
        }

        throw McpError('Authentication failed: ${_response!.statusCode}');
      }

      if (_response!.statusCode != 200) {
        final body = await _response!.transform(utf8.decoder).join();
        throw McpError(
          'Failed to connect to authenticated SSE endpoint: ${_response!.statusCode} - $body',
        );
      }

      _isConnected = true;
      _logger.debug('Authenticated EventSource connection established');

      // Set up subscription to process events
      _subscription = _response!.listen(
        (List<int> data) {
          try {
            final chunk = utf8.decode(data, allowMalformed: true);
            _logger.debug('Raw authenticated SSE data: [$chunk]');
            _buffer.write(chunk);

            // Process all events in buffer
            final content = _buffer.toString();

            // Check for JSON-RPC responses
            if (content.contains('"jsonrpc":"2.0"') ||
                content.contains('"jsonrpc": "2.0"')) {
              _logger.debug(
                'Detected JSON-RPC data in authenticated SSE stream',
              );

              try {
                final jsonStart = content.indexOf('{');
                final jsonEnd = content.lastIndexOf('}') + 1;

                if (jsonStart >= 0 && jsonEnd > jsonStart) {
                  final jsonStr = content.substring(jsonStart, jsonEnd);
                  _logger.debug('Extracted authenticated JSON: $jsonStr');

                  try {
                    final jsonData = jsonDecode(jsonStr);
                    _logger.debug(
                      'Parsed authenticated JSON-RPC data: $jsonData',
                    );

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
                    _logger.debug(
                      'JSON parse error in authenticated stream: $e',
                    );
                  }
                }
              } catch (e) {
                _logger.debug(
                  'Error extracting JSON from authenticated stream: $e',
                );
              }
            }

            // Process SSE events
            final event = _processBuffer();
            _logger.debug(
              'Processed authenticated SSE event: ${event.event}, data: ${event.data}',
            );

            if (event.event == 'endpoint' && event.data != null) {
              _logger.debug(
                'Received authenticated endpoint event: ${event.data}',
              );
              if (onOpen != null) {
                onOpen(event.data);
              }
            } else if (event.data != null && onMessage != null) {
              onMessage(event.data);
            }
          } catch (e) {
            _logger.debug('Error processing authenticated SSE data: $e');
          }
        },
        onError: (e) {
          _logger.debug('Authenticated EventSource error: $e');
          _isConnected = false;
          if (onError != null) {
            onError(e);
          }
        },
        onDone: () {
          _logger.debug('Authenticated EventSource stream closed');
          _isConnected = false;
          if (onClose != null) {
            onClose();
          }
        },
      );
    } catch (e) {
      _logger.debug('Authenticated EventSource connection error: $e');
      _isConnected = false;
      if (onError != null) {
        onError(e);
      }
      rethrow;
    }
  }

  _SseEvent _processBuffer() {
    final content = _buffer.toString();
    _logger.debug('_processBuffer authenticated content: [$content]');

    if (content.isEmpty) {
      return _SseEvent('', null);
    }

    final eventBlocks = content.split('\n\n');
    _logger.debug(
      '_processBuffer authenticated event blocks count: ${eventBlocks.length}',
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
      _logger.debug('Processing authenticated line: [$trimmedLine]');

      if (trimmedLine.startsWith('event:')) {
        currentEvent = trimmedLine.substring(6).trim();
        _logger.debug('Found authenticated event type: $currentEvent');
      } else if (trimmedLine.startsWith('data:')) {
        currentData = trimmedLine.substring(5).trim();
        _logger.debug('Found authenticated event data: $currentData');
      }
    }

    // Clear processed event from buffer
    final remaining = eventBlocks.skip(1).join('\n\n');
    _buffer.clear();
    if (remaining.isNotEmpty) {
      _buffer.write(remaining);
    }

    _logger.debug(
      'Complete authenticated event found: $currentEvent, data: $currentData',
    );
    return _SseEvent(currentEvent, currentData);
  }

  @override
  void close() {
    _logger.debug('Closing AuthenticatedEventSource');

    _subscription?.cancel();

    try {
      _response?.detachSocket().then((socket) {
        _logger.debug('Detached authenticated socket - destroying...');
        socket.destroy();
      });
    } catch (e) {
      _logger.debug('Error detaching authenticated socket: $e');
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
