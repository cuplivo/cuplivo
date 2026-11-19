import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/model_spec.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_reasoning_picker.dart';

import 'dsh_picker_test_host.dart';

const DshModelOption _model = DshModelOption(
  id: 'deepseek-flash',
  name: 'deepseek-flash',
  reasoningEfforts: <DshReasoningEffort>[
    DshReasoningEffort(id: 'off', name: 'Off'),
    DshReasoningEffort(
      id: 'low',
      name: 'Low',
      description: 'Faster, less deliberation',
    ),
    DshReasoningEffort(id: 'high', name: 'High'),
  ],
  defaultReasoningEffortId: 'high',
);

Future<void> pumpPickerHost(
  WidgetTester tester, {
  required DshModelOption model,
  required DshModelSelection? current,
  required void Function(String?) onResult,
}) async {
  await tester.pumpWidget(
    await buildDshPickerTestApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final result = await showDshReasoningPicker(
                  context,
                  model: model,
                  current: current,
                );
                onResult(result);
              },
              child: const Text('open picker'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open picker'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the advertised efforts and returns the picked one', (
    tester,
  ) async {
    String? result;
    await pumpPickerHost(
      tester,
      model: _model,
      current: const DshModelSelection(
        providerId: 'deepseek',
        modelId: 'deepseek-flash',
        reasoningEffortId: 'off',
      ),
      onResult: (value) => result = value,
    );

    expect(find.text('Reasoning effort'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('dsh-reasoning-off')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dsh-reasoning-low')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dsh-reasoning-high')),
      findsOneWidget,
    );
    // The catalog default is marked, and the current effort is checked.
    expect(find.text('Default'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('dsh-reasoning-high')));
    await tester.pumpAndSettle();

    expect(result, 'high');
  });

  testWidgets('a model without efforts shows the empty state', (tester) async {
    String? result;
    await pumpPickerHost(
      tester,
      model: const DshModelOption(id: 'plain', name: 'plain'),
      current: null,
      onResult: (value) => result = value,
    );

    expect(
      find.text('This model has no adjustable reasoning effort.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dsh-reasoning-off')),
      findsNothing,
    );
    expect(result, isNull);
  });

  test('wire effort ids map to Cuplivo reasoning levels', () {
    expect(dshReasoningLevelForEffort('off'), ReasoningLevel.off);
    expect(dshReasoningLevelForEffort('high'), ReasoningLevel.high);
    expect(dshReasoningLevelForEffort('xhigh'), ReasoningLevel.xhigh);
    // A Host plugin may invent an id; the label comes from the catalog, the
    // icon falls back to the neutral level instead of failing.
    expect(dshReasoningLevelForEffort('turbo'), ReasoningLevel.auto);
    expect(dshReasoningRequestForEffort('medium').level, ReasoningLevel.medium);
  });
}
