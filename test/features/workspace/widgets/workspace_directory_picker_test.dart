import 'dart:io';

import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/features/settings/pages/mount_files_page.dart';
import 'package:Cuplivo/features/workspace/widgets/workspace_directory_picker.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tablet opens the directory picker in a constrained dialog', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('cuplivo_picker_');
    final originalPlatform = debugDefaultTargetPlatformOverride;
    final originalPathProvider = PathProviderPlatform.instance;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = originalPlatform;
      PathProviderPlatform.instance = originalPathProvider;
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final workspaces = WorkspaceProvider();
    final workspace = Workspace(
      id: 'tablet-workspace',
      displayName: 'Tablet',
      alias: 'tablet',
      customHostPath: temp.path,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showWorkspaceDirectoryPicker(
              context,
              workspace: workspace,
              workspaces: workspaces,
              initialDirectory: '/workspace',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(MountFilesPage), findsOneWidget);

    Navigator.of(tester.element(find.byType(MountFilesPage))).pop();
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = originalPlatform;
  });
}
