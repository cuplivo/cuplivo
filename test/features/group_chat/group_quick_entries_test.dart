import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/model_spec.dart';
import 'package:Cuplivo/core/models/reasoning_request.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/group_chat/models/group_quick_entries.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/business_test_harness.dart';

/// The composer's two composed entries report the roster, not one assistant:
/// a group sends each reply with its speaker's own model and its own record, so
/// "the group searches" is only true when every member agrees — everything else
/// is the neutral, lit state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BusinessPreferences preferences;
  late SettingsProvider settings;

  setUp(() {
    preferences = createBusinessTestPreferences();
    settings = SettingsProvider(preferences);
  });

  Assistant member(
    String id, {
    bool search = false,
    ReasoningRequest? reasoning,
    String model = 'gpt-4o',
  }) {
    return Assistant(
      id: id,
      name: id,
      chatModelProvider: 'openai',
      chatModelId: model,
      searchEnabled: search,
      reasoning: reasoning,
    );
  }

  bool supportsReasoning(String providerKey, String modelId) => true;
  bool noReasoning(String providerKey, String modelId) => false;

  group('search entry', () {
    test('members that agree on the external switch are uniform', () {
      final entry = resolveGroupSearch(
        settings: settings,
        members: [member('a', search: true), member('b', search: true)],
      );

      expect(entry.anyOn, isTrue);
      expect(entry.uniform, isTrue);
      expect(entry.builtIn, isFalse);
    });

    test('one member searching is lit but not uniform', () {
      final entry = resolveGroupSearch(
        settings: settings,
        members: [member('a', search: true), member('b')],
      );

      expect(entry.anyOn, isTrue);
      expect(entry.uniform, isFalse);
      expect(entry.builtIn, isFalse);
      expect(entry.serviceName, isNull);
    });

    test('nobody searching agrees on nothing, and is not lit', () {
      final entry = resolveGroupSearch(
        settings: settings,
        members: [member('a'), member('b')],
      );

      // Unanimous, but unanimously off: the entry is grey rather than lit, and
      // it carries no service name to display.
      expect(entry.anyOn, isFalse);
      expect(entry.uniform, isTrue);
      expect(entry.serviceName, isNull);
    });

    test('a member without a model cannot search', () {
      final entry = resolveGroupSearch(
        settings: settings,
        members: [
          const Assistant(id: 'x', name: 'x'),
          const Assistant(id: 'y', name: 'y'),
        ],
      );

      expect(entry.anyOn, isFalse);
    });
  });

  group('tools entry', () {
    const withLocalTools = Assistant(
      id: 'a',
      name: 'a',
      chatModelProvider: 'openai',
      chatModelId: 'gpt-4o',
      localToolIds: ['current_time'],
    );
    const withMcp = Assistant(
      id: 'b',
      name: 'b',
      chatModelProvider: 'openai',
      chatModelId: 'gpt-4o',
      mcpServerIds: ['srv'],
    );
    bool allModelsCallTools(String providerKey, String modelId) => true;
    bool noModelCallsTools(String providerKey, String modelId) => false;

    test('a bound workspace does not light it for models that cannot use it', () {
      final active = resolveGroupToolsActive(
        settings: settings,
        members: [withLocalTools, withMcp],
        workspaceBound: true,
        supportsTools: noModelCallsTools,
        connectedServerIds: const ['srv'],
      );

      // The capability gate comes first: a workspace, a local tool switch and an
      // MCP selection are three ways of *having* tools.
      expect(active, isFalse);
    });

    test('a bound workspace lights it once a model can call tools', () {
      final active = resolveGroupToolsActive(
        settings: settings,
        members: [withLocalTools],
        workspaceBound: true,
        supportsTools: allModelsCallTools,
        connectedServerIds: const <String>[],
      );

      expect(active, isTrue);
    });

    test('local tools and a connected MCP server light it on their own', () {
      expect(
        resolveGroupToolsActive(
          settings: settings,
          members: [withLocalTools],
          workspaceBound: false,
          supportsTools: allModelsCallTools,
          connectedServerIds: const <String>[],
        ),
        isTrue,
      );
      expect(
        resolveGroupToolsActive(
          settings: settings,
          members: [withMcp],
          workspaceBound: false,
          supportsTools: allModelsCallTools,
          connectedServerIds: const ['srv'],
        ),
        isTrue,
      );
      // A server that is not connected is not a tool the member can offer.
      expect(
        resolveGroupToolsActive(
          settings: settings,
          members: [withMcp],
          workspaceBound: false,
          supportsTools: allModelsCallTools,
          connectedServerIds: const <String>[],
        ),
        isFalse,
      );
    });

    test('a roster with nothing to offer is not lit', () {
      expect(
        resolveGroupToolsActive(
          settings: settings,
          members: const [
            Assistant(id: 'x', name: 'x'),
            Assistant(id: 'y', name: 'y'),
          ],
          workspaceBound: false,
          supportsTools: allModelsCallTools,
          connectedServerIds: const ['srv'],
        ),
        isFalse,
      );
    });
  });

  group('reasoning entry', () {
    test('members on the same level are uniform', () {
      final entry = resolveGroupReasoning(
        settings: settings,
        members: [
          member('a', reasoning: const ReasoningRequest(ReasoningLevel.low)),
          member('b', reasoning: const ReasoningRequest(ReasoningLevel.low)),
        ],
        supportsReasoning: supportsReasoning,
      );

      expect(entry.anySupported, isTrue);
      expect(entry.uniform, isTrue);
      expect(entry.request?.level, ReasoningLevel.low);
      expect(entry.anyActive, isTrue);
    });

    test('different levels are lit but carry no shared request', () {
      final entry = resolveGroupReasoning(
        settings: settings,
        members: [
          member('a', reasoning: const ReasoningRequest(ReasoningLevel.low)),
          member('b', reasoning: const ReasoningRequest(ReasoningLevel.high)),
        ],
        supportsReasoning: supportsReasoning,
      );

      expect(entry.uniform, isFalse);
      expect(entry.request, isNull);
      expect(entry.anyActive, isTrue);
    });

    test('everyone off is lit nowhere', () {
      final entry = resolveGroupReasoning(
        settings: settings,
        members: [
          member('a', reasoning: ReasoningRequest.off),
          member('b', reasoning: ReasoningRequest.off),
        ],
        supportsReasoning: supportsReasoning,
      );

      expect(entry.uniform, isTrue);
      expect(entry.anyActive, isFalse);
    });

    test('a roster whose models cannot reason hides the entry', () {
      final entry = resolveGroupReasoning(
        settings: settings,
        members: [member('a'), member('b')],
        supportsReasoning: noReasoning,
      );

      expect(entry.anySupported, isFalse);
      // A model that cannot reason still resolves to the spec default (`auto`),
      // which is not off — so the level alone would call this round active.
      expect(entry.anyActive, isFalse);
    });

    test('a capable member switched off does not make the round active', () {
      final entry = resolveGroupReasoning(
        settings: settings,
        members: [
          member('a', model: 'o3', reasoning: ReasoningRequest.off),
          // Cannot reason at all, so it carries the spec default rather than an
          // explicit off.
          member('b'),
        ],
        supportsReasoning: (_, modelId) => modelId == 'o3',
      );

      expect(entry.anySupported, isTrue);
      expect(entry.anyActive, isFalse);
    });
  });
}
