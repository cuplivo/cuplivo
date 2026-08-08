import 'package:flutter/material.dart';

import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../../../backup/pages/backup_page.dart';
import '../../../stats/pages/stats_page.dart';
import '../storage_space_page.dart';

class DataSettingsPage extends StatefulWidget {
  const DataSettingsPage({super.key, this.autoOpenBackup = false});

  /// Whether to auto-push [BackupPage] after the first frame.
  ///
  /// Route-only: the post-frame `Navigator.push` is only valid when this page
  /// is pushed as a standalone route, not embedded in another page. The
  /// callback also guards with `ModalRoute.of(context)?.isCurrent` so a stale
  /// frame (e.g. this route already covered by another push) never double-
  /// pushes.
  final bool autoOpenBackup;

  @override
  State<DataSettingsPage> createState() => _DataSettingsPageState();
}

class _DataSettingsPageState extends State<DataSettingsPage> {
  @override
  void initState() {
    super.initState();
    if (widget.autoOpenBackup) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ModalRoute.of(context)?.isCurrent != true) return;
        _openBackup();
      });
    }
  }

  void _openBackup() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const BackupPage()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IosSettingsPage(
      title: l10n.newSettingsDataTitle,
      subtitle: l10n.newSettingsDataSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Database,
              label: l10n.settingsPageBackup,
              onTap: _openBackup,
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.HardDrive,
              label: l10n.settingsPageChatStorage,
              detailBuilder: (_) => const ChatStorageSummaryDetail(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StorageSpacePage()),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.ChartColumnBig,
              label: l10n.settingsPageStatistics,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const StatsPage())),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
