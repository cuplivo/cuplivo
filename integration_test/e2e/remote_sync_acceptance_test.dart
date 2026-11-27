import 'package:Cuplivo/features/home/pages/home_mobile_layout.dart';
import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/features/settings/pages/settings_page.dart';
import 'package:Cuplivo/features/sync/widgets/sync_mode_panel.dart';
import 'package:Cuplivo/features/sync/widgets/tailcat_remote_panel.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'acceptance_support.dart';

/// Acceptance scenario for the Convenient Sync page (ADR-0021): the renamed
/// entry opens a page whose segments switch between the untouched LAN panel and
/// the new remote panel.
///
/// Deliberately not a pairing walk: the remote listener starts on tab
/// visibility and needs the network, so the scenario asserts what the reviewer
/// is reviewing — the entry, the tabs and the remote panel's sections — rather
/// than a tunnel that would make the run depend on a relay.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('convenient sync opens the LAN and remote panels', (
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

    // The renamed entry itself is part of the change under review. It sits in
    // the Data section, below the first screenful, so the scenario scrolls to
    // it the way a user does instead of assuming a lazy list built it.
    final syncEntry = find.text('Convenient Sync');
    await tester.scrollUntilVisible(
      syncEntry,
      250,
      scrollable: find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 40,
    );
    // Building and being visible are different: the lazy list builds a
    // cache-extent beyond the viewport, and scrolling stops at the first built
    // frame. Bring the row into the viewport before tapping it.
    await tester.ensureVisible(syncEntry);
    await pumpFrames(tester);
    expect(syncEntry, findsOneWidget);
    await tester.tap(syncEntry);
    await pumpUntil(
      tester,
      () => find.byType(SyncModePanel).evaluate().isNotEmpty,
      maxFrames: 100,
    );
    expect(find.byType(SyncModePanel), findsOneWidget);
    // LAN is the default half: the LAN panel is what a user lands on.
    expect(find.text('LAN Sync'), findsOneWidget);
    expect(find.text('Remote Sync (Experimental)'), findsOneWidget);
    await capture(tester, binding, 'convenient_sync_lan');

    await tester.tap(find.text('Remote Sync (Experimental)'));
    await pumpUntil(
      tester,
      () => find.byType(TailcatRemotePanel).evaluate().isNotEmpty,
      maxFrames: 100,
    );
    expect(find.byType(TailcatRemotePanel), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    await capture(tester, binding, 'convenient_sync_remote');

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
