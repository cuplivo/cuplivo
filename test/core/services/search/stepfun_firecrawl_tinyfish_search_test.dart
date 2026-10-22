import 'dart:convert';

import 'package:Cuplivo/core/services/search/providers/firecrawl_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/stepfun_search_service.dart';
import 'package:Cuplivo/core/services/search/providers/tinyfish_search_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('StepFun / Firecrawl / TinyFish search providers', () {
    test('StepFun posts /v1/search and parses results', () async {
      http.Request? captured;
      final service = StepFunSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'title': 'Step',
                  'url': 'https://example.com',
                  'snippet': 'hello',
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'kelivo',
        commonOptions: const SearchCommonOptions(resultSize: 5, timeout: 1000),
        serviceOptions: StepFunOptions(id: 's1', apiKey: 'k'),
      );

      expect(captured?.url.toString(), StepFunOptions.defaultUrl);
      expect(captured?.headers['Authorization'], 'Bearer k');
      expect(jsonDecode(captured!.body)['query'], 'kelivo');
      expect(result.items.single.title, 'Step');
      expect(
        SearchService.getService(StepFunOptions(id: 'x', apiKey: '')),
        isA<StepFunSearchService>(),
      );
    });

    test(
      'Firecrawl sends bearer key when present and parses v2 web results',
      () async {
        http.Request? captured;
        final service = FirecrawlSearchService(
          client: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({
                'data': {
                  'web': [
                    {
                      'title': 'Fire',
                      'url': 'https://example.com/a',
                      'description': 'desc',
                    },
                  ],
                },
              }),
              200,
            );
          }),
        );

        final result = await service.search(
          query: 'docs',
          commonOptions: const SearchCommonOptions(
            resultSize: 3,
            timeout: 1000,
          ),
          serviceOptions: FirecrawlOptions(id: 'f1', apiKey: 'fc-key'),
        );

        expect(captured?.url.toString(), FirecrawlOptions.defaultUrl);
        expect(captured?.headers['Authorization'], 'Bearer fc-key');
        expect(result.items.single.url, 'https://example.com/a');
      },
    );

    test(
      'Firecrawl omits Authorization when no API key is configured',
      () async {
        http.Request? captured;
        final service = FirecrawlSearchService(
          client: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({
                'data': {
                  'web': [
                    {
                      'title': 'Fire',
                      'url': 'https://example.com/a',
                      'description': 'desc',
                    },
                  ],
                },
              }),
              200,
            );
          }),
        );

        final result = await service.search(
          query: 'docs',
          commonOptions: const SearchCommonOptions(
            resultSize: 3,
            timeout: 1000,
          ),
          serviceOptions: FirecrawlOptions(id: 'f1', apiKey: ''),
        );

        expect(captured?.url.toString(), FirecrawlOptions.defaultUrl);
        expect(captured?.headers.containsKey('Authorization'), isFalse);
        expect(result.items.single.url, 'https://example.com/a');
      },
    );

    test('Firecrawl serializes sources/categories and posts them', () async {
      http.Request? captured;
      final options = FirecrawlOptions(
        id: 'f2',
        apiKey: 'fc-key',
        sources: const ['web', 'news'],
        categories: const ['github', 'research'],
        country: 'US',
        location: 'San Francisco',
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());
      expect(restored, isA<FirecrawlOptions>());
      final firecrawl = restored as FirecrawlOptions;
      expect(firecrawl.sources, ['web', 'news']);
      expect(firecrawl.categories, ['github', 'research']);
      expect(firecrawl.country, 'US');
      expect(firecrawl.location, 'San Francisco');

      // Rebuild the way editors do when UI has no sources/categories fields:
      // keep the non-default lists from the existing options object.
      final rebuilt = FirecrawlOptions(
        id: firecrawl.id,
        apiKey: 'fc-key-2',
        url: firecrawl.url,
        sources: firecrawl.sources,
        categories: firecrawl.categories,
        country: 'CA',
        location: firecrawl.location,
      );
      expect(rebuilt.sources, ['web', 'news']);
      expect(rebuilt.categories, ['github', 'research']);
      expect(rebuilt.apiKey, 'fc-key-2');
      expect(rebuilt.country, 'CA');

      final service = FirecrawlSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'data': {
                'web': [
                  {
                    'title': 'Fire',
                    'url': 'https://example.com/a',
                    'description': 'desc',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      await service.search(
        query: 'docs',
        commonOptions: const SearchCommonOptions(resultSize: 3, timeout: 1000),
        serviceOptions: rebuilt,
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['sources'], [
        {'type': 'web'},
        {'type': 'news'},
      ]);
      expect(body['categories'], [
        {'type': 'github'},
        {'type': 'research'},
      ]);
      expect(body['country'], 'CA');
    });

    test(
      'TinyFish uses X-API-Key and location/language query params',
      () async {
        http.Request? captured;
        final service = TinyFishSearchService(
          client: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({
                'results': [
                  {
                    'title': 'Tiny',
                    'url': 'https://example.com/t',
                    'snippet': 'fish',
                  },
                ],
              }),
              200,
            );
          }),
        );

        final result = await service.search(
          query: 'automation',
          commonOptions: const SearchCommonOptions(
            resultSize: 2,
            timeout: 1000,
          ),
          serviceOptions: TinyFishOptions(
            id: 't1',
            apiKey: 'tf-key',
            location: 'US',
            language: 'en',
          ),
        );

        expect(captured?.headers['X-API-Key'], 'tf-key');
        expect(captured?.url.queryParameters['query'], 'automation');
        expect(captured?.url.queryParameters['location'], 'US');
        expect(captured?.url.queryParameters['language'], 'en');
        expect(result.items.single.title, 'Tiny');
      },
    );
  });
}
