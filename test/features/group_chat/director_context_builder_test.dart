import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/group_chat/services/director_context_builder.dart';

void main() {
  group('DirectorContextBuilder.plainTextForDirector', () {
    test('strips image markers to bare placeholder', () {
      expect(
        DirectorContextBuilder.plainTextForDirector(
          '看这张 [image:/data/a/b.png] 然后说',
        ),
        '看这张 [image] 然后说',
      );
    });

    test('strips file markers with pipe-separated metadata', () {
      expect(
        DirectorContextBuilder.plainTextForDirector(
          '附件 [file:/tmp/r.pdf|report.pdf|application/pdf] 已上传',
        ),
        '附件 [file] 已上传',
      );
    });

    test('strips multiple markers preserving surrounding text', () {
      expect(
        DirectorContextBuilder.plainTextForDirector(
          '[image:/x/1.jpg] 与 [image:/x/2.jpg]\n[file:/x/3.txt|a.txt|text/plain]',
        ),
        '[image] 与 [image]\n[file]',
      );
    });

    test('returns input unchanged when no markers', () {
      const raw = '普通消息 没有标记';
      expect(DirectorContextBuilder.plainTextForDirector(raw), raw);
    });

    test('handles empty and marker-only strings', () {
      expect(DirectorContextBuilder.plainTextForDirector(''), '');
      expect(
        DirectorContextBuilder.plainTextForDirector('[image:/a/b]'),
        '[image]',
      );
    });

    test('does not touch unrelated bracket content', () {
      const raw = '[User]: 提到 [image]/不是标记';
      expect(DirectorContextBuilder.plainTextForDirector(raw), raw);
    });
  });
}
