import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_model_picker.dart';

import 'dsh_picker_test_host.dart';

DshModelCatalog buildCatalog() {
  return const DshModelCatalog(
    groups: <DshModelProviderGroup>[
      DshModelProviderGroup(
        id: 'deepseek',
        name: 'DeepSeek',
        models: <DshModelOption>[
          DshModelOption(
            id: 'deepseek-flash',
            name: 'deepseek-flash',
            description: 'Fast answers',
            reasoningEfforts: <DshReasoningEffort>[
              DshReasoningEffort(id: 'medium', name: 'Medium'),
              DshReasoningEffort(id: 'high', name: 'High'),
            ],
            defaultReasoningEffortId: 'medium',
          ),
          DshModelOption(
            id: 'deepseek-reasoner',
            name: 'deepseek-reasoner',
            badge: 'beta',
          ),
        ],
      ),
      DshModelProviderGroup(
        id: 'moonshot',
        name: 'Moonshot',
        models: <DshModelOption>[
          DshModelOption(id: 'kimi-k2', name: 'kimi-k2'),
        ],
      ),
    ],
    failures: <DshModelCatalogFailure>[
      DshModelCatalogFailure(
        id: 'broken',
        name: 'Broken provider',
        message: 'route crashed',
      ),
    ],
  );
}

Future<void> pumpPickerHost(
  WidgetTester tester, {
  required DshModelCatalog catalog,
  required DshModelSelection? current,
  required void Function(DshModelSelection?) onResult,
}) async {
  await tester.pumpWidget(
    await buildDshPickerTestApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final result = await showDshModelPicker(
                  context,
                  catalog: catalog,
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
  testWidgets('lists providers and preserves the current effort', (
    tester,
  ) async {
    DshModelSelection? result;
    await pumpPickerHost(
      tester,
      catalog: buildCatalog(),
      current: const DshModelSelection(
        providerId: 'deepseek',
        modelId: 'deepseek-reasoner',
        reasoningEffortId: 'high',
      ),
      onResult: (value) => result = value,
    );

    expect(find.text('Choose a model'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('dsh-model-provider-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dsh-model-provider-deepseek')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dsh-model-provider-moonshot')),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(
        const ValueKey<String>('dsh-model-row-deepseek::deepseek-flash'),
      ),
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('dsh-model-row-deepseek::deepseek-flash'),
      ),
    );
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.providerId, 'deepseek');
    expect(result!.modelId, 'deepseek-flash');
    // The current effort survives when the new model advertises it too.
    expect(result!.reasoningEffortId, 'high');
  });

  testWidgets('search filters rows and a provider pill narrows the catalog', (
    tester,
  ) async {
    DshModelSelection? result;
    await pumpPickerHost(
      tester,
      catalog: buildCatalog(),
      current: null,
      onResult: (value) => result = value,
    );

    await tester.enterText(find.byKey(DshModelPicker.searchFieldKey), 'kimi');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('dsh-model-row-moonshot::kimi-k2')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('dsh-model-row-deepseek::deepseek-flash'),
      ),
      findsNothing,
    );

    await tester.enterText(find.byKey(DshModelPicker.searchFieldKey), '');
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('dsh-model-provider-deepseek')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey<String>('dsh-model-row-deepseek::deepseek-flash'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dsh-model-row-moonshot::kimi-k2')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('dsh-model-provider-all')),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('dsh-model-row-moonshot::kimi-k2')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('dsh-model-row-moonshot::kimi-k2')),
    );
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.providerId, 'moonshot');
    expect(result!.modelId, 'kimi-k2');
    expect(result!.reasoningEffortId, isNull);
  });

  testWidgets('failed providers are shown, not silently dropped', (
    tester,
  ) async {
    await pumpPickerHost(
      tester,
      catalog: const DshModelCatalog(
        failures: <DshModelCatalogFailure>[
          DshModelCatalogFailure(
            id: 'broken',
            name: 'Broken provider',
            message: 'route crashed',
          ),
        ],
      ),
      current: null,
      onResult: (_) {},
    );

    expect(find.text('Providers that failed to load'), findsOneWidget);
    expect(find.text('Broken provider'), findsOneWidget);
    expect(find.text('route crashed'), findsOneWidget);
  });
}
