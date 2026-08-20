import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/memory/memory_strategy.dart';
import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import '../view_models/setting_memory_view_model.dart';
import 'memory_bank_page.dart';

/// Per-assistant 3-layer memory settings page.
///
/// Mirrors Tumin's `SettingMemoryPage` layout — 4 sections, 3 switches,
/// 3 presets, 4 numeric parameters — but each section is keyed to one of
/// the new [Assistant] memory v2 fields so a v20 backup with the same
/// schema drops in unchanged.
class SettingMemoryPage extends StatefulWidget {
  const SettingMemoryPage({super.key, required this.assistantId});

  final String assistantId;

  @override
  State<SettingMemoryPage> createState() => _SettingMemoryPageState();
}

class _SettingMemoryPageState extends State<SettingMemoryPage> {
  late SettingMemoryViewModel _vm;

  @override
  void initState() {
    super.initState();
    final ap = context.read<AssistantProvider>();
    final a = ap.getById(widget.assistantId)!;
    _vm = SettingMemoryViewModel(initialAssistant: a);
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final update = _vm.buildUpdate();
    if (update == null) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    await context.read<AssistantProvider>().updateAssistant(update);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ChangeNotifierProvider<SettingMemoryViewModel>.value(
      value: _vm,
      child: Consumer<SettingMemoryViewModel>(
        builder: (context, vm, _) {
          final a = vm.draft;
          return Scaffold(
            appBar: AppBar(
              title: Text(l10n.memorySettingsPageTitle),
              actions: [
                TextButton(
                  onPressed: _save,
                  child: Text(l10n.commonSave),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                // Section 1: master switch + preset picker.
                _Section(
                  title: l10n.memorySettingsPageSectionMaster,
                  children: [
                    _SwitchRow(
                      icon: Lucide.Layers,
                      title: l10n.memorySettingsPageEnableThreeLayer,
                      subtitle: l10n.memorySettingsPageEnableThreeLayerSub,
                      value: a.enableThreeLayerMemory,
                      onChanged: vm.setThreeLayerEnabled,
                    ),
                  ],
                ),
                _Section(
                  title: l10n.memorySettingsPageSectionPreset,
                  children: [
                    _PresetPicker(
                      active: vm.activeStrategy,
                      onPick: vm.applyPreset,
                    ),
                  ],
                ),
                // Section 2: cross-window + compression knobs.
                _Section(
                  title: l10n.memorySettingsPageSectionCrossWindow,
                  children: [
                    _SwitchRow(
                      icon: Lucide.Repeat,
                      title: l10n.memorySettingsPageEnableCrossWindow,
                      subtitle: l10n.memorySettingsPageEnableCrossWindowSub,
                      value: a.enableCrossWindowMemory,
                      onChanged: vm.setCrossWindowEnabled,
                    ),
                    const _Divider(),
                    _SwitchRow(
                      icon: Lucide.Sparkles,
                      title: l10n.memorySettingsPageEnableCompression,
                      subtitle: l10n.memorySettingsPageEnableCompressionSub,
                      value: a.enableCrossWindowMemoryCompression,
                      onChanged: vm.setCompressionEnabled,
                    ),
                    const _Divider(),
                    _NumberRow(
                      icon: Lucide.TextSelect,
                      title: l10n
                          .memorySettingsPageCompressionThresholdTitle,
                      subtitle: l10n
                          .memorySettingsPageCompressionThresholdSub,
                      value: a.crossWindowMemoryCompressionThresholdChars,
                      min: 1000,
                      max: 200000,
                      step: 1000,
                      onChanged: vm.setCompressionThresholdChars,
                      suffix: l10n.memorySettingsPageUnitChars,
                    ),
                    const _Divider(),
                    _NumberRow(
                      icon: Lucide.ListOrdered,
                      title: l10n.memorySettingsPageTailEntriesTitle,
                      subtitle: l10n.memorySettingsPageTailEntriesSub,
                      value: a.crossWindowMemoryTailEntries,
                      min: 1,
                      max: 200,
                      step: 1,
                      onChanged: vm.setCompressionTailEntries,
                      suffix: l10n.memorySettingsPageUnitEntries,
                    ),
                  ],
                ),
                // Section 3: long-term recall.
                _Section(
                  title: l10n.memorySettingsPageSectionLongTerm,
                  children: [
                    _NumberRow(
                      icon: Lucide.History,
                      title: l10n.memorySettingsPageRecallCountTitle,
                      subtitle: l10n.memorySettingsPageRecallCountSub,
                      value: a.longTermMemoryRecallCount,
                      min: 1,
                      max: 50,
                      step: 1,
                      onChanged: vm.setRecallCount,
                      suffix: l10n.memorySettingsPageUnitEntries,
                    ),
                    const _Divider(),
                    _NumberRow(
                      icon: Lucide.TextSelect,
                      title: l10n.memorySettingsPageLongTermMaxCharsTitle,
                      subtitle: l10n.memorySettingsPageLongTermMaxCharsSub,
                      value: a.longTermMemoryMaxChars,
                      min: 200,
                      max: 50000,
                      step: 100,
                      onChanged: vm.setLongTermMaxChars,
                      suffix: l10n.memorySettingsPageUnitChars,
                    ),
                    const _Divider(),
                    _SwitchRow(
                      icon: Lucide.Shield,
                      title: l10n.memorySettingsPageRecentChatsFallback,
                      subtitle:
                          l10n.memorySettingsPageRecentChatsFallbackSub,
                      value: a.useRecentChatsAsFallback,
                      onChanged: vm.setRecentChatsFallbackEnabled,
                    ),
                  ],
                ),
                // Section 4: jump to bank browser.
                _Section(
                  title: l10n.memorySettingsPageSectionBank,
                  children: [
                    _NavRow(
                      icon: Lucide.Database,
                      title: l10n.memorySettingsPageOpenBank,
                      subtitle: l10n.memorySettingsPageOpenBankSub,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MemoryBankPage(
                              assistantId: widget.assistantId,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                SizedBox(height: 12 + MediaQuery.of(context).padding.bottom),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.6),
                letterSpacing: 0.4,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.4),
                width: 0.6,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 0.5,
      thickness: 0.5,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(
            alpha: 0.3,
          ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
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
                    fontSize: 12,
                    height: 1.4,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.suffix,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;
  final String suffix;

  Future<void> _edit(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController(text: value.toString());

    int? parse() {
      final raw = int.tryParse(controller.text.trim());
      if (raw == null) return null;
      if (raw < min || raw > max) return null;
      return raw;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final parsed = parse();
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Text(title),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: cs.onSurface.withValues(alpha: 0.68),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: InputDecoration(
                        suffixText: suffix,
                        helperText: '$min – $max',
                      ),
                      onChanged: (_) => setLocal(() {}),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10n.commonCancel),
                ),
                TextButton(
                  onPressed: parsed == null
                      ? null
                      : () {
                          onChanged(parsed);
                          Navigator.of(ctx).pop();
                        },
                  child: Text(l10n.commonSave),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _edit(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
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
                      fontSize: 12,
                      height: 1.4,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$value $suffix',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetPicker extends StatelessWidget {
  const _PresetPicker({required this.active, required this.onPick});
  final MemoryStrategy? active;
  final ValueChanged<MemoryStrategy> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.memorySettingsPagePresetHelp,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 10),
          for (final s in MemoryStrategy.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _PresetRow(
                strategy: s,
                selected: active == s,
                custom: active == null,
                onTap: () => onPick(s),
              ),
            ),
        ],
      ),
    );
  }
}

class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.strategy,
    required this.selected,
    required this.custom,
    required this.onTap,
  });
  final MemoryStrategy strategy;
  final bool selected;
  final bool custom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? cs.primary.withValues(alpha: 0.08)
          : cs.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Lucide.CheckCircle : Lucide.circleDot,
                size: 18,
                color: selected
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          strategy.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: AppFontWeights.semibold,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest
                                .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            strategy.cost,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      strategy.description,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: cs.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
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
                      fontSize: 12,
                      height: 1.4,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Lucide.ChevronRight,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}
