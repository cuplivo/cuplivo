import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/settings_provider.dart';
import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../utils/platform_utils.dart';
import '../../widgets/display_setting_rows.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../display_settings_page.dart';

class ChatAppearanceSettingsPage extends StatelessWidget {
  const ChatAppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDesktop = PlatformUtils.isDesktopTargetSafe;
    final topicPos = context.select<SettingsProvider, DesktopTopicPosition>(
      (s) => s.desktopTopicPosition,
    );
    final showProvider = context.select<SettingsProvider, bool>(
      (s) => s.showProviderInModelCapsule,
    );
    final navButtonsMode = context
        .select<SettingsProvider, DesktopMessageNavButtonsMode>(
          (s) => s.desktopMessageNavButtonsMode,
        );

    return IosSettingsPage(
      title: l10n.newSettingsChatAppearanceTitle,
      subtitle: l10n.newSettingsChatAppearanceSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.MessageCircleMore,
              label: l10n.displaySettingsPageChatItemDisplayTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ChatItemDisplaySettingsPage(),
                ),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.TextInitial,
              label: l10n.displaySettingsPageRenderingSettingsTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const RenderingSettingsPage(),
                ),
              ),
            ),
            IosSettingsDivider(context),
            const ChatMessageBackgroundRow(),
            IosSettingsDivider(context),
            const ChatBackgroundMaskRow(),
            IosSettingsDivider(context),
            const ChatInputBackgroundOpacityRow(),
          ],
        ),
        if (isDesktop) ...[
          const SizedBox(height: 12),
          IosSettingsHeader(context, l10n.newSettingsDesktopOnlySection),
          IosSettingsSectionCard(
            children: [
              IosSettingsNavRow(
                context,
                icon: Lucide.panelLeft,
                label: l10n.desktopDisplaySettingsTopicPositionTitle,
                detailText: topicPos == DesktopTopicPosition.left
                    ? l10n.desktopDisplaySettingsTopicPositionLeft
                    : l10n.desktopDisplaySettingsTopicPositionRight,
                onTap: () => _showTopicPositionSheet(context),
              ),
              IosSettingsDivider(context),
              IosSettingsNavRow(
                context,
                icon: Lucide.ChevronsUpDown,
                label: l10n.displaySettingsPageMessageNavButtonsTitle,
                detailText: _navButtonsModeLabel(l10n, navButtonsMode),
                onTap: () => _showNavButtonsModeSheet(context),
              ),
              IosSettingsDivider(context),
              IosSettingsSwitchRow(
                label: l10n.desktopShowProviderInModelCapsule,
                value: showProvider,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setShowProviderInModelCapsule(v),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

Future<void> _showTopicPositionSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final selected = await showModalBottomSheet<DesktopTopicPosition>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IosSettingsSheetOption(
              ctx,
              icon: Lucide.panelLeft,
              label: l10n.desktopDisplaySettingsTopicPositionLeft,
              onTap: () => Navigator.of(ctx).pop(DesktopTopicPosition.left),
            ),
            IosSettingsSheetDivider(ctx),
            IosSettingsSheetOption(
              ctx,
              icon: Lucide.panelRight,
              label: l10n.desktopDisplaySettingsTopicPositionRight,
              onTap: () => Navigator.of(ctx).pop(DesktopTopicPosition.right),
            ),
          ],
        ),
      ),
    ),
  );
  if (selected == null) return;
  if (!context.mounted) return;
  await context.read<SettingsProvider>().setDesktopTopicPosition(selected);
}

String _navButtonsModeLabel(
  AppLocalizations l10n,
  DesktopMessageNavButtonsMode mode,
) {
  switch (mode) {
    case DesktopMessageNavButtonsMode.always:
      return l10n.displaySettingsPageMessageNavButtonsModeAlways;
    case DesktopMessageNavButtonsMode.scroll:
      return l10n.displaySettingsPageMessageNavButtonsModeScroll;
    case DesktopMessageNavButtonsMode.hover:
      return l10n.displaySettingsPageMessageNavButtonsModeHover;
    case DesktopMessageNavButtonsMode.scrollAndHover:
      return l10n.displaySettingsPageMessageNavButtonsModeScrollAndHover;
    case DesktopMessageNavButtonsMode.never:
      return l10n.displaySettingsPageMessageNavButtonsModeNever;
  }
}

Future<void> _showNavButtonsModeSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final modes = <DesktopMessageNavButtonsMode>[
    DesktopMessageNavButtonsMode.always,
    DesktopMessageNavButtonsMode.scroll,
    DesktopMessageNavButtonsMode.hover,
    DesktopMessageNavButtonsMode.scrollAndHover,
    DesktopMessageNavButtonsMode.never,
  ];
  final selected = await showModalBottomSheet<DesktopMessageNavButtonsMode>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in modes) ...[
              IosSettingsSheetOption(
                ctx,
                label: _navButtonsModeLabel(l10n, mode),
                onTap: () => Navigator.of(ctx).pop(mode),
              ),
              if (mode != modes.last) IosSettingsSheetDivider(ctx),
            ],
          ],
        ),
      ),
    ),
  );
  if (selected == null) return;
  if (!context.mounted) return;
  await context.read<SettingsProvider>().setDesktopMessageNavButtonsMode(
    selected,
  );
}
