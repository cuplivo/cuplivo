import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/settings_provider.dart';
import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../theme/palettes.dart';
import '../../widgets/display_setting_rows.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../theme_settings_page.dart';

class ColorThemeSettingsPage extends StatelessWidget {
  const ColorThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final themePaletteId = context.select<SettingsProvider, String>(
      (s) => s.themePaletteId,
    );

    String paletteName() {
      final palette = ThemePalettes.byId(themePaletteId);
      final locale = Localizations.localeOf(context);
      return locale.languageCode == 'zh' &&
              (locale.scriptCode ?? '').toLowerCase() != 'hant'
          ? palette.displayNameZh
          : palette.displayNameEn;
    }

    return IosSettingsPage(
      title: l10n.newSettingsColorThemeTitle,
      subtitle: l10n.newSettingsColorThemeSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            const ThemeModeRow(),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Palette,
              label: l10n.displaySettingsPageThemeSettingsTitle,
              detailText: paletteName(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ThemeSettingsPage()),
              ),
            ),
            IosSettingsDivider(context),
            IosComingSoonRow(
              context,
              icon: Lucide.Download,
              label: l10n.newSettingsImportAppThemeTitle,
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
