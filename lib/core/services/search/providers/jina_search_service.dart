import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class JinaSearchService extends SearchService<JinaOptions> {
  @override
  String get name => 'Jina';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderJinaDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required JinaOptions serviceOptions,
    String? apiKeyOverride,
  }) async {
    try {
      final body = jsonEncode({'q': query});

      final response = await client
          .post(
            Uri.parse('https://s.jina.ai/'),
            headers: {
              'Authorization':
                  'Bearer ${apiKeyOverride ?? serviceOptions.apiKey}',
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              // Speed up and reduce payload: omit page content in response
              // 'X-Respond-With': 'no-content',
              // Some gateways behave better with a standard UA
              // 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            },
            body: body,
          )
          .timeout(
            Duration(
              milliseconds: commonOptions.timeout < 15000
                  ? 15000
                  : commonOptions.timeout,
            ),
          );

      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      // Jina typically returns { data: [...] }. Be permissive in case of variant shapes.
      final listRaw =
          (data['data'] ?? data['results'] ?? const <dynamic>[]) as List;
      final list = listRaw;
      final results = list.take(commonOptions.resultSize).map((item) {
        final m = (item as Map).cast<String, dynamic>();
        return SearchResultItem(
          title: (m['title'] ?? '').toString(),
          url: (m['url'] ?? '').toString(),
          text: (m['description'] ?? '').toString(),
        );
      }).toList();

      return SearchResult(items: results);
    } catch (e) {
      throw Exception('Jina search failed: $e');
    }
  }
}
