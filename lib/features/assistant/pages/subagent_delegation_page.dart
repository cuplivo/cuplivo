import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../../utils/platform_utils.dart';
import '../../home/services/local_tools_service.dart';

void pushSubagentDelegationPage(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const SubagentDelegationPage()),
  );
}

/// Dedicated sub-agent delegation configuration page: per-assistant
/// `discoverable` / delegation ID / description, grouped into delegatable
/// and unconfigured sections. Feature-side counterpart to the assistant edit
/// basic tab (both write the same assistant fields via AssistantProvider).
class SubagentDelegationPage extends StatelessWidget {
  const SubagentDelegationPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.subagentPageTitle),
      ),
      body: const _SubagentDelegationList(),
    );
  }
}

class _SubagentDelegationList extends StatelessWidget {
  const _SubagentDelegationList();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    final assistants = context.watch<AssistantProvider>().assistants;
    final targets = LocalToolsService.handoffTargets(assistants);
    final targetIds = targets.map((a) => a.id).toSet();

    // Pre-existing duplicate delegation IDs (possible via backup restore or
    // legacy writes): surface them so the user can resolve the ambiguity.
    final idCounts = <String, int>{};
    for (final a in assistants) {
      final id = a.handoffId;
      if (id != null && id.isNotEmpty) {
        idCounts[id] = (idCounts[id] ?? 0) + 1;
      }
    }
    final unconfigured = assistants
        .where((a) => !targetIds.contains(a.id))
        .toList(growable: false);

    if (assistants.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.subagentPageEmpty,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: appColors.surfaceFill,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            l10n.subagentPageExplainer,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.68),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _SubagentStatusCard(count: targets.length),
        const SizedBox(height: 18),
        _SectionHeader(
          icon: Lucide.ListChecks,
          iconColor: appColors.success,
          title: l10n.subagentSectionDelegatable,
          count: targets.length,
        ),
        const SizedBox(height: 6),
        for (final target in targets) ...[
          _AssistantDelegationRow(
            assistant: target,
            conflict: idCounts[target.handoffId] == null
                ? false
                : idCounts[target.handoffId]! > 1,
          ),
          const SizedBox(height: 6),
        ],
        const SizedBox(height: 14),
        _SectionHeader(
          icon: Lucide.Bot,
          iconColor: cs.onSurface.withValues(alpha: 0.45),
          title: l10n.subagentSectionUnconfigured,
          count: unconfigured.length,
        ),
        const SizedBox(height: 6),
        for (final a in unconfigured) ...[
          _AssistantDelegationRow(
            assistant: a,
            reasonText: a.discoverable
                ? l10n.subagentReasonNoId
                : l10n.subagentReasonNotDiscoverable,
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _SubagentStatusCard extends StatelessWidget {
  const _SubagentStatusCard({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final empty = count == 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: empty ? cs.error.withValues(alpha: 0.06) : cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: empty
              ? cs.error.withValues(alpha: 0.25)
              : cs.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Icon(
              empty ? Lucide.TriangleAlert : Lucide.ListChecks,
              size: 20,
              color: empty ? cs.error : cs.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.subagentTargetStatus(count),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.semibold,
                    color: empty ? cs.error : cs.onSurface,
                  ),
                ),
                if (empty) ...[
                  const SizedBox(height: 2),
                  Text(
                    l10n.subagentPageStatusEmptySub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.count,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantDelegationRow extends StatelessWidget {
  const _AssistantDelegationRow({
    required this.assistant,
    this.conflict = false,
    this.reasonText,
  });

  final Assistant assistant;

  /// True when another assistant claims the same delegation ID.
  final bool conflict;

  /// Non-null when the assistant is not yet a valid target (reason line).
  final String? reasonText;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    final ok = reasonText == null;
    return IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: cs.surface,
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: () => showSubagentEditor(context, assistant: assistant),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Icon(
              Lucide.Bot,
              size: 20,
              color: ok ? cs.primary : cs.onSurface.withValues(alpha: 0.35),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        assistant.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: AppFontWeights.semibold,
                          color: ok
                              ? cs.onSurface
                              : cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (ok) _Chip(text: assistant.handoffId ?? ''),
                    if (conflict)
                      _Chip(
                        text: l10n.subagentIdConflict,
                        background: appColors.warningContainer,
                        foreground: appColors.warning,
                        borderColor: appColors.warning.withValues(alpha: 0.35),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                if (ok && (assistant.handoffDescription ?? '').isNotEmpty)
                  Text(
                    assistant.handoffDescription!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.62),
                    ),
                  )
                else if (!ok)
                  Text(
                    reasonText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: AppFontWeights.medium,
                      color: !assistant.discoverable
                          ? cs.onSurface.withValues(alpha: 0.45)
                          : appColors.warning,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Lucide.ChevronRight,
            size: 18,
            color: cs.onSurface.withValues(alpha: 0.35),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.text,
    this.background,
    this.foreground,
    this.borderColor,
  });

  final String text;
  final Color? background;
  final Color? foreground;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: borderColor ?? cs.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: AppFontWeights.semibold,
          color: foreground ?? cs.primary,
        ),
      ),
    );
  }
}

/// Low-level editor for a single assistant's delegation trio
/// (discoverable / delegation ID / description). Shown as a bottom sheet on
/// mobile and a centered dialog on desktop.
class _SubagentEditor extends StatefulWidget {
  const _SubagentEditor({required this.assistant});

  final Assistant assistant;

  @override
  State<_SubagentEditor> createState() => _SubagentEditorState();
}

class _SubagentEditorState extends State<_SubagentEditor> {
  late final TextEditingController _idCtrl;
  late final TextEditingController _descCtrl;
  late bool _discoverable;
  String? _idError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _idCtrl = TextEditingController(text: widget.assistant.handoffId ?? '');
    _descCtrl = TextEditingController(
      text: widget.assistant.handoffDescription ?? '',
    );
    _discoverable = widget.assistant.discoverable;
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  static String _sanitize(String v) =>
      v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '');

  void _onIdChanged(String v) {
    final l10n = AppLocalizations.of(context)!;
    final sanitized = _sanitize(v);
    String? error;
    if (sanitized != v.toLowerCase()) {
      error = l10n.assistantEditHandoffIdInvalid;
    } else {
      final dup = context.read<AssistantProvider>().assistants.any(
        (o) =>
            o.id != widget.assistant.id &&
            o.handoffId == sanitized &&
            sanitized.isNotEmpty,
      );
      if (dup) error = l10n.assistantEditHandoffIdUnique;
    }
    setState(() => _idError = error);
  }

  Future<void> _save() async {
    if (_saving || _idError != null) return;
    setState(() => _saving = true);
    final ap = context.read<AssistantProvider>();
    final fresh = ap.getById(widget.assistant.id);
    if (fresh == null) {
      debugPrint(
        'Subagent editor: assistant vanished while editing: '
        '${widget.assistant.id}',
      );
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    await ap.updateAssistant(
      fresh.copyWith(
        discoverable: _discoverable,
        handoffId: _sanitize(_idCtrl.text),
        handoffDescription: _descCtrl.text,
      ),
    );
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    final okNow =
        _discoverable && _sanitize(_idCtrl.text).isNotEmpty && _idError == null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.assistant.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: okNow
                      ? appColors.successContainer
                      : cs.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: okNow
                        ? appColors.success.withValues(alpha: 0.35)
                        : cs.outlineVariant,
                  ),
                ),
                child: Text(
                  okNow
                      ? l10n.subagentEditorStateOk
                      : (_discoverable
                            ? l10n.subagentReasonNoId
                            : l10n.subagentReasonNotDiscoverable),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: AppFontWeights.semibold,
                    color: okNow
                        ? appColors.success
                        : cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            okNow
                ? l10n.subagentEditorOkSub
                : (_discoverable
                      ? l10n.subagentEditorNoIdSub
                      : l10n.subagentEditorNotDiscSub),
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 14),
          _EditorSwitchRow(
            label: l10n.assistantEditHandoffDiscoverable,
            subtitle: l10n.assistantEditHandoffDiscoverableSubtitle,
            value: _discoverable,
            onChanged: (v) => setState(() => _discoverable = v),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.assistantEditHandoffId,
            style: TextStyle(
              fontSize: 14,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _idCtrl,
            enabled: _discoverable,
            decoration: InputDecoration(
              hintText: 'research-bot',
              errorText: _idError,
              filled: true,
              fillColor: appColors.surfaceFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
            onChanged: _onIdChanged,
          ),
          const SizedBox(height: 14),
          Text(
            l10n.assistantEditHandoffDescription,
            style: TextStyle(
              fontSize: 14,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _descCtrl,
            enabled: _discoverable,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: l10n.assistantEditHandoffDescription,
              filled: true,
              fillColor: appColors.surfaceFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _saving ? null : _save,
              child: Text(
                l10n.quickPhraseSaveButton,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorSwitchRow extends StatelessWidget {
  const _EditorSwitchRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11.5,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        IosSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

Future<void> showSubagentEditor(
  BuildContext context, {
  required Assistant assistant,
}) async {
  final cs = Theme.of(context).colorScheme;
  if (PlatformUtils.isDesktop) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 480),
          child: SingleChildScrollView(
            child: _SubagentEditor(assistant: assistant),
          ),
        ),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 12, bottom: 20),
          child: _SubagentEditor(assistant: assistant),
        ),
      ),
    );
  }
}
