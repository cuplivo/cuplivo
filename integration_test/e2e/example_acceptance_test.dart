import 'package:Cuplivo/features/home/pages/home_mobile_layout.dart';
import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/features/settings/pages/settings_page.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'acceptance_support.dart';

/// A one-shot reference scenario for the incremental Android E2E harness.
///
/// This is intentionally small: it boots the seeded production app, opens one
/// surface, asserts it, and captures one screenshot. It is not a regression
/// baseline and it is not run unless this file changes. A UI PR should add its
/// own `integration_test/e2e/<name>_test.dart` started from this shape.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('example acceptance scenario captures the settings surface', (
    tester,
  ) async {
    await bootSeededApp(tester, binding);

    final home = tester.widget<HomeMobileScaffold>(
      find.byType(HomeMobileScaffold),
    );
    home.drawerController.jumpTo(1.0);
    await pumpFrames(tester);
    expect(find.byType(SideDrawer), findsOneWidget);

    final settingsButton = find.descendant(
      of: find.byType(SideDrawer),
      matching: find.byIcon(Lucide.Settings),
    );
    expect(settingsButton, findsOneWidget);
    await tester.tap(settingsButton);
    await pumpUntil(
      tester,
      () => find.byType(SettingsPage).evaluate().isNotEmpty,
      maxFrames: 100,
    );
    expect(find.byType(SettingsPage), findsOneWidget);

    await capture(tester, binding, 'settings_surface');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
