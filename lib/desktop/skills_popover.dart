import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/providers/assistant_provider.dart';
import '../features/skills/skill_manager.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_font_weights.dart';

Future<void> showDesktopSkillsPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required List<SkillMetadata> skills,
  String? assistantId,
  VoidCallback? onManageSkills,
}) async {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return;

  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return;
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(
    offset.dx,
    offset.dy,
    size.width,
    size.height,
  );

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _SkillsPopover(
      anchorRect: anchorRect,
      anchorWidth: size.width,
      skills: skills,
      assistantId: assistantId,
      onManageSkills: onManageSkills,
      onClose: () {
        try {
          entry.remove();
        } catch (_) {}
      },
    ),
  );
  overlay.insert(entry);
}

class _SkillsPopover extends StatefulWidget {
  const _SkillsPopover({
    required this.anchorRect,
    required this.anchorWidth,
    required this.skills,
    required this.assistantId,
    required this.onManageSkills,
    required this.onClose,
  });

  final Rect anchorRect;
  final double anchorWidth;
  final List<SkillMetadata> skills;
  final String? assistantId;
  final VoidCallback? onManageSkills;
  final VoidCallback onClose;

  @override
  State<_SkillsPopover> createState() => _SkillsPopoverState();
}

class _SkillsPopoverState extends State<_SkillsPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  Offset _offset = const Offset(0, 0.12);
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _fadeIn = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() => _offset = Offset.zero);
      try {
        await _controller.forward();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    setState(() => _offset = const Offset(0, 1.0));
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final width = (widget.anchorWidth - 16).clamp(260.0, 720.0);
    final left =
        (widget.anchorRect.left + (widget.anchorRect.width - width) / 2).clamp(
          8.0,
          screen.width - width - 8.0,
        );
    final clipHeight = widget.anchorRect.top.clamp(0.0, screen.height);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: clipHeight,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  width: width,
                  bottom: 0,
                  child: FadeTransition(
                    opacity: _fadeIn,
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      offset: _offset,
                      child: _GlassPanel(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(14),
                        ),
                        child: _SkillsPopoverContent(
                          skills: widget.skills,
                          assistantId: widget.assistantId,
                          onManageSkills: widget.onManageSkills,
                          onClose: _close,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child, this.borderRadius});
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white).withValues(
              alpha: isDark ? 0.28 : 0.56,
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.18),
                width: 0.7,
              ),
              left: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
              right: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _SkillsPopoverContent extends StatelessWidget {
  const _SkillsPopoverContent({
    required this.skills,
    required this.assistantId,
    required this.onManageSkills,
    required this.onClose,
  });

  final List<SkillMetadata> skills;
  final String? assistantId;
  final VoidCallback? onManageSkills;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SkillsPopoverHeader(
              onManageSkills: onManageSkills == null
                  ? null
                  : () {
                      onClose();
                      onManageSkills?.call();
                    },
            ),
            if (skills.isEmpty)
              _SkillsPopoverEmpty(onImport: onManageSkills, onClose: onClose)
            else
              for (final (group, groupSkills) in groupSkillsByCategory(
                skills,
              )) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 2),
                  child: _GroupHeaderRow(
                    title:
                        group ??
                        AppLocalizations.of(context)!.skillsUncategorizedGroup,
                  ),
                ),
                for (final skill in groupSkills)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: _SkillsRowItem(
                      name: skill.name,
                      description: skill.description,
                      assistantId: assistantId,
                    ),
                  ),
              ],
          ],
        ),
      ),
    );
  }
}

class _SkillsPopoverHeader extends StatefulWidget {
  const _SkillsPopoverHeader({required this.onManageSkills});

  final VoidCallback? onManageSkills;

  @override
  State<_SkillsPopoverHeader> createState() => _SkillsPopoverHeaderState();
}

class _SkillsPopoverHeaderState extends State<_SkillsPopoverHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hoverBg = (isDark ? Colors.white : Colors.black).withValues(
      alpha: isDark ? 0.10 : 0.06,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            Lucide.Sparkles,
            size: 16,
            color: cs.onSurface.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.skillsTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: AppFontWeights.emphasis,
                color: cs.onSurface.withValues(alpha: 0.9),
                decoration: TextDecoration.none,
              ),
            ),
          ),
          if (widget.onManageSkills != null)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  widget.onManageSkills?.call();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: _hovered ? hoverBg : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Lucide.BookOpen, size: 14, color: cs.primary),
                      const SizedBox(width: 5),
                      Text(
                        l10n.skillsSheetManageAction,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: AppFontWeights.medium,
                          color: cs.primary,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SkillsPopoverEmpty extends StatelessWidget {
  const _SkillsPopoverEmpty({required this.onImport, required this.onClose});

  final VoidCallback? onImport;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Lucide.BookOpen,
            size: 28,
            color: cs.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.skillsEmptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          if (onImport != null) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () {
                onClose();
                onImport?.call();
              },
              icon: const Icon(Lucide.Download, size: 15),
              label: Text(l10n.skillsSheetImportAction),
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupHeaderRow extends StatelessWidget {
  const _GroupHeaderRow({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: AppFontWeights.emphasis,
                color: cs.onSurface.withValues(alpha: 0.75),
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkillsRowItem extends StatefulWidget {
  const _SkillsRowItem({
    required this.name,
    required this.description,
    required this.assistantId,
  });

  final String name;
  final String description;
  final String? assistantId;

  @override
  State<_SkillsRowItem> createState() => _SkillsRowItemState();
}

class _SkillsRowItemState extends State<_SkillsRowItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hoverBg = (isDark ? Colors.white : Colors.black).withValues(
      alpha: isDark ? 0.12 : 0.10,
    );
    final ap = context.watch<AssistantProvider>();
    final assistant = widget.assistantId != null
        ? ap.getById(widget.assistantId!)
        : ap.currentAssistant;
    final enabled = assistant?.skillIds.contains(widget.name) ?? false;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (assistant == null) return;
          final ids = assistant.skillIds.toSet();
          if (enabled) {
            ids.remove(widget.name);
          } else {
            ids.add(widget.name);
          }
          ap.updateAssistant(
            assistant.copyWith(skillIds: ids.toList(growable: false)),
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _hovered ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Lucide.BookOpen,
                size: 16,
                color: enabled
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: AppFontWeights.medium,
                        color: enabled ? cs.primary : cs.onSurface,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    if (widget.description.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        widget.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: AppFontWeights.regular,
                          color: cs.onSurface.withValues(alpha: 0.65),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (enabled)
                Icon(Lucide.Check, size: 14, color: cs.primary)
              else
                const SizedBox(width: 14),
            ],
          ),
        ),
      ),
    );
  }
}
