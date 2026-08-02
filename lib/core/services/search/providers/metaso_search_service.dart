import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class MetasoSearchService extends SearchService<MetasoOptions> {
  @override
  String get name => 'Metaso (秘塔)';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderMetasoDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required MetasoOptions serviceOptions,
    String? apiKeyOverride,
  }) async {
    try {
      final body = jsonEncode({
        'q': query,
        'scope': 'webpage',
        'size': commonOptions.resultSize,
        'includeSummary': false,
      });

      final response = await client
          .post(
            Uri.parse('https://metaso.cn/api/v1/search'),
            headers: {
              'Authorization':
                  'Bearer ${apiKeyOverride ?? serviceOptions.apiKey}',
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      final webpages = data['webpages'] as List? ?? [];
      final results = webpages.map((item) {
        return SearchResultItem(
          title: item['title'] ?? '',
          url: item['link'] ?? '',
          text: item['snippet'] ?? '',
        );
      }).toList();

      return SearchResult(items: results);
    } catch (e) {
      throw Exception('Metaso search failed: $e');
    }
  }
}
