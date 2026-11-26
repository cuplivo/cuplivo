import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/segmented_tabs.dart';
import 'sync_panel_body.dart';
import 'tailcat_remote_panel.dart';

/// The sync settings surface, shared by the mobile page and the desktop pane:
/// a segmented switch between the local network panel (unchanged) and the
/// experimental remote sync panel.
///
/// Only the selected half is built. The remote panel starts this device's
/// remote listener the first time it is shown, and building it ahead of that
/// would make the LAN tab pay for a relay registration nobody asked for; the
/// LAN panel in turn counts as a viewer of the arrival toasts only while it is
/// the visible half.
class SyncModePanel extends StatefulWidget {
  const SyncModePanel({super.key});

  @override
  State<SyncModePanel> createState() => _SyncModePanelState();
}

class _SyncModePanelState extends State<SyncModePanel> {
  int _mode = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedTabs(
          tabs: [
            SegmentedTab(label: l10n.remoteSyncTabLan),
            SegmentedTab(label: l10n.remoteSyncTabRemote),
          ],
          index: _mode,
          // Both labels are closed sets the user compares; a slightly smaller
          // word stays a word, where an ellipsis would make the two tabs read
          // alike on a narrow phone.
          shrinkLabels: true,
          onChanged: (index) => setState(() => _mode = index),
        ),
        const SizedBox(height: 12),
        if (_mode == 0) const SyncPanelBody() else const TailcatRemotePanel(),
      ],
    );
  }
}
