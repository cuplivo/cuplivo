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
    });
  });
}
