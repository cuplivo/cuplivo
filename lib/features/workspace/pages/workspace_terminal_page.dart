import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/workspace/linux_sandbox_service.dart';
import '../../../core/services/workspace/terminal_extra_keys.dart';
import '../../../core/services/workspace/workspace_terminal_coordinator.dart';
import '../../../core/services/workspace/workspace_terminal_gate.dart';
import '../../../core/services/workspace/workspace_terminal_native_bridge.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../widgets/android_workspace_terminal_view.dart';
import '../widgets/workspace_terminal_extra_keys_bar.dart';

class WorkspaceTerminalPage extends StatefulWidget {
  const WorkspaceTerminalPage({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  State<WorkspaceTerminalPage> createState() => _WorkspaceTerminalPageState();
}

class _WorkspaceTerminalPageState extends State<WorkspaceTerminalPage>
    with WidgetsBindingObserver {
  final TerminalExtraKeysController _keys = TerminalExtraKeysController();

  AndroidWorkspaceTerminalViewController? _viewController;
  WorkspaceTerminalCoordinator? _coordinator;
  WorkspaceTerminalGate? _gate;
  WorkspaceTerminalSessionState? _sessionState;
  String? _startError;
  bool _starting = false;
  bool _copyMode = false;
  final int _fontSize = 12;
  StreamSubscription<bool>? _volumeSub;

  LinuxSandboxService get _sandbox => LinuxSandboxService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _keys.addListener(_syncModifiers);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_evaluateAndMaybeStart());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _coordinator ??= context.read<WorkspaceTerminalCoordinator>();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keys.removeListener(_syncModifiers);
    _viewController?.dispose();
    _viewController = null;
    unawaited(_teardownNative());
    final coordinator = _coordinator;
    if (coordinator != null) {
      unawaited(
        coordinator.leaveTerminalPage(widget.workspaceId).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint(
            'WorkspaceTerminalPage.leaveTerminalPage: '
            '$error\n$stackTrace',
          );
        }),
      );
    }
    _volumeSub?.cancel();
    _keys.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final keepOn =
        state == AppLifecycleState.resumed &&
        _gate == WorkspaceTerminalGate.ready &&
        _sessionState?.running == true;
    unawaited(_sandbox.setKeepScreenOn(keepOn));
  }

  Future<void> _teardownNative() async {
    await _sandbox.setVolumeCtrlIntercept(false);
    await _sandbox.setKeepScreenOn(false);
  }

  Future<void> _evaluateAndMaybeStart() async {
    final wp = context.read<WorkspaceProvider>();
    final ws = wp.getById(widget.workspaceId);
    if (ws == null) {
      setState(() => _gate = WorkspaceTerminalGate.unsupported);
      return;
    }
    final host = wp.hostPathFor(ws);
    SandboxStatus status = SandboxStatus.unsupported;
    if (host != null && Platform.isAndroid) {
      try {
        status = await _sandbox.statusFor(host);
      } catch (error) {
        debugPrint('WorkspaceTerminalPage.statusFor: $error');
        status = SandboxStatus.broken;
      }
    }
    final gate = WorkspaceTerminalAdmission.evaluate(
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
      readOnly: ws.readOnly,
      status: status,
    );
    if (!mounted) return;
    setState(() {
      _gate = gate;
      _startError = null;
    });
    if (gate == WorkspaceTerminalGate.ready) await _startSession();
  }

  Future<void> _startSession() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _copyMode = false;
      _startError = null;
    });
    try {
      final l10n = AppLocalizations.of(context)!;
      final coordinator = _coordinator!;
      coordinator.updateNotificationStrings(
        WorkspaceTerminalNotificationStrings(
          channelName: l10n.workspaceTerminalNotificationChannel,
          title: l10n.workspaceTerminalNotificationTitle,
          text: l10n.workspaceTerminalNotificationText,
        ),
      );
      _keys.resetSessionModifiers();
      final state = await coordinator.ensureSession(widget.workspaceId);
      await _sandbox.setKeepScreenOn(true);
      await _volumeSub?.cancel();
      _volumeSub = _sandbox.volumeCtrlEvents().listen(
        (down) => _keys.setVolumeCtrlHeld(down),
        onError: (Object error) {
          debugPrint('WorkspaceTerminalPage.volumeCtrl: $error');
        },
      );
      await _sandbox.setVolumeCtrlIntercept(true);
      if (!mounted) return;
      setState(() {
        _sessionState = state;
        _starting = false;
      });
    } catch (error) {
      debugPrint('WorkspaceTerminalPage.start: $error');
      if (!mounted) return;
      setState(() {
        _startError = error.toString();
        _starting = false;
        _sessionState = null;
      });
    }
  }

  Future<void> _restart() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _copyMode = false;
      _startError = null;
    });
    try {
      final state = await _coordinator!.restartSession(widget.workspaceId);
      await _viewController?.attach();
      await _sandbox.setKeepScreenOn(true);
      if (!mounted) return;
      setState(() {
        _sessionState = state;
        _starting = false;
      });
    } catch (error) {
      debugPrint('WorkspaceTerminalPage.restart: $error');
      if (!mounted) return;
      setState(() {
        _startError = error.toString();
        _starting = false;
      });
    }
  }

  void _onViewControllerCreated(
    AndroidWorkspaceTerminalViewController controller,
  ) {
    _viewController?.dispose();
    _viewController = controller;
    _syncModifiers();
    unawaited(
      controller.attach().catchError((Object error) {
        _onTerminalViewError(error);
      }),
    );
  }

  void _onSessionStateChanged(WorkspaceTerminalSessionState state) {
    if (!mounted) return;
    setState(() {
      _sessionState = state;
      if (!state.running) _copyMode = false;
    });
    if (!state.running) unawaited(_sandbox.setKeepScreenOn(false));
  }

  void _onTerminalViewError(Object error) {
    debugPrint('WorkspaceTerminalPage.view: $error');
    if (mounted) setState(() => _startError = error.toString());
  }

  void _syncModifiers() {
    final controller = _viewController;
    if (controller == null) return;
    unawaited(
      controller
          .setModifiers(ctrl: _keys.ctrlActive, alt: _keys.altActive)
          .catchError((Object error) {
            debugPrint('WorkspaceTerminalPage.setModifiers: $error');
          }),
    );
  }

  void _consumeNativeModifier() {
    _keys.consumeOneShot();
  }

  void _emitExtraKey(ExtraKeyBinding key, {required bool popup}) {
    final controller = _viewController;
    if (controller == null || key.modifier != null) return;
    final text = popup ? key.popupText : key.text;
    final operation = text != null
        ? controller.sendText(
            text,
            ctrl: _keys.ctrlActive,
            alt: _keys.altActive,
          )
        : key.terminalKey == null
        ? Future<void>.value()
        : controller.sendKey(
            key.terminalKey!,
            ctrl: _keys.ctrlActive,
            alt: _keys.altActive,
          );
    _keys.consumeOneShot();
    unawaited(
      operation.catchError((Object error) {
        debugPrint('WorkspaceTerminalPage.extraKey: $error');
      }),
    );
  }

  Future<void> _copySelection() async {
    final text = await _viewController?.copySelection();
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => _copyMode = false);
  }

  String _gateMessage(AppLocalizations l10n) {
    switch (_gate) {
      case WorkspaceTerminalGate.androidOnly:
        return l10n.workspaceTerminalAndroidOnly;
      case WorkspaceTerminalGate.readOnly:
        return l10n.workspaceTerminalReadOnly;
      case WorkspaceTerminalGate.runtimeMissing:
        return l10n.workspaceSandboxRuntimeMissing;
      case WorkspaceTerminalGate.baseMissing:
        return l10n.workspaceSandboxBaseRequired;
      case WorkspaceTerminalGate.broken:
        return l10n.workspaceTerminalOpenFailed('broken');
      case WorkspaceTerminalGate.unsupported:
        return l10n.workspaceTerminalAndroidOnly;
      case WorkspaceTerminalGate.ready:
      case null:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final wp = context.watch<WorkspaceProvider>();
    final ws = wp.getById(widget.workspaceId);
    final title = ws?.displayName ?? l10n.workspaceTerminal;
    final ready =
        _gate == WorkspaceTerminalGate.ready &&
        _sessionState?.exists == true &&
        _startError == null;
    return Scaffold(
      // color-gate: ignore -- terminal canvas intentionally uses ANSI black.
      backgroundColor: ready ? const Color(0xFF000000) : null,
      appBar: AppBar(title: Text(title)),
      body: _buildBody(context, l10n, ready),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n, bool ready) {
    if (_gate == null || _starting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_startError != null) {
      return _messagePane(
        context,
        l10n.workspaceTerminalOpenFailed(_startError!),
        actionLabel: l10n.workspaceTerminalRestart,
        onAction: _restart,
      );
    }
    if (!ready) return _messagePane(context, _gateMessage(l10n));
    final exited = _sessionState?.state == WorkspaceTerminalProcessState.exited;
    return Column(
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              AndroidWorkspaceTerminalView(
                workspaceId: widget.workspaceId,
                fontSize: _fontSize,
                onControllerCreated: _onViewControllerCreated,
                onStateChanged: _onSessionStateChanged,
                onCopyModeChanged: (active) {
                  if (mounted) setState(() => _copyMode = active);
                },
                onModifierConsumed: _consumeNativeModifier,
                onError: _onTerminalViewError,
              ),
              if (exited)
                ColoredBox(
                  // color-gate: ignore -- overlay belongs to terminal canvas.
                  color: const Color(0xCC000000),
                  child: _messagePane(
                    context,
                    l10n.workspaceTerminalExited,
                    actionLabel: l10n.workspaceTerminalRestart,
                    onAction: _restart,
                    dark: true,
                  ),
                ),
              if (_copyMode && !exited)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: IosTileButton(
                    label: l10n.workspaceTerminalCopy,
                    icon: Lucide.Copy,
                    onTap: () => unawaited(_copySelection()),
                  ),
                ),
            ],
          ),
        ),
        WorkspaceTerminalExtraKeysBar(controller: _keys, onEmit: _emitExtraKey),
      ],
    );
  }

  Widget _messagePane(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    bool dark = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: dark
                    // color-gate: ignore -- text sits on ANSI black overlay.
                    ? const Color(0xFFFFFFFF)
                    : colors.onSurface,
                fontSize: 15,
                height: 1.35,
              ),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 16),
              IosTileButton(
                label: actionLabel,
                icon: Lucide.RotateCw,
                onTap: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
