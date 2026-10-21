import 'package:flutter/foundation.dart'
    show
        kIsWeb,
        defaultTargetPlatform,
        debugPrint,
        visibleForTesting,
        TargetPlatform;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/services/app_exit_flush.dart';
import '../l10n/app_localizations.dart';

/// Whether an OS *exit request* is really the user closing the window with
/// "minimize to tray on close" enabled.
///
/// It is, on Windows: the engine's lifecycle manager registers its top-level
/// window proc delegate before any plugin registers theirs, consumes the last
/// window's `WM_CLOSE` itself, and asks the framework whether it may quit
/// (`windows_lifecycle_manager.cc`: `HandleCloseMessage` → `RequestApplicationQuit`
/// → the message is handled), re-dispatching the close only when the answer is
/// `exit`. An app that only hides from [WindowListener.onWindowClose] has
/// therefore already been asked to quit by the time the window hides, and
/// answering `exit` there also runs the exit-flush registry — which is how #1036
/// closed the LAN sync listener on a window that never went away.
///
/// The other two desktops answer "no" for their own reasons:
///
/// - **Linux** never delivers the close this way while close-to-tray is on.
///   `window_manager` installs its own `delete-event` handler whose return value
///   is `preventClose` (`window_manager 0.5.2`, `linux/window_manager_plugin.cc`,
///   `on_window_close`), and it is connected before the engine's handler — the
///   engine attaches its own at realize (`fl_view.cc`'s `realize_cb`), which runs
///   after plugin registration. A handled delete-event stops the emission, so
///   the engine's `fl_engine_request_app_exit` never runs.
///   [WindowListener.onWindowClose] is Linux's hide path; the exit request there
///   only arrives when `preventClose` is already false, which is exactly when
///   this returns false.
/// - **macOS**'s exit request *is* a terminate (Cmd+Q, Dock → Quit) and the red
///   button never reaches it (window_manager intercepts that close first), so
///   hiding here would turn Quit into a no-op.
///
/// A future plugin or embedder that stops intercepting the close on Linux would
/// make that platform belong here; today it does not, and a platform list wider
/// than the evidence is a path no test can reach.
///
/// [quitting] is the tray's own Exit item, which must always be a real quit.
bool exitRequestHidesToTray({
  required TargetPlatform platform,
  required bool showTray,
  required bool minimizeToTrayOnClose,
  required bool quitting,
}) {
  if (quitting || !showTray || !minimizeToTrayOnClose) return false;
  return platform == TargetPlatform.windows;
}

/// Desktop tray + window close behaviour controller.
///
/// - Manages system tray icon visibility and context menu
/// - Implements "minimize to tray on close" when enabled in settings
class DesktopTrayController with TrayListener, WindowListener {
  DesktopTrayController._();
  static final DesktopTrayController instance = DesktopTrayController._();

  bool _initialized = false;
  bool _isDesktop = false;
  bool _trayVisible = false;
  bool _showTraySetting = false;
  bool _minimizeToTrayOnClose = false;
  String _localeKey = '';
  bool _contextMenuOpen = false;

  /// Set by the tray's Exit item for the close it is about to request. From that
  /// point a close is a quit, never a hide.
  bool _quitting = false;

  /// Whether a close request should hide the window rather than quit it.
  bool get _hidesOnClose =>
      _isDesktop && _showTraySetting && _minimizeToTrayOnClose;

  /// Returns the controller to its pre-initialization state.
  ///
  /// This class is a process singleton, so a test that drives the close paths
  /// has to start from a known state; the tray and window listeners stay
  /// registered because registering them twice would double every event.
  @visibleForTesting
  void debugReset() {
    _isDesktop = false;
    _trayVisible = false;
    _showTraySetting = false;
    _minimizeToTrayOnClose = false;
    _localeKey = '';
    _contextMenuOpen = false;
    _quitting = false;
  }

  /// Sync tray state from settings & current localization.
  /// Safe to call multiple times; initialization is performed lazily.
  Future<void> syncFromSettings(
    AppLocalizations l10n, {
    required bool showTray,
    required bool minimizeToTrayOnClose,
  }) async {
    if (kIsWeb) return;
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (!isDesktop) return;
    _isDesktop = true;

    if (!_initialized) {
      try {
        await windowManager.ensureInitialized();
      } catch (_) {}
      try {
        trayManager.addListener(this);
      } catch (_) {}
      try {
        windowManager.addListener(this);
      } catch (_) {}
      _initialized = true;
    }

    // Persist latest settings (enforce basic invariant in controller as well).
    _showTraySetting = showTray;
    _minimizeToTrayOnClose = showTray && minimizeToTrayOnClose;

    // Whether to intercept window close.
    final shouldPreventClose = _showTraySetting && _minimizeToTrayOnClose;
    try {
      await windowManager.setPreventClose(shouldPreventClose);
    } catch (_) {}

    // Handle tray icon visibility + localized menu.
    final newLocaleKey = l10n.localeName;
    final localeChanged = newLocaleKey != _localeKey;
    _localeKey = newLocaleKey;

    if (_showTraySetting) {
      if (!_trayVisible || localeChanged) {
        await _ensureTrayIconAndMenu(l10n);
        _trayVisible = true;
      }
    } else {
      if (_trayVisible) {
        try {
          await trayManager.destroy();
        } catch (_) {}
        _trayVisible = false;
      }
    }
  }

  Future<void> _ensureTrayIconAndMenu(AppLocalizations l10n) async {
    if (!_isDesktop) return;

    // Use platform-specific tray icons (mirrors Gopeed's approach):
    // - Windows: multi-size ICO for crisp scaling
    // - macOS: template PNG so the system can adapt to light/dark menu bar
    // - Linux/others: regular PNG asset
    final platform = defaultTargetPlatform;
    try {
      if (platform == TargetPlatform.windows) {
        await trayManager.setIcon('assets/app_icon.ico');
      } else if (platform == TargetPlatform.macOS) {
        await trayManager.setIcon('assets/icon_mac.png', isTemplate: true);
      } else {
        await trayManager.setIcon('assets/app_icon_about.png');
      }
    } catch (_) {}

    // Some Linux environments do not support tooltip; keep the call
    // consistent with Gopeed and skip it there.
    if (platform != TargetPlatform.linux) {
      try {
        await trayManager.setToolTip('Cuplivo');
      } catch (_) {}
    }
    try {
      final menu = Menu(
        items: [
          MenuItem(
            label: l10n.desktopTrayMenuShowWindow,
            onClick: (_) async => _showWindow(),
          ),
          MenuItem.separator(),
          MenuItem(
            label: l10n.desktopTrayMenuExit,
            onClick: (_) async => exitApp(),
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (_) {}
  }

  Future<void> _showWindow() async {
    if (!_isDesktop) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  /// Answers an OS exit request that this device treats as "hide to the tray".
  ///
  /// Returns true when the window was hidden and the caller must answer the
  /// request as **cancel** — the app keeps running, and so does its LAN sync
  /// listener. False means a real quit is being asked for, and the caller owns
  /// the flush + shutdown.
  Future<bool> hideForExitRequest() async {
    if (!_isDesktop ||
        !exitRequestHidesToTray(
          platform: defaultTargetPlatform,
          showTray: _showTraySetting,
          minimizeToTrayOnClose: _minimizeToTrayOnClose,
          quitting: _quitting,
        )) {
      await _allowEngineExit();
      return false;
    }
    try {
      await windowManager.hide();
      return true;
    } catch (error) {
      // A window that cannot be hidden must not leave the close button dead:
      // fall through to the real quit instead — and let that quit land (see
      // [_allowEngineExit]): answering `exit` while `preventClose` is still set
      // would have window_manager swallow the close the engine re-dispatches.
      debugPrint('desktop tray: hiding on an exit request failed: $error');
      await _allowEngineExit();
      return false;
    }
  }

  /// Clears the close-to-tray gate so a close the caller is about to allow
  /// actually closes the window.
  ///
  /// The engine answers an `exit` decision by re-dispatching the OS close; with
  /// `preventClose` still set, window_manager consumes that message, so the
  /// process would stay up with the app's queues already flushed and its
  /// shutdown already run. Both real-quit paths (the tray's Exit item, and an
  /// exit request this controller answered as a quit) go through here.
  Future<void> _allowEngineExit() async {
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
  }

  /// Quits the app from the tray's Exit item.
  ///
  /// A close from here on is a quit, not a hide: the exit request this close
  /// produces must be answered with `exit`, so the quitting flag is set first
  /// and the close-to-tray gate is cleared before the window is closed. Writes
  /// are drained and process-owned resources handed back here rather than left
  /// to the engine's exit-request channel — see the two comments below for why
  /// that cannot be assumed on every platform.
  Future<void> exitApp() async {
    if (!_isDesktop) return;
    // A close from here on is a quit: the exit request it produces must not be
    // answered as a hide.
    _quitting = true;
    try {
      // Drain pending writes before exiting. The flush registry is idempotent,
      // and a platform whose close comes back through the engine's exit request
      // (macOS terminates; Linux clears `preventClose` and closes, which emits
      // `delete-event`) simply runs it a second time. Windows is the platform
      // that needs it here: its `destroy()` fallback posts WM_QUIT and bypasses
      // WM_CLOSE entirely. The timeout keeps a stuck write queue from hanging
      // tray exit.
      try {
        await AppExitFlush.flushAll().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      } catch (_) {}
      // Hand back what lives with the process: the LAN sync listener and its
      // ephemeral-port firewall rule. Run here instead of relying on the
      // engine's exit-request channel: the Windows destroy() fallback bypasses
      // that channel, and this path should not depend on how each platform's
      // close is routed. The handlers are idempotent, so a platform whose close
      // does come back through the channel only runs them twice.
      try {
        await AppShutdown.runAll().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      } catch (_) {}
      // On Windows we may have `preventClose` enabled to support
      // "close to tray". Temporarily disable it and send a normal
      // close so the window can exit immediately without being
      // intercepted by the minimize‑to‑tray logic.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await _allowEngineExit();
        try {
          await windowManager.close();
          return;
        } catch (_) {}
      }

      // Other desktop platforms (and Windows fallback): destroy the
      // window so the process exits cleanly.
      await windowManager.destroy();
    } catch (_) {
      // The window refused to go: leave the app usable rather than half-quit,
      // where every later close would be treated as a quit.
      _quitting = false;
    }
  }

  // ===== TrayListener =====

  @override
  void onTrayIconMouseDown() {
    // Left‑click: bring main window to front.
    if (!_isDesktop) return;
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Right‑click: 弹出托盘菜单。
    // 使用内部标记防止在一次交互周期内重复弹出，
    // 否则在某些 Windows 环境下会看到第二个偏移的菜单。
    if (_contextMenuOpen) {
      return;
    }
    _contextMenuOpen = true;
    try {
      // Windows 环境下建议在弹出菜单前尝试聚焦窗口，
      // 以避免部分环境中菜单不会在点击其他地方时自动关闭。
      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await windowManager.focus();
        } catch (_) {}
      }
      await trayManager.popUpContextMenu();
    } catch (_) {}
    // 无论是点击菜单项还是点击其他地方关闭菜单，
    // popUpContextMenu 都会在菜单关闭后返回，这里统一重置标记。
    _contextMenuOpen = false;
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // 任一菜单项被点击视为一次菜单交互结束，
    // 额外保险地解除防抖标记（即使 Future 尚未完成）。
    _contextMenuOpen = false;
  }

  // ===== WindowListener =====

  @override
  void onWindowClose() async {
    if (!_isDesktop) return;
    // Two questions, deliberately kept apart. [_hidesOnClose] is "the tray
    // settings say a close means hide" — still true for a close that is a quit,
    // because quitting does not change the settings; [_quitting] is "this close
    // is a quit", set by the tray's Exit item. Both are read because the close
    // that carries the settings' intent and the close that must be honoured as
    // a quit are the same OS message.
    //
    // Where the two paths meet: on Linux and macOS a close arrives here and
    // nowhere else (window_manager's own `delete-event` handler consumes it on
    // Linux; macOS' red button never reaches the exit request), so this is the
    // hide. On Windows a close-to-tray close is answered by the exit request
    // before window_manager sees it, so the Windows closes that do reach this
    // handler are already quits — and [_quitting] is what makes them quits.
    if (_quitting || !_hidesOnClose) return;
    try {
      final isPreventClose = await windowManager.isPreventClose();
      if (!isPreventClose) return;
      await windowManager.hide();
    } catch (_) {}
  }
}
