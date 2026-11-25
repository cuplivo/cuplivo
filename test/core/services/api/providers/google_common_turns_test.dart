import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/api/providers/google_common.dart';

void main() {
  test('a tool result followed by a step-boundary message is one user turn', () {
    final merged = mergeAdjacentGoogleTurns([
      {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {'name': 'read_file'},
          },
        ],
      },
      {
        'role': 'user',
        'parts': [
          {'text': 'use YAML'},
        ],
      },
      {
        'role': 'model',
        'parts': [
          {'text': 'ok'},
        ],
      },
    ]);

    // Gemini rejects non-alternating contents; the mail row would otherwise be
    // a second user turn right after the tool result.
    expect(merged, hasLength(2));
    expect(merged.first['role'], 'user');
    expect((merged.first['parts'] as List), hasLength(2));
    expect(merged.last['role'], 'model');
  });

  test('alternating turns are left alone and stay separate objects', () {
    final source = <Map<String, dynamic>>[
      {
        'role': 'user',
        'parts': [
          {'text': 'a'},
        ],
      },
      {
        'role': 'model',
        'parts': [
          {'text': 'b'},
        ],
      },
    ];
    final merged = mergeAdjacentGoogleTurns(source);
    expect(merged, hasLength(2));
    expect(identical(merged.first, source.first), isFalse);
    expect(source.first['parts'], hasLength(1));
  });

  test('three turns of one role collapse into one, in order', () {
    final merged = mergeAdjacentGoogleTurns([
      {
        'role': 'user',
        'parts': [
          {'text': '1'},
        ],
      },
      {
        'role': 'user',
        'parts': [
          {'text': '2'},
        ],
      },
      {
        'role': 'user',
        'parts': [
          {'text': '3'},
        ],
      },
    ]);
    expect(merged, hasLength(1));
    expect(
      (merged.single['parts'] as List).map((part) => (part as Map)['text']),
      <String>['1', '2', '3'],
    );
  });
}
