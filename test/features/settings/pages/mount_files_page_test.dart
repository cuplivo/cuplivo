import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import 'package:Cuplivo/features/settings/pages/mount_files_page.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/pages/html_file_preview_page.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      alias: 'default',
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
    expect(find.text('@default'), findsOneWidget, reason: 'root crumb');
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
      alias: 'default',
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
    expect(find.text('@default'), findsOneWidget, reason: 'breadcrumb');
  });

  testWidgets('mobile "open" on an html file routes to the in-app WebView '
      'preview instead of the system open', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('mount_page_test_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    File(
      '${tmp.path}/page.html',
    ).writeAsStringSync('<!doctype html><html><body>hello</body></html>');

    // IosCardPress reads SettingsProvider on tap; its constructor loads
    // shared_preferences, so the platform channel needs the in-memory mock.
    SharedPreferences.setMockInitialValues({});
    final mount = FilesystemMount(
      alias: 'default',
      path: tmp.path,
      readOnly: false,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: MountFilesPage(mount: mount),
        ),
      ),
    );

    await pumpUntilFound(tester, find.text('page.html'));
    // Mobile entry: actions fold into the "more" sheet.
    await tester.tap(find.byIcon(Lucide.Ellipsis));
    await pumpUntilFound(
      tester,
      find.text(
        AppLocalizations.of(
          tester.element(find.byType(MountFilesPage)),
        )!.mountFilesOpenButton,
      ),
    );
    // Let the sheet finish sliding in before tapping its action.
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(
        AppLocalizations.of(
          tester.element(find.byType(MountFilesPage)),
        )!.mountFilesOpenButton,
      ),
    );
    await pumpUntilFound(tester, find.byType(HtmlFilePreviewPage));
  });

  testWidgets('desktop shows the system-open entry for html files without '
      'routing into the in-app WebView', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final tmp = Directory.systemTemp.createTempSync('mount_page_test_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      File('${tmp.path}/page.html').writeAsStringSync('<html></html>');

      final mount = FilesystemMount(
        alias: 'default',
        path: tmp.path,
        readOnly: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: MountFilesPage(mount: mount),
        ),
      );

      await pumpUntilFound(tester, find.text('page.html'));
      // Desktop keeps the system default app: the row exposes the inline
      // external-open icon and never routes into the in-app WebView preview.
      // (Deliberately not tapped — OpenFilex's desktop branch spawns a real
      // OS process that would open the browser mid-test.)
      expect(find.byIcon(Lucide.ExternalLink), findsOneWidget);
      expect(find.byType(HtmlFilePreviewPage), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('directory selection hides files and returns canonical path', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final tmp = Directory.systemTemp.createTempSync('mount_picker_test_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    Directory('${tmp.path}/project').createSync();
    File('${tmp.path}/ignored.txt').writeAsStringSync('ignored');
    final mount = FilesystemMount(
      alias: 'default',
      path: tmp.path,
      readOnly: false,
    );
    String? selected;

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          MountFilesPage(mount: mount, selectDirectory: true),
                    ),
                  );
                },
                child: const Text('open picker'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open picker'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntilFound(tester, find.text('project'));
    expect(find.text('ignored.txt'), findsNothing);
    expect(find.text('/workspace'), findsOneWidget);
    await tester.tap(find.text('project'));
    await tester.pump();
    final pageL10n = AppLocalizations.of(
      tester.element(find.byType(MountFilesPage)),
    )!;
    await pumpUntilFound(tester, find.text(pageL10n.mountFilesEmptyDir));
    final l10n = AppLocalizations.of(
      tester.element(find.byType(MountFilesPage)),
    )!;
    await tester.tap(find.text(l10n.workspaceDirectorySelectCurrent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(selected, '/workspace/project');
  });
}
