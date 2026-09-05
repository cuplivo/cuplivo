import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/api_keys.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api_key_manager.dart';

ApiKeyConfig _key(String id, String value) {
  return ApiKeyConfig(id: id, key: value, createdAt: 1, updatedAt: 1);
}

ApiKeyConfig _usedKey(String id, String value, int totalRequests) {
  return _key(
    id,
    value,
  ).copyWith(usage: ApiKeyUsage(totalRequests: totalRequests));
}

ProviderConfig _provider({
  required String id,
  required List<ApiKeyConfig> keys,
  LoadBalanceStrategy strategy = LoadBalanceStrategy.roundRobin,
  KeyManagementConfig? keyManagement,
}) {
  return ProviderConfig(
    id: id,
    enabled: true,
    name: id,
    apiKey: '',
    baseUrl: 'https://example.test/v1',
    providerType: ProviderKind.openai,
    multiKeyEnabled: true,
    apiKeys: keys,
    keyManagement: keyManagement ?? KeyManagementConfig(strategy: strategy),
  );
}

void main() {
  group('ApiKeyManager', () {
    test('successful status update clears a prior key error', () {
      final key = ApiKeyConfig.create(
        'key',
      ).copyWith(status: ApiKeyStatus.error, lastError: 'previous failure');

      final updated = ApiKeyManager().updateKeyStatusFromConfig(
        const KeyManagementConfig(),
        key,
        true,
      );

      expect(updated.status, ApiKeyStatus.active);
      expect(updated.lastError, isNull);
    });

    test('round robin consumes keys in configured list order', () {
      final provider = _provider(
        id: 'round-robin-list-order',
        keys: [
          _key('key_z', 'first'),
          _key('key_a', 'second'),
          _key('key_m', 'third'),
        ],
      );
      final manager = ApiKeyManager();

      final selected = [
        manager.selectForProvider(provider).key?.key,
        manager.selectForProvider(provider).key?.key,
        manager.selectForProvider(provider).key?.key,
        manager.selectForProvider(provider).key?.key,
      ];

      expect(selected, ['first', 'second', 'third', 'first']);
    });

    test(
      'round robin skips disabled keys without reordering remaining keys',
      () {
        final provider = _provider(
          id: 'round-robin-disabled-skip',
          keys: [
            _key('key_m', 'disabled').copyWith(isEnabled: false),
            _key('key_z', 'second'),
            _key('key_a', 'third'),
          ],
        );
        final manager = ApiKeyManager();

        final selected = [
          manager.selectForProvider(provider).key?.key,
          manager.selectForProvider(provider).key?.key,
          manager.selectForProvider(provider).key?.key,
        ];

        expect(selected, ['second', 'third', 'second']);
      },
    );

    test('returns no available keys when all configured keys are disabled', () {
      final provider = _provider(
        id: 'round-robin-no-available',
        keys: [
          _key('key_a', 'first').copyWith(isEnabled: false),
          _key('key_b', 'second').copyWith(status: ApiKeyStatus.disabled),
        ],
      );

      final result = ApiKeyManager().selectForProvider(provider);

      expect(result.key, isNull);
      expect(result.reason, 'no_available_keys');
    });

    test('priority strategy still selects the lowest priority value', () {
      final provider = _provider(
        id: 'priority-strategy',
        strategy: LoadBalanceStrategy.priority,
        keys: [
          _key('key_a', 'normal').copyWith(priority: 5),
          _key('key_b', 'preferred').copyWith(priority: 1),
        ],
      );

      final result = ApiKeyManager().selectForProvider(provider);

      expect(result.key?.key, 'preferred');
    });

    test('least used strategy still selects the key with fewer requests', () {
      final provider = _provider(
        id: 'least-used-strategy',
        strategy: LoadBalanceStrategy.leastUsed,
        keys: [_usedKey('key_a', 'busy', 5), _usedKey('key_b', 'idle', 1)],
      );

      final result = ApiKeyManager().selectForProvider(provider);

      expect(result.key?.key, 'idle');
    });

    test('error key is selectable again once its cooldown has elapsed', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final key = _key(
        'key_a',
        'recovered',
      ).copyWith(status: ApiKeyStatus.error, updatedAt: now - 10 * 60 * 1000);
      final provider = _provider(
        id: 'cooldown-expired',
        keys: [key],
        keyManagement: const KeyManagementConfig(
          failureRecoveryTimeMinutes: 5,
          enableAutoRecovery: false,
        ),
      );

      final result = ApiKeyManager().selectForProvider(provider);

      expect(result.key?.key, 'recovered');
      expect(result.reason, 'strategy_roundRobin');
    });

    test(
      'error key inside its cooldown is skipped when auto recovery is off',
      () {
        final now = DateTime.now().millisecondsSinceEpoch;
        final key = _key(
          'key_a',
          'cooling',
        ).copyWith(status: ApiKeyStatus.error, updatedAt: now - 60 * 1000);
        final provider = _provider(
          id: 'cooldown-active',
          keys: [key],
          keyManagement: const KeyManagementConfig(
            failureRecoveryTimeMinutes: 5,
            enableAutoRecovery: false,
          ),
        );

        final result = ApiKeyManager().selectForProvider(provider);

        expect(result.key, isNull);
        expect(result.reason, 'no_available_keys');
      },
    );

    test('all-error pool escalates to the key with the earliest failure', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Both inside the 5-minute cooldown; oldest failure is last in the
      // list to prove escalation is ordered by recency, not list order.
      final provider = _provider(
        id: 'escalation-oldest',
        keys: [
          _key(
            'key_b',
            'fresh-fail',
          ).copyWith(status: ApiKeyStatus.error, updatedAt: now - 60 * 1000),
          _key('key_a', 'old-fail').copyWith(
            status: ApiKeyStatus.error,
            updatedAt: now - 4 * 60 * 1000,
          ),
        ],
      );

      final result = ApiKeyManager().selectForProvider(provider);

      expect(result.key?.key, 'old-fail');
      expect(result.reason, 'escalation_all_error');
    });

    test('escalation is disabled by enableAutoRecovery=false', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final provider = _provider(
        id: 'escalation-disabled',
        keys: [
          _key('key_a', 'failing').copyWith(
            status: ApiKeyStatus.error,
            updatedAt: now - 3 * 60 * 1000,
          ),
        ],
        keyManagement: const KeyManagementConfig(
          failureRecoveryTimeMinutes: 5,
          enableAutoRecovery: false,
        ),
      );

      final result = ApiKeyManager().selectForProvider(provider);

      expect(result.key, isNull);
      expect(result.reason, 'no_available_keys');
    });

    test('active keys take precedence over escalation candidates', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final provider = _provider(
        id: 'escalation-not-triggered',
        keys: [
          _key(
            'key_a',
            'cooling',
          ).copyWith(status: ApiKeyStatus.error, updatedAt: now - 60 * 1000),
          _key('key_b', 'healthy'),
        ],
      );

      final result = ApiKeyManager().selectForProvider(provider);

      expect(result.key?.key, 'healthy');
      expect(result.reason, 'strategy_roundRobin');
    });
  });
}
