import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:Cuplivo/features/harness/models/dsh_provider_settings.dart';
import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_settings_controller.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_filled_button.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_models_states.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_provider_icon.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_reasoning_efforts_editor.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_checkbox.dart';
import 'package:Cuplivo/shared/widgets/ios_form_text_field.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The provider detail page of the DSH assistant settings 模型 tab (R11).
///
/// Two honest modes:
/// - with a [DshProviderSettingsGateway] the form edits the provider profile
///   and credential on the remote host through [DshProviderSettingsController].
///   Every configurable route shows the same editable model rows; a shipped
///   route whose profile declares no models shows the adapter's catalog rows
///   under `正在使用适配器默认模型`, and only a custom provider adds the
///   per-model reasoning-effort editor;
/// - without the seam the page still shows the provider header and the models
///   the live catalog serves, and states plainly that editing needs the
///   settings adapter — it never writes local provider rows or makes up values.
class DshProviderDetailPage extends StatefulWidget {
  const DshProviderDetailPage({
    super.key,
    required this.remoteId,
    this.settings,
    this.controller,
    this.entry,
    this.catalogGroup,
    this.createCustom = false,
  });

  final String remoteId;
  final DshProviderSettingsGateway? settings;
  final DshProviderSettingsController? controller;
  final DshProviderEntry? entry;
  final DshProviderGroup? catalogGroup;
  final bool createCustom;

  @override
  State<DshProviderDetailPage> createState() => _DshProviderDetailPageState();
}

class _DshProviderDetailPageState extends State<DshProviderDetailPage> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _baseURLController = TextEditingController();
  final TextEditingController _providerIdController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();

  DshProviderSettingsController? _controller;
  bool _ownsController = false;
  DshProviderEntry? _entry;
  List<_DshModelEditor> _models = <_DshModelEditor>[];
  DshProviderApi _api = DshProviderApi.openAiChatCompletions;
  bool _customExpanded = true;
  bool _usesAdapterDefaults = false;
  bool _modelsEdited = false;
  bool _saving = false;
  bool _initialized = false;
  String? _inlineError;

  bool get _hasSeam => widget.settings != null;
  bool get _isNew => widget.createCustom;
  bool get _isCustomProvider => _isNew || (_entry?.isCustom ?? false);

  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
    final controller = widget.controller;
    if (controller != null) {
      _controller = controller;
    } else if (widget.settings != null) {
      final owned = DshProviderSettingsController(gateway: widget.settings!);
      _controller = owned;
      _ownsController = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) owned.ensureLoaded();
      });
    }
    if (_entry != null) _adoptEntry(_entry!);
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseURLController.dispose();
    _providerIdController.dispose();
    _displayNameController.dispose();
    for (final editor in _models) {
      editor.dispose();
    }
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!_hasSeam) return _buildWithoutSeam(context);
    final controller = _controller;
    if (controller == null) return _buildWithoutSeam(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final resolved = _resolveEntry(controller);
        if (resolved != null && resolved != _entry) {
          _entry = resolved;
          if (!_initialized) _adoptEntry(resolved);
        }
        if (_entry == null &&
            !_isNew &&
            (!controller.hasLoaded || controller.isLoading)) {
          return _pageScaffold(
            title: l10n.dshProviderDetailModels,
            child: DshModelsStatePanel(
              icon: Lucide.Loader,
              title: l10n.dshModelsLoading,
            ),
          );
        }
        if (_entry == null && !_isNew) {
          return _pageScaffold(
            title: l10n.dshModelsLoadFailed,
            child: DshModelsStatePanel(
              icon: Lucide.CloudOff,
              title: l10n.dshModelsLoadFailed,
              body: l10n.dshProviderDetailRequiredFields,
            ),
          );
        }
        return _buildForm(context);
      },
    );
  }

  DshProviderEntry? _resolveEntry(DshProviderSettingsController controller) {
    if (widget.entry != null) return widget.entry;
    final wanted = widget.catalogGroup?.id;
    if (wanted == null) return null;
    for (final entry in controller.entries ?? const <DshProviderEntry>[]) {
      if (entry.id == wanted) return entry;
    }
    return null;
  }

  void _adoptEntry(DshProviderEntry entry) {
    _initialized = true;
    _api = entry.profile.api;
    _baseURLController.text = entry.profile.baseURL?.trim() ?? '';
    _providerIdController.text = entry.id;
    _displayNameController.text = entry.displayName;
    _disposeModels();
    _modelsEdited = false;
    final profileModels = entry.profile.models;
    _usesAdapterDefaults = profileModels.isEmpty;
    if (!_hasSeam) return;
    if (profileModels.isNotEmpty) {
      _models = [
        for (final model in profileModels) _DshModelEditor.fromModel(model),
      ];
      return;
    }
    // No profile models: the adapter is serving its default catalog. Surface
    // those models as the same editable rows so R11 has one shape (the ids and
    // names are the host's; specs the catalog does not expose stay empty).
    _models = [
      for (final model in widget.catalogGroup?.models ?? const <DshModel>[])
        _DshModelEditor.fromCatalog(model),
    ];
  }

  void _disposeModels() {
    for (final editor in _models) {
      editor.dispose();
    }
    _models = <_DshModelEditor>[];
  }

  // ---------------------------------------------------------------------------
  // No settings adapter: read-only but honest.
  // ---------------------------------------------------------------------------

  Widget _buildWithoutSeam(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final group = widget.catalogGroup;
    final entry = widget.entry;
    final displayName = _isNew
        ? l10n.dshProviderDetailCustomProviderTitle
        : (entry?.effectiveDisplayName ??
              group?.title ??
              widget.catalogGroup?.id ??
              '');
    final providerId = entry?.id ?? group?.id ?? '';
    final catalogModels = group?.models ?? const <DshModel>[];
    return _pageScaffold(
      title: displayName,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (!_isNew)
            _ProviderHeader(
              displayName: displayName,
              providerId: providerId,
              providerIconId: providerId,
            ),
          if (_isNew) const SizedBox(height: 4),
          const SizedBox(height: 12),
          DshModelsStatePanel(
            icon: Lucide.Settings2,
            title: l10n.dshModelsSettingsUnavailableTitle,
            body: l10n.dshModelsSettingsUnavailableBody,
            compact: true,
          ),
          if (catalogModels.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionLabel(text: l10n.dshProviderDetailModels),
            const SizedBox(height: 6),
            Text(
              l10n.dshProviderDetailModelsAdapterDefault,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 10),
            for (final model in catalogModels) _ReadOnlyModelCard(model: model),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Settings adapter present: the R11 form.
  // ---------------------------------------------------------------------------

  Widget _buildForm(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entry = _entry;
    final displayName = _isNew
        ? l10n.dshProviderDetailCustomProviderTitle
        : entry?.effectiveDisplayName ?? '';
    final providerId = _isNew ? '' : entry?.id ?? '';
    final configured = entry?.configured ?? false;
    final oauth = entry?.oauth ?? false;
    final defaultBaseURL = (entry?.defaultBaseURL ?? '').trim();
    final baseURLEnv = entry?.baseURLEnv ?? const <String>[];
    final hasCredential =
        configured || _apiKeyController.text.trim().isNotEmpty;
    final modelEditors = _models;
    // R11: every configurable route is editable through the settings adapter;
    // a shipped route may serve its model list from the adapter instead of its
    // profile, and those rows stay editable. First-config (no credential yet)
    // shows only the connection/credential fields.
    final showsModelCatalog =
        !_isNew && (hasCredential || modelEditors.isNotEmpty);
    final adapterDefaultNote = _usesAdapterDefaults && modelEditors.isNotEmpty;

    return _pageScaffold(
      title: displayName,
      actions: [
        if (!_isNew && (entry?.isCustom ?? false))
          IosIconButton(
            icon: Lucide.Trash2,
            size: 19,
            tooltip: l10n.dshProviderDetailDeleteProvider,
            semanticLabel: l10n.dshProviderDetailDeleteProvider,
            onTap: _saving ? null : _confirmDelete,
          ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (_isNew) ...[
            _FieldLabel(text: l10n.dshProviderDetailProviderId),
            IosFormTextField(
              key: const Key('dsh-provider-detail-id'),
              label: '',
              controller: _providerIdController,
              hintText: l10n.dshProviderDetailProviderIdHint,
              inlineLabel: false,
              outerPadding: EdgeInsets.zero,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _FieldLabel(text: l10n.dshProviderDetailDisplayName),
            IosFormTextField(
              key: const Key('dsh-provider-detail-name'),
              label: '',
              controller: _displayNameController,
              inlineLabel: false,
              outerPadding: EdgeInsets.zero,
              onChanged: (_) => setState(() {}),
            ),
          ] else
            _ProviderHeader(
              displayName: displayName,
              providerId: providerId,
              providerIconId: providerId,
            ),
          const SizedBox(height: 16),
          if (oauth)
            _OAuthNote(env: entry?.nativeAuthEnv ?? const <String>[])
          else ...[
            Row(
              children: [
                _FieldLabel(text: l10n.dshProviderDetailApiKey),
                const SizedBox(width: 4),
                IosIconButton(
                  icon: Lucide.MessageCircleQuestionMark,
                  size: 15,
                  padding: const EdgeInsets.all(2),
                  tooltip: l10n.dshProviderDetailApiKeyHelp,
                  semanticLabel: l10n.dshProviderDetailApiKeyHelp,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.45),
                ),
              ],
            ),
            IosFormTextField(
              key: const Key('dsh-provider-detail-api-key'),
              label: '',
              controller: _apiKeyController,
              hintText: l10n.dshProviderDetailApiKeyHint,
              obscureText: true,
              inlineLabel: false,
              outerPadding: EdgeInsets.zero,
              autocorrect: false,
              enableSuggestions: false,
              suffix: _apiKeyController.text.trim().isNotEmpty
                  ? IosIconButton(
                      icon: Lucide.X,
                      size: 14,
                      padding: const EdgeInsets.all(4),
                      onTap: () => setState(() => _apiKeyController.clear()),
                    )
                  : null,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 6),
            Text(
              configured
                  ? l10n.dshProviderDetailCredentialConfigured
                  : l10n.dshProviderDetailCredentialMissing,
              style: TextStyle(
                fontSize: 12,
                color: configured
                    ? context.appColors.success
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
          const SizedBox(height: 18),
          _CollapsibleSection(
            title: l10n.dshProviderDetailCustomSettings,
            expanded: _customExpanded,
            onToggle: () => setState(() => _customExpanded = !_customExpanded),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isNew) ...[
                  _FieldLabel(text: l10n.dshProviderDetailApiProtocol),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final protocol in DshProviderApi.values)
                        _ProtocolChip(
                          label: switch (protocol) {
                            DshProviderApi.openAiChatCompletions =>
                              l10n.dshProviderDetailProtocolOpenAiChat,
                            DshProviderApi.openAiResponses =>
                              l10n.dshProviderDetailProtocolOpenAiResponses,
                            DshProviderApi.anthropicMessages =>
                              l10n.dshProviderDetailProtocolAnthropic,
                          },
                          selected: _api == protocol,
                          onTap: () => setState(() => _api = protocol),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
                _FieldLabel(text: l10n.dshProviderDetailApiAddress),
                IosFormTextField(
                  key: const Key('dsh-provider-detail-base-url'),
                  label: '',
                  controller: _baseURLController,
                  hintText: defaultBaseURL.isNotEmpty
                      ? defaultBaseURL
                      : l10n.dshProviderDetailBaseUrlHint,
                  inlineLabel: false,
                  outerPadding: EdgeInsets.zero,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                Text(
                  _api.isAnthropic
                      ? l10n.dshProviderDetailApiAddressHintAnthropic
                      : l10n.dshProviderDetailApiAddressHintOpenAi,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                if (baseURLEnv.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.dshProviderDetailEnvHint(baseURLEnv.join(', ')),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (showsModelCatalog) ...[
            Row(
              children: [
                _SectionLabel(text: l10n.dshProviderDetailModels),
                const Spacer(),
                IosIconButton(
                  icon: Lucide.Plus,
                  size: 17,
                  tooltip: l10n.dshProviderDetailAddModel,
                  semanticLabel: l10n.dshProviderDetailAddModel,
                  onTap: _saving ? null : _addModel,
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (adapterDefaultNote) ...[
              Text(
                l10n.dshProviderDetailModelsAdapterDefault,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (modelEditors.isEmpty)
              Text(
                l10n.dshProviderDetailModelsEmpty,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              )
            else
              _buildEditableModels(modelEditors),
          ] else
            Text(
              l10n.dshProviderDetailModelsFirstConfig,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          const SizedBox(height: 24),
          if (_inlineError != null) ...[
            Text(
              _inlineError!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 10),
          ],
          DshFilledButton(
            key: const Key('dsh-provider-detail-save'),
            label: l10n.dshProviderDetailSave,
            busy: _saving,
            enabled: !_saving,
            onPressed: _save,
          ),
        ],
      ),
    );
  }

  Widget _buildEditableModels(List<_DshModelEditor> editors) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: editors.length,
      onReorderItem: (oldIndex, newIndex) {
        setState(() {
          _modelsEdited = true;
          final editor = editors.removeAt(oldIndex);
          editors.insert(newIndex, editor);
        });
      },
      itemBuilder: (context, index) {
        final editor = editors[index];
        return Padding(
          key: ValueKey<int>(editor.keyId),
          padding: const EdgeInsets.only(bottom: 10),
          child: _DshModelEditorCard(
            editor: editor,
            index: index,
            editable: true,
            showReasoningEfforts: _isCustomProvider,
            onChanged: () => setState(() => _modelsEdited = true),
            onRemove: () {
              setState(() {
                _modelsEdited = true;
                editors.removeAt(index);
                editor.dispose();
              });
            },
          ),
        );
      },
    );
  }

  void _addModel() {
    setState(() {
      _modelsEdited = true;
      _models = [..._models, _DshModelEditor.empty()];
    });
  }

  Future<void> _save() async {
    final controller = _controller;
    if (controller == null || _saving) return;
    final l10n = AppLocalizations.of(context)!;
    final entry = _entry;
    final providerId = _isNew
        ? _providerIdController.text.trim()
        : entry?.id ?? '';
    if (providerId.isEmpty) {
      setState(() => _inlineError = l10n.dshProviderDetailRequiredFields);
      return;
    }
    final baseURL = _baseURLController.text.trim();
    if (_isNew && baseURL.isEmpty) {
      setState(() => _inlineError = l10n.dshProviderDetailRequiredFields);
      return;
    }
    final models = <DshProviderModel>[];
    for (final editor in _models) {
      final model = editor.toModel();
      if (model == null) {
        setState(() => _inlineError = l10n.dshProviderDetailInvalidModelId);
        return;
      }
      models.add(model);
    }
    final credential = _apiKeyController.text.trim();
    final settingsNs = _isNew ? 'llm-pi-ai' : entry!.settingsNs;
    final settingsPath = _isNew
        ? <String>['providers', providerId]
        : entry!.settingsPath;
    final credentialRef =
        entry?.credentialRef ?? _deriveCredentialRef(providerId);
    final draft = DshProviderDraft(
      providerId: providerId,
      displayName: _isNew
          ? (_displayNameController.text.trim().isEmpty
                ? providerId
                : _displayNameController.text.trim())
          : entry!.displayName,
      settingsNs: settingsNs,
      settingsPath: settingsPath,
      profile: DshProviderProfile(
        api: _api,
        baseURL: baseURL.isEmpty ? null : baseURL,
        models: _isNew || !_usesAdapterDefaults || _modelsEdited
            ? models
            : entry!.profile.models,
      ),
      expectedRevision: _isNew ? null : entry!.revision,
      isNew: _isNew,
      credentialRef: credentialRef,
      oauth: entry?.oauth ?? false,
    );
    setState(() {
      _saving = true;
      _inlineError = null;
    });
    try {
      final saved = await controller.save(draft);
      if (!mounted) return;
      if (saved == null) {
        setState(() {
          _inlineError = _failureMessage(l10n, controller.lastFailure);
        });
        showAppSnackBar(
          context,
          message: _failureMessage(l10n, controller.lastFailure),
          type: NotificationType.error,
        );
        return;
      }
      var adopted = saved;
      if (credential.isNotEmpty) {
        final ok = await controller.setCredential(credentialRef, credential);
        if (!mounted) return;
        if (!ok) {
          setState(() {
            _inlineError = _failureMessage(l10n, controller.lastFailure);
          });
          return;
        }
        adopted = saved.copyWith(configured: true);
        _apiKeyController.clear();
      }
      if (!mounted) return;
      _entry = adopted;
      _initialized = false;
      _adoptEntry(adopted);
      showAppSnackBar(
        context,
        message: l10n.dshProviderDetailSaved,
        type: NotificationType.success,
      );
      if (_isNew) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _failureMessage(
    AppLocalizations l10n,
    DshProviderSettingsFailure? failure,
  ) {
    return switch (failure) {
      DshProviderSettingsFailure.conflict => l10n.dshProviderDetailConflict,
      DshProviderSettingsFailure.unavailable =>
        l10n.dshModelsSettingsUnavailableBody,
      DshProviderSettingsFailure.rejected => l10n.dshProviderDetailSaveFailed,
      DshProviderSettingsFailure.unreachable => l10n.dshErrorUnreachable,
      DshProviderSettingsFailure.unsupported => l10n.dshErrorUnsupported,
      _ => l10n.dshProviderDetailSaveFailed,
    };
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context)!;
    final entry = _entry;
    final controller = _controller;
    if (entry == null || controller == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.dshProviderDetailDeleteConfirmTitle),
        content: Text(l10n.dshProviderDetailDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.dshCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.dshProviderDetailDeleteProvider),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = await controller.delete(entry);
    if (!mounted) return;
    if (removed) {
      Navigator.of(context).pop();
    } else {
      showAppSnackBar(
        context,
        message: _failureMessage(l10n, controller.lastFailure),
        type: NotificationType.error,
      );
    }
  }

  Widget _pageScaffold({
    required String title,
    required Widget child,
    List<Widget> actions = const <Widget>[],
  }) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: SafeArea(top: false, child: child),
    );
  }

  static String _deriveCredentialRef(String providerId) {
    final upper = providerId.trim().toUpperCase().replaceAll(
      RegExp(r'[^A-Z0-9]+'),
      '_',
    );
    return '${upper}_API_KEY';
  }
}

// -----------------------------------------------------------------------------
// Small shared pieces (private to this page).
// -----------------------------------------------------------------------------

class _ProviderHeader extends StatelessWidget {
  const _ProviderHeader({
    required this.displayName,
    required this.providerId,
    required this.providerIconId,
  });

  final String displayName;
  final String providerId;
  final String providerIconId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        DshProviderIcon(
          providerId: providerIconId,
          displayName: displayName,
          size: 30,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            displayName,
            style: TextStyle(
              fontSize: 18,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (providerId.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              providerId,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: AppFontWeights.semibold,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: AppFontWeights.semibold,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.9),
      ),
    );
  }
}

class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IosCardPress(
          baseColor: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          onTap: onToggle,
          child: Row(
            children: [
              Icon(
                expanded ? Lucide.ChevronDown : Lucide.ChevronRight,
                size: 17,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
        AnimatedCrossFade(
          firstChild: child,
          secondChild: const SizedBox(width: double.infinity),
          crossFadeState: expanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: const Duration(milliseconds: 160),
        ),
      ],
    );
  }
}

class _ProtocolChip extends StatelessWidget {
  const _ProtocolChip({
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
    return IosCardPress(
      baseColor: selected
          ? cs.primary.withValues(alpha: 0.14)
          : context.appColors.surfaceCardFill,
      borderRadius: BorderRadius.circular(10),
      pressedBlendStrength: 0.08,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: selected
              ? AppFontWeights.semibold
              : AppFontWeights.medium,
          color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.8),
        ),
      ),
    );
  }
}

class _OAuthNote extends StatelessWidget {
  const _OAuthNote({required this.env});

  final List<String> env;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(text: l10n.dshProviderDetailApiKey),
        Text(
          l10n.dshProviderDetailCredentialConfigured,
          style: TextStyle(fontSize: 12, color: context.appColors.success),
        ),
        if (env.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            l10n.dshProviderDetailEnvHint(env.join(', ')),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ],
    );
  }
}

class _ReadOnlyModelCard extends StatelessWidget {
  const _ReadOnlyModelCard({required this.model});

  final DshModel model;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.appColors.surfaceCardFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  model.modelId,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  model.title,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Editable state for one model row; owns its text controllers.
class _DshModelEditor {
  _DshModelEditor({
    required this.keyId,
    required this.idController,
    required this.nameController,
    required this.contextWindowController,
    required this.maxTokensController,
    required this.inputs,
    required this.reasoningEfforts,
    this.expanded = true,
  });

  factory _DshModelEditor.fromModel(DshProviderModel model) {
    return _DshModelEditor(
      keyId: _nextKey++,
      idController: TextEditingController(text: model.id),
      nameController: TextEditingController(text: model.name ?? ''),
      contextWindowController: TextEditingController(
        text: model.contextWindow?.toString() ?? '',
      ),
      maxTokensController: TextEditingController(
        text: model.maxTokens?.toString() ?? '',
      ),
      inputs: {...model.inputs},
      reasoningEfforts: [...model.reasoningEfforts],
    );
  }

  factory _DshModelEditor.fromCatalog(DshModel model) {
    return _DshModelEditor(
      keyId: _nextKey++,
      idController: TextEditingController(text: model.modelId),
      nameController: TextEditingController(text: model.title),
      contextWindowController: TextEditingController(),
      maxTokensController: TextEditingController(),
      inputs: <DshModelInput>{DshModelInput.text},
      reasoningEfforts: <DshReasoningChoice>[],
    );
  }

  factory _DshModelEditor.empty() {
    return _DshModelEditor(
      keyId: _nextKey++,
      idController: TextEditingController(),
      nameController: TextEditingController(),
      contextWindowController: TextEditingController(),
      maxTokensController: TextEditingController(),
      inputs: <DshModelInput>{DshModelInput.text},
      reasoningEfforts: <DshReasoningChoice>[],
      expanded: true,
    );
  }

  static int _nextKey = 0;

  final int keyId;
  final TextEditingController idController;
  final TextEditingController nameController;
  final TextEditingController contextWindowController;
  final TextEditingController maxTokensController;
  final Set<DshModelInput> inputs;
  final List<DshReasoningChoice> reasoningEfforts;
  bool expanded;

  DshProviderModel? toModel() {
    final id = idController.text.trim();
    if (id.isEmpty) return null;
    final name = nameController.text.trim();
    return DshProviderModel(
      id: id,
      name: name.isEmpty ? null : name,
      contextWindow: int.tryParse(contextWindowController.text.trim()),
      maxTokens: int.tryParse(maxTokensController.text.trim()),
      inputs: {...inputs},
      reasoningEfforts: [...reasoningEfforts],
    );
  }

  void dispose() {
    idController.dispose();
    nameController.dispose();
    contextWindowController.dispose();
    maxTokensController.dispose();
  }
}

/// One editable model card (R11): drag handle, id, display name, collapse,
/// delete, context window, max output, input types and (custom only) reasoning
/// efforts.
class _DshModelEditorCard extends StatelessWidget {
  const _DshModelEditorCard({
    required this.editor,
    required this.index,
    required this.editable,
    required this.showReasoningEfforts,
    required this.onChanged,
    required this.onRemove,
  });

  final _DshModelEditor editor;
  final int index;
  final bool editable;
  final bool showReasoningEfforts;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: context.appColors.surfaceCardFill,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (editable)
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(
                      Lucide.GripVertical,
                      size: 16,
                      color: cs.onSurface.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              Expanded(
                child: IosFormTextField(
                  label: '',
                  controller: editor.idController,
                  hintText: l10n.dshProviderDetailModelId,
                  inlineLabel: false,
                  outerPadding: EdgeInsets.zero,
                  compact: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: IosFormTextField(
                  label: '',
                  controller: editor.nameController,
                  hintText: l10n.dshProviderDetailModelName,
                  inlineLabel: false,
                  outerPadding: EdgeInsets.zero,
                  compact: true,
                  onChanged: (_) => onChanged(),
                ),
              ),
              IosIconButton(
                icon: editor.expanded ? Lucide.ChevronUp : Lucide.ChevronDown,
                size: 15,
                padding: const EdgeInsets.all(3),
                onTap: () {
                  editor.expanded = !editor.expanded;
                  onChanged();
                },
              ),
              IosIconButton(
                icon: Lucide.Trash2,
                size: 15,
                padding: const EdgeInsets.all(3),
                tooltip: l10n.dshProviderDetailDeleteModel,
                semanticLabel: l10n.dshProviderDetailDeleteModel,
                onTap: editable ? onRemove : null,
              ),
            ],
          ),
          if (editor.expanded) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FieldLabel(text: l10n.dshProviderDetailContextWindow),
                      IosFormTextField(
                        label: '',
                        controller: editor.contextWindowController,
                        inlineLabel: false,
                        outerPadding: EdgeInsets.zero,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => onChanged(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FieldLabel(text: l10n.dshProviderDetailMaxTokens),
                      IosFormTextField(
                        label: '',
                        controller: editor.maxTokensController,
                        hintText: l10n.dshProviderDetailMaxTokensHint,
                        inlineLabel: false,
                        outerPadding: EdgeInsets.zero,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => onChanged(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _FieldLabel(text: l10n.dshProviderDetailInputTypes),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      IosCheckbox(
                        value: editor.inputs.contains(DshModelInput.text),
                        size: 18,
                        onChanged: editable
                            ? (value) {
                                if (value) {
                                  editor.inputs.add(DshModelInput.text);
                                } else {
                                  editor.inputs.remove(DshModelInput.text);
                                }
                                onChanged();
                              }
                            : null,
                      ),
                      const SizedBox(width: 6),
                      Text(l10n.dshProviderDetailInputText),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      IosCheckbox(
                        value: editor.inputs.contains(DshModelInput.image),
                        size: 18,
                        onChanged: editable
                            ? (value) {
                                if (value) {
                                  editor.inputs.add(DshModelInput.image);
                                } else {
                                  editor.inputs.remove(DshModelInput.image);
                                }
                                onChanged();
                              }
                            : null,
                      ),
                      const SizedBox(width: 6),
                      Text(l10n.dshProviderDetailInputImage),
                    ],
                  ),
                ),
              ],
            ),
            if (showReasoningEfforts) ...[
              const SizedBox(height: 12),
              DshReasoningEffortsEditor(
                choices: editor.reasoningEfforts,
                enabled: editable,
                onChanged: (choices) {
                  editor.reasoningEfforts
                    ..clear()
                    ..addAll(choices);
                  onChanged();
                },
              ),
            ],
          ],
        ],
      ),
    );
  }
}
