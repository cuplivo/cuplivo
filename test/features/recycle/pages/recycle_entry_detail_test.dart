import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/features/recycle/pages/recycle_entry_detail_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// The decisions the detail page makes on its own, without a widget tree: how
/// much of a body it reads, how much it draws, and when a staged conversation's
/// assistant is worth warning about.
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

  group('readBodyHead', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('kelivo_bin_head_');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    Future<File> write(String name, List<int> bytes) async {
      final file = File('${directory.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      return file;
    }

    test('a small text body comes back whole and is not marked cut', () async {
      final file = await write('small.txt', utf8.encode('a short body'));

      final head = await readBodyHead(file);

      expect(head.text, 'a short body');
      expect(head.truncated, isFalse);
    });

    test('a large body is read only up to the cap', () async {
      // The point of the range read: 4 MB on disk, one capped string in memory.
      final file = await write(
        'big.txt',
        List<int>.filled(4 * 1024 * 1024, 0x61),
      );

      final head = await readBodyHead(file, capBytes: 1024);

      expect(utf8.encode(head.text!).length, lessThanOrEqualTo(1024));
      expect(head.truncated, isTrue);
    });

    test('a tail cut mid-rune does not turn text into a binary body', () async {
      // Three bytes per ideograph, so a 1001-byte head ends inside one.
      final file = await write('cjk.txt', utf8.encode('回' * 2000));

      final head = await readBodyHead(file, capBytes: 1001);

      expect(head.text, isNotNull);
      expect(head.text, isNot(contains('\uFFFD')));
      expect(utf8.decode(utf8.encode(head.text!)), head.text);
      expect(head.truncated, isTrue);
    });

    test('only the head is decoded, not the whole body', () async {
      // A text head over a tail that is not UTF-8 at all. Reading (and decoding)
      // the whole file would report a binary body; reading the head keeps the
      // text, which is what this page is for.
      final file = await write('mixed.txt', [
        ...List<int>.filled(1024, 0x61),
        ...List<int>.filled(64 * 1024, 0xff),
      ]);

      final head = await readBodyHead(file, capBytes: 1024);

      expect(head.text, 'a' * 1024);
      expect(head.truncated, isTrue);
    });

    test('bytes that are not text are reported as such', () async {
      final file = await write('blob.bin', const [0x00, 0xff, 0x10, 0x00]);

      final head = await readBodyHead(file);

      expect(head.text, isNull);
    });
  });

  group('encodeTablesHead', () {
    test('a body inside the budget is the JSON the encoder writes', () {
      final tables = {
        'preference_rows': [
          {'key': 'user_name', 'value': '"Me"'},
        ],
      };

      final head = encodeTablesHead(tables);

      expect(head.preview, const JsonEncoder.withIndent('  ').convert(tables));
      expect(head.truncated, isFalse);
    });

    test('a body over the budget is cut while it is encoded', () {
      final tables = {
        'message_rows': [
          for (var index = 0; index < 2000; index++)
            {'id': 'm$index', 'content': 'x' * 200},
        ],
      };

      final head = encodeTablesHead(tables, capBytes: 1024);

      expect(utf8.encode(head.preview).length, lessThanOrEqualTo(1024));
      expect(head.truncated, isTrue);
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
