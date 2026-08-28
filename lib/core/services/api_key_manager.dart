import 'dart:math';
import '../models/api_keys.dart';
import '../providers/settings_provider.dart';

class KeySelectionResult {
  final ApiKeyConfig? key;
  final String reason;
  const KeySelectionResult(this.key, this.reason);
}

class ApiKeyManager {
  static final ApiKeyManager _instance = ApiKeyManager._internal();
  factory ApiKeyManager() => _instance;
  ApiKeyManager._internal();

  final Map<String, int> _roundRobinIndexMap = {}; // scopeId -> index
  final Map<String, int> _keyUsageMap = {}; // keyId -> total uses (ephemeral)

  KeySelectionResult selectForProvider(ProviderConfig provider) {
    return selectFromKeys(
      provider.apiKeys ?? const [],
      provider.keyManagement ?? const KeyManagementConfig(),
      provider.id,
    );
  }

  KeySelectionResult selectFromKeys(
    List<ApiKeyConfig> keys,
    KeyManagementConfig config,
    String scopeId,
  ) {
    final enabled = List<ApiKeyConfig>.from(keys.where((k) => k.isEnabled));
    if (enabled.isEmpty) return const KeySelectionResult(null, 'no_keys');

    final now = DateTime.now().millisecondsSinceEpoch;
    final cooldownMs = config.failureRecoveryTimeMinutes * 60 * 1000;
    // An error key becomes selectable again once its cooldown has elapsed;
    // the next failure re-marks it error with a fresh [updatedAt] (new
    // cooldown), while success flips it back to active.
    final available = enabled.where((k) {
      if (k.status == ApiKeyStatus.error) {
        return now - k.updatedAt >= cooldownMs;
      }
      return k.status == ApiKeyStatus.active;
    }).toList();

    if (available.isEmpty) {
      final probe = _recoveryProbe(enabled, config);
      if (probe != null) {
        return KeySelectionResult(probe, 'escalation_all_error');
      }
      return const KeySelectionResult(null, 'no_available_keys');
    }

    final strategy = config.strategy;
    ApiKeyConfig chosen;
    switch (strategy) {
      case LoadBalanceStrategy.priority:
        available.sort((a, b) => a.priority.compareTo(b.priority));
        chosen = available.first;
        break;
      case LoadBalanceStrategy.leastUsed:
        available.sort(
          (a, b) => (a.usage.totalRequests).compareTo(b.usage.totalRequests),
        );
        chosen = available.first;
        break;
      case LoadBalanceStrategy.random:
        chosen = available[Random().nextInt(available.length)];
        break;
      case LoadBalanceStrategy.roundRobin:
        final cur =
            _roundRobinIndexMap[scopeId] ?? (config.roundRobinIndex ?? 0);
        final idx = cur % available.length;
        chosen = available[idx];
        _roundRobinIndexMap[scopeId] = (idx + 1) % available.length;
        break;
    }

    return KeySelectionResult(chosen, 'strategy_${strategy.name}');
  }

  /// When every enabled key is inside its failure cooldown, re-admit the key
  /// whose cooldown is closest to expiry (its failure is the oldest) as a
  /// single probe, so a recovering provider resumes without user intervention.
  /// Escalation is gated by [KeyManagementConfig.enableAutoRecovery]. Callers
  /// that persist the updated key (e.g. `SearchToolService._runWithKeyRotation`)
  /// refresh [ApiKeyConfig.updatedAt] on a probe failure, so consecutive probes
  /// rotate across keys instead of hammering one.
  static ApiKeyConfig? _recoveryProbe(
    List<ApiKeyConfig> enabled,
    KeyManagementConfig config,
  ) {
    if (!config.enableAutoRecovery) return null;
    final candidates = enabled
        .where((k) => k.status == ApiKeyStatus.error)
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    return candidates.first;
  }

  ApiKeyConfig updateKeyStatus(
    ProviderConfig provider,
    ApiKeyConfig key,
    bool success, {
    String? error,
  }) {
    return updateKeyStatusFromConfig(
      provider.keyManagement ?? const KeyManagementConfig(),
      key,
      success,
      error: error,
    );
  }

  ApiKeyConfig updateKeyStatusFromConfig(
    KeyManagementConfig config,
    ApiKeyConfig key,
    bool success, {
    String? error,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var updated = key.copyWith(
      usage: key.usage.copyWith(
        totalRequests: key.usage.totalRequests + 1,
        successfulRequests: key.usage.successfulRequests + (success ? 1 : 0),
        failedRequests: key.usage.failedRequests + (success ? 0 : 1),
        consecutiveFailures: success ? 0 : (key.usage.consecutiveFailures + 1),
        lastUsed: now,
      ),
      status: success
          ? ApiKeyStatus.active
          : (key.usage.consecutiveFailures + 1) >=
                (config.maxFailuresBeforeDisable)
          ? ApiKeyStatus.error
          : key.status,
      lastError: success ? null : (error ?? key.lastError),
      updatedAt: now,
    );
    _keyUsageMap[updated.id] = (_keyUsageMap[updated.id] ?? 0) + 1;
    return updated;
  }

  void recordKeyUsage(String keyId, bool success) {
    _keyUsageMap[keyId] = (_keyUsageMap[keyId] ?? 0) + 1;
  }

  int? getRoundRobinIndex(String scopeId) => _roundRobinIndexMap[scopeId];
}
