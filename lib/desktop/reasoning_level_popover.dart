import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/assistant.dart';
import '../core/providers/settings_provider.dart';
import '../features/chat/widgets/reasoning_level_sheet.dart';
import '../features/group_chat/widgets/group_member_strip.dart';
import '../features/home/utils/model_display_helper.dart';
import '../l10n/app_localizations.dart';
import 'desktop_glass_popover.dart';

/// The 1:1 popover: one model, whose level the tiles below commit.
Future<void> showDesktopReasoningLevelPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required ProviderConfig config,
  required String modelId,
  Assistant? assistant,
  String? conversationId,
}) async {
  final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) return;
  await _showPanel(
    context,
    box.localToGlobal(Offset.zero) & box.size,
    ReasoningLevelPicker(
      config: config,
      modelId: modelId,
      assistant: assistant,
      conversationId: conversationId,
      compact: true,
    ),
  );
}

/// The group's popover, scoped to one member at a time: every member resolves
/// its own model, so the group needs nothing but the roster — which is why it
/// takes no model of its own.
Future<void> showDesktopGroupReasoningPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required List<Assistant> members,
  String? initialAssistantId,
}) async {
  if (members.isEmpty) return;
  final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) return;
  await _showPanel(
    context,
    box.localToGlobal(Offset.zero) & box.size,
    _GroupReasoningPanel(members: members, initialId: initialAssistantId),
  );
}

/// The roster's reasoning panel: the strip picks whose level the picker below
/// commits. One panel for the whole group, because each member resolves its own
/// model through the same rule a 1:1 chat uses.
class _GroupReasoningPanel extends StatefulWidget {
  const _GroupReasoningPanel({required this.members, this.initialId});

  final List<Assistant> members;
  final String? initialId;

  @override
  State<_GroupReasoningPanel> createState() => _GroupReasoningPanelState();
}

class _GroupReasoningPanelState extends State<_GroupReasoningPanel> {
  late String _selectedId = widget.initialId ?? widget.members.first.id;

  @override
  Widget build(BuildContext context) {
    final members = widget.members;
    final byId = {for (final member in members) member.id: member};
    final member = byId[_selectedId] ?? members.first;
    final settings = context.watch<SettingsProvider>();
    final model = resolveChatModel(settings, assistant: member);
    final providerKey = model.providerKey;
    final modelId = model.modelId;
    final hasModel = providerKey != null && (modelId ?? '').isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: GroupMemberStrip(
            members: members,
            selectedId: member.id,
            onSelect: (picked) => setState(() => _selectedId = picked.id),
          ),
        ),
        if (hasModel)
          ReasoningLevelPicker(
            config: settings.getProviderConfig(providerKey),
            modelId: modelId!,
            assistant: member,
            compact: true,
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Text(
              AppLocalizations.of(context)!.reasoningLevelNoReasoning,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.62),
                decoration: TextDecoration.none,
              ),
            ),
          ),
      ],
    );
  }
}

/// Anchors [child] above its anchor, or below it when there is no room.
Future<void> _showPanel(
  BuildContext context,
  Rect anchorRect,
  Widget child,
) async {
  // A route lets nested speed menus and budget dialogs appear above the panel.
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: const Duration(milliseconds: 180),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          child: child,
        ),
    pageBuilder: (ctx, _, __) {
      final screen = MediaQuery.sizeOf(ctx);
      final safe = MediaQuery.paddingOf(ctx);
      final width = math.min(
        260.0,
        math.max(0.0, screen.width - safe.horizontal - 16),
      );
      final left = (anchorRect.center.dx - width / 2).clamp(
        safe.left + 8,
        screen.width - safe.right - width - 8,
      );
      final above = anchorRect.top - safe.top - 16;
      final below = screen.height - safe.bottom - anchorRect.bottom - 16;
      final placeAbove = above >= below;
      return Stack(
        children: [
          Positioned(
            left: left,
            width: width,
            bottom: placeAbove ? screen.height - anchorRect.top + 8 : null,
            top: placeAbove ? null : anchorRect.bottom + 8,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.max(0.0, placeAbove ? above : below),
              ),
              child: DesktopGlassPanel(
                borderRadius: BorderRadius.circular(16),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 10),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
