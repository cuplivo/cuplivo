import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class LinkUpSearchService extends SearchService<LinkUpOptions> {
  @override
  String get name => 'LinkUp';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderLinkUpDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required LinkUpOptions serviceOptions,
    String? apiKeyOverride,
  }) async {
    try {
      final body = jsonEncode({
        'q': query,
        'depth': 'standard',
        'outputType': 'sourcedAnswer',
        'includeImages': 'false',
      });

      final response = await client
          .post(
            Uri.parse('https://api.linkup.so/v1/search'),
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

      final data = jsonDecode(response.body);
      final sources = data['sources'] as List? ?? [];
      final results = sources.take(commonOptions.resultSize).map((item) {
        return SearchResultItem(
          title: item['name'] ?? '',
          url: item['url'] ?? '',
          text: item['snippet'] ?? '',
        );
      }).toList();

      return SearchResult(answer: data['answer'], items: results);
    } catch (e) {
      throw Exception('LinkUp search failed: $e');
    }
  }
}
