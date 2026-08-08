import 'package:flutter/material.dart';

import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../utils/platform_utils.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../../../mcp/pages/mcp_page.dart';
import '../../../search/pages/search_services_page.dart';
import '../../../quick_phrase/pages/quick_phrases_page.dart';
import '../../../instruction_injection/pages/instruction_injection_page.dart';
import '../../../skills/pages/skills_page.dart';
import '../network_proxy_page.dart';

class MoreToolsSettingsPage extends StatelessWidget {
  const MoreToolsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDesktop = PlatformUtils.isDesktopTargetSafe;
    return IosSettingsPage(
      title: l10n.newSettingsMoreToolsTitle,
      subtitle: l10n.newSettingsMoreToolsSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Earth,
              label: l10n.settingsPageSearch,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SearchServicesPage()),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Terminal,
              label: l10n.settingsPageMcp,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const McpPage())),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Zap,
              label: l10n.settingsPageQuickPhrase,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const QuickPhrasesPage()),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Layers,
              label: l10n.settingsPageInstructionInjection,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const InstructionInjectionPage(),
                ),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.BookOpen,
              label: l10n.settingsPageSkills,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SkillsPage())),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.EthernetPort,
              label: l10n.settingsPageNetworkProxy,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NetworkProxyPage()),
              ),
            ),
            if (isDesktop) ...[
              IosSettingsDivider(context),
              IosComingSoonRow(
                context,
                icon: Lucide.Shield,
                label: l10n.newSettingsLinuxSandboxTitle,
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
