/// Director tool names and OpenAI-shaped function definitions.
class DirectorTools {
  DirectorTools._();

  static const selectSpeaker = 'select_speaker';
  static const endTurn = 'end_turn';

  static List<Map<String, dynamic>> definitions(List<String> assistantIds) {
    final enumIds = assistantIds.isEmpty
        ? <String>['__none__']
        : List<String>.from(assistantIds);
    return [
      {
        'type': 'function',
        'function': {
          'name': selectSpeaker,
          'description': 'Choose exactly one roster assistant to speak next.',
          'parameters': {
            'type': 'object',
            'properties': {
              'assistant_id': {
                'type': 'string',
                'enum': enumIds,
                'description': 'Roster id',
              },
              'reason': {
                'type': 'string',
                'description': 'Brief internal rationale (not shown to user)',
              },
            },
            'required': ['assistant_id'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': endTurn,
          'description':
              'End this speaking round; wait for the next human message.',
          'parameters': {
            'type': 'object',
            'properties': {
              'reason': {'type': 'string', 'description': 'Optional rationale'},
            },
          },
        },
      },
    ];
  }
}

enum DirectorDecisionKind { selectSpeaker, endTurn }

class DirectorDecision {
  const DirectorDecision({
    required this.kind,
    this.assistantId,
    this.reason,
    this.fallback = false,
  });

  final DirectorDecisionKind kind;
  final String? assistantId;
  final String? reason;
  final bool fallback;

  factory DirectorDecision.end({String? reason, bool fallback = false}) =>
      DirectorDecision(
        kind: DirectorDecisionKind.endTurn,
        reason: reason,
        fallback: fallback,
      );

  factory DirectorDecision.speak(String assistantId, {String? reason}) =>
      DirectorDecision(
        kind: DirectorDecisionKind.selectSpeaker,
        assistantId: assistantId,
        reason: reason,
      );
}
