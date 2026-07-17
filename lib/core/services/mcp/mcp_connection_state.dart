import 'package:flutter/foundation.dart';

@immutable
sealed class McpConnectionState {
  const McpConnectionState();
}

final class McpConnectionIdle extends McpConnectionState {
  const McpConnectionIdle();
}

final class McpConnectionConnecting extends McpConnectionState {
  const McpConnectionConnecting();
}

final class McpConnectionConnected extends McpConnectionState {
  const McpConnectionConnected();
}

final class McpConnectionError extends McpConnectionState {
  final String message;
  const McpConnectionError(this.message);
}
