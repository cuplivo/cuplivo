import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class ExaSearchService extends SearchService<ExaOptions> {
  ExaSearchService({super.client});

  @override
  String get name => 'Exa';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderExaDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  bool get supportsNativeFetch => true;

  @override
  Future<WebFetchResult> fetch({
    required Uri url,
    required SearchCommonOptions commonOptions,
    required ExaOptions serviceOptions,
    required http.Client fetchClient,
    String? apiKeyOverride,
  }) async {
    try {
      final endpoint = _contentsEndpoint(serviceOptions.resolvedUrl);
      final response = await fetchClient
          .post(
            endpoint,
            headers: {
              'x-api-key': apiKeyOverride ?? serviceOptions.apiKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'urls': [url.toString()],
              'text': true,
            }),
          )
          .timeout(Duration(milliseconds: commonOptions.timeout));
      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List? ?? const <dynamic>[];
      if (results.isEmpty || results.first is! Map) {
        throw Exception('Contents response did not contain page content');
      }
      final item = (results.first as Map).cast<String, dynamic>();
      final content = (item['text'] ?? '').toString();
      if (content.trim().isEmpty) {
        throw Exception('Contents response contained empty page content');
      }
      return WebFetchResult(
        url: (item['url'] ?? url).toString(),
        title: item['title']?.toString(),
        content: content,
      );
    } catch (e) {
      throw Exception('Exa fetch failed: $e');
    }
  }

  static Uri _contentsEndpoint(String searchUrl) {
    final uri = Uri.parse(searchUrl);
    if (!uri.hasAuthority || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw Exception('Exa URL must be an absolute HTTP(S) URL');
    }
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.isEmpty || segments.last != 'search') {
      throw Exception('Exa URL must end with /search');
    }
    segments[segments.length - 1] = 'contents';
    final trailingSlash = uri.path.endsWith('/');
    return uri.replace(
      path: '/${segments.join('/')}${trailingSlash ? '/' : ''}',
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required ExaOptions serviceOptions,
    String? apiKeyOverride,
  }) async {
    try {
      final body = jsonEncode({
        'query': query,
        'numResults': commonOptions.resultSize,
        'contents': {'text': true},
      });

      final response = await client
          .post(
            Uri.parse(serviceOptions.resolvedUrl),
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
      final results = (data['results'] as List? ?? const <dynamic>[]).map((
        item,
      ) {
        return SearchResultItem(
          title: item['title'] ?? '',
          url: item['url'] ?? '',
          text: item['text'] ?? '',
        );
      }).toList();

      return SearchResult(items: results);
    } catch (e) {
      throw Exception('Exa search failed: $e');
    }
  }
}
