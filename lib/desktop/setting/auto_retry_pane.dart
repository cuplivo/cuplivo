part of '../desktop_settings_page.dart';

/// Opens the auto-retry configuration dialog (used by the Display pane row).
Future<void> showDesktopAutoRetryDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.of(dialogContext).size.height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.settingsPageAutoRetry,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                  IosIconButton(
                    icon: lucide.Lucide.X,
                    size: 18,
                    onTap: () => Navigator.of(dialogContext).maybePop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                child: DesktopAutoRetryPane(
                  key: const ValueKey('desktopAutoRetryPane'),
                  showPageTitle: false,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Desktop auto-retry configuration pane (mounted inside a dialog).
class DesktopAutoRetryPane extends StatefulWidget {
  const DesktopAutoRetryPane({super.key, this.showPageTitle = true});

  final bool showPageTitle;

  @override
  State<DesktopAutoRetryPane> createState() => _DesktopAutoRetryPaneState();
}

class _DesktopAutoRetryPaneState extends State<DesktopAutoRetryPane> {
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final options = context.watch<SettingsProvider>().autoRetryOptions;
    return Container(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showPageTitle) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.settingsPageAutoRetry,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.regular,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            _SettingsCard(
              title: l10n.settingsPageAutoRetry,
              children: [
                _row(
                  l10n.autoRetryEnableLabel,
                  IosSwitch(
                    value: options.enabled,
                    onChanged: (v) => _save(options.copyWith(enabled: v)),
                  ),
                ),
                _rowDivider(),
                _row(
                  l10n.autoRetryMaxRetries,
                  IosNumberField(
                    controller: _maxRetriesCtl,
                    focusNode: _maxRetriesFn,
                  ),
                ),
                _rowDivider(),
                _row(
                  l10n.autoRetryInitialDelay,
                  IosNumberField(
                    controller: _initialDelayCtl,
                    focusNode: _initialDelayFn,
                  ),
                ),
                _rowDivider(),
                _row(
                  l10n.autoRetryMultiplier,
                  IosNumberField(
                    controller: _multiplierCtl,
                    focusNode: _multiplierFn,
                    decimal: true,
                  ),
                ),
                _rowDivider(),
                _row(
                  l10n.autoRetryMaxDelay,
                  IosNumberField(
                    controller: _maxDelayCtl,
                    focusNode: _maxDelayFn,
                  ),
                ),
                _rowDivider(),
                _row(
                  l10n.autoRetryJitter,
                  IosSwitch(
                    value: options.jitter,
                    onChanged: (v) => _save(options.copyWith(jitter: v)),
                  ),
                ),
                _rowDivider(),
                _row(
                  l10n.autoRetryOnNetworkError,
                  IosSwitch(
                    value: options.retryOnNetworkError,
                    onChanged: (v) =>
                        _save(options.copyWith(retryOnNetworkError: v)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _SettingsCard(
              title: l10n.autoRetryStatusCodes,
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
            const SizedBox(height: 10),
            _SettingsCard(
              title: l10n.autoRetryKeywords,
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
            const SizedBox(height: 10),
            _SettingsCard(
              title: l10n.autoRetryStopKeywords,
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
            const SizedBox(height: 10),
            Text(
              l10n.autoRetryFooter,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, Widget trailing) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: AppFontWeights.regular,
                color: cs.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ],
      ),
    );
  }

  Widget _rowDivider() => Divider(
    height: 5,
    thickness: 0.5,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.18),
  );
}
