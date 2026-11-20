import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:terminal_view/terminal_view.dart';

import 'package:Cuplivo/features/workspace/terminal/terminal_session_manager.dart';
import 'package:Cuplivo/features/workspace/terminal/widgets/system_terminal_card.dart';
import 'package:Cuplivo/features/workspace/terminal/widgets/terminal_key_bar.dart';
import 'package:Cuplivo/features/workspace/terminal/widgets/terminal_tab_strip.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// The reusable body of the in-app terminal: tab strip, emulator, key bar.
///
/// Extracted from `TerminalPage` so a second host (the DeepSeek Harness right
/// rail's remote terminal) renders the exact same surface instead of forking
/// the emulator, key bar and copy behavior. The page keeps the Scaffold, AppBar
/// and page-level actions; everything from the tab strip down lives here, and
/// the surface owns the per-session `TerminalController`s and clipboard copy
/// listeners because those follow the emulator, not the page.
class TerminalSurface extends StatefulWidget {
  const TerminalSurface({
    super.key,
    required this.manager,
    required this.session,
    required this.supportsPty,
    required this.hostDir,
    required this.onOpenUrl,
    this.showTabStrip = true,
    this.pinchAreaKey,
    this.viewKey,
    this.onSelectSession,
    this.onAddSession,
    this.onRenameSession,
    this.onCloseSession,
    this.onOpenSystemTerminal,
  });

  /// Key on the gesture/pinch area around the emulator.
  static const Key surfaceKey = ValueKey<String>('terminal-surface');

  final TerminalSessionManager manager;

  /// Active session; null renders the honest unavailable/system card state.
  final TerminalSession? session;

  final bool supportsPty;

  /// Host directory shown by [SystemTerminalCard] when there is no PTY.
  final String hostDir;

  /// Opens a URL requested by the shell (OSC 1337 links, `kelivo:` links).
  final Future<void> Function(TerminalSession session, Uri uri) onOpenUrl;

  /// Whether the tab strip is part of this host (full page) or not (inline
  /// rail panel with a single session).
  final bool showTabStrip;

  final Key? pinchAreaKey;
  final Key? viewKey;

  final ValueChanged<String>? onSelectSession;
  final VoidCallback? onAddSession;
  final ValueChanged<String>? onRenameSession;
  final ValueChanged<String>? onCloseSession;
  final VoidCallback? onOpenSystemTerminal;

  @override
  State<TerminalSurface> createState() => _TerminalSurfaceState();
}

class _TerminalSurfaceState extends State<TerminalSurface> {
  final Map<String, TerminalController> _controllers =
      <String, TerminalController>{};
  final Map<String, StreamSubscription<Uri>> _urlSubs =
      <String, StreamSubscription<Uri>>{};
  final Map<String, VoidCallback> _selectionListeners =
      <String, VoidCallback>{};
  Timer? _copyDebounce;
  double _pinchBaseFont = kTerminalDefaultFontSize;

  @override
  void initState() {
    super.initState();
    _syncSessionBindings();
  }

  @override
  void didUpdateWidget(TerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager)) {
      _disposeBindings();
    }
    _syncSessionBindings();
  }

  @override
  void dispose() {
    _copyDebounce?.cancel();
    _disposeBindings();
    super.dispose();
  }

  void _disposeBindings() {
    for (final sub in _urlSubs.values) {
      unawaited(sub.cancel());
    }
    _urlSubs.clear();
    for (final entry in _selectionListeners.entries) {
      _controllers[entry.key]?.removeListener(entry.value);
    }
    _selectionListeners.clear();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }

  void _syncSessionBindings() {
    final manager = widget.manager;
    final sessions = manager.sessions;
    final ids = sessions.map((session) => session.id).toSet();
    for (final id in List<String>.from(_urlSubs.keys)) {
      if (!ids.contains(id)) {
        unawaited(_urlSubs.remove(id)?.cancel());
      }
    }
    for (final id in List<String>.from(_controllers.keys)) {
      if (!ids.contains(id)) {
        final listener = _selectionListeners.remove(id);
        final controller = _controllers.remove(id);
        if (listener != null) controller?.removeListener(listener);
        controller?.dispose();
      }
    }
    for (final session in sessions) {
      _controllers.putIfAbsent(session.id, () {
        final controller = TerminalController();
        void onSelection() =>
            _copySelection(session, controller, debounce: true);
        _selectionListeners[session.id] = onSelection;
        controller.addListener(onSelection);
        return controller;
      });
      _urlSubs.putIfAbsent(
        session.id,
        () => session.openUrlRequests.listen((uri) {
          if (!mounted) return;
          unawaited(widget.onOpenUrl(session, uri));
        }),
      );
    }
  }

  void _copySelection(
    TerminalSession session,
    TerminalController controller, {
    bool debounce = false,
  }) {
    void copy() {
      final range = controller.selection;
      if (range == null) return;
      final text = session.terminal.buffer.getText(range);
      if (text.trim().isEmpty) return;
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    }

    if (!debounce) {
      copy();
      return;
    }
    _copyDebounce?.cancel();
    _copyDebounce = Timer(const Duration(milliseconds: 350), copy);
  }

  Future<void> _paste(TerminalSession session) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    session.pasteText(text);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final manager = widget.manager;
    final showTabs =
        widget.showTabStrip &&
        widget.supportsPty &&
        widget.onSelectSession != null &&
        widget.onAddSession != null &&
        widget.onRenameSession != null &&
        widget.onCloseSession != null;
    return Column(
      children: [
        if (showTabs)
          TerminalTabStrip(
            sessions: manager.sessions,
            activeId: session?.id,
            onSelect: widget.onSelectSession!,
            onAdd: widget.onAddSession!,
            onRename: widget.onRenameSession!,
            onClose: widget.onCloseSession!,
          ),
        if (session?.readOnly == true) const _ReadOnlyBanner(),
        Expanded(
          child: !widget.supportsPty || session == null
              ? SystemTerminalCard(
                  hostDir: widget.hostDir,
                  onOpen: widget.onOpenSystemTerminal,
                )
              : _buildEmulator(session),
        ),
        if (widget.supportsPty && session != null && !session.readOnly)
          TerminalKeyBar(
            session: session,
            onCopy: () {
              final controller = _controllers[session.id];
              if (controller != null) {
                _copySelection(session, controller);
              }
            },
            onPaste: () => unawaited(_paste(session)),
          ),
      ],
    );
  }

  Widget _buildEmulator(TerminalSession session) {
    final controller = _controllers[session.id];
    return KeyedSubtree(
      key: widget.pinchAreaKey ?? TerminalSurface.surfaceKey,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onScaleStart: (_) => _pinchBaseFont = session.fontSize,
            onScaleUpdate: (details) {
              if (details.pointerCount < 2) return;
              widget.manager.setFontSize(
                session.id,
                _pinchBaseFont * details.scale,
              );
            },
            child: TerminalView(
              key: widget.viewKey,
              session.terminal,
              controller: controller,
              autofocus: true,
              deleteDetection: true,
              backgroundOpacity: 0,
              theme: buildTerminalViewTheme(Theme.of(context).colorScheme),
              textStyle: TerminalStyle(fontSize: session.fontSize),
              keyboardAppearance: Theme.of(context).brightness,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when the Host's snapshot reported `writable: false`: the surface
/// renders output but hides the key bar and drops input.
class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner();

  static const Key bannerKey = ValueKey<String>('dsh-terminal-readonly');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: bannerKey,
      width: double.infinity,
      color: context.appColors.surfaceFill,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Lucide.Lock,
            size: 13,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 6),
          Text(
            l10n.workspaceMountReadOnly,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
