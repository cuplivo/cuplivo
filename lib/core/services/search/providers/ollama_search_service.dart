import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class OllamaSearchService extends SearchService<OllamaOptions> {
  OllamaSearchService({super.client});

  @override
  String get name => 'Ollama';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderOllamaDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  bool get supportsNativeFetch => true;

  @override
  Future<WebFetchResult> fetch({
    required Uri url,
    required SearchCommonOptions commonOptions,
    required OllamaOptions serviceOptions,
    required http.Client fetchClient,
    String? apiKeyOverride,
  }) async {
    try {
      final response = await fetchClient
          .post(
            Uri.parse('https://ollama.com/api/web_fetch'),
            headers: {
              'Authorization':
                  'Bearer ${apiKeyOverride ?? serviceOptions.apiKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'url': url.toString()}),
          )
          .timeout(Duration(milliseconds: commonOptions.timeout));
      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final content = (data['content'] ?? '').toString();
      if (content.trim().isEmpty) {
        throw Exception('Web fetch response contained empty page content');
      }
      return WebFetchResult(
        url: url.toString(),
        title: data['title']?.toString(),
        content: content,
      );
    } catch (e) {
      throw Exception('Ollama fetch failed: $e');
    }
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required OllamaOptions serviceOptions,
    String? apiKeyOverride,
  }) async {
    try {
      final body = jsonEncode({
        'query': query,
        'max_results': commonOptions.resultSize.clamp(1, 10),
      });

      final response = await client
          .post(
            Uri.parse('https://ollama.com/api/web_search'),
            headers: {
              'Authorization':
                  'Bearer ${apiKeyOverride ?? serviceOptions.apiKey}',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final list = (data['results'] as List? ?? const []);
      final results = list.map((item) {
        final map = item as Map<String, dynamic>;
        return SearchResultItem(
          title: (map['title'] ?? '').toString(),
          url: (map['url'] ?? '').toString(),
          text: (map['content'] ?? '').toString(),
        );
      }).toList();

      return SearchResult(items: results);
    } catch (e) {
      throw Exception('Ollama search failed: $e');
    }
  }
}
