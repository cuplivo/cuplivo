import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../../main.dart' show routeObserver;
import '../../../core/models/workspace.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../../core/services/workspace/linux_sandbox_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_expandable_section.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../settings/pages/mount_files_page.dart';
import '../controllers/dependency_install_controller.dart';
import 'sandbox_files_page.dart';
import 'workspace_terminal_page.dart';

class WorkspaceDetailPage extends StatefulWidget {
  const WorkspaceDetailPage({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  State<WorkspaceDetailPage> createState() => _WorkspaceDetailPageState();
}

class _WorkspaceDetailPageState extends State<WorkspaceDetailPage>
    with RouteAware {
  bool _toolsExpanded = false;
  bool _depsExpanded = false;
  final Map<String, bool> _depInstalled = <String, bool>{};
  bool _depStatusLoading = false;
  bool _hasRuntime = true;

  @override
  void initState() {
    super.initState();
    context.read<DependencyInstallController>().addListener(_onInstallChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshDepStatus());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    // Re-probe on every return to this page so dependencies installed by the
    // LLM shell tool (or finished background queue items) show up.
    if (mounted) unawaited(_refreshDepStatus());
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    context.read<DependencyInstallController>().removeListener(
      _onInstallChanged,
    );
    super.dispose();
  }

  void _onInstallChanged() {
    if (!mounted) return;
    final controller = context.read<DependencyInstallController>();
    final wp = context.read<WorkspaceProvider>();
    final ws = wp.getById(widget.workspaceId);
    if (ws == null) return;
    final done = controller.takeCompleted(ws.id);
    if (done.isNotEmpty) {
      unawaited(_refreshDepStatus());
      final l10n = AppLocalizations.of(context)!;
      for (final e in done.entries) {
        final error = e.value;
        if (error != null) {
          showAppSnackBar(context, message: error.toString());
        } else if (e.key == WorkspaceDependencyIds.base) {
          // Base install may succeed while the native runtime is missing.
          LinuxSandboxService.instance.hasRuntime().then((runtime) {
            if (!mounted) return;
            showAppSnackBar(
              context,
              message: runtime
                  ? l10n.workspaceDepInstallDone
                  : l10n.workspaceSandboxRuntimeMissing,
            );
          });
        } else {
          showAppSnackBar(context, message: l10n.workspaceDepInstallDone);
        }
      }
    }
    setState(() {});
  }

  Future<void> _refreshDepStatus() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final wp = context.read<WorkspaceProvider>();
    final ws = wp.getById(widget.workspaceId);
    if (ws == null) return;
    final host = wp.hostPathFor(ws);
    if (host == null) return;
    setState(() => _depStatusLoading = true);
    try {
      final svc = LinuxSandboxService.instance;
      final runtime = await svc.hasRuntime();
      final next = <String, bool>{};
      for (final id in WorkspaceDependencyIds.ordered) {
        next[id] = await svc.isDependencyInstalled(host, id);
      }
      if (!mounted) return;
      setState(() {
        _hasRuntime = runtime;
        _depInstalled
          ..clear()
          ..addAll(next);
        _depStatusLoading = false;
      });
    } catch (e) {
      debugPrint('WorkspaceDetailPage._refreshDepStatus: $e');
      if (mounted) setState(() => _depStatusLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final wp = context.watch<WorkspaceProvider>();
    final ws = wp.getById(widget.workspaceId);
    if (ws == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsPageWorkspace)),
        body: Center(child: Text(l10n.workspaceNotFound)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(ws.displayName),
        actions: [
          IconButton(
            tooltip: l10n.workspaceRename,
            icon: Icon(Lucide.Pencil, size: 20, color: cs.onSurface),
            onPressed: () => _rename(context, ws),
          ),
          if (Platform.isAndroid || Platform.isIOS)
            IconButton(
              tooltip: l10n.workspaceTerminal,
              icon: Icon(Lucide.Terminal, size: 20, color: cs.onSurface),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WorkspaceTerminalPage(workspaceId: ws.id),
                  ),
                );
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _sectionCard(
            children: [
              _navRow(
                context,
                icon: Lucide.FolderOpen,
                title: l10n.workspaceFilesEntry,
                subtitle: '@${ws.alias}',
                onTap: () {
                  final path = wp.hostPathFor(ws);
                  if (path == null) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MountFilesPage(
                        mount: FilesystemMount(
                          alias: ws.alias,
                          path: path,
                          readOnly: ws.readOnly,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          IosExpandableSection(
            icon: Lucide.Wrench,
            title: l10n.workspaceFilesystemTools,
            expanded: _toolsExpanded,
            onToggle: () => setState(() => _toolsExpanded = !_toolsExpanded),
            showDivider: true,
            children: [
              for (final tool in WorkspaceToolNames.filesystemTools)
                _toolRow(context, ws, tool),
            ],
          ),
          const SizedBox(height: 12),
          _sectionCard(
            children: [
              _toolRow(
                context,
                ws,
                WorkspaceToolNames.shell,
                forceTitle: l10n.workspaceToolShellTitle,
                forceSubtitle: (!Platform.isAndroid && !Platform.isIOS)
                    ? l10n.workspaceShellMobileOnly
                    : !_hasRuntime
                    ? l10n.workspaceSandboxRuntimeMissing
                    : (_depInstalled[WorkspaceDependencyIds.base] != true)
                    ? l10n.workspaceSandboxBaseRequired
                    : l10n.workspaceToolShellUserDesc,
                enabledOverride: (Platform.isAndroid || Platform.isIOS)
                    ? null
                    : false,
                onChangedOverride: (Platform.isAndroid || Platform.isIOS)
                    ? null
                    : (_) {
                        showAppSnackBar(
                          context,
                          message: l10n.workspaceShellMobileOnly,
                        );
                      },
              ),
            ],
          ),
          if (Platform.isAndroid || Platform.isIOS) ...[
            const SizedBox(height: 12),
            IosExpandableSection(
              icon: Lucide.Boxes,
              title: l10n.workspaceInstallDeps,
              expanded: _depsExpanded,
              onToggle: () => setState(() => _depsExpanded = !_depsExpanded),
              showDivider: true,
              children: [
                for (final depId in WorkspaceDependencyIds.ordered)
                  _depRow(context, ws, depId),
              ],
            ),
            const SizedBox(height: 12),
            _sectionCard(
              children: [
                _navRow(
                  context,
                  icon: Lucide.HardDrive,
                  title: l10n.workspaceSandboxDirEntryTitle,
                  subtitle: _sandboxDirSubtitle(context),
                  enabled: _depInstalled[WorkspaceDependencyIds.base] == true,
                  onTap: () => _openSandboxDir(ws),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Sandbox dir entry subtitle: "Title ✓ · Title ✓" for every installed
  /// non-base dependency, or the base-required hint when the base is missing.
  String _sandboxDirSubtitle(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_depInstalled[WorkspaceDependencyIds.base] != true) {
      return l10n.workspaceSandboxBaseRequired;
    }
    final installed = [
      for (final id in WorkspaceDependencyIds.ordered)
        if (id != WorkspaceDependencyIds.base && _depInstalled[id] == true)
          _depTitle(l10n, id),
    ];
    if (installed.isEmpty) return l10n.workspaceSandboxNoDeps;
    return installed.map((t) => '$t ✓').join(' · ');
  }

  Future<void> _openSandboxDir(Workspace ws) async {
    final l10n = AppLocalizations.of(context)!;
    if (_depInstalled[WorkspaceDependencyIds.base] != true) {
      showAppSnackBar(context, message: l10n.workspaceSandboxBaseRequired);
      return;
    }
    final wp = context.read<WorkspaceProvider>();
    final host = wp.hostPathFor(ws);
    if (host == null) return;
    final svc = LinuxSandboxService.instance;
    String root;
    try {
      // Guest root `/` maps to the per-workspace proot rootfs on Android
      // and the shared fakefs `data/` tree on iOS.
      root = Platform.isIOS
          ? p.join(await svc.iosRootfsPath(), 'data')
          : svc.linuxDir(host);
    } catch (e) {
      debugPrint('WorkspaceDetailPage._openSandboxDir: $e');
      if (mounted) showAppSnackBar(context, message: e.toString());
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SandboxFilesPage(rootHostPath: root)),
    );
  }

  Widget _toolRow(
    BuildContext context,
    Workspace ws,
    String tool, {
    String? forceTitle,
    String? forceSubtitle,
    bool? enabledOverride,
    ValueChanged<bool>? onChangedOverride,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final enabled = enabledOverride ?? ws.isToolEnabled(tool);
    final needsApproval = ws.isToolNeedsApproval(tool);
    final title = forceTitle ?? _toolTitle(l10n, tool);
    final subtitle = forceSubtitle ?? _toolDesc(l10n, tool);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: cs.onSurface.withValues(alpha: 0.62),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              IosSwitch(
                value: enabled,
                onChanged:
                    onChangedOverride ??
                    (v) => context.read<WorkspaceProvider>().setToolEnabled(
                      ws.id,
                      tool,
                      v,
                    ),
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Lucide.Shield,
                  size: 13,
                  color: needsApproval
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.mcpToolNeedsApproval,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                IosSwitch(
                  value: needsApproval,
                  onChanged: (v) => context
                      .read<WorkspaceProvider>()
                      .setToolNeedsApproval(ws.id, tool, v),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _depRow(BuildContext context, Workspace ws, String depId) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const SizedBox.shrink();
    }
    final status = context.watch<DependencyInstallController>().statusFor(
      ws.id,
      depId,
    );
    final installing = status == DepInstallStatus.installing;
    final queued = status == DepInstallStatus.queued;
    final installed = _depInstalled[depId] == true;
    final baseInstalled = _depInstalled[WorkspaceDependencyIds.base] == true;
    final needsBaseFirst =
        depId != WorkspaceDependencyIds.base && !baseInstalled;
    final needsRuntime =
        depId != WorkspaceDependencyIds.base && baseInstalled && !_hasRuntime;

    String? subtitleExtra;
    if (needsBaseFirst) {
      subtitleExtra = l10n.workspaceSandboxBaseRequired;
    } else if (needsRuntime) {
      subtitleExtra = l10n.workspaceSandboxRuntimeMissing;
    }

    final label = installing
        ? l10n.workspaceDepInstalling
        : queued
        ? l10n.workspaceDepQueued
        : installed
        ? l10n.workspaceDepInstalled
        : l10n.workspaceDepInstall;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _depTitle(l10n, depId),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _depDesc(l10n, depId),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.62),
                      ),
                    ),
                    if (subtitleExtra != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitleExtra,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.error.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.workspaceDepSettings,
                icon: Icon(Lucide.Settings, size: 18, color: cs.primary),
                onPressed: installing || queued
                    ? null
                    : () => _showDepSettings(context, ws, depId),
              ),
              TextButton(
                onPressed: installing || queued || _depStatusLoading
                    ? null
                    : () =>
                          _installDep(context, ws, depId, reinstall: installed),
                child: Text(label),
              ),
            ],
          ),
          if (installing) ..._installProgressArea(context, ws, depId),
        ],
      ),
    );
  }

  List<Widget> _installProgressArea(
    BuildContext context,
    Workspace ws,
    String depId,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final controller = context.read<DependencyInstallController>();
    final progress = controller.progressFor(ws.id, depId);
    final stage = controller.stageFor(ws.id, depId);
    final stageLabel = _depStageLabel(l10n, stage);
    final percent = progress != null ? '${(progress * 100).round()}%' : null;
    return [
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          minHeight: 3,
          value: progress,
          backgroundColor: cs.primary.withValues(alpha: 0.12),
          color: cs.primary,
        ),
      ),
      if (stageLabel != null || percent != null) ...[
        const SizedBox(height: 4),
        Text(
          [
            if (stageLabel != null) stageLabel,
            if (percent != null) percent,
          ].join(' · '),
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ],
    ];
  }

  String? _depStageLabel(AppLocalizations l10n, String? stage) =>
      switch (stage) {
        'downloading' => l10n.workspaceDepStageDownloading,
        'extracting' => l10n.workspaceDepStageExtracting,
        'recover' => l10n.workspaceDepStageRecover,
        'update' => l10n.workspaceDepStageUpdate,
        'install' || 'installing' => l10n.workspaceDepStageInstall,
        _ => null,
      };

  Future<void> _installDep(
    BuildContext context,
    Workspace ws,
    String depId, {
    bool reinstall = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    if (!Platform.isAndroid && !Platform.isIOS) {
      showAppSnackBar(context, message: l10n.workspaceShellMobileOnly);
      return;
    }
    if (reinstall) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.workspaceDepReinstall),
          content: Text(_depTitle(l10n, depId)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.workspaceCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.workspaceConfirm),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    final wp = context.read<WorkspaceProvider>();
    final host = wp.hostPathFor(ws);
    if (host == null) return;
    final latest = wp.getById(ws.id) ?? ws;
    context.read<DependencyInstallController>().enqueue(
      workspaceId: ws.id,
      depId: depId,
      hostPath: host,
      pref: latest.prefFor(depId),
    );
  }

  Future<void> _showDepSettings(
    BuildContext context,
    Workspace ws,
    String depId,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final pref = ws.prefFor(depId);
    var sourceId = pref.sourceId;
    final customCtrl = TextEditingController(text: pref.customUrl ?? '');
    try {
      final ok = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
            ),
            child: StatefulBuilder(
              builder: (ctx, setSt) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.workspaceDepSettings,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(l10n.workspaceDepSource),
                    const SizedBox(height: 8),
                    DropdownButton<String>(
                      value: sourceId,
                      isExpanded: true,
                      items: [
                        DropdownMenuItem(
                          value: 'auto',
                          child: Text(l10n.workspaceDepSourceAuto),
                        ),
                        DropdownMenuItem(
                          value: 'official',
                          child: Text(l10n.workspaceDepSourceOfficial),
                        ),
                        DropdownMenuItem(
                          value: 'tuna',
                          child: Text(l10n.workspaceDepSourceTuna),
                        ),
                        DropdownMenuItem(
                          value: 'aliyun',
                          child: Text(l10n.workspaceDepSourceAliyun),
                        ),
                        DropdownMenuItem(
                          value: 'custom',
                          child: Text(l10n.workspaceDepSourceCustom),
                        ),
                      ],
                      onChanged: (v) => setSt(() => sourceId = v ?? 'auto'),
                    ),
                    if (sourceId == 'custom') ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: customCtrl,
                        decoration: InputDecoration(
                          hintText: l10n.workspaceDepCustomUrlHint,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(l10n.workspaceConfirm),
                    ),
                  ],
                );
              },
            ),
          );
        },
      );
      if (ok == true && context.mounted) {
        await context.read<WorkspaceProvider>().setDependencyPref(
          ws.id,
          depId,
          DependencyInstallPref(
            sourceId: sourceId,
            customUrl: customCtrl.text.trim().isEmpty
                ? null
                : customCtrl.text.trim(),
          ),
        );
      }
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => customCtrl.dispose());
    }
  }

  Future<void> _rename(BuildContext context, Workspace ws) async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: ws.displayName);
    final provider = context.read<WorkspaceProvider>();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.workspaceRename),
          content: TextField(controller: ctrl, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.workspaceCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.workspaceConfirm),
            ),
          ],
        ),
      );
      if (ok == true && context.mounted) {
        try {
          await provider.renameWorkspace(ws.id, ctrl.text);
        } catch (e) {
          if (context.mounted) {
            showAppSnackBar(context, message: e.toString());
          }
        }
      }
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    }
  }

  String _toolTitle(AppLocalizations l10n, String tool) => switch (tool) {
    WorkspaceToolNames.read => l10n.workspaceToolReadTitle,
    WorkspaceToolNames.write => l10n.workspaceToolWriteTitle,
    WorkspaceToolNames.patch => l10n.workspaceToolPatchTitle,
    WorkspaceToolNames.delete => l10n.workspaceToolDeleteTitle,
    WorkspaceToolNames.glob => l10n.workspaceToolGlobTitle,
    WorkspaceToolNames.grep => l10n.workspaceToolGrepTitle,
    WorkspaceToolNames.outline => l10n.workspaceToolOutlineTitle,
    WorkspaceToolNames.mkdir => l10n.workspaceToolMkdirTitle,
    WorkspaceToolNames.move => l10n.workspaceToolMoveTitle,
    WorkspaceToolNames.zip => l10n.workspaceToolZipTitle,
    WorkspaceToolNames.unzip => l10n.workspaceToolUnzipTitle,
    WorkspaceToolNames.download => l10n.workspaceToolDownloadTitle,
    _ => tool,
  };

  String _toolDesc(AppLocalizations l10n, String tool) => switch (tool) {
    WorkspaceToolNames.read => l10n.workspaceToolReadUserDesc,
    WorkspaceToolNames.write => l10n.workspaceToolWriteUserDesc,
    WorkspaceToolNames.patch => l10n.workspaceToolPatchUserDesc,
    WorkspaceToolNames.delete => l10n.workspaceToolDeleteUserDesc,
    WorkspaceToolNames.glob => l10n.workspaceToolGlobUserDesc,
    WorkspaceToolNames.grep => l10n.workspaceToolGrepUserDesc,
    WorkspaceToolNames.outline => l10n.workspaceToolOutlineUserDesc,
    WorkspaceToolNames.mkdir => l10n.workspaceToolMkdirUserDesc,
    WorkspaceToolNames.move => l10n.workspaceToolMoveUserDesc,
    WorkspaceToolNames.zip => l10n.workspaceToolZipUserDesc,
    WorkspaceToolNames.unzip => l10n.workspaceToolUnzipUserDesc,
    WorkspaceToolNames.download => l10n.workspaceToolDownloadUserDesc,
    _ => '',
  };

  String _depTitle(AppLocalizations l10n, String id) => switch (id) {
    WorkspaceDependencyIds.base => l10n.workspaceDepBaseTitle,
    WorkspaceDependencyIds.python => l10n.workspaceDepPythonTitle,
    WorkspaceDependencyIds.nodejs => l10n.workspaceDepNodeTitle,
    WorkspaceDependencyIds.git => l10n.workspaceDepGitTitle,
    WorkspaceDependencyIds.office => l10n.workspaceDepOfficeTitle,
    WorkspaceDependencyIds.buildEssential => l10n.workspaceDepBuildTitle,
    _ => id,
  };

  String _depDesc(AppLocalizations l10n, String id) => switch (id) {
    WorkspaceDependencyIds.base => l10n.workspaceDepBaseDesc,
    WorkspaceDependencyIds.python => l10n.workspaceDepPythonDesc,
    WorkspaceDependencyIds.nodejs => l10n.workspaceDepNodeDesc,
    WorkspaceDependencyIds.git => l10n.workspaceDepGitDesc,
    WorkspaceDependencyIds.office => l10n.workspaceDepOfficeDesc,
    WorkspaceDependencyIds.buildEssential => l10n.workspaceDepBuildDesc,
    _ => '',
  };

  Widget _sectionCard({required List<Widget> children}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.1)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Widget _navRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    bool enabled = true,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurface.withValues(alpha: 0.45);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Icon(icon, size: 20, color: enabled ? cs.primary : dim),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.semibold,
                      color: enabled
                          ? cs.onSurface
                          : cs.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: enabled
                            ? cs.onSurface.withValues(alpha: 0.55)
                            : dim,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Lucide.ChevronRight,
              size: 18,
              color: enabled
                  ? cs.onSurface.withValues(alpha: 0.35)
                  : cs.onSurface.withValues(alpha: 0.15),
            ),
          ],
        ),
      ),
    );
  }
}
