import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart' show debugPrint;

import '../../providers/settings_provider.dart';
import '../api/chat_api_helpers.dart';
import '../model_spec/model_spec_resolver.dart';
import '../network/provider_http_client.dart';
import 'decision_dialect.dart';
import 'decision_outcome.dart';
import 'decision_question.dart';
import 'openai_decisions_dialect.dart';
import 'systemone_dialect.dart';

/// Asks a decision model one typed question and returns its answer.
///
/// Every call is a single attempt on purpose: a decision answer is worth
/// milliseconds, and the retry that matters already exists at the call site
/// (keep the current state, degrade, fall back to a member). Nothing here
/// guesses on the model's behalf — [DecisionUnavailable] travels back with the
/// reason and the caller decides what a missing answer means.
abstract final class DecisionClient {
  static const Duration defaultTimeout = Duration(seconds: 8);

  /// Whether [config]/[modelId] can be asked a decision question at all: the
  /// model has to be a decision model.
  static bool canDecide(ProviderConfig config, String modelId) {
    try {
      return ModelSpecResolver.instance.spec(config, modelId).isDecision;
    } catch (_) {
      return false;
    }
  }

  /// Where [modelId] is asked: the user's URL override when there is one,
  /// otherwise the dialect's own path under the provider's base URL.
  static Uri endpointFor(
    ProviderConfig config,
    String modelId,
    DecisionDialect dialect,
  ) {
    final override = DecisionDialectSetting.urlOverride(config, modelId);
    if (override != null) {
      return resolveDecisionUrl(override, providerBaseUrl: config.baseUrl);
    }
    return switch (dialect) {
      DecisionDialect.systemOne => SystemOneDialect.endpoint(config),
      DecisionDialect.openAi => OpenAiDecisionsDialect.endpoint(config),
    };
  }

  /// Reads an override the way a person types one: a whole URL, host-and-path,
  /// or a bare path.
  ///
  /// A bare path is resolved against the provider's **origin**, not its base
  /// URL: the decision endpoint sits beside `/v1`, not under it, so
  /// `/api/alpha/decisions` against `https://openrouter.ai/api/v1` must become
  /// `https://openrouter.ai/api/alpha/decisions`. A missing scheme borrows the
  /// provider's, so a self-hosted `http` gateway keeps its scheme.
  static Uri resolveDecisionUrl(String raw, {required String providerBaseUrl}) {
    final value = raw.trim();
    final base = Uri.tryParse(providerBaseUrl.trim());
    final scheme = (base != null && base.scheme.isNotEmpty)
        ? base.scheme
        : 'https';
    if (RegExp(
      r'^[a-z][a-z0-9+.\-]*://',
      caseSensitive: false,
    ).hasMatch(value)) {
      return Uri.parse(value);
    }
    if (value.startsWith('//')) return Uri.parse('$scheme:$value');
    if (value.startsWith('/')) {
      if (base == null || base.host.isEmpty) return Uri.parse(value);
      final origin = Uri(
        scheme: scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
      );
      return origin.resolve(value);
    }
    return Uri.parse('$scheme://$value');
  }

  static Future<DecisionOutcome> ask({
    required ProviderConfig config,
    required String modelId,
    required DecisionQuestion question,
    Duration timeout = defaultTimeout,
    CancelToken? cancelToken,
  }) async {
    final dialect = DecisionDialectSetting.of(config, modelId);
    final uri = endpointFor(config, modelId, dialect);
    final body = switch (dialect) {
      DecisionDialect.systemOne => SystemOneDialect.encode(
        model: apiModelId(config, modelId),
        question: question,
      ),
      DecisionDialect.openAi => OpenAiDecisionsDialect.encode(
        model: apiModelId(config, modelId),
        question: question,
      ),
    };
    final client = providerHttpClient(config, cancelToken: cancelToken);
    try {
      final response = await client
          .post(
            uri,
            headers: customHeaders(
              config,
              modelId,
              baseHeaders: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${apiKeyForRequest(config, modelId)}',
              },
            ),
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // A decision endpoint rejects the whole body at once, and says which
        // field it disliked: keep that sentence in the log, or a wrong dialect
        // is only ever "the director failed".
        final detail = utf8
            .decode(response.bodyBytes, allowMalformed: true)
            .replaceAll(RegExp(r'\s+'), ' ');
        debugPrint(
          '[Decision] $uri answered ${response.statusCode}: '
          '${detail.length > 500 ? '${detail.substring(0, 500)}…' : detail}',
        );
        return DecisionUnavailable(
          DecisionFailure.request,
          status: response.statusCode,
        );
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        return const DecisionUnavailable(DecisionFailure.malformed);
      }
      return switch (dialect) {
        DecisionDialect.systemOne => SystemOneDialect.decode(
          body: decoded,
          question: question,
        ),
        DecisionDialect.openAi => OpenAiDecisionsDialect.decode(
          body: decoded,
          question: question,
        ),
      };
    } on TimeoutException {
      return const DecisionUnavailable(DecisionFailure.timeout);
    } catch (_) {
      return const DecisionUnavailable(DecisionFailure.request);
    } finally {
      client.close();
    }
  }
}
