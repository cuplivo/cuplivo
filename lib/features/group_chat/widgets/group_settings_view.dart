import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/responsive/screen_type_helper.dart';
import '../../../shared/widgets/avatar_menu.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../../model/pages/default_model_page.dart';
import '../group_actions.dart';
import 'group_member_list.dart';

/// Everything a group can change about itself, in one body used by both layouts:
/// a page on mobile, a dialog on desktop.
class GroupSettingsView extends StatefulWidget {
  const GroupSettingsView({super.key, required this.groupId, this.onDeleted});

  final String groupId;

  /// Called after the group is gone, so a dialog can close and a page can pop.
  final VoidCallback? onDeleted;

  @override
  State<GroupSettingsView> createState() => _GroupSettingsViewState();
}

class _GroupSettingsViewState extends State<GroupSettingsView> {
  final TextEditingController _name = TextEditingController();
  final GlobalKey _avatarKey = GlobalKey();
  Timer? _nameDebounce;
  String? _initialisedFor;

  @override
  void dispose() {
    _nameDebounce?.cancel();
    _name.dispose();
    super.dispose();
  }

  Future<void> _editAvatar(GroupChat group) async {
    await showAvatarMenu(
      context,
      value: group.avatar,
      anchorKey: _avatarKey,
      // The menu stays open for seconds: apply the pick to the row as it is when
      // it lands, so a rename typed meanwhile is not rolled back.
      onSelected: (avatar) => unawaited(
        context.read<GroupChatProvider>().update(
          group.id,
          (current) =>
              current.copyWith(avatar: avatar, clearAvatar: avatar == null),
        ),
      ),
    );
  }

  void _syncName(GroupChat group) {
    if (_initialisedFor == group.id) return;
    _initialisedFor = group.id;
    _name.text = group.name;
  }

  void _onNameChanged(GroupChat group, String value) {
    _nameDebounce?.cancel();
    _nameDebounce = Timer(const Duration(milliseconds: 400), () {
      final name = value.trim();
      if (name.isEmpty) return;
      // 400 ms is long enough for a turn-cap tap or an avatar to land first:
      // the rename must join the row, not replace the snapshot it was typed on.
      unawaited(
        context.read<GroupChatProvider>().update(
          group.id,
          (current) => current.copyWith(name: name),
        ),
      );
    });
  }

  Future<void> _invite(GroupChat group, List<Assistant> members) async {
    final assistants = context.read<AssistantProvider>().assistants;
    final existing = members.map((member) => member.id).toSet();
    final candidates = [
      for (final assistant in assistants)
        if (!existing.contains(assistant.id)) assistant,
    ];
    if (candidates.isEmpty) return;
    final picked = await showGroupMemberPickerDialog(
      context,
      title: AppLocalizations.of(context)!.groupChatInvite,
      candidates: candidates,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    await context.read<GroupChatProvider>().update(
      group.id,
      (current) => current.copyWith(
        memberIds: List<String>.unmodifiable({...current.memberIds, ...picked}),
      ),
    );
  }

  Future<void> _removeMember(GroupChat group, Assistant member) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.groupChatRemoveMemberTitle),
        content: Text(l10n.groupChatRemoveMemberContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.groupChatCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.groupChatRemoveMember),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<GroupChatProvider>().update(group.id, (current) {
      // Keep the roster non-empty: the rule `GroupCreateForm` applies at
      // creation has to hold here too, or the group can never answer again. It
      // is read from the row that is there now, because the confirmation dialog
      // was an await.
      if (current.memberIds.length <= 1) return current;
      return current.copyWith(
        memberIds: List<String>.unmodifiable(
          current.memberIds.where((id) => id != member.id),
        ),
      );
    });
  }

  Future<void> _delete(GroupChat group) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.groupChatDeleteTitle),
        // A topic that was never sent lives only in the composer, so it cannot
        // be staged: say so instead of promising it back.
        content: Text(
          '${l10n.groupChatDeleteContent}\n\n${l10n.composerDraftDeleteNotice}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.groupChatCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: Text(l10n.groupChatDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await deleteGroupChat(context, group.id);
    if (!mounted) return;
    widget.onDeleted?.call();
    showAppSnackBar(
      context,
      message: AppLocalizations.of(context)!.groupChatDeleted,
      type: NotificationType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final groups = context.watch<GroupChatProvider>();
    final assistants = context.watch<AssistantProvider>();
    final settings = context.watch<SettingsProvider>();
    final group = groups.byId(widget.groupId);
    if (group == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          l10n.groupChatUnavailable,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
        ),
      );
    }
    _syncName(group);
    final members = <Assistant>[];
    for (final id in group.memberIds) {
      final assistant = assistants.getById(id);
      if (assistant != null) members.add(assistant);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Row(
          children: [
            _GroupAvatarButton(
              key: _avatarKey,
              group: group,
              size: ResponsiveHelper.isDesktop(context) ? 68 : 64,
              onTap: () => unawaited(_editAvatar(group)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: IosFormTextFieldShell(
                child: TextField(
                  controller: _name,
                  onChanged: (value) => _onNameChanged(group, value),
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: l10n.groupChatNameHint,
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _SectionLabel(l10n.groupChatMembers),
        const SizedBox(height: 6),
        if (members.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              l10n.groupChatMembersEmpty,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        for (final member in members)
          _SettingRow(
            leading: AssistantAvatar(assistant: member, size: 30),
            label: member.name.trim().isEmpty ? member.id : member.name,
            // With one member left there is nobody to remove it for, so the
            // row does not offer the action.
            onTap: members.length > 1
                ? () => _removeMemberConfirm(member)
                : null,
            trailing: members.length > 1
                ? Icon(
                    Lucide.X,
                    size: 16,
                    color: cs.onSurface.withValues(alpha: 0.4),
                  )
                : null,
          ),
        _SettingRow(
          leading: _CircleIcon(icon: Lucide.UserPlus, color: cs.primary),
          label: l10n.groupChatInvite,
          onTap: () => _invite(group, members),
        ),
        const SizedBox(height: 22),
        _SectionLabel(l10n.groupChatOrchestration),
        const SizedBox(height: 6),
        _SettingRow(
          leading: _CircleIcon(
            icon: Lucide.Sparkles,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
          label: l10n.groupChatDirectorTitle,
          subtitle: l10n.groupChatDirectorSubtitle,
          value: _directorLabel(settings),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const DefaultModelPage())),
        ),
        _SettingRow(
          leading: _CircleIcon(
            icon: Lucide.MessagesSquare,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
          label: l10n.groupChatMaxTurnsTitle,
          subtitle: l10n.groupChatMaxTurnsSubtitle,
          trailing: _TurnStepper(
            value: group.speakerTurnLimit,
            onChanged: (next) => unawaited(
              groups.update(
                group.id,
                (current) => current.copyWith(maxSpeakerTurns: next),
              ),
            ),
          ),
        ),
        const SizedBox(height: 26),
        _SettingRow(
          leading: _CircleIcon(icon: Lucide.Trash2, color: cs.error),
          label: l10n.groupChatDelete,
          danger: true,
          onTap: () => _delete(group),
        ),
      ],
    );
  }

  void _removeMemberConfirm(Assistant member) {
    final group = context.read<GroupChatProvider>().byId(widget.groupId);
    if (group == null) return;
    unawaited(_removeMember(group, member));
  }

  String _directorLabel(SettingsProvider settings) {
    final provider = settings.directorModelProvider;
    final modelId = settings.directorModelId;
    if (provider == null || modelId == null) {
      return AppLocalizations.of(context)!.groupChatDirectorFollowDefault;
    }
    return modelId;
  }
}

/// Small rounded field shell so the name input matches the rows around it.
class IosFormTextFieldShell extends StatelessWidget {
  const IosFormTextFieldShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.35),
          width: 0.6,
        ),
      ),
      child: child,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: AppFontWeights.semibold,
          color: cs.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.leading,
    required this.label,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final Widget leading;
  final String label;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: IosCardPress(
        borderRadius: BorderRadius.circular(14),
        baseColor: context.appColors.surfaceCard,
        duration: const Duration(milliseconds: 200),
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.medium,
                      color: danger ? cs.error : null,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (value != null)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  value!,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            if (trailing != null) trailing!,
            if (onTap != null && trailing == null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  Lucide.ChevronRight,
                  size: 16,
                  color: cs.onSurface.withValues(alpha: 0.35),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TurnStepper extends StatelessWidget {
  const _TurnStepper({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepperButton(
          icon: Lucide.Minus,
          enabled: value > GroupChat.minSpeakerTurns,
          onTap: () => onChanged(value - 1),
        ),
        SizedBox(
          width: 26,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface.withValues(alpha: 0.85),
            ),
          ),
        ),
        _StepperButton(
          icon: Lucide.Plus,
          enabled: value < GroupChat.maxSpeakerTurnsLimit,
          onTap: () => onChanged(value + 1),
        ),
      ],
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: enabled ? 0.06 : 0.03),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 14,
            color: cs.onSurface.withValues(alpha: enabled ? 0.7 : 0.25),
          ),
        ),
      ),
    );
  }
}

class _CircleIcon extends StatelessWidget {
  const _CircleIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// The group's avatar, which is also its edit button.
///
/// Mobile keeps a camera badge visible; desktop reveals "更换群头像" over the
/// avatar on hover. The whole circle is one tap target either way — nothing
/// here depends on hitting a 22 px badge.
class _GroupAvatarButton extends StatefulWidget {
  const _GroupAvatarButton({
    super.key,
    required this.group,
    required this.size,
    required this.onTap,
  });

  final GroupChat group;
  final double size;
  final VoidCallback onTap;

  @override
  State<_GroupAvatarButton> createState() => _GroupAvatarButtonState();
}

class _GroupAvatarButtonState extends State<_GroupAvatarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final desktop = ResponsiveHelper.isDesktop(context);
    final size = widget.size;
    return Semantics(
      button: true,
      label: l10n.groupChatChangeAvatar,
      child: Tooltip(
        message: l10n.groupChatChangeAvatar,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ExcludeSemantics(
                    child: GroupAvatar(group: widget.group, size: size),
                  ),
                  if (desktop)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: _hovered ? 1 : 0,
                          duration: const Duration(milliseconds: 140),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF141311,
                              ).withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Text(
                                  l10n.groupChatChangeAvatar,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    height: 1.25,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: IgnorePointer(
                        child: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: context.appColors.surfaceCard,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Icon(
                            Lucide.Camera,
                            size: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
