import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, debugPrint, TargetPlatform;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/services/app_exit_flush.dart';
import '../l10n/app_localizations.dart';

/// Whether an OS *exit request* is really the user closing the window with
/// "minimize to tray on close" enabled.
///
/// Windows and Linux deliver the window's close as an exit request before any
/// window-manager delegate sees `WM_CLOSE`: the engine's lifecycle manager
/// consumes that message and asks the framework whether it may quit. An app
/// that only hides from [WindowListener.onWindowClose] has therefore already
/// been asked to quit by the time the window hides, and answering `exit` there
/// runs the exit-flush registry — which is how #1036 closed the LAN sync
/// listener on a window that never went away.
///
/// macOS is deliberately excluded: there the exit request *is* a terminate
/// (Cmd+Q, Dock → Quit) and the red button never reaches it (window_manager
/// intercepts that close first), so hiding here would turn Quit into a no-op.
///
/// [quitting] is the tray's own Exit item, which must always be a real quit.
bool exitRequestHidesToTray({
  required TargetPlatform platform,
  required bool showTray,
  required bool minimizeToTrayOnClose,
  required bool quitting,
}) {
  if (quitting || !showTray || !minimizeToTrayOnClose) return false;
  return platform == TargetPlatform.windows || platform == TargetPlatform.linux;
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
            onClick: (_) async => _exitApp(),
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
      return false;
    }
    try {
      await windowManager.hide();
      return true;
    } catch (error) {
      // A window that cannot be hidden must not leave the close button dead:
      // fall through to the real quit instead.
      debugPrint('desktop tray: hiding on an exit request failed: $error');
      return false;
    }
  }

  Future<void> _exitApp() async {
    if (!_isDesktop) return;
    // A close from here on is a quit: the exit request it produces must not be
    // answered as a hide.
    _quitting = true;
    try {
      // Drain pending writes before exiting. On macOS/Linux destroy()
      // routes through the engine's exit-request channel (which flushes
      // again — flush handlers are idempotent), but on Windows the
      // destroy() fallback posts WM_QUIT directly and bypasses WM_CLOSE,
      // so without this the fallback exit would skip the flush entirely.
      // The timeout keeps a stuck write queue from hanging tray exit.
      try {
        await AppExitFlush.flushAll().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      } catch (_) {}
      // Hand back what lives with the process: the LAN sync listener and its
      // ephemeral-port firewall rule. On macOS/Linux destroy() below bypasses
      // the engine's exit-request channel entirely, so this is the only place
      // that teardown is guaranteed to run.
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
        try {
          await windowManager.setPreventClose(false);
        } catch (_) {}
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
    // The other delivery path of the same intent: on macOS the red-button close
    // arrives here (the exit request never sees it), and on Windows or Linux it
    // lands here only when the window-manager delegate got the message first.
    // The intent is "the tray settings say close means hide" — [_hidesOnClose].
    // Only the message that carries it differs, which is why
    // [exitRequestHidesToTray] adds the platform check and this path does not.
    if (_quitting || !_hidesOnClose) return;
    try {
      final isPreventClose = await windowManager.isPreventClose();
      if (!isPreventClose) return;
      await windowManager.hide();
    } catch (_) {}
  }
}
