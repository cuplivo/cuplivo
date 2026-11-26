/// Tool names and OpenAI-shaped function definitions for the proactive care
/// ("Ta的来信") decision flow. Mirrors DirectorTools (group chat).
class ProactiveCareDecisionTools {
  ProactiveCareDecisionTools._();

  static const updateTime = 'update_care_time';
  static const keepTime = 'keep_care_time';

  static List<Map<String, dynamic>> definitions() {
    return [
      {
        'type': 'function',
        'function': {
          'name': updateTime,
          'description':
              'Change the next proactive care message time to a new time.',
          'parameters': {
            'type': 'object',
            'properties': {
              'next_care_time': {
                'type': 'string',
                'description':
                    'ISO 8601 local time, e.g. 2026-08-04T09:30:00. '
                    'Must be later than the current system time.',
              },
            },
            'required': ['next_care_time'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': keepTime,
          'description':
              'Keep the currently scheduled next care time unchanged.',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
    ];
  }

  /// Validates update_care_time args with the exact semantics of the removed
  /// JSON decision parser: ISO-8601 parse, UTC→local, strictly after [now].
  /// Any invalid/missing/past input → null (= keep current time).
  static DateTime? parseUpdateTimeArgs(
    Map<String, dynamic> args, {
    required DateTime now,
  }) {
    final raw = args['next_care_time'];
    if (raw is! String || raw.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed == null) return null;
    final local = parsed.isUtc ? parsed.toLocal() : parsed;
    if (!local.isAfter(now)) return null;
    return local;
  }

  /// Lenient tool-name matching, mirrors DirectorRunner._parseTool.
  static String _normalize(String name) =>
      name.trim().toLowerCase().replaceAll('-', '_');

  static bool isUpdateTime(String name) {
    final n = _normalize(name);
    return n == updateTime || n.endsWith(updateTime);
  }

  static bool isKeepTime(String name) {
    final n = _normalize(name);
    return n == keepTime || n.endsWith(keepTime);
  }
}
