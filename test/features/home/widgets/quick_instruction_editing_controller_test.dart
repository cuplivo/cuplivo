import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/features/home/widgets/quick_instruction_editing_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

QuickInstructionInvocationSnapshot _snapshot(String id, int order) {
  return QuickInstructionInvocationSnapshot.fromInstruction(
    QuickInstruction(id: id, title: 'Instruction $id', prompt: 'Prompt $id'),
    order: order,
  );
}

void main() {
  testWidgets('renders frozen invocations as leading WidgetSpans', (
    tester,
  ) async {
    final controller = QuickInstructionEditingController(text: 'message');
    addTearDown(controller.dispose);
    controller.setInstructions(<QuickInstructionInvocationSnapshot>[
      _snapshot('one', 0),
      _snapshot('two', 1),
    ]);

    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(),
      withComposing: true,
    );

    expect(span.children?.whereType<WidgetSpan>(), hasLength(2));
    expect(controller.bodyText, 'message');
    expect(
      controller.value.text,
      '${QuickInstructionEditingController.objectReplacementCharacter}'
      '${QuickInstructionEditingController.objectReplacementCharacter}'
      'message',
    );
  });

  test('backspace at the body boundary atomically removes the left label', () {
    final controller = QuickInstructionEditingController(text: 'message');
    addTearDown(controller.dispose);
    controller.setInstructions(<QuickInstructionInvocationSnapshot>[
      _snapshot('one', 0),
      _snapshot('two', 1),
    ]);
    final formatter = QuickInstructionEditingFormatter(controller);
    final oldValue = controller.value.copyWith(
      selection: const TextSelection.collapsed(offset: 2),
    );
    final nextValue = TextEditingValue(
      text:
          '${QuickInstructionEditingController.objectReplacementCharacter}message',
      selection: const TextSelection.collapsed(offset: 1),
    );

    controller.value = formatter.formatEditUpdate(oldValue, nextValue);

    expect(controller.instructions.map((item) => item.instructionId), ['one']);
    expect(controller.bodyText, 'message');
    expect(controller.bodySelection.baseOffset, 0);
  });

  test('typing between labels moves the inserted text to the body start', () {
    final controller = QuickInstructionEditingController(text: 'message');
    addTearDown(controller.dispose);
    controller.setInstructions(<QuickInstructionInvocationSnapshot>[
      _snapshot('one', 0),
      _snapshot('two', 1),
    ]);
    final formatter = QuickInstructionEditingFormatter(controller);
    final marker = QuickInstructionEditingController.objectReplacementCharacter;
    final oldValue = controller.value.copyWith(
      selection: const TextSelection.collapsed(offset: 1),
    );

    controller.value = formatter.formatEditUpdate(
      oldValue,
      TextEditingValue(
        text: '${marker}x${marker}message',
        selection: const TextSelection.collapsed(offset: 2),
      ),
    );

    expect(controller.instructions, hasLength(2));
    expect(controller.bodyText, 'xmessage');
    expect(controller.bodySelection.baseOffset, 1);
  });
}
