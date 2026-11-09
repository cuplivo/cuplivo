import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/models/provider_group.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

import '../../support/business_preferences_test_harness.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

/// The persisted key the retired built-in provider is stored under. It is a
/// storage key, not a brand string: the repair matches on it.
const _retiredKey = 'KelivoIN';

Future<void> _seedProviderConfigs(
  BusinessPreferencesTestSession session,
  Map<String, ProviderConfig> configs,
) => session.preferences.setString(
  'provider_configs_v1',
  jsonEncode({for (final e in configs.entries) e.key: e.value.toJson()}),
);

ProviderConfig _configFor(String key, {required String baseUrl}) =>
    ProviderConfig.defaultsFor(key).copyWith(baseUrl: baseUrl);

Future<String> _persistedProviderKeys(
  BusinessPreferencesTestHarness harness,
) async {
  final reopened = await harness.open();
  final raw = reopened.preferences.getString('provider_configs_v1') ?? '{}';
  return (jsonDecode(raw) as Map<String, dynamic>).keys.join(',');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late BusinessPreferencesTestHarness harness;
  late BusinessPreferencesTestSession session;
  final services = <ChatService>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'cuplivo_kelivoin_removal_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    harness = await BusinessPreferencesTestHarness.create();
    session = await harness.open();
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    await Hive.close();
    await harness.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ChatService createService() {
    final service = ChatService();
    services.add(service);
    return service;
  }

  Future<AssistantProvider> createAssistants({
    required ChatService chatService,
    required List<Map<String, Object?>> assistants,
  }) async {
    await session.preferences.setString(
      'assistants_v1',
      jsonEncode(assistants),
    );
    await session.preferences.setString(
      'current_assistant_id_v1',
      assistants.first['id']! as String,
    );
    final provider = AssistantProvider(
      preferences: session.preferences,
      chatService: chatService,
    );
    for (var i = 0; i < 25; i++) {
      if (provider.assistants.length == assistants.length) return provider;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return provider;
  }

  test('a fresh install has no built-in KelivoIN provider', () async {
    SharedPreferences.setMockInitialValues({'flutter_log_enabled_v1': false});

    final settings = SettingsProvider(session.preferences);
    await settings.loaded;

    expect(settings.providerConfigs.containsKey(_retiredKey), isFalse);
    expect(SettingsProvider.isBuiltInProvider(_retiredKey), isFalse);
    // Not a built-in identity means not a built-in prefill either: a provider
    // that still lands with four free models would be the same service back.
    final defaults = ProviderConfig.defaultsFor(_retiredKey);
    expect(defaults.models, isEmpty);
    expect(defaults.modelOverrides, isEmpty);
    expect(defaults.enabled, isFalse);
    expect(defaults.baseUrl, isNot('https://api.cuplivoas.top/v1'));
    expect(await _persistedProviderKeys(harness), isNot(contains(_retiredKey)));
  });

  test(
    'a config on the retired free backend leaves with every selection',
    () async {
      SharedPreferences.setMockInitialValues({'flutter_log_enabled_v1': false});
      final chatService = createService();
      await chatService.init();
      final assistants = await createAssistants(
        chatService: chatService,
        assistants: const [
          {
            'id': 'assistant-retired',
            'name': 'Retired model',
            'chatModelProvider': _retiredKey,
            'chatModelId': 'mistral',
          },
          {
            'id': 'assistant-kept',
            'name': 'Kept model',
            'chatModelProvider': 'OpenAI',
            'chatModelId': 'gpt-4o',
          },
        ],
      );
      final retiredChat = await chatService.createConversation(
        title: 'Retired',
      );
      await chatService.setConversationModel(
        retiredChat.id,
        providerKey: _retiredKey,
        modelId: 'qwen-coder',
      );
      final keptChat = await chatService.createConversation(title: 'Kept');
      await chatService.setConversationModel(
        keptChat.id,
        providerKey: 'OpenAI',
        modelId: 'gpt-4o',
      );

      await _seedProviderConfigs(session, {
        _retiredKey: _configFor(
          _retiredKey,
          baseUrl: 'https://text.pollinations.ai/openai',
        ).copyWith(apiKey: 'cuplivo', models: const ['mistral', 'qwen-coder']),
      });

      final retiredCalls = <String>[];
      final settings = SettingsProvider(
        session.preferences,
        onProviderModelsRetired: (key) {
          retiredCalls.add(key);
          return assistants.clearModelSelectionsForProvider(key);
        },
      );
      await settings.loaded;

      expect(retiredCalls, [_retiredKey]);
      expect(settings.providerConfigs.containsKey(_retiredKey), isFalse);
      expect(
        assistants.getById('assistant-retired')!.chatModelProvider,
        isNull,
      );
      expect(assistants.getById('assistant-retired')!.chatModelId, isNull);
      expect(assistants.getById('assistant-kept')!.chatModelId, 'gpt-4o');
      expect(chatService.getConversation(retiredChat.id)!.chatModelId, isNull);
      expect(chatService.getConversation(keptChat.id)!.chatModelId, 'gpt-4o');
      expect(
        await _persistedProviderKeys(harness),
        isNot(contains(_retiredKey)),
      );

      final reloadedAssistants = AssistantProvider(
        preferences: (await harness.open()).preferences,
      );
      await reloadedAssistants.loaded;
      expect(
        reloadedAssistants.getById('assistant-retired')!.chatModelId,
        isNull,
      );
      final reloadedChat = createService();
      await reloadedChat.init();
      expect(reloadedChat.getConversation(retiredChat.id)!.chatModelId, isNull);
    },
  );

  test(
    'a config on the dead host this fork wrote also leaves the order',
    () async {
      SharedPreferences.setMockInitialValues({'flutter_log_enabled_v1': false});
      await session.preferences.setStringList('providers_order_v1', [
        _retiredKey,
        'OpenAI',
        'Tensdaq',
      ]);
      await session.preferences.setString(
        'provider_groups_v1',
        ProviderGroup.encodeList([
          const ProviderGroup(id: 'g1', name: 'Free', createdAt: 1),
        ]),
      );
      await session.preferences.setString(
        'provider_group_map_v1',
        jsonEncode({_retiredKey: 'g1'}),
      );
      await _seedProviderConfigs(session, {
        _retiredKey: _configFor(
          _retiredKey,
          baseUrl: 'https://api.cuplivoas.top/v1',
        ).copyWith(models: const ['Qwen/Qwen3-8B', 'auto']),
      });

      final retiredCalls = <String>[];
      final settings = SettingsProvider(
        session.preferences,
        onProviderModelsRetired: (key) async => retiredCalls.add(key),
      );
      await settings.loaded;

      expect(retiredCalls, [_retiredKey]);
      expect(settings.providerConfigs.containsKey(_retiredKey), isFalse);
      expect(settings.providersOrder, isNot(contains(_retiredKey)));
      expect(settings.groupIdForProvider(_retiredKey), isNull);
      expect(
        await _persistedProviderKeys(harness),
        isNot(contains(_retiredKey)),
      );
      // The group itself is the user's and stays.
      final reopened = await harness.open();
      expect(
        ProviderGroup.decodeList(
          reopened.preferences.getString('provider_groups_v1') ?? '',
        ),
        hasLength(1),
      );
    },
  );

  test("a config on upstream's own host stays as an ordinary provider", () async {
    SharedPreferences.setMockInitialValues({'flutter_log_enabled_v1': false});
    final kept = _configFor(
      _retiredKey,
      baseUrl: 'https://api.psycheas.top/v1',
    ).copyWith(apiKey: 'user-key', models: const ['qwen-max'], enabled: true);
    await _seedProviderConfigs(session, {_retiredKey: kept});

    final retiredCalls = <String>[];
    final settings = SettingsProvider(
      session.preferences,
      onProviderModelsRetired: (key) async => retiredCalls.add(key),
    );
    await settings.loaded;

    expect(retiredCalls, isEmpty);
    final config = settings.getProviderConfig(_retiredKey);
    expect(config.baseUrl, 'https://api.psycheas.top/v1');
    expect(config.apiKey, 'user-key');
    expect(config.models, ['qwen-max']);
    expect(config.enabled, isTrue);
    // Ordinary, so the detail page offers delete and the base URL stays editable.
    expect(SettingsProvider.isBuiltInProvider(_retiredKey), isFalse);
    expect(await _persistedProviderKeys(harness), contains(_retiredKey));
  });

  test(
    'a recorded list position survives the provider becoming dynamic',
    () async {
      SharedPreferences.setMockInitialValues({'flutter_log_enabled_v1': false});
      await _seedProviderConfigs(session, {
        _retiredKey: _configFor(
          _retiredKey,
          baseUrl: 'https://api.psycheas.top/v1',
        ).copyWith(apiKey: 'user-key'),
      });
      await session.preferences.setStringList('providers_order_v1', [
        'OpenAI',
        _retiredKey,
        'Tensdaq',
      ]);

      final settings = SettingsProvider(session.preferences);
      await settings.loaded;

      // Being dynamic is not a reordering: the saved order wins.
      expect(settings.providersOrder.indexOf(_retiredKey), 1);
    },
  );

  test('the v4.5.0 OpenAI shell is kept and is no longer built-in', () async {
    SharedPreferences.setMockInitialValues({'flutter_log_enabled_v1': false});
    await _seedProviderConfigs(session, {
      _retiredKey: _configFor(
        _retiredKey,
        baseUrl: 'https://api.openai.com/v1',
      ),
    });

    final settings = SettingsProvider(session.preferences);
    await settings.loaded;

    final config = settings.getProviderConfig(_retiredKey);
    expect(config.baseUrl, 'https://api.openai.com/v1');
    expect(config.models, isEmpty);
    expect(SettingsProvider.isBuiltInProvider(_retiredKey), isFalse);
    expect(await _persistedProviderKeys(harness), contains(_retiredKey));
  });
}
