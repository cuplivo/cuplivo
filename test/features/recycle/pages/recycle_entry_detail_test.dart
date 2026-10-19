import 'dart:convert';

import 'package:Cuplivo/features/recycle/pages/recycle_entry_detail_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two decisions the detail page makes on its own, without a widget tree:
/// how much of a body it draws, and when a staged conversation's assistant is
/// worth warning about.
void main() {
  group('capRecyclePreview', () {
    test('text inside the budget is handed back untouched', () {
      const text = 'a short body';
      expect(capRecyclePreview(text), text);
    });

    test('an ASCII body is cut at the byte budget', () {
      final text = 'x' * 5000;
      final capped = capRecyclePreview(text, capBytes: 1024);
      expect(utf8.encode(capped), hasLength(1024));
    });

    test('a CJK body is cut on a character boundary, not mid-rune', () {
      // Three bytes per ideograph, so a naive byte cut lands inside one.
      final text = '回' * 1000;
      final capped = capRecyclePreview(text, capBytes: 1000);
      expect(utf8.encode(capped).length, 999);
      // Decoding must not produce a replacement character: that is what a
      // half-cut rune would have drawn as.
      expect(utf8.decode(utf8.encode(capped)), capped);
      expect(capped.contains('\uFFFD'), isFalse);
      expect(capped.length, 333);
    });

    test('a four-byte rune is not split either', () {
      final text = '😀' * 400;
      final capped = capRecyclePreview(text, capBytes: 1001);
      expect(utf8.decode(utf8.encode(capped)), capped);
      expect(utf8.encode(capped).length, lessThanOrEqualTo(1001));
    });
  });

  group('orphanAssistantName', () {
    Map<String, List<Map<String, Object?>>> conversationWith(
      Object? assistantId,
    ) => {
      'conversation_rows': [
        {'id': 'c1', 'assistant_id': assistantId},
      ],
    };

    test('an assistant that still exists says nothing', () {
      expect(
        orphanAssistantName(
          tables: conversationWith('a1'),
          exists: (id) => id == 'a1',
        ),
        isNull,
      );
    });

    test('an assistant that is gone is named from the group label', () {
      expect(
        orphanAssistantName(
          tables: conversationWith('a1'),
          exists: (id) => false,
          fallbackName: 'Delete Me',
        ),
        'Delete Me',
      );
    });

    test('without a surviving name the id is what there is', () {
      expect(
        orphanAssistantName(
          tables: conversationWith('a1'),
          exists: (id) => false,
        ),
        'a1',
      );
    });

    test('an unbound or unreadable conversation has nothing to warn about', () {
      expect(
        orphanAssistantName(
          tables: conversationWith(null),
          exists: (id) => false,
        ),
        isNull,
      );
      expect(orphanAssistantName(tables: null, exists: (id) => false), isNull);
      expect(
        orphanAssistantName(
          tables: const <String, List<Map<String, Object?>>>{},
          exists: (id) => false,
        ),
        isNull,
      );
    });
  });
}
