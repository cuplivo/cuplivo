import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/avatar_value.dart';
import '../../../shared/widgets/custom_bottom_sheet.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../../home/widgets/assistant_entry_actions.dart';
import 'group_member_cluster.dart';

/// The roster, as a list: one row per member, then the two things a group can
/// do to itself — invite, and settings.
///
/// Deliberately no per-member shortcut beyond "open this assistant": removing
/// someone is a group decision and lives in the group's own settings.
class GroupMemberList extends StatelessWidget {
  const GroupMemberList({
    super.key,
    required this.group,
    required this.members,
    required this.onInvite,
    required this.onOpenSettings,
    this.onClose,
  });

  final GroupChat group;
  final List<Assistant> members;
  final VoidCallback onInvite;
  final VoidCallback onOpenSettings;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (members.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              l10n.groupChatMembersEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        for (final member in members)
          _Row(
            leading: AssistantAvatar(assistant: member, size: 32),
            label: member.name.trim().isEmpty ? member.id : member.name,
            trailing: Icon(
              Lucide.ChevronRight,
              size: 16,
              color: cs.onSurface.withValues(alpha: 0.35),
            ),
            onTap: () {
              onClose?.call();
              AssistantEntryActions.openAssistantSettings(context, member.id);
            },
          ),
        const SizedBox(height: 6),
        _Row(
          leading: _CircleIcon(icon: Lucide.UserPlus, color: cs.primary),
          label: l10n.groupChatInvite,
          onTap: () {
            onClose?.call();
            onInvite();
          },
        ),
        _Row(
          leading: _CircleIcon(
            icon: Lucide.Settings2,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
          label: l10n.groupChatSettingsTitle,
          onTap: () {
            onClose?.call();
            onOpenSettings();
          },
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.leading,
    required this.label,
    this.trailing,
    required this.onTap,
  });

  final Widget leading;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: IosCardPress(
        borderRadius: BorderRadius.circular(14),
        baseColor: Colors.transparent,
        duration: const Duration(milliseconds: 200),
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.medium,
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
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
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 17, color: color),
    );
  }
}

/// Picks the members a new group starts with, or the assistants to invite into
/// an existing one.
class GroupMemberPicker extends StatefulWidget {
  const GroupMemberPicker({
    super.key,
    required this.title,
    required this.candidates,
    this.initialSelection = const <String>[],
    this.requireSelection = false,
  });

  final String title;
  final List<Assistant> candidates;
  final List<String> initialSelection;
  final bool requireSelection;

  @override
  State<GroupMemberPicker> createState() => _GroupMemberPickerState();
}

class _GroupMemberPickerState extends State<GroupMemberPicker> {
  late final Set<String> _selected = {...widget.initialSelection};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final canConfirm = !widget.requireSelection || _selected.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.candidates.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              l10n.groupChatNoAssistantToInvite,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final assistant in widget.candidates)
                  _Row(
                    leading: AssistantAvatar(assistant: assistant, size: 32),
                    label: assistant.name.trim().isEmpty
                        ? assistant.id
                        : assistant.name,
                    trailing: Icon(
                      _selected.contains(assistant.id)
                          ? Lucide.CheckCircle
                          : Lucide.Circle,
                      size: 20,
                      color: _selected.contains(assistant.id)
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.3),
                    ),
                    onTap: () => setState(() {
                      if (!_selected.remove(assistant.id)) {
                        _selected.add(assistant.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
              FilledButton(
                onPressed: canConfirm
                    ? () => Navigator.of(context).pop(_selected.toList())
                    : null,
                child: Text(l10n.groupChatSave),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shared picker chooser: a sheet on mobile, a dialog on desktop.
///
/// Lives beside the picker itself so the group's settings and the member list
/// can both open it without either owning the other.
Future<List<String>?> showGroupMemberPickerDialog(
  BuildContext context, {
  required String title,
  required List<Assistant> candidates,
  List<String> initialSelection = const <String>[],
}) {
  if (_isDesktopPlatform) {
    return showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        content: SizedBox(
          width: 360,
          height: 380,
          child: GroupMemberPicker(
            title: title,
            candidates: candidates,
            initialSelection: initialSelection,
          ),
        ),
      ),
    );
  }
  return showCustomBottomSheet<List<String>>(
    context: context,
    title: title,
    builder: (sheetContext, scrollController) => Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: GroupMemberPicker(
        title: title,
        candidates: candidates,
        initialSelection: initialSelection,
      ),
    ),
  );
}

bool get _isDesktopPlatform =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Name plus initial members — the whole of "create a group".
class GroupCreateForm extends StatefulWidget {
  const GroupCreateForm({super.key, required this.candidates});

  final List<Assistant> candidates;

  @override
  State<GroupCreateForm> createState() => _GroupCreateFormState();
}

class _GroupCreateFormState extends State<GroupCreateForm> {
  final TextEditingController _name = TextEditingController();
  final Set<String> _selected = <String>{};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final canCreate = _name.text.trim().isNotEmpty && _selected.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          autofocus: false,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: l10n.groupChatNameHint,
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
              borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.5)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final assistant in widget.candidates)
                _Row(
                  leading: AssistantAvatar(assistant: assistant, size: 32),
                  label: assistant.name.trim().isEmpty
                      ? assistant.id
                      : assistant.name,
                  trailing: Icon(
                    _selected.contains(assistant.id)
                        ? Lucide.CheckCircle
                        : Lucide.Circle,
                    size: 20,
                    color: _selected.contains(assistant.id)
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.3),
                  ),
                  onTap: () => setState(() {
                    if (!_selected.remove(assistant.id)) {
                      _selected.add(assistant.id);
                    }
                  }),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.groupChatCreateHint,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
            FilledButton(
              onPressed: canCreate
                  ? () => Navigator.of(context).pop((
                      name: _name.text.trim(),
                      memberIds: _selected.toList(),
                    ))
                  : null,
              child: Text(l10n.groupChatCreate),
            ),
          ],
        ),
      ],
    );
  }
}

/// The cluster used as a group's avatar wherever a talk-shaped identity is
/// needed (sidebar row, topic header, settings).
///
/// A group that has set its own avatar shows that instead; the cluster stays
/// as the default *and* as the fallback for an image that no longer loads.
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({super.key, required this.group, this.size = 32});

  final GroupChat group;
  final double size;

  @override
  Widget build(BuildContext context) {
    final assistants = context.watch<AssistantProvider>();
    final members = <Assistant>[];
    for (final id in group.memberIds) {
      final assistant = assistants.getById(id);
      if (assistant != null) members.add(assistant);
    }
    final Widget cluster;
    if (members.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      cluster = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(Lucide.Users, size: size * 0.5, color: cs.primary),
      );
    } else {
      cluster = GroupMemberCluster(members: members, size: size * 0.72);
    }
    return AvatarValue(value: group.avatar, size: size, fallback: cluster);
  }
}
