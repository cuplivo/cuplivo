import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/settings_provider.dart';
import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../theme/palettes.dart';
import '../../widgets/display_setting_rows.dart';
import '../../widgets/ios_settings_widgets.dart';
import 'chat_appearance_settings_page.dart';
import 'color_theme_settings_page.dart';
import 'behavior_settings_page.dart';
import 'font_settings_page.dart';

class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();

    String paletteName() {
      final palette = ThemePalettes.byId(sp.themePaletteId);
      final locale = Localizations.localeOf(context);
      return locale.languageCode == 'zh' &&
              (locale.scriptCode ?? '').toLowerCase() != 'hant'
          ? palette.displayNameZh
          : palette.displayNameEn;
    }

    return IosSettingsPage(
      title: l10n.newSettingsAppearanceTitle,
      subtitle: l10n.newSettingsAppearanceSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Palette,
              label: l10n.newSettingsColorThemeTitle,
              detailText: paletteName(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ColorThemeSettingsPage(),
                ),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.MessageCircleMore,
              label: l10n.newSettingsChatAppearanceTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ChatAppearanceSettingsPage(),
                ),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Vibrate,
              label: l10n.newSettingsBehaviorTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BehaviorSettingsPage()),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Type,
              label: l10n.newSettingsFontsTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FontSettingsPage()),
              ),
            ),
            IosSettingsDivider(context),
            const LanguageRow(),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
