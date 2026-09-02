import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/backup/widgets/backup_action_row.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRow(
    WidgetTester tester, {
    required String label,
    String? subtitle,
    String? value,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: BackupActionRow(
                label: label,
                subtitle: subtitle,
                value: value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('value keeps natural width and sits flush right', (tester) async {
    await pumpRow(tester, label: '该备份了', value: '9/1 14:38');

    final valueRect = tester.getRect(find.text('9/1 14:38'));
    // IosCardPress horizontal padding 12 → row content right edge at 538
    // (Center offset 250 + SizedBox width 300 − 12).
    expect(valueRect.right, closeTo(538, 1));

    final labelRect = tester.getRect(find.text('该备份了'));
    expect(labelRect.right, lessThan(valueRect.left));

    expect(tester.takeException(), isNull);
  });

  testWidgets('long label ellipsizes first while value stays full width', (
    tester,
  ) async {
    const longLabel =
        'Import from Cherry Studio app with a really really long name';
    await pumpRow(tester, label: longLabel, value: 'Enabled');

    expect(find.text('Enabled'), findsOneWidget);
    final valueRect = tester.getRect(find.text('Enabled'));
    expect(valueRect.right, closeTo(538, 1));
    expect(valueRect.width, greaterThan(40));

    expect(tester.takeException(), isNull);
  });

  testWidgets('labelMaxLines param reaches the label/subtitle Text widgets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: BackupActionRow(
                label: 'Export Kelivo-Compatible Backup',
                subtitle:
                    'A full backup that old Kelivo or older Cuplivo builds can import',
                labelMaxLines: 2,
                subtitleMaxLines: 2,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final label = tester.widget<Text>(
      find.text('Export Kelivo-Compatible Backup'),
    );
    expect(label.maxLines, 2);
    final subtitle = tester.widget<Text>(
      find.text(
        'A full backup that old Kelivo or older Cuplivo builds can import',
      ),
    );
    expect(subtitle.maxLines, 2);

    expect(tester.takeException(), isNull);
  });
}
