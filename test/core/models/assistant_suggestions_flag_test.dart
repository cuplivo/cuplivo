import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';

void main() {
  group('Assistant.suggestionsEnabled', () {
    test(
      'defaults to true so payloads written before the field keep it on',
      () {
        final assistant = Assistant.fromJson({'id': 'a', 'name': 'A'});

        expect(assistant.suggestionsEnabled, isTrue);
        expect(assistant.toJson()['suggestionsEnabled'], isTrue);
      },
    );

    test('round-trips through JSON and the encoded assistant list', () {
      const off = Assistant(id: 'a', name: 'A', suggestionsEnabled: false);

      expect(off.toJson()['suggestionsEnabled'], isFalse);
      expect(Assistant.fromJson(off.toJson()).suggestionsEnabled, isFalse);

      final decoded = Assistant.decodeList(
        Assistant.encodeList(const [off]),
      ).single;
      expect(decoded.suggestionsEnabled, isFalse);
    });

    test('copyWith can turn it off and back on', () {
      const assistant = Assistant(id: 'a', name: 'A');
      final off = assistant.copyWith(suggestionsEnabled: false);

      expect(off.suggestionsEnabled, isFalse);
      expect(off.copyWith(suggestionsEnabled: true).suggestionsEnabled, isTrue);
      // Unrelated edits keep the value.
      expect(off.copyWith(name: 'B').suggestionsEnabled, isFalse);
    });
  });
}
