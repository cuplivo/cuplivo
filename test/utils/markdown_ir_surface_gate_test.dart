import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The IR's public surface only carries members something reads.
///
/// The refresh that added this file deleted `MdNode.block`, whose doc promised
/// the separator a selection gets between two blocks while `MdSelection.emit`
/// says separators are never synthesized, along with
/// `MdItem.contributesDisplay`, two write-only link offsets, the unread
/// `MdDocument.source` and `markdownEndsWithDisplayMath`, which had lost its
/// only production caller. None of them was reachable by `dart analyze`: the
/// analyzer never reports an unused *public* member, and `dependencies/` is
/// outside the analyzed roots, so a documented field with no reader survived a
/// green gate. This test asks the question from the other side: a field on one
/// of the IR's public classes has to be named somewhere outside the file that
/// declares it, and the list is frozen, so a new field has to bring its reader
/// with it.
void main() {
  const ir = 'dependencies/gpt_markdown/lib/markdown_ir.dart';

  // Every field on a public IR class, as `Class.field`. Private classes
  // (`_MdIndex`) and private fields stay internal.
  const frozen = {
    'MdRange.source',
    'MdRange.start',
    'MdRange.end',
    'MdNode.kind',
    'MdNode.range',
    'MdNode.display',
    'MdNode.children',
    'MdNode.open',
    'MdNode.close',
    'MdItem.node',
    'MdItem.ancestors',
    'MdItem.display',
    'MdItem.sourceText',
    'MdDocument.blocks',
    'MdSelection.document',
    'MdSelection.startOffset',
    'MdSelection.endOffset',
  };

  test('every public IR field is read outside its declaration', () {
    final declaration = File(ir).readAsStringSync();
    final fields = <String>{};
    final classes = RegExp(
      r'^final class (Md\w+) \{(.*?)^\}',
      multiLine: true,
      dotAll: true,
    ).allMatches(declaration);
    for (final match in classes) {
      final className = match.group(1)!;
      for (final field in RegExp(
        r'^  final [A-Za-z<>?, ]+ ([a-zA-Z][A-Za-z0-9]*);$',
        multiLine: true,
      ).allMatches(match.group(2)!).map((field) => field.group(1)!)) {
        fields.add('$className.$field');
      }
    }
    expect(
      fields,
      frozen,
      reason: 'the public IR surface changed; add the field with its reader',
    );

    final readers = <String, int>{};
    for (final entity in Directory('.').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path == ir || path.contains('/.dart_tool/')) continue;
      final text = entity.readAsStringSync();
      for (final field in fields) {
        final name = field.split('.').last;
        if (RegExp('\\b$name\\b').hasMatch(text)) {
          readers[field] = (readers[field] ?? 0) + 1;
        }
      }
    }
    for (final field in fields) {
      expect(
        readers[field] ?? 0,
        greaterThan(0),
        reason: '$field is declared but nothing reads it',
      );
    }
  });
}
