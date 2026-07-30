import '../../models/assistant.dart';

Map<String, String>? buildAssistantCustomHeaders(Assistant? assistant) {
  final entries = assistant?.customHeaders ?? const <Map<String, String>>[];
  final headers = <String, String>{
    for (final entry in entries)
      if ((entry['name'] ?? '').trim().isNotEmpty)
        entry['name']!.trim(): entry['value'] ?? '',
  };
  return headers.isEmpty ? null : headers;
}

Map<String, dynamic>? buildAssistantCustomBody(Assistant? assistant) {
  final entries = assistant?.customBody ?? const <Map<String, String>>[];
  final body = <String, dynamic>{
    for (final entry in entries)
      if ((entry['key'] ?? '').trim().isNotEmpty)
        entry['key']!.trim(): entry['value'] ?? '',
  };
  return body.isEmpty ? null : body;
}
