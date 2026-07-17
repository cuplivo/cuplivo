/// Abstract EventSource interface for cross-platform SSE support
abstract class EventSource {
  /// Whether the connection is active
  bool get isConnected;

  /// Get the HTTP response (if available)
  dynamic get response;

  /// Connect to an SSE endpoint
  Future<void> connect(
    String url, {
    Map<String, String>? headers,
    Function(String?)? onOpen,
    Function(dynamic)? onMessage,
    Function(dynamic)? onError,
    Function(String?)? onEndpoint,
    Function()? onClose,
  });

  /// Close the connection
  void close();

  /// Factory constructor that throws an error
  factory EventSource() =>
      throw UnsupportedError('EventSource is not supported on this platform');
}
