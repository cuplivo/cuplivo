import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/harness_connection_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../core/services/harness/harness_connection_probe.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../home/controllers/chat_actions.dart';
import '../../home/widgets/assistant_avatar.dart';

/// Connection settings for one [AssistantKind.deepSeekHarness] assistant: its
/// name and the launch link of the remote WebUI.
///
/// The page owns no connection state of its own. [HarnessConnectionProvider]
/// holds what was last proved, so the dot here and the one on the assistants
/// list are the same answer; the page only re-proves the saved link when it
/// opens. The URL field always starts empty because the stored link carries
/// the instance's token, and a token is not something to render on screen.
class HarnessSettingsPage extends StatefulWidget {
  const HarnessSettingsPage({super.key, required this.assistantId});

  final String assistantId;

  @override
  State<HarnessSettingsPage> createState() => _HarnessSettingsPageState();
}

class _HarnessSettingsPageState extends State<HarnessSettingsPage> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();

  /// The name field is seeded once: rewriting its text on every provider
  /// notification would move the caret while the user is typing.
  bool _nameSeeded = false;
  bool _confirming = false;
  bool _probeOnOpenScheduled = false;
  bool _autoPopScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_nameSeeded) return;
    final assistant = context.read<AssistantProvider>().getById(
      widget.assistantId,
    );
    if (assistant == null) return;
    _nameSeeded = true;
    _nameCtrl.text = assistant.name;
    _scheduleStoredLinkProbe();
  }

  /// A saved link is re-proved every time the page opens: the token behind it
  /// dies with the remote instance, so a remembered "connected" would lie.
  void _scheduleStoredLinkProbe() {
    if (_probeOnOpenScheduled) return;
    _probeOnOpenScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeOnOpenScheduled = false;
      if (!mounted) return;
      final assistant = context.read<AssistantProvider>().getById(
        widget.assistantId,
      );
      if (assistant == null) return;
      final url = assistant.harnessUrl?.trim() ?? '';
      if (url.isEmpty) return;
      unawaited(
        _probeStoredLink(context.read<HarnessConnectionProvider>(), assistant),
      );
    });
  }

  Future<void> _probeStoredLink(
    HarnessConnectionProvider connections,
    Assistant assistant,
  ) async {
    try {
      await connections.check(assistant);
    } catch (_) {
      // A probe that throws is still "not connected": the page shows no status
      // row, and the next explicit 确认 runs it again. Never an unhandled error.
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final assistant = context.watch<AssistantProvider>().getById(
      widget.assistantId,
    );
    if (assistant == null) {
      // Deleted underneath the page (or opened with no assistant): leave on the
      // next frame instead of keeping a dead page on top of the list.
      _scheduleAutoPop();
      return const Scaffold(body: SizedBox.shrink());
    }

    final connections = context.watch<HarnessConnectionProvider>();
    final phase = connections.phaseOf(assistant.id);
    final confirming = _confirming || phase == HarnessConnectionPhase.checking;
    final connected = phase == HarnessConnectionPhase.connected;

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(
          assistant.name.isNotEmpty
              ? assistant.name
              : l10n.assistantHarnessDefaultName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 18, fontWeight: AppFontWeights.semibold),
        ),
        actions: [
          Tooltip(
            message: l10n.assistantSettingsDeleteButton,
            child: IosIconButton(
              icon: Lucide.Trash2,
              size: 21,
              minSize: 44,
              color: cs.onSurface,
              semanticLabel: l10n.assistantSettingsDeleteButton,
              onTap: _confirmDelete,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _IdentityCard(
                  assistant: assistant,
                  nameController: _nameCtrl,
                  onNameChanged: _onNameChanged,
                ),
                const SizedBox(height: 14),
                _ConnectionCard(
                  l10n: l10n,
                  urlController: _urlCtrl,
                  confirming: confirming,
                  connected: connected,
                  onUrlChanged: _onUrlChanged,
                  onConfirm: _confirmConnection,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onNameChanged(String value) {
    final assistantProvider = context.read<AssistantProvider>();
    final assistant = assistantProvider.getById(widget.assistantId);
    if (assistant == null) return;
    unawaited(
      assistantProvider.updateAssistant(assistant.copyWith(name: value)),
    );
  }

  void _onUrlChanged(String _) {
    // The link is about to change: drop the old answer so the dot cannot claim
    // the previous link while this text is being typed.
    context.read<HarnessConnectionProvider>().reset(widget.assistantId);
  }

  Future<void> _confirmConnection() async {
    if (_confirming) return;
    final l10n = AppLocalizations.of(context)!;
    final assistantProvider = context.read<AssistantProvider>();
    final connections = context.read<HarnessConnectionProvider>();
    final assistant = assistantProvider.getById(widget.assistantId);
    if (assistant == null) return;

    final url = _urlCtrl.text.trim();
    if (!_looksLikeWebUiUrl(url)) {
      showAppSnackBar(
        context,
        message: l10n.assistantHarnessInvalidUrl,
        type: NotificationType.warning,
      );
      return;
    }

    // Prove the link before storing it: a failing link is never persisted.
    final candidate = assistant.copyWith(harnessUrl: url);
    setState(() => _confirming = true);
    final HarnessConnectionResult result;
    try {
      result = await connections.check(candidate);
    } catch (_) {
      if (!mounted) return;
      setState(() => _confirming = false);
      showAppSnackBar(
        context,
        message: l10n.assistantHarnessConnectionFailed,
        type: NotificationType.error,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _confirming = false);

    if (!result.isConnected) {
      // Keep the typed text: the user has to correct it and try again.
      showAppSnackBar(
        context,
        message: _connectionFailureMessage(l10n, result.failure),
        type: NotificationType.error,
      );
      return;
    }

    // The link is proved: leave the input before the status row can appear
    // beside it. The launch token lives in `Assistant.harnessUrl`, not on a
    // screen that may be captured.
    _urlCtrl.clear();
    setState(() {});
    FocusManager.instance.primaryFocus?.unfocus();
    await assistantProvider.updateAssistant(candidate);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context)!;
    final assistantProvider = context.read<AssistantProvider>();
    final assistant = assistantProvider.getById(widget.assistantId);
    if (assistant == null) return;
    // Deleting a harness never violates the one-local-assistant rule: the
    // provider refuses that case, and the `deleted != true` branch below warns.

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(l10n.assistantSettingsDeleteDialogTitle),
          content: Text(l10n.assistantSettingsDeleteDialogContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.assistantSettingsDeleteDialogCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                l10n.assistantSettingsDeleteDialogConfirm,
                style: TextStyle(color: cs.error),
              ),
            ),
          ],
        );
      },
    );
    if (!mounted || confirmed != true) return;

    // Same order as every other delete path: stop the work, then remove the row.
    await ChatActions.cancelActiveGenerationsForAssistant(assistant.id);
    if (!mounted) return;
    final deleted = await assistantProvider.deleteAssistant(assistant.id);
    if (!mounted) return;
    if (!deleted) {
      showAppSnackBar(
        context,
        message: l10n.assistantSettingsAtLeastOneAssistantRequired,
        type: NotificationType.warning,
      );
      return;
    }
    // The assistant is gone, so the next build leaves the page.
  }

  void _scheduleAutoPop() {
    if (_autoPopScheduled) return;
    _autoPopScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).maybePop();
    });
  }

  static bool _looksLikeWebUiUrl(String value) {
    if (value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return uri.host.isNotEmpty;
  }

  static String _connectionFailureMessage(
    AppLocalizations l10n,
    HarnessConnectionFailure? failure,
  ) {
    switch (failure) {
      case HarnessConnectionFailure.invalidUrl:
        return l10n.assistantHarnessInvalidUrl;
      case HarnessConnectionFailure.missingToken:
        return l10n.assistantHarnessMissingToken;
      case HarnessConnectionFailure.rejected:
        return l10n.assistantHarnessRejected;
      case HarnessConnectionFailure.unreachable:
        return l10n.assistantHarnessUnreachable;
      case HarnessConnectionFailure.apiUnavailable:
        return l10n.assistantHarnessApiUnavailable;
      case null:
        return l10n.assistantHarnessConnectionFailed;
    }
  }
}

/// Avatar + editable name, the same identity row every assistant settings page
/// has, so a harness assistant can be renamed where it got created.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.assistant,
    required this.nameController,
    required this.onNameChanged,
  });

  final Assistant assistant;
  final TextEditingController nameController;
  final ValueChanged<String> onNameChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AssistantAvatar(assistant: assistant, size: 62),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.assistantEditAssistantNameLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.62),
                  ),
                ),
                const SizedBox(height: 8),
                _FilledTextField(
                  controller: nameController,
                  onChanged: onNameChanged,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The access-link card: field, explanation, prove-and-save button and — only
/// while the saved link is verified — the connected status line.
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.l10n,
    required this.urlController,
    required this.confirming,
    required this.connected,
    required this.onUrlChanged,
    required this.onConfirm,
  });

  final AppLocalizations l10n;
  final TextEditingController urlController;
  final bool confirming;
  final bool connected;
  final ValueChanged<String> onUrlChanged;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.assistantHarnessWebUiUrlLabel,
            style: TextStyle(fontSize: 16, fontWeight: AppFontWeights.emphasis),
          ),
          const SizedBox(height: 12),
          _FilledTextField(
            key: const Key('harness-url-field'),
            controller: urlController,
            onChanged: onUrlChanged,
            onSubmitted: (_) => onConfirm(),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            hintText: l10n.assistantHarnessWebUiUrlHint,
            style: TextStyle(
              fontSize: 15,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.assistantHarnessWebUiUrlHelper,
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 16),
          _ConfirmButton(
            key: const Key('harness-confirm-button'),
            label: confirming
                ? l10n.assistantHarnessChecking
                : l10n.assistantHarnessConfirm,
            confirming: confirming,
            onTap: onConfirm,
          ),
          if (connected) ...[
            const SizedBox(height: 12),
            Center(
              child: Row(
                key: const Key('harness-connected-status'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: context.appColors.success,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.assistantHarnessConnected,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Filled field on the card's own surface — the input shape used across the
/// app's settings pages, sized for a one-line URL or name.
class _FilledTextField extends StatelessWidget {
  const _FilledTextField({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    this.hintText,
    this.keyboardType,
    this.textInputAction,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.style,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? hintText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        smartDashesType: autocorrect ? null : SmartDashesType.disabled,
        smartQuotesType: autocorrect ? null : SmartQuotesType.disabled,
        style: style,
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          hintText: hintText,
          hintStyle: TextStyle(
            fontSize: 15,
            fontWeight: AppFontWeights.medium,
            color: cs.onSurface.withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }
}

/// Full-width primary action. Shows its progress in place: the request is a
/// probe of the link the user just pasted, so the button is where the waiting
/// happens.
class _ConfirmButton extends StatefulWidget {
  const _ConfirmButton({
    super.key,
    required this.label,
    required this.confirming,
    required this.onTap,
  });

  final String label;
  final bool confirming;
  final VoidCallback onTap;

  @override
  State<_ConfirmButton> createState() => _ConfirmButtonState();
}

class _ConfirmButtonState extends State<_ConfirmButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      enabled: !widget.confirming,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.confirming ? null : (_) => _setPressed(true),
        onTapUp: widget.confirming ? null : (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.confirming
            ? null
            : () {
                Haptics.soft();
                widget.onTap();
              },
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: Container(
            width: double.infinity,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.confirming) ...[
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(cs.onPrimary),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontSize: 16,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
