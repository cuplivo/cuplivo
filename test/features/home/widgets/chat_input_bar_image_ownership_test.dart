// Draft ownership of the stored copies the composer created: which ones a draft
// may release when an attachment leaves it, and which ones it must leave alone
// because a persisted message may already reference them.
import 'dart:io';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/utils/image_compressor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/business_test_harness.dart';

const _config = ImageCompressConfig(
  enabled: true,
  quality: 80,
  maxLongEdge: 1024,
  includeTransparent: false,
);

void main() {
  late PathProviderPlatform previousPathProvider;
  late Directory appSupportDir;
  late Directory userDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previousPathProvider = PathProviderPlatform.instance;
    appSupportDir = await Directory.systemTemp.createTemp('kelivo_owned_app_');
    userDir = await Directory.systemTemp.createTemp('kelivo_owned_user_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(
      appSupportDir.path,
    );
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    await _forceDelete(appSupportDir);
    await _forceDelete(userDir);
  });

  Future<File> writeUserImage(String name, {int byteCount = 256}) async {
    final file = File('${userDir.path}/$name');
    await file.writeAsBytes(List<int>.filled(byteCount, 7), flush: true);
    return file;
  }

  Future<bool> fileExists(WidgetTester tester, File file) async {
    final result = await tester.runAsync(() => file.exists());
    return result ?? false;
  }

  Future<bool> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return condition();
    });
    return result ?? false;
  }

  Widget buildHarness({
    required TextEditingController controller,
    required FocusNode focusNode,
    required ChatInputBarController mediaController,
    required Future<ChatInputSubmissionResult> Function(ChatInputData input)
    onSend,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(
          value: SettingsProvider(createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider.value(
          value: AssistantProvider(
            preferences: createBusinessTestPreferences(),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            focusNode: focusNode,
            mediaController: mediaController,
            onSend: onSend,
          ),
        ),
      ),
    );
  }

  testWidgets('移除 chip 会回收自有副本', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final mediaController = ChatInputBarController();

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        focusNode: focusNode,
        mediaController: mediaController,
        onSend: (_) async => ChatInputSubmissionResult.rejected,
      ),
    );

    late File source;
    await tester.runAsync(() async {
      source = await writeUserImage('owned_user.png');
      mediaController.enqueueImages(
        [source.path],
        _config,
        deleteSourcesAfterProcessing: false,
      );
    });
    expect(
      await pumpUntil(tester, () => !mediaController.hasUnreadyImages),
      isTrue,
      reason: 'image processing did not finish in time',
    );
    final stored = File(mediaController.snapshotInput('').imagePaths.single);
    expect(await fileExists(tester, stored), isTrue);

    // The draft created this copy and never sent it, so dropping the attachment
    // releases the file; the user's own source is never touched.
    await tester.runAsync(() async {
      mediaController.clearImages();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    expect(await fileExists(tester, stored), isFalse);
    expect(await fileExists(tester, source), isTrue);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('被拒绝的发送不再持有副本', (tester) async {
    final controller = TextEditingController(text: 'with image');
    final focusNode = FocusNode();
    final mediaController = ChatInputBarController();

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        focusNode: focusNode,
        mediaController: mediaController,
        onSend: (_) async => ChatInputSubmissionResult.rejected,
      ),
    );

    late File source;
    await tester.runAsync(() async {
      source = await writeUserImage('rejected_user.png');
      mediaController.enqueueImages(
        [source.path],
        _config,
        deleteSourcesAfterProcessing: false,
      );
    });
    expect(
      await pumpUntil(tester, () => !mediaController.hasUnreadyImages),
      isTrue,
      reason: 'image processing did not finish in time',
    );
    final stored = File(mediaController.snapshotInput('').imagePaths.single);
    expect(await fileExists(tester, stored), isTrue);

    // A rejected submission may already have persisted the message (temporary
    // conversations write it before generation starts), so the restored draft
    // must stop claiming the stored copy.
    await tester.tap(find.byIcon(Lucide.ArrowUp));
    await tester.pumpAndSettle();
    expect(mediaController.snapshotInput('').imagePaths, isNotEmpty);

    await tester.runAsync(() async {
      mediaController.clearImages();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    expect(await fileExists(tester, stored), isTrue);

    controller.dispose();
    focusNode.dispose();
  });
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

Future<void> _forceDelete(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {}
}
