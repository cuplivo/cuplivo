import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/shared/widgets/mini_map/mini_map_shared.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _msg(String role, String content, {String? id}) {
  return ChatMessage(
    id: id ?? 'msg-$role-${content.hashCode}',
    role: role,
    content: content,
    conversationId: 'conv',
  );
}

void main() {
  group('buildMiniMapPairs', () {
    test('pairs user with following assistant', () {
      final pairs = buildMiniMapPairs([
        _msg('user', 'q1'),
        _msg('assistant', 'a1'),
        _msg('user', 'q2'),
        _msg('assistant', 'a2'),
      ]);
      expect(pairs, hasLength(2));
      expect(pairs[0].user!.content, 'q1');
      expect(pairs[0].assistant!.content, 'a1');
      expect(pairs[1].user!.content, 'q2');
      expect(pairs[1].assistant!.content, 'a2');
    });

    test('orphan assistant without user', () {
      final pairs = buildMiniMapPairs([
        _msg('assistant', 'lonely'),
        _msg('user', 'q'),
      ]);
      expect(pairs, hasLength(2));
      expect(pairs[0].user, isNull);
      expect(pairs[0].assistant!.content, 'lonely');
      expect(pairs[1].user!.content, 'q');
      expect(pairs[1].assistant, isNull);
    });

    test('trailing user without assistant', () {
      final pairs = buildMiniMapPairs([
        _msg('user', 'q'),
        _msg('assistant', 'a'),
        _msg('user', 'trailing'),
      ]);
      expect(pairs, hasLength(2));
      expect(pairs[1].user!.content, 'trailing');
      expect(pairs[1].assistant, isNull);
    });

    test('non user/assistant roles are ignored', () {
      final pairs = buildMiniMapPairs([
        _msg('system', 'sys'),
        _msg('user', 'q'),
        _msg('tool', 'tool-result'),
        _msg('assistant', 'a'),
      ]);
      expect(pairs, hasLength(1));
      expect(pairs[0].user!.content, 'q');
      expect(pairs[0].assistant!.content, 'a');
    });

    test('empty input', () {
      expect(buildMiniMapPairs(const []), isEmpty);
    });
  });

  group('miniMapOneLine', () {
    test('strips think/thought/reasoning blocks entirely', () {
      expect(
        miniMapOneLine('hi <think>inner</think> <reasoning>r</reasoning> x'),
        'hi x',
      );
      expect(miniMapOneLine('<thought>t</thought>only'), 'only');
    });

    test('strips image and file markers', () {
      expect(
        miniMapOneLine('see [image:foo.png] and [file:a.txt] done'),
        'see and done',
      );
    });

    test('collapses newlines and whitespace', () {
      expect(miniMapOneLine('a\n  b\t c'), 'a b c');
    });
  });

  group('miniMapSearchTokens', () {
    test('splits on whitespace and lowercases', () {
      expect(miniMapSearchTokens('Hello  World'), ['hello', 'world']);
    });

    test('drops empty tokens', () {
      expect(miniMapSearchTokens('   '), isEmpty);
      expect(miniMapSearchTokens(''), isEmpty);
    });
  });

  group('filterMiniMapMessages', () {
    test('AND semantics: every token must hit', () {
      final msgs = [
        _msg('user', 'foo bar'),
        _msg('assistant', 'foo only'),
        _msg('user', 'bar only'),
        _msg('user', 'foo bar baz'),
      ];
      final result = filterMiniMapMessages(
        msgs,
        miniMapSearchTokens('foo bar'),
      );
      expect(result.map((m) => m.content), ['foo bar', 'foo bar baz']);
    });

    test('single token matches', () {
      final msgs = [_msg('user', 'alpha'), _msg('assistant', 'beta')];
      final result = filterMiniMapMessages(msgs, ['beta']);
      expect(result.map((m) => m.content), ['beta']);
    });

    test('empty tokens returns empty list', () {
      expect(filterMiniMapMessages([_msg('user', 'x')], const []), isEmpty);
    });

    test('matches inside raw content including stripped regions', () {
      final msgs = [
        _msg('user', 'before <think>secret</think> after'),
        _msg('assistant', '[image:photo.png] plain'),
      ];
      expect(filterMiniMapMessages(msgs, ['secret']).map((m) => m.content), [
        'before <think>secret</think> after',
      ]);
      expect(filterMiniMapMessages(msgs, ['photo']).map((m) => m.content), [
        '[image:photo.png] plain',
      ]);
    });

    test('excludes tool/system messages', () {
      final msgs = [_msg('tool', 'foo'), _msg('system', 'foo')];
      expect(filterMiniMapMessages(msgs, ['foo']), isEmpty);
    });
  });

  group('miniMapHitSnippet', () {
    test('centers on the hit', () {
      final content = List.filled(30, 'word').join(' ');
      final snippet = miniMapHitSnippet(content, ['word'], maxChars: 80);
      expect(snippet, contains('word'));
      expect(snippet.length, lessThanOrEqualTo(86)); // 80 + ellipsis
    });

    test('flattens tags but keeps inner text', () {
      final snippet = miniMapHitSnippet(
        'before <think>secret needle</think> after',
        ['needle'],
      );
      expect(snippet, contains('needle'));
      expect(snippet, isNot(contains('<think>')));
      expect(snippet, isNot(contains('</think>')));
    });

    test('flattens image marker keeping inner text', () {
      final snippet = miniMapHitSnippet('see [image:photo.png] here', [
        'photo',
      ]);
      expect(snippet, contains('photo'));
      expect(snippet, isNot(contains('[image:')));
    });

    test('window cut mid-block leaves no stray vendor tags', () {
      // The window (hit-centered, maxChars 100) contains the full `<think>`
      // opening tag and the needle, but its end lands before `</think>` —
      // a lone opening tag that must be scrubbed.
      final content =
          '${List.filled(20, 'pad').join(' ')} <think>needle '
          '${List.filled(60, 'x').join('')} </think> '
          '${List.filled(20, 'tail').join(' ')}';
      final snippet = miniMapHitSnippet(content, ['needle'], maxChars: 100);
      expect(snippet, isNot(contains('<think>')));
      expect(snippet, isNot(contains('</think>')));
      expect(snippet, contains('needle'));
      expect(snippet, startsWith('... '));
      expect(snippet, endsWith(' ...'));
    });

    test('window cut mid-marker leaves no raw marker prefix', () {
      // The needle sits before the marker, so the window starts with
      // `[image:` but cuts inside its inner text — the unterminated prefix
      // must be scrubbed (inner text survives).
      final content =
          '${List.filled(10, 'pad').join(' ')} needle '
          '${List.filled(10, 'mid').join(' ')} [image:'
          '${List.filled(30, 'x').join('')}]';
      final snippet = miniMapHitSnippet(content, ['needle'], maxChars: 100);
      expect(snippet, isNot(contains('[image:')));
      expect(snippet, contains('needle'));
      expect(snippet, contains('xxx'));
    });

    test('unterminated marker prefix is scrubbed', () {
      final snippet = miniMapHitSnippet('see [image:photo.png here', ['photo']);
      expect(snippet, isNot(contains('[image:')));
      expect(snippet, contains('photo'));
    });

    test('short content is returned whole', () {
      expect(miniMapHitSnippet('a needle b', ['needle']), 'a needle b');
    });

    test('empty input', () {
      expect(miniMapHitSnippet('', ['x']), '');
      expect(miniMapHitSnippet('x', const []), '');
    });
  });

  group('buildMiniMapHighlightSpans', () {
    test('highlights matching token case-insensitively', () {
      final spans = buildMiniMapHighlightSpans(
        'Hello world hello',
        ['hello'],
        const TextStyle(),
        const TextStyle(backgroundColor: Color(0xFFFF0000)),
      );
      expect(spans, hasLength(3));
      expect(spans[0].text, 'Hello');
      expect(spans[0].style?.backgroundColor, const Color(0xFFFF0000));
      expect(spans[1].text, ' world ');
      expect(spans[1].style?.backgroundColor, isNull);
      expect(spans[2].text, 'hello');
      expect(spans[2].style?.backgroundColor, const Color(0xFFFF0000));
    });

    test('no tokens yields single plain span', () {
      final spans = buildMiniMapHighlightSpans(
        'plain',
        const [],
        const TextStyle(),
        const TextStyle(),
      );
      expect(spans, hasLength(1));
      expect(spans[0].text, 'plain');
    });

    test('empty text yields single empty span', () {
      final spans = buildMiniMapHighlightSpans(
        '',
        ['x'],
        const TextStyle(),
        const TextStyle(),
      );
      expect(spans, hasLength(1));
      expect(spans[0].text, '');
    });
  });
}
