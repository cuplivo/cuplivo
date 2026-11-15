import 'package:flutter/material.dart';

import '../../features/sync/widgets/sync_panel_body.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';

/// Desktop LAN sync pane. Same panel as the mobile page — only the chrome
/// differs (pane container instead of Scaffold, dialogs instead of sheets).
class DesktopSyncPane extends StatelessWidget {
  const DesktopSyncPane({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            children: [
              SizedBox(
                height: 36,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.settingsPageLanSync,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: AppFontWeights.regular,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const SyncPanelBody(),
            ],
          ),
        ),
      ),
    );
  }
}
