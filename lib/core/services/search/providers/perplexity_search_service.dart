import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class PerplexitySearchService extends SearchService<PerplexityOptions> {
  PerplexitySearchService({super.client});

  @override
  String get name => 'Perplexity';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderPerplexityDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  bool get supportsNativeFetch => true;

  @override
  Future<WebFetchResult> fetch({
    required Uri url,
    required SearchCommonOptions commonOptions,
    required PerplexityOptions serviceOptions,
    required http.Client fetchClient,
    String? apiKeyOverride,
  }) async {
    try {
      final response = await fetchClient
          .post(
            Uri.parse('https://api.perplexity.ai/v1/agent'),
            headers: {
              'Authorization':
                  'Bearer ${apiKeyOverride ?? serviceOptions.apiKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': 'perplexity/sonar',
              'input': 'Fetch the full contents of this exact URL: $url',
              'instructions':
                  'Call fetch_url exactly once for the URL in the input. '
                  'Do not search for alternatives.',
              'tools': [
                {'type': 'fetch_url'},
              ],
              'max_steps': 1,
              'max_output_tokens': 64,
              'store': false,
              'stream': false,
            }),
          )
          .timeout(Duration(milliseconds: commonOptions.timeout));
      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final output = data['output'] as List? ?? const <dynamic>[];
      final contents = <Map<String, dynamic>>[];
      for (final item in output.whereType<Map>()) {
        if (item['type'] != 'fetch_url_results') continue;
        for (final content
            in (item['contents'] as List? ?? const <dynamic>[])
                .whereType<Map>()) {
          contents.add(Map<String, dynamic>.from(content));
        }
      }
      if (contents.isEmpty) {
        throw Exception('Agent did not return fetch_url results');
      }
      final requested = _normalizeUrl(url);
      final requestedOriginPath = _normalizeOriginPath(url);
      final result = contents.firstWhere(
        (item) =>
            _normalizeUrl(Uri.tryParse((item['url'] ?? '').toString())) ==
            requested,
        // The agent may echo the fetched URL re-encoded or with reordered
        // query parameters; fall back to a scheme/host/path match so a
        // semantically identical page is not rejected as a false negative.
        orElse: () => contents.firstWhere(
          (item) =>
              _normalizeOriginPath(
                Uri.tryParse((item['url'] ?? '').toString()),
              ) ==
              requestedOriginPath,
          orElse: () => throw Exception(
            'Agent returned content for a different URL than requested '
            '(requested $requested, got '
            '${contents.map((item) => item['url']).join(', ')})',
          ),
        ),
      );
      final content = (result['snippet'] ?? result['content'] ?? '').toString();
      if (content.trim().isEmpty) {
        throw Exception('Fetch URL result contained empty page content');
      }
      return WebFetchResult(
        url: (result['url'] ?? url).toString(),
        title: result['title']?.toString(),
        content: content,
      );
    } catch (e) {
      throw Exception('Perplexity fetch failed: $e');
    }
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required PerplexityOptions serviceOptions,
    String? apiKeyOverride,
  }) async {
    try {
      final body = <String, dynamic>{
        'query': query,
        'max_results': commonOptions.resultSize.clamp(1, 20),
      };

      if (serviceOptions.country != null &&
          serviceOptions.country!.trim().isNotEmpty) {
        body['country'] = serviceOptions.country!.trim();
      }
      if (serviceOptions.searchDomainFilter != null &&
          serviceOptions.searchDomainFilter!.isNotEmpty) {
        body['search_domain_filter'] = serviceOptions.searchDomainFilter;
      }
      if (serviceOptions.maxTokensPerPage != null) {
        body['max_tokens_per_page'] = serviceOptions.maxTokensPerPage;
      }

      final response = await client
          .post(
            Uri.parse('https://api.perplexity.ai/search'),
            headers: {
              'Authorization':
                  'Bearer ${apiKeyOverride ?? serviceOptions.apiKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final resultsList = (data['results'] as List?) ?? const <dynamic>[];
      // Support both single-query (list of items) and multi-query (list of lists)
      final flat = <Map<String, dynamic>>[];
      for (final item in resultsList) {
        if (item is List) {
          for (final sub in item) {
            if (sub is Map<String, dynamic>) flat.add(sub);
          }
        } else if (item is Map<String, dynamic>) {
          flat.add(item);
        }
      }

      final items = flat.take(commonOptions.resultSize).map((m) {
        return SearchResultItem(
          title: (m['title'] ?? '').toString(),
          url: (m['url'] ?? '').toString(),
          text: (m['snippet'] ?? '').toString(),
        );
      }).toList();

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('Perplexity search failed: $e');
    }
  }

  /// Normalizes a URL for comparison: lowercases the scheme/host, strips the
  /// fragment, default ports and trailing slash, percent-decodes the path,
  /// and sorts query parameters so reordered query strings compare equal.
  /// Returns null for unparseable values so a malformed candidate never
  /// matches the requested URL.
  static String? _normalizeUrl(Uri? uri) {
    final origin = _normalizeOriginPath(uri);
    if (origin == null) return null;
    final queryKeys = uri!.queryParameters.keys.toList()..sort();
    if (queryKeys.isEmpty) return origin;
    return '$origin?${queryKeys.map((k) => '$k=${uri.queryParameters[k]}').join('&')}';
  }

  /// Normalizes only the scheme/host/path (ignoring query and fragment) for
  /// the lenient fallback match. Returns null for unparseable values.
  static String? _normalizeOriginPath(Uri? uri) {
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) return null;
    var port = uri.port;
    if ((uri.scheme == 'http' && port == 80) ||
        (uri.scheme == 'https' && port == 443)) {
      port = -1;
    }
    // pathSegments are percent-decoded, so encoding differences (e.g. %20 vs
    // a literal space) and a single trailing slash compare equal.
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final path = '/${segments.join('/')}';
    final portPart = port < 0 ? '' : ':$port';
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}'
        '$portPart$path';
  }
}
