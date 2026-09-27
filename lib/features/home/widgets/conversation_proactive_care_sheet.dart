import 'package:flutter/material.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../assistant/widgets/proactive_care_datetime_picker.dart';

typedef ConversationProactiveCareOverrideSetter =
    Future<void> Function(bool? value);
typedef ConversationProactiveCareTimeSetter =
    Future<void> Function(DateTime? value);

Future<void> showConversationProactiveCareSheet(
  BuildContext context, {
  required Conversation conversation,
  required Assistant assistant,
  required ConversationProactiveCareOverrideSetter onOverrideChanged,
  required ConversationProactiveCareTimeSetter onNextMessageAtChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) => ConversationProactiveCareSheet(
      conversation: conversation,
      assistant: assistant,
      onOverrideChanged: onOverrideChanged,
      onNextMessageAtChanged: onNextMessageAtChanged,
    ),
  );
}

class ConversationProactiveCareSheet extends StatefulWidget {
  const ConversationProactiveCareSheet({
    super.key,
    required this.conversation,
    required this.assistant,
    required this.onOverrideChanged,
    required this.onNextMessageAtChanged,
  });

  final Conversation conversation;
  final Assistant assistant;
  final ConversationProactiveCareOverrideSetter onOverrideChanged;
  final ConversationProactiveCareTimeSetter onNextMessageAtChanged;

  @override
  State<ConversationProactiveCareSheet> createState() =>
      _ConversationProactiveCareSheetState();
}

class _ConversationProactiveCareSheetState
    extends State<ConversationProactiveCareSheet> {
  late bool? _enabledOverride;
  late DateTime? _nextMessageAt;
  bool _savingOverride = false;
  bool _savingTime = false;

  bool get _effectiveEnabled =>
      _enabledOverride ?? widget.assistant.enableProactiveCare;

  @override
  void initState() {
    super.initState();
    _enabledOverride = widget.conversation.proactiveCareEnabledOverride;
    _nextMessageAt = widget.conversation.proactiveCareNextMessageAt;
  }

  Future<void> _setOverride(bool? value) async {
    if (_savingOverride) return;
    setState(() => _savingOverride = true);
    try {
      await widget.onOverrideChanged(value);
      if (mounted) setState(() => _enabledOverride = value);
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to update conversation proactive-care override: $error\n'
        '$stackTrace',
      );
      if (mounted) _showUpdateError();
    } finally {
      if (mounted) setState(() => _savingOverride = false);
    }
  }

  Future<void> _setNextMessageAt(DateTime? value) async {
    if (_savingTime) return;
    setState(() => _savingTime = true);
    try {
      await widget.onNextMessageAtChanged(value);
      if (mounted) setState(() => _nextMessageAt = value);
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to update conversation proactive-care time: $error\n'
        '$stackTrace',
      );
      if (mounted) _showUpdateError();
    } finally {
      if (mounted) setState(() => _savingTime = false);
    }
  }

  void _showUpdateError() {
    showAppSnackBar(
      context,
      message: AppLocalizations.of(
        context,
      )!.conversationProactiveCareUpdateFailed,
      type: NotificationType.error,
    );
  }

  Future<void> _pickNextMessageAt() async {
    if (_savingTime) return;
    final picked = await showProactiveCareDateTimePicker(
      context,
      initial: _nextMessageAt,
    );
    if (!mounted || picked == null) return;
    await _setNextMessageAt(picked);
  }

  String _statusSubtitle(AppLocalizations l10n) {
    if (_enabledOverride == null) {
      return _effectiveEnabled
          ? l10n.conversationProactiveCareFollowingAssistantOn
          : l10n.conversationProactiveCareFollowingAssistantOff;
    }
    return _effectiveEnabled
        ? l10n.conversationProactiveCareExplicitOn
        : l10n.conversationProactiveCareExplicitOff;
  }

  Widget _actionButton({
    required Key key,
    required String label,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final foreground = cs.onSurface.withValues(alpha: enabled ? 0.9 : 0.38);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: IosCardPress(
        key: key,
        baseColor: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: AppFontWeights.semibold,
                  color: foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final cardColor = context.appColors.surfaceCard;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 44),
                  Expanded(
                    child: Text(
                      l10n.conversationProactiveCareTitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: AppFontWeights.emphasis,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  IosIconButton(
                    icon: Lucide.X,
                    size: 20,
                    minSize: 44,
                    color: cs.onSurface,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('conversation-proactive-care-switch-row'),
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(Lucide.HeartPulse, size: 21, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.assistantEditProactiveCareEnableTitle,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: AppFontWeights.emphasis,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _statusSubtitle(l10n),
                            key: const ValueKey(
                              'conversation-proactive-care-status',
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: cs.onSurface.withValues(alpha: 0.62),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IosSwitch(
                      key: const ValueKey('conversation-proactive-care-switch'),
                      value: _effectiveEnabled,
                      semanticLabel: l10n.assistantEditProactiveCareEnableTitle,
                      onChanged: _savingOverride
                          ? null
                          : (_) => _setOverride(!_effectiveEnabled),
                    ),
                  ],
                ),
              ),
              if (_enabledOverride != null) ...[
                const SizedBox(height: 10),
                _actionButton(
                  key: const ValueKey('conversation-proactive-care-restore'),
                  label: l10n.conversationProactiveCareRestoreFollowing,
                  icon: Lucide.RotateCcw,
                  enabled: !_savingOverride,
                  onTap: () => _setOverride(null),
                ),
              ],
              const SizedBox(height: 16),
              IosCardPress(
                key: const ValueKey('conversation-proactive-care-time'),
                baseColor: cardColor,
                borderRadius: BorderRadius.circular(14),
                onTap: _savingTime ? null : _pickNextMessageAt,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(Lucide.clock, size: 21, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.assistantEditProactiveCareNextMessageTimeTitle,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: AppFontWeights.emphasis,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            proactiveCareNextMessageLabel(
                              context,
                              _nextMessageAt,
                            ),
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.62),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Lucide.ChevronRight,
                      size: 18,
                      color: cs.onSurface.withValues(alpha: 0.45),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _actionButton(
                key: const ValueKey('conversation-proactive-care-clear-time'),
                label: l10n.conversationProactiveCareClearTime,
                icon: Lucide.Trash2,
                enabled: _nextMessageAt != null && !_savingTime,
                onTap: () => _setNextMessageAt(null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
