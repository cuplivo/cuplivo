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
      barrierLabel: 'group-member-picker',
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
  late final Set<String> _selected = {...widget.initiallySelected};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    final canConfirm = _selected.length >= widget.minSelection;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                children: [
                  Text(
                    l10n.groupChatSelectMembersTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.groupChatSelectMembersHint,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                itemCount: widget.assistants.length,
                itemBuilder: (context, index) {
                  final a = widget.assistants[index];
                  final checked = _selected.contains(a.id);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: IosCardPress(
                      borderRadius: BorderRadius.circular(14),
                      baseColor: checked
                          ? cs.primary.withValues(alpha: 0.08)
                          : cs.surface,
                      onTap: () {
                        Haptics.soft();
                        setState(() {
                          if (checked) {
                            _selected.remove(a.id);
                          } else {
                            _selected.add(a.id);
                          }
                        });
                      },
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          AssistantAvatar(assistant: a, size: 36),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: AppFontWeights.medium,
                              ),
                            ),
                          ),
                          IosCheckbox(
                            value: checked,
                            onChanged: (v) {
                              setState(() {
                                if (v) {
                                  _selected.add(a.id);
                                } else {
                                  _selected.remove(a.id);
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: canConfirm
                      ? () => Navigator.of(context).pop(_selected.toList())
                      : null,
                  child: Text(
                    l10n.groupChatSelectMembersConfirm(_selected.length),
                  ),
                ),
              ),
            ),
          ],
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
  late final Set<String> _selected = {...widget.initiallySelected};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canConfirm = _selected.length >= widget.minSelection;

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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.groupChatSelectMembersTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ),
                      IosIconButton(
                        icon: Lucide.X,
                        size: 18,
                        onTap: widget.onCancel,
                        semanticLabel: l10n.groupChatSettingsCancel,
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  l10n.groupChatSelectMembersHint,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  itemCount: widget.assistants.length,
                  itemBuilder: (context, index) {
                    final a = widget.assistants[index];
                    final checked = _selected.contains(a.id);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: IosCardPress(
                        borderRadius: BorderRadius.circular(12),
                        baseColor: checked
                            ? cs.primary.withValues(alpha: 0.08)
                            : Colors.transparent,
                        onTap: () {
                          setState(() {
                            if (checked) {
                              _selected.remove(a.id);
                            } else {
                              _selected.add(a.id);
                            }
                          });
                        },
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            AssistantAvatar(assistant: a, size: 30),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                a.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IosCheckbox(
                              value: checked,
                              onChanged: (v) {
                                setState(() {
                                  if (v) {
                                    _selected.add(a.id);
                                  } else {
                                    _selected.remove(a.id);
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    const Spacer(),
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
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
