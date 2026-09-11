import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:Cuplivo/shared/widgets/plain_text_code_editor.dart';

void main() {
  test('factory preserves CRLF and CR line endings', () {
    final crlf = createPlainTextCodeController('first\r\nlast');
    final cr = createPlainTextCodeController('first\rlast');

    expect(crlf.options.lineBreak, TextLineBreak.crlf);
    expect(crlf.text, 'first\r\nlast');
    expect(cr.options.lineBreak, TextLineBreak.cr);
    expect(cr.text, 'first\rlast');

    crlf.dispose();
    cr.dispose();
  });

  test('CodeLineEditingController preserves large plain text', () {
    final text = List<String>.generate(
      5000,
      (index) => 'line $index: ${'x' * 80}',
    ).join('\n');
    final controller = CodeLineEditingController.fromText(text);
    addTearDown(controller.dispose);

    expect(controller.text, text);
    expect(controller.lineCount, 5000);

    controller.replaceSelection('inserted');
    expect(controller.text.startsWith('inserted'), isTrue);
  });
}
