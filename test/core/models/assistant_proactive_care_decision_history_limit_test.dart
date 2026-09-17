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
      // WT keeps the constructor const, so normalization converges at the
      // write paths (copyWith/fromJson); both clamp identically.
      expect(
        Assistant(id: 'low', name: 'Low')
            .copyWith(proactiveCareDecisionHistoryMessageLimit: 0)
            .proactiveCareDecisionHistoryMessageLimit,
        Assistant.minContextMessageSize,
      );
      expect(
        Assistant(id: 'high', name: 'High')
            .copyWith(proactiveCareDecisionHistoryMessageLimit: 8192)
            .proactiveCareDecisionHistoryMessageLimit,
        Assistant.maxContextMessageSize,
      );
      expect(
        Assistant.fromJson(const {
          'id': 'json',
          'name': 'Json',
          'proactiveCareDecisionHistoryMessageLimit': 8192,
        }).proactiveCareDecisionHistoryMessageLimit,
        Assistant.maxContextMessageSize,
      );
    });
  });
}
