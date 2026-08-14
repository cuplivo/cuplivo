import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/workspace/pages/sandbox_files_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/pages/file_preview_page.dart';

/// The page loads its listing via real dart:io streams; each stream event is
/// delivered on the real event loop, so pump+runAsync must cycle until the
/// listing lands. A page-level exception surfaces as the real cause instead
/// of a masked "timed out" message.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final error = tester.takeException();
    if (error != null) fail('Page threw during listing: $error');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}

Directory _sandboxTree() {
  final tmp = Directory.systemTemp.createTempSync('sandbox_page_test_');
  final root = Directory('${tmp.path}/data');
  root.createSync(recursive: true);
  Directory('${root.path}/usr/bin').createSync(recursive: true);
  File('${root.path}/usr/bin/python3').writeAsStringSync('#!/bin/sh\n');
  Directory('${root.path}/root').createSync();
  File('${root.path}/root/.bashrc').writeAsStringSync('export PATH=/usr/bin\n');
  File('${root.path}/.profile').writeAsStringSync('export EDITOR=vi\n');
  File('${root.path}/etc_hosts').writeAsStringSync('127.0.0.1 localhost');
  // Usrmerge-style symlink: a rootfs's /bin usually IS a link to usr/bin.
  Link('${root.path}/bin').createSync('usr/bin');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  return root;
}

void main() {
  testWidgets('lists entries with guest-style root breadcrumb and shows '
      'dotfiles (system viewer)', (tester) async {
    final root = _sandboxTree();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: SandboxFilesPage(rootHostPath: root.path),
      ),
    );

    await pumpUntilFound(tester, find.text('usr'));
    expect(find.text('usr'), findsOneWidget);
    expect(find.text('root'), findsOneWidget);
    // Symlink to a directory (usrmerge-style /bin) resolves to a
    // navigable directory instead of being dropped from the listing.
    expect(find.text('bin'), findsOneWidget);
    // Dotfiles are ALWAYS visible — the point of a system-directory viewer.
    await pumpUntilFound(tester, find.text('.profile'));
    expect(find.text('.profile'), findsOneWidget);
    // Root breadcrumb uses guest addressing: `/`, not the host path.
    expect(find.text('/'), findsOneWidget);
    expect(find.text(root.path), findsNothing);

    // Navigate into usr → bin → preview a file on tap.
    await tester.tap(find.text('usr'));
    await pumpUntilFound(tester, find.text('bin'));
    await tester.tap(find.text('bin'));
    await pumpUntilFound(tester, find.text('python3'));
    expect(find.text('python3'), findsOneWidget);

    await tester.tap(find.text('python3'));
    await pumpUntilFound(tester, find.byType(FilePreviewPage));
    // The preview page's AppBar carries the file name; scope the assertion
    // to the page so a stale list row cannot satisfy it.
    expect(
      find.descendant(
        of: find.byType(FilePreviewPage),
        matching: find.text('python3'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('empty directory keeps the breadcrumb so the user can step '
      'back to the root', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('sandbox_empty_test_');
    final root = Directory('${tmp.path}/data');
    root.createSync(recursive: true);
    Directory('${root.path}/empty').createSync();
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: SandboxFilesPage(rootHostPath: root.path),
      ),
    );

    await pumpUntilFound(tester, find.text('empty'));
    await tester.tap(find.text('empty'));

    final l10n = AppLocalizations.of(
      tester.element(find.byType(SandboxFilesPage)),
    )!;
    await pumpUntilFound(tester, find.text(l10n.mountFilesEmptyDir));
    expect(find.text('/'), findsOneWidget, reason: 'root crumb stays');

    // Step back up via the breadcrumb.
    await tester.tap(find.text('/'));
    await pumpUntilFound(tester, find.text('empty'));
    expect(find.text('empty'), findsOneWidget);
  });

  testWidgets('missing root directory degrades to the empty state without '
      'a snackbar crash', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('sandbox_missing_');
    final missing = Directory('${tmp.path}/nope');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: SandboxFilesPage(rootHostPath: missing.path),
      ),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(SandboxFilesPage)),
    )!;
    await pumpUntilFound(tester, find.text(l10n.mountFilesEmptyDir));
    expect(find.text('/'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
