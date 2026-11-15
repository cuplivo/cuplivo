part of 'assistant_settings_edit_page.dart';

class _BasicSettingsTab extends StatefulWidget {
  const _BasicSettingsTab({required this.assistantId});
  final String assistantId;

  @override
  State<_BasicSettingsTab> createState() => _BasicSettingsTabState();
}

class _BasicSettingsTabState extends State<_BasicSettingsTab> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _maxTokensCtrl;
  late final TextEditingController _backgroundCtrl;

  @override
  void initState() {
    super.initState();
    final ap = context.read<AssistantProvider>();
    final a = ap.getById(widget.assistantId)!;
    _nameCtrl = TextEditingController(text: a.name);
    _maxTokensCtrl = TextEditingController(text: a.maxTokens?.toString() ?? '');
    _backgroundCtrl = TextEditingController(text: a.background ?? '');
  }

  @override
  void didUpdateWidget(covariant _BasicSettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assistantId != widget.assistantId) {
      final ap = context.read<AssistantProvider>();
      final a = ap.getById(widget.assistantId)!;
      _nameCtrl.text = a.name;
      _maxTokensCtrl.text = a.maxTokens?.toString() ?? '';
      _backgroundCtrl.text = a.background ?? '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _maxTokensCtrl.dispose();
    _backgroundCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ap = context.watch<AssistantProvider>();
    final a = ap.getById(widget.assistantId)!;
    final settingsProvider = context.watch<SettingsProvider>();

    Widget avatarWidget({double size = 56}) {
      final bg = cs.primary.withValues(alpha: isDark ? 0.18 : 0.12);
      Widget inner;
      final av = a.avatar?.trim();
      if (av != null && av.isNotEmpty) {
        if (av.startsWith('http')) {
          inner = FutureBuilder<String?>(
            future: AvatarCache.getPath(av),
            builder: (ctx, snap) {
              final p = snap.data;
              if (p != null && File(p).existsSync()) {
                return ClipOval(
                  child: Image.file(
                    File(p),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                  ),
                );
              }
              return ClipOval(
                child: Image.network(
                  av,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
              );
            },
          );
        } else if (av.startsWith('/') || av.contains(':')) {
          final fixed = SandboxPathResolver.fix(av);
          inner = ClipOval(
            child: Image.file(
              File(fixed),
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
          );
        } else {
          inner = Text(
            av,
            style: TextStyle(
              color: cs.primary,
              fontWeight: AppFontWeights.emphasis,
              fontSize: size * 0.42,
            ),
          );
        }
      } else {
        inner = Text(
          (a.name.trim().isNotEmpty
              ? String.fromCharCode(a.name.trim().runes.first).toUpperCase()
              : 'A'),
          style: TextStyle(
            color: cs.primary,
            fontWeight: AppFontWeights.emphasis,
            fontSize: size * 0.42,
          ),
        );
      }
      return InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _showAvatarPicker(context, a),
        child: CircleAvatar(
          radius: size / 2,
          backgroundColor: bg,
          child: inner,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // Identity card (avatar + name) - iOS style
        SectionCard(
          radius: 16,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              avatarWidget(size: 64),
              const SizedBox(width: 14),
              Expanded(
                child: _InputRow(
                  label: l10n.assistantEditAssistantNameLabel,
                  controller: _nameCtrl,
                  onChanged: (v) => context
                      .read<AssistantProvider>()
                      .updateAssistant(a.copyWith(name: v)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // iOS section card with all settings (without Use Assistant Avatar and Stream Output)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 0),
          child: SectionCard(
            children: [
              // Temperature
              _iosNavRow(
                context,
                icon: Lucide.Thermometer,
                label: 'Temperature',
                detailText: a.temperature != null
                    ? a.temperature!.toStringAsFixed(2)
                    : l10n.assistantEditParameterDisabled,
                onTap: () => _showTemperatureSheet(context, a),
              ),
              _iosDivider(context),
              // Top P
              _iosNavRow(
                context,
                icon: Lucide.Wand2,
                label: 'Top P',
                detailText: a.topP != null
                    ? a.topP!.toStringAsFixed(2)
                    : l10n.assistantEditParameterDisabled,
                onTap: () => _showTopPSheet(context, a),
              ),
              _iosDivider(context),
              // Context messages
              _iosNavRow(
                context,
                icon: Lucide.MessagesSquare,
                label: l10n.assistantEditContextMessagesTitle,
                detailText: a.limitContextMessages
                    ? a.contextMessageSize.toString()
                    : l10n.assistantEditParameterDisabled2,
                onTap: () => _showContextMessagesSheet(context, a),
              ),
              _iosDivider(context),
              // Thinking / reasoning default
              _iosNavRow(
                context,
                icon: Lucide.Brain,
                label: l10n.assistantEditThinkingBudgetTitle,
                tip: l10n.assistantEditReasoningClampedSubtitle,
                detailText: a.reasoning == null
                    ? l10n.assistantEditReasoningFollowDefault
                    : reasoningLevelLabel(l10n, a.reasoning!.level),
                onTap: () async {
                  final assistantProvider = context.read<AssistantProvider>();
                  final picked = await showAssistantReasoningPicker(
                    context,
                    current: a.reasoning,
                  );
                  if (!context.mounted || picked == null) return;
                  if (picked.request == a.reasoning) return;
                  await assistantProvider.updateAssistant(
                    picked.request == null
                        ? a.copyWith(clearReasoning: true)
                        : a.copyWith(reasoning: picked.request),
                  );
                },
              ),
              _iosDivider(context),
              // Max tokens
              _iosNavRow(
                context,
                icon: Lucide.Hash,
                label: l10n.assistantEditMaxTokensTitle,
                detailText:
                    a.maxTokens?.toString() ?? l10n.assistantEditMaxTokensHint,
                onTap: () => _showMaxTokensSheet(context, a),
              ),
              _iosDivider(context),
              AssistantDefaultWorkspaceRow(assistantId: widget.assistantId),
              _iosDivider(context),
              // Use assistant avatar
              _iosSwitchRow(
                context,
                icon: Lucide.User,
                label: l10n.assistantEditUseAssistantAvatarTitle,
                value: a.useAssistantAvatar,
                onChanged: (v) => context
                    .read<AssistantProvider>()
                    .updateAssistant(a.copyWith(useAssistantAvatar: v)),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.CaseSensitive,
                label: l10n.assistantEditUseAssistantNameTitle,
                value: a.useAssistantName,
                onChanged: (v) => context
                    .read<AssistantProvider>()
                    .updateAssistant(a.copyWith(useAssistantName: v)),
              ),
              _iosDivider(context),
              // Stream output
              _iosSwitchRow(
                context,
                icon: Lucide.Zap,
                label: l10n.assistantEditStreamOutputTitle,
                value: a.streamOutput,
                onChanged: (v) => context
                    .read<AssistantProvider>()
                    .updateAssistant(a.copyWith(streamOutput: v)),
              ),
              _iosDivider(context),
              // Chat suggestions: a per-assistant opt-out of the global switch.
              KeyedSubtree(
                key: _chatSuggestionsSwitchKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _iosSwitchRow(
                      context,
                      icon: Lucide.MessagesSquare,
                      label: l10n.assistantEditChatSuggestionsTitle,
                      tip: l10n.assistantEditChatSuggestionsTip,
                      value: a.suggestionsEnabled,
                      onChanged: (v) => context
                          .read<AssistantProvider>()
                          .updateAssistant(a.copyWith(suggestionsEnabled: v)),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: settingsProvider.isSuggestionOptOutInactiveFor(a)
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(48, 0, 44, 8),
                              child: Text(
                                l10n.assistantEditChatSuggestionsGlobalOff,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: cs.onSurface.withValues(alpha: 0.58),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Chat model card (moved down, styled like DefaultModelPage)
        SectionCard(
          radius: 16,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Lucide.MessageCircle, size: 18, color: cs.onSurface),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.assistantEditChatModelTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                  if (a.chatModelProvider != null && a.chatModelId != null)
                    Tooltip(
                      message: l10n.defaultModelPageResetDefault,
                      child: _TactileIconButton(
                        icon: Lucide.RotateCcw,
                        color: cs.onSurface,
                        size: 20,
                        onTap: () async {
                          await context
                              .read<AssistantProvider>()
                              .updateAssistant(
                                a.copyWith(clearChatModel: true),
                              );
                        },
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                l10n.assistantEditChatModelSubtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 8),
              _TactileRow(
                onTap: () async {
                  final assistantProvider = context.read<AssistantProvider>();
                  final sel = await showModelSelector(
                    context,
                    initialProviderKey: a.chatModelProvider,
                    initialModelId: a.chatModelId,
                  );
                  if (!context.mounted || sel == null) return;
                  await assistantProvider.updateAssistant(
                    a.copyWith(
                      chatModelProvider: sel.providerKey,
                      chatModelId: sel.modelId,
                    ),
                  );
                },
                pressedScale: 0.98,
                builder: (pressed) {
                  final bg = context.appColors.surfaceFill;
                  final overlay = cs.onSurface.withValues(
                    alpha: isDark ? 0.06 : 0.05,
                  );
                  final pressedBg = Color.alphaBlend(overlay, bg);
                  final l10n = AppLocalizations.of(context)!;
                  final settings = context.read<SettingsProvider>();
                  String display = l10n.assistantEditModelUseGlobalDefault;
                  if (a.chatModelProvider != null && a.chatModelId != null) {
                    try {
                      final cfg = settings.getProviderConfig(
                        a.chatModelProvider!,
                      );
                      final ov = cfg.modelOverrides[a.chatModelId] as Map?;
                      final mdl =
                          (ov != null &&
                              (ov['name'] as String?)?.isNotEmpty == true)
                          ? (ov['name'] as String)
                          : a.chatModelId!;
                      display = mdl;
                    } catch (_) {
                      display = a.chatModelId ?? '';
                    }
                  }
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: pressed ? pressedBg : bg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        CurrentModelIcon(
                          providerKey:
                              a.chatModelProvider ??
                              settings.currentModelProvider,
                          modelId: a.chatModelId ?? settings.currentModelId,
                          size: 24,
                          iconScale: .62,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            display,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Chat background (separate iOS card)
        SectionCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Lucide.Image, size: 18, color: cs.onSurface),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.assistantEditChatBackgroundTitle,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              AssistantGradientSettings(assistant: a),
              if (!a.useGradientBackground) ...[
                const SizedBox(height: 6),
                Text(
                  l10n.assistantEditChatBackgroundDescription,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 8),
                if ((a.background ?? '').isEmpty) ...[
                  // Single button when no background (full width)
                  _TactileRow(
                    onTap: () => _pickBackground(context, a),
                    pressedScale: 0.98,
                    builder: (pressed) {
                      final bg = context.appColors.surfaceFill;
                      final overlay = cs.onSurface.withValues(
                        alpha: isDark ? 0.06 : 0.05,
                      );
                      final pressedBg = Color.alphaBlend(overlay, bg);
                      final iconColor = cs.onSurface.withValues(alpha: 0.75);
                      final textColor = cs.onSurface.withValues(alpha: 0.9);
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: pressed ? pressedBg : bg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: cs.outlineVariant.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 2.0,
                              ), // Material icon spacing
                              child: Icon(
                                Icons.image,
                                size: 18,
                                color: iconColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              l10n.assistantEditChooseImageButton,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: AppFontWeights.semibold,
                                color: textColor,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ] else ...[
                  // Two buttons when background exists
                  Row(
                    children: [
                      Expanded(
                        child: _IosButton(
                          label: l10n.assistantEditChooseImageButton,
                          icon: Icons.image,
                          onTap: () => _pickBackground(context, a),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _IosButton(
                          label: l10n.assistantEditClearButton,
                          icon: Lucide.X,
                          onTap: () =>
                              context.read<AssistantProvider>().updateAssistant(
                                a.copyWith(clearBackground: true),
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
                if ((a.background ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _BackgroundPreview(path: a.background!),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showAvatarPicker(BuildContext context, Assistant a) async {
    await showAvatarMenu(
      context,
      value: a.avatar,
      onSelected: (avatar) async {
        await context.read<AssistantProvider>().updateAssistant(
          a.copyWith(avatar: avatar, clearAvatar: avatar == null),
        );
      },
    );
  }

  Future<void> _pickBackground(BuildContext context, Assistant a) async {
    try {
      final assistantProvider = context.read<AssistantProvider>();
      final picker = ImagePicker();
      final XFile? file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        imageQuality: 85,
      );
      if (!context.mounted || file == null) return;
      await assistantProvider.updateAssistant(
        a.copyWith(background: file.path),
      );
    } catch (_) {}
  }

  Future<void> _showTemperatureSheet(BuildContext context, Assistant a) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet(
      context: context,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: false,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Builder(
              builder: (context) {
                final theme = Theme.of(context);
                final cs = theme.colorScheme;
                final value =
                    context
                        .watch<AssistantProvider>()
                        .getById(widget.assistantId)
                        ?.temperature ??
                    Assistant.defaultTemperature;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
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
                            'Temperature',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                        ),
                        IosSwitch(
                          value: a.temperature != null,
                          onChanged: (v) async {
                            final assistantProvider = context
                                .read<AssistantProvider>();
                            final navigator = Navigator.of(ctx);
                            if (v) {
                              await assistantProvider.updateAssistant(
                                a.copyWith(
                                  temperature: Assistant.defaultTemperature,
                                ),
                              );
                            } else {
                              await assistantProvider.updateAssistant(
                                a.copyWith(clearTemperature: true),
                              );
                            }
                            if (navigator.mounted) navigator.pop();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (a.temperature != null) ...[
                      _SliderTileNew(
                        value: value.clamp(0.0, 2.0),
                        min: 0.0,
                        max: 2.0,
                        divisions: 20,
                        label: value.toStringAsFixed(2),
                        onChanged: (v) => context
                            .read<AssistantProvider>()
                            .updateAssistant(a.copyWith(temperature: v)),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.assistantEditTemperatureDescription,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ] else ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          l10n.assistantEditParameterDisabled,
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

  Future<void> _showTopPSheet(BuildContext context, Assistant a) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet(
      context: context,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: false,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Builder(
              builder: (context) {
                final theme = Theme.of(context);
                final cs = theme.colorScheme;
                final value =
                    context
                        .watch<AssistantProvider>()
                        .getById(widget.assistantId)
                        ?.topP ??
                    1.0;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
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
                            'Top P',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                        ),
                        IosSwitch(
                          value: a.topP != null,
                          onChanged: (v) async {
                            final assistantProvider = context
                                .read<AssistantProvider>();
                            final navigator = Navigator.of(ctx);
                            if (v) {
                              await assistantProvider.updateAssistant(
                                a.copyWith(topP: 1.0),
                              );
                            } else {
                              await assistantProvider.updateAssistant(
                                a.copyWith(clearTopP: true),
                              );
                            }
                            if (navigator.mounted) navigator.pop();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (a.topP != null) ...[
                      _SliderTileNew(
                        value: value.clamp(0.0, 1.0),
                        min: 0.0,
                        max: 1.0,
                        divisions: 20,
                        label: value.toStringAsFixed(2),
                        onChanged: (v) => context
                            .read<AssistantProvider>()
                            .updateAssistant(a.copyWith(topP: v)),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.assistantEditTopPDescription,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ] else ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          l10n.assistantEditParameterDisabled,
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

  Future<void> _showContextMessagesSheet(
    BuildContext context,
    Assistant a,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet(
      context: context,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: false,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Builder(
              builder: (context) {
                final cs = Theme.of(context).colorScheme;
                final value = _clampContextMessages(
                  context
                          .watch<AssistantProvider>()
                          .getById(widget.assistantId)
                          ?.contextMessageSize ??
                      20,
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
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
                            l10n.assistantEditContextMessagesTitle,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                        ),
                        IosSwitch(
                          value: a.limitContextMessages,
                          onChanged: (v) async {
                            final assistantProvider = context
                                .read<AssistantProvider>();
                            final navigator = Navigator.of(ctx);
                            final next =
                                v && a.contextMessageSize < _contextMessageMin
                                ? a.copyWith(
                                    limitContextMessages: v,
                                    contextMessageSize: _contextMessageMin,
                                  )
                                : a.copyWith(limitContextMessages: v);
                            await assistantProvider.updateAssistant(next);
                            if (navigator.mounted) navigator.pop();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (a.limitContextMessages) ...[
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
                          2048.0,
                          4096.0,
                        ],
                        onLabelTap: () async {
                          final assistantProvider = context
                              .read<AssistantProvider>();
                          final chosen = await _showContextMessageInputDialog(
                            context,
                            initialValue: value,
                          );
                          if (!context.mounted || chosen == null) return;
                          await assistantProvider.updateAssistant(
                            a.copyWith(contextMessageSize: chosen),
                          );
                        },
                        onChanged: (v) =>
                            context.read<AssistantProvider>().updateAssistant(
                              a.copyWith(
                                contextMessageSize: _clampContextMessages(v),
                              ),
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.assistantEditContextMessagesDescription,
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

  Future<void> _showMaxTokensSheet(BuildContext context, Assistant a) async {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(
      text: a.maxTokens?.toString() ?? '',
    );
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
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
                // Header with Close (X) and Save buttons
                Row(
                  children: [
                    _TactileIconButton(
                      icon: Lucide.X,
                      color: cs.onSurface,
                      size: 20,
                      onTap: () => Navigator.of(ctx).pop(),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          l10n.assistantEditMaxTokensTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                      ),
                    ),
                    _TactileRow(
                      onTap: () {
                        final val = int.tryParse(controller.text.trim());
                        context.read<AssistantProvider>().updateAssistant(
                          a.copyWith(
                            maxTokens: val,
                            clearMaxTokens: controller.text.trim().isEmpty,
                          ),
                        );
                        Navigator.of(ctx).pop();
                      },
                      pressedScale: 0.95,
                      builder: (pressed) {
                        final color = pressed
                            ? cs.primary.withValues(alpha: 0.7)
                            : cs.primary;
                        return Text(
                          l10n.assistantSettingsAddSheetSave, // "Save"
                          style: TextStyle(
                            color: color,
                            fontSize: 16,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: l10n.assistantEditMaxTokensHint,
                    filled: true,
                    fillColor: ctx.appColors.surfaceFill,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: cs.primary.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.assistantEditMaxTokensDescription,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BackgroundPreview extends StatefulWidget {
  const _BackgroundPreview({required this.path});
  final String path;

  @override
  State<_BackgroundPreview> createState() => _BackgroundPreviewState();
}

class _BackgroundPreviewState extends State<_BackgroundPreview> {
  Size? _size;

  @override
  void initState() {
    super.initState();
    _resolveSize();
  }

  @override
  void didUpdateWidget(covariant _BackgroundPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _size = null;
      _resolveSize();
    }
  }

  Future<void> _resolveSize() async {
    try {
      if (widget.path.startsWith('http')) {
        // Skip network size probe; render with a sensible max height
        setState(() => _size = null);
        return;
      }
      final file = File(SandboxPathResolver.fix(widget.path));
      if (!await file.exists()) {
        setState(() => _size = null);
        return;
      }
      final bytes = await file.readAsBytes();
      final img = await decodeImageFromList(bytes);
      final s = Size(img.width.toDouble(), img.height.toDouble());
      if (mounted) setState(() => _size = s);
    } catch (_) {
      if (mounted) setState(() => _size = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNetwork = widget.path.startsWith('http');
    final imageWidget = isNetwork
        ? Image.network(widget.path, fit: BoxFit.contain)
        : (() {
            final fixed = SandboxPathResolver.fix(widget.path);
            final f = File(fixed);
            if (!f.existsSync()) {
              // Gracefully fallback to empty box when local file missing (e.g., imported from mobile)
              return const SizedBox.shrink();
            }
            return Image.file(f, fit: BoxFit.contain);
          })();
    // When size known, maintain aspect ratio; otherwise cap the height to avoid overflow
    if (_size != null && _size!.width > 0 && _size!.height > 0) {
      final ratio = _size!.width / _size!.height;
      return SizedBox(
        width: double.infinity,
        child: AspectRatio(aspectRatio: ratio, child: imageWidget),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: 280,
        minHeight: 100,
        minWidth: double.infinity,
      ),
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        child: SizedBox(width: 400, height: 240, child: imageWidget),
      ),
    );
  }
}

class _SliderTileNew extends StatelessWidget {
  const _SliderTileNew({
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.label,
    required this.onChanged,
    this.customLabelStops,
    this.onLabelTap,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String label;
  final ValueChanged<double> onChanged;
  final List<double>? customLabelStops;
  final VoidCallback? onLabelTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final useCustomLabels =
        customLabelStops != null && customLabelStops!.isNotEmpty;
    final stops = useCustomLabels
        ? (customLabelStops!.where((v) => v >= min && v <= max).toSet().toList()
            ..sort())
        : const <double>[];

    final active = cs.primary;
    final inactive = cs.onSurface.withValues(alpha: isDark ? 0.25 : 0.20);
    final double clamped = value.clamp(min, max);
    final double? step = (divisions != null && divisions! > 0)
        ? (max - min) / divisions!
        : null;
    // Compute a readable major interval and minor tick count
    final total = (max - min).abs();
    double interval;
    if (total <= 0) {
      interval = 1;
    } else if ((divisions ?? 0) <= 20) {
      interval = total / 4; // up to 5 major ticks inc endpoints
    } else if ((divisions ?? 0) <= 50) {
      interval = total / 5;
    } else {
      interval = total / 8;
    }
    if (interval <= 0) interval = 1;
    int minor = 0;
    if (step != null && step > 0) {
      // Ensure minor ticks align with the chosen step size
      minor = ((interval / step) - 1).round();
      if (minor < 0) minor = 0;
      if (minor > 8) minor = 8;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SfSliderTheme(
                    data: SfSliderThemeData(
                      activeTrackHeight: 8,
                      inactiveTrackHeight: 8,
                      overlayRadius: 14,
                      activeTrackColor: active,
                      inactiveTrackColor: inactive,
                      // Waterdrop tooltip uses theme primary background with onPrimary text
                      tooltipBackgroundColor: cs.primary,
                      tooltipTextStyle: TextStyle(
                        color: cs.onPrimary,
                        fontWeight: AppFontWeights.semibold,
                      ),
                      thumbStrokeColor: Colors.transparent,
                      thumbStrokeWidth: 0,
                      activeTickColor: cs.onSurface.withValues(
                        alpha: isDark ? 0.45 : 0.35,
                      ),
                      inactiveTickColor: cs.onSurface.withValues(
                        alpha: isDark ? 0.30 : 0.25,
                      ),
                      activeMinorTickColor: cs.onSurface.withValues(
                        alpha: isDark ? 0.34 : 0.28,
                      ),
                      inactiveMinorTickColor: cs.onSurface.withValues(
                        alpha: isDark ? 0.24 : 0.20,
                      ),
                    ),
                    child: SfSlider(
                      value: clamped,
                      min: min,
                      max: max,
                      stepSize: step,
                      enableTooltip: true,
                      // Show the paddle tooltip only while interacting
                      shouldAlwaysShowTooltip: false,
                      showTicks: true,
                      showLabels: !useCustomLabels,
                      interval: interval,
                      minorTicksPerInterval: minor,
                      activeColor: active,
                      inactiveColor: inactive,
                      tooltipTextFormatterCallback: (actual, text) => label,
                      tooltipShape: const SfPaddleTooltipShape(),
                      labelFormatterCallback: (actual, formattedText) {
                        // Prefer integers for wide ranges, keep 2 decimals for 0..1
                        if (total <= 2.0) return actual.toStringAsFixed(2);
                        if (actual == actual.roundToDouble()) {
                          return actual.toStringAsFixed(0);
                        }
                        return actual.toStringAsFixed(1);
                      },
                      thumbIcon: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                          boxShadow: isDark
                              ? []
                              : [
                                  BoxShadow(
                                    color: cs.shadow.withValues(alpha: 0.08),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                        ),
                      ),
                      onChanged: (v) =>
                          onChanged(v is num ? v.toDouble() : (v as double)),
                    ),
                  ),
                  if (useCustomLabels && stops.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    LayoutBuilder(
                      builder: (_, __) {
                        final range = (max - min).abs();
                        return SizedBox(
                          height: 18,
                          child: Stack(
                            fit: StackFit.expand,
                            children: stops.map((v) {
                              final t = range == 0
                                  ? 0.0
                                  : ((v - min) / range).clamp(0.0, 1.0);
                              return Align(
                                alignment: Alignment(-1 + t * 2, 0),
                                child: Text(
                                  v == v.roundToDouble()
                                      ? v.toInt().toString()
                                      : v.toStringAsFixed(1),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurface.withValues(alpha: 0.65),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            _ValuePill(text: label, onTap: onLabelTap),
          ],
        ),
        // Remove explicit min/max captions since ticks already indicate range
      ],
    );
  }
}

class _ValuePill extends StatelessWidget {
  const _ValuePill({required this.text, this.onTap});
  final String text;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: onTap != null
          ? HitTestBehavior.opaque
          : HitTestBehavior.deferToChild,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: isDark ? 0.18 : 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: cs.primary.withValues(alpha: isDark ? 0.28 : 0.22),
          ),
          boxShadow: isDark ? [] : AppShadows.soft,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            text,
            style: TextStyle(
              color: cs.primary,
              fontWeight: AppFontWeights.emphasis,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
