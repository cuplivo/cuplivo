import 'package:flutter/material.dart';

import '../../../core/models/workspace.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_expandable_section.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../theme/app_font_weights.dart';

class WorkspaceTerminalPersistenceSection extends StatelessWidget {
  const WorkspaceTerminalPersistenceSection({
    super.key,
    required this.workspace,
    required this.expanded,
    required this.busy,
    required this.onToggle,
    required this.onKeepChanged,
    required this.onDurableChanged,
    required this.onAutoStartChanged,
  });

  final Workspace workspace;
  final bool expanded;
  final bool busy;
  final VoidCallback onToggle;
  final ValueChanged<bool> onKeepChanged;
  final ValueChanged<bool> onDurableChanged;
  final ValueChanged<bool> onAutoStartChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final childrenEnabled = workspace.keepTerminalAfterExit && !busy;
    return IosExpandableSection(
      key: const ValueKey<String>('workspace-terminal-persistence-section'),
      icon: Lucide.Terminal,
      title: l10n.workspaceTerminalPersistenceSettings,
      expanded: expanded,
      onToggle: onToggle,
      showDivider: true,
      children: <Widget>[
        _TerminalSettingRow(
          key: const ValueKey<String>('workspace-terminal-keep-row'),
          title: l10n.workspaceKeepTerminalAfterExit,
          description: l10n.workspaceKeepTerminalAfterExitDescription,
          value: workspace.keepTerminalAfterExit,
          onChanged: busy ? null : onKeepChanged,
        ),
        _TerminalSettingRow(
          key: const ValueKey<String>('workspace-terminal-durable-row'),
          title: l10n.workspaceTerminalPersistentKeepAlive,
          description: l10n.workspaceTerminalPersistentKeepAliveDescription,
          value: workspace.terminalPersistentKeepAlive,
          onChanged: childrenEnabled ? onDurableChanged : null,
        ),
        _TerminalSettingRow(
          key: const ValueKey<String>('workspace-terminal-auto-start-row'),
          title: l10n.workspaceAutoStartLinuxSandbox,
          description: l10n.workspaceAutoStartLinuxSandboxDescription,
          value: workspace.autoStartLinuxSandbox,
          onChanged: childrenEnabled ? onAutoStartChanged : null,
        ),
      ],
    );
  }
}

class _TerminalSettingRow extends StatelessWidget {
  const _TerminalSettingRow({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final titleColor = colors.onSurface.withValues(alpha: enabled ? 0.9 : 0.45);
    final descriptionColor = colors.onSurface.withValues(
      alpha: enabled ? 0.62 : 0.35,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: descriptionColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          IosSwitch(value: value, semanticLabel: title, onChanged: onChanged),
        ],
      ),
    );
  }
}
