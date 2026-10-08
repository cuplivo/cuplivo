import 'dart:convert';

import 'package:Cuplivo/core/services/search/providers/doubao_search_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Doubao search provider', () {
    test('posts a Custom web search and parses URL results', () async {
      http.Request? captured;
      final service = DoubaoSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'ResponseMetadata': <String, dynamic>{},
              'Result': {
                'WebResults': [
                  {
                    'Title': 'Kelivo',
                    'Url': 'https://example.com/kelivo',
                    'Summary': 'summary',
                    'Snippet': 'snippet',
                  },
                  {
                    'Title': 'Fallback',
                    'Url': 'https://example.com/fallback',
                    'Summary': '',
                    'Content': 'content',
                  },
                  {'Title': 'No URL', 'Summary': 'ignored'},
                ],
              },
            }),
            200,
          );
        }),
      );

      final options = DoubaoOptions(id: 'doubao-1', apiKey: 'db-key');
      final restored = SearchServiceOptions.fromJson(options.toJson());
      expect(restored, isA<DoubaoOptions>());
      expect(SearchService.getService(restored), isA<DoubaoSearchService>());

      final result = await service.search(
        query: 'kelivo',
        commonOptions: const SearchCommonOptions(resultSize: 80, timeout: 1000),
        serviceOptions: options,
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(captured?.url.toString(), DoubaoSearchService.endpoint);
      expect(captured?.headers['Authorization'], 'Bearer db-key');
      expect(body['Query'], 'kelivo');
      expect(body['SearchType'], 'web');
      expect(body['Count'], 50);
      expect((body['Filter'] as Map)['NeedUrl'], isTrue);
      expect(result.items, hasLength(2));
      expect(result.items.map((item) => item.text), ['summary', 'content']);
    });

    test('reports API errors returned with HTTP 200', () async {
      final service = DoubaoSearchService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'ResponseMetadata': {
                'Error': {'Code': '10403', 'Message': 'denied'},
              },
              'Result': null,
            }),
            200,
          ),
        ),
      );

      expect(
        () => service.search(
          query: 'kelivo',
          commonOptions: const SearchCommonOptions(timeout: 1000),
          serviceOptions: DoubaoOptions(id: 'doubao-1', apiKey: 'db-key'),
        ),
        throwsA(predicate((error) => '$error'.contains('denied'))),
      );
    });
  });
}
