import 'package:Cuplivo/core/utils/token_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty string is 0 tokens', () {
    expect(estimateTokens(''), 0);
  });

  test('CJK characters count as 1 token each', () {
    expect(estimateTokens('你好'), 2);
    expect(estimateTokens('世界'), 2);
  });

  test('latin uses 4 characters per token, rounded up', () {
    expect(estimateTokens('abcd'), 1);
    expect(estimateTokens('abcde'), 2);
    expect(estimateTokens('hello'), 2);
  });

  test('mixes CJK and latin', () {
    expect(estimateTokens('你好hello'), 4);
  });
}
