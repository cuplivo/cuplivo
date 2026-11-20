import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/responsive/screen_type_helper.dart';
import '../../../../shared/widgets/ios_form_text_field.dart';
import '../../../../shared/widgets/ios_settings_rows.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../../../shared/widgets/snackbar.dart';
import '../../../../theme/app_font_weights.dart';
import '../../../../theme/app_semantic_colors.dart';
import '../../models/dsh_remote.dart';
import '../../models/dsh_web_ui_link.dart';
import '../../state/dsh_connections_provider.dart';
import '../../state/dsh_gateway.dart';
import '../../widgets/dsh_failure_text.dart';
import '../../widgets/dsh_filled_button.dart';
import '../../widgets/dsh_link_status_dot.dart';
import '../../widgets/dsh_settings_tab_strip.dart';
import '../../widgets/dsh_whale_mark.dart';
import 'dsh_settings_tab_bodies.dart';
import 'dsh_settings_tabs.dart';
import 'models/dsh_models_tab_body.dart';

/// One remote DeepSeek Harness, as the user configures it.
///
/// The same page serves the two moments the reference pairs: [create] is the
/// direct-connect form reached from the create menu (tab 连接设置 selected, the
/// two cards, a WebUI link field and `确认`), and [edit] is the assistant
/// settings page opened from the owner card or the drawer's pencil. The tab
/// list is DSH's own: 连接设置 (Cuplivo's own connect surface), 通用设置, 模型,
/// 内置插件, Agent 预设, then the settings tabs enabled Host plugins register.
/// A tab whose data source is unavailable is absent rather than a placeholder.
///
/// DSH keeps every session and setting; this page writes only the local
/// connection record and the two server settings the brief puts outside
/// Cuplivo's scope. The launch token from the pasted link is used for one
/// connect attempt and never stored.
class DshAssistantSettingsPage extends StatefulWidget {
  const DshAssistantSettingsPage.create({super.key}) : remoteId = null;

  const DshAssistantSettingsPage.edit({super.key, required this.remoteId});

  /// Null in create mode; otherwise the record this page edits.
  final String? remoteId;

  @override
  State<DshAssistantSettingsPage> createState() =>
      _DshAssistantSettingsPageState();
}

class _DshAssistantSettingsPageState extends State<DshAssistantSettingsPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();

  String _tabId = 'connection';
  bool _submitting = false;
  String? _error;
  String? _success;

  /// Set the moment the record exists (create mode). After the first failed
  /// connect the page keeps editing that record instead of creating a second.
  String? _remoteId;
  String _createdName = '';
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _remoteId = widget.remoteId;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Localizations and the provider are inherited, so they are only readable
    // from here, not from initState.
    if (_initialized) return;
    _initialized = true;
    final l10n = AppLocalizations.of(context)!;
    final remote = _remoteId == null
        ? null
        : context.read<DshConnectionsProvider?>()?.remoteById(_remoteId!);
    _nameController.text = remote == null
        ? l10n.dshProductName
        : dshRemoteDisplayName(l10n, remote);
    _createdName = _nameController.text;
    _urlController.text = remote?.baseUrl ?? '';
    _nameController.addListener(_onNameChanged);
  }

  @override
  void dispose() {
    _nameController
      ..removeListener(_onNameChanged)
      ..dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    final trimmed = _nameController.text.trim();
    if (trimmed == _createdName) return;
    setState(() => _createdName = trimmed);
  }

  bool get _isCreate => widget.remoteId == null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connections = context.watch<DshConnectionsProvider?>();
    final status = _remoteId == null
        ? const DshLinkStatus.idle()
        : (connections?.linkStatus(_remoteId!) ?? const DshLinkStatus.idle());
    final catalog = _remoteId == null
        ? null
        : connections?.catalogFor(_remoteId!);
    final title = _createdName.trim().isEmpty
        ? l10n.dshProductName
        : _createdName.trim();
    final tabs = _buildTabs(
      l10n: l10n,
      status: status,
      catalog: catalog,
      connections: connections,
    );
    // A plugin can disappear while the page is open (disabled in another
    // window, or the Host restarted without it); keep the strip on a tab that
    // still exists instead of showing an empty pane. Mutating the field here is
    // safe: this build already uses the resolved id, and no rebuild is needed.
    final activeId = tabs.any((tab) => tab.id == _tabId) ? _tabId : 'general';
    _tabId = activeId;

    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 17)),
        actions: [
          if (!_isCreate)
            IconButton(
              tooltip: l10n.dshRemoteDeleteTooltip,
              icon: Icon(Lucide.Trash2, size: 20),
              onPressed: () => _confirmDelete(connections),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: DshSettingsTabStrip(
                    key: const Key('dsh-settings-tabs'),
                    specs: tabs,
                    activeId: activeId,
                    onChanged: (id) => setState(() => _tabId = id),
                  ),
                ),
                Expanded(
                  child: IndexedStack(
                    index: tabs.indexWhere((tab) => tab.id == activeId),
                    children: [for (final tab in tabs) tab.body(context)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The DSH-native tabs first, then the settings tabs enabled Host plugins
  /// register. A section the Host does not expose is absent, never a dead tab.
  List<DshSettingsTabSpec> _buildTabs({
    required AppLocalizations l10n,
    required DshLinkStatus status,
    required DshCatalogSnapshot? catalog,
    required DshConnectionsProvider? connections,
  }) {
    final remoteId = _remoteId ?? '';
    final tabs = <DshSettingsTabSpec>[
      DshSettingsTabSpec(
        id: 'connection',
        label: l10n.dshTabConnection,
        body: (context) => _buildConnectionTab(
          l10n: l10n,
          status: status,
          connections: connections,
        ),
      ),
      DshSettingsTabSpec(
        id: 'general',
        label: l10n.dshTabGeneral,
        body: (context) => _buildGeneralTab(
          l10n: l10n,
          status: status,
          catalog: catalog,
          connections: connections,
        ),
      ),
      DshSettingsTabSpec(
        id: 'models',
        label: l10n.dshTabModels,
        key: const Key('dsh-models-tab'),
        body: (context) => DshModelsTabBody(
          remoteId: remoteId,
          settings: connections?.providerSettingsFor(remoteId),
        ),
      ),
    ];
    final catalogNow = catalog;
    if (catalogNow == null ||
        !catalogNow.capabilities.supports(DshCapability.plugins)) {
      return tabs;
    }
    final plugins = catalogNow.plugins;
    final agentPresets = catalogNow.agentPresets;
    tabs
      ..add(
        DshSettingsTabSpec(
          id: 'plugins',
          label: l10n.dshTabPlugins,
          body: (context) => DshPluginsTabBody(plugins: plugins),
        ),
      )
      ..add(
        DshSettingsTabSpec(
          id: 'agentPresets',
          label: l10n.dshTabAgentPresets,
          body: (context) => DshAgentPresetsTabBody(groups: agentPresets),
        ),
      );
    // Plugin-registered settings sections are `settings.section` slots in the
    // official UI, not Host metadata: inventory `meta.title` is package
    // metadata and would turn every installed plugin into a fake tab. The spec
    // list stays dynamic so the later generic-surface harvest can append them,
    // but v2 ships only the five native tabs.
    return tabs;
  }

  Widget _buildConnectionTab({
    required AppLocalizations l10n,
    required DshLinkStatus status,
    required DshConnectionsProvider? connections,
  }) {
    final cs = Theme.of(context).colorScheme;
    final error = _error;
    final success = _success;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        SectionCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const DshWhaleAvatar(size: 56),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.dshAssistantNameLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 6),
                    IosFormTextField(
                      key: const Key('dsh-connect-name'),
                      label: '',
                      controller: _nameController,
                      inlineLabel: false,
                      outerPadding: EdgeInsets.zero,
                      textInputAction: TextInputAction.next,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              IosFormTextField(
                key: const Key('dsh-connect-url'),
                label: l10n.dshWebUiUrlLabel,
                hintText: l10n.dshWebUiUrlHint,
                controller: _urlController,
                inlineLabel: false,
                outerPadding: EdgeInsets.zero,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.dshWebUiUrlHelper,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
              if (status.isConnecting) ...[
                const SizedBox(height: 10),
                _InlineStatusLine(
                  icon: null,
                  busy: true,
                  text: l10n.dshStatusConnecting,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                _InlineStatusLine(
                  icon: Lucide.CircleAlert,
                  text: error,
                  color: cs.error,
                ),
              ],
              if (success != null) ...[
                const SizedBox(height: 10),
                _InlineStatusLine(
                  icon: Lucide.CheckCircle,
                  text: success,
                  color: context.appColors.success,
                ),
              ],
              const SizedBox(height: 16),
              DshFilledButton(
                key: const Key('dsh-connect-confirm'),
                label: l10n.dshConfirm,
                busy: _submitting,
                onPressed: _submit,
              ),
              if (!_isCreate && connections != null) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    DshLinkStatusDot(status: status),
                    const SizedBox(width: 6),
                    Text(
                      dshLinkStatusText(l10n, status),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGeneralTab({
    required AppLocalizations l10n,
    required DshLinkStatus status,
    required DshCatalogSnapshot? catalog,
    required DshConnectionsProvider? connections,
  }) {
    final cs = Theme.of(context).colorScheme;
    final ready = status.isReady && catalog != null;
    final settings = catalog?.generalSettings ?? const DshGeneralSettings();
    final presets = catalog?.permissionPresets ?? const <DshPermissionPreset>[];
    String? presetTitle;
    for (final preset in presets) {
      if (preset.id == settings.defaultPermissionPresetId) {
        presetTitle = preset.title;
        break;
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (!ready) ...[
          SectionCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Lucide.BadgeInfo,
                  size: 18,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status.isFailed
                        ? dshFailureText(l10n, status.failure)
                        : l10n.dshGeneralNotConnected,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        SectionCard(
          children: [
            IosNavRow(
              icon: Lucide.Shield,
              label: l10n.dshDefaultPermissionLabel,
              detailText: presetTitle ?? l10n.dshPermissionUnset,
              onTap: ready
                  ? () => _pickPermission(
                      l10n: l10n,
                      presets: presets,
                      current: settings.defaultPermissionPresetId,
                    )
                  : null,
            ),
            const IosRowDivider(),
            IosSwitchRow(
              icon: Lucide.Upload,
              label: l10n.dshUploadSessionLogLabel,
              value: settings.uploadSessionLog,
              onChanged: ready
                  ? (value) => _updateGeneral(
                      l10n,
                      settings.copyWith(uploadSessionLog: value),
                    )
                  : (_) {},
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickPermission({
    required AppLocalizations l10n,
    required List<DshPermissionPreset> presets,
    required String? current,
  }) async {
    final choice = await _showPresetPicker(
      context,
      l10n: l10n,
      presets: presets,
      current: current,
    );
    if (choice == null || !mounted) return;
    final connections = context.read<DshConnectionsProvider?>();
    final catalog = connections?.catalogFor(_remoteId!);
    final settings = catalog?.generalSettings ?? const DshGeneralSettings();
    await _updateGeneral(
      l10n,
      settings.copyWith(
        defaultPermissionPresetId: choice.clear ? null : choice.id,
      ),
    );
  }

  Future<void> _updateGeneral(
    AppLocalizations l10n,
    DshGeneralSettings next,
  ) async {
    final connections = context.read<DshConnectionsProvider?>();
    final id = _remoteId;
    if (connections == null || id == null) return;
    try {
      await connections.updateGeneralSettings(id, next);
    } on DshGatewayException catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: dshFailureText(l10n, error.failure),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final l10n = AppLocalizations.of(context)!;
    final connections = context.read<DshConnectionsProvider?>();
    if (connections == null) {
      setState(() {
        _error = l10n.dshErrorNotConfigured;
        _success = null;
      });
      return;
    }
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _error = l10n.dshErrorNameRequired;
        _success = null;
      });
      return;
    }
    final link = DshWebUiLink.tryParse(_urlController.text);
    if (link == null) {
      setState(() {
        _error = l10n.dshErrorInvalidLink;
        _success = null;
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _success = null;
    });
    try {
      final remote = await _resolveRemote(connections, name: name, link: link);
      if (!mounted) return;
      if (_remoteId != remote.id) setState(() => _remoteId = remote.id);
      final status = await connections.connect(
        remote.id,
        launchToken: link.launchToken,
      );
      if (!mounted) return;
      if (status.isReady) {
        setState(() => _success = l10n.dshStatusReady);
        if (_isCreate) {
          // The new owner card is what the user should see next; the owner
          // list has already rebuilt from the provider notification.
          Navigator.of(context).pop(remote.id);
        }
      } else {
        setState(() => _error = dshFailureText(l10n, status.failure));
      }
    } on DshGatewayException catch (error) {
      if (!mounted) return;
      setState(() => _error = dshFailureText(l10n, error.failure));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = l10n.dshErrorUnknown);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Returns the local record for this form, creating or updating it first.
  ///
  /// A record can disappear while the page is open (deleted from the owner
  /// list in another window); that case creates it again, exactly like the
  /// create flow, rather than leaving the page without a target.
  Future<DshRemote> _resolveRemote(
    DshConnectionsProvider connections, {
    required String name,
    required DshWebUiLink link,
  }) async {
    final id = _remoteId;
    final existing = id == null ? null : connections.remoteById(id);
    if (existing == null) {
      return connections.createRemote(name: name, link: link);
    }
    if (existing.name == name &&
        existing.baseUrl == link.baseUrl &&
        existing.authority == link.authority &&
        existing.secure == link.secure) {
      return existing;
    }
    return connections.updateRemote(
      existing.copyWith(
        name: name,
        baseUrl: link.baseUrl,
        authority: link.authority,
        secure: link.secure,
      ),
    );
  }

  Future<void> _confirmDelete(DshConnectionsProvider? connections) async {
    final l10n = AppLocalizations.of(context)!;
    final id = _remoteId;
    if (connections == null || id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(l10n.dshRemoteDeleteTitle),
          content: Text(l10n.dshRemoteDeleteContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.dshCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: cs.error),
              child: Text(l10n.dshRemoteDeleteConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await connections.deleteRemote(id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }
}

class _InlineStatusLine extends StatelessWidget {
  const _InlineStatusLine({
    required this.text,
    required this.color,
    this.icon,
    this.busy = false,
  });

  final String text;
  final Color color;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (busy)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.8, color: color),
          )
        else if (icon != null)
          Icon(icon, size: 15, color: color),
        if (busy || icon != null) const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, height: 1.3, color: color),
          ),
        ),
      ],
    );
  }
}

/// One permission choice in the picker: a preset, or "follow the server".
class _PresetChoice {
  const _PresetChoice.preset(this.id) : clear = false;

  const _PresetChoice.serverDefault() : id = null, clear = true;

  final String? id;
  final bool clear;
}

Future<_PresetChoice?> _showPresetPicker(
  BuildContext context, {
  required AppLocalizations l10n,
  required List<DshPermissionPreset> presets,
  required String? current,
}) {
  final cs = Theme.of(context).colorScheme;
  // Both layouts render the same rows; only the container differs, because
  // desktop never uses a bottom sheet (AGENTS UI guidelines).
  Widget rows(BuildContext ctx, {required bool withHandle}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (withHandle)
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
        if (withHandle) const SizedBox(height: 12),
        Text(
          l10n.dshPermissionPickerTitle,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, fontWeight: AppFontWeights.semibold),
        ),
        const SizedBox(height: 8),
        _PresetRow(
          label: l10n.dshPermissionUnset,
          selected: current == null,
          onTap: () =>
              Navigator.of(ctx).pop(const _PresetChoice.serverDefault()),
        ),
        for (final preset in presets)
          _PresetRow(
            label: preset.title,
            subtitle: preset.description,
            selected: preset.id == current,
            onTap: () => Navigator.of(ctx).pop(_PresetChoice.preset(preset.id)),
          ),
      ],
    );
  }

  if (ResponsiveHelper.isDesktop(context)) {
    return showDialog<_PresetChoice>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: context.overlaySurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: rows(ctx, withHandle: false),
            ),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<_PresetChoice>(
    context: context,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: rows(ctx, withHandle: true),
        ),
      ),
    ),
  );
}

class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(label, style: const TextStyle(fontSize: 15)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
      trailing: selected
          ? Icon(Lucide.Check, size: 18, color: cs.primary)
          : null,
      onTap: onTap,
    );
  }
}
