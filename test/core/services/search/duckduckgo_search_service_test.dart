import 'package:Cuplivo/core/services/search/providers/duckduckgo_search_service.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('queries DuckDuckGo through the injected common HTTP path', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.host, 'duckduckgo.com');
      expect(request.url.path, '/html/');
      expect(request.url.queryParameters['q'], 'flutter search');
      expect(request.url.queryParameters['kl'], 'zh-cn');
      return http.Response('''
        <html><body>
          <div class="result">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fflutter.dev%2Fdocs">Flutter</a>
            <a class="result__url">flutter.dev/docs</a>
            <div class="result__snippet">Build apps with Flutter.</div>
          </div>
        </body></html>
      ''', 200);
    });

    final result = await DuckDuckGoSearchService(client: client).search(
      query: 'flutter search',
      commonOptions: const SearchCommonOptions(resultSize: 5),
      serviceOptions: DuckDuckGoOptions(id: 'ddg', region: 'zh-cn'),
    );

    expect(result.items, hasLength(1));
    expect(result.items.single.title, 'Flutter');
    expect(result.items.single.url, 'https://flutter.dev/docs');
    expect(result.items.single.text, 'Build apps with Flutter.');
  });
}
