part of 'assistant_settings_edit_page.dart';

class AssistantProactiveLetterTab extends StatefulWidget {
  const AssistantProactiveLetterTab({
    super.key,
    required this.assistantId,
    this.settingsService,
  });

  final String assistantId;
  final AndroidProactiveCareSettingsService? settingsService;

  @override
  State<AssistantProactiveLetterTab> createState() =>
      _AssistantProactiveLetterTabState();
}

class _AssistantProactiveLetterTabState
    extends State<AssistantProactiveLetterTab>
    with WidgetsBindingObserver {
  late final TextEditingController _carePromptCtrl;
  late final TextEditingController _decisionPromptCtrl;
  late AndroidProactiveCareSettingsService _settingsService;
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
    _settingsService =
        widget.settingsService ?? AndroidProactiveCareSettingsService();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshSettings());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncControllers();
  }

  @override
  void didUpdateWidget(covariant AssistantProactiveLetterTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assistantId != widget.assistantId) {
      _boundAssistantId = null;
      _syncControllers(force: true);
    }
    if (oldWidget.settingsService != widget.settingsService) {
      _settingsService =
          widget.settingsService ?? AndroidProactiveCareSettingsService();
      unawaited(_refreshSettings());
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
    final defaultDecision =
        l10n.assistantEditProactiveCareDecisionPromptDefault;

    final careText = a.proactiveCarePrompt.isEmpty
        ? l10n.assistantEditProactiveCarePromptDefault
        : a.proactiveCarePrompt;
    if (_carePromptCtrl.text != careText) {
      _carePromptCtrl.text = careText;
    }
    final decisionText = a.proactiveCareDecisionPrompt.isEmpty
        ? defaultDecision
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

  InputDecoration _promptDecoration(BuildContext context, {String? hint}) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      hintText: hint,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: cs.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.5)),
      ),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
    );
  }

  Future<void> _refreshSettings() async {
    if (_refreshingSettings) return;
    _refreshingSettings = true;
    final status = await _settingsService.queryStatus();
    _refreshingSettings = false;
    if (mounted) setState(() => _settingsStatus = status);
  }

  Future<void> _pickNextMessageTime(Conversation conversation) async {
    final picked = await showProactiveCareDateTimePicker(
      context,
      initial: conversation.proactiveCareNextMessageAt,
    );
    if (!mounted || picked == null) return;
    await _setConversationTime(conversation, picked);
  }

  Future<void> _setConversationTime(
    Conversation conversation,
    DateTime? value,
  ) async {
    if (_savingConversationIds.contains(conversation.id)) return;
    setState(() => _savingConversationIds.add(conversation.id));
    try {
      await context
          .read<ChatService>()
          .setConversationProactiveCareNextMessageAt(conversation.id, value);
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
          (conversation) =>
              !chatService.isDraftConversation(conversation.id) &&
              ProactiveCareConversationPolicy.isEligible(
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

  String _conversationTimeStatus(
    BuildContext context,
    Conversation conversation,
    DateTime now,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final time = conversation.proactiveCareNextMessageAt;
    if (time == null) {
      return l10n.assistantEditProactiveCareConversationTimeUnset;
    }
    final formatted = proactiveCareNextMessageLabel(context, time);
    return time.isAfter(now)
        ? l10n.assistantEditProactiveCareConversationTimeFuture(formatted)
        : l10n.assistantEditProactiveCareConversationTimeExpired(formatted);
  }

  Widget _conversationRow(
    BuildContext context,
    Conversation conversation,
    DateTime now,
  ) {
    final cs = Theme.of(context).colorScheme;
    final saving = _savingConversationIds.contains(conversation.id);
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
                  _conversationTimeStatus(context, conversation, now),
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
          if (conversation.proactiveCareNextMessageAt != null)
            Tooltip(
              message: AppLocalizations.of(
                context,
              )!.conversationProactiveCareClearTime,
              child: IosIconButton(
                key: ValueKey(
                  'assistant-proactive-conversation-clear-${conversation.id}',
                ),
                icon: Lucide.X,
                size: 17,
                minSize: 40,
                color: cs.onSurface.withValues(alpha: 0.55),
                enabled: !saving,
                semanticLabel: AppLocalizations.of(
                  context,
                )!.conversationProactiveCareClearTime,
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _iosSectionCard(
          children: [
            _iosSwitchRow(
              context,
              icon: Lucide.HeartPulse,
              label: l10n.assistantEditProactiveCareEnableTitle,
              value: a.enableProactiveCare,
              onChanged: (v) => _onProactiveCareChanged(a, v),
              subtitle: l10n.assistantEditProactiveCareDefaultDescription,
            ),
          ],
        ),
        const SizedBox(height: 12),
        IosExpandableSection(
          key: const ValueKey('assistant-proactive-conversation-times'),
          icon: Lucide.MessageSquare,
          title: l10n.assistantEditProactiveCareConversationTimesTitle,
          expanded: _conversationTimesExpanded,
          onToggle: () => setState(
            () => _conversationTimesExpanded = !_conversationTimesExpanded,
          ),
          showDivider: true,
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
        IosExpandableSection(
          key: const ValueKey('assistant-proactive-permissions'),
          icon: Lucide.Shield,
          title: l10n.assistantEditProactiveCarePermissionsTitle,
          expanded: _permissionsExpanded,
          onToggle: () =>
              setState(() => _permissionsExpanded = !_permissionsExpanded),
          showDivider: true,
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
