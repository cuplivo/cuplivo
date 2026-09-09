import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
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
