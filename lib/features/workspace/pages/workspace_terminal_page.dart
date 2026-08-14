import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/workspace/linux_sandbox_service.dart';
import '../../../core/services/workspace/terminal_extra_keys.dart';
import '../../../core/services/workspace/workspace_terminal_gate.dart';
import '../../../core/services/workspace/workspace_terminal_pty.dart'
    deferred as terminal_pty;
import '../../../core/services/workspace/workspace_terminal_session.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../widgets/workspace_terminal_extra_keys_bar.dart';

class WorkspaceTerminalPage extends StatefulWidget {
  const WorkspaceTerminalPage({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  State<WorkspaceTerminalPage> createState() => _WorkspaceTerminalPageState();
}

class _WorkspaceTerminalPageState extends State<WorkspaceTerminalPage>
    with WidgetsBindingObserver {
  static const _termuxTheme = TerminalTheme(
    cursor: Color(0xFFFFFFFF),
    selection: Color(0x80FFFFFF),
    foreground: Color(0xFFFFFFFF),
    background: Color(0xFF000000),
    black: Color(0xFF000000),
    red: Color(0xFFCD0000),
    green: Color(0xFF00CD00),
    yellow: Color(0xFFCDCD00),
    blue: Color(0xFF6495ED),
    magenta: Color(0xFFCD00CD),
    cyan: Color(0xFF00CDCD),
    white: Color(0xFFE5E5E5),
    brightBlack: Color(0xFF7F7F7F),
    brightRed: Color(0xFFFF0000),
    brightGreen: Color(0xFF00FF00),
    brightYellow: Color(0xFFFFFF00),
    brightBlue: Color(0xFF5C5CFF),
    brightMagenta: Color(0xFFFF00FF),
    brightCyan: Color(0xFF00FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFFF00),
    searchHitBackgroundCurrent: Color(0xFFFF8C00),
    searchHitForeground: Color(0xFF000000),
  );

  final TerminalExtraKeysController _keys = TerminalExtraKeysController();
  final TerminalController _termController = TerminalController();
  WorkspaceTerminalController? _sessionController;

  Terminal? _terminal;
  WorkspaceTerminalGate? _gate;
  String? _startError;
  bool _exited = false;
  bool _starting = false;
  double _fontSize = 12;
  double _pinchBase = 12;
  StreamSubscription<bool>? _volumeSub;
  StreamSubscription<List<int>>? _outputSub;

  LinuxSandboxService get _sandbox => LinuxSandboxService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_evaluateAndMaybeStart());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_teardownNative());
    unawaited(_sessionController?.dispose());
    _volumeSub?.cancel();
    _outputSub?.cancel();
    _keys.dispose();
    _termController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final keepOn =
        state == AppLifecycleState.resumed &&
        _gate == WorkspaceTerminalGate.ready &&
        !_exited;
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
    if (host != null && (Platform.isAndroid || Platform.isIOS)) {
      try {
        status = await _sandbox.statusFor(host);
      } catch (e) {
        debugPrint('WorkspaceTerminalPage.statusFor: $e');
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
    if (gate == WorkspaceTerminalGate.ready && host != null) {
      await _startSession(host);
    }
  }

  Future<void> _startSession(String hostPath) async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _exited = false;
      _startError = null;
    });
    try {
      await terminal_pty.loadLibrary();
      final sessionController = _sessionController ??=
          WorkspaceTerminalController(
            session: terminal_pty.WorkspaceTerminalSession(),
          );
      await _outputSub?.cancel();
      _keys.resetSessionModifiers();
      await sessionController.stop();
      final spec = await _sandbox.ptyLaunchSpec(hostPath);
      if (!mounted || sessionController.closed) return;
      final terminal = Terminal(
        maxLines: 5000,
        platform: TerminalTargetPlatform.android,
        onOutput: _handleTerminalOutput,
        onResize: (w, h, pw, ph) {
          sessionController.resize(rows: h, columns: w);
        },
      );
      await sessionController.start(spec, rows: 24, columns: 80);
      if (!mounted || sessionController.closed) {
        await sessionController.stop();
        return;
      }
      _outputSub = sessionController.output.listen(
        (chunk) {
          terminal.write(utf8.decode(chunk, allowMalformed: true));
        },
        onError: (Object e) {
          debugPrint('WorkspaceTerminalPage.output: $e');
        },
      );
      unawaited(
        sessionController.exitCode.then((code) {
          debugPrint('WorkspaceTerminalPage.exit: $code');
          if (!mounted) return;
          setState(() => _exited = true);
          unawaited(_sandbox.setKeepScreenOn(false));
        }),
      );
      await _sandbox.setKeepScreenOn(true);
      await _volumeSub?.cancel();
      _volumeSub = _sandbox.volumeCtrlEvents().listen(
        (down) {
          _keys.setVolumeCtrlHeld(down);
        },
        onError: (Object e) {
          debugPrint('WorkspaceTerminalPage.volumeCtrl: $e');
        },
      );
      await _sandbox.setVolumeCtrlIntercept(true);
      if (!mounted || sessionController.closed) {
        await sessionController.stop();
        await _teardownNative();
        return;
      }
      setState(() {
        _terminal = terminal;
        _starting = false;
        _exited = false;
      });
    } catch (e) {
      debugPrint('WorkspaceTerminalPage.start: $e');
      if (!mounted) return;
      setState(() {
        _startError = e.toString();
        _starting = false;
        _terminal = null;
      });
    }
  }

  void _handleTerminalOutput(String data) {
    var out = data;
    if (_keys.ctrlActive) {
      out = TerminalExtraKeys.applyCtrl(data);
      _keys.consumeOneShot();
    } else if (_keys.altActive) {
      out = '\x1b$data';
      _keys.consumeOneShot();
    }
    _sessionController?.write(utf8.encode(out));
  }

  Future<void> _restart() async {
    final wp = context.read<WorkspaceProvider>();
    final ws = wp.getById(widget.workspaceId);
    final host = ws == null ? null : wp.hostPathFor(ws);
    if (host == null) return;
    await _startSession(host);
  }

  void _emitExtraKey(ExtraKeyBinding key, {required bool popup}) {
    final terminal = _terminal;
    if (terminal == null) return;
    if (key.modifier != null) return;
    final text = popup ? key.popupText : key.text;
    if (text != null) {
      if (_keys.ctrlActive || _keys.altActive) {
        terminal.charInput(
          text.codeUnitAt(0),
          ctrl: _keys.ctrlActive,
          alt: _keys.altActive,
        );
        _keys.consumeOneShot();
      } else {
        terminal.textInput(text);
      }
      return;
    }
    final mapped = _mapTerminalKey(key.terminalKey);
    if (mapped == null) return;
    terminal.keyInput(mapped, ctrl: _keys.ctrlActive, alt: _keys.altActive);
    _keys.consumeOneShot();
  }

  TerminalKey? _mapTerminalKey(String? name) {
    switch (name) {
      case 'escape':
        return TerminalKey.escape;
      case 'tab':
        return TerminalKey.tab;
      case 'home':
        return TerminalKey.home;
      case 'end':
        return TerminalKey.end;
      case 'arrowUp':
        return TerminalKey.arrowUp;
      case 'arrowDown':
        return TerminalKey.arrowDown;
      case 'arrowLeft':
        return TerminalKey.arrowLeft;
      case 'arrowRight':
        return TerminalKey.arrowRight;
      case 'pageUp':
        return TerminalKey.pageUp;
      case 'pageDown':
        return TerminalKey.pageDown;
      default:
        return null;
    }
  }

  Future<void> _copySelection() async {
    final selection = _termController.selection;
    final terminal = _terminal;
    if (selection == null || terminal == null) return;
    final text = terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _termController.clearSelection();
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
        _terminal != null &&
        _startError == null;
    return Scaffold(
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
    if (!ready) {
      return _messagePane(context, _gateMessage(l10n));
    }
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              RawGestureDetector(
                gestures: {
                  ScaleGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        ScaleGestureRecognizer
                      >(ScaleGestureRecognizer.new, (instance) {
                        instance.onStart = (details) {
                          _pinchBase = _fontSize;
                        };
                        instance.onUpdate = (details) {
                          if (details.pointerCount < 2) return;
                          final next = (_pinchBase * details.scale).clamp(
                            8.0,
                            32.0,
                          );
                          final snapped = (next / 2).round() * 2.0;
                          if (snapped != _fontSize) {
                            setState(() => _fontSize = snapped);
                          }
                        };
                      }),
                },
                child: TerminalView(
                  _terminal!,
                  controller: _termController,
                  theme: _termuxTheme,
                  textStyle: TerminalStyle(fontSize: _fontSize),
                  autofocus: true,
                  backgroundOpacity: 1,
                  keyboardAppearance: Brightness.dark,
                  deleteDetection: true,
                ),
              ),
              if (_exited)
                ColoredBox(
                  color: const Color(0xCC000000),
                  child: _messagePane(
                    context,
                    l10n.workspaceTerminalExited,
                    actionLabel: l10n.workspaceTerminalRestart,
                    onAction: _restart,
                    dark: true,
                  ),
                ),
              ListenableBuilder(
                listenable: _termController,
                builder: (context, _) {
                  if (_termController.selection == null || _exited) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    right: 12,
                    bottom: 12,
                    child: IosTileButton(
                      label: l10n.workspaceTerminalCopy,
                      icon: Lucide.Copy,
                      onTap: () => unawaited(_copySelection()),
                    ),
                  );
                },
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
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: dark ? const Color(0xFFFFFFFF) : cs.onSurface,
                fontSize: 15,
                height: 1.35,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
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
