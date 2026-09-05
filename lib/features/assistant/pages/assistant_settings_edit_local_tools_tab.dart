part of 'assistant_settings_edit_page.dart';

class _LocalToolsTab extends StatelessWidget {
  const _LocalToolsTab({required this.assistantId});
  final String assistantId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ap = context.watch<AssistantProvider>();
    final assistant = ap.getById(assistantId)!;
    final timeEnabled = assistant.localToolIds.contains(
      LocalToolNames.timeInfo,
    );
    final clipboardEnabled = assistant.localToolIds.contains(
      LocalToolNames.clipboard,
    );
    final textToSpeechEnabled = assistant.localToolIds.contains(
      LocalToolNames.textToSpeech,
    );
    final askUserEnabled = assistant.localToolIds.contains(
      LocalToolNames.askUser,
    );
    final calculateEnabled = assistant.localToolIds.contains(
      LocalToolNames.calculate,
    );
    final handoffEnabled = assistant.localToolIds.contains(
      LocalToolNames.handoff,
    );
    final handoffTargets = LocalToolsService.handoffTargets(
      ap.assistants,
      excludeId: assistant.id,
    );
    final screenTimeEnabled = assistant.localToolIds.contains(
      LocalToolNames.screenTime,
    );
    final calendarQueryEnabled = assistant.localToolIds.contains(
      LocalToolNames.calendarQuery,
    );
    final calendarCreateEnabled = assistant.localToolIds.contains(
      LocalToolNames.calendarCreate,
    );

    Future<void> updateTool(String toolId, bool value) async {
      if (!context.mounted) {
        // The permission flow (system settings page / dialog) may have
        // unmounted this tab; writing through a stale context would silently
        // drop the toggle (review finding: stale snapshot round trip).
        return;
      }
      // Re-read at write time: the permission round trip may have changed
      // other tools, and the build-time snapshot can be stale.
      final current = context.read<AssistantProvider>().getById(assistantId);
      if (current == null) {
        debugPrint(
          'Local tools tab: assistant vanished during toggle: $assistantId',
        );
        return;
      }
      final ids = current.localToolIds.toSet();
      if (value) {
        ids.add(toolId);
      } else {
        ids.remove(toolId);
      }
      try {
        await context.read<AssistantProvider>().updateAssistant(
          current.copyWith(localToolIds: ids.toList(growable: false)),
        );
      } catch (e) {
        debugPrint('Failed to persist local tool switch: $e');
      }
    }

    Future<void> toggleTool(String toolId, bool value) async {
      if (!value) {
        await updateTool(toolId, false);
        return;
      }
      if (!DeviceLocalTools.isSupportedDeviceTool(toolId)) {
        await updateTool(toolId, true);
        return;
      }
      final outcome = await DeviceLocalTools.requestToggleEnable(toolId);
      if (!context.mounted) {
        // Toggled off or the tab closed during the permission round trip;
        // never write through a stale context.
        return;
      }
      switch (outcome) {
        case DeviceToolToggleOutcome.canEnable:
          await updateTool(toolId, true);
        case DeviceToolToggleOutcome.canEnableUsageAccessMissing:
          showAppSnackBar(
            context,
            message: l10n.chatMessageWidgetScreenTimePermissionRequired,
            type: NotificationType.warning,
          );
          // Upstream parity (rikkahub): still enable even when Usage Access
          // is not granted yet — the tool error guides the user to the page.
          await updateTool(toolId, true);
        case DeviceToolToggleOutcome.blocked:
          showAppSnackBar(
            context,
            message: l10n.chatMessageWidgetCalendarPermissionDenied,
            type: NotificationType.warning,
          );
        case DeviceToolToggleOutcome.notSupported:
          // The row should not be visible on unsupported platforms; if it is,
          // keep the tool off.
          break;
      }
    }

    final workspaceOn = assistant.workspaceEnabled;
    var workspaceReady = false;
    String workspaceSubtitle = l10n.workspaceEntrySubtitleOff;
    String directorySubtitle = l10n.workspaceBindDisabledHint;
    if (workspaceOn) {
      try {
        final wp = context.watch<WorkspaceProvider>();
        final ws = assistant.workspaceId == null
            ? null
            : wp.getById(assistant.workspaceId!);
        workspaceSubtitle = ws?.displayName ?? l10n.workspaceBindTitle;
        workspaceReady = ws != null;
        if (ws != null) {
          directorySubtitle =
              assistant.workspaceDefaultDirectories[ws.id] ?? '/workspace';
        }
      } on ProviderNotFoundException catch (e) {
        debugPrint('workspace provider missing: $e');
      } catch (e) {
        debugPrint('workspace subtitle: $e');
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _iosSectionCard(
          children: [
            _LocalToolNavRow(
              icon: Lucide.FolderOpen,
              title: l10n.assistantEditLocalToolWorkspaceTitle,
              subtitle: workspaceSubtitle,
              onTap: () => showWorkspaceBindSheet(context, assistant),
            ),
            _iosDivider(context),
            _LocalToolNavRow(
              icon: Lucide.FolderOpen,
              title: l10n.workspaceDefaultDirectoryTitle,
              subtitle: directorySubtitle,
              enabled: workspaceReady,
              onTap: workspaceReady
                  ? () => showWorkspaceDirectorySettings(
                      context,
                      assistantId: assistant.id,
                    )
                  : null,
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.clock,
              title: l10n.assistantEditLocalToolTimeInfoTitle,
              subtitle: l10n.assistantEditLocalToolTimeInfoSubtitle,
              enabled: timeEnabled,
              onChanged: (value) => updateTool(LocalToolNames.timeInfo, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Clipboard,
              title: l10n.assistantEditLocalToolClipboardTitle,
              subtitle: l10n.assistantEditLocalToolClipboardSubtitle,
              enabled: clipboardEnabled,
              onChanged: (value) => updateTool(LocalToolNames.clipboard, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Volume2,
              title: l10n.assistantEditLocalToolTextToSpeechTitle,
              subtitle: l10n.assistantEditLocalToolTextToSpeechSubtitle,
              enabled: textToSpeechEnabled,
              onChanged: (value) =>
                  updateTool(LocalToolNames.textToSpeech, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.MessageCircleQuestionMark,
              title: l10n.assistantEditLocalToolAskUserTitle,
              subtitle: l10n.assistantEditLocalToolAskUserSubtitle,
              enabled: askUserEnabled,
              onChanged: (value) => updateTool(LocalToolNames.askUser, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Calculator,
              title: l10n.assistantEditLocalToolCalculateTitle,
              subtitle: l10n.assistantEditLocalToolCalculateSubtitle,
              enabled: calculateEnabled,
              onChanged: (value) => updateTool(LocalToolNames.calculate, value),
            ),
            if (DeviceLocalTools.screenTimeSupported) ...[
              _iosDivider(context),
              _LocalToolRow(
                icon: Lucide.Smartphone,
                title: l10n.assistantEditLocalToolScreenTimeTitle,
                subtitle: l10n.assistantEditLocalToolScreenTimeSubtitle,
                enabled: screenTimeEnabled,
                onChanged: (value) =>
                    toggleTool(LocalToolNames.screenTime, value),
              ),
            ],
            if (DeviceLocalTools.calendarSupported) ...[
              _iosDivider(context),
              _LocalToolRow(
                icon: Lucide.Calendar,
                title: l10n.assistantEditLocalToolCalendarQueryTitle,
                subtitle: l10n.assistantEditLocalToolCalendarQuerySubtitle,
                enabled: calendarQueryEnabled,
                onChanged: (value) =>
                    toggleTool(LocalToolNames.calendarQuery, value),
              ),
              _iosDivider(context),
              _LocalToolRow(
                icon: Lucide.CalendarPlus,
                title: l10n.assistantEditLocalToolCalendarCreateTitle,
                subtitle: l10n.assistantEditLocalToolCalendarCreateSubtitle,
                enabled: calendarCreateEnabled,
                onChanged: (value) =>
                    toggleTool(LocalToolNames.calendarCreate, value),
              ),
            ],
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Bot,
              title: l10n.assistantEditLocalToolHandoffTitle,
              subtitle: l10n.assistantEditLocalToolHandoffSubtitle,
              enabled: handoffEnabled,
              onChanged: (value) => updateTool(LocalToolNames.handoff, value),
            ),
            _iosDivider(context),
            if (handoffEnabled)
              SubagentDelegationStatusRow(
                count: handoffTargets.length,
                onTap: () => pushSubagentDelegationPage(context),
              ),
          ],
        ),
      ],
    );
  }
}

class _LocalToolNavRow extends StatelessWidget {
  const _LocalToolNavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: onTap,
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return Opacity(
          opacity: enabled ? 1 : 0.55,
          child: _AnimatedPressColor(
            pressed: pressed,
            base: baseColor,
            builder: (color) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Icon(icon, size: 20, color: cs.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: color,
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.25,
                              color: cs.onSurface.withValues(alpha: 0.62),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Lucide.ChevronRight,
                      size: 18,
                      color: cs.onSurface.withValues(alpha: 0.35),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _LocalToolRow extends StatelessWidget {
  const _LocalToolRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: () => onChanged(!enabled),
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(
                      icon,
                      size: 20,
                      color: enabled ? cs.primary : color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: color,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: cs.onSurface.withValues(alpha: 0.62),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  IosSwitch(value: enabled, onChanged: onChanged),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
