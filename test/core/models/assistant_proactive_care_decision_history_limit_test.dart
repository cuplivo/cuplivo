import 'package:Cuplivo/core/models/assistant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Assistant proactive-care decision history limit', () {
    test('defaults old assistants to unlimited', () {
      expect(
        Assistant(
          id: 'a1',
          name: 'Assistant',
        ).proactiveCareDecisionHistoryMessageLimit,
        isNull,
      );
      expect(
        Assistant.fromJson({
          'id': 'a1',
          'name': 'Assistant',
        }).proactiveCareDecisionHistoryMessageLimit,
        isNull,
      );
    });

    test('round-trips and can be explicitly cleared', () {
      final configured = Assistant(
        id: 'a1',
        name: 'Assistant',
        proactiveCareDecisionHistoryMessageLimit: 64,
      );

      expect(
        Assistant.fromJson(
          configured.toJson(),
        ).proactiveCareDecisionHistoryMessageLimit,
        64,
      );
      expect(
        configured
            .copyWith(clearProactiveCareDecisionHistoryMessageLimit: true)
            .proactiveCareDecisionHistoryMessageLimit,
        isNull,
      );
    });

    test('clamps configured values to the supported range on writes', () {
      // The const constructor passes through (same as contextMessageSize);
      // every write path (fromJson restore, copyWith UI edits) normalizes.
      final passthrough = Assistant(
        id: 'low',
        name: 'Low',
        proactiveCareDecisionHistoryMessageLimit: 0,
      );
      expect(passthrough.proactiveCareDecisionHistoryMessageLimit, 0);

      expect(
        Assistant.fromJson({
          ...passthrough.toJson(),
          'id': 'restored',
        }).proactiveCareDecisionHistoryMessageLimit,
        Assistant.minContextMessageSize,
      );
      expect(
        passthrough
            .copyWith(proactiveCareDecisionHistoryMessageLimit: 0)
            .proactiveCareDecisionHistoryMessageLimit,
        Assistant.minContextMessageSize,
      );
      expect(
        Assistant.fromJson({
          'id': 'high',
          'name': 'High',
          'proactiveCareDecisionHistoryMessageLimit': 9999,
        }).proactiveCareDecisionHistoryMessageLimit,
        Assistant.maxContextMessageSize,
      );
      expect(
        Assistant(
          id: 'high',
          name: 'High',
        ).copyWith(proactiveCareDecisionHistoryMessageLimit: 9999)
            .proactiveCareDecisionHistoryMessageLimit,
        Assistant.maxContextMessageSize,
      );
    });
  });
}
