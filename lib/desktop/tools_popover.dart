import 'dart:math' as math;
import 'dart:async';
import '../core/services/proactive_care_alarm_service.dart';
import '../features/home/widgets/conversation_proactive_care_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../features/mcp/widgets/mcp_server_avatar.dart';
import '../features/mcp/utils/mcp_tool_groups.dart';
import 'package:provider/provider.dart';

import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../core/providers/mcp_provider.dart';
import '../core/providers/assistant_provider.dart';
import '../core/providers/settings_provider.dart';
import '../core/models/conversation.dart';
import '../core/models/conversation_mcp_settings.dart';
import '../core/services/chat/chat_service.dart';
import '../features/chat/utils/ensure_conversation.dart';
import '../features/home/services/local_tool_labels.dart';
import '../features/home/services/local_tool_toggle.dart';
import '../core/models/assistant.dart';
import '../features/group_chat/widgets/group_member_strip.dart';
import '../features/home/utils/model_display_helper.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import '../theme/design_tokens.dart';
import 'desktop_overlay_backdrop.dart';

Future<void> showDesktopToolsPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required String assistantId,
  String? conversationId,
  required bool supportsModelTools,
  bool Function(String providerKey, String modelId)? modelSupportsTools,
  List<Assistant>? members,
}) async {
  if (context
          .read<AssistantProvider>()
          .getById(assistantId)
          ?.allowConversationMcp ==
      true) {
    conversationId = await ensureConversationId(
      context,
      conversationId: conversationId,
      assistantId: assistantId,
    );
    if (conversationId == null || !context.mounted) return;
  }
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
      conversationId: conversationId,
      supportsModelTools: supportsModelTools,
      modelSupportsTools: modelSupportsTools,
      members: members,
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
    required this.conversationId,
    required this.supportsModelTools,
    required this.onClose,
    this.modelSupportsTools,
    this.members,
  });

  /// Non-null in a group chat: the roster whose member the strip selects.
  final List<Assistant>? members;

  final Rect anchorRect;
  final double anchorWidth;
  final String assistantId;
  final String? conversationId;
  final bool supportsModelTools;

  /// The composer's capability check, for the member the strip selects. Null in
  /// a 1:1 chat, where [supportsModelTools] already speaks for the only model.
  final bool Function(String providerKey, String modelId)? modelSupportsTools;
  final VoidCallback onClose;

  @override
  State<_ToolsPopover> createState() => _ToolsPopoverState();
}

class _ToolsPopoverState extends State<_ToolsPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  Offset _offset = const Offset(0, 0.12);
  bool _closing = false;

  /// Which member a group popover is editing.
  String? _selectedId;

  String get _targetId {
    final members = widget.members;
    if (members == null || members.isEmpty) return widget.assistantId;
    final id = _selectedId ?? widget.assistantId;
    return members.any((member) => member.id == id) ? id : members.first.id;
  }

  Widget? get _memberStrip {
    final members = widget.members;
    if (members == null || members.length < 2) return null;
    return GroupMemberStrip(
      members: members,
      selectedId: _targetId,
      onSelect: (member) => setState(() => _selectedId = member.id),
    );
  }

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
    final width = math.min(
      (widget.anchorWidth - 16).clamp(260.0, 720.0),
      math.max(0.0, screen.width - 16),
    );
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
                          assistantId: _targetId,
                          conversationId: widget.conversationId,
                          supportsModelTools: widget.supportsModelTools,
                          modelSupportsTools: widget.modelSupportsTools,
                          header: _memberStrip,
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
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// Whether [member]'s own model passes the composer's tool capability check.
bool _modelCanCallTools(
  SettingsProvider settings,
  Assistant member,
  bool Function(String providerKey, String modelId) supportsTools,
) {
  final model = resolveChatModel(settings, assistant: member);
  final providerKey = model.providerKey;
  final modelId = model.modelId;
  if (providerKey == null || (modelId ?? '').isEmpty) return false;
  return supportsTools(providerKey, modelId!);
}

class _ToolsContent extends StatelessWidget {
  const _ToolsContent({
    required this.assistantId,
    required this.conversationId,
    required this.supportsModelTools,
    required this.onDone,
    this.header,
    this.modelSupportsTools,
  });
  final String assistantId;
  final String? conversationId;
  final bool supportsModelTools;
  final VoidCallback onDone;

  /// Rendered above the rows; a group puts its member strip here.
  final Widget? header;

  /// The composer's capability check, for the member the strip selects: a
  /// group's members each send with their own model, so [supportsModelTools] —
  /// resolved for the composer's model — says nothing about the one on show.
  /// Null in a 1:1 chat, where it says everything.
  final bool Function(String providerKey, String modelId)? modelSupportsTools;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final mcp = context.watch<McpProvider>();
    final ap = context.watch<AssistantProvider>();
    final a = ap.getById(assistantId);
    if (a == null) return const SizedBox.shrink();
    final supportsTools = modelSupportsTools;
    final toolsAllowed = supportsTools == null
        ? supportsModelTools
        : _modelCanCallTools(
            context.watch<SettingsProvider>(),
            a,
            supportsTools,
          );
    final conversationScoped = a.allowConversationMcp && conversationId != null;
    final conversation = conversationScoped
        ? context.select<ChatService, Conversation?>(
            (chat) => chat.getConversation(conversationId!),
          )
        : null;
    final inherited = !ConversationMcpSettings.isOverridden(conversation);
    final selected = ConversationMcpSettings.effectiveServerIds(
      a,
      conversation,
    ).toSet();
    Future<void> setIds(List<String>? ids) {
      if (conversationScoped) {
        return context.read<ChatService>().setConversationMcpServers(
          conversationId!,
          ids,
        );
      }
      return ap.updateAssistant(a.copyWith(mcpServerIds: ids!));
    }

    final groups = [if (toolsAllowed) ...mcpToolGroups(mcp)];

    final localToolIds = toolsAllowed
        ? availableLocalToolIds()
        : const <String>[];
    final enabledLocalTools = a.localToolIds.toSet();

    final rows = <WidgetBuilder>[];
    // The assistant tool list can outgrow the popover's height cap, so the
    // conversation-level care entry stays pinned above it.
    final careConversation = conversationId == null
        ? null
        : context.select<ChatService, Conversation?>(
            (chat) => chat.getConversation(conversationId!),
          );
    // A group topic carries no assistant, and care speaks for the
    // conversation's own one — the row would open nothing.
    if (ProactiveCareAlarmService.isSupported &&
        careConversation != null &&
        careConversation.assistantId != null) {
      rows.add(
        (context) => _RowItem(
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
      rows.add(
        (context) => _SectionLabel(text: l10n.assistantEditPageLocalToolsTab),
      );
      for (final id in localToolIds) {
        final isEnabled = enabledLocalTools.contains(id);
        rows.add(
          (context) => _RowItem(
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

    if (groups.isNotEmpty || (toolsAllowed && conversationScoped)) {
      rows.add(
        (context) => _SectionLabel(
          text: conversationScoped
              ? '${l10n.mcpAssistantSheetTitle} · ${inherited ? l10n.mcpSelectionInherited : l10n.mcpSelectionCustom}'
              : l10n.mcpAssistantSheetTitle,
        ),
      );
      if (conversationScoped) {
        rows.add(
          (context) => _RowItem(
            key: const ValueKey('desktop-tools-mcp-inherit'),
            leading: Icon(Lucide.RotateCcw, size: 16, color: cs.onSurface),
            label: l10n.mcpInheritAssistant,
            selected: inherited,
            onTap: () => setIds(null),
          ),
        );
      }
      rows.add(
        (context) => _RowItem(
          key: const ValueKey('desktop-tools-mcp-clear'),
          leading: Icon(Lucide.CircleX, size: 16, color: cs.onSurface),
          label: l10n.mcpAssistantSheetClearAll,
          onTap: () async {
            await setIds(const <String>[]);
            onDone();
          },
        ),
      );
    }

    for (final group in groups) {
      if (mcp.groups.isNotEmpty) {
        rows.add(
          (context) => _SectionLabel(
            text: group.group?.name ?? l10n.providerGroupsOther,
            subgroup: true,
          ),
        );
      }
      for (final s in group.servers) {
        final isSelected = selected.contains(s.id);
        rows.add(
          (context) => _RowItem(
            key: ValueKey('desktop-tools-mcp-${s.id}'),
            leading: McpServerAvatar(
              server: s,
              size: 16,
              radius: 7,
              showBackground: false,
            ),
            detail:
                '${s.tools.where((t) => t.enabled).length}/${s.tools.length}',
            label: s.name,
            selected: isSelected,
            onTap: () async {
              final set = selected.toSet();
              if (isSelected) {
                set.remove(s.id);
              } else {
                set.add(s.id);
              }
              await setIds(set.toList());
              // Do not close; allow multi-select
            },
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: header,
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: ListView.builder(
              shrinkWrap: true,
              addRepaintBoundaries: false,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              itemCount: rows.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: rows[index](context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text, this.subgroup = false});
  final bool subgroup;

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
          fontWeight: subgroup
              ? AppFontWeights.regular
              : AppFontWeights.semibold,
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
    this.detail,
    required this.label,
    this.selected,
    required this.onTap,
  });
  final Widget leading;
  final String? detail;
  final String label;
  final bool? selected;
  final VoidCallback onTap;

  @override
  State<_RowItem> createState() => _RowItemState();
}

class _RowItemState extends State<_RowItem> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final onColor = widget.selected == true ? cs.primary : cs.onSurface;
    final baseBg = Colors.transparent;
    final hoverBg = cs.onSurface.withValues(alpha: isDark ? 0.12 : 0.10);
    return Semantics(
      button: true,
      toggled: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: FocusableActionDetector(
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: _hovered || _focused ? hoverBg : baseBg,
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
                  if (widget.detail != null) ...[
                    Text(
                      widget.detail!,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: .5),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: widget.selected == true
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
        ),
      ),
    );
  }
}
