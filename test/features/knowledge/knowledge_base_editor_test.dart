import 'package:Cuplivo/features/knowledge/widgets/knowledge_base_editor.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_form_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DraftHolder {
  KnowledgeBaseDraft? value;
}

Future<_DraftHolder> _openEditor(
  WidgetTester tester, {
  String name = 'Old',
  String description = 'desc',
  int chunkSize = 512,
  int chunkOverlap = 64,
}) async {
  final holder = _DraftHolder();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                holder.value = await showKnowledgeBaseEditor(
                  context,
                  name: name,
                  description: description,
                  chunkSize: chunkSize,
                  chunkOverlap: chunkOverlap,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  return holder;
}

Finder _fieldAt(int index) => find
    .descendant(
      of: find.byType(IosFormTextField).at(index),
      matching: find.byType(TextField),
    )
    .first;

void main() {
  testWidgets('editor clamps chunk values and returns the draft', (
    tester,
  ) async {
    final holder = await _openEditor(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldAt(0), 'Handbook');
    await tester.enterText(_fieldAt(2), '10'); // below the minimum
    await tester.enterText(_fieldAt(3), '999'); // overlap >= size
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final draft = holder.value;
    expect(draft, isNotNull);
    expect(draft!.name, 'Handbook');
    expect(draft.description, 'desc');
    expect(draft.chunkSize, kKnowledgeMinChunkSize);
    expect(draft.chunkOverlap, kKnowledgeMinChunkSize - 1);
  });

  testWidgets('editor disables save while the name is empty', (tester) async {
    await _openEditor(tester, name: '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final save = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Save'),
    );
    expect(save.onPressed, isNull);

    await tester.enterText(_fieldAt(0), 'Named');
    await tester.pumpAndSettle();
    final enabled = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Save'),
    );
    expect(enabled.onPressed, isNotNull);
  });
}
