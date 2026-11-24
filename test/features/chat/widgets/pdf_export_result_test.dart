import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:Cuplivo/features/chat/widgets/pdf_export_dialog.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// The panel a finished PDF lands on: what it says, what its two actions do, and
/// what it leaves behind.
///
/// The saver and the sharer are substituted, so no test opens a real save picker
/// or hands anything to the operating system. What is asserted is the decision the
/// panel owns: a cancelled picker leaves the document in hand, a written one
/// closes the panel and says where it went, and the working copy is discarded
/// unless someone else still has to read it.
void main() {
  late Directory workspace;
  late File pdf;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('pdf-result-test-');
    pdf = File('${workspace.path}/Project notes.pdf');
    await pdf.writeAsBytes(Uint8List.fromList(<int>[1, 2, 3]));
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  testWidgets('a phone gets a sheet that names the file and the page count', (
    tester,
  ) async {
    await _open(tester, _export(pdf), size: const Size(390, 844));

    expect(find.text('Export complete'), findsOneWidget);
    expect(find.text('3 pages · 1 KB'), findsOneWidget);
    expect(find.text('Project notes.pdf'), findsOneWidget);
    // One formula and one picture: two things the export could not draw.
    expect(find.text('2 item(s) not fully exported'), findsOneWidget);
    expect(find.text('1 formula(s) shown as plain text'), findsOneWidget);
    expect(
      find.text(
        '1 image(s) could not be read and are shown as their reference',
      ),
      findsOneWidget,
    );
    // The sheet's own shape: the two actions, no dialog.
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Save PDF'), findsOneWidget);
  });

  testWidgets('a computer gets a dialog with the same body', (tester) async {
    await _open(tester, _export(pdf), size: const Size(1400, 1000));

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Export complete'), findsOneWidget);
    expect(find.text('3 pages · 1 KB'), findsOneWidget);
    expect(find.text('Project notes.pdf'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Save PDF'), findsOneWidget);
  });

  testWidgets('save hands the file over, and closes once it is written', (
    tester,
  ) async {
    File? handedOver;
    String? handedName;
    String? handedTitle;
    await _open(
      tester,
      _export(pdf),
      size: const Size(390, 844),
      save: ({required file, fileName, dialogTitle}) async {
        handedOver = file;
        handedName = fileName;
        handedTitle = dialogTitle;
        // The desktop picker answers with the destination path; the toast still
        // names the file the way every other export's does.
        return '${workspace.path}/Downloads/Project notes.pdf';
      },
    );

    await tester.tap(find.text('Save PDF'));
    await tester.pumpAndSettle();

    // Read the toast, then run its timer out, then assert: the framework checks
    // for pending timers *before* teardown, so the drain cannot live in a hook —
    // and doing it before the assertions keeps a failure from leaving one behind.
    final toast = AppSnackBarManager().activeToasts.single.notification.message;
    await _drainToasts(tester);

    expect(handedOver?.path, pdf.path);
    // The picker offers the same name iOS cannot change afterwards.
    expect(handedName, 'Project notes.pdf');
    expect(handedTitle, 'Save PDF');
    expect(find.text('Export complete'), findsNothing);
    expect(toast, 'Exported as Project notes.pdf');
  });

  testWidgets('a cancelled picker leaves the panel, and the file, in hand', (
    tester,
  ) async {
    var saves = 0;
    await _open(
      tester,
      _export(pdf),
      size: const Size(390, 844),
      save: ({required file, fileName, dialogTitle}) async {
        saves++;
        return null;
      },
    );

    await tester.tap(find.text('Save PDF'));
    await tester.pumpAndSettle();

    expect(saves, 1);
    // The document is already built, so cancelling costs nothing and the next
    // thing the user may want is the share sheet.
    expect(find.text('Export complete'), findsOneWidget);
    expect(find.text('Save PDF'), findsOneWidget);
    expect(AppSnackBarManager().activeToasts, isEmpty);
    expect(await _eventually(tester, () => pdf.exists(), true), isTrue);
    // And the button goes back to being tappable.
    await tester.tap(find.text('Save PDF'));
    await tester.pumpAndSettle();
    expect(saves, 2);
  });

  testWidgets('a failed save says so and keeps the panel', (tester) async {
    await _open(
      tester,
      _export(pdf),
      size: const Size(390, 844),
      save: ({required file, fileName, dialogTitle}) async {
        throw const FileSystemException('the destination is read-only');
      },
    );

    await tester.tap(find.text('Save PDF'));
    await tester.pumpAndSettle();

    final toast = AppSnackBarManager().activeToasts.single.notification.message;
    await _drainToasts(tester);

    expect(toast, contains('the destination is read-only'));
    expect(find.text('Export complete'), findsOneWidget);
  });

  testWidgets('share hands the same file over, and closes on success', (
    tester,
  ) async {
    File? shared;
    Rect? sharedOrigin;
    await _open(
      tester,
      _export(pdf),
      size: const Size(390, 844),
      share: (file, {origin}) async {
        shared = file;
        // The parameter is named like the record field it fills: the shadowing
        // assignment is the bug, so the local says which one it is.
        sharedOrigin = origin;
        return true;
      },
    );

    await tester.tap(find.byType(IosCardPress).first);
    await tester.pumpAndSettle();

    expect(shared?.path, pdf.path);
    // iPad draws the sheet as a popover, so it has to be anchored.
    expect(sharedOrigin, isNotNull);
    expect(find.text('Export complete'), findsNothing);
    // The app it went to reads the path after the sheet returns, so this copy
    // outlives the panel.
    await _settleRealIo(tester);
    expect(await tester.runAsync(() => pdf.exists()), isTrue);
  });

  testWidgets('a share the user dismissed keeps the panel', (tester) async {
    await _open(
      tester,
      _export(pdf),
      size: const Size(390, 844),
      share: (file, {origin}) async => false,
    );

    await tester.tap(find.byType(IosCardPress).first);
    await tester.pumpAndSettle();

    expect(find.text('Export complete'), findsOneWidget);
  });

  testWidgets('a second tap on share does not open a second sheet', (
    tester,
  ) async {
    var shares = 0;
    final gate = Completer<bool>();
    await _open(
      tester,
      _export(pdf),
      size: const Size(390, 844),
      share: (file, {origin}) async {
        shares++;
        return gate.future;
      },
    );

    await tester.tap(find.byType(IosCardPress).first);
    await tester.pump();
    await tester.tap(find.byType(IosCardPress).first, warnIfMissed: false);
    await tester.pump();
    expect(shares, 1);

    gate.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Export complete'), findsOneWidget);
  });

  testWidgets('dismissing the panel discards the working copy', (tester) async {
    await _open(tester, _export(pdf), size: const Size(390, 844));
    expect(await tester.runAsync(() => pdf.exists()), isTrue);

    // Tapping outside the sheet closes it without saving or sharing.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('Export complete'), findsNothing);
    expect(await _eventually(tester, () => pdf.exists(), false), isFalse);
  });

  testWidgets('a save hands over a copy, so the panel discards its own', (
    tester,
  ) async {
    File? handedOver;
    await _open(
      tester,
      _export(pdf),
      size: const Size(390, 844),
      save: ({required file, fileName, dialogTitle}) async {
        // What the picker answers once it has copied the file: the name it was
        // written under. Copying is the picker's own tested behaviour.
        handedOver = file;
        return 'copy.pdf';
      },
    );

    await tester.tap(find.text('Save PDF'));
    await tester.pumpAndSettle();
    await _drainToasts(tester);

    expect(handedOver?.path, pdf.path);
    expect(await _eventually(tester, () => pdf.exists(), false), isFalse);
  });

  testWidgets('an export with nothing to report says only the size', (
    tester,
  ) async {
    await _open(
      tester,
      ExportedPdf(
        file: pdf,
        result: PdfExportResult(
          bytes: Uint8List(1024),
          pages: 1,
          degradedMath: const <String>[],
          degradedDiagrams: const <String>[],
          undrawnImages: const <String>[],
        ),
      ),
      size: const Size(390, 844),
    );

    expect(find.text('1 pages · 1 KB'), findsOneWidget);
    expect(find.textContaining('not fully exported'), findsNothing);
  });
}

ExportedPdf _export(File file) => ExportedPdf(
  file: file,
  result: PdfExportResult(
    bytes: Uint8List(1024),
    pages: 3,
    degradedMath: const <String>['x^2'],
    degradedDiagrams: const <String>[],
    undrawnImages: const <String>['a.png'],
  ),
);

Future<void> _open(
  WidgetTester tester,
  ExportedPdf export, {
  required Size size,
  PdfDocumentSaver? save,
  PdfDocumentSharer? share,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>(
      create: (_) => SettingsProvider(createBusinessTestPreferences()),
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPdfExportResult(
                context,
                export,
                save:
                    save ??
                    ({required file, fileName, dialogTitle}) async => null,
                share: share ?? (file, {origin}) async => false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Runs the toast the panel showed out of the fake clock's pending timers.
///
/// This has to happen inside the body: `_verifyInvariants` refuses a test whose
/// timers are still pending *before* teardown callbacks run, so a hook is too
/// late by construction. Every caller drains before it asserts.
Future<void> _drainToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

/// Lets I/O the widget under test started in the fake zone actually finish.
///
/// `dart:io` futures need the real event loop, and the test body runs on a fake
/// clock: a value read the moment `pumpAndSettle` returns is a value read before
/// the delete landed.
Future<void> _settleRealIo(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
}

/// [probe] until it answers [expected], or fails after about a second.
Future<bool> _eventually(
  WidgetTester tester,
  Future<bool> Function() probe,
  bool expected,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    final answer = await tester.runAsync(probe);
    if (answer == expected) return answer!;
    await _settleRealIo(tester);
  }
  return await tester.runAsync(probe) ?? !expected;
}
