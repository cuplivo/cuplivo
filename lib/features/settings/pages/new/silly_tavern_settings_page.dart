import 'package:flutter/material.dart';

import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../../../world_book/pages/world_book_page.dart';

class SillyTavernSettingsPage extends StatelessWidget {
  const SillyTavernSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IosSettingsPage(
      title: l10n.newSettingsSillyTavernTitle,
      subtitle: l10n.newSettingsSillyTavernSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.BookOpen,
              label: l10n.settingsPageWorldBook,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const WorldBookPage())),
            ),
            IosSettingsDivider(context),
            IosComingSoonRow(
              context,
              icon: Lucide.TextSelect,
              label: l10n.newSettingsAdvancedRegexTitle,
            ),
            IosSettingsDivider(context),
            IosComingSoonRow(
              context,
              icon: Lucide.Shapes,
              label: l10n.newSettingsSillyTavernPluginCompatTitle,
            ),
            IosSettingsDivider(context),
            IosComingSoonRow(
              context,
              icon: Lucide.GripHorizontal,
              label: l10n.newSettingsSillyTavernPresetCompatTitle,
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
