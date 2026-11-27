import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';

void main() {
  group('Assistant.description', () {
    test(
      'defaults to empty, so payloads written before the field read clean',
      () {
        final assistant = Assistant.fromJson({'id': 'a', 'name': 'A'});

        expect(assistant.description, isEmpty);
        expect(assistant.toJson()['description'], '');
      },
    );

    test('round-trips through JSON, including newlines', () {
      const described = Assistant(
        id: 'a',
        name: 'SQL 专家',
        description: '把需求写成 SQL\n并解释执行计划',
      );

      expect(
        Assistant.fromJson(described.toJson()).description,
        described.description,
      );

      final decoded = Assistant.decodeList(
        Assistant.encodeList(const [described]),
      ).single;
      expect(decoded.description, described.description);
    });

    test('copyWith edits it and leaves unrelated edits alone', () {
      const assistant = Assistant(id: 'a', name: 'A');
      final described = assistant.copyWith(description: 'write SQL');

      expect(described.description, 'write SQL');
      expect(described.copyWith(name: 'B').description, 'write SQL');
    });
  });

  group('Assistant.subagentTargetIds', () {
    test('defaults to none: a delegation offers no target at all', () {
      final assistant = Assistant.fromJson({'id': 'a', 'name': 'A'});

      expect(assistant.subagentTargetIds, isEmpty);
      expect(assistant.toJson()['subagentTargetIds'], isEmpty);
    });

    test('round-trips the selection', () {
      const chosen = Assistant(
        id: 'a',
        name: 'A',
        subagentTargetIds: <String>['b', 'c'],
      );

      expect(Assistant.fromJson(chosen.toJson()).subagentTargetIds, <String>[
        'b',
        'c',
      ]);
      // An explicit empty selection is still a selection, not a missing key.
      final none = chosen.copyWith(subagentTargetIds: const <String>[]);
      expect(Assistant.fromJson(none.toJson()).subagentTargetIds, isEmpty);
    });
  });
}
