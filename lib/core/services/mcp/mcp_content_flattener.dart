import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' as mcp;

import '../../../utils/app_directories.dart';

/// Converts [mcp.CallToolResult] to a plain text string for LLM consumption.
class McpContentFlattener {
  static Future<String> flatten(mcp.CallToolResult result) async {
    final buf = StringBuffer();
    for (final c in result.content) {
      try {
        if (c is mcp.TextContent) {
          if (c.text.trim().isNotEmpty) buf.writeln(c.text);
          continue;
        }
        if (c is mcp.ResourceContent) {
          final t = (c.text ?? '').toString();
          if (t.trim().isNotEmpty) {
            buf.writeln(t);
          } else {
            final uri = c.uri.toString();
            if (uri.isNotEmpty) buf.writeln('resource: $uri');
          }
          continue;
        }
        if (c is mcp.ImageContent) {
          final data = c.data.toString();
          final mime = c.mimeType.toString();
          if (data.isNotEmpty) {
            final savedPath = await AppDirectories.saveBase64Image(
              mime,
              data,
              prefix: 'mcp_img',
            );
            if (savedPath != null) buf.writeln('[image:$savedPath]');
          } else {
            final url = (c.url ?? '').toString();
            if (url.isNotEmpty) buf.writeln('[image:$url]');
          }
          continue;
        }
        // Dynamic fallback for unknown content types
        final dyn = c as dynamic;
        try {
          final txt = dyn.text as String?;
          if (txt != null && txt.trim().isNotEmpty) {
            buf.writeln(txt);
            continue;
          }
        } catch (_) {}
        try {
          final uri = dyn.uri as String?;
          if (uri != null && uri.isNotEmpty) {
            buf.writeln('resource: $uri');
            continue;
          }
        } catch (_) {}
        try {
          final json = (dyn.toJson as dynamic).call();
          buf.writeln(const JsonEncoder.withIndent('  ').convert(json));
          continue;
        } catch (_) {}
        final s = c.toString();
        if (!s.startsWith('Instance of')) buf.writeln(s);
      } catch (_) {
        // ignore single content parse errors and continue
      }
    }
    return buf.toString().trim();
  }
}
