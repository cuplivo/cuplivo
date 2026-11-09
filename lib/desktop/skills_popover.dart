import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/assistant.dart';
import '../core/services/skills/skills_service.dart';
import '../features/group_chat/widgets/group_member_strip.dart';
import '../features/workspace/pages/skills_page.dart';
import '../features/workspace/widgets/desktop_workspace_button.dart';
import '../features/workspace/widgets/skills/conversation_skills_sheet.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../shared/widgets/ios_tactile.dart';
import '../theme/app_font_weights.dart';
import '../theme/design_tokens.dart';
import 'desktop_overlay_backdrop.dart';

const desktopSkillsPopoverKey = ValueKey('desktop-skills-popover');

Future<void> showDesktopSkillsPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required String conversationId,
  required Assistant? assistant,
  List<Assistant>? members,
}) async {
  final anchor = anchorKey.currentContext?.findRenderObject();
  if (anchor is! RenderBox || !anchor.attached || !anchor.hasSize) return;
  final overlay = Navigator.of(context, rootNavigator: true).overlay!;
  final overlayBox = overlay.context.findRenderObject()! as RenderBox;
  final anchorRect =
      anchor.localToGlobal(Offset.zero, ancestor: overlayBox) & anchor.size;
  final manage = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context)!.commonClose,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (popoverContext, animation, _) => _SkillsPopoverPosition(
      anchor: anchor,
      overlay: overlayBox,
      initialRect: anchorRect,
      animation: animation,
      child: _SkillsPopover(
        conversationId: conversationId,
        assistant: assistant,
        members: members,
      ),
    ),
    transitionBuilder: (_, __, ___, child) => child,
  );
  if (manage == true && context.mounted) {
    await openSkillsPage(context);
  }
}

class _SkillsPopoverPosition extends StatefulWidget {
  const _SkillsPopoverPosition({
    required this.anchor,
    required this.overlay,
    required this.initialRect,
    required this.animation,
    required this.child,
  });

  final RenderBox anchor;
  final RenderBox overlay;
  final Rect initialRect;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_SkillsPopoverPosition> createState() => _SkillsPopoverPositionState();
}

class _SkillsPopoverPositionState extends State<_SkillsPopoverPosition> {
  late Rect _anchorRect = widget.initialRect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    MediaQuery.sizeOf(context);
    // Read transforms after layout: the composer can sit under a slide
    // transition whose size may not be read from another subtree's layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.anchor.attached) {
        Navigator.of(context).maybePop();
        return;
      }
      final rect =
          widget.anchor.localToGlobal(Offset.zero, ancestor: widget.overlay) &
          widget.anchor.size;
      if (rect != _anchorRect) setState(() => _anchorRect = rect);
    });
  }

  @override
  Widget build(BuildContext context) => CustomSingleChildLayout(
    delegate: _SkillsPopoverLayout(anchorRect: _anchorRect),
    child: ClipRect(
      child: AnimatedBuilder(
        animation: widget.animation,
        child: widget.child,
        builder: (context, child) {
          final animation = widget.animation;
          final closing = animation.status == AnimationStatus.reverse;
          final offset = closing
              ? Curves.easeOutCubic.transform(1 - animation.value)
              : 0.12 * (1 - Curves.easeOutCubic.transform(animation.value));
          return FractionalTranslation(
            translation: Offset(0, offset),
            child: Opacity(
              opacity: Curves.easeOutCubic.transform(animation.value),
              child: child,
            ),
          );
        },
      ),
    ),
  );
}

class _SkillsPopoverLayout extends SingleChildLayoutDelegate {
  _SkillsPopoverLayout({required this.anchorRect});

  final Rect anchorRect;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final rect = anchorRect;
    final width = math.min(
      (rect.width - 16).clamp(260.0, 720.0),
      math.max(0.0, constraints.maxWidth - 16),
    );
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.max(
        0.0,
        math.min(420.0, math.min(rect.top, constraints.maxHeight - 8) - 8),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rect = anchorRect;
    return Offset(
      (rect.center.dx - childSize.width / 2).clamp(
        8.0,
        math.max(8.0, size.width - childSize.width - 8),
      ),
      math.max(8.0, math.min(rect.top, size.height - 8) - childSize.height),
    );
  }

  @override
  bool shouldRelayout(_SkillsPopoverLayout oldDelegate) =>
      anchorRect != oldDelegate.anchorRect;
}

class _SkillsPopover extends StatefulWidget {
  const _SkillsPopover({
    required this.conversationId,
    required this.assistant,
    this.members,
  });

  final String conversationId;
  final Assistant? assistant;

  /// Non-null in a group: the panel edits the member its strip selects.
  final List<Assistant>? members;

  @override
  State<_SkillsPopover> createState() => _SkillsPopoverState();
}

class _SkillsPopoverState extends State<_SkillsPopover> {
  String? _selectedId;

  /// The member the switches write for: a group edits one at a time, a 1:1 chat
  /// has nobody to switch between. The composer's own assistant starts selected
  /// when it is one of them.
  Assistant? get _targetAssistant {
    final members = widget.members;
    if (members == null || members.isEmpty) return widget.assistant;
    final preferred = _selectedId ?? widget.assistant?.id;
    for (final member in members) {
      if (member.id == preferred) return member;
    }
    return members.first;
  }

  @override
  Widget build(BuildContext context) {
    final members = widget.members;
    final roster = members != null && members.length > 1 ? members : null;
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const radius = BorderRadius.vertical(top: Radius.circular(14));
    return ClipRRect(
      key: desktopSkillsPopoverKey,
      borderRadius: radius,
      child: DesktopOverlayBackdrop(
        sigma: 20,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppOverlayColors.desktopPopoverSurface(cs),
            borderRadius: radius,
            border: Border(
              top: BorderSide(
                color: cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.12),
                width: 0.7,
              ),
              left: BorderSide(
                color: cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.12),
                width: 0.6,
              ),
              right: BorderSide(
                color: cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.12),
                width: 0.6,
              ),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.skillsSessionTitle,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: AppFontWeights.semibold,
                            color: cs.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                      IosIconButton(
                        icon: Lucide.X,
                        size: 16,
                        tooltip: l10n.commonClose,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  if (roster != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
                      child: GroupMemberStrip(
                        members: roster,
                        selectedId: _targetAssistant!.id,
                        onSelect: (member) =>
                            setState(() => _selectedId = member.id),
                        // The panel's own number: how many skills that member
                        // brings, before the rows say which.
                        valueBuilder: (member) {
                          final skills = context.watch<SkillsService?>();
                          if (skills == null) return null;
                          final count = skills
                              .resolveForAssistant(member)
                              .length;
                          return count == 0 ? null : Text('$count');
                        },
                      ),
                    ),
                  ConversationSkillsPanel(
                    conversationId: widget.conversationId,
                    assistant: _targetAssistant,
                    // The strip above makes the rows this member's own, so the
                    // panel writes that member rather than the global switch or
                    // the roster-wide conversation override.
                    scopeToAssistant: roster != null,
                    compact: true,
                    footerAction: DesktopWorkspaceButton(
                      label: l10n.storageSpaceManageSkills,
                      icon: Lucide.Settings2,
                      onPressed: () => Navigator.of(context).pop(true),
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
