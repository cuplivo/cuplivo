import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/settings/logs/request_log_ai_analysis.dart';
import 'package:Cuplivo/features/settings/logs/request_log_parser.dart';

void main() {
  group('RequestLogAiAnalysisExporter', () {
    test('redacts sensitive values while preserving useful diagnostics', () {
      final entry = RequestLogEntry(
        id: 7,
        sequence: 1,
        method: 'POST',
        rawUrl:
            'https://api.example.com/v1/chat?model=test&api_key=secret-value&key=also-secret',
        requestHeaders: <String, dynamic>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer secret-value',
        },
        requestBody: jsonEncode(<String, dynamic>{
          'model': 'test',
          'api_key': 'secret-value',
          'nested': <String, dynamic>{'access_token': 'another-secret'},
        }),
        responseBody: jsonEncode(<String, dynamic>{
          'request_id': 'req_123',
          'session_id': 'private-session',
        }),
      );

      final payload = RequestLogAiAnalysisExporter.buildPayload(<RequestLogEntry>[
        entry,
      ]);
      final request = (payload['requests'] as List<dynamic>).single
          as Map<String, dynamic>;
      final headers = request['request_headers'] as Map<String, dynamic>;
      final body = request['request_body'] as Map<String, dynamic>;
      final nested = body['nested'] as Map<String, dynamic>;
      final response = request['response_body'] as Map<String, dynamic>;

      expect(
        request['url'],
        'https://api.example.com/v1/chat?model=test&api_key='
        '<REDACTED: api_key>&key=<REDACTED: key>',
      );
      expect(headers['Content-Type'], 'application/json');
      expect(headers['Authorization'], '<REDACTED: Authorization>');
      expect(body['model'], 'test');
      expect(body['api_key'], '<REDACTED: api_key>');
      expect(nested['access_token'], '<REDACTED: access_token>');
      expect(response['request_id'], 'req_123');
      expect(response['session_id'], '<REDACTED: session_id>');
    });

    test('truncates only an oversized JSON string value', () {
      final longValue = List<String>.filled(8193, 'a').join();
      final entry = RequestLogEntry(
        id: 8,
        sequence: 1,
        requestBody: jsonEncode(<String, dynamic>{
          'image_data': longValue,
          'model': 'test',
        }),
      );

      final payload = RequestLogAiAnalysisExporter.buildPayload(<RequestLogEntry>[
        entry,
      ]);
      final request = (payload['requests'] as List<dynamic>).single
          as Map<String, dynamic>;
      final body = request['request_body'] as Map<String, dynamic>;
      final transformed = body['image_data'] as String;

      expect(transformed, startsWith(List<String>.filled(2048, 'a').join()));
      expect(transformed, contains('<TRUNCATED: 4097 characters omitted>'));
      expect(transformed, endsWith(List<String>.filled(2048, 'a').join()));
      expect(body['model'], 'test');
    });

    test('preserves malformed JSON as raw text without throwing', () {
      final entry = RequestLogEntry(
        id: 9,
        sequence: 1,
        requestBody: '{not valid json',
      );

      final payload = RequestLogAiAnalysisExporter.buildPayload(<RequestLogEntry>[
        entry,
      ]);
      final request = (payload['requests'] as List<dynamic>).single
          as Map<String, dynamic>;

      expect(request['request_body'], '{not valid json');
    });
  });
}
