import 'dart:io';

import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:flutter/foundation.dart';
import 'package:Cuplivo/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../test/support/e2e_app_seed.dart';

/// Shared setup for one acceptance scenario.
///
/// A scenario owns its navigation and screenshots; this helper only boots the
/// production entry point against a disposable, seeded database and enables
/// Android surface capture. Keeping the setup here keeps each scenario small
/// enough to run on its own when a PR changes it.
Future<void> bootSeededApp(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  String appLocale = 'en_US',
}) async {
  final root = await Directory.systemTemp.createTemp('cuplivo_e2e_');
  final originalPaths = PathProviderPlatform.instance;
  PathProviderPlatform.instance = E2eFixturePaths(root.path);
  addTearDown(() {
    PathProviderPlatform.instance = originalPaths;
  });
  await seedE2eDatabase(root, appLocale: appLocale);

  await app.main(const []);

  // Wait until the real home window has loaded the seeded conversation.
  final messageList = find.byType(MessageListView);
  MessageListView? view;
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (messageList.evaluate().isNotEmpty) {
      final candidate = tester.widget<MessageListView>(messageList.first);
      if (candidate.messages.isNotEmpty) {
        view = candidate;
        break;
      }
    }
  }
  expect(view, isNotNull);
  expect(view!.messages, isNotEmpty);
  // Startup finishes provider and draft warmups after the first visible
  // frame; start the scenario from a settled home.
  await pumpFrames(tester, frames: 30);
  expect(tester.takeException(), isNull);

  _e2eStartedAt = DateTime.now();

  if (Platform.isAndroid) {
    // Required before `takeScreenshot` on Android; the binding reverts the
    // surface in its teardown. See package:integration_test.
    await binding.convertFlutterSurfaceToImage();
    await pumpFrames(tester);
  }
}

DateTime? _e2eStartedAt;

/// Logs one scenario milestone with the elapsed wall clock.
///
/// The E2E job's log is the only place a timeout currently explains nothing
/// about where the run was; a milestone line makes the last reached step part
/// of the artifacts. Never logs a URL, token or any other credential.
void e2eStep(String message) {
  final startedAt = _e2eStartedAt;
  if (startedAt == null) {
    debugPrint('[dsh-e2e] $message');
    return;
  }
  final elapsed = DateTime.now().difference(startedAt).inSeconds;
  debugPrint('[dsh-e2e] +${elapsed}s $message');
}

/// Captures one acceptance screenshot after letting transient animation decay.
Future<void> capture(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
) async {
  e2eStep('capture $name');
  await pumpFrames(tester, frames: 20);
  await binding.takeScreenshot(name);
  e2eStep('captured $name');
}

Future<void> pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required int maxFrames,
}) async {
  for (var i = 0; i < maxFrames && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
