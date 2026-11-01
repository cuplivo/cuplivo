import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../../../icons/lucide_adapter.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../home/controllers/chat_actions.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/chat_owners_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../shared/widgets/action_sheet.dart';
import '../../group_chat/group_navigation.dart';
import '../../group_chat/widgets/group_member_list.dart';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'assistant_settings_edit_page.dart';
import '../../../utils/avatar_cache.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../core/services/haptics.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// Settings › 助手与群聊: assistants and groups in one list, in one order.
///
/// The sidebar and this page share [ChatOwnersProvider], so a drag here moves
/// the same row there. They also share one "+": assistants used to be created
/// here and groups in the sidebar, which is why reordering felt arbitrary.
class ChatOwnerSettingsPage extends StatelessWidget {
  const ChatOwnerSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final assistants = {
      for (final assistant in context.watch<AssistantProvider>().assistants)
        assistant.id: assistant,
    };
    final groups = {
      for (final group in context.watch<GroupChatProvider>().groups)
        group.id: group,
    };
    // The order provider reconciles with the live sources, so a row whose
    // owner is gone is skipped rather than rendered as a hole.
    final rows = [
      for (final owner in context.watch<ChatOwnersProvider>().owners)
        if (owner.isGroup
            ? groups.containsKey(owner.id)
            : assistants.containsKey(owner.id))
          owner,
    ];

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.settingsPageChatOwners),
        actions: [
          Tooltip(
            message: l10n.settingsPageChatOwnersCreate,
            child: _TactileIconButton(
              icon: Lucide.Plus,
              color: cs.onSurface,
              size: 22,
              onTap: () => _showCreateMenu(context),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
        itemCount: rows.length,
        onReorderItem: (oldIndex, newIndex) async {
          await context.read<ChatOwnersProvider>().reorder(oldIndex, newIndex);
        },
        proxyDecorator: (child, index, animation) {
          return AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final t = Curves.easeOutBack.transform(animation.value);
              return Transform.scale(
                scale: 0.98 + 0.02 * t,
                child: Material(
                  elevation: 0, // remove drag shadow
                  shadowColor: Colors.transparent,
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  child: child,
                ),
              );
            },
          );
        },
        itemBuilder: (context, index) {
          final owner = rows[index];
          final group = owner.isGroup ? groups[owner.id] : null;
          return KeyedSubtree(
            key: ValueKey('owner-${owner.key}'),
            child: ReorderableDelayedDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: group != null
                    ? _GroupCard(group: group, assistants: assistants)
                    : _AssistantCard(item: assistants[owner.id]!),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showCreateMenu(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await showAdaptiveActionMenu(
      context,
      items: [
        ActionSheetItem(
          icon: Lucide.UserPlus,
          label: l10n.chatOwnerCreateAssistant,
          onTap: () => _createAssistant(context),
        ),
        ActionSheetItem(
          icon: Lucide.Users,
          label: l10n.groupChatCreate,
          onTap: () => _createGroup(context),
        ),
      ],
    );
  }

  Future<void> _createAssistant(BuildContext context) async {
    final assistantProvider = context.read<AssistantProvider>();
    final navigator = Navigator.of(context);
    final name = await _showAddAssistantSheet(context);
    if (name == null || !context.mounted) return;
    final id = await assistantProvider.addAssistant(
      name: name.trim(),
      context: context,
    );
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => AssistantSettingsEditPage(assistantId: id),
      ),
    );
  }

  Future<void> _createGroup(BuildContext context) async {
    final group = await showGroupCreate(context);
    if (group == null || !context.mounted) return;
    await showGroupSettings(context, group.id);
  }
}

class _AssistantCard extends StatelessWidget {
  const _AssistantCard({required this.item});
  final Assistant item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final baseBg = context.appColors.surfaceCard;
    final content = _TactileCard(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AssistantSettingsEditPage(assistantId: item.id),
          ),
        );
      },
      builder: (pressed, overlay) {
        return Container(
          decoration: BoxDecoration(
            color: Color.alphaBlend(overlay, baseBg),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant.withValues(
                alpha: isDark ? 0.12 : 0.08,
              ),
              width: 0.8,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AssistantAvatar(item: item, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: AppFontWeights.emphasis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            (item.systemPrompt.trim().isEmpty
                                ? l10n.assistantSettingsNoPromptPlaceholder
                                : item.systemPrompt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.7),
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    return Slidable(
      key: ValueKey('slidable-assistant-${item.id}'),
      endActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: 0.6,
        children: [
          CustomSlidableAction(
            autoClose: true,
            backgroundColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            onPressed: (_) async {
              final assistantProvider = context.read<AssistantProvider>();
              final newId = await assistantProvider.duplicateAssistant(
                item.id,
                l10n: l10n,
              );
              if (!context.mounted) return;
              if (newId != null) {
                showAppSnackBar(
                  context,
                  message: l10n.assistantSettingsCopySuccess,
                  type: NotificationType.success,
                );
              }
            },
            child: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                color: isDark
                    ? cs.primary.withValues(alpha: 0.16)
                    : cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: SizedBox.expand(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Lucide.Copy, color: cs.primary, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          l10n.assistantSettingsCopyButton,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          CustomSlidableAction(
            autoClose: true,
            backgroundColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            onPressed: (_) async {
              final assistantProvider = context.read<AssistantProvider>();
              final count = assistantProvider.assistants.length;
              if (count <= 1) {
                showAppSnackBar(
                  context,
                  message: l10n.assistantSettingsAtLeastOneAssistantRequired,
                  type: NotificationType.warning,
                );
                return;
              }
              final ok = await _confirmDelete(context, l10n);
              if (!context.mounted || ok != true) return;
              await ChatActions.cancelActiveGenerationsForAssistant(item.id);
              if (!context.mounted) return;
              final success = await assistantProvider.deleteAssistant(item.id);
              if (!context.mounted) return;
              if (success != true) {
                showAppSnackBar(
                  context,
                  message: l10n.assistantSettingsAtLeastOneAssistantRequired,
                  type: NotificationType.warning,
                );
              }
            },
            child: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                color: isDark
                    ? cs.error.withValues(alpha: 0.22)
                    : cs.error.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.error.withValues(alpha: 0.35)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: SizedBox.expand(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Lucide.Trash2, color: cs.error, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          l10n.assistantSettingsDeleteButton,
                          style: TextStyle(
                            color: cs.error,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      child: content,
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.assistants});

  final GroupChat group;
  final Map<String, Assistant> assistants;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = context.appColors.surfaceCard;
    final separator = Localizations.localeOf(context).languageCode == 'zh'
        ? '、'
        : ', ';
    final names = [
      for (final id in group.memberIds)
        (assistants[id]?.name ?? '').trim().isEmpty
            ? id
            : assistants[id]!.name.trim(),
    ];

    return _TactileCard(
      onTap: () => showGroupSettings(context, group.id),
      builder: (pressed, overlay) {
        return Container(
          decoration: BoxDecoration(
            color: Color.alphaBlend(overlay, baseBg),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
              width: 0.8,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                GroupAvatar(group: group, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.name.isEmpty ? l10n.groupChatTitle : group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        names.join(separator),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.7),
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- iOS-style tactile helpers ---
class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 22,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;
  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final pressColor = base.withValues(alpha: 0.7);
    final icon = Icon(
      widget.icon,
      size: widget.size,
      color: _pressed ? pressColor : base,
    );
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          Haptics.light();
          widget.onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: icon,
        ),
      ),
    );
  }
}

class _TactileCard extends StatefulWidget {
  const _TactileCard({required this.builder, this.onTap});
  final Widget Function(bool pressed, Color overlay) builder;
  final VoidCallback? onTap;
  @override
  State<_TactileCard> createState() => _TactileCardState();
}

class _TactileCardState extends State<_TactileCard> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlay = _pressed
        ? (Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: isDark ? 0.06 : 0.04))
        : Colors.transparent;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: widget.onTap == null ? null : () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (context.read<SettingsProvider>().hapticsOnCardTap) {
                Haptics.soft();
              }
              widget.onTap!.call();
            },
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: widget.builder(_pressed, overlay),
        ),
      ),
    );
  }
}

Future<String?> _showAddAssistantSheet(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  String? result;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
      return SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: bottomInset + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              const SizedBox(height: 12),
              Center(
                child: Text(
                  l10n.assistantSettingsAddSheetTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.assistantSettingsAddSheetHint,
                  filled: true,
                  fillColor: context.appColors.surfaceFill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: cs.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: cs.primary.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                onSubmitted: (_) =>
                    Navigator.of(ctx).pop(controller.text.trim()),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _IosOutlineButton(
                      label: l10n.assistantSettingsAddSheetCancel,
                      onTap: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _IosFilledButton(
                      label: l10n.assistantSettingsAddSheetSave,
                      onTap: () =>
                          Navigator.of(ctx).pop(controller.text.trim()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  ).then((val) => result = val as String?);
  final trimmed = (result ?? '').trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

Future<bool?> _confirmDelete(
  BuildContext context,
  AppLocalizations l10n,
) async {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text(l10n.assistantSettingsDeleteDialogTitle),
        content: Text(l10n.assistantSettingsDeleteDialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.assistantSettingsDeleteDialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              l10n.assistantSettingsDeleteDialogConfirm,
              style: TextStyle(color: cs.error),
            ),
          ),
        ],
      );
    },
  );
}

class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar({required this.item, this.size = 40});
  final Assistant item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final av = (item.avatar ?? '').trim();
    if (av.isNotEmpty) {
      if (av.startsWith('http')) {
        return FutureBuilder<String?>(
          future: AvatarCache.getPath(av),
          builder: (ctx, snap) {
            final p = snap.data;
            if (p != null && File(p).existsSync()) {
              return ClipOval(
                child: Image(
                  image: FileImage(File(p)),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
              );
            }
            return ClipOval(
              child: Image.network(
                av,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (c, e, s) => _initial(cs),
              ),
            );
          },
        );
      } else if (!kIsWeb && (av.startsWith('/') || av.contains(':'))) {
        final fixed = SandboxPathResolver.fix(av);
        final f = File(fixed);
        if (f.existsSync()) {
          return ClipOval(
            child: Image(
              image: FileImage(f),
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
          );
        }
        return _initial(cs);
      } else {
        return _emoji(cs, av);
      }
    }
    return _initial(cs);
  }

  Widget _initial(ColorScheme cs) {
    final letter = item.name.isNotEmpty ? item.name.characters.first : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: cs.primary,
          fontWeight: AppFontWeights.emphasis,
          fontSize: size * 0.42,
        ),
      ),
    );
  }

  Widget _emoji(ColorScheme cs, String emoji) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        emoji.characters.take(1).toString(),
        style: TextStyle(fontSize: size * 0.5),
      ),
    );
  }
}

class _IosOutlineButton extends StatefulWidget {
  const _IosOutlineButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  State<_IosOutlineButton> createState() => _IosOutlineButtonState();
}

class _IosOutlineButtonState extends State<_IosOutlineButton> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.primary.withValues(alpha: 0.5)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.primary,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}

class _IosFilledButton extends StatefulWidget {
  const _IosFilledButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  State<_IosFilledButton> createState() => _IosFilledButtonState();
}

class _IosFilledButtonState extends State<_IosFilledButton> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.onPrimary,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}
