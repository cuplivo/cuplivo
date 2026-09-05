import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/auto_retry_options.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_chip_input.dart';
import '../../../shared/widgets/ios_number_field.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

/// Mobile settings page for the configurable exponential-backoff auto-retry.
class AutoRetryPage extends StatefulWidget {
  const AutoRetryPage({super.key});

  @override
  State<AutoRetryPage> createState() => _AutoRetryPageState();
}

class _AutoRetryPageState extends State<AutoRetryPage> {
  late final SettingsProvider _settingsProvider;
  late final TextEditingController _maxRetriesCtl;
  late final TextEditingController _initialDelayCtl;
  late final TextEditingController _multiplierCtl;
  late final TextEditingController _maxDelayCtl;
  late final FocusNode _maxRetriesFn;
  late final FocusNode _initialDelayFn;
  late final FocusNode _multiplierFn;
  late final FocusNode _maxDelayFn;
  var _disposing = false;

  @override
  void initState() {
    super.initState();
    _settingsProvider = context.read<SettingsProvider>();
    final options = _settingsProvider.autoRetryOptions;
    _maxRetriesCtl = TextEditingController(text: '${options.maxRetries}');
    _initialDelayCtl = TextEditingController(text: '${options.initialDelayMs}');
    _multiplierCtl = TextEditingController(
      text: _formatMultiplier(options.multiplier),
    );
    _maxDelayCtl = TextEditingController(text: '${options.maxDelayMs}');
    _maxRetriesFn = FocusNode();
    _initialDelayFn = FocusNode();
    _multiplierFn = FocusNode();
    _maxDelayFn = FocusNode();
    _maxRetriesFn.addListener(() {
      if (!_maxRetriesFn.hasFocus) _commitNumbers();
    });
    _initialDelayFn.addListener(() {
      if (!_initialDelayFn.hasFocus) _commitNumbers();
    });
    _multiplierFn.addListener(() {
      if (!_multiplierFn.hasFocus) _commitNumbers();
    });
    _maxDelayFn.addListener(() {
      if (!_maxDelayFn.hasFocus) _commitNumbers();
    });
  }

  @override
  void dispose() {
    _disposing = true;
    final next = _parsedNumbers();
    final settings = _settingsProvider;
    // Back / tapping other controls often skips unfocus on mobile, so commit
    // once more on dispose.
    scheduleMicrotask(() {
      settings.setAutoRetryOptions(next);
    });
    _maxRetriesFn.dispose();
    _initialDelayFn.dispose();
    _multiplierFn.dispose();
    _maxDelayFn.dispose();
    _maxRetriesCtl.dispose();
    _initialDelayCtl.dispose();
    _multiplierCtl.dispose();
    _maxDelayCtl.dispose();
    super.dispose();
  }

  AutoRetryOptions get _options => _settingsProvider.autoRetryOptions;

  Future<void> _save(AutoRetryOptions next) =>
      _settingsProvider.setAutoRetryOptions(next);

  String _formatMultiplier(double value) {
    if (value == value.roundToDouble()) return '${value.toInt()}';
    return value.toString();
  }

  AutoRetryOptions _parsedNumbers() {
    return _options.copyWith(
      maxRetries:
          int.tryParse(_maxRetriesCtl.text.trim()) ?? _options.maxRetries,
      initialDelayMs:
          int.tryParse(_initialDelayCtl.text.trim()) ?? _options.initialDelayMs,
      multiplier:
          double.tryParse(_multiplierCtl.text.trim()) ?? _options.multiplier,
      maxDelayMs: int.tryParse(_maxDelayCtl.text.trim()) ?? _options.maxDelayMs,
    );
  }

  void _commitNumbers({bool syncField = true}) {
    if (_disposing) return;
    final next = _parsedNumbers();
    if (syncField) {
      _maxRetriesCtl.text = '${next.maxRetries}';
      _initialDelayCtl.text = '${next.initialDelayMs}';
      _multiplierCtl.text = _formatMultiplier(next.multiplier);
      _maxDelayCtl.text = '${next.maxDelayMs}';
    }
    _save(next);
  }

  Widget _numberRow({
    required String label,
    required TextEditingController controller,
    required FocusNode focusNode,
    bool decimal = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: AppFontWeights.regular,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.88),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 150,
            child: IosNumberField(
              controller: controller,
              focusNode: focusNode,
              decimal: decimal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.regular,
                    color: cs.onSurface.withValues(alpha: 0.88),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          IosSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _divider() => Divider(
    height: 1,
    thickness: 0.5,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.18),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final options = context.watch<SettingsProvider>().autoRetryOptions;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 20,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.settingsPageAutoRetry),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _sectionCard(
            children: [
              _switchRow(
                label: l10n.autoRetryEnableLabel,
                value: options.enabled,
                onChanged: (v) => _save(options.copyWith(enabled: v)),
              ),
              _divider(),
              _numberRow(
                label: l10n.autoRetryMaxRetries,
                controller: _maxRetriesCtl,
                focusNode: _maxRetriesFn,
              ),
              _divider(),
              _numberRow(
                label: l10n.autoRetryInitialDelay,
                controller: _initialDelayCtl,
                focusNode: _initialDelayFn,
              ),
              _divider(),
              _numberRow(
                label: l10n.autoRetryMultiplier,
                controller: _multiplierCtl,
                focusNode: _multiplierFn,
                decimal: true,
              ),
              _divider(),
              _numberRow(
                label: l10n.autoRetryMaxDelay,
                controller: _maxDelayCtl,
                focusNode: _maxDelayFn,
              ),
              _divider(),
              _switchRow(
                label: l10n.autoRetryJitter,
                subtitle: l10n.autoRetryJitterSubtitle,
                value: options.jitter,
                onChanged: (v) => _save(options.copyWith(jitter: v)),
              ),
              _divider(),
              _switchRow(
                label: l10n.autoRetryOnNetworkError,
                value: options.retryOnNetworkError,
                onChanged: (v) =>
                    _save(options.copyWith(retryOnNetworkError: v)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionCard(
            children: [
              IosChipInput(
                title: l10n.autoRetryStatusCodes,
                values: [
                  for (final c in options.retryStatusCodes.toList()..sort())
                    '$c',
                ],
                addHint: l10n.autoRetryAddHint,
                keyboardType: TextInputType.number,
                onAdd: (raw) {
                  final code = int.tryParse(raw.trim());
                  if (code == null || code < 100 || code > 599) return;
                  _save(
                    options.copyWith(
                      retryStatusCodes: {...options.retryStatusCodes, code},
                    ),
                  );
                },
                onRemove: (raw) {
                  final code = int.tryParse(raw);
                  if (code == null) return;
                  _save(
                    options.copyWith(
                      retryStatusCodes: {...options.retryStatusCodes}
                        ..remove(code),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionCard(
            children: [
              IosChipInput(
                title: l10n.autoRetryKeywords,
                values: options.retryKeywords,
                addHint: l10n.autoRetryAddHint,
                restoreLabel: l10n.autoRetryRestoreDefaults,
                onAdd: (raw) {
                  if (raw.isEmpty || options.retryKeywords.contains(raw)) {
                    return;
                  }
                  _save(
                    options.copyWith(
                      retryKeywords: [...options.retryKeywords, raw],
                    ),
                  );
                },
                onRemove: (raw) {
                  _save(
                    options.copyWith(
                      retryKeywords: [
                        for (final k in options.retryKeywords)
                          if (k != raw) k,
                      ],
                    ),
                  );
                },
                onRestore: () => _save(
                  options.copyWith(
                    retryKeywords: AutoRetryOptions.defaultRetryKeywords,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionCard(
            children: [
              IosChipInput(
                title: l10n.autoRetryStopKeywords,
                values: options.stopKeywords,
                addHint: l10n.autoRetryAddHint,
                restoreLabel: l10n.autoRetryRestoreDefaults,
                onAdd: (raw) {
                  if (raw.isEmpty || options.stopKeywords.contains(raw)) {
                    return;
                  }
                  _save(
                    options.copyWith(
                      stopKeywords: [...options.stopKeywords, raw],
                    ),
                  );
                },
                onRemove: (raw) {
                  _save(
                    options.copyWith(
                      stopKeywords: [
                        for (final k in options.stopKeywords)
                          if (k != raw) k,
                      ],
                    ),
                  );
                },
                onRestore: () => _save(
                  options.copyWith(
                    stopKeywords: AutoRetryOptions.defaultStopKeywords,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            l10n.autoRetryFooter,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({required List<Widget> children}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: context.appColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.08 : 0.06,
          ),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}
