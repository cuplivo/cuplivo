import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/harness_tailcat_endpoint.dart';
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
/// name, the way it reaches the remote instance, and that way's credential.
///
/// Two transports exist: the public WebUI launch link printed by `dsh web`, and
/// the ds-hu remote-access plugin's tailcat address. They are not two kinds of
/// assistant — the same harness assistant holds one connection, and the method
/// selector only decides which credential the field below it takes. Whichever
/// is chosen, [HarnessConnectionProvider] proves it before it is saved, so a
/// stored connection is one that worked.
///
/// The page owns no connection state of its own. The provider holds what was
/// last proved, so the dot here and the one on the assistants list are the same
/// answer; the page only re-proves the saved connection when it opens. Neither
/// credential field is ever seeded from storage: a launch token and a tailcat
/// address are both capabilities, and a capability is not something to render
/// on a screen that may be captured.
class HarnessSettingsPage extends StatefulWidget {
  const HarnessSettingsPage({super.key, required this.assistantId});

  final String assistantId;

  @override
  State<HarnessSettingsPage> createState() => _HarnessSettingsPageState();
}

class _HarnessSettingsPageState extends State<HarnessSettingsPage> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _tailcatCtrl = TextEditingController();

  /// The method the form below the selector is editing. Seeded from the stored
  /// assistant (the method itself is not a secret), and switched locally until
  /// a connection is proved and saved.
  HarnessConnectionMode _mode = HarnessConnectionMode.publicLink;

  /// The identity fields are seeded once: rewriting their text on every
  /// provider notification would move the caret while the user is typing.
  bool _seeded = false;
  bool _confirming = false;
  bool _probeOnOpenScheduled = false;
  bool _autoPopScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    final assistant = context.read<AssistantProvider>().getById(
      widget.assistantId,
    );
    if (assistant == null) return;
    _seeded = true;
    _nameCtrl.text = assistant.name;
    _mode = assistant.harnessConnectionMode;
    _scheduleStoredConnectionProbe();
  }

  /// A saved connection is re-proved every time the page opens: a launch token
  /// dies with the remote instance and a tailcat tunnel has to be rebuilt, so a
  /// remembered "connected" would lie.
  void _scheduleStoredConnectionProbe() {
    if (_probeOnOpenScheduled) return;
    _probeOnOpenScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeOnOpenScheduled = false;
      if (!mounted) return;
      final assistant = context.read<AssistantProvider>().getById(
        widget.assistantId,
      );
      if (assistant == null || !assistant.hasHarnessConnection) return;
      unawaited(
        _probeStoredConnection(
          context.read<HarnessConnectionProvider>(),
          assistant,
        ),
      );
    });
  }

  Future<void> _probeStoredConnection(
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
    _tailcatCtrl.dispose();
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
    // The status row describes the *stored* connection. While the user edits
    // the method or a field, the dot is reset by [_onConnectionEdit], so it
    // cannot claim the configuration that is no longer on screen.
    final connected =
        phase == HarnessConnectionPhase.connected &&
        _mode == assistant.harnessConnectionMode;

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
                  mode: _mode,
                  onModeChanged: _onModeChanged,
                  urlController: _urlCtrl,
                  tailcatController: _tailcatCtrl,
                  confirming: confirming,
                  connected: connected,
                  onFieldChanged: _onConnectionEdit,
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

  void _onModeChanged(HarnessConnectionMode mode) {
    if (mode == _mode) return;
    Haptics.soft();
    setState(() => _mode = mode);
    _onConnectionEdit();
  }

  /// The connection is about to change: drop the old answer so the dot cannot
  /// claim the previous credential while a new one is being typed.
  void _onConnectionEdit() {
    context.read<HarnessConnectionProvider>().reset(widget.assistantId);
  }

  Future<void> _confirmConnection() async {
    if (_confirming) return;
    final l10n = AppLocalizations.of(context)!;
    final assistantProvider = context.read<AssistantProvider>();
    final connections = context.read<HarnessConnectionProvider>();
    final assistant = assistantProvider.getById(widget.assistantId);
    if (assistant == null) return;

    final candidate = switch (_mode) {
      HarnessConnectionMode.publicLink => _linkCandidate(l10n, assistant),
      HarnessConnectionMode.tailcat => _tailcatCandidate(l10n, assistant),
    };
    if (candidate == null) return;

    // Prove the connection before storing it: a failing one is never persisted.
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

    // The connection is proved: leave the input before the status row can
    // appear beside it. The credential lives in the assistant, not on a screen
    // that may be captured.
    _urlCtrl.clear();
    _tailcatCtrl.clear();
    setState(() {});
    FocusManager.instance.primaryFocus?.unfocus();
    await assistantProvider.updateAssistant(candidate);
    if (!mounted) return;
    setState(() {});
  }

  /// The assistant as it would be saved from the link form, or `null` after
  /// reporting why the text cannot be a link.
  Assistant? _linkCandidate(AppLocalizations l10n, Assistant assistant) {
    final url = _urlCtrl.text.trim();
    if (!_looksLikeWebUiUrl(url)) {
      showAppSnackBar(
        context,
        message: l10n.assistantHarnessInvalidUrl,
        type: NotificationType.warning,
      );
      return null;
    }
    // One connection per assistant: saving this one retires the other
    // transport's credential instead of leaving a second secret behind.
    return assistant.copyWith(
      harnessConnectionMode: HarnessConnectionMode.publicLink,
      harnessUrl: url,
      clearHarnessTailcatAddress: true,
    );
  }

  /// The assistant as it would be saved from the tailcat form, or `null` after
  /// reporting why the text cannot be a tailcat address.
  Assistant? _tailcatCandidate(AppLocalizations l10n, Assistant assistant) {
    final endpoint = parseHarnessTailcatInput(_tailcatCtrl.text);
    if (endpoint == null) {
      showAppSnackBar(
        context,
        message: l10n.assistantHarnessTailcatInvalidAddress,
        type: NotificationType.warning,
      );
      return null;
    }
    return assistant.copyWith(
      harnessConnectionMode: HarnessConnectionMode.tailcat,
      harnessTailcatAddress: endpoint.address,
      harnessTailcatPort: endpoint.port,
      clearHarnessUrl: true,
    );
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
      case HarnessConnectionFailure.invalidTailcatAddress:
        return l10n.assistantHarnessTailcatInvalidAddress;
      case HarnessConnectionFailure.tailcatUnavailable:
        return l10n.assistantHarnessTailcatUnavailable;
      case HarnessConnectionFailure.tailcatUnsupported:
        return l10n.assistantHarnessTailcatUnsupported;
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

/// The connection card: method selector, that method's credential field,
/// explanation, prove-and-save button and — only while the saved connection is
/// verified — the connected status line.
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.l10n,
    required this.mode,
    required this.onModeChanged,
    required this.urlController,
    required this.tailcatController,
    required this.confirming,
    required this.connected,
    required this.onFieldChanged,
    required this.onConfirm,
  });

  final AppLocalizations l10n;
  final HarnessConnectionMode mode;
  final ValueChanged<HarnessConnectionMode> onModeChanged;
  final TextEditingController urlController;
  final TextEditingController tailcatController;
  final bool confirming;
  final bool connected;
  final VoidCallback onFieldChanged;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLink = mode == HarnessConnectionMode.publicLink;
    return SectionCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.assistantHarnessConnectionMethodLabel,
            style: TextStyle(fontSize: 16, fontWeight: AppFontWeights.emphasis),
          ),
          const SizedBox(height: 12),
          _HarnessMethodSelector(mode: mode, onChanged: onModeChanged),
          const SizedBox(height: 16),
          Text(
            isLink
                ? l10n.assistantHarnessWebUiUrlLabel
                : l10n.assistantHarnessTailcatAddressLabel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface.withValues(alpha: 0.62),
            ),
          ),
          const SizedBox(height: 8),
          if (isLink)
            _FilledTextField(
              key: const Key('harness-url-field'),
              controller: urlController,
              onChanged: (_) => onFieldChanged(),
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
            )
          else
            _FilledTextField(
              key: const Key('harness-tailcat-field'),
              controller: tailcatController,
              onChanged: (_) => onFieldChanged(),
              onSubmitted: (_) => onConfirm(),
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              hintText: l10n.assistantHarnessTailcatAddressHint,
              style: TextStyle(
                fontSize: 15,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface,
              ),
            ),
          const SizedBox(height: 10),
          Text(
            isLink
                ? l10n.assistantHarnessWebUiUrlHelper
                : l10n.assistantHarnessTailcatAddressHelper,
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

/// The two transports, as one exclusive choice.
///
/// A pill pair rather than a dropdown: two options fit on one line, and the
/// field below changes with the choice, so the relation has to stay visible.
class _HarnessMethodSelector extends StatelessWidget {
  const _HarnessMethodSelector({required this.mode, required this.onChanged});

  final HarnessConnectionMode mode;
  final ValueChanged<HarnessConnectionMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _HarnessMethodPill(
              key: const Key('harness-method-link'),
              label: l10n.assistantHarnessMethodLink,
              selected: mode == HarnessConnectionMode.publicLink,
              onTap: () => onChanged(HarnessConnectionMode.publicLink),
            ),
          ),
          Expanded(
            child: _HarnessMethodPill(
              key: const Key('harness-method-tailcat'),
              label: l10n.assistantHarnessMethodTailcat,
              selected: mode == HarnessConnectionMode.tailcat,
              onTap: () => onChanged(HarnessConnectionMode.tailcat),
            ),
          ),
        ],
      ),
    );
  }
}

class _HarnessMethodPill extends StatelessWidget {
  const _HarnessMethodPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final foreground = selected
        ? cs.onPrimary
        : cs.onSurface.withValues(alpha: 0.72);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? cs.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: AppFontWeights.medium,
              color: foreground,
            ),
          ),
        ),
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
/// probe of the credential the user just pasted, so the button is where the
/// waiting happens.
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
