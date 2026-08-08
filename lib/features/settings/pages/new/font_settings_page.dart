import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../widgets/display_setting_rows.dart';
import '../../widgets/ios_settings_widgets.dart';

class FontSettingsPage extends StatelessWidget {
  const FontSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IosSettingsPage(
      title: l10n.newSettingsFontsTitle,
      subtitle: l10n.newSettingsFontsSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            const AppFontRow(),
            IosSettingsDivider(context),
            const CodeFontRow(),
            IosSettingsDivider(context),
            const ChatFontSizeRow(),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
