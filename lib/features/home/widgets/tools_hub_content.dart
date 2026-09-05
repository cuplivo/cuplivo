import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/workspace.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/collapsible_group_header.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/platform_utils.dart';
import '../../../desktop/desktop_settings_navigation_bus.dart';
import '../../mcp/pages/mcp_page.dart';
import '../../workspace/pages/workspace_list_page.dart';
import '../../workspace/pages/workspace_terminal_page.dart';
import '../../workspace/widgets/workspace_bind_sheet.dart';
import '../../assistant/pages/assistant_settings_page.dart';
import '../../workspace/widgets/workspace_settings_sheet.dart';
import '../services/local_tools_service.dart';
import 'subagent_target_sheet.dart';

/// The shared Tools Hub content: local tools / MCP servers / workspace
/// management grouped with collapsible headers. Used by both the mobile
/// bottom sheet and the desktop anchored popover.
///
/// Row styles follow the platform's original per-server UI: compact
/// check-mark rows on desktop (hover highlight), card rows with switches on
/// mobile.
class ToolsHubContent extends StatefulWidget {
  const ToolsHubContent({
    super.key,
    required this.assistantId,
    required this.conversationId,
    this.onClose,
  });

  final String assistantId;
  final String? conversationId;

  /// Invoked before navigation actions (dialog/routes) so hosting shells
  /// (e.g. the desktop popover with its full-screen dismiss barrier) can
  /// remove themselves first.
  final VoidCallback? onClose;

  @override
  State<ToolsHubContent> createState() => _ToolsHubContentState();
}

class _ToolsHubContentState extends State<ToolsHubContent>
    with CollapsibleGroupsMixin<ToolsHubContent> {
  static const String _localToolsKey = 'local_tools';
  static const String _mcpKey = 'mcp';
  static const String _workspaceKey = 'workspace';

  /// Desktop popover inline hint: dismissed per-open (transient surface).
  bool _subagentHintDismissed = false;

  @override
  Set<String> get initialCollapsedGroups => {_localToolsKey};

  void _updateAssistant(Assistant next) {
    try {
      context.read<AssistantProvider>().updateAssistant(next);
    } catch (e) {
      debugPrint('ToolsHubContent: failed to persist assistant update: $e');
    }
  }

  void _goAssistantSettings() {
    widget.onClose?.call();
    if (PlatformUtils.isDesktop) {
      // Desktop deep link mirrors the backup-reminder pattern: the settings
      // shell owns the assistant list pane; pushing a mobile-style route on
      // desktop is wrong (see side_drawer._openBackupSettings).
      DesktopSettingsNavigationBus.instance.openAssistants();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AssistantSettingsPage()),
    );
  }

  void _toggleLocalTool(Assistant a, String toolId, bool value) {
    Haptics.light();
    final ids = a.localToolIds.toSet();
    if (value) {
      ids.add(toolId);
    } else {
      ids.remove(toolId);
    }
    _updateAssistant(a.copyWith(localToolIds: ids.toList(growable: false)));
    if (toolId == LocalToolNames.handoff && value) {
      final targets = LocalToolsService.handoffTargets(
        context.read<AssistantProvider>().assistants,
        excludeId: a.id,
      );
      if (targets.isEmpty) {
        setState(() => _subagentHintDismissed = false);
        if (PlatformUtils.isMobile) {
          showSubagentNoTargetSnackbar(
            context,
            onGoSetup: _goAssistantSettings,
          );
        }
      }
    }
  }

  Future<void> _toggleDeviceTool(Assistant a, String toolId, bool value) async {
    if (!value) {
      _toggleLocalTool(a, toolId, false);
      return;
    }
    final outcome = await DeviceLocalTools.requestToggleEnable(toolId);
    if (!mounted) {
      // The permission flow (system settings page / dialog) may have closed
      // the hub sheet/popover; writing through a stale context would silently
      // drop the toggle (review finding: stale snapshot round trip).
      return;
    }
    // Re-read the assistant at write time: the permission round trip may have
    // changed other tools, and the captured snapshot can be stale.
    final fresh = context.read<AssistantProvider>().getById(a.id);
    if (fresh == null) {
      debugPrint('ToolsHubContent: assistant vanished during toggle: ${a.id}');
      return;
    }
    switch (outcome) {
      case DeviceToolToggleOutcome.canEnable:
        _toggleLocalTool(fresh, toolId, true);
      case DeviceToolToggleOutcome.canEnableUsageAccessMissing:
        showAppSnackBar(
          context,
          message: AppLocalizations.of(
            context,
          )!.chatMessageWidgetScreenTimePermissionRequired,
          type: NotificationType.warning,
        );
        // Upstream parity: still enable even when Usage Access is not
        // granted yet — the tool error guides the user to the page.
        _toggleLocalTool(fresh, toolId, true);
      case DeviceToolToggleOutcome.blocked:
        showAppSnackBar(
          context,
          message: AppLocalizations.of(
            context,
          )!.chatMessageWidgetCalendarPermissionDenied,
          type: NotificationType.warning,
        );
      case DeviceToolToggleOutcome.notSupported:
        // The row should not be visible on unsupported platforms; if it is,
        // keep the tool off.
        break;
    }
  }

  void _toggleMcpServer(Assistant a, String id, bool value) {
    Haptics.light();
    final set = a.mcpServerIds.toSet();
    if (value) {
      set.add(id);
    } else {
      set.remove(id);
    }
    _updateAssistant(a.copyWith(mcpServerIds: set.toList(growable: false)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final ap = context.watch<AssistantProvider>();
    final assistant = ap.getById(widget.assistantId);
    if (assistant == null) return const SizedBox.shrink();

    final mcp = context.watch<McpProvider>();
    final wp = context.watch<WorkspaceProvider>();
    final servers = mcp.servers
        .where((s) => mcp.statusFor(s.id) == McpStatus.connected)
        .toList();
    final selected = assistant.mcpServerIds.toSet();
    final boundWs = assistant.workspaceId == null
        ? null
        : wp.getById(assistant.workspaceId!);
    final conversation = widget.conversationId == null
        ? null
        : context.watch<ChatService>().getConversation(widget.conversationId!);
    final wsTerminalReady =
        Platform.isAndroid &&
        assistant.workspaceEnabled &&
        boundWs != null &&
        !boundWs.readOnly;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.chatInputBarToolsTooltip,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
              Tooltip(
                message: l10n.mcpAssistantSheetTitle,
                child: IosIconButton(
                  icon: Lucide.Hammer,
                  size: 18,
                  minSize: 34,
                  padding: const EdgeInsets.all(8),
                  onTap: () {
                    Haptics.light();
                    widget.onClose?.call();
                    Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const McpPage()));
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildLocalToolsGroup(l10n, cs, assistant),
              const SizedBox(height: 6),
              _buildMcpGroup(l10n, cs, assistant, servers, selected),
              const SizedBox(height: 6),
              _buildWorkspaceGroup(
                l10n,
                cs,
                assistant,
                boundWs,
                wsTerminalReady,
                conversation,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Row style follows the shell: mobile sheet rows on mobile, compact
  /// popover rows on desktop.
  bool get _isMobileStyle => PlatformUtils.isMobile;

  Widget _localToolRow(
    Assistant a, {
    required IconData icon,
    required String title,
    required String toolId,
    bool deviceTool = false,
    int? targetBadge,
  }) {
    final enabled = a.localToolIds.contains(toolId);
    void toggle(bool v) {
      if (deviceTool) {
        unawaited(_toggleDeviceTool(a, toolId, v));
      } else {
        _toggleLocalTool(a, toolId, v);
      }
    }

    if (_isMobileStyle) {
      return _SheetToolRow(
        icon: icon,
        title: title,
        enabled: enabled,
        onChanged: toggle,
        tag: targetBadge == null
            ? null
            : AppLocalizations.of(context)!.subagentTargetBadge(targetBadge),
        tagWarning: targetBadge != null && targetBadge == 0,
      );
    }
    return _DesktopToolRow(
      icon: icon,
      label: title,
      selected: enabled,
      onTap: () => toggle(!enabled),
      trailing: targetBadge == null
          ? null
          : _SubagentBadgeText(count: targetBadge, showCheck: enabled),
    );
  }

  Widget _buildLocalToolsGroup(
    AppLocalizations l10n,
    ColorScheme cs,
    Assistant a,
  ) {
    final targets = LocalToolsService.handoffTargets(
      context.read<AssistantProvider>().assistants,
      excludeId: a.id,
    );
    final handoffEnabled = a.localToolIds.contains(LocalToolNames.handoff);
    final rows = <Widget>[
      for (final toolId in LocalToolNames.toolsHubManaged)
        if (_localToolVisibleOnThisDevice(toolId))
          _localToolRow(
            a,
            icon: _localToolIcon(toolId),
            title: _localToolTitle(l10n, toolId),
            toolId: toolId,
            deviceTool: _isDeviceLocalTool(toolId),
            targetBadge: toolId == LocalToolNames.handoff
                ? targets.length
                : null,
          ),
    ];
    final toolCount = rows.length;
    if (!PlatformUtils.isMobile &&
        handoffEnabled &&
        targets.isEmpty &&
        !_subagentHintDismissed) {
      rows.add(
        SubagentNoTargetHintRow(
          onGoSetup: _goAssistantSettings,
          onDismiss: () => setState(() => _subagentHintDismissed = true),
        ),
      );
    }
    return _buildGroup(
      keyName: _localToolsKey,
      groupName: l10n.toolsHubLocalToolsTitle,
      count: toolCount,
      children: rows,
    );
  }

  bool _isDeviceLocalTool(String toolId) =>
      toolId == LocalToolNames.screenTime ||
      toolId == LocalToolNames.calendarQuery ||
      toolId == LocalToolNames.calendarCreate;

  bool _localToolVisibleOnThisDevice(String toolId) => switch (toolId) {
    LocalToolNames.screenTime => DeviceLocalTools.screenTimeSupported,
    LocalToolNames.calendarQuery ||
    LocalToolNames.calendarCreate => DeviceLocalTools.calendarSupported,
    _ => true,
  };

  IconData _localToolIcon(String toolId) => switch (toolId) {
    LocalToolNames.timeInfo => Lucide.clock,
    LocalToolNames.clipboard => Lucide.Clipboard,
    LocalToolNames.textToSpeech => Lucide.Volume2,
    LocalToolNames.askUser => Lucide.MessageCircleQuestionMark,
    LocalToolNames.calculate => Lucide.Calculator,
    LocalToolNames.handoff => Lucide.Bot,
    LocalToolNames.screenTime => Lucide.Smartphone,
    LocalToolNames.calendarQuery => Lucide.Calendar,
    LocalToolNames.calendarCreate => Lucide.CalendarPlus,
    _ => Lucide.Wrench,
  };

  String _localToolTitle(AppLocalizations l10n, String toolId) =>
      switch (toolId) {
        LocalToolNames.timeInfo => l10n.assistantEditLocalToolTimeInfoTitle,
        LocalToolNames.clipboard => l10n.assistantEditLocalToolClipboardTitle,
        LocalToolNames.textToSpeech =>
          l10n.assistantEditLocalToolTextToSpeechTitle,
        LocalToolNames.askUser => l10n.assistantEditLocalToolAskUserTitle,
        LocalToolNames.calculate => l10n.assistantEditLocalToolCalculateTitle,
        LocalToolNames.handoff => l10n.assistantEditLocalToolHandoffTitle,
        LocalToolNames.screenTime => l10n.assistantEditLocalToolScreenTimeTitle,
        LocalToolNames.calendarQuery =>
          l10n.assistantEditLocalToolCalendarQueryTitle,
        LocalToolNames.calendarCreate =>
          l10n.assistantEditLocalToolCalendarCreateTitle,
        _ => toolId,
      };

  Widget _buildMcpGroup(
    AppLocalizations l10n,
    ColorScheme cs,
    Assistant a,
    List<McpServerConfig> servers,
    Set<String> selected,
  ) {
    final children = <Widget>[];
    if (servers.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              l10n.mcpConversationSheetNoRunning,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    } else {
      for (final s in servers) {
        final isSelected = selected.contains(s.id);
        final tools = s.tools;
        final enabledTools = tools.where((t) => t.enabled).length;
        if (_isMobileStyle) {
          children.add(
            _SheetToolRow(
              icon: Lucide.Hammer,
              title: s.name,
              tag: l10n.mcpConversationSheetToolsCount(
                enabledTools,
                tools.length,
              ),
              enabled: isSelected,
              onChanged: (v) => _toggleMcpServer(a, s.id, v),
            ),
          );
        } else {
          children.add(
            _DesktopToolRow(
              icon: Lucide.Hammer,
              label: s.name,
              selected: isSelected,
              onTap: () => _toggleMcpServer(a, s.id, !isSelected),
            ),
          );
        }
      }
    }
    return _buildGroup(
      keyName: _mcpKey,
      groupName: l10n.mcpConversationSheetTitle,
      count: servers.length,
      trailing: isGroupExpanded(_mcpKey) && servers.isNotEmpty
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HeaderTextButton(
                  label: l10n.mcpConversationSheetSelectAll,
                  onTap: () {
                    Haptics.light();
                    _updateAssistant(
                      a.copyWith(
                        mcpServerIds: servers.map((e) => e.id).toList(),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 4),
                _HeaderTextButton(
                  label: l10n.mcpConversationSheetClearAll,
                  onTap: () {
                    Haptics.light();
                    _updateAssistant(
                      a.copyWith(mcpServerIds: const <String>[]),
                    );
                  },
                ),
              ],
            )
          : null,
      children: children,
    );
  }

  Widget _buildWorkspaceGroup(
    AppLocalizations l10n,
    ColorScheme cs,
    Assistant a,
    Workspace? boundWs,
    bool wsTerminalReady,
    Conversation? conversation,
  ) {
    final boundLabel = boundWs?.displayName ?? l10n.toolsHubWorkspaceUnbound;
    final directoryReady =
        a.workspaceEnabled && boundWs != null && conversation != null;
    final directoryLabel = directoryReady
        ? conversation.workspaceDirectoryOverrides[boundWs.id] ??
              a.workspaceDefaultDirectories[boundWs.id] ??
              '/workspace'
        : l10n.workspaceBindDisabledHint;

    void openDirectorySettings() {
      final conversationId = widget.conversationId;
      if (!directoryReady || conversationId == null) return;
      Haptics.light();
      final launchContext = widget.onClose == null
          ? context
          : Navigator.of(context, rootNavigator: true).context;
      widget.onClose?.call();
      unawaited(
        showWorkspaceDirectorySettings(
          launchContext,
          assistantId: a.id,
          conversationId: conversationId,
        ),
      );
    }

    final children = <Widget>[
      if (_isMobileStyle)
        _SheetNavRow(
          icon: Lucide.FolderOpen,
          title: l10n.workspaceBindTitle,
          trailingText: boundLabel,
          onTap: () {
            Haptics.light();
            widget.onClose?.call();
            showWorkspaceBindSheet(context, a);
          },
        )
      else
        _DesktopToolRow(
          icon: Lucide.FolderOpen,
          label: l10n.workspaceBindTitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                boundLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ],
          ),
          onTap: () {
            Haptics.light();
            widget.onClose?.call();
            showWorkspaceBindSheet(context, a);
          },
        ),
      if (_isMobileStyle)
        _SheetNavRow(
          icon: Lucide.FolderOpen,
          title: l10n.workspaceDirectoryPickerTitle,
          trailingText: directoryLabel,
          enabled: directoryReady,
          onTap: directoryReady ? openDirectorySettings : null,
        )
      else
        _DesktopToolRow(
          icon: Lucide.FolderOpen,
          label: l10n.workspaceDirectoryPickerTitle,
          enabled: directoryReady,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                directoryLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ],
          ),
          onTap: directoryReady ? openDirectorySettings : null,
        ),
    ];
    if (Platform.isAndroid) {
      children.add(
        _SheetNavRow(
          icon: Lucide.Terminal,
          title: l10n.toolsHubOpenTerminal,
          trailingText: wsTerminalReady
              ? boundWs!.displayName
              : l10n.toolsHubTerminalDisabledHint,
          enabled: wsTerminalReady,
          onTap: wsTerminalReady
              ? () {
                  Haptics.light();
                  widget.onClose?.call();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          WorkspaceTerminalPage(workspaceId: boundWs!.id),
                    ),
                  );
                }
              : null,
        ),
      );
    }
    return _buildGroup(
      keyName: _workspaceKey,
      groupName: l10n.settingsPageWorkspace,
      count: Platform.isAndroid ? 3 : 2,
      trailing: Tooltip(
        message: l10n.toolsHubWorkspaceManage,
        child: IosIconButton(
          icon: Lucide.Settings2,
          size: 16,
          minSize: 30,
          padding: const EdgeInsets.all(6),
          onTap: () {
            Haptics.light();
            widget.onClose?.call();
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WorkspaceListPage()),
            );
          },
        ),
      ),
      children: children,
    );
  }

  Widget _buildGroup({
    required String keyName,
    required String groupName,
    required int count,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CollapsibleGroupHeader(
          groupName: groupName,
          skillCount: count,
          expanded: isGroupExpanded(keyName),
          onTap: () => toggleGroup(keyName),
          fontSize: 12.5,
          fontWeight: AppFontWeights.emphasis,
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
          trailing: trailing,
        ),
        CollapsibleGroupBody(
          expanded: isGroupExpanded(keyName),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0) const SizedBox(height: 6),
                child,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _HeaderTextButton extends StatelessWidget {
  const _HeaderTextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: cs.primary,
        textStyle: const TextStyle(fontSize: 11),
      ),
      child: Text(label),
    );
  }
}

/// Desktop compact row (original MCP popover style): 40px, hover highlight,
/// check marker when selected.
class _DesktopToolRow extends StatefulWidget {
  const _DesktopToolRow({
    required this.icon,
    required this.label,
    this.selected = false,
    this.enabled = true,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  State<_DesktopToolRow> createState() => _DesktopToolRowState();
}

class _DesktopToolRowState extends State<_DesktopToolRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final onColor = widget.selected ? cs.primary : cs.onSurface;
    final hoverBg = (isDark ? Colors.white : Colors.black).withValues(
      alpha: isDark ? 0.12 : 0.10,
    );
    return Opacity(
      opacity: widget.enabled ? 1 : 0.55,
      child: MouseRegion(
        cursor: !widget.enabled || widget.onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onEnter: (_) {
          if (widget.enabled) setState(() => _hovered = true);
        },
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovered ? hoverBg : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Center(
                    child: Icon(
                      widget.icon,
                      size: 16,
                      color: widget.selected ? cs.primary : onColor,
                    ),
                  ),
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
                      color: onColor,
                    ),
                  ),
                ),
                if (widget.trailing != null)
                  widget.trailing!
                else if (widget.selected)
                  Icon(Lucide.Check, size: 16, color: cs.primary)
                else
                  const SizedBox(width: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mobile card row (original assistant MCP sheet style): icon + title +
/// optional tag + switch.
class _SheetToolRow extends StatelessWidget {
  const _SheetToolRow({
    required this.icon,
    required this.title,
    required this.enabled,
    required this.onChanged,
    this.tag,
    this.tagWarning = false,
  });

  final IconData icon;
  final String title;
  final String? tag;
  final bool tagWarning;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = enabled
        ? cs.primary
        : cs.onSurface.withValues(alpha: 0.7);
    final tagColor = tagWarning ? cs.error : cs.primary;
    return IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: cs.surface,
      duration: const Duration(milliseconds: 260),
      onTap: () => onChanged(!enabled),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface,
              ),
            ),
          ),
          if (tag != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: tagColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: tagColor.withValues(alpha: 0.35)),
              ),
              child: Text(
                tag!,
                style: TextStyle(
                  fontSize: 11,
                  color: tagColor,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
            ),
          ],
          const SizedBox(width: 8),
          IosSwitch(value: enabled, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Desktop trailing badge for the Sub-agent Delegation row: live target count
/// (error-tinted at zero) next to the selected check marker.
class _SubagentBadgeText extends StatelessWidget {
  const _SubagentBadgeText({required this.count, required this.showCheck});

  final int count;
  final bool showCheck;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final color = count == 0 ? cs.error : cs.onSurface.withValues(alpha: 0.5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.subagentTargetBadge(count),
          style: TextStyle(
            fontSize: 11,
            fontWeight: AppFontWeights.medium,
            color: color,
          ),
        ),
        const SizedBox(width: 6),
        if (showCheck)
          Icon(Lucide.Check, size: 16, color: cs.primary)
        else
          const SizedBox(width: 16),
      ],
    );
  }
}

/// Mobile nav card row: icon + title + trailing text + chevron.
class _SheetNavRow extends StatelessWidget {
  const _SheetNavRow({
    required this.icon,
    required this.title,
    required this.trailingText,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String trailingText;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dimmed = !enabled;
    return IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: cs.surface,
      duration: const Duration(milliseconds: 260),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Opacity(
        opacity: dimmed ? 0.55 : 1.0,
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: dimmed ? cs.onSurface.withValues(alpha: 0.4) : cs.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                trailingText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Lucide.ChevronRight,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ],
        ),
      ),
    );
  }
}
