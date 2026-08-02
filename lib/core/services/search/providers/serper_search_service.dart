import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../../l10n/app_localizations.dart';
import '../../../../core/services/network/logging_http_client.dart';
import '../search_service.dart';

class SerperSearchService extends SearchService<SerperOptions> {
  SerperSearchService({http.Client? client})
    : _client = client ?? LoggingHttpClient.of(LoggingCategory.search);

  static const String endpoint = 'https://google.serper.dev/search';

  final http.Client _client;

  @override
  String get name => 'Serper';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderSerperDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required SerperOptions serviceOptions,
    String? apiKeyOverride,
  }) async {
    try {
      final body = <String, dynamic>{
        'q': query,
        if (serviceOptions.gl.trim().isNotEmpty) 'gl': serviceOptions.gl.trim(),
        if (serviceOptions.hl.trim().isNotEmpty) 'hl': serviceOptions.hl.trim(),
        if (serviceOptions.tbs.trim().isNotEmpty)
          'tbs': serviceOptions.tbs.trim(),
        if (serviceOptions.page > 1) 'page': serviceOptions.page,
      };

      final response = await _client
          .post(
            Uri.parse(endpoint),
            headers: {
              'X-API-KEY': apiKeyOverride ?? serviceOptions.apiKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final organic = (data['organic'] as List?) ?? const <dynamic>[];
      final items = organic.take(commonOptions.resultSize).map((item) {
        final m = (item as Map).cast<String, dynamic>();
        return SearchResultItem(
          title: (m['title'] ?? '').toString(),
          url: (m['link'] ?? '').toString(),
          text: (m['snippet'] ?? '').toString(),
        );
      }).toList();

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('Serper search failed: $e');
    }
  }
}
