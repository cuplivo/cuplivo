import 'package:Cuplivo/features/home/controllers/stream_presentation_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('large provider burst begins with a restrained presentation step', () {
    final policy = StreamPresentationPolicy();
    final target = List.filled(400, '字').join();

    final first = policy.advance(target: target, visible: '');

    expect(first, isNotNull);
    expect(first!.length, inInclusiveRange(2, 6));
    expect(first.length, lessThan(target.length));
  });

  test('presentation accelerates without revealing the whole backlog', () {
    final policy = StreamPresentationPolicy();
    final target = List.filled(800, 'a').join();
    var visible = '';
    final stepSizes = <int>[];

    for (var i = 0; i < 8; i++) {
      final next = policy.advance(target: target, visible: visible)!;
      stepSizes.add(next.length - visible.length);
      visible = next;
    }

    expect(stepSizes.first, lessThan(stepSizes.last));
    expect(visible.length, lessThan(target.length));
    expect(stepSizes.every((step) => step <= 96), isTrue);
  });

  test('never exposes half of a UTF-16 surrogate pair', () {
    final policy = StreamPresentationPolicy(
      minUnitsPerTick: 1,
      initialUnitsPerTick: 1,
    );
    const target = 'a😀b';
    var visible = '';

    while (visible != target) {
      visible = policy.advance(target: target, visible: visible)!;
      expect(_containsLoneSurrogate(visible), isFalse);
    }
  });

  test('replacement content is displayed immediately and resets cadence', () {
    final policy = StreamPresentationPolicy();

    expect(
      policy.advance(target: 'replacement', visible: 'original'),
      'replacement',
    );
    final next = policy.advance(
      target: 'replacement${List.filled(200, 'x').join()}',
      visible: 'replacement',
    );
    expect(next!.length - 'replacement'.length, lessThanOrEqualTo(6));
  });
}

bool _containsLoneSurrogate(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length) return true;
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return true;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return true;
    }
  }
  return false;
}
