import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/providers/settings_provider.dart';
import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../utils/platform_utils.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../about_page.dart';
import '../log_viewer_page.dart';
import '../sponsor_page.dart';
import 'log_settings_page.dart';

class CuplivoSettingsPage extends StatelessWidget {
  const CuplivoSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDesktop = PlatformUtils.isDesktopTargetSafe;
    final showLogs = context.select<SettingsProvider, bool>(
      (s) => s.requestLogEnabled || s.flutterLogEnabled,
    );
    return IosSettingsPage(
      title: l10n.newSettingsCuplivoTitle,
      subtitle: l10n.newSettingsCuplivoSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.BadgeInfo,
              label: l10n.settingsPageAbout,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const AboutPage())),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Library,
              label: l10n.settingsPageDocs,
              onTap: () async {
                final uri = Uri.parse('https://kelivo.psycheas.top/');
                if (!await launchUrl(uri, mode: LaunchMode.platformDefault)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Heart,
              label: l10n.settingsPageSponsor,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SponsorPage())),
            ),
            if (isDesktop) ...[
              IosSettingsDivider(context),
              IosSettingsNavRow(
                context,
                icon: Lucide.Settings2,
                label: l10n.newSettingsLogSettingsTitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LogSettingsPage()),
                ),
              ),
            ],
            if (showLogs) ...[
              IosSettingsDivider(context),
              IosSettingsNavRow(
                context,
                icon: Lucide.FileText,
                label: l10n.settingsPageLogs,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LogViewerPage()),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
