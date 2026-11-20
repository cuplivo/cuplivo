import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/chat/widgets/tools_sheet_row.dart';
import 'package:Cuplivo/features/settings/widgets/custom_theme_widgets.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// Opens the slash-command list the Host advertises (`commands/list`).
///
/// Returns the picked command, or null when dismissed. The composer decides
/// whether to insert the command text (command expects input) or run it
/// immediately.
Future<DshSlashCommand?> showDshSlashCommandsSheet(
  BuildContext context, {
  required List<DshSlashCommand> commands,
}) {
  if (commands.isEmpty) return Future<DshSlashCommand?>.value(null);
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (isDesktop) {
    return showAppDialog<DshSlashCommand>(
      context,
      child: _DshSlashCommandsView(commands: commands),
    );
  }
  return showModalBottomSheet<DshSlashCommand>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      top: false,
      child: _DshSlashCommandsView(
        commands: commands,
        onClose: () => Navigator.of(sheetContext).maybePop(),
      ),
    ),
  );
}

class _DshSlashCommandsView extends StatelessWidget {
  const _DshSlashCommandsView({required this.commands, this.onClose});

  final List<DshSlashCommand> commands;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final body = Column(
      key: const ValueKey<String>('dsh-slash-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onClose != null) ...[
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        Padding(
          padding: EdgeInsets.fromLTRB(18, onClose == null ? 16 : 0, 18, 6),
          child: Text(
            l10n.dshSlashCommandsTitle,
            style: TextStyle(fontSize: 17, fontWeight: AppFontWeights.emphasis),
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            children: [
              for (final command in commands)
                _DshSlashCommandRow(
                  key: ValueKey<String>('dsh-slash-command-${command.name}'),
                  command: command,
                  onTap: () => Navigator.of(context).pop(command),
                ),
            ],
          ),
        ),
      ],
    );
    if (onClose == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: body,
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      child: body,
    );
  }
}

class _DshSlashCommandRow extends StatelessWidget {
  const _DshSlashCommandRow({
    super.key,
    required this.command,
    required this.onTap,
  });

  final DshSlashCommand command;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hint = (command.inputHint ?? '').trim();
    final description = (command.description ?? '').trim();
    final detail = hint.isNotEmpty
        ? '$description · $hint'.trim()
        : description.isEmpty
        ? null
        : description;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: IosCardPress(
        borderRadius: BorderRadius.circular(14),
        baseColor: sheetTileColor(context),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        onTap: onTap,
        child: SizedBox(
          height: detail == null ? 48 : 60,
          child: Row(
            children: [
              Icon(
                Lucide.Terminal,
                size: 20,
                color: cs.onSurface.withValues(alpha: 0.72),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '/${command.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: AppFontWeights.medium,
                      ),
                    ),
                    if (detail != null && detail.isNotEmpty)
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Lucide.ChevronRight,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
