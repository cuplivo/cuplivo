import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_agent_preset_picker.dart';

import 'dsh_picker_test_host.dart';

const DshAgentPresetState _state = DshAgentPresetState(
  options: <DshAgentPresetOption>[
    DshAgentPresetOption(id: 'standard', isDefault: true),
    DshAgentPresetOption(
      id: 'ptc',
      description: 'Calls tools from generated code.',
    ),
    DshAgentPresetOption(
      id: 'review',
      name: 'Code review',
      description: 'Prioritizes bugs and test gaps.',
    ),
    DshAgentPresetOption(
      id: 'broken-one',
      name: 'Broken mode',
      broken: 'Its plugin failed to activate.',
    ),
  ],
  currentId: 'standard',
  defaultId: 'standard',
  canSelect: true,
);

Future<void> pumpPickerHost(
  WidgetTester tester, {
  required DshAgentPresetState state,
  required void Function(String?) onResult,
}) async {
  await tester.pumpWidget(
    await buildDshPickerTestApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final result = await showDshAgentPresetPicker(
                  context,
                  state: state,
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
  testWidgets('the shipped presets use Cuplivo copy and a plugin name wins', (
    tester,
  ) async {
    String? result;
    await pumpPickerHost(
      tester,
      state: _state,
      onResult: (value) => result = value,
    );

    expect(find.text('Agent preset'), findsOneWidget);
    // The shipped rows publish no copy, so Cuplivo localizes them by id.
    expect(find.text('Standard mode'), findsOneWidget);
    expect(find.text('PTC mode'), findsOneWidget);
    // A declaration that names itself is rendered verbatim.
    expect(find.text('Code review'), findsOneWidget);
    expect(find.text('Prioritizes bugs and test gaps.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('dsh-preset-ptc')));
    await tester.pumpAndSettle();

    expect(result, 'ptc');
  });

  testWidgets('a broken declaration renders the Host reason and cannot start', (
    tester,
  ) async {
    String? result;
    await pumpPickerHost(
      tester,
      state: _state,
      onResult: (value) => result = value,
    );

    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Its plugin failed to activate.'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('dsh-preset-broken-one')),
    );
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('a started session cannot open the picker from the chip', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      await buildDshPickerTestApp(
        home: Scaffold(
          body: Center(
            child: DshAgentPresetChip(
              agentPresets: _state.copyWith(canSelect: false),
              onTap: () => tapped += 1,
            ),
          ),
        ),
      ),
    );

    // The chip reports what the session runs even when it can no longer change.
    expect(find.text('Standard mode'), findsOneWidget);

    await tester.tap(find.byKey(DshAgentPresetChip.chipKey));
    await tester.pumpAndSettle();

    expect(tapped, 0);
  });

  testWidgets('the chip shows the current name and opens the picker', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      await buildDshPickerTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: DshAgentPresetChip(
                agentPresets: _state,
                onTap: () async {
                  final picked = await showDshAgentPresetPicker(
                    context,
                    state: _state,
                  );
                  result = picked;
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Standard mode'), findsOneWidget);

    await tester.tap(find.byKey(DshAgentPresetChip.chipKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('dsh-preset-standard')));
    await tester.pumpAndSettle();

    // Picking the row the session already runs closes without a write.
    expect(result, isNull);
  });
}
