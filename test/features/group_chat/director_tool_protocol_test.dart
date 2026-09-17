import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/group_chat/services/director_tool_protocol.dart';

void main() {
  group('DirectorTools.definitions', () {
    test('exposes select_speaker with the roster enum and required id', () {
      final defs = DirectorTools.definitions(['a1', 'a2']);

      expect(defs, hasLength(2));
      final speak = defs.first['function'] as Map<String, dynamic>;
      expect(speak['name'], DirectorTools.selectSpeaker);
      final params = speak['parameters'] as Map<String, dynamic>;
      expect(params['required'], ['assistant_id']);
      final props = params['properties'] as Map<String, dynamic>;
      expect((props['assistant_id'] as Map)['enum'], ['a1', 'a2']);
      expect(props.containsKey('reason'), isTrue);
    });

    test(
      'empty roster falls back to a sentinel enum so the schema stays valid',
      () {
        final defs = DirectorTools.definitions(const []);
        final speak = defs.first['function'] as Map<String, dynamic>;
        final props =
            (speak['parameters'] as Map<String, dynamic>)['properties']
                as Map<String, dynamic>;
        expect((props['assistant_id'] as Map)['enum'], ['__none__']);
      },
    );

    test('end_turn takes an optional reason only', () {
      final defs = DirectorTools.definitions(['a1']);
      final end = defs.last['function'] as Map<String, dynamic>;
      expect(end['name'], DirectorTools.endTurn);
      final params = end['parameters'] as Map<String, dynamic>;
      expect(params.containsKey('required'), isFalse);
      final props = params['properties'] as Map<String, dynamic>;
      expect(props.keys, ['reason']);
    });

    test('survives a JSON round trip unchanged', () {
      final defs = DirectorTools.definitions(['a1', 'a2']);
      final decoded = jsonDecode(jsonEncode(defs));
      expect(decoded, defs);
    });
  });

  group('DirectorDecision', () {
    test('speak carries the assistant id and reason', () {
      const decision = DirectorDecision(
        kind: DirectorDecisionKind.selectSpeaker,
        assistantId: 'a1',
        reason: 'coding task',
      );
      expect(decision.kind, DirectorDecisionKind.selectSpeaker);
      expect(decision.assistantId, 'a1');
      expect(decision.fallback, isFalse);
    });

    test('factory helpers build each kind', () {
      final speak = DirectorDecision.speak('a2', reason: 'r');
      expect(speak.kind, DirectorDecisionKind.selectSpeaker);
      expect(speak.assistantId, 'a2');
      expect(speak.reason, 'r');

      final end = DirectorDecision.end(reason: 'done', fallback: true);
      expect(end.kind, DirectorDecisionKind.endTurn);
      expect(end.assistantId, isNull);
      expect(end.fallback, isTrue);
    });
  });
}
