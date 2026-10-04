import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../core/models/conversation.dart';
import '../core/providers/mcp_provider.dart';
import '../core/providers/assistant_provider.dart';
import '../core/services/proactive_care_alarm_service.dart';
import '../features/home/services/local_tool_labels.dart';
import '../features/home/services/local_tool_toggle.dart';
import '../features/home/widgets/conversation_proactive_care_sheet.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import '../theme/design_tokens.dart';

Future<void> showDesktopToolsPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required String assistantId,
  Conversation? conversation,
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
    builder: (ctx) => _ToolsPopover(
      anchorRect: anchorRect,
      anchorWidth: size.width,
      assistantId: assistantId,
      conversation: conversation,
      onClose: () {
        try {
          entry.remove();
        } catch (_) {}
      },
    ),
  );
  overlay.insert(entry);
}

class _ToolsPopover extends StatefulWidget {
  const _ToolsPopover({
    required this.anchorRect,
    required this.anchorWidth,
    required this.assistantId,
    required this.onClose,
    this.conversation,
  });

  final Rect anchorRect;
  final double anchorWidth;
  final String assistantId;
  final VoidCallback onClose;
  final Conversation? conversation;

  @override
  State<_ToolsPopover> createState() => _ToolsPopoverState();
}

class _ToolsPopoverState extends State<_ToolsPopover>
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
                        child: _ToolsContent(
                          assistantId: widget.assistantId,
                          conversation: widget.conversation,
                          onDone: _close,
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
    final cs = Theme.of(context).colorScheme;
    final radius = borderRadius ?? BorderRadius.circular(14);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
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
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _ToolsContent extends StatelessWidget {
  const _ToolsContent({
    required this.assistantId,
    required this.onDone,
    this.conversation,
  });
  final String assistantId;
  final VoidCallback onDone;
  final Conversation? conversation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final mcp = context.watch<McpProvider>();
    final ap = context.watch<AssistantProvider>();
    final a = ap.getById(assistantId)!;
    final selected = a.mcpServerIds.toSet();
    final servers = mcp.servers
        .where((s) => mcp.statusFor(s.id) == McpStatus.connected)
        .toList();

    final localToolIds = availableLocalToolIds();
    final enabledLocalTools = a.localToolIds.toSet();

    final rows = <Widget>[];
    // The assistant tool list can outgrow the popover's height cap, so the
    // conversation-level care entry stays pinned above it.
    final careConversation = conversation;
    if (ProactiveCareAlarmService.isSupported && careConversation != null) {
      rows.add(
        _RowItem(
          key: const ValueKey<String>('desktop-tools-proactive-care'),
          leading: Icon(Lucide.HeartPulse, size: 16, color: cs.onSurface),
          label: l10n.conversationProactiveCareTitle,
          selected: false,
          onTap: () {
            onDone();
            unawaited(
              showConversationProactiveCare(
                context,
                conversation: careConversation,
                assistant: a,
              ),
            );
          },
        ),
      );
    }
    if (localToolIds.isNotEmpty) {
      rows.add(_SectionLabel(text: l10n.assistantEditPageLocalToolsTab));
      for (final id in localToolIds) {
        final isEnabled = enabledLocalTools.contains(id);
        rows.add(
          _RowItem(
            leading: Icon(
              localToolIcon(id),
              size: 16,
              color: isEnabled ? cs.primary : cs.onSurface,
            ),
            label: localToolTitle(l10n, id),
            selected: isEnabled,
            onTap: () async {
              await setLocalToolEnabled(
                context,
                assistant: a,
                toolId: id,
                value: !isEnabled,
              );
              // Do not close; allow multi-select
            },
          ),
        );
      }
    }

    if (servers.isNotEmpty) {
      rows.add(_SectionLabel(text: l10n.mcpAssistantSheetTitle));
      rows.add(
        _RowItem(
          leading: Icon(Lucide.CircleX, size: 16, color: cs.onSurface),
          label: l10n.mcpAssistantSheetClearAll,
          selected: false,
          onTap: () async {
            await context.read<AssistantProvider>().updateAssistant(
              a.copyWith(mcpServerIds: const <String>[]),
            );
            onDone();
          },
        ),
      );
    }

    for (final s in servers) {
      final isSelected = selected.contains(s.id);
      rows.add(
        _RowItem(
          leading: Icon(
            Lucide.Hammer,
            size: 16,
            color: isSelected ? cs.primary : cs.onSurface,
          ),
          label: s.name,
          selected: isSelected,
          onTap: () async {
            final set = a.mcpServerIds.toSet();
            if (isSelected) {
              set.remove(s.id);
            } else {
              set.add(s.id);
            }
            await context.read<AssistantProvider>().updateAssistant(
              a.copyWith(mcpServerIds: set.toList()),
            );
            // Do not close; allow multi-select
          },
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...rows.map(
                (w) => Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: w,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: AppFontWeights.semibold,
          decoration: TextDecoration.none,
          color: cs.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _RowItem extends StatefulWidget {
  const _RowItem({
    super.key,
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
  State<_RowItem> createState() => _RowItemState();
}

class _RowItemState extends State<_RowItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final onColor = widget.selected ? cs.primary : cs.onSurface;
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
                  ).copyWith(color: onColor),
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
