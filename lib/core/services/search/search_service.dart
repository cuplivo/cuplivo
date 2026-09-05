import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../models/api_keys.dart';
import '../network/logging_http_client.dart';
// Import statements for service implementations
import 'providers/bing_search_service.dart';
import 'providers/tavily_search_service.dart';
import 'providers/exa_search_service.dart';
import 'providers/zhipu_search_service.dart';
import 'providers/searxng_search_service.dart';
import 'providers/linkup_search_service.dart';
import 'providers/brave_search_service.dart';
import 'providers/metaso_search_service.dart';
import 'providers/ollama_search_service.dart';
import 'providers/jina_search_service.dart';
import 'providers/bocha_search_service.dart';
import 'providers/perplexity_search_service.dart';
import 'providers/duckduckgo_search_service.dart';
import 'providers/serper_search_service.dart';
import 'providers/grok_search_service.dart';
import 'providers/querit_search_service.dart';
import 'providers/stepfun_search_service.dart';
import 'providers/firecrawl_search_service.dart';
import 'providers/tinyfish_search_service.dart';
import 'providers/doubao_search_service.dart';

// Base interface for all search services
abstract class SearchService<T extends SearchServiceOptions> {
  /// HTTP client used for provider requests. Defaults to the shared
  /// search-logging wrapper; tests may inject a mock.
  final http.Client client;

  SearchService({http.Client? client})
    : client = client ?? LoggingHttpClient.of(LoggingCategory.search);

  String get name;

  Widget description(BuildContext context);

  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required T serviceOptions,
    String? apiKeyOverride,
  });

  /// Whether this provider exposes an official API for reading a known URL.
  bool get supportsNativeFetch => false;

  /// Fetches a known URL through the provider's official API.
  ///
  /// [fetchClient] is owned by the caller so one client can be reused while
  /// rotating API keys and then closed deterministically.
  Future<WebFetchResult> fetch({
    required Uri url,
    required SearchCommonOptions commonOptions,
    required T serviceOptions,
    required http.Client fetchClient,
    String? apiKeyOverride,
  }) {
    throw UnsupportedError('$name does not provide native web fetch');
  }

  // Factory method to get service instance based on options type. Tests may
  // inject a mock [client]; production callers use the shared default.
  static SearchService getService(
    SearchServiceOptions options, {
    http.Client? client,
  }) {
    switch (options) {
      case BingLocalOptions _:
        return BingSearchService(client: client) as SearchService;
      case TavilyOptions _:
        return TavilySearchService(client: client) as SearchService;
      case ExaOptions _:
        return ExaSearchService(client: client) as SearchService;
      case ZhipuOptions _:
        return ZhipuSearchService(client: client) as SearchService;
      case SearXNGOptions _:
        return SearXNGSearchService(client: client) as SearchService;
      case LinkUpOptions _:
        return LinkUpSearchService(client: client) as SearchService;
      case BraveOptions _:
        return BraveSearchService(client: client) as SearchService;
      case MetasoOptions _:
        return MetasoSearchService(client: client) as SearchService;
      case OllamaOptions _:
        return OllamaSearchService(client: client) as SearchService;
      case JinaOptions _:
        return JinaSearchService(client: client) as SearchService;
      case BochaOptions _:
        return BochaSearchService(client: client) as SearchService;
      case PerplexityOptions _:
        return PerplexitySearchService(client: client) as SearchService;
      case DuckDuckGoOptions _:
        return DuckDuckGoSearchService(client: client) as SearchService;
      case SerperOptions _:
        return SerperSearchService(client: client) as SearchService;
      case GrokOptions _:
        return GrokSearchService(client: client) as SearchService;
      case QueritOptions _:
        return QueritSearchService(client: client) as SearchService;
      case StepFunOptions _:
        return StepFunSearchService(client: client) as SearchService;
      case FirecrawlOptions _:
        return FirecrawlSearchService(client: client) as SearchService;
      case TinyFishOptions _:
        return TinyFishSearchService(client: client) as SearchService;
      case DoubaoOptions _:
        return DoubaoSearchService(client: client) as SearchService;
      default:
        return BingSearchService() as SearchService;
    }
  }

  /// Whether this service type uses API keys (keyless services don't show key UI).
  static bool serviceUsesKeys(SearchServiceOptions options) {
    return options is! BingLocalOptions &&
        options is! DuckDuckGoOptions &&
        options is! SearXNGOptions;
  }
}

class WebFetchResult {
  final String url;
  final String? title;
  final String content;

  const WebFetchResult({required this.url, this.title, required this.content});
}

// Search result data structure
class SearchResult {
  final String? answer;
  final List<SearchResultItem> items;

  SearchResult({this.answer, required this.items});

  Map<String, dynamic> toJson() => {
    if (answer != null) 'answer': answer,
    'items': items.map((e) => e.toJson()).toList(),
  };

  factory SearchResult.fromJson(Map<String, dynamic> json) => SearchResult(
    answer: json['answer'],
    items: (json['items'] as List)
        .map((e) => SearchResultItem.fromJson(e))
        .toList(),
  );
}

class SearchResultItem {
  final String title;
  final String url;
  final String text;
  String? id;
  int? index;

  SearchResultItem({
    required this.title,
    required this.url,
    required this.text,
    this.id,
    this.index,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'text': text,
    if (id != null) 'id': id,
    if (index != null) 'index': index,
  };

  factory SearchResultItem.fromJson(Map<String, dynamic> json) =>
      SearchResultItem(
        title: json['title'],
        url: json['url'],
        text: json['text'],
        id: json['id'],
        index: json['index'],
      );
}

// Common search options
class SearchCommonOptions {
  final int resultSize;
  final int timeout;
  final bool enableFetchForUnsupportedProviders;

  const SearchCommonOptions({
    this.resultSize = 10,
    this.timeout = 5000,
    this.enableFetchForUnsupportedProviders = true,
  });

  Map<String, dynamic> toJson() => {
    'resultSize': resultSize,
    'timeout': timeout,
    'enableFetchForUnsupportedProviders': enableFetchForUnsupportedProviders,
  };

  factory SearchCommonOptions.fromJson(Map<String, dynamic> json) =>
      SearchCommonOptions(
        resultSize: json['resultSize'] ?? 10,
        timeout: json['timeout'] ?? 5000,
        enableFetchForUnsupportedProviders:
            json['enableFetchForUnsupportedProviders'] ?? true,
      );

  SearchCommonOptions copyWith({
    int? resultSize,
    int? timeout,
    bool? enableFetchForUnsupportedProviders,
  }) => SearchCommonOptions(
    resultSize: resultSize ?? this.resultSize,
    timeout: timeout ?? this.timeout,
    enableFetchForUnsupportedProviders:
        enableFetchForUnsupportedProviders ??
        this.enableFetchForUnsupportedProviders,
  );
}

// Base class for service-specific options
abstract class SearchServiceOptions {
  final String id;
  final List<ApiKeyConfig> apiKeys;
  final KeyManagementConfig? keyManagement;

  const SearchServiceOptions({
    required this.id,
    this.apiKeys = const [],
    this.keyManagement,
  });

  /// Resolves the first active key for backward-compatible single-key access.
  /// Provider implementations (TavilySearchService, etc.) call this getter
  /// and never see the list. Rotation happens in SearchToolService.
  String get apiKey {
    if (apiKeys.isEmpty) return '';
    final enabled = apiKeys.where((k) => k.isEnabled).toList();
    if (enabled.isEmpty) return apiKeys.first.key;
    return enabled.first.key;
  }

  Map<String, dynamic> toJson();

  /// Dual-read: prefers the full `keyConfigs` objects written by Cuplivo
  /// exports (lossless round-trip), then the `apiKeys` list, then the legacy
  /// `apiKey` string. `apiKeys` may be either a list of ApiKeyConfig objects
  /// (Cuplivo's native shape) or a list of plain key strings (Kelivo's
  /// round-robin pool shape) when the backup originated from Kelivo.
  static List<ApiKeyConfig> readKeys(Map<String, dynamic> json) {
    final configs = json['keyConfigs'];
    if (configs is List && configs.isNotEmpty) {
      return configs
          .map((e) => ApiKeyConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (json['apiKeys'] != null) {
      final rawKeys = json['apiKeys'] as List;
      if (rawKeys.isNotEmpty && rawKeys.every((e) => e is Map)) {
        return rawKeys
            .map((e) => ApiKeyConfig.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [
        for (final key in rawKeys)
          if (key.toString().trim().isNotEmpty)
            ApiKeyConfig.create(key.toString()),
      ];
    }
    final legacy = json['apiKey'] as String?;
    if (legacy != null && legacy.isNotEmpty) {
      return [ApiKeyConfig.create(legacy)];
    }
    return [];
  }

  /// Dual-write: writes the full `apiKeys` list AND the first active key as
  /// legacy `apiKey` string for backward compat with older versions.
  static void writeKeys(
    Map<String, dynamic> json,
    List<ApiKeyConfig> keys, {
    KeyManagementConfig? keyManagement,
  }) {
    json['apiKeys'] = keys.map((k) => k.toJson()).toList();
    final active = keys.where((k) => k.isEnabled);
    json['apiKey'] = active.isNotEmpty
        ? active.first.key
        : (keys.isNotEmpty ? keys.first.key : '');
    if (keyManagement != null) {
      json['keyManagement'] = keyManagement.toJson();
    }
  }

  static KeyManagementConfig? readKeyManagement(Map<String, dynamic> json) {
    if (json['keyManagement'] != null) {
      return KeyManagementConfig.fromJson(
        json['keyManagement'] as Map<String, dynamic>,
      );
    }
    return null;
  }

  static SearchServiceOptions fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'bing_local':
        return BingLocalOptions.fromJson(json);
      case 'tavily':
        return TavilyOptions.fromJson(json);
      case 'exa':
        return ExaOptions.fromJson(json);
      case 'zhipu':
        return ZhipuOptions.fromJson(json);
      case 'searxng':
        return SearXNGOptions.fromJson(json);
      case 'linkup':
        return LinkUpOptions.fromJson(json);
      case 'brave':
        return BraveOptions.fromJson(json);
      case 'metaso':
        return MetasoOptions.fromJson(json);
      case 'ollama':
        return OllamaOptions.fromJson(json);
      case 'jina':
        return JinaOptions.fromJson(json);
      case 'bocha':
        return BochaOptions.fromJson(json);
      case 'duckduckgo':
        return DuckDuckGoOptions.fromJson(json);
      case 'perplexity':
        return PerplexityOptions.fromJson(json);
      case 'serper':
        return SerperOptions.fromJson(json);
      case 'grok':
        return GrokOptions.fromJson(json);
      case 'querit':
        return QueritOptions.fromJson(json);
      case 'stepfun':
        return StepFunOptions.fromJson(json);
      case 'firecrawl':
        return FirecrawlOptions.fromJson(json);
      case 'tinyfish':
        return TinyFishOptions.fromJson(json);
      case 'doubao':
        return DoubaoOptions.fromJson(json);
      default:
        return BingLocalOptions(id: json['id']);
    }
  }

  static final SearchServiceOptions defaultOption = BingLocalOptions(
    id: 'default',
  );
}

// Service-specific option classes
class BingLocalOptions extends SearchServiceOptions {
  final String acceptLanguage;

  BingLocalOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.acceptLanguage = 'en-US,en;q=0.9',
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': 'bing_local',
    'id': id,
    'acceptLanguage': acceptLanguage,
  };

  factory BingLocalOptions.fromJson(Map<String, dynamic> json) =>
      BingLocalOptions(
        id: json['id'],
        apiKeys: SearchServiceOptions.readKeys(json),
        keyManagement: SearchServiceOptions.readKeyManagement(json),
        acceptLanguage: json['acceptLanguage'] ?? 'en-US,en;q=0.9',
      );
}

class TavilyOptions extends SearchServiceOptions {
  static const String defaultUrl = 'https://api.tavily.com/search';

  final String url;

  TavilyOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.url = '',
  });

  String get resolvedUrl {
    final trimmed = url.trim();
    return trimmed.isEmpty ? defaultUrl : trimmed;
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'tavily',
      'id': id,
      'url': url.trim(),
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory TavilyOptions.fromJson(Map<String, dynamic> json) => TavilyOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
    url: json['url'] ?? '',
  );
}

class ExaOptions extends SearchServiceOptions {
  static const String defaultUrl = 'https://api.exa.ai/search';

  final String url;

  ExaOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.url = '',
  });

  String get resolvedUrl {
    final trimmed = url.trim();
    return trimmed.isEmpty ? defaultUrl : trimmed;
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'type': 'exa', 'id': id, 'url': url.trim()};
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory ExaOptions.fromJson(Map<String, dynamic> json) => ExaOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
    url: json['url'] ?? '',
  );
}

class ZhipuOptions extends SearchServiceOptions {
  ZhipuOptions({required super.id, super.apiKeys, super.keyManagement});

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'type': 'zhipu', 'id': id};
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory ZhipuOptions.fromJson(Map<String, dynamic> json) => ZhipuOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
  );
}

class SearXNGOptions extends SearchServiceOptions {
  final String url;
  final String engines;
  final String language;
  final String username;
  final String password;

  SearXNGOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    required this.url,
    this.engines = '',
    this.language = '',
    this.username = '',
    this.password = '',
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': 'searxng',
    'id': id,
    'url': url,
    'engines': engines,
    'language': language,
    'username': username,
    'password': password,
  };

  factory SearXNGOptions.fromJson(Map<String, dynamic> json) => SearXNGOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
    url: json['url'],
    engines: json['engines'] ?? '',
    language: json['language'] ?? '',
    username: json['username'] ?? '',
    password: json['password'] ?? '',
  );
}

class LinkUpOptions extends SearchServiceOptions {
  LinkUpOptions({required super.id, super.apiKeys, super.keyManagement});

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'type': 'linkup', 'id': id};
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory LinkUpOptions.fromJson(Map<String, dynamic> json) => LinkUpOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
  );
}

class BraveOptions extends SearchServiceOptions {
  BraveOptions({required super.id, super.apiKeys, super.keyManagement});

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'type': 'brave', 'id': id};
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory BraveOptions.fromJson(Map<String, dynamic> json) => BraveOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
  );
}

class MetasoOptions extends SearchServiceOptions {
  MetasoOptions({required super.id, super.apiKeys, super.keyManagement});

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'type': 'metaso', 'id': id};
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory MetasoOptions.fromJson(Map<String, dynamic> json) => MetasoOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
  );
}

class OllamaOptions extends SearchServiceOptions {
  OllamaOptions({required super.id, super.apiKeys, super.keyManagement});

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'type': 'ollama', 'id': id};
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory OllamaOptions.fromJson(Map<String, dynamic> json) => OllamaOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
  );
}

class JinaOptions extends SearchServiceOptions {
  JinaOptions({required super.id, super.apiKeys, super.keyManagement});

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'type': 'jina', 'id': id};
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory JinaOptions.fromJson(Map<String, dynamic> json) => JinaOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
  );
}

class DuckDuckGoOptions extends SearchServiceOptions {
  final String region;

  DuckDuckGoOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.region = 'us-en',
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': 'duckduckgo',
    'id': id,
    'region': region,
  };

  factory DuckDuckGoOptions.fromJson(Map<String, dynamic> json) =>
      DuckDuckGoOptions(
        id: json['id'],
        apiKeys: SearchServiceOptions.readKeys(json),
        keyManagement: SearchServiceOptions.readKeyManagement(json),
        region: json['region'] ?? 'us-en',
      );
}

class PerplexityOptions extends SearchServiceOptions {
  final String? country; // ISO 3166-1 alpha-2
  final List<String>? searchDomainFilter; // domains/URLs
  final int? maxTokensPerPage; // default 1024

  PerplexityOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.country,
    this.searchDomainFilter,
    this.maxTokensPerPage,
  });

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'perplexity',
      'id': id,
      if (country != null) 'country': country,
      if (searchDomainFilter != null) 'searchDomainFilter': searchDomainFilter,
      if (maxTokensPerPage != null) 'maxTokensPerPage': maxTokensPerPage,
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory PerplexityOptions.fromJson(Map<String, dynamic> json) =>
      PerplexityOptions(
        id: json['id'],
        apiKeys: SearchServiceOptions.readKeys(json),
        keyManagement: SearchServiceOptions.readKeyManagement(json),
        country: json['country'],
        searchDomainFilter: (json['searchDomainFilter'] as List?)
            ?.map((e) => e.toString())
            .toList(),
        maxTokensPerPage: json['maxTokensPerPage'],
      );
}

class BochaOptions extends SearchServiceOptions {
  final String? freshness; // e.g., 'noLimit', 'week', 'month', etc.
  final bool summary; // whether to include textual summary
  final String? include; // e.g., 'qq.com|m.163.com'
  final String? exclude; // e.g., 'qq.com|m.163.com'

  BochaOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.freshness,
    this.summary = true,
    this.include,
    this.exclude,
  });

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'bocha',
      'id': id,
      if (freshness != null) 'freshness': freshness,
      'summary': summary,
      if (include != null) 'include': include,
      if (exclude != null) 'exclude': exclude,
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory BochaOptions.fromJson(Map<String, dynamic> json) => BochaOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
    freshness: json['freshness'],
    summary: (json['summary'] ?? true) as bool,
    include: json['include'],
    exclude: json['exclude'],
  );
}

class SerperOptions extends SearchServiceOptions {
  final String gl;
  final String hl;
  final String tbs;
  final int page;

  SerperOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.gl = '',
    this.hl = '',
    this.tbs = '',
    this.page = 1,
  });

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'serper',
      'id': id,
      'gl': gl.trim(),
      'hl': hl.trim(),
      'tbs': tbs.trim(),
      'page': page,
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory SerperOptions.fromJson(Map<String, dynamic> json) => SerperOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
    gl: json['gl'] ?? '',
    hl: json['hl'] ?? '',
    tbs: json['tbs'] ?? '',
    page: json['page'] ?? 1,
  );
}

class GrokOptions extends SearchServiceOptions {
  static const String defaultUrl = 'https://api.x.ai/v1/responses';
  static const String defaultModel = 'grok-4.5';
  static const String defaultReasoningEffort = 'low';
  static const String defaultSystemPrompt =
      "You are a helpful search assistant. Search the web to find accurate and up-to-date information for the user's query. Provide a comprehensive answer with citations.";

  final String model;
  final String reasoningEffort;
  final String customUrl;
  final String systemPrompt;

  GrokOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.model = defaultModel,
    String? reasoningEffort,
    this.customUrl = defaultUrl,
    this.systemPrompt = defaultSystemPrompt,
  }) : reasoningEffort =
           reasoningEffort ??
           ((model.trim().isEmpty || model.trim() == defaultModel)
               ? defaultReasoningEffort
               : '');

  String get resolvedUrl {
    final trimmed = customUrl.trim();
    return trimmed.isEmpty ? defaultUrl : trimmed;
  }

  String get resolvedModel {
    final trimmed = model.trim();
    return trimmed.isEmpty ? defaultModel : trimmed;
  }

  String get resolvedReasoningEffort => reasoningEffort.trim();

  String get resolvedSystemPrompt {
    final trimmed = systemPrompt.trim();
    return trimmed.isEmpty ? defaultSystemPrompt : trimmed;
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'grok',
      'id': id,
      'model': model.trim(),
      'reasoningEffort': reasoningEffort.trim(),
      'customUrl': customUrl.trim(),
      'systemPrompt': systemPrompt,
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory GrokOptions.fromJson(Map<String, dynamic> json) => GrokOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
    model: json['model'] ?? defaultModel,
    reasoningEffort: json['reasoningEffort'],
    customUrl: json['customUrl'] ?? defaultUrl,
    systemPrompt: json['systemPrompt'] ?? defaultSystemPrompt,
  );
}

class QueritOptions extends SearchServiceOptions {
  final String sitesInclude;
  final String sitesExclude;
  final String timeRange;
  final String countries;
  final String languages;

  QueritOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.sitesInclude = '',
    this.sitesExclude = '',
    this.timeRange = '',
    this.countries = '',
    this.languages = '',
  });

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'querit',
      'id': id,
      'sitesInclude': sitesInclude.trim(),
      'sitesExclude': sitesExclude.trim(),
      'timeRange': timeRange.trim(),
      'countries': countries.trim(),
      'languages': languages.trim(),
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory QueritOptions.fromJson(Map<String, dynamic> json) => QueritOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
    sitesInclude: json['sitesInclude'] ?? '',
    sitesExclude: json['sitesExclude'] ?? '',
    timeRange: json['timeRange'] ?? '',
    countries: json['countries'] ?? '',
    languages: json['languages'] ?? '',
  );
}

class StepFunOptions extends SearchServiceOptions {
  static const String defaultUrl = 'https://api.stepfun.com/v1/search';

  final String url;
  final String category;

  StepFunOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.url = '',
    this.category = '',
  });

  String get resolvedUrl {
    final trimmed = url.trim();
    return trimmed.isEmpty ? defaultUrl : trimmed;
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'stepfun',
      'id': id,
      'url': url.trim(),
      'category': category.trim(),
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory StepFunOptions.fromJson(Map<String, dynamic> json) => StepFunOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
    url: json['url'] ?? '',
    category: json['category'] ?? '',
  );
}

class FirecrawlOptions extends SearchServiceOptions {
  static const String defaultUrl = 'https://api.firecrawl.dev/v2/search';

  final String url;
  final List<String> sources;
  final List<String> categories;
  final String country;
  final String location;

  FirecrawlOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.url = '',
    this.sources = const <String>['web'],
    this.categories = const <String>[],
    this.country = '',
    this.location = '',
  });

  String get resolvedUrl {
    final trimmed = url.trim();
    return trimmed.isEmpty ? defaultUrl : trimmed;
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'firecrawl',
      'id': id,
      'url': url.trim(),
      'sources': sources,
      'categories': categories,
      'country': country.trim(),
      'location': location.trim(),
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory FirecrawlOptions.fromJson(Map<String, dynamic> json) =>
      FirecrawlOptions(
        id: json['id'],
        apiKeys: SearchServiceOptions.readKeys(json),
        keyManagement: SearchServiceOptions.readKeyManagement(json),
        url: json['url'] ?? '',
        sources:
            (json['sources'] as List?)
                ?.map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList() ??
            const <String>['web'],
        categories:
            (json['categories'] as List?)
                ?.map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList() ??
            const <String>[],
        country: json['country'] ?? '',
        location: json['location'] ?? '',
      );
}

class TinyFishOptions extends SearchServiceOptions {
  static const String defaultUrl = 'https://api.search.tinyfish.ai';

  final String url;
  final String location;
  final String language;
  final String includeDomains;
  final String excludeDomains;

  TinyFishOptions({
    required super.id,
    super.apiKeys,
    super.keyManagement,
    this.url = '',
    this.location = '',
    this.language = '',
    this.includeDomains = '',
    this.excludeDomains = '',
  });

  String get resolvedUrl {
    final trimmed = url.trim();
    return trimmed.isEmpty ? defaultUrl : trimmed;
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'tinyfish',
      'id': id,
      'url': url.trim(),
      'location': location.trim(),
      'language': language.trim(),
      'includeDomains': includeDomains.trim(),
      'excludeDomains': excludeDomains.trim(),
    };
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory TinyFishOptions.fromJson(Map<String, dynamic> json) =>
      TinyFishOptions(
        id: json['id'],
        apiKeys: SearchServiceOptions.readKeys(json),
        keyManagement: SearchServiceOptions.readKeyManagement(json),
        url: json['url'] ?? '',
        location: json['location'] ?? '',
        language: json['language'] ?? '',
        includeDomains: json['includeDomains'] ?? '',
        excludeDomains: json['excludeDomains'] ?? '',
      );
}

class DoubaoOptions extends SearchServiceOptions {
  DoubaoOptions({required super.id, super.apiKeys, super.keyManagement});

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'type': 'doubao', 'id': id};
    SearchServiceOptions.writeKeys(json, apiKeys, keyManagement: keyManagement);
    return json;
  }

  factory DoubaoOptions.fromJson(Map<String, dynamic> json) => DoubaoOptions(
    id: json['id'],
    apiKeys: SearchServiceOptions.readKeys(json),
    keyManagement: SearchServiceOptions.readKeyManagement(json),
  );
}
