import 'package:flutter/material.dart';

import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../../../model/pages/default_model_page.dart';
import '../tts_services_page.dart';

class AuxModelSettingsPage extends StatelessWidget {
  const AuxModelSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IosSettingsPage(
      title: l10n.newSettingsAuxModelsTitle,
      subtitle: l10n.newSettingsAuxModelsSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Heart,
              label: l10n.settingsPageDefaultModel,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DefaultModelPage()),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Volume2,
              label: l10n.newSettingsTtsModelTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TtsServicesPage()),
              ),
            ),
            IosSettingsDivider(context),
            IosComingSoonRow(
              context,
              icon: Lucide.AudioWaveform,
              label: l10n.newSettingsAsrModelTitle,
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
