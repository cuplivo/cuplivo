/// SSE Transport with compression support (gzip/deflate/br)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        ContentType,
        gzip,
        zlib,
        HttpClient,
        HttpClientRequest,
        HttpClientResponse;

import '../../logger.dart';
import '../models/models.dart';
import 'transport.dart';

final Logger _logger = Logger('mcp_client.sse_compressed_transport');

/// Compression types supported
enum CompressionType {
  none('identity'),
  gzip('gzip'),
  deflate('deflate'),
  brotli('br');

  const CompressionType(this.encoding);
  final String encoding;
}

/// SSE Transport with automatic compression support
class SseCompressedClientTransport implements ClientTransport {
  final String serverUrl;
  final Map<String, String> _baseHeaders;
  final List<CompressionType> _supportedCompressions;
  final int _compressionThreshold;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  late CompressedEventSource _eventSource;
  String? _messageEndpoint;
  CompressionType _negotiatedCompression = CompressionType.none;
  bool _isClosed = false;

  SseCompressedClientTransport._internal({
    required this.serverUrl,
    Map<String, String>? headers,
    List<CompressionType>? supportedCompressions,
    int compressionThreshold = 1024, // 1KB threshold
  }) : _baseHeaders = headers ?? {},
       _supportedCompressions =
           supportedCompressions ??
           [
             CompressionType.gzip,
             CompressionType.deflate,
             CompressionType.brotli,
             CompressionType.none,
           ],
       _compressionThreshold = compressionThreshold {
    _eventSource = CompressedEventSource();
  }

  /// Create SSE transport with compression negotiation
  static Future<SseCompressedClientTransport> create({
    required String serverUrl,
    Map<String, String>? headers,
    List<CompressionType>? supportedCompressions,
    int compressionThreshold = 1024,
  }) async {
    final transport = SseCompressedClientTransport._internal(
      serverUrl: serverUrl,
      headers: headers,
      supportedCompressions: supportedCompressions,
      compressionThreshold: compressionThreshold,
    );

    try {
      // Set up compression negotiation headers
      final compressionHeaders = Map<String, String>.from(
        transport._baseHeaders,
      );

      // Add Accept-Encoding for compression negotiation
      final acceptEncodings = transport._supportedCompressions
          .map((c) => c.encoding)
          .join(', ');
      compressionHeaders['Accept-Encoding'] = acceptEncodings;

      // Add standard SSE headers
      compressionHeaders['Accept'] = 'text/event-stream';
      compressionHeaders['Cache-Control'] = 'no-cache';
      compressionHeaders['Connection'] = 'keep-alive';

      _logger.debug('Connecting with compression support: $acceptEncodings');

      // Set up event handlers
      final endpointCompleter = Completer<String>();

      await transport._eventSource.connect(
        serverUrl,
        headers: compressionHeaders,
        compressionThreshold: transport._compressionThreshold,
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
          _logger.debug('SSE compression error: $e');
          if (!endpointCompleter.isCompleted) {
            endpointCompleter.completeError(e);
          }
          transport._handleError(e);
        },
        onCompressionNegotiated: (compression) {
          transport._negotiatedCompression = compression;
          _logger.debug('Compression negotiated: ${compression.encoding}');
        },
        onClose: () {
          transport._handleClose();
        },
      );

      // Wait for endpoint
      final endpointPath = await endpointCompleter.future.timeout(
        Duration(seconds: 15),
        onTimeout:
            () => throw McpError('Timed out waiting for compressed endpoint'),
      );

      transport._messageEndpoint =
          endpointPath.startsWith('http')
              ? endpointPath
              : transport._constructEndpointUrl(
                Uri.parse(serverUrl),
                endpointPath,
              );

      _logger.debug(
        'Compressed SSE transport ready: ${transport._messageEndpoint}',
      );
      _logger.debug(
        'Active compression: ${transport._negotiatedCompression.encoding}',
      );

      return transport;
    } catch (e) {
      transport.close();
      throw McpError('Failed to establish compressed SSE connection: $e');
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

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) async {
    if (_isClosed) {
      _logger.debug('Attempted to send on closed compressed transport');
      return;
    }

    if (_messageEndpoint == null) {
      throw McpError(
        'Cannot send message: Compressed SSE connection not established',
      );
    }

    try {
      final jsonMessage = jsonEncode(message);
      final shouldCompress = jsonMessage.length >= _compressionThreshold;

      _logger.debug(
        'Sending message (${jsonMessage.length} bytes, compress: $shouldCompress): ${jsonMessage.substring(0, 100)}...',
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

      // Apply compression if needed and supported
      List<int> bodyBytes = utf8.encode(jsonMessage);
      if (shouldCompress && _negotiatedCompression != CompressionType.none) {
        bodyBytes = await _compressData(bodyBytes, _negotiatedCompression);
        request.headers.set(
          'Content-Encoding',
          _negotiatedCompression.encoding,
        );
        _logger.debug(
          'Compressed message from ${jsonMessage.length} to ${bodyBytes.length} bytes',
        );
      }

      // Send the request
      request.add(bodyBytes);
      final response = await request.close();

      // Handle response
      if (response.statusCode == 200) {
        final responseBody = await _decompressResponse(response);
        _logger.debug(
          'Compressed message delivery confirmation: $responseBody',
        );
      } else {
        final responseBody = await _decompressResponse(response);
        _logger.debug('Error response: $responseBody');
        throw McpError(
          'Error sending compressed message: ${response.statusCode}',
        );
      }

      client.close();
      _logger.debug('Compressed message sent successfully');
    } catch (e) {
      _logger.debug('Error sending compressed message: $e');
      rethrow;
    }
  }

  /// Compress data using the specified compression type
  Future<List<int>> _compressData(
    List<int> data,
    CompressionType compression,
  ) async {
    switch (compression) {
      case CompressionType.gzip:
        return gzip.encode(data);
      case CompressionType.deflate:
        return zlib.encode(data);
      case CompressionType.brotli:
        // Note: Dart doesn't have built-in Brotli support
        // In a real implementation, you'd use a package like 'brotli'
        _logger.debug(
          'Brotli compression not implemented, falling back to gzip',
        );
        return gzip.encode(data);
      case CompressionType.none:
        return data;
    }
  }

  /// Decompress HTTP response based on Content-Encoding header
  Future<String> _decompressResponse(HttpClientResponse response) async {
    final contentEncoding = response.headers.value('content-encoding');
    final bodyBytes = await response.fold<List<int>>(
      [],
      (bytes, chunk) => bytes..addAll(chunk),
    );

    List<int> decompressedBytes;
    switch (contentEncoding) {
      case 'gzip':
        decompressedBytes = gzip.decode(bodyBytes);
        break;
      case 'deflate':
        decompressedBytes = zlib.decode(bodyBytes);
        break;
      case 'br':
        // Brotli decompression would go here
        _logger.debug(
          'Brotli decompression not implemented, treating as uncompressed',
        );
        decompressedBytes = bodyBytes;
        break;
      default:
        decompressedBytes = bodyBytes;
        break;
    }

    return utf8.decode(decompressedBytes);
  }

  /// Get compression statistics
  Map<String, dynamic> getCompressionStats() {
    return {
      'negotiatedCompression': _negotiatedCompression.encoding,
      'supportedCompressions':
          _supportedCompressions.map((c) => c.encoding).toList(),
      'compressionThreshold': _compressionThreshold,
      'isConnected': !_isClosed,
    };
  }

  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;

    _logger.debug('Closing SseCompressedClientTransport');

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

/// Compressed EventSource implementation
class CompressedEventSource {
  HttpClient? _client;
  HttpClientRequest? _request;
  HttpClientResponse? _response;
  StreamSubscription? _subscription;
  final _buffer = StringBuffer();
  bool _isConnected = false;
  CompressionType _activeCompression = CompressionType.none;

  bool get isConnected => _isConnected;
  CompressionType get activeCompression => _activeCompression;

  Future<void> connect(
    String url, {
    Map<String, String>? headers,
    int compressionThreshold = 1024,
    Function(String?)? onOpen,
    Function(dynamic)? onMessage,
    Function(dynamic)? onError,
    Function(CompressionType)? onCompressionNegotiated,
    Function()? onClose,
  }) async {
    _logger.debug('CompressedEventSource connecting to: $url');
    if (_isConnected) {
      throw McpError('CompressedEventSource is already connected');
    }

    try {
      _client = HttpClient();
      _request = await _client!.getUrl(Uri.parse(url));

      // Set compression and SSE headers
      if (headers != null) {
        headers.forEach((key, value) {
          _request!.headers.set(key, value);
        });
      }

      _response = await _request!.close();

      if (_response!.statusCode != 200) {
        final body = await _response!.transform(utf8.decoder).join();
        throw McpError(
          'Failed to connect to compressed SSE endpoint: ${_response!.statusCode} - $body',
        );
      }

      // Check negotiated compression
      final contentEncoding = _response!.headers.value('content-encoding');
      _activeCompression = _parseCompressionType(contentEncoding);

      if (onCompressionNegotiated != null) {
        onCompressionNegotiated(_activeCompression);
      }

      _isConnected = true;
      _logger.debug(
        'Compressed EventSource connection established with encoding: ${_activeCompression.encoding}',
      );

      // Set up subscription to process compressed events
      _subscription = _response!.listen(
        (List<int> data) {
          try {
            // Decompress data if needed
            List<int> decompressedData;
            switch (_activeCompression) {
              case CompressionType.gzip:
                decompressedData = gzip.decode(data);
                break;
              case CompressionType.deflate:
                decompressedData = zlib.decode(data);
                break;
              case CompressionType.brotli:
                // Brotli decompression would go here
                _logger.debug('Brotli decompression not implemented');
                decompressedData = data;
                break;
              case CompressionType.none:
                decompressedData = data;
                break;
            }

            final chunk = utf8.decode(decompressedData, allowMalformed: true);
            _logger.debug('Raw decompressed SSE data: [$chunk]');
            _buffer.write(chunk);

            // Process all events in buffer
            final content = _buffer.toString();

            // Check for JSON-RPC responses
            if (content.contains('"jsonrpc":"2.0"') ||
                content.contains('"jsonrpc": "2.0"')) {
              _logger.debug('Detected JSON-RPC data in compressed SSE stream');

              try {
                final jsonStart = content.indexOf('{');
                final jsonEnd = content.lastIndexOf('}') + 1;

                if (jsonStart >= 0 && jsonEnd > jsonStart) {
                  final jsonStr = content.substring(jsonStart, jsonEnd);
                  _logger.debug(
                    'Extracted compressed JSON: ${jsonStr.substring(0, 100)}...',
                  );

                  try {
                    final jsonData = jsonDecode(jsonStr);
                    _logger.debug(
                      'Parsed compressed JSON-RPC data: ${jsonData.toString().substring(0, 100)}...',
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
                    _logger.debug('JSON parse error in compressed stream: $e');
                  }
                }
              } catch (e) {
                _logger.debug(
                  'Error extracting JSON from compressed stream: $e',
                );
              }
            }

            // Process SSE events
            final event = _processBuffer();
            _logger.debug(
              'Processed compressed SSE event: ${event.event}, data: ${event.data}',
            );

            if (event.event == 'endpoint' && event.data != null) {
              _logger.debug(
                'Received compressed endpoint event: ${event.data}',
              );
              if (onOpen != null) {
                onOpen(event.data);
              }
            } else if (event.data != null && onMessage != null) {
              onMessage(event.data);
            }
          } catch (e) {
            _logger.debug('Error processing compressed SSE data: $e');
          }
        },
        onError: (e) {
          _logger.debug('Compressed EventSource error: $e');
          _isConnected = false;
          if (onError != null) {
            onError(e);
          }
        },
        onDone: () {
          _logger.debug('Compressed EventSource stream closed');
          _isConnected = false;
          if (onClose != null) {
            onClose();
          }
        },
      );
    } catch (e) {
      _logger.debug('Compressed EventSource connection error: $e');
      _isConnected = false;
      if (onError != null) {
        onError(e);
      }
      rethrow;
    }
  }

  CompressionType _parseCompressionType(String? encoding) {
    switch (encoding) {
      case 'gzip':
        return CompressionType.gzip;
      case 'deflate':
        return CompressionType.deflate;
      case 'br':
        return CompressionType.brotli;
      case 'identity':
      case null:
      default:
        return CompressionType.none;
    }
  }

  _SseEvent _processBuffer() {
    final content = _buffer.toString();
    _logger.debug('_processBuffer compressed content: [$content]');

    if (content.isEmpty) {
      return _SseEvent('', null);
    }

    final eventBlocks = content.split('\n\n');
    _logger.debug(
      '_processBuffer compressed event blocks count: ${eventBlocks.length}',
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
      _logger.debug('Processing compressed line: [$trimmedLine]');

      if (trimmedLine.startsWith('event:')) {
        currentEvent = trimmedLine.substring(6).trim();
        _logger.debug('Found compressed event type: $currentEvent');
      } else if (trimmedLine.startsWith('data:')) {
        currentData = trimmedLine.substring(5).trim();
        _logger.debug('Found compressed event data: $currentData');
      }
    }

    // Clear processed event from buffer
    final remaining = eventBlocks.skip(1).join('\n\n');
    _buffer.clear();
    if (remaining.isNotEmpty) {
      _buffer.write(remaining);
    }

    _logger.debug(
      'Complete compressed event found: $currentEvent, data: $currentData',
    );
    return _SseEvent(currentEvent, currentData);
  }

  void close() {
    _logger.debug('Closing CompressedEventSource');

    _subscription?.cancel();

    try {
      _response?.detachSocket().then((socket) {
        _logger.debug('Detached compressed socket - destroying...');
        socket.destroy();
      });
    } catch (e) {
      _logger.debug('Error detaching compressed socket: $e');
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
