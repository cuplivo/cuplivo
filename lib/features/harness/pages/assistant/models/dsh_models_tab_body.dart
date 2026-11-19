import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_add_provider_page.dart';
import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_detail_page.dart';
import 'package:Cuplivo/features/harness/models/dsh_provider_settings.dart';
import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_settings_controller.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_failure_text.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_models_search_bar.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_models_states.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_provider_row.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_provider_icon.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// One provider row of the 模型 tab, independent of where it came from.
///
/// [entry] is set when the settings seam supplied the list (every configurable
/// route, including ones without a credential); [group] is set when only the
/// live model catalog was readable (this build, before the seam is wired).
@immutable
class DshProviderListRow {
  const DshProviderListRow({
    required this.providerId,
    required this.displayName,
    required this.enabled,
    required this.modelCount,
    this.entry,
    this.group,
    this.diagnostic,
  });

  final String providerId;
  final String displayName;
  final bool enabled;
  final int modelCount;
  final DshProviderEntry? entry;
  final DshProviderGroup? group;
  final String? diagnostic;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshProviderListRow &&
          other.providerId == providerId &&
          other.displayName == displayName &&
          other.enabled == enabled &&
          other.modelCount == modelCount &&
          other.entry == entry &&
          other.group == group &&
          other.diagnostic == diagnostic;

  @override
  int get hashCode => Object.hash(
    providerId,
    displayName,
    enabled,
    modelCount,
    entry,
    group,
    diagnostic,
  );
}

/// Builds the provider rows the 模型 tab shows.
///
/// The settings list wins when available because it is the complete route
/// directory (R10 needs it); otherwise the live catalog's groups are used, so
/// the connected host's providers still render in this build. Search matches
/// the display name and the route id, case-insensitively; the result is sorted
/// by display name, with route id breaking ties.
List<DshProviderListRow> dshProviderListRows({
  List<DshProviderEntry>? settingsEntries,
  List<DshProviderGroup> catalogGroups = const <DshProviderGroup>[],
  String query = '',
}) {
  final rows = <DshProviderListRow>[
    if (settingsEntries != null)
      for (final entry in settingsEntries)
        DshProviderListRow(
          providerId: entry.id,
          displayName: entry.effectiveDisplayName,
          enabled: entry.configured && (entry.error ?? '').trim().isEmpty,
          modelCount: entry.profile.models.length,
          entry: entry,
          diagnostic: entry.error,
        )
    else
      for (final group in catalogGroups)
        DshProviderListRow(
          providerId: group.id,
          displayName: group.title.trim().isEmpty ? group.id : group.title,
          enabled: (group.failureMessage ?? '').trim().isEmpty,
          modelCount: group.models.length,
          group: group,
          diagnostic: group.failureMessage,
        ),
  ];
  final normalized = query.trim().toLowerCase();
  final filtered = normalized.isEmpty
      ? rows
      : [
          for (final row in rows)
            if (row.displayName.toLowerCase().contains(normalized) ||
                row.providerId.toLowerCase().contains(normalized))
              row,
        ];
  filtered.sort((a, b) {
    final byName = a.displayName.toLowerCase().compareTo(
      b.displayName.toLowerCase(),
    );
    return byName != 0 ? byName : a.providerId.compareTo(b.providerId);
  });
  return filtered;
}

/// The embeddable body of the assistant settings 模型 tab (R9–R11).
///
/// The foundation's settings page owns the tab strip and the page chrome; this
/// widget owns everything under it. It reads the live provider list from
/// [DshConnectionsProvider.catalogFor] so the row data is the connected host's
/// own catalog, and accepts an optional [settings] seam for editing provider
/// profiles. Without the seam the list and the read-only model details still
/// work; the detail page then says provider editing needs the settings adapter
/// that ships in the next slice — never fake data.
class DshModelsTabBody extends StatefulWidget {
  const DshModelsTabBody({super.key, required this.remoteId, this.settings});

  /// The remote whose providers this tab lists.
  final String remoteId;

  /// Provider-settings seam. Null until the foundation wires the adapter;
  /// everything that needs a write is disabled honestly in that case.
  final DshProviderSettingsGateway? settings;

  @override
  State<DshModelsTabBody> createState() => _DshModelsTabBodyState();
}

class _DshModelsTabBodyState extends State<DshModelsTabBody> {
  final TextEditingController _searchController = TextEditingController();
  DshProviderSettingsController? _controller;
  String _query = '';
  bool _refreshingCatalog = false;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  @override
  void didUpdateWidget(covariant DshModelsTabBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) {
      _controller?.dispose();
      _controller = null;
      _createController();
    }
  }

  void _createController() {
    final settings = widget.settings;
    if (settings == null) return;
    final controller = DshProviderSettingsController(gateway: settings);
    _controller = controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      controller.ensureLoaded();
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return _buildBody(context, null);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildBody(context, controller),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DshProviderSettingsController? controller,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final connections = context.watch<DshConnectionsProvider?>();
    final catalog = connections?.catalogFor(widget.remoteId);
    final status =
        connections?.linkStatus(widget.remoteId) ?? const DshLinkStatus.idle();
    final settingsEntries = controller?.entries;

    final rows = dshProviderListRows(
      settingsEntries: settingsEntries,
      catalogGroups: catalog?.models.providers ?? const <DshProviderGroup>[],
      query: _query,
    );
    // A failed `session/modelCatalog` read is a per-section failure, not an
    // empty list: say so instead of pretending the host has no providers.
    DshCatalogFailure? modelsFailure;
    for (final failure in catalog?.failures ?? const <DshCatalogFailure>[]) {
      if (failure.section == DshCatalogSection.models) {
        modelsFailure = failure;
        break;
      }
    }

    final card = <Widget>[
      const SizedBox(height: 8),
      DshModelsSearchBar(
        key: const Key('dsh-models-search'),
        controller: _searchController,
        hintText: l10n.dshModelsSearchHint,
        addTooltip: l10n.dshModelsAddProvider,
        onChanged: (value) => setState(() => _query = value),
        onClear: () {
          if (_searchController.text.isEmpty) return;
          _searchController.clear();
          setState(() => _query = '');
        },
        onAdd: () => _openAddProvider(controller, catalog),
      ),
      const SizedBox(height: 12),
      // Adding a provider is the first row of the reference list; it stays
      // visible while searching so the creation flow never gets filtered out.
      DshProviderCustomCard(
        key: const Key('dsh-models-custom-provider'),
        onTap: () => _openDetail(controller, createCustom: true),
      ),
      const SizedBox(height: 10),
    ];

    Widget content;
    if (controller != null && !controller.hasLoaded) {
      content = DshModelsStatePanel(
        icon: Lucide.Loader,
        title: l10n.dshModelsLoading,
      );
    } else if (controller != null &&
        controller.isLoading &&
        settingsEntries == null) {
      content = DshModelsStatePanel(
        icon: Lucide.Loader,
        title: l10n.dshModelsLoading,
      );
    } else if (controller != null &&
        settingsEntries == null &&
        controller.lastFailure != null) {
      content = DshModelsStatePanel(
        icon: Lucide.CloudOff,
        title: l10n.dshModelsLoadFailed,
        body: dshProviderSettingsFailureText(l10n, controller.lastFailure),
        actionLabel: l10n.dshModelsRefresh,
        onAction: () => controller.load(),
      );
    } else if (settingsEntries == null && !status.isReady) {
      content = status.isFailed
          ? DshModelsStatePanel(
              icon: Lucide.CloudOff,
              title: l10n.dshModelsNotConnectedTitle,
              body: dshFailureText(l10n, status.failure),
              actionLabel: l10n.dshModelsRefresh,
              onAction: () => _refreshCatalog(connections),
            )
          : DshModelsStatePanel(
              icon: status.isConnecting ? Lucide.Loader : Lucide.Link2,
              title: status.isConnecting
                  ? l10n.dshModelsLoading
                  : l10n.dshModelsNotConnectedTitle,
              body: status.isConnecting ? null : l10n.dshModelsNotConnectedBody,
            );
    } else if (settingsEntries == null && catalog == null) {
      content = DshModelsStatePanel(
        icon: Lucide.Loader,
        title: l10n.dshModelsLoading,
      );
    } else if (rows.isEmpty && modelsFailure != null) {
      content = DshModelsStatePanel(
        icon: Lucide.CloudOff,
        title: l10n.dshModelsLoadFailed,
        body: dshFailureText(l10n, modelsFailure.failure),
        actionLabel: l10n.dshModelsRefresh,
        onAction: () => _refreshCatalog(connections),
      );
    } else if (rows.isEmpty) {
      final searching = _query.trim().isNotEmpty;
      content = DshModelsStatePanel(
        icon: searching ? Lucide.SearchX : Lucide.Boxes,
        title: searching ? l10n.dshModelsSearchEmpty : l10n.dshModelsEmptyTitle,
        body: searching ? null : l10n.dshModelsEmptyBody,
      );
    } else {
      content = ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          for (final row in rows) ...[
            _DshProviderRowTile(
              key: ValueKey<String>('dsh-provider-row-${row.providerId}'),
              row: row,
              onTap: () => _openDetail(controller, row: row),
            ),
            const SizedBox(height: 10),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Column(children: card),
        ),
        Expanded(child: content),
      ],
    );
  }

  Future<void> _refreshCatalog(DshConnectionsProvider? connections) async {
    if (connections == null || _refreshingCatalog) return;
    setState(() => _refreshingCatalog = true);
    try {
      await connections.refreshCatalog(widget.remoteId);
    } finally {
      if (mounted) setState(() => _refreshingCatalog = false);
    }
  }

  /// The live catalog group behind a settings row, so the detail page can show
  /// the adapter's model list read-only when the profile itself declares none.
  DshProviderGroup? _catalogGroupFor(String? providerId) {
    if (providerId == null || providerId.isEmpty) return null;
    final catalog = context.read<DshConnectionsProvider?>()?.catalogFor(
      widget.remoteId,
    );
    for (final group
        in catalog?.models.providers ?? const <DshProviderGroup>[]) {
      if (group.id == providerId) return group;
    }
    return null;
  }

  Future<void> _openAddProvider(
    DshProviderSettingsController? controller,
    DshCatalogSnapshot? catalog,
  ) async {
    final entries = controller?.entries;
    final choices = <DshProviderChoice>[
      if (entries != null)
        for (final entry in entries)
          DshProviderChoice(
            providerId: entry.id,
            displayName: entry.effectiveDisplayName,
            entry: entry,
          )
      else
        for (final group
            in catalog?.models.providers ?? const <DshProviderGroup>[])
          DshProviderChoice(
            providerId: group.id,
            displayName: group.title.trim().isEmpty ? group.id : group.title,
            group: group,
          ),
    ];
    final picked = await showDshAddProviderPicker(
      context,
      choices: choices,
      customEnabled: true,
    );
    if (!mounted || picked == null) return;
    if (picked.isCustom) {
      await _openDetail(controller, createCustom: true);
      return;
    }
    final entry = picked.entry;
    final group = picked.group;
    await _openDetail(controller, entry: entry, group: group);
  }

  Future<void> _openDetail(
    DshProviderSettingsController? controller, {
    DshProviderListRow? row,
    DshProviderEntry? entry,
    DshProviderGroup? group,
    bool createCustom = false,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DshProviderDetailPage(
          remoteId: widget.remoteId,
          settings: widget.settings,
          controller: controller,
          entry: entry ?? row?.entry,
          catalogGroup:
              group ??
              row?.group ??
              _catalogGroupFor(entry?.id ?? row?.providerId),
          createCustom: createCustom,
        ),
      ),
    );
    if (!mounted) return;
    // A save/deletion inside the detail page updates the shared controller;
    // rebuild so the list reflects it even if the controller is owned above.
  }
}

class _DshProviderRowTile extends StatelessWidget {
  const _DshProviderRowTile({
    super.key,
    required this.row,
    required this.onTap,
  });

  final DshProviderListRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The reference card carries only name + 启用 pill + chevron; the host's
    // diagnostic line is the one exception, because an unusable provider must
    // say why instead of hiding the reason.
    final diagnostic = row.diagnostic?.trim() ?? '';
    final subtitle = diagnostic.isEmpty ? null : diagnostic;
    return DshProviderCard(
      providerId: row.providerId,
      displayName: row.displayName,
      enabled: row.enabled,
      subtitle: subtitle,
      icon: DshProviderIcon(
        providerId: row.providerId,
        displayName: row.displayName,
      ),
      onTap: onTap,
    );
  }
}

/// The localized sentence for a settings-seam failure.
String dshProviderSettingsFailureText(
  AppLocalizations l10n,
  DshProviderSettingsFailure? failure,
) {
  return switch (failure) {
    null => l10n.dshOperationFailed,
    DshProviderSettingsFailure.unavailable =>
      l10n.dshModelsSettingsUnavailableBody,
    DshProviderSettingsFailure.conflict => l10n.dshProviderDetailConflict,
    DshProviderSettingsFailure.rejected => l10n.dshProviderDetailSaveFailed,
    DshProviderSettingsFailure.unreachable => l10n.dshErrorUnreachable,
    DshProviderSettingsFailure.unsupported => l10n.dshErrorUnsupported,
    DshProviderSettingsFailure.unknown => l10n.dshOperationFailed,
  };
}
