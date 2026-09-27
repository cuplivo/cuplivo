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

    test('clamps configured values to the supported range', () {
      expect(
        Assistant(
          id: 'low',
          name: 'Low',
          proactiveCareDecisionHistoryMessageLimit: 0,
        ).proactiveCareDecisionHistoryMessageLimit,
        Assistant.minContextMessageSize,
      );
      expect(
        Assistant(
          id: 'high',
          name: 'High',
          proactiveCareDecisionHistoryMessageLimit: 2048,
        ).proactiveCareDecisionHistoryMessageLimit,
        Assistant.maxContextMessageSize,
      );
    });
  });
}
