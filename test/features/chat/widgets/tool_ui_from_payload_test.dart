import 'dart:convert';

import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'empty tool id falls back to name plus ordinal so the card still renders',
    () {
      final parsed = toolUiFromPayload(
        jsonEncode(<String, dynamic>{
          'id': '',
          'name': 'lookup',
          'arguments': <String, dynamic>{'q': 'kelivo'},
        }),
        fallbackOrdinal: 2,
      );

      expect(parsed, isNotNull);
      expect(parsed!.id, 'lookup-2');
      expect(parsed.toolName, 'lookup');
      expect(parsed.arguments, <String, dynamic>{'q': 'kelivo'});
      expect(parsed.loading, isTrue);
    },
  );

  test('empty tool id and name still synthesize a renderable id', () {
    final parsed = toolUiFromPayload(
      jsonEncode(<String, dynamic>{'id': '', 'name': ''}),
    );

    expect(parsed, isNotNull);
    expect(parsed!.id, 'tool-0');
    expect(parsed.toolName, isEmpty);
  });
}
