import 'dart:math' as math;

import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/assistant.dart';
import '../core/providers/settings_provider.dart';
import '../features/chat/widgets/reasoning_level_sheet.dart';
import '../features/group_chat/widgets/group_member_strip.dart';
import '../features/home/utils/model_display_helper.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import 'desktop_glass_popover.dart';

/// The 1:1 popover: one model, driven by the spec's picker.
///
/// The panel is a *route*, not an inline overlay: the response-speed menu and the
/// custom-budget dialog both open from inside it and have to paint above it.
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
  final anchorRect = box.localToGlobal(Offset.zero) & box.size;
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
                  child: ReasoningLevelPicker(
                    config: config,
                    modelId: modelId,
                    assistant: assistant,
                    conversationId: conversationId,
                    compact: true,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
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
  String? conversationId,
}) {
  return _showReasoningPopover(
    context,
    anchorKey: anchorKey,
    build: (handle) => _GroupReasoningPopover(
      conversationId: conversationId,
      members: members,
      initialId: initialAssistantId,
      onDone: handle.close,
      onSuspendedChanged: handle.setSuspended,
    ),
  );
}

/// Anchors [build]'s popover above [anchorKey], or does nothing when the anchor
/// is already gone.
Future<void> _showReasoningPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required Widget Function(DesktopGlassPopoverHandle handle) build,
}) {
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return Future.value();

  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return Future.value();
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(
    offset.dx,
    offset.dy,
    size.width,
    size.height,
  );

  return showDesktopGlassPopover(
    context,
    anchorRect: anchorRect,
    // Upstream's picker is 260 wide (a slider needs the room); the fork's
    // anchor-sized panel was sized for its tiles.
    width: (MediaQuery.sizeOf(context).width - 16).clamp(0.0, 260.0),
    builder: (ctx, handle) => build(handle),
  );
}

/// The popover, scoped to one member of a group: the strip picks whose level
/// the tiles below commit, and each member resolves its own model.
class _GroupReasoningPopover extends StatefulWidget {
  const _GroupReasoningPopover({
    required this.members,
    required this.onDone,
    required this.onSuspendedChanged,
    this.initialId,
    this.conversationId,
  });

  final List<Assistant> members;
  final String? initialId;
  final String? conversationId;
  final Future<void> Function() onDone;
  final ValueChanged<bool> onSuspendedChanged;

  @override
  State<_GroupReasoningPopover> createState() => _GroupReasoningPopoverState();
}

class _GroupReasoningPopoverState extends State<_GroupReasoningPopover> {
  late String _selectedId = widget.initialId ?? widget.members.first.id;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final byId = {for (final member in widget.members) member.id: member};
    final member = byId[_selectedId] ?? widget.members.first;
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
            members: widget.members,
            selectedId: member.id,
            onSelect: (picked) => setState(() => _selectedId = picked.id),
          ),
        ),
        if (hasModel)
          ReasoningLevelPicker(
            config: settings.getProviderConfig(providerKey),
            modelId: modelId!,
            assistant: member,
            conversationId: widget.conversationId,
            compact: true,
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Text(
              l10n.reasoningLevelNoReasoning,
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

class _HoverRow extends StatefulWidget {
  const _HoverRow({
    required this.leading,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final Widget leading;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final baseBg = Colors.transparent;
    final hoverBg = cs.onSurface.withValues(alpha: isDark ? 0.12 : 0.10);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hovered ? hoverBg : baseBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Center(child: widget.leading),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFontWeights.regular,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: widget.selected
                    ? Icon(
                        Lucide.Check,
                        key: const ValueKey('check'),
                        size: 16,
                        color: cs.primary,
                      )
                    : const SizedBox(width: 16, key: ValueKey('space')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
