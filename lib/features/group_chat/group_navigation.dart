import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/assistant.dart';
import '../../core/models/group_chat.dart';
import '../../core/providers/assistant_provider.dart';
import '../../core/providers/group_chat_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/custom_bottom_sheet.dart';
import '../group_chat/pages/group_settings_page.dart';
import '../group_chat/widgets/group_member_list.dart';
import '../group_chat/widgets/group_settings_view.dart';

bool get _isDesktop =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Mobile is a sheet, desktop is a dialog — never a bottom sheet on desktop.
///
/// The member list itself is the same [GroupMemberList] either way, so the
/// information architecture is identical on both platforms.
Future<void> showGroupMembers(BuildContext context, String groupId) async {
  final groups = context.read<GroupChatProvider>();
  final group = groups.byId(groupId);
  if (group == null) return;
  final l10n = AppLocalizations.of(context)!;

  void invite() => unawaited(showGroupInvite(context, groupId));
  void settings() => unawaited(showGroupSettings(context, groupId));

  if (_isDesktop) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final members = _membersOf(dialogContext, group);
        return AlertDialog(
          title: Text(group.name.isEmpty ? l10n.groupChatTitle : group.name),
          contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: GroupMemberList(
                group: group,
                members: members,
                onInvite: invite,
                onOpenSettings: settings,
                onClose: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ),
        );
      },
    );
    return;
  }

  await showCustomBottomSheet<void>(
    context: context,
    title: group.name.isEmpty ? l10n.groupChatTitle : group.name,
    partialHeightFactor: 0.55,
    builder: (sheetContext, scrollController) {
      final members = _membersOf(sheetContext, group);
      return ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        children: [
          GroupMemberList(
            group: group,
            members: members,
            onInvite: invite,
            onOpenSettings: settings,
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        ],
      );
    },
  );
}

List<Assistant> _membersOf(BuildContext context, GroupChat group) {
  final assistants = context.read<AssistantProvider>();
  final members = <Assistant>[];
  for (final id in group.memberIds) {
    final assistant = assistants.getById(id);
    if (assistant != null) members.add(assistant);
  }
  return members;
}

Future<void> showGroupSettings(BuildContext context, String groupId) async {
  if (!_isDesktop) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GroupSettingsPage(groupId: groupId)),
    );
    return;
  }
  final l10n = AppLocalizations.of(context)!;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 460,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.groupChatSettingsTitle,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GroupSettingsView(
                groupId: groupId,
                onDeleted: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Adds assistants to an existing group.
Future<void> showGroupInvite(BuildContext context, String groupId) async {
  final groups = context.read<GroupChatProvider>();
  final group = groups.byId(groupId);
  if (group == null) return;
  final existing = _membersOf(context, group).map((m) => m.id).toSet();
  final candidates = [
    for (final assistant in context.read<AssistantProvider>().assistants)
      if (!existing.contains(assistant.id)) assistant,
  ];
  if (candidates.isEmpty) return;
  final picked = await showGroupMemberPickerDialog(
    context,
    title: AppLocalizations.of(context)!.groupChatInvite,
    candidates: candidates,
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;
  final current = groups.byId(groupId);
  if (current == null) return;
  await groups.update(
    current.copyWith(
      memberIds: List<String>.unmodifiable({...current.memberIds, ...picked}),
    ),
  );
}

/// Creates a group from a name plus its first members.
Future<GroupChat?> showGroupCreate(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final candidates = context.read<AssistantProvider>().assistants;
  if (candidates.isEmpty) return null;

  Future<({String name, List<String> memberIds})?> ask(
    BuildContext hostContext,
  ) {
    if (_isDesktop) {
      return showDialog<({String name, List<String> memberIds})>(
        context: hostContext,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.groupChatCreate),
          contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          content: SizedBox(
            width: 380,
            height: 420,
            child: GroupCreateForm(candidates: candidates),
          ),
        ),
      );
    }
    return showCustomBottomSheet<({String name, List<String> memberIds})>(
      context: hostContext,
      title: l10n.groupChatCreate,
      builder: (sheetContext, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: GroupCreateForm(candidates: candidates),
      ),
    );
  }

  final answer = await ask(context);
  if (answer == null || !context.mounted) return null;
  return context.read<GroupChatProvider>().create(
    name: answer.name,
    memberIds: answer.memberIds,
  );
}
