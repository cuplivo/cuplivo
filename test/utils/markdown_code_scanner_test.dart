import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/utils/markdown_code_scanner.dart';

void main() {
  group('markdownCodeFenceMark', () {
    test('runs of three or more backticks/tildes after indent', () {
      final bt = markdownCodeFenceMark('```dart');
      expect(bt, isNotNull);
      expect(bt!.length, 3);
      expect(bt.marker, MarkdownCodeFenceMarker.backtick);
      expect(bt.canClose, isFalse);
      final tilde = markdownCodeFenceMark('~~~~');
      expect(tilde!.length, 4);
      expect(tilde.marker, MarkdownCodeFenceMarker.tilde);
      expect(markdownCodeFenceMark('``'), isNull);
      expect(markdownCodeFenceMark('    ```  '), isNotNull);
      expect(markdownCodeFenceMark('prefix ```'), isNull);
    });

    test('canClose requires horizontal whitespace after the run', () {
      expect(markdownCodeFenceMark('```')!.canClose, isTrue);
      expect(markdownCodeFenceMark('```  ')!.canClose, isTrue);
      expect(markdownCodeFenceMark('``` not-a-closer')!.canClose, isFalse);
    });
  });

  group('markdownCodePairInline', () {
    test('pairs equal-run spans left to right', () {
      final pairs = markdownCodePairInline('use `code` and ``t`x`` after');
      expect(pairs, hasLength(2));
      expect(pairs[0].openStart, 4);
      expect(pairs[0].openLength, 1);
      expect(pairs[0].closeStart, 9);
      expect(pairs[1].openLength, 2);
      expect(pairs[1].closeLength, 2);
    });

    test('escaped opener does not open (escapeSensitive)', () {
      final pairs = markdownCodePairInline(r'use \`code` here');
      expect(pairs, isEmpty);
    });

    test('wider hiding rule pairs the escaped run too', () {
      final pairs = markdownCodePairInline(
        r'\`<details>`',
        escapeSensitive: false,
      );
      expect(pairs, hasLength(1));
    });

    test('two backslashes before a run make it a real opener', () {
      final pairs = markdownCodePairInline('use \\\\`code` now');
      expect(pairs, hasLength(1));
      expect(pairs.single.openStart, 6);
    });
  });

  group('markdownCodeSpanNormalize', () {
    test('peels one space when both ends are spaces', () {
      expect(markdownCodeSpanNormalize(' a '), 'a');
      expect(markdownCodeSpanNormalize('   '), '   ');
      expect(markdownCodeSpanNormalize('a b'), 'a b');
      expect(markdownCodeSpanNormalize('a\nb'), 'a b');
    });
  });

  group('markdownCodeInlineClosingFence', () {
    test('closes only when the line ends with a run after content', () {
      expect(markdownCodeInlineClosingFence('}```', 3), 1);
      expect(markdownCodeInlineClosingFence('}```  ', 3), 1);
      expect(markdownCodeInlineClosingFence('```', 3), isNull);
      expect(markdownCodeInlineClosingFence('}``', 3), isNull);
      expect(markdownCodeInlineClosingFence('}``` not-close', 3), isNull);
      expect(markdownCodeInlineClosingFence('a}}```', 3), 3);
    });
  });

  group('markdownCodeScan: inline spans', () {
    test('windows path with trailing backslash stays one span (#544)', () {
      final res = markdownCodeScan(': `D:\\ComfyUI\\` 为环境层（含');
      expect(res.segments, hasLength(1));
      final seg = res.segments.single;
      expect(seg.kind, MarkdownCodeSegmentKind.inlineCode);
      expect(seg.content, 'D:\\ComfyUI\\');
      expect(res.segments.single.start, 2);
      expect(seg.end - seg.start, '`D:\\ComfyUI\\`'.length);
    });

    test('swallowing gone: sentence fragment is not part of the span', () {
      final res = markdownCodeScan(
        ': `D:\\ComfyUI\\` 为环境层（含 `python_embedded`、',
      );
      expect(res.segments, hasLength(2));
      expect(res.segments[0].content, 'D:\\ComfyUI\\');
      expect(res.segments[1].content, 'python_embedded');
    });

    test('mismatched runs: lazy second span starts after escape', () {
      final res = markdownCodeScan('`a` and `` b ``');
      expect(res.segments, hasLength(2));
    });

    test('double-backtick delimiters with inner backtick', () {
      final res = markdownCodeScan('use `` `x` `` here');
      expect(res.segments, hasLength(1));
      expect(res.segments.single.content, '`x`');
      expect(res.segments.single.kind, MarkdownCodeSegmentKind.inlineCode);
    });

    test('three backticks delimit a span with double inner', () {
      final res = markdownCodeScan('use ``` ``x`` ``` now');
      expect(res.segments, hasLength(1));
      expect(res.segments.single.content, '``x``');
    });

    test('single-line only: run pairs never cross a line break', () {
      final res = markdownCodeScan('`a\nb`');
      expect(res.segments, isEmpty);
    });
  });

  group('markdownCodeScan: fences', () {
    test('plain fenced block with info string, content and closer', () {
      final res = markdownCodeScan('```dart\nvar x = 1;\nprint(x);\n```');
      expect(res.segments, hasLength(1));
      final seg = res.segments.single;
      expect(seg.kind, MarkdownCodeSegmentKind.codeBlock);
      expect(seg.identifier, 'dart');
      expect(seg.closed, isTrue);
      expect(seg.content, 'var x = 1;\nprint(x);');
    });

    test('info-string closer line does not close (#544 family)', () {
      final res = markdownCodeScan(
        '```dart\na\n``` not-a-closer\nfollowing\n```',
      );
      final seg = res.segments.single;
      expect(seg.closed, isTrue);
      expect(seg.content, 'a\n``` not-a-closer\nfollowing');
    });

    test('four-backtick opener is not closed by a three-run', () {
      final res = markdownCodeScan('````dart\na\n```\n\nb\n````');
      expect(res.segments, hasLength(1));
      expect(res.segments.single.closed, isTrue);
    });

    test('tilde fence closes on a longer same-marker run', () {
      final res = markdownCodeScan('~~~\na\n~~~~');
      expect(res.segments.single.closed, isTrue);
      expect(res.segments.single.marker, MarkdownCodeFenceMarker.tilde);
    });

    test('unclosed fence to EOF has closed=false', () {
      final res = markdownCodeScan('```dart\nvar a = 1;');
      expect(res.segments, hasLength(1));
      expect(res.segments.single.closed, isFalse);
      expect(res.segments.single.content, 'var a = 1;');
    });

    test('incomplete opener line at EOF is not a fence', () {
      final res = markdownCodeScan('```dart');
      expect(res.segments, isEmpty);
    });

    test('inline closing extension: }``` line closes the fence', () {
      final res = markdownCodeScan('```\na\n}```\n');
      expect(res.segments.single.closed, isTrue);
      expect(res.segments.single.content, 'a\n}');
    });

    test('inline closing never opens outside a fence', () {
      final res = markdownCodeScan('text }```\nmore');
      expect(res.segments, isEmpty);
    });

    test('indented full-line closer does not leak indent into content', () {
      final res = markdownCodeScan(
        '   ```powershell\n   Get-Content x\n   ```',
      );
      final seg = res.segments.single;
      expect(seg.kind, MarkdownCodeSegmentKind.codeBlock);
      expect(seg.closed, isTrue);
      expect(seg.content, '   Get-Content x');
    });

    test('blockquote fence: quote prefix and stripped content', () {
      final res = markdownCodeScan('> ```\n> code\n> ```\nafter');
      expect(res.segments, hasLength(1));
      final seg = res.segments.single;
      expect(seg.context, MarkdownCodeFenceContext.blockquote);
      expect(seg.contextPrefix, '> ');
      expect(seg.content, 'code');
      expect(seg.closed, isTrue);
    });

    test('list fence: info shape keeps no spaces', () {
      final res = markdownCodeScan('- ```yaml\npkgs:\n- deps\n```');
      expect(res.segments, hasLength(1));
      expect(res.segments.single.context, MarkdownCodeFenceContext.list);
      expect(res.segments.single.contextPrefix, '- ');
      expect(res.segments.single.identifier, 'yaml');
      expect(res.segments.single.content, 'pkgs:\n- deps');
    });

    test('list fence with a space in the info is not a list fence', () {
      final res = markdownCodeScan('- ```yaml with space\nx\n');
      expect(res.segments, isEmpty);
    });

    test('tilde list fence stays literal text', () {
      final res = markdownCodeScan('- ~~~\nx\n~~~');
      expect(res.segments, isEmpty);
    });
  });

  group('markdownCodeScan: mixed docs', () {
    test('garbling case from issue #544 end to end', () {
      const source =
          '包）：`D:\\ComfyUI\\` 为环境层（含 `python_embedded`、'
          '`run_nvidia_gpu.bat`），`D:\\ComfyUI\\ComfyUI\\` 为内容层（含 '
          '`models`、`custom_nodes`）。模型路径：`D:\\ComfyUI\\ComfyUI\\models\\...`，'
          '输出路径：`D:\\ComfyUI\\ComfyUI\\output`。';
      final res = markdownCodeScan(source);
      expect(res.segments.map((s) => s.content).toList(), [
        r'D:\ComfyUI\',
        'python_embedded',
        'run_nvidia_gpu.bat',
        r'D:\ComfyUI\ComfyUI\',
        'models',
        'custom_nodes',
        r'D:\ComfyUI\ComfyUI\models\...',
        r'D:\ComfyUI\ComfyUI\output',
      ]);
    });

    test('spans and fences interleave without overlap', () {
      final res = markdownCodeScan('`a`\n```b\nc\n```\n`d`');
      expect(res.segments, hasLength(3));
      expect(res.segments[0].kind, MarkdownCodeSegmentKind.inlineCode);
      expect(res.segments[1].kind, MarkdownCodeSegmentKind.codeBlock);
      expect(res.segments[2].kind, MarkdownCodeSegmentKind.inlineCode);
      for (var i = 1; i < res.segments.length; i++) {
        expect(res.segments[i].start >= res.segments[i - 1].end, isTrue);
      }
    });

    test('segments slice the source consistently', () {
      const source = 'x `A` ```r\ncode\n``` y';
      final res = markdownCodeScan(source);
      for (final seg in res.segments) {
        expect(source.substring(seg.start, seg.end), isNotEmpty);
      }
    });
  });

  group('markdownRemoveCode', () {
    test('returns text unchanged when no code is present', () {
      final input = '旁白 “保留” 以及普通段落。';
      expect(markdownRemoveCode(input), input);
    });

    test('replaces inline code with a space', () {
      expect(markdownRemoveCode('旁白 `print("hi")` 结尾'), '旁白   结尾');
    });

    test('preserves the line structure around a fenced block', () {
      expect(
        markdownRemoveCode('保留\n```dart\nprint(x);\n```\n结束'),
        '保留\n \n结束',
      );
    });

    test('removes fences in blockquotes and unclosed fences', () {
      expect(markdownRemoveCode('> ```\n> code\n> ```\nafter'), ' \nafter');
      expect(markdownRemoveCode('x\n```dart\nprint(1);'), 'x\n ');
    });

    test('removes spans and fences in source order', () {
      expect(markdownRemoveCode('`a`\n```b\nc\n```\n`d`'), ' \n \n ');
    });

    test('unmatched backtick runs across lines keep the prose', () {
      expect(markdownRemoveCode('`第一行\n旁白\n第三行`'), '`第一行\n旁白\n第三行`');
    });
  });
}
