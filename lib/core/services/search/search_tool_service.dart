import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../../models/api_keys.dart';
import '../api_key_manager.dart';
import '../fetch/builtin_web_fetch_service.dart';
import '../fetch/web_fetch_content.dart';
import '../network/dio_http_client.dart';
import 'search_service.dart';
import '../../providers/settings_provider.dart';

class SearchToolService {
  static const String toolName = 'search_web';
  static const String fetchToolName = 'web_fetch';
  static const String toolDescription =
      '''Search the web for up-to-date information via the user's configured search engine. Returns results with title, URL, snippet, "index" (1-based rank) and "id" (6-char citation id). An optional "answer" summary may be included. Refer to the system prompt for when to use this tool and how to format inline citations.

When to use: (1) explicit request to search from the user; (2) the LATEST news/data such as exchange rate, pricing and availability; (3) changes to NEW versions of libraries / applications or any other content that are released after your knowledge cutoff; (4) time-sensitive fact check.

When NOT to use: (1) explicit request to disable searching; (2) YOUR self-identity, capabilities or YOUR opinion; (3) reasoning / calculation / common sense that is too trivial to warrant a search; (4) personal information or context that are already exposed in chat history or memory.

Citation Format: `Details [citation](index:id)`. Citations MUST follow th​e relevant fact immediat​ely, placed after the pu​nctuation. Never pile them all up at the end. Good example: The document shows that the feature requires 3.0+ version. [citation](1:d4e5f6) The steps are as follows: ... [citation](3:a1b2c3).

Best Practice: (1) Use keywords rather than a complete sentence for `query`; (2) Retry searching with different keywords if the first search doesn't find relevant information. If the search results ar​e consistently filled wi​th noise/irrelevant cont​ent, report to the user if possible; (3) Fetch relevant links after searching if relevant tools are available; (4) Prefer organizing information into fluent paragraphs to repeating titles and links unless specially requested; (5) If the `answer` field (AI abstract) exists, you can refer to it.''';

  static const String fetchToolDescription =
      '''Fetch the readable contents of a specific public web page through the user's configured search provider. Only fetch a URL that already appears in the conversation: one provided by the user or returned by a prior search or fetch tool. The URL must be an absolute http:// or https:// URL. Use start_index with the same URL to continue when truncated is true.''';
  static const String _builtInFetchDescription =
      ''' This provider uses Cuplivo's built-in reader. Optional headers can be sent to the page, and raw returns the original text instead of readable Markdown.''';
  static const Set<String> _builtInOnlyArguments = {'headers', 'raw'};

  static final RegExp _schemeRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

  static String _normalizeUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return u;

    // Strip surrounding quotes if the backend returns a JSON-ish value.
    if ((u.startsWith('"') && u.endsWith('"')) ||
        (u.startsWith("'") && u.endsWith("'"))) {
      u = u.substring(1, u.length - 1).trim();
    }
    if (u.isEmpty) return u;

    // Protocol-relative URL (e.g. //example.com/path)
    if (u.startsWith('//')) return 'https:$u';

    // No scheme => default to https.
    if (!_schemeRe.hasMatch(u)) return 'https://$u';
    return u;
  }

  static Map<String, dynamic> getToolDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': toolName,
        'description': toolDescription,
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query to look up online',
            },
          },
          'required': ['query'],
        },
      },
    };
  }

  static bool selectedProviderSupportsNativeFetch(SettingsProvider settings) {
    final services = settings.searchServices;
    if (services.isEmpty) return false;
    final index = settings.searchServiceSelected.clamp(0, services.length - 1);
    return SearchService.getService(services[index]).supportsNativeFetch;
  }

  static bool shouldExposeFetchTool(SettingsProvider settings) {
    if (settings.searchServices.isEmpty) return false;
    return selectedProviderSupportsNativeFetch(settings) ||
        settings.searchCommonOptions.enableFetchForUnsupportedProviders;
  }

  static bool shouldUseBuiltInFetch(SettingsProvider settings) =>
      settings.searchServices.isNotEmpty &&
      !selectedProviderSupportsNativeFetch(settings);

  static Map<String, dynamic> getFetchToolDefinition({
    bool includeBuiltInOptions = false,
  }) {
    return {
      'type': 'function',
      'function': {
        'name': fetchToolName,
        'description':
            '$fetchToolDescription${includeBuiltInOptions ? _builtInFetchDescription : ''}',
        'parameters': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': 'Absolute http:// or https:// URL to fetch',
            },
            'max_length': {
              'type': 'integer',
              'description': 'Maximum content characters to return',
              'default': WebFetchContentWindow.defaultMaxLength,
              'minimum': 1,
              'maximum': WebFetchContentWindow.maximumMaxLength,
            },
            'start_index': {
              'type': 'integer',
              'description': 'Character index used to continue a long page',
              'default': 0,
              'minimum': 0,
            },
            if (includeBuiltInOptions) ...{
              'headers': {
                'type': 'object',
                'description': 'Optional HTTP headers sent to the page',
                'additionalProperties': {'type': 'string'},
              },
              'raw': {
                'type': 'boolean',
                'description':
                    'Return raw source instead of compact, readable Markdown',
                'default': false,
              },
            },
          },
          'required': ['url'],
        },
      },
    };
  }

  static Future<String> executeSearch(
    String query,
    SettingsProvider settings, {
    http.Client? searchClient,
  }) async {
    final services = settings.searchServices;
    if (services.isEmpty) {
      return jsonEncode({'error': 'No search services configured'});
    }

    final selectedIndex = settings.searchServiceSelected.clamp(
      0,
      services.length - 1,
    );
    final serviceOptions = services[selectedIndex];
    final service = SearchService.getService(
      serviceOptions,
      client: searchClient,
    );
    final manager = ApiKeyManager();

    // Keyless services (BingLocal, DuckDuckGo, SearXNG) or providers whose
    // keys are all disabled — call directly (rotation needs an enabled key).
    if (serviceOptions.apiKeys.every((key) => !key.isEnabled)) {
      return _searchDirect(query, settings, service, serviceOptions);
    }

    // Keyed services: rotate keys on failure, retry transparently.
    final config = serviceOptions.keyManagement ?? const KeyManagementConfig();
    final beforeJson = serviceOptions.toJson();
    String? lastError;
    final result = await _runWithKeyRotation<String>(
      serviceOptions,
      manager,
      config,
      (apiKey) => _trySearch(
        query,
        settings,
        service,
        serviceOptions,
        apiKeyOverride: apiKey,
        onError: (error) => lastError = error,
      ),
      failureCode: 'search_failed',
    );

    // Persist updated key status/usage and roundRobinIndex back to settings.
    await _persistKeyUpdates(
      settings,
      selectedIndex,
      serviceOptions,
      manager,
      config,
      beforeJson,
    );

    return result ??
        jsonEncode({
          'error': 'All search keys failed${_errorSuffix(lastError)}',
        });
  }

  static Future<String> executeFetch(
    Map<String, dynamic> arguments,
    SettingsProvider settings, {
    http.Client? fetchClient,
  }) async {
    final urlRaw = (arguments['url'] ?? '').toString().trim();
    final url = Uri.tryParse(urlRaw);
    if (url == null ||
        !url.hasAuthority ||
        url.host.isEmpty ||
        !(url.isScheme('http') || url.isScheme('https'))) {
      return _fetchError('Invalid URL: expected an absolute http(s) URL');
    }

    final services = settings.searchServices;
    if (services.isEmpty) {
      return _fetchError('No search services configured', url: url);
    }
    final selectedIndex = settings.searchServiceSelected.clamp(
      0,
      services.length - 1,
    );
    final serviceOptions = services[selectedIndex];
    final service = SearchService.getService(serviceOptions);

    if (!service.supportsNativeFetch) {
      if (!settings.searchCommonOptions.enableFetchForUnsupportedProviders) {
        return _fetchError(
          'Built-in web fetch is disabled for ${service.name}',
          code: 'built_in_fetch_disabled',
          provider: service.name,
          url: url,
        );
      }

      BuiltInWebFetchRequest request;
      try {
        request = BuiltInWebFetchRequest.parse(arguments);
      } catch (e) {
        return _fetchError(
          e.toString(),
          code: 'invalid_parameters',
          provider: 'Cuplivo Built-in',
          url: url,
        );
      }
      try {
        final result = await BuiltInWebFetchService.fetch(
          request,
          timeout: Duration(milliseconds: settings.searchCommonOptions.timeout),
        );
        return _encodeFetchResult(
          provider: 'Cuplivo Built-in',
          result: WebFetchResult(
            url: result.url,
            title: result.title,
            content: result.content!,
          ),
          startIndex: request.startIndex,
          maxLength: request.maxLength,
          raw: result.raw,
        );
      } catch (e) {
        debugPrint('[web_fetch] Cuplivo built-in fetch failed for $url: $e');
        return _fetchError(
          'Cuplivo built-in fetch failed: $e',
          provider: 'Cuplivo Built-in',
          url: url,
        );
      }
    }

    final unsupportedArguments = arguments.keys
        .where(_builtInOnlyArguments.contains)
        .toList(growable: false);
    if (unsupportedArguments.isNotEmpty) {
      return _fetchError(
        '${service.name} does not support: ${unsupportedArguments.join(', ')}',
        code: 'unsupported_parameters',
        provider: service.name,
        url: url,
      );
    }

    final maxLength = _parseInteger(
      arguments['max_length'],
      defaultValue: WebFetchContentWindow.defaultMaxLength,
    );
    if (maxLength == null ||
        maxLength < 1 ||
        maxLength > WebFetchContentWindow.maximumMaxLength) {
      return _fetchError(
        'Invalid max_length: expected 1-${WebFetchContentWindow.maximumMaxLength}',
        code: 'invalid_parameters',
        url: url,
      );
    }
    final startIndex = _parseInteger(arguments['start_index'], defaultValue: 0);
    if (startIndex == null || startIndex < 0) {
      return _fetchError(
        'Invalid start_index: expected a non-negative integer',
        code: 'invalid_parameters',
        url: url,
      );
    }

    final client = fetchClient ?? DioHttpClient();
    final ownsClient = fetchClient == null;
    final manager = ApiKeyManager();
    final config = serviceOptions.keyManagement ?? const KeyManagementConfig();
    String? lastError;
    try {
      // Keyless or all-disabled keys: call directly (rotation needs an
      // enabled key).
      if (serviceOptions.apiKeys.every((key) => !key.isEnabled)) {
        final result = await _tryNativeFetch(
          url,
          settings,
          service,
          serviceOptions,
          client,
          onError: (error) => lastError = error,
        );
        if (result == null) {
          return _fetchError(
            '${service.name} fetch failed${_errorSuffix(lastError)}',
            provider: service.name,
            url: url,
          );
        }
        return _encodeFetchResult(
          provider: service.name,
          result: result,
          startIndex: startIndex,
          maxLength: maxLength,
        );
      }

      final beforeJson = serviceOptions.toJson();
      final result = await _runWithKeyRotation<WebFetchResult>(
        serviceOptions,
        manager,
        config,
        (apiKey) => _tryNativeFetch(
          url,
          settings,
          service,
          serviceOptions,
          client,
          apiKeyOverride: apiKey,
          onError: (error) => lastError = error,
        ),
        failureCode: 'fetch_failed',
      );

      await _persistKeyUpdates(
        settings,
        selectedIndex,
        serviceOptions,
        manager,
        config,
        beforeJson,
      );
      if (result == null) {
        return _fetchError(
          'All ${service.name} fetch keys failed${_errorSuffix(lastError)}',
          provider: service.name,
          url: url,
        );
      }
      return _encodeFetchResult(
        provider: service.name,
        result: result,
        startIndex: startIndex,
        maxLength: maxLength,
      );
    } finally {
      if (ownsClient) client.close();
    }
  }

  static Future<WebFetchResult?> _tryNativeFetch(
    Uri url,
    SettingsProvider settings,
    SearchService service,
    SearchServiceOptions serviceOptions,
    http.Client fetchClient, {
    String? apiKeyOverride,
    void Function(String error)? onError,
  }) async {
    try {
      return await service.fetch(
        url: url,
        commonOptions: settings.searchCommonOptions,
        serviceOptions: serviceOptions,
        fetchClient: fetchClient,
        apiKeyOverride: apiKeyOverride,
      );
    } catch (e) {
      debugPrint('[web_fetch] ${service.name} fetch failed for $url: $e');
      onError?.call(e.toString());
      return null;
    }
  }

  static String _encodeFetchResult({
    required String provider,
    required WebFetchResult result,
    required int startIndex,
    required int maxLength,
    bool raw = false,
  }) {
    final window = WebFetchContentWindow.fromText(
      result.content,
      startIndex: startIndex,
      maxLength: maxLength,
    );
    return jsonEncode({
      'provider': provider,
      'url': result.url,
      if (result.title?.trim().isNotEmpty == true)
        'title': result.title!.trim(),
      'content': window.content,
      'start_index': window.startIndex,
      'end_index': window.endIndex,
      'total_length': window.totalLength,
      'truncated': window.truncated,
      if (raw) 'raw': true,
      if (window.nextStartIndex != null)
        'next_start_index': window.nextStartIndex,
    });
  }

  static String _fetchError(
    String error, {
    String? code,
    String? provider,
    Uri? url,
  }) => jsonEncode({
    if (code != null) 'code': code,
    if (provider != null) 'provider': provider,
    if (url != null) 'url': url.toString(),
    'error': error,
  });

  /// Appends the underlying provider error to a generic failure message when
  /// available, so the model gets the root cause instead of a flat message.
  static String _errorSuffix(String? error) {
    if (error == null || error.isEmpty) return '';
    final trimmed = error.trim();
    if (trimmed.isEmpty) return '';
    return ': $trimmed';
  }

  static int? _parseInteger(Object? raw, {required int defaultValue}) {
    if (raw == null) return defaultValue;
    if (raw is int) return raw;
    if (raw is num && raw == raw.roundToDouble()) return raw.toInt();
    return int.tryParse(raw.toString());
  }

  /// Direct search for keyless services.
  static Future<String> _searchDirect(
    String query,
    SettingsProvider settings,
    SearchService service,
    SearchServiceOptions serviceOptions,
  ) async {
    final result = await _trySearch(query, settings, service, serviceOptions);
    if (result != null) return result;
    return jsonEncode({'error': 'Search failed'});
  }

  /// Runs one operation against each available key at most once.
  static Future<T?> _runWithKeyRotation<T>(
    SearchServiceOptions serviceOptions,
    ApiKeyManager manager,
    KeyManagementConfig config,
    Future<T?> Function(String apiKey) operation, {
    required String failureCode,
  }) async {
    final remaining = serviceOptions.apiKeys
        .where((key) => key.isEnabled)
        .toList();

    while (remaining.isNotEmpty) {
      final selection = manager.selectFromKeys(
        remaining,
        config,
        serviceOptions.id,
      );
      if (selection.key == null) break;

      final selected = selection.key!;
      final result = await operation(selected.key);
      final updated = manager.updateKeyStatusFromConfig(
        config,
        selected,
        result != null,
        error: result == null ? failureCode : null,
      );
      _replaceApiKey(serviceOptions.apiKeys, updated);
      remaining.removeWhere((key) => key.id == selected.id);
      if (result != null) return result;
    }
    return null;
  }

  /// Replaces an [ApiKeyConfig] in [list] by matching [id].
  static void _replaceApiKey(List<ApiKeyConfig> list, ApiKeyConfig updated) {
    final idx = list.indexWhere((k) => k.id == updated.id);
    if (idx >= 0) list[idx] = updated;
  }

  /// Persists updated key status/usage and roundRobinIndex back to settings.
  ///
  /// Only writes when the serialized options actually changed versus
  /// [beforeJson] (captured before key rotation) — a success on a
  /// single-key config or an unchanged round-robin index must not trigger a
  /// SharedPreferences write and settings notification on every call.
  static Future<void> _persistKeyUpdates(
    SettingsProvider settings,
    int selectedIndex,
    SearchServiceOptions serviceOptions,
    ApiKeyManager manager,
    KeyManagementConfig config,
    Map<String, dynamic> beforeJson,
  ) async {
    final roundRobinIndex = manager.getRoundRobinIndex(serviceOptions.id);
    final json = serviceOptions.toJson();

    if (roundRobinIndex != null &&
        config.strategy == LoadBalanceStrategy.roundRobin) {
      final updatedConfig = config.copyWith(roundRobinIndex: roundRobinIndex);
      json['keyManagement'] = updatedConfig.toJson();
    }
    if (jsonEncode(beforeJson) == jsonEncode(json)) return;

    final services = List<SearchServiceOptions>.from(settings.searchServices);
    services[selectedIndex] = SearchServiceOptions.fromJson(json);

    await settings.setSearchServices(services);
  }

  /// Returns the encoded result on success, or null on failure.
  static Future<String?> _trySearch(
    String query,
    SettingsProvider settings,
    SearchService service,
    SearchServiceOptions serviceOptions, {
    String? apiKeyOverride,
    void Function(String error)? onError,
  }) async {
    try {
      final result = await service.search(
        query: query,
        commonOptions: settings.searchCommonOptions,
        serviceOptions: serviceOptions,
        apiKeyOverride: apiKeyOverride,
      );

      final itemsWithIds = result.items.asMap().entries.map((entry) {
        final item = entry.value;
        return SearchResultItem(
          title: item.title,
          url: _normalizeUrl(item.url),
          text: item.text,
          id: const Uuid().v4().substring(0, 6),
          index: entry.key + 1,
        );
      }).toList();

      return jsonEncode({
        if (result.answer != null) 'answer': result.answer,
        'items': itemsWithIds.map((item) => item.toJson()).toList(),
      });
    } catch (e) {
      debugPrint('[search_web] ${service.name} search failed: $e');
      onError?.call(e.toString());
      return null;
    }
  }
}
