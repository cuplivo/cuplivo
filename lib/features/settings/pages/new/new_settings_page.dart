import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/settings_provider.dart';
import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../utils/platform_utils.dart';
import '../../../../desktop/desktop_settings_page.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../../../assistant/pages/assistant_settings_page.dart';
import '../../../provider/pages/providers_page.dart';
import '../settings_page.dart';
import 'appearance_settings_page.dart';
import 'aux_model_settings_page.dart';
import 'cuplivo_settings_page.dart';
import 'data_settings_page.dart';
import 'more_tools_settings_page.dart';
import 'silly_tavern_settings_page.dart';

enum NewSettingsTarget { backup }

class NewSettingsPage extends StatefulWidget {
  const NewSettingsPage({super.key, this.initialTarget});

  final NewSettingsTarget? initialTarget;

  @override
  State<NewSettingsPage> createState() => _NewSettingsPageState();
}

class _NewSettingsPageState extends State<NewSettingsPage> {
  @override
  void initState() {
    super.initState();
    if (widget.initialTarget == NewSettingsTarget.backup) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const DataSettingsPage(autoOpenBackup: true),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final hasAnyActiveModel = context.select<SettingsProvider, bool>(
      (s) => s.hasAnyActiveModel,
    );

    return IosSettingsPage(
      title: l10n.settingsPageTitle,
      subtitle: l10n.newSettingsPageSubtitle,
      actions: const [_LegacySettingsAction()],
      children: [
        if (!hasAnyActiveModel)
          Material(
            color: cs.errorContainer.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Lucide.MessageCircleWarning, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.settingsPageWarningMessage,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        IosSettingsHeader(
          context,
          l10n.newSettingsSectionAssistant,
          first: true,
        ),
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Bot,
              label: l10n.newSettingsSectionAssistant,
              description: l10n.newSettingsAssistantDescription,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AssistantSettingsPage(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IosSettingsHeader(context, l10n.newSettingsSectionAppearance),
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Monitor,
              label: l10n.newSettingsSectionAppearance,
              description: l10n.newSettingsAppearanceDescription,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AppearanceSettingsPage(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IosSettingsHeader(context, l10n.newSettingsSectionProviders),
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Boxes,
              label: l10n.newSettingsSectionProviders,
              description: l10n.newSettingsProvidersDescription,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ProvidersPage())),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IosSettingsHeader(context, l10n.newSettingsSectionAuxModels),
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Heart,
              label: l10n.newSettingsSectionAuxModels,
              description: l10n.newSettingsAuxModelsDescription,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AuxModelSettingsPage()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IosSettingsHeader(context, l10n.newSettingsSectionSillyTavern),
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.BookOpen,
              label: l10n.newSettingsSectionSillyTavern,
              description: l10n.newSettingsSillyTavernDescription,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SillyTavernSettingsPage(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IosSettingsHeader(context, l10n.newSettingsSectionMoreTools),
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Wrench,
              label: l10n.newSettingsSectionMoreTools,
              description: l10n.newSettingsMoreToolsDescription,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const MoreToolsSettingsPage(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IosSettingsHeader(context, l10n.newSettingsSectionData),
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.Database,
              label: l10n.newSettingsSectionData,
              description: l10n.newSettingsDataDescription,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DataSettingsPage()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IosSettingsHeader(context, l10n.newSettingsSectionCuplivo),
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.BadgeInfo,
              label: l10n.newSettingsSectionCuplivo,
              description: l10n.newSettingsCuplivoDescription,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CuplivoSettingsPage()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _LegacySettingsAction extends StatelessWidget {
  const _LegacySettingsAction();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final textColor = cs.onSurface.withValues(alpha: 0.65);
    return Tooltip(
      message: l10n.newSettingsLegacyTooltip,
      child: Semantics(
        button: true,
        label: l10n.newSettingsLegacyEntry,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openLegacySettings(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.newSettingsLegacyEntry,
                  style: TextStyle(fontSize: 12, color: textColor),
                ),
                const SizedBox(width: 4),
                Icon(Lucide.Settings2, size: 16, color: textColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _openLegacySettings(BuildContext context) {
  if (PlatformUtils.isDesktopTargetSafe) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const DesktopSettingsPage(showLegacyBackButton: true),
      ),
    );
  } else {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }
}
