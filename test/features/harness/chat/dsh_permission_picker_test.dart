import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_permission_picker.dart';

import 'dsh_picker_test_host.dart';

const DshPermissionState _state = DshPermissionState(
  options: <DshPermissionOption>[
    DshPermissionOption(
      value: 'read-only',
      name: 'Read only',
      description: 'Read files and answer, change nothing.',
    ),
    DshPermissionOption(
      value: 'workspace-write',
      name: 'Workspace write',
      description: 'Create and edit files inside the workspace.',
    ),
    DshPermissionOption(
      value: 'danger-full-access',
      name: 'Full access',
      description: 'Run commands anywhere the host allows.',
    ),
  ],
  currentValue: 'workspace-write',
);

Future<void> pumpPickerHost(
  WidgetTester tester, {
  required DshPermissionState state,
  required void Function(String?) onResult,
}) async {
  await tester.pumpWidget(
    await buildDshPickerTestApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final result = await showDshPermissionPicker(
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
  testWidgets('a safe preset is returned without confirmation', (tester) async {
    String? result;
    await pumpPickerHost(
      tester,
      state: _state,
      onResult: (value) => result = value,
    );

    expect(find.text('Permissions'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('dsh-permission-read-only')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dsh-permission-workspace-write')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('dsh-permission-read-only')),
    );
    await tester.pumpAndSettle();

    expect(result, 'read-only');
  });

  testWidgets('full access asks for an explicit acknowledgement first', (
    tester,
  ) async {
    String? result;
    await pumpPickerHost(
      tester,
      state: _state,
      onResult: (value) => result = value,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('dsh-permission-danger-full-access')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Allow full access?'), findsOneWidget);
    expect(find.textContaining('without asking again'), findsOneWidget);

    // Confirming without acknowledging must not choose anything.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Allow full access?'), findsOneWidget);

    await tester.tap(find.text('I understand the risk'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(result, 'danger-full-access');
  });

  testWidgets('a destructive preset flagged by the Host is risk-gated too', (
    tester,
  ) async {
    const state = DshPermissionState(
      options: <DshPermissionOption>[
        DshPermissionOption(
          value: 'auto',
          name: 'Auto review',
          requiresRiskConfirmation: true,
        ),
      ],
      currentValue: 'read-only',
    );
    String? result;
    await pumpPickerHost(
      tester,
      state: state,
      onResult: (value) => result = value,
    );

    await tester.tap(find.byKey(const ValueKey<String>('dsh-permission-auto')));
    await tester.pumpAndSettle();

    expect(result, isNull);
    await tester.tap(find.text('I understand the risk'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(result, 'auto');
  });

  testWidgets('a server without presets shows the empty state', (tester) async {
    String? result;
    await pumpPickerHost(
      tester,
      state: const DshPermissionState(
        options: <DshPermissionOption>[],
        currentValue: 'read-only',
      ),
      onResult: (value) => result = value,
    );

    expect(
      find.text('This server exposes no permission presets.'),
      findsOneWidget,
    );
    expect(result, isNull);
  });

  test('full access and auto always require the risk confirmation', () {
    expect(
      dshPermissionRequiresConfirmation(
        const DshPermissionOption(
          value: 'danger-full-access',
          name: 'Full access',
        ),
      ),
      isTrue,
    );
    expect(
      dshPermissionRequiresConfirmation(
        const DshPermissionOption(value: 'auto', name: 'Auto review'),
      ),
      isTrue,
    );
    expect(
      dshPermissionRequiresConfirmation(
        const DshPermissionOption(
          value: 'workspace-write',
          name: 'Workspace write',
        ),
      ),
      isFalse,
    );
  });
}
