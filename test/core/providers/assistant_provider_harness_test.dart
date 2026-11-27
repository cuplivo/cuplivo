import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';

import '../../support/business_test_harness.dart';

const _localA = Assistant(id: 'local-a', name: 'Local A');
const _localB = Assistant(id: 'local-b', name: 'Local B');

final _linkedHarness = Assistant.harness(
  id: 'harness',
  name: 'Remote harness',
  harnessUrl: 'http://127.0.0.1:9/ui/?token=launch',
);

Future<BusinessTestHarness> _seed({
  required List<Assistant> assistants,
  String? currentAssistantId,
}) => createBusinessTestHarness(
  initial: <String, Object?>{
    'assistants_v1': Assistant.encodeList(assistants),
    if (currentAssistantId != null)
      'current_assistant_id_v1': currentAssistantId,
  },
);

Future<AssistantProvider> _openProvider(BusinessTestHarness harness) async {
  final provider = AssistantProvider(preferences: harness.preferences);
  addTearDown(provider.dispose);
  await provider.loaded;
  return provider;
}

/// The bytes a provider would read on the next launch, not its in-memory list.
Future<List<Assistant>> _persistedAssistants(
  BusinessTestHarness harness,
) async {
  final preferences = BusinessPreferences(harness.repository);
  await preferences.load();
  final raw = preferences.getString('assistants_v1');
  return raw == null ? const <Assistant>[] : Assistant.decodeList(raw);
}

Future<void> _writeAssistants(
  BusinessTestHarness harness,
  List<Assistant> assistants,
) => harness.preferences.setString(
  'assistants_v1',
  Assistant.encodeList(assistants),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AssistantProvider DeepSeek Harness support', () {
    test(
      'addHarnessAssistant persists an unlinked harness and notifies',
      () async {
        final harness = await _seed(
          assistants: <Assistant>[_localA, _localB],
          currentAssistantId: 'local-a',
        );
        final provider = await _openProvider(harness);
        var notifications = 0;
        provider.addListener(() {
          notifications++;
        });

        final id = await provider.addHarnessAssistant(
          name: '  Remote harness  ',
        );

        expect(notifications, 1);
        final added = provider.getById(id)!;
        expect(added.kind, AssistantKind.deepSeekHarness);
        expect(added.isDeepSeekHarness, isTrue);
        expect(added.harnessUrl, isNull);
        expect(added.name, 'Remote harness');
        // Connecting one is a settings-page step; the chat owner does not move.
        expect(provider.currentAssistantId, 'local-a');

        final persisted = await _persistedAssistants(harness);
        expect(persisted, hasLength(3));
        final saved = persisted.firstWhere((assistant) => assistant.id == id);
        expect(saved.kind, AssistantKind.deepSeekHarness);
        expect(saved.harnessUrl, isNull);
      },
    );

    test('a harness is listed but never offered as a chat assistant', () async {
      final harness = await _seed(
        assistants: <Assistant>[_localA, _linkedHarness, _localB],
        currentAssistantId: 'local-b',
      );
      final provider = await _openProvider(harness);

      // The saved kind and link survive the JSON round-trip through _load.
      final restored = provider.getById('harness')!;
      expect(restored.kind, AssistantKind.deepSeekHarness);
      expect(restored.harnessUrl, _linkedHarness.harnessUrl);
      expect(provider.assistants.map((assistant) => assistant.id), <String>[
        'local-a',
        'harness',
        'local-b',
      ]);
      expect(provider.chatAssistants.map((assistant) => assistant.id), <String>[
        'local-a',
        'local-b',
      ]);
      expect(provider.currentAssistantId, 'local-b');
      expect(provider.currentAssistant!.isDeepSeekHarness, isFalse);
    });

    test(
      'selecting a harness does not take the chat owner away from the local assistant',
      () async {
        final harness = await _seed(
          assistants: <Assistant>[_localA, _linkedHarness, _localB],
          currentAssistantId: 'local-a',
        );
        final provider = await _openProvider(harness);
        var notifications = 0;
        provider.addListener(() {
          notifications++;
        });

        await provider.setCurrentAssistant('harness');

        expect(notifications, 0);
        expect(provider.currentAssistantId, 'local-a');
        expect(
          harness.preferences.getString('current_assistant_id_v1'),
          'local-a',
        );

        // A local id is still accepted, so the no-op is specific to harness rows.
        await provider.setCurrentAssistant('local-b');
        expect(provider.currentAssistantId, 'local-b');
      },
    );

    test(
      'a persisted current id naming a harness falls back to the first local assistant',
      () async {
        final harness = await _seed(
          assistants: <Assistant>[_linkedHarness, _localA, _localB],
          currentAssistantId: 'harness',
        );

        final provider = await _openProvider(harness);

        expect(provider.currentAssistantId, 'local-a');
        expect(provider.currentAssistant!.isDeepSeekHarness, isFalse);
        // The stored pointer is repaired, so the next launch does not repeat it.
        expect(
          harness.preferences.getString('current_assistant_id_v1'),
          'local-a',
        );
      },
    );

    test(
      'deleting the current local assistant falls back to another local, not the harness',
      () async {
        final harness = await _seed(
          assistants: <Assistant>[_localA, _linkedHarness, _localB],
          currentAssistantId: 'local-a',
        );
        final provider = await _openProvider(harness);

        expect(await provider.deleteAssistant('local-a'), isTrue);

        expect(provider.currentAssistantId, 'local-b');
        expect(provider.currentAssistant!.isDeepSeekHarness, isFalse);
        expect(
          harness.preferences.getString('current_assistant_id_v1'),
          'local-b',
        );
      },
    );

    test('a conversation naming a harness resolves to a local owner', () async {
      final harness = await _seed(
        assistants: <Assistant>[_localA, _linkedHarness, _localB],
        currentAssistantId: 'local-a',
      );
      final provider = await _openProvider(harness);

      // An imported/synced conversation may name the harness as its owner; it
      // still needs a local assistant to chat with.
      expect(provider.resolveConversationAssistant('harness')!.id, 'local-a');
      expect(provider.resolveConversationAssistant('local-b')!.id, 'local-b');
      expect(provider.resolveConversationAssistant(null)!.id, 'local-a');
    });

    test(
      'reloadAfterExternalChange restores a harness pointer and its link',
      () async {
        final harness = await _seed(
          assistants: <Assistant>[_localA, _localB],
          currentAssistantId: 'local-a',
        );
        final provider = await _openProvider(harness);

        await _writeAssistants(harness, <Assistant>[
          _localA,
          _localB,
          Assistant.harness(
            id: 'external',
            name: 'External harness',
            harnessUrl: 'http://127.0.0.1:9/ui/?token=one',
          ),
        ]);
        await provider.reloadAfterExternalChange();

        final restored = provider.getById('external')!;
        expect(restored.kind, AssistantKind.deepSeekHarness);
        expect(restored.harnessUrl, 'http://127.0.0.1:9/ui/?token=one');
        expect(provider.assistants, hasLength(3));
        expect(
          provider.chatAssistants.map((assistant) => assistant.id),
          <String>['local-a', 'local-b'],
        );
        expect(provider.currentAssistantId, 'local-a');

        // A peer could have selected the harness; the reload must not adopt it.
        await harness.preferences.setString(
          'current_assistant_id_v1',
          'external',
        );
        await provider.reloadAfterExternalChange();
        expect(provider.currentAssistantId, 'local-a');
        expect(
          harness.preferences.getString('current_assistant_id_v1'),
          'local-a',
        );

        // A rotated token replaces the link; a stale cached pointer would keep
        // probing the invalidated one.
        await _writeAssistants(harness, <Assistant>[
          _localA,
          _localB,
          Assistant.harness(
            id: 'external',
            name: 'External harness',
            harnessUrl: 'http://127.0.0.1:9/ui/?token=two',
          ),
        ]);
        await provider.reloadAfterExternalChange();
        expect(
          provider.getById('external')!.harnessUrl,
          'http://127.0.0.1:9/ui/?token=two',
        );
      },
    );
  });
}
