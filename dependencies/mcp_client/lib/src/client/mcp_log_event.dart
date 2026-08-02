/// Structured log event emitted by [Client] through its log listener.
///
/// The listener is a sink only: the library never formats, filters, or
/// persists anything. Consumers (e.g. an app-side request-log bridge)
/// decide what to write.
library;

/// Listener signature for MCP protocol traffic.
typedef McpLogListener = void Function(McpLogEvent event);

/// One protocol-level message exchange (or lifecycle event).
class McpLogEvent {
  /// Client name — the app sets this to a server-identifying label.
  final String server;

  /// `send` (outgoing) or `receive` (incoming).
  final String direction;

  /// `request` | `notification` | `response` | `error-response` | `lifecycle`.
  final String kind;

  /// JSON-RPC request id (requests/responses only; null for
  /// notifications and lifecycle events).
  final dynamic id;

  /// JSON-RPC method (requests/notifications only).
  final String? method;

  /// Method params, result, or error map `{code, message, data?}` —
  /// never the JSON-RPC envelope itself.
  final Object? payload;

  /// Optional caller-supplied tags (e.g. `{'reason': 'heartbeat'}`).
  final Map<String, String>? tags;

  const McpLogEvent({
    required this.server,
    required this.direction,
    required this.kind,
    this.id,
    this.method,
    this.payload,
    this.tags,
  });
}
