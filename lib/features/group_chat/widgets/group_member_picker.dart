import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../home/widgets/assistant_avatar.dart';

bool get _isDesktop =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Multi-select assistants for creating a group or adding members.
///
/// Returns selected assistant ids, or null if cancelled.
Future<List<String>?> showGroupMemberPicker(
  BuildContext context, {
  Set<String> excludeAssistantIds = const {},
  Set<String> initiallySelected = const {},
  int minSelection = 2,
}) async {
  final ap = context.read<AssistantProvider>();
  final assistants = ap.assistants
      .where((a) => !excludeAssistantIds.contains(a.id))
      .toList();

  if (_isDesktop && !kIsWeb) {
    List<String>? result;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.15),
      pageBuilder: (ctx, _, __) {
        return _GroupMemberPickerDialog(
          assistants: assistants,
          initiallySelected: initiallySelected,
          minSelection: minSelection,
          onConfirm: (ids) {
            result = ids;
            Navigator.of(ctx).maybePop();
          },
          onCancel: () => Navigator.of(ctx).maybePop(),
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
    return result;
  }

  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return _GroupMemberPickerSheet(
        assistants: assistants,
        initiallySelected: initiallySelected,
        minSelection: minSelection,
      );
    },
  );
}

class _GroupMemberPickerSheet extends StatefulWidget {
  const _GroupMemberPickerSheet({
    required this.assistants,
    required this.initiallySelected,
    required this.minSelection,
  });

  final List<Assistant> assistants;
  final Set<String> initiallySelected;
  final int minSelection;

  @override
  State<_GroupMemberPickerSheet> createState() =>
      _GroupMemberPickerSheetState();
}

class _GroupMemberPickerSheetState extends State<_GroupMemberPickerSheet> {
  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: _GroupMemberPickerContent(
          assistants: widget.assistants,
          initiallySelected: widget.initiallySelected,
          minSelection: widget.minSelection,
          onConfirm: (ids) => Navigator.of(context).pop(ids),
          onCancel: () => Navigator.of(context).maybePop(),
          desktop: false,
        ),
      ),
    );
  }
}

class _GroupMemberPickerDialog extends StatefulWidget {
  const _GroupMemberPickerDialog({
    required this.assistants,
    required this.initiallySelected,
    required this.minSelection,
    required this.onConfirm,
    required this.onCancel,
  });

  final List<Assistant> assistants;
  final Set<String> initiallySelected;
  final int minSelection;
  final ValueChanged<List<String>> onConfirm;
  final VoidCallback onCancel;

  @override
  State<_GroupMemberPickerDialog> createState() =>
      _GroupMemberPickerDialogState();
}

class _GroupMemberPickerDialogState extends State<_GroupMemberPickerDialog> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 520,
          minWidth: 400,
          maxHeight: 560,
        ),
        child: Material(
          color: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : cs.outlineVariant.withValues(alpha: 0.2),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: _GroupMemberPickerContent(
            assistants: widget.assistants,
            initiallySelected: widget.initiallySelected,
            minSelection: widget.minSelection,
            onConfirm: widget.onConfirm,
            onCancel: widget.onCancel,
            desktop: true,
          ),
        ),
      ),
    );
  }
}

class _GroupMemberPickerContent extends StatefulWidget {
  const _GroupMemberPickerContent({
    required this.assistants,
    required this.initiallySelected,
    required this.minSelection,
    required this.onConfirm,
    required this.onCancel,
    required this.desktop,
  });

  final List<Assistant> assistants;
  final Set<String> initiallySelected;
  final int minSelection;
  final ValueChanged<List<String>> onConfirm;
  final VoidCallback onCancel;
  final bool desktop;

  @override
  State<_GroupMemberPickerContent> createState() =>
      _GroupMemberPickerContentState();
}

class _GroupMemberPickerContentState extends State<_GroupMemberPickerContent> {
  late final Set<String> _selected = {...widget.initiallySelected};

  void _setSelected(String id, bool selected) {
    Haptics.soft();
    setState(() {
      if (selected) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final canConfirm = _selected.length >= widget.minSelection;
    final desktop = widget.desktop;

    return Column(
      mainAxisSize: desktop ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!desktop) ...[
          const SizedBox(height: 10),
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
        ],
        Padding(
          padding: EdgeInsets.fromLTRB(16, desktop ? 10 : 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.groupChatSelectMembersTitle,
                  textAlign: desktop ? TextAlign.start : TextAlign.center,
                  style: TextStyle(
                    fontSize: desktop ? 13.5 : 16,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
              if (desktop)
                IosIconButton(
                  icon: Lucide.X,
                  size: 18,
                  onTap: widget.onCancel,
                  semanticLabel: l10n.groupChatSettingsCancel,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            l10n.groupChatSelectMembersHint,
            textAlign: desktop ? TextAlign.start : TextAlign.center,
            style: TextStyle(
              fontSize: desktop ? 12 : 12.5,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: !desktop,
            padding: EdgeInsets.fromLTRB(
              desktop ? 10 : 12,
              0,
              desktop ? 10 : 12,
              desktop ? 10 : 8,
            ),
            itemCount: widget.assistants.length,
            itemBuilder: (context, index) {
              final assistant = widget.assistants[index];
              final checked = _selected.contains(assistant.id);
              return Padding(
                padding: EdgeInsets.only(bottom: desktop ? 4 : 6),
                child: IosCardPress(
                  borderRadius: BorderRadius.circular(desktop ? 12 : 14),
                  baseColor: checked
                      ? cs.primary.withValues(alpha: 0.08)
                      : desktop
                      ? Colors.transparent
                      : cs.surface,
                  onTap: () => _setSelected(assistant.id, !checked),
                  padding: EdgeInsets.symmetric(
                    horizontal: desktop ? 10 : 12,
                    vertical: desktop ? 8 : 10,
                  ),
                  child: Row(
                    children: [
                      AssistantAvatar(
                        assistant: assistant,
                        size: desktop ? 30 : 36,
                      ),
                      SizedBox(width: desktop ? 10 : 12),
                      Expanded(
                        child: Text(
                          assistant.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: desktop ? null : 15,
                            fontWeight: desktop ? null : AppFontWeights.medium,
                          ),
                        ),
                      ),
                      IosCheckbox(
                        value: checked,
                        onChanged: (value) => _setSelected(assistant.id, value),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, desktop ? 12 : 16),
          child: desktop
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: widget.onCancel,
                      child: Text(l10n.groupChatSettingsCancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: canConfirm
                          ? () => widget.onConfirm(_selected.toList())
                          : null,
                      child: Text(
                        l10n.groupChatSelectMembersConfirm(_selected.length),
                      ),
                    ),
                  ],
                )
              : SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: canConfirm
                        ? () => widget.onConfirm(_selected.toList())
                        : null,
                    child: Text(
                      l10n.groupChatSelectMembersConfirm(_selected.length),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
