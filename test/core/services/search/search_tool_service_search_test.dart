import 'dart:convert';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/api_keys.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:Cuplivo/core/services/search/search_tool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  setUp(() {
    businessPrefs = BusinessPreferences.memoryForTests({});
  });

  test(
    'all-error pool escalates to the key with the earliest failure and recovers',
    () async {
      final settings = SettingsProvider(preferences: businessPrefs);
      await pumpEventQueue();
      final now = DateTime.now().millisecondsSinceEpoch;
      await settings.setSearchServices([
        TavilyOptions(
          id: 'probe-recovery',
          apiKeys: [
            ApiKeyConfig.create(
              'dead-new',
            ).copyWith(status: ApiKeyStatus.error, updatedAt: now - 60 * 1000),
            ApiKeyConfig.create('dead-old').copyWith(
              status: ApiKeyStatus.error,
              updatedAt: now - 4 * 60 * 1000,
            ),
          ],
          keyManagement: const KeyManagementConfig(
            failureRecoveryTimeMinutes: 5,
            maxFailuresBeforeDisable: 1,
          ),
        ),
      ]);
      final usedKeys = <String>[];
      final client = MockClient((request) async {
        usedKeys.add(request.headers['Authorization'] ?? '');
        return http.Response(
          jsonEncode({
            'results': [
              {
                'title': 'Example',
                'url': 'https://example.com/a',
                'content': 'hello world',
              },
            ],
          }),
          200,
        );
      });

      final result =
          jsonDecode(
                await SearchToolService.executeSearch(
                  'cuplivo',
                  settings,
                  searchClient: client,
                ),
              )
              as Map<String, dynamic>;

      expect(usedKeys, ['Bearer dead-old']);
      expect((result['items'] as List).length, 1);

      final old = settings.searchServices.single.apiKeys.firstWhere(
        (k) => k.key == 'dead-old',
      );
      expect(old.status, ApiKeyStatus.active);
      expect(old.lastError, isNull);
      expect(old.usage.successfulRequests, 1);
    },
  );

  test('all keys drained reports the underlying provider error', () async {
    final settings = SettingsProvider(preferences: businessPrefs);
    await pumpEventQueue();
    final now = DateTime.now().millisecondsSinceEpoch;
    await settings.setSearchServices([
      TavilyOptions(
        id: 'probe-all-fail',
        apiKeys: [
          ApiKeyConfig.create('dead-b').copyWith(
            status: ApiKeyStatus.error,
            updatedAt: now - 2 * 60 * 1000,
          ),
          ApiKeyConfig.create(
            'dead-a',
          ).copyWith(status: ApiKeyStatus.error, updatedAt: now - 60 * 1000),
        ],
        keyManagement: const KeyManagementConfig(
          failureRecoveryTimeMinutes: 5,
          maxFailuresBeforeDisable: 1,
        ),
      ),
    ]);
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('boom', 503);
    });

    final result =
        jsonDecode(
              await SearchToolService.executeSearch(
                'cuplivo',
                settings,
                searchClient: client,
              ),
            )
            as Map<String, dynamic>;

    expect(requests, 2);
    expect(result['error'], contains('All search keys failed'));
    expect(result['error'], contains('Tavily search failed'));
    expect(result['error'], contains('503'));
  });

  test('cooldown-expired error key is retried and healed on success', () async {
    final settings = SettingsProvider(preferences: businessPrefs);
    await pumpEventQueue();
    final now = DateTime.now().millisecondsSinceEpoch;
    await settings.setSearchServices([
      TavilyOptions(
        id: 'cooldown-heal',
        apiKeys: [
          ApiKeyConfig.create('expired-key').copyWith(
            status: ApiKeyStatus.error,
            lastError: 'previous failure',
            updatedAt: now - 10 * 60 * 1000,
          ),
        ],
        keyManagement: const KeyManagementConfig(
          failureRecoveryTimeMinutes: 5,
          enableAutoRecovery: false,
        ),
      ),
    ]);
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response(
        jsonEncode({
          'results': [
            {
              'title': 'Example',
              'url': 'https://example.com/a',
              'content': 'hello world',
            },
          ],
        }),
        200,
      );
    });

    final result =
        jsonDecode(
              await SearchToolService.executeSearch(
                'cuplivo',
                settings,
                searchClient: client,
              ),
            )
            as Map<String, dynamic>;

    expect(requests, 1);
    expect((result['items'] as List).length, 1);

    final key = settings.searchServices.single.apiKeys.single;
    expect(key.status, ApiKeyStatus.active);
    expect(key.lastError, isNull);
  });
}
