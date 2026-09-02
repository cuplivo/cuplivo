import 'package:Cuplivo/core/services/api/gemini_thought_signature.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const firstSignature =
      '<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"first"}} -->';
  const lastSignature =
      '<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"last"}} -->';

  test('content without a Gemini signature is unchanged', () {
    final result = extractGeminiThoughtSignature('visible reply');

    expect(result.content, 'visible reply');
    expect(result.signature, isNull);
  });

  test('extracts the last signature and removes all signature comments', () {
    final result = extractGeminiThoughtSignature(
      'visible reply\n$firstSignature\n$lastSignature',
    );

    expect(result.content, 'visible reply');
    expect(result.signature, lastSignature);
  });

  test('a signature-only chunk has empty visible content', () {
    final result = extractGeminiThoughtSignature(firstSignature);

    expect(result.content, isEmpty);
    expect(result.signature, firstSignature);
  });

  test('appends a stored signature once for API history replay', () {
    expect(
      appendGeminiThoughtSignature('visible reply', firstSignature),
      'visible reply\n$firstSignature',
    );
    expect(
      appendGeminiThoughtSignature(
        'visible reply\n$firstSignature',
        lastSignature,
      ),
      'visible reply\n$firstSignature',
    );
  });
}
