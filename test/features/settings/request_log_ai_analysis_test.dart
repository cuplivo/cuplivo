import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/settings/logs/request_log_ai_analysis.dart';
import 'package:Cuplivo/features/settings/logs/request_log_parser.dart';

RequestLogEntry _entry({
  int id = 1,
  DateTime? started,
  DateTime? ended,
  String? url,
  int? status,
  String? requestBody,
}) {
  return RequestLogEntry(
    id: id,
    sequence: id,
    startedAt: started ?? DateTime(2026, 1, 3, 10),
    lastEventAt: ended ?? DateTime(2026, 1, 3, 10, 0, 2),
    method: 'POST',
    rawUrl: url ?? 'https://api.example.com/v1/chat/completions?apikey=SECRET',
    requestHeaders: const {'authorization': 'Bearer sk-secret'},
    requestBody: requestBody ?? '{"model": "gpt"}',
    statusCode: status,
  );
}

void main() {
  group('RequestLogAiAnalysisExporter.buildPayload', () {
    test('carries request identity with redacted url and headers', () {
      final payload = RequestLogAiAnalysisExporter.buildPayload([
        _entry(),
      ], generatedAt: DateTime(2026, 1, 3, 12));
      final first = (payload['requests'] as List).single as Map;
      expect(first['method'], 'POST');
      expect(first['url'], isNot(contains('SECRET')));
      expect(
        first['request_headers'].toString().toLowerCase(),
        isNot(contains('sk-secret')),
      );
    });

    test('computes duration from started/last-event timestamps', () {
      final payload = RequestLogAiAnalysisExporter.buildPayload([
        _entry(ended: DateTime(2026, 1, 3, 10, 0, 5)),
      ], generatedAt: DateTime(2026, 1, 3, 12));
      final first = (payload['requests'] as List).single as Map;
      expect(first['duration_ms'], 5000);
    });

    test('error statuses surface for the model to prioritize', () {
      final payload = RequestLogAiAnalysisExporter.buildPayload([
        _entry(status: 429),
        _entry(id: 2, status: 500),
      ], generatedAt: DateTime(2026, 1, 3, 12));
      final requests = (payload['requests'] as List).cast<Map>();
      expect(requests[0]['status_code'], 429);
      expect(requests[1]['status_code'], 500);
    });
  });
}
