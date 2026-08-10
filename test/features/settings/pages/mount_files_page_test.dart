import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import 'package:Cuplivo/features/settings/pages/mount_files_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// The page loads its listing via real dart:io streams; each stream event is
/// delivered on the real event loop, so pump+runAsync must cycle until the
/// listing lands.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}

void main() {
  testWidgets('empty directory keeps the breadcrumb so the user can step up '
      'one level instead of leaving the page', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('mount_page_test_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    Directory('${tmp.path}/sub').createSync();

    final mount = FilesystemMount(
      alias: 'workspaces',
      path: tmp.path,
      readOnly: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: MountFilesPage(mount: mount),
      ),
    );

    // Enter the empty subdirectory.
    await pumpUntilFound(tester, find.text('sub'));
    await tester.tap(find.text('sub'));

    final l10n = AppLocalizations.of(
      tester.element(find.byType(MountFilesPage)),
    )!;
    await pumpUntilFound(tester, find.text(l10n.mountFilesEmptyDir));
    expect(find.text('@workspaces'), findsOneWidget, reason: 'root crumb');
    expect(find.text('sub'), findsOneWidget, reason: 'subdir crumb');
  });

  testWidgets('non-empty directory shows breadcrumb and entries', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('mount_page_test_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    File('${tmp.path}/a.txt').writeAsStringSync('x');

    final mount = FilesystemMount(
      alias: 'workspaces',
      path: tmp.path,
      readOnly: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: MountFilesPage(mount: mount),
      ),
    );

    await pumpUntilFound(tester, find.text('a.txt'));
    expect(find.text('@workspaces'), findsOneWidget, reason: 'breadcrumb');
  });
}
