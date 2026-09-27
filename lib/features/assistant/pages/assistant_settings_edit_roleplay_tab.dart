part of 'assistant_settings_edit_page.dart';

/// 角色扮演 tab: Ta的来信 ("Their Letter") — proactive care settings.
///
/// Android-only (see `_assistantEditTabSpecs`): letter delivery depends on
/// the Android alarm registry.
class AssistantSettingsEditRoleplayTab extends StatefulWidget {
  const AssistantSettingsEditRoleplayTab({
    super.key,
    required this.assistantId,
  });

  final String assistantId;

  @visibleForTesting
  static const Key conversationTimesSectionKey = ValueKey(
    'assistant-proactive-conversation-times',
  );
  @visibleForTesting
  static const Key permissionsSectionKey = ValueKey(
    'assistant-proactive-permissions',
  );

  @override
  State<AssistantSettingsEditRoleplayTab> createState() =>
      _AssistantSettingsEditRoleplayTabState();
}

class _AssistantSettingsEditRoleplayTabState
    extends State<AssistantSettingsEditRoleplayTab>
    with WidgetsBindingObserver {
  late final TextEditingController _carePromptCtrl;
  late final TextEditingController _decisionPromptCtrl;
  final AndroidProactiveCareSettingsService _settingsService =
      AndroidProactiveCareSettingsService();
  String? _boundAssistantId;
  AndroidProactiveCareSettingsStatus? _settingsStatus;
  bool _conversationTimesExpanded = false;
  bool _permissionsExpanded = false;
  bool _refreshingSettings = false;
  String? _activeSettingsAction;
  final Set<String> _savingConversationIds = <String>{};

  @override
  void initState() {
    super.initState();
    _carePromptCtrl = TextEditingController();
    _decisionPromptCtrl = TextEditingController();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshSettings());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncControllers();
  }

  @override
  void didUpdateWidget(covariant AssistantSettingsEditRoleplayTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assistantId != widget.assistantId) {
      _boundAssistantId = null;
      _syncControllers(force: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshSettings());
    }
  }

  void _syncControllers({bool force = false}) {
    final a = context.read<AssistantProvider>().getById(widget.assistantId);
    if (a == null) return;
    if (!force && _boundAssistantId == a.id) return;
    _boundAssistantId = a.id;

    final l10n = AppLocalizations.of(context)!;

    // Empty custom prompts display (and seed) the localized builtin defaults.
    final careText = a.proactiveCarePrompt.isEmpty
        ? l10n.assistantEditProactiveCarePromptDefault
        : a.proactiveCarePrompt;
    if (_carePromptCtrl.text != careText) {
      _carePromptCtrl.text = careText;
    }
    final decisionText = a.proactiveCareDecisionPrompt.isEmpty
        ? l10n.assistantEditProactiveCareDecisionPromptDefault
        : a.proactiveCareDecisionPrompt;
    if (_decisionPromptCtrl.text != decisionText) {
      _decisionPromptCtrl.text = decisionText;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _carePromptCtrl.dispose();
    _decisionPromptCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshSettings() async {
    if (_refreshingSettings) return;
    _refreshingSettings = true;
    final status = await _settingsService.queryStatus();
    _refreshingSettings = false;
    if (mounted) setState(() => _settingsStatus = status);
  }

  Future<void> _setConversationTime(
    Conversation conversation,
    DateTime? value,
  ) async {
    if (_savingConversationIds.contains(conversation.id)) return;
    setState(() => _savingConversationIds.add(conversation.id));
    try {
      // The central extras hook in ChatService re-arms (or cancels) the
      // Android letter alarm for this conversation.
      await context.read<ChatService>().updateConversationExtras(
        conversation.id,
        (extras) {
          if (value == null) {
            extras.remove(Conversation.proactiveCareNextMessageAtKey);
          } else {
            extras[Conversation.proactiveCareNextMessageAtKey] = value
                .toIso8601String();
          }
          return extras;
        },
      );
    } catch (error) {
      debugPrint(
        '[AssistantProactiveCare] Failed to update ${conversation.id}: $error',
      );
      if (mounted) {
        showAppSnackBar(
          context,
          message: AppLocalizations.of(
            context,
          )!.conversationProactiveCareUpdateFailed,
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _savingConversationIds.remove(conversation.id));
      }
    }
  }

  Future<void> _pickNextMessageTime(Conversation conversation) async {
    final picked = await showProactiveCareDateTimePicker(
      context,
      initial: conversation.proactiveCareNextMessageAt,
    );
    if (!mounted || picked == null) return;
    await _setConversationTime(conversation, picked);
  }

  Future<void> _onProactiveCareChanged(Assistant a, bool enabled) async {
    await context.read<AssistantProvider>().updateAssistant(
      a.copyWith(enableProactiveCare: enabled),
    );
  }

  List<Conversation> _eligibleConversations(
    ChatService chatService,
    Assistant assistant,
    DateTime now,
  ) {
    final indexed = chatService
        .getAllConversations()
        .where(
          (conversation) => ProactiveCareConversationPolicy.isEligible(
            conversation,
            assistant,
          ),
        )
        .indexed
        .toList();
    int category(Conversation conversation) {
      final time = conversation.proactiveCareNextMessageAt;
      if (time == null) return 2;
      return time.isAfter(now) ? 0 : 1;
    }

    indexed.sort((left, right) {
      final leftCategory = category(left.$2);
      final rightCategory = category(right.$2);
      final categoryOrder = leftCategory.compareTo(rightCategory);
      if (categoryOrder != 0) return categoryOrder;
      if (leftCategory == 0) {
        final timeOrder = left.$2.proactiveCareNextMessageAt!.compareTo(
          right.$2.proactiveCareNextMessageAt!,
        );
        if (timeOrder != 0) return timeOrder;
      }
      return left.$1.compareTo(right.$1);
    });
    return indexed.map((entry) => entry.$2).toList();
  }

  AndroidProactiveCareSettingState _notificationState() {
    final status = _settingsStatus;
    if (status == null) return AndroidProactiveCareSettingState.unknown;
    final states = <AndroidProactiveCareSettingState>[
      status.appNotifications,
      status.proactiveCareChannel,
    ];
    if (states.every(
      (state) => state == AndroidProactiveCareSettingState.ready,
    )) {
      return AndroidProactiveCareSettingState.ready;
    }
    if (states.contains(AndroidProactiveCareSettingState.notReady)) {
      return AndroidProactiveCareSettingState.notReady;
    }
    return AndroidProactiveCareSettingState.unknown;
  }

  Future<void> _runSettingsAction(
    String action,
    Future<void> Function() operation,
  ) async {
    if (_activeSettingsAction != null) return;
    setState(() => _activeSettingsAction = action);
    try {
      await operation();
    } finally {
      if (mounted) setState(() => _activeSettingsAction = null);
      await _refreshSettings();
    }
  }

  Future<void> _handleNotifications() =>
      _runSettingsAction('notifications', () async {
        if (_settingsStatus?.appNotifications !=
            AndroidProactiveCareSettingState.ready) {
          final state = await _settingsService.requestNotifications();
          if (state != AndroidProactiveCareSettingState.ready) {
            await _settingsService.openAppNotificationSettings();
          }
        } else {
          await _settingsService.openProactiveCareChannelSettings();
        }
      });

  Future<void> _handleExactAlarm() =>
      _runSettingsAction('exactAlarm', () async {
        final state = await _settingsService.requestExactAlarm();
        if (!mounted || state != AndroidProactiveCareSettingState.ready) return;
        final chatService = context.read<ChatService>();
        await ProactiveCareAlarmService.rescheduleAll(
          conversations: chatService.getAllConversations(),
          assistants: context.read<AssistantProvider>().assistants,
        );
      });

  Future<void> _handleAutoStart() => _runSettingsAction(
    'autoStart',
    () async => _settingsService.openAutoStartSettings(),
  );

  Future<void> _handleBattery() => _runSettingsAction(
    'battery',
    () async => _settingsService.requestBatteryOptimizationExemption(),
  );

  String _statusLabel(
    AppLocalizations l10n,
    AndroidProactiveCareSettingState state,
  ) => switch (state) {
    AndroidProactiveCareSettingState.ready =>
      l10n.assistantEditProactiveCarePermissionReady,
    AndroidProactiveCareSettingState.notReady =>
      l10n.assistantEditProactiveCarePermissionMissing,
    AndroidProactiveCareSettingState.manual =>
      l10n.assistantEditProactiveCarePermissionManual,
    AndroidProactiveCareSettingState.unknown ||
    AndroidProactiveCareSettingState.notApplicable =>
      l10n.assistantEditProactiveCarePermissionUnknown,
  };

  Widget _conversationRow(
    BuildContext context,
    Conversation conversation,
    DateTime now,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final saving = _savingConversationIds.contains(conversation.id);
    final time = conversation.proactiveCareNextMessageAt;
    String statusText;
    if (time == null) {
      statusText = l10n.assistantEditProactiveCareConversationTimeUnset;
    } else {
      final formatted = proactiveCareNextMessageLabel(context, time);
      statusText = time.isAfter(now)
          ? l10n.assistantEditProactiveCareConversationTimeFuture(formatted)
          : l10n.assistantEditProactiveCareConversationTimeExpired(formatted);
    }
    return IosCardPress(
      key: ValueKey('assistant-proactive-conversation-${conversation.id}'),
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      haptics: false,
      onTap: saving ? null : () => _pickNextMessageTime(conversation),
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: cs.onSurface),
                ),
                const SizedBox(height: 3),
                Text(
                  statusText,
                  key: ValueKey(
                    'assistant-proactive-conversation-status-${conversation.id}',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          if (time != null)
            Tooltip(
              message: l10n.conversationProactiveCareClearTime,
              child: IosIconButton(
                key: ValueKey(
                  'assistant-proactive-conversation-clear-${conversation.id}',
                ),
                icon: Lucide.X,
                size: 17,
                minSize: 40,
                color: cs.onSurface.withValues(alpha: 0.55),
                enabled: !saving,
                semanticLabel: l10n.conversationProactiveCareClearTime,
                onTap: () => _setConversationTime(conversation, null),
              ),
            ),
          Icon(
            Lucide.ChevronRight,
            size: 17,
            color: cs.onSurface.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }

  Widget _permissionRow(
    BuildContext context, {
    required String keyName,
    required IconData icon,
    required String title,
    required String importance,
    required AndroidProactiveCareSettingState state,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final active = _activeSettingsAction == keyName;
    return IosCardPress(
      key: ValueKey('assistant-proactive-permission-$keyName'),
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      haptics: false,
      onTap: _activeSettingsAction == null ? onTap : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        children: [
          SizedBox(width: 36, child: Icon(icon, size: 20, color: cs.primary)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 15, color: cs.onSurface),
                ),
                const SizedBox(height: 3),
                Text(
                  importance,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          if (active)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: cs.primary,
              ),
            )
          else
            Text(
              _statusLabel(AppLocalizations.of(context)!, state),
              key: ValueKey('assistant-proactive-permission-status-$keyName'),
              style: TextStyle(
                fontSize: 13,
                color: state == AndroidProactiveCareSettingState.ready
                    ? context.appColors.success
                    : cs.onSurface.withValues(alpha: 0.58),
              ),
            ),
          const SizedBox(width: 6),
          Icon(
            Lucide.ChevronRight,
            size: 16,
            color: cs.onSurface.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final a = context.watch<AssistantProvider>().getById(widget.assistantId);
    if (a == null) {
      return const SizedBox.shrink();
    }

    final chatService = context.watch<ChatService>();
    final now = DateTime.now();
    final conversations = _eligibleConversations(chatService, a, now);
    final status = _settingsStatus;
    const unknown = AndroidProactiveCareSettingState.unknown;

    return ListView(
      key: const ValueKey('assistant-roleplay-tab'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Row(
            children: [
              Icon(Lucide.HeartPulse, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                l10n.assistantEditProactiveCareFeatureTitle,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.onSurface.withValues(alpha: 0.92),
                ),
              ),
            ],
          ),
        ),
        SectionCard(
          children: [
            IosSwitchRow(
              icon: Lucide.HeartPulse,
              label: l10n.assistantEditProactiveCareEnableTitle,
              value: a.enableProactiveCare,
              onChanged: (v) => _onProactiveCareChanged(a, v),
              subtitle: l10n.assistantEditProactiveCareDefaultDescription,
            ),
            const IosRowDivider(),
            KeyedSubtree(
              key: const ValueKey('assistant-proactive-decision-history-limit'),
              child: IosNavRow(
                icon: Lucide.MessagesSquare,
                label: l10n.assistantEditProactiveCareDecisionHistoryLimitTitle,
                detailText:
                    a.proactiveCareDecisionHistoryMessageLimit?.toString() ??
                    l10n.assistantEditParameterDisabled2,
                onTap: () => _showAssistantMessageLimitSheet(
                  context,
                  assistantId: a.id,
                  title:
                      l10n.assistantEditProactiveCareDecisionHistoryLimitTitle,
                  description: l10n
                      .assistantEditProactiveCareDecisionHistoryLimitDescription,
                  isEnabled: (assistant) =>
                      assistant.proactiveCareDecisionHistoryMessageLimit !=
                      null,
                  readValue: (assistant) =>
                      assistant.proactiveCareDecisionHistoryMessageLimit ??
                      assistant.contextMessageSize,
                  writeLimit: (assistant, limit) => limit == null
                      ? assistant.copyWith(
                          clearProactiveCareDecisionHistoryMessageLimit: true,
                        )
                      : assistant.copyWith(
                          proactiveCareDecisionHistoryMessageLimit: limit,
                        ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _RoleplayExpandableCard(
          key: AssistantSettingsEditRoleplayTab.conversationTimesSectionKey,
          icon: Lucide.MessageSquare,
          title: l10n.assistantEditProactiveCareConversationTimesTitle,
          expanded: _conversationTimesExpanded,
          onToggle: () => setState(
            () => _conversationTimesExpanded = !_conversationTimesExpanded,
          ),
          children: conversations.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    child: Text(
                      l10n.assistantEditProactiveCareNoEligibleConversations,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.58),
                      ),
                    ),
                  ),
                ]
              : [
                  for (final conversation in conversations)
                    _conversationRow(context, conversation, now),
                ],
        ),
        const SizedBox(height: 12),
        _RoleplayExpandableCard(
          key: AssistantSettingsEditRoleplayTab.permissionsSectionKey,
          icon: Lucide.Shield,
          title: l10n.assistantEditProactiveCarePermissionsTitle,
          expanded: _permissionsExpanded,
          onToggle: () =>
              setState(() => _permissionsExpanded = !_permissionsExpanded),
          children: [
            _permissionRow(
              context,
              keyName: 'notifications',
              icon: Lucide.MessageCircle,
              title: l10n.assistantEditProactiveCareNotificationsTitle,
              importance: l10n.assistantEditProactiveCarePermissionRequired,
              state: _notificationState(),
              onTap: _handleNotifications,
            ),
            _permissionRow(
              context,
              keyName: 'exactAlarm',
              icon: Lucide.Timer,
              title: l10n.assistantEditProactiveCareExactAlarmTitle,
              importance: l10n.assistantEditProactiveCarePermissionRequired,
              state: status?.exactAlarms ?? unknown,
              onTap: _handleExactAlarm,
            ),
            _permissionRow(
              context,
              keyName: 'autoStart',
              icon: Lucide.Smartphone,
              title: l10n.assistantEditProactiveCareAutoStartTitle,
              importance: l10n.assistantEditProactiveCarePermissionRecommended,
              state: status?.autoStart ?? unknown,
              onTap: _handleAutoStart,
            ),
            _permissionRow(
              context,
              keyName: 'battery',
              icon: Lucide.Zap,
              title: l10n.assistantEditProactiveCareBatteryTitle,
              importance: l10n.assistantEditProactiveCarePermissionRecommended,
              state: status?.batteryOptimizationExemption ?? unknown,
              onTap: _handleBattery,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          l10n.assistantEditProactiveCarePromptTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: AppFontWeights.emphasis,
            color: cs.onSurface.withValues(alpha: 0.92),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _carePromptCtrl,
          onChanged: (v) => context.read<AssistantProvider>().updateAssistant(
            a.copyWith(proactiveCarePrompt: v),
          ),
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          decoration: _promptDecoration(
            context,
            hint: l10n.assistantEditProactiveCarePromptHint,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.assistantEditProactiveCareDecisionPromptTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: AppFontWeights.emphasis,
            color: cs.onSurface.withValues(alpha: 0.92),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _decisionPromptCtrl,
          onChanged: (v) => context.read<AssistantProvider>().updateAssistant(
            a.copyWith(proactiveCareDecisionPrompt: v),
          ),
          maxLines: null,
          minLines: 8,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          decoration: _promptDecoration(context),
        ),
      ],
    );
  }
}

/// Collapsible card used by the roleplay tab sections (letter times,
/// Android runtime conditions).
class _RoleplayExpandableCard extends StatelessWidget {
  const _RoleplayExpandableCard({
    super.key,
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IosCardPress(
            baseColor: Colors.transparent,
            borderRadius: BorderRadius.zero,
            onTap: onToggle,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Icon(icon, size: 20, color: cs.onSurface),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 15, color: cs.onSurface),
                  ),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Lucide.ChevronRight,
                    size: 17,
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
          if (expanded)
            ClipRect(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
        ],
      ),
    );
  }
}

InputDecoration _promptDecoration(BuildContext context, {String? hint}) {
  final cs = Theme.of(context).colorScheme;
  return InputDecoration(
    hintText: hint,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.35)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.5)),
    ),
    contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
  );
}

Future<void> _showAssistantMessageLimitSheet(
  BuildContext context, {
  required String assistantId,
  required String title,
  required String description,
  required bool Function(Assistant assistant) isEnabled,
  required int Function(Assistant assistant) readValue,
  required Assistant Function(Assistant assistant, int? limit) writeLimit,
}) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: false,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Builder(
            builder: (context) {
              final cs = Theme.of(context).colorScheme;
              final assistant = context.watch<AssistantProvider>().getById(
                assistantId,
              );
              if (assistant == null) return const SizedBox.shrink();
              final enabled = isEnabled(assistant);
              final value = _clampContextMessages(readValue(assistant));
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                      ),
                      IosSwitch(
                        value: enabled,
                        onChanged: (nextEnabled) async {
                          final provider = context.read<AssistantProvider>();
                          final current = provider.getById(assistantId);
                          if (current == null) return;
                          final navigator = Navigator.of(sheetContext);
                          await provider.updateAssistant(
                            writeLimit(current, nextEnabled ? value : null),
                          );
                          if (navigator.mounted) navigator.pop();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (enabled) ...[
                    _SliderTileNew(
                      value: value.toDouble(),
                      min: _contextMessageMin.toDouble(),
                      max: _contextMessageMax.toDouble(),
                      divisions: _contextMessageMax - _contextMessageMin,
                      label: value.toString(),
                      customLabelStops: const <double>[
                        1.0,
                        64.0,
                        128.0,
                        256.0,
                        512.0,
                        1024.0,
                      ],
                      onLabelTap: () async {
                        final chosen = await _showContextMessageInputDialog(
                          context,
                          initialValue: value,
                        );
                        if (!context.mounted || chosen == null) return;
                        final provider = context.read<AssistantProvider>();
                        final current = provider.getById(assistantId);
                        if (current == null) return;
                        await provider.updateAssistant(
                          writeLimit(current, chosen),
                        );
                      },
                      onChanged: (nextValue) {
                        final provider = context.read<AssistantProvider>();
                        final current = provider.getById(assistantId);
                        if (current == null) return;
                        provider.updateAssistant(
                          writeLimit(current, _clampContextMessages(nextValue)),
                        );
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ] else ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l10n.assistantEditParameterDisabled2,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
