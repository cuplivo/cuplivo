import 'package:flutter/material.dart';

import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/ios_settings_rows.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../../../theme/app_font_weights.dart';
import '../../state/dsh_gateway_models.dart';
import 'dsh_settings_tabs.dart';

/// 内置插件 tab: the Host's plugin inventory, read-only.
///
/// The gateway has no management methods yet, so the body never renders a dead
/// switch: it shows what the Host reports (title, module name, enabled state,
/// Loader phase and diagnostics) and says so in one sentence.
class DshPluginsTabBody extends StatelessWidget {
  const DshPluginsTabBody({
    super.key,
    required this.plugins,
    this.onOpenOfficialSettings,
  });

  final List<DshPluginEntry> plugins;

  /// Opens the Host's own settings dialog once so Cuplivo can learn which
  /// plugin-registered sections exist. Null in create mode, where there is no
  /// remote to visit yet.
  final VoidCallback? onOpenOfficialSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (onOpenOfficialSettings != null) ...[
          SectionCard(
            children: [
              IosNavRow(
                key: const ValueKey<String>('dsh-settings-open-official'),
                icon: Lucide.Settings,
                label: l10n.dshPluginPanelTitle,
                subtitle: l10n.dshPluginsReadOnly,
                onTap: onOpenOfficialSettings,
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        _DshSettingsNoteCard(text: l10n.dshPluginsReadOnly),
        const SizedBox(height: 12),
        if (plugins.isEmpty)
          _DshSettingsEmptyState(
            icon: Lucide.Package,
            text: l10n.dshPluginsEmpty,
          )
        else
          SectionCard(
            children: [
              for (var i = 0; i < plugins.length; i++) ...[
                if (i > 0) const IosRowDivider(),
                _DshPluginRow(plugin: plugins[i]),
              ],
            ],
          ),
      ],
    );
  }
}

class _DshPluginRow extends StatelessWidget {
  const _DshPluginRow({required this.plugin});

  final DshPluginEntry plugin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final title = dshSettingsLocalizedPluginTitle(
      context,
      titles: plugin.localizedTitle,
      fallback: plugin.title,
    );
    final caption = <String>[
      if (plugin.phase != null) l10n.dshPluginsPhase(plugin.phase!),
      if (plugin.diagnostic != null) plugin.diagnostic!,
    ].join(' · ');
    return IosNavRow(
      icon: Lucide.Package,
      label: title,
      subtitle: plugin.moduleName.isEmpty ? null : plugin.moduleName,
      caption: caption.isEmpty ? null : caption,
      detailText: plugin.enabled
          ? l10n.dshPluginsEnabled
          : l10n.dshPluginsDisabled,
      trailing: plugin.enabled
          ? null
          : Icon(
              Lucide.CircleAlert,
              size: 16,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
    );
  }
}

/// Agent 预设 tab: the compositions `pluginInventory/list` reports, read-only.
///
/// The `agentPresets/*` RPCs are not in the core client yet, so this body lists
/// the groups and their plugin rows without a select action.
class DshAgentPresetsTabBody extends StatelessWidget {
  const DshAgentPresetsTabBody({super.key, required this.groups});

  final List<DshAgentPresetGroup> groups;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _DshSettingsNoteCard(text: l10n.dshAgentPresetsReadOnly),
        const SizedBox(height: 12),
        if (groups.isEmpty)
          _DshSettingsEmptyState(
            icon: Lucide.Bot,
            text: l10n.dshAgentPresetsEmpty,
          )
        else
          for (final group in groups) ...[
            _DshAgentPresetCard(group: group),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

class _DshAgentPresetCard extends StatelessWidget {
  const _DshAgentPresetCard({required this.group});

  final DshAgentPresetGroup group;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final name = (group.name ?? '').trim();
    return SectionCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name.isEmpty ? group.id : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
              if (group.isDefault) ...[
                const SizedBox(width: 8),
                _DshPresetBadge(label: l10n.dshAgentPresetsDefault),
              ],
            ],
          ),
          if (group.broken != null) ...[
            const SizedBox(height: 8),
            Text(
              group.broken!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                color: cs.error.withValues(alpha: 0.9),
              ),
            ),
          ],
          if (group.plugins.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final plugin in group.plugins)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _DshPresetPluginRow(plugin: plugin),
              ),
          ],
        ],
      ),
    );
  }
}

class _DshPresetPluginRow extends StatelessWidget {
  const _DshPresetPluginRow({required this.plugin});

  final DshAgentPresetPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final title = dshSettingsLocalizedPluginTitle(
      context,
      titles: plugin.localizedTitle,
      fallback: plugin.title ?? plugin.moduleName,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '• ',
          style: TextStyle(
            fontSize: 13,
            height: 1.35,
            color: cs.onSurface.withValues(alpha: 0.45),
          ),
        ),
        Expanded(
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: cs.onSurface.withValues(
                alpha: plugin.enabled ? 0.8 : 0.45,
              ),
            ),
          ),
        ),
        if (!plugin.enabled)
          Text(
            l10n.dshPluginsDisabled,
            style: TextStyle(
              fontSize: 11.5,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ),
      ],
    );
  }
}

class _DshSettingsNoteCard extends StatelessWidget {
  const _DshSettingsNoteCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Lucide.BadgeInfo,
            size: 18,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.3,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DshSettingsEmptyState extends StatelessWidget {
  const _DshSettingsEmptyState({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Column(
        children: [
          Icon(icon, size: 28, color: cs.onSurface.withValues(alpha: 0.35)),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _DshPresetBadge extends StatelessWidget {
  const _DshPresetBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: AppFontWeights.medium,
          color: cs.primary,
        ),
      ),
    );
  }
}
