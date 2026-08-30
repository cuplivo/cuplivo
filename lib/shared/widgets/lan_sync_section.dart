import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../core/database/business_preferences.dart';
import '../../core/models/backup.dart';
import '../../core/services/backup/data_sync.dart';
import '../../core/services/backup/restore_refresher.dart';
import '../../core/services/chat/chat_service.dart';
import '../../core/services/sync/lan_sync_client.dart';
import '../../core/services/sync/lan_sync_models.dart';
import '../../core/services/sync/lan_sync_server.dart';
import '../../core/services/sync/windows_firewall.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/app_semantic_colors.dart';
import '../../utils/format.dart';
import '../dialogs/restart_required_dialog.dart';
import 'ios_form_text_field.dart';
import 'ios_tactile.dart';
import 'ios_tile_button.dart';
import 'loading_dialog_card.dart' show buildRestoreProgress;

/// Shared restore-progress content for the sync dialog/sheet mask: stage
/// text + determinate bar (indeterminate stages render a busy bar).
///
/// [buildRestoreProgress] lives in [loading_dialog_card.dart] (single source
/// shared with the backup import overlay) and is imported from there.
export 'loading_dialog_card.dart' show buildRestoreProgress;

/// Shared LAN Sync section widget for backup settings.
///
/// Adapts layout for mobile vs desktop based on [Platform.isAndroid]/[isIOS].
/// Both layouts share the same sync logic via [LanSyncServer] and [LanSyncClient].
class LanSyncSection extends StatefulWidget {
  const LanSyncSection({super.key, this.lanSyncHttpClient, this.dataSync});

  /// HTTP client for the LAN sync client. Mirrors the injected client on
  /// [LanSyncClient]: keeps LAN traffic off the environment proxy, and lets
  /// widget tests stub the wire with a `MockClient`. Null = production
  /// default (direct, proxy-free).
  final http.Client? lanSyncHttpClient;

  /// Optional [DataSync] override. Lets widget tests inject a fake whose
  /// `buildFileManifest` needs no real filesystem (real file I/O cannot
  /// complete inside `testWidgets`'s fake-async zone). Null = production
  /// default built from the ambient [ChatService].
  final DataSync? dataSync;

  @override
  State<LanSyncSection> createState() => _LanSyncSectionState();
}

/// Localized status line for the server dialog.
String serverPhaseText(LanSyncPhase phase, AppLocalizations l10n) {
  switch (phase) {
    case LanSyncPhase.waiting:
      return l10n.lanSyncServerWaiting;
    case LanSyncPhase.planSent:
      return l10n.lanSyncServerPlanSent;
    case LanSyncPhase.exchanging:
      return l10n.lanSyncServerExchanging;
    case LanSyncPhase.done:
      return l10n.lanSyncServerDone;
    case LanSyncPhase.idle:
    case LanSyncPhase.planReceived:
    case LanSyncPhase.noData:
      return '';
  }
}

/// Localized status line for the client dialog/sheet.
String clientPhaseText(LanSyncPhase phase, AppLocalizations l10n) {
  switch (phase) {
    case LanSyncPhase.waiting:
      return l10n.lanSyncClientConnecting;
    case LanSyncPhase.planReceived:
      return l10n.lanSyncClientPlanReceived;
    case LanSyncPhase.exchanging:
      return l10n.lanSyncClientExchanging;
    case LanSyncPhase.noData:
      // The plan summary below already says "No changes to sync."
      return '';
    case LanSyncPhase.done:
      return l10n.lanSyncClientDone;
    case LanSyncPhase.idle:
    case LanSyncPhase.planSent:
      return '';
  }
}

class _LanSyncSectionState extends State<LanSyncSection> {
  late final LanSyncServer _server;
  late final LanSyncClient _client;
  late final DataSync _dataSync;

  // Client-side form controllers
  final _hostController = TextEditingController(text: '192.168.');
  final _portController = TextEditingController(text: '9527');
  final _pinController = TextEditingController();

  /// The initiator's chosen conflict direction for this session (issue #615).
  /// Null = auto (current merge behavior). Session-only, never persisted.
  SyncPriority? _priorityChoice;

  /// The zip received for merge-restore, kept so a failed restore can be
  /// cleaned up when the section is disposed (the temp dir must not
  /// accumulate large sync payloads).
  File? _receivedZipFile;

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void initState() {
    super.initState();
    final chatService = context.read<ChatService>();
    _dataSync =
        widget.dataSync ??
        DataSync(
          chatService: chatService,
          preferences: context.read<BusinessPreferences>(),
        );
    _server = LanSyncServer(chatService: chatService, dataSync: _dataSync);
    _client = LanSyncClient(
      chatService: chatService,
      dataSync: _dataSync,
      httpClient: widget.lanSyncHttpClient,
    );
    _server.addListener(_onChanged);
    _client.addListener(_onChanged);

    // When a zip is received (either side), restore it and prompt restart.
    _server.onZipReceived = (zip) => _restoreAndRestart(zip, isServer: true);
    _client.onZipReceived = (zip) => _restoreAndRestart(zip, isServer: false);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _server.removeListener(_onChanged);
    _client.removeListener(_onChanged);
    _hostController.dispose();
    _portController.dispose();
    _pinController.dispose();
    _server.stop();
    _client.close();
    // Clean up a received-but-not-restored sync zip (e.g. after a failed
    // restore) so the temp dir does not accumulate large payloads.
    final received = _receivedZipFile;
    if (received != null) {
      unawaited(() async {
        try {
          if (await received.exists()) {
            await received.delete();
          }
        } catch (_) {
          // Best-effort: a still-locked file (e.g. open handle on Windows)
          // must not surface as an unhandled async error during teardown.
        }
      }());
    }
    super.dispose();
  }

  Future<void> _restoreAndRestart(
    File zipFile, {
    required bool isServer,
  }) async {
    if (!mounted) return;
    // The sync dialog/sheet stays mounted throughout the write window — its
    // non-dismissible barrier IS the full-screen mask. Never pop it here.
    // A second sync session within this section's lifetime (e.g. after a
    // failed restore) would otherwise leak the previous session's zip.
    final previous = _receivedZipFile;
    if (previous != null && previous.path != zipFile.path) {
      unawaited(() async {
        try {
          if (await previous.exists()) {
            await previous.delete();
          }
        } catch (_) {
          // Best-effort: a still-locked file must not surface as an
          // unhandled async error.
        }
      }());
    }
    _receivedZipFile = zipFile;
    // Reset the notify throttle so the first progress frame of this session
    // always renders (a stale stage/timestamp could otherwise swallow it).
    _lastRestoreNotify = DateTime.fromMillisecondsSinceEpoch(0);
    _lastRestoreNotifyStage = null;
    _setRestoreProgress(const RestoreProgress(stage: RestoreStage.extracting));
    try {
      // Derive the role-relative conflict direction for THIS device (issue
      // #615): the wire bit is absolute (initiator wins / server wins); this
      // device is the initiator when it is not the server side of the sync.
      // The initiator only applies a direction the server echoed back —
      // effectivePriority is null (auto) on mixed-version sessions.
      final priority = isServer
          ? _server.initiatorPriority
          : _client.effectivePriority;
      await _dataSync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(),
        mode: RestoreMode.merge,
        precedence: resolveSyncPrecedence(priority, isInitiator: !isServer),
        onProgress: _setRestoreProgress,
      );
      if (!mounted) return;
      // Keep the in-memory providers consistent with the merged disk state
      // while the restart prompt is up (and defensively if it is dismissed).
      await refreshProvidersAfterRestore(context);
      if (!mounted) return;
      // The write window is over. The non-dismissible restart dialog takes
      // over the screen from the sync dialog/sheet below.
      _setRestoreProgress(null);
      await showRestartRequiredDialog(context);
    } catch (e) {
      if (!mounted) return;
      // Close-with-error: the peer already received its zip, so the sync
      // simply did not complete on this side. Never rethrow — a restore
      // failure must not surface as a transport error to the exchange layer.
      final message = e.toString();
      _server.setRestoreError(message);
      _client.setRestoreError(message);
    }
  }

  /// Mirrors the restore progress onto both notifiers so whichever dialog or
  /// sheet is mounted rebuilds its mask content. Null clears the mask.
  ///
  /// Throttled to ~100 ms: the restore loop reports per file, and thousands
  /// of rebuilds per second buy nothing on an I/O-bound write. Stage changes,
  /// indeterminate stages, the final step and the null clear always pass.
  void _setRestoreProgress(RestoreProgress? progress) {
    if (progress != null) {
      final now = DateTime.now();
      final stageChanged = progress.stage != _lastRestoreNotifyStage;
      final indeterminate = progress.fraction == null;
      final finalStep = (progress.fraction ?? 0) >= 1.0;
      final withinThrottle =
          now.difference(_lastRestoreNotify) < _restoreNotifyThrottle;
      if (!stageChanged && !indeterminate && !finalStep && withinThrottle) {
        return;
      }
      _lastRestoreNotify = now;
    }
    _lastRestoreNotifyStage = progress?.stage;
    _server.setRestoreProgress(progress);
    _client.setRestoreProgress(progress);
  }

  static const Duration _restoreNotifyThrottle = Duration(milliseconds: 100);
  DateTime _lastRestoreNotify = DateTime.fromMillisecondsSinceEpoch(0);
  RestoreStage? _lastRestoreNotifyStage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isDesktop) {
      return _buildDesktop(context, l10n, cs, isDark);
    }
    return _buildMobile(context, l10n, cs, isDark);
  }

  // ===== Desktop layout =====

  Widget _buildDesktop(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
    bool isDark,
  ) {
    return _desktopCard(
      isDark,
      cs,
      children: [
        _desktopHeader(l10n.lanSyncSectionTitle, cs),
        const SizedBox(height: 4),
        Text(
          l10n.lanSyncSecurityNote,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _server.running ? null : () => _showServerDialog(),
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: Text(l10n.lanSyncServerMode),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _server.running
                    ? null
                    : () => _showClientDialog(context, l10n, cs),
                icon: const Icon(Icons.link, size: 18),
                label: Text(l10n.lanSyncClientMode),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _desktopCard(
    bool isDark,
    ColorScheme cs, {
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: context.appColors.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _desktopHeader(String title, ColorScheme cs) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 15,
        fontWeight: AppFontWeights.semibold,
        color: cs.onSurface.withValues(alpha: 0.95),
      ),
    );
  }

  void _showServerDialog() {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ServerDialog(
        server: _server,
        l10n: l10n,
        cs: cs,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  void _showClientDialog(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    _client.reset();
    _priorityChoice = null;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ClientDialog(
        hostController: _hostController,
        portController: _portController,
        pinController: _pinController,
        client: _client,
        l10n: l10n,
        cs: cs,
        onNegotiate: _negotiate,
        onExchange: _exchange,
        onClose: () => Navigator.of(ctx).pop(),
        priority: _priorityChoice,
        onPriorityChanged: (v) => setState(() => _priorityChoice = v),
      ),
    );
  }

  // ===== Mobile layout =====

  Widget _buildMobile(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
    bool isDark,
  ) {
    return _mobileCard(
      isDark,
      cs,
      children: [
        _mobileNavRow(
          context,
          icon: Icons.wifi_tethering,
          label: l10n.lanSyncServerMode,
          onTap: _server.running ? null : () => _showServerDialog(),
        ),
        _mobileDivider(context),
        _mobileNavRow(
          context,
          icon: Icons.link,
          label: l10n.lanSyncClientMode,
          onTap: _server.running
              ? null
              : () => _showMobileClientSheet(context, l10n, cs),
        ),
      ],
    );
  }

  Widget _mobileCard(
    bool isDark,
    ColorScheme cs, {
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: context.appColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
    );
  }

  Widget _mobileNavRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final interactive = onTap != null;
    return IosCardPress(
      onTap: onTap,
      baseColor: Colors.transparent,
      pressedBlendStrength: 0.06,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            SizedBox(width: 36, child: Icon(icon, size: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (interactive) Icon(Icons.chevron_right, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _mobileDivider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Divider(
      height: 6,
      thickness: 0.6,
      indent: 54,
      endIndent: 12,
      color: cs.outlineVariant.withValues(alpha: 0.18),
    );
  }

  void _showMobileClientSheet(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    _client.reset();
    _priorityChoice = null;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _ClientSheet(
        hostController: _hostController,
        portController: _portController,
        pinController: _pinController,
        client: _client,
        l10n: l10n,
        cs: cs,
        onNegotiate: _negotiate,
        onExchange: _exchange,
        onClose: () => Navigator.of(ctx).pop(),
        priority: _priorityChoice,
        onPriorityChanged: (v) => setState(() => _priorityChoice = v),
      ),
    );
  }

  // ===== Shared logic =====

  Future<void> _negotiate() async {
    final l10n = AppLocalizations.of(context)!;
    final host = _hostController.text.trim();
    final portStr = _portController.text.trim();
    final pin = _pinController.text.trim();

    if (host.isEmpty || portStr.isEmpty || pin.isEmpty) {
      _showError(l10n.lanSyncErrorFieldsRequired);
      return;
    }

    final port = int.tryParse(portStr);
    if (port == null || port < 1 || port > 65535) {
      _showError(l10n.lanSyncErrorInvalidPort);
      return;
    }

    try {
      await _client.negotiate(
        host: host,
        port: port,
        pin: pin,
        syncPriority: _priorityChoice,
      );
    } catch (e) {
      _showError(
        e.toString().contains('PIN')
            ? l10n.lanSyncErrorInvalidPin
            : l10n.lanSyncErrorConnection(e.toString()),
      );
    }
  }

  /// Round 2. Returns `true` only when the caller should close its sheet:
  /// the empty-response (`noData`) path — a received zip already went
  /// through [_restoreAndRestart], which pops the dialog/sheet itself, and
  /// errors keep the sheet open for retry (or it was already popped by the
  /// restore flow).
  Future<bool> _exchange() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final host = _hostController.text.trim();
      final portStr = _portController.text.trim();
      final pin = _pinController.text.trim();
      final port = int.tryParse(portStr) ?? 9527;
      await _client.exchange(host: host, port: port, pin: pin);
      return _client.phase == LanSyncPhase.noData;
    } catch (e) {
      _showError(l10n.lanSyncErrorConnection(e.toString()));
      return false;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    final snackBar = SnackBar(content: Text(message));
    ScaffoldMessenger.of(context).showSnackBar(snackBar);
  }
}

// ===== Server dialog (shared by mobile & desktop) =====

enum _FirewallState { idle, adding, added, needsElevation }

class _ServerDialog extends StatefulWidget {
  final LanSyncServer server;
  final AppLocalizations l10n;
  final ColorScheme cs;
  final VoidCallback onClose;

  const _ServerDialog({
    required this.server,
    required this.l10n,
    required this.cs,
    required this.onClose,
  });

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  _FirewallState _fw = _FirewallState.idle;

  /// The in-flight firewall setup, so [dispose] can defer the fallback-rule
  /// cleanup until a still-running add (or UAC prompt) has finished —
  /// otherwise the delete would run before the rule exists and the late
  /// add would leave an orphan inbound rule on a random port.
  Future<void>? _firewallOp;

  @override
  void initState() {
    super.initState();
    widget.server.addListener(_onChanged);
    _start();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.server.removeListener(_onChanged);
    // Only the random-fallback port rule is removed on stop; the main-port
    // (9527) rule is kept so the common path never re-prompts for UAC.
    final fallbackPort =
        !kIsWeb && Platform.isWindows && !widget.server.usedPreferredPort
        ? widget.server.port
        : null;
    widget.server.stop();
    if (fallbackPort != null) {
      final pending = _firewallOp;
      unawaited(
        (pending ?? Future<void>.value()).then(
          (_) => WindowsFirewall.tryDeleteRule(fallbackPort),
        ),
      );
    }
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await widget.server.start(preferredPort: 9527);
      if (mounted && !kIsWeb && Platform.isWindows) {
        await _setupFirewall();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.l10n.lanSyncErrorConnection(e.toString())),
          ),
        );
        widget.onClose();
      }
    }
  }

  /// Best-effort auto-add of the inbound rule (works when the app already
  /// runs elevated). Falls back to the UAC button when it fails.
  Future<void> _setupFirewall() async {
    final port = widget.server.port;
    if (port == null) return;
    _firewallOp = _setupFirewallInternal(port);
    await _firewallOp;
  }

  Future<void> _setupFirewallInternal(int port) async {
    setState(() => _fw = _FirewallState.adding);
    if (await WindowsFirewall.ruleExists(port) ||
        await WindowsFirewall.tryAddRule(port)) {
      if (mounted) setState(() => _fw = _FirewallState.added);
      return;
    }
    if (mounted) setState(() => _fw = _FirewallState.needsElevation);
  }

  Future<void> _elevateFirewall() async {
    final port = widget.server.port;
    if (port == null) return;
    _firewallOp = _elevateFirewallInternal(port);
    await _firewallOp;
  }

  Future<void> _elevateFirewallInternal(int port) async {
    setState(() => _fw = _FirewallState.adding);
    final ok = await WindowsFirewall.addRuleElevated(port);
    if (!mounted) return;
    setState(
      () => _fw = ok ? _FirewallState.added : _FirewallState.needsElevation,
    );
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.l10n.lanSyncFirewallRuleFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final cs = widget.cs;
    final server = widget.server;
    final port = server.port;
    final phaseText = serverPhaseText(server.phase, l10n);

    return PopScope(
      // The mask contract: the system back button / Esc must not dismiss the
      // dialog while the merge-restore write window is open (barrierDismissible
      // does not intercept back — only PopScope does).
      canPop: server.restoreProgress == null,
      child: AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.wifi_tethering, size: 20, color: cs.primary),
            const SizedBox(width: 8),
            Text(l10n.lanSyncServerDialogTitle),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.lanSyncSecurityNote,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 16),
              // Every non-loopback IPv4 of this device — the user picks the
              // one on the peer's subnet (multi-NIC / VPN machines).
              if (server.addresses.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    l10n.lanSyncNoLanAddress,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                )
              else
                for (final (index, ip) in server.addresses.indexed)
                  _AddressDisplay(
                    label: index == 0 ? l10n.lanSyncServerAddress : '',
                    value: ip,
                    cs: cs,
                  ),
              _AddressDisplay(
                label: l10n.lanSyncServerPort,
                value: port?.toString() ?? '...',
                cs: cs,
              ),
              _AddressDisplay(
                label: l10n.lanSyncServerPin,
                value: server.pin ?? '...',
                cs: cs,
                emphasize: true,
              ),
              if (!kIsWeb && Platform.isWindows) ...[
                const SizedBox(height: 10),
                ..._buildFirewallSection(l10n, cs, port),
              ],
              if (phaseText.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  phaseText,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
              // Display-only notice (issue #615): the initiator's conflict
              // direction reaches the server UI so its user knows how
              // conflicting data will be resolved. No veto — the PIN already
              // gates the session.
              if (server.initiatorPriority != null &&
                  server.restoreProgress == null) ...[
                const SizedBox(height: 8),
                Text(
                  server.initiatorPriority == SyncPriority.initiatorWins
                      ? l10n.lanSyncPeerPriorityInitiatorWins
                      : l10n.lanSyncPeerPriorityServerWins,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
              if (server.restoreProgress != null) ...[
                const SizedBox(height: 12),
                buildRestoreProgress(server.restoreProgress!, l10n, cs),
              ] else if (server.restoreError != null) ...[
                const SizedBox(height: 12),
                buildRestoreError(
                  server.restoreError!,
                  l10n,
                  cs,
                  onClose: widget.onClose,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: server.restoreProgress != null ? null : widget.onClose,
            child: Text(l10n.lanSyncServerStop),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFirewallSection(
    AppLocalizations l10n,
    ColorScheme cs,
    int? port,
  ) {
    switch (_fw) {
      case _FirewallState.idle:
        return [];
      case _FirewallState.adding:
        return [
          Text(
            l10n.lanSyncFirewallAdding,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ];
      case _FirewallState.added:
        return [
          Text(
            l10n.lanSyncFirewallRuleAdded(port ?? 0),
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ];
      case _FirewallState.needsElevation:
        return [
          Text(
            l10n.lanSyncFirewallRuleFailed,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _elevateFirewall,
            icon: const Icon(Icons.shield, size: 16),
            label: Text(l10n.lanSyncFirewallAllow),
          ),
        ];
    }
  }
}

/// Displays an address-like value with prominent (non-gray) styling.
class _AddressDisplay extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme cs;
  final bool emphasize;

  const _AddressDisplay({
    required this.label,
    required this.value,
    required this.cs,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: emphasize ? 22 : 16,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface,
                letterSpacing: emphasize ? 4 : 0,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ===== Client dialog (desktop) =====

class _ClientDialog extends StatefulWidget {
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController pinController;
  final LanSyncClient client;
  final AppLocalizations l10n;
  final ColorScheme cs;
  final Future<void> Function() onNegotiate;
  final Future<bool> Function() onExchange;
  final VoidCallback onClose;
  final SyncPriority? priority;
  final ValueChanged<SyncPriority?> onPriorityChanged;

  const _ClientDialog({
    required this.hostController,
    required this.portController,
    required this.pinController,
    required this.client,
    required this.l10n,
    required this.cs,
    required this.onNegotiate,
    required this.onExchange,
    required this.onClose,
    required this.priority,
    required this.onPriorityChanged,
  });

  @override
  State<_ClientDialog> createState() => _ClientDialogState();
}

class _ClientDialogState extends State<_ClientDialog> {
  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.client.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final cs = widget.cs;
    final client = widget.client;
    final phaseText = clientPhaseText(client.phase, l10n);

    return PopScope(
      // The mask contract: the system back button / Esc must not dismiss the
      // dialog while the merge-restore write window is open (barrierDismissible
      // does not intercept back — only PopScope does).
      canPop: client.restoreProgress == null,
      child: AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.link, size: 20, color: cs.primary),
            const SizedBox(width: 8),
            Text(l10n.lanSyncClientDialogTitle),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: widget.hostController,
                decoration: InputDecoration(
                  labelText: l10n.lanSyncClientHost,
                  hintText: '192.168.1.100',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.portController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: l10n.lanSyncClientPort,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: widget.pinController,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      decoration: InputDecoration(
                        labelText: l10n.lanSyncClientPin,
                        isDense: true,
                        border: const OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _SyncPriorityPicker(
                value: widget.priority,
                onChanged: widget.onPriorityChanged,
                // Locked while the plan request is in flight: the wire value
                // is captured at negotiate time, so a late pick would diverge
                // from what the peer will actually apply (issue #615 review).
                enabled: !client.busy && client.plan == null,
                l10n: l10n,
                cs: cs,
              ),
              if (phaseText.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  phaseText,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
              if (client.plan != null) ...[
                const SizedBox(height: 12),
                ...buildPlanSummary(
                  l10n,
                  client.plan!,
                  cs,
                  outboundFileCount: client.outboundFileCount,
                  outboundFileSizeBytes: client.outboundFileSizeBytes,
                  forceSettingsExchange: client.forceSettingsExchange,
                ),
              ],
              if (client.restoreProgress != null) ...[
                const SizedBox(height: 12),
                buildRestoreProgress(client.restoreProgress!, l10n, cs),
              ] else if (client.restoreError != null) ...[
                const SizedBox(height: 12),
                buildRestoreError(
                  client.restoreError!,
                  l10n,
                  cs,
                  onClose: widget.onClose,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: client.busy || client.restoreError != null
                ? null
                : widget.onClose,
            child: Text(l10n.backupPageCancel),
          ),
          FilledButton(
            onPressed: client.busy || client.restoreError != null
                ? null
                : () async {
                    if (client.plan == null) {
                      await widget.onNegotiate();
                    } else {
                      await widget.onExchange();
                    }
                  },
            child: client.busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onPrimary,
                    ),
                  )
                : Text(
                    client.plan == null
                        ? l10n.lanSyncClientConnect
                        : l10n.lanSyncClientConfirm,
                  ),
          ),
        ],
      ),
    );
  }
}

// ===== Client sheet (mobile) =====

class _ClientSheet extends StatefulWidget {
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController pinController;
  final LanSyncClient client;
  final AppLocalizations l10n;
  final ColorScheme cs;
  final Future<void> Function() onNegotiate;
  final Future<bool> Function() onExchange;
  final VoidCallback onClose;
  final SyncPriority? priority;
  final ValueChanged<SyncPriority?> onPriorityChanged;

  const _ClientSheet({
    required this.hostController,
    required this.portController,
    required this.pinController,
    required this.client,
    required this.l10n,
    required this.cs,
    required this.onNegotiate,
    required this.onExchange,
    required this.onClose,
    required this.priority,
    required this.onPriorityChanged,
  });

  @override
  State<_ClientSheet> createState() => _ClientSheetState();
}

class _ClientSheetState extends State<_ClientSheet> {
  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.client.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final cs = widget.cs;
    final client = widget.client;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final phaseText = clientPhaseText(client.phase, l10n);

    return PopScope(
      // The mask contract: the system back button / Esc must not dismiss the
      // sheet while the merge-restore write window is open (isDismissible does
      // not intercept back — only PopScope does).
      canPop: client.restoreProgress == null,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                const SizedBox(height: 12),
                Text(
                  l10n.lanSyncClientDialogTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                IosFormTextField(
                  label: l10n.lanSyncClientHost,
                  controller: widget.hostController,
                  hintText: '192.168.1.100',
                ),
                const SizedBox(height: 10),
                // Stacked, not side-by-side: two fields in one row are too
                // cramped for phone widths (issue #182).
                IosFormTextField(
                  label: l10n.lanSyncClientPort,
                  controller: widget.portController,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 10),
                IosFormTextField(
                  label: l10n.lanSyncClientPin,
                  controller: widget.pinController,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                ),
                const SizedBox(height: 16),
                _SyncPriorityPicker(
                  value: widget.priority,
                  onChanged: widget.onPriorityChanged,
                  // Locked while the plan request is in flight: the wire value
                  // is captured at negotiate time, so a late pick would diverge
                  // from what the peer will actually apply (issue #615 review).
                  enabled: !client.busy && client.plan == null,
                  l10n: l10n,
                  cs: cs,
                ),
                const SizedBox(height: 16),
                if (phaseText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      phaseText,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                if (client.plan != null) ...[
                  ...buildPlanSummary(
                    l10n,
                    client.plan!,
                    cs,
                    outboundFileCount: client.outboundFileCount,
                    outboundFileSizeBytes: client.outboundFileSizeBytes,
                    forceSettingsExchange: client.forceSettingsExchange,
                  ),
                  const SizedBox(height: 12),
                ],
                if (client.restoreProgress != null) ...[
                  buildRestoreProgress(client.restoreProgress!, l10n, cs),
                  const SizedBox(height: 12),
                ] else if (client.restoreError != null) ...[
                  buildRestoreError(
                    client.restoreError!,
                    l10n,
                    cs,
                    onClose: widget.onClose,
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton(
                  onPressed: client.busy || client.restoreError != null
                      ? null
                      : () async {
                          if (client.plan == null) {
                            await widget.onNegotiate();
                          } else {
                            final shouldClose = await widget.onExchange();
                            if (context.mounted && shouldClose) {
                              widget.onClose();
                            }
                          }
                        },
                  child: client.busy
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.onPrimary,
                          ),
                        )
                      : Text(
                          client.plan == null
                              ? l10n.lanSyncClientConnect
                              : l10n.lanSyncClientConfirm,
                        ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: client.busy || client.restoreError != null
                      ? null
                      : widget.onClose,
                  child: Text(l10n.backupPageCancel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared conflict-direction picker (issue #615), used by the desktop client
/// dialog and the mobile client sheet. Three modes: auto (default merge) /
/// this device wins / peer wins. Disabled once the plan request has been sent
/// — the choice is fixed for the whole session.
class _SyncPriorityPicker extends StatelessWidget {
  final SyncPriority? value;
  final ValueChanged<SyncPriority?> onChanged;
  final bool enabled;
  final AppLocalizations l10n;
  final ColorScheme cs;

  const _SyncPriorityPicker({
    required this.value,
    required this.onChanged,
    required this.enabled,
    required this.l10n,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final options = <(SyncPriority?, String)>[
      (null, l10n.lanSyncPriorityAuto),
      (SyncPriority.initiatorWins, l10n.lanSyncPriorityInitiatorWins),
      (SyncPriority.serverWins, l10n.lanSyncPriorityServerWins),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.lanSyncPriorityLabel,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 8),
        for (final option in options) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: IosTileButton(
              label: option.$2,
              icon: value == option.$1
                  ? Icons.radio_button_checked
                  : Icons.circle_outlined,
              onTap: enabled ? () => onChanged(option.$1) : () {},
              enabled: enabled,
              fontSize: 13,
              // Matches the tinted-pill pattern (bg primary + default primary
              // fg) — no onPrimary over the pale primary tint (contrast).
              backgroundColor: value == option.$1 ? cs.primary : null,
            ),
          ),
        ],
      ],
    );
  }
}

/// Shared plan summary widget builder for sync plan display.
///
/// [outboundFileCount]/[outboundFileSizeBytes] are the initiator's own file
/// payload (computed client-side); [SyncPlan.serverFileCount] is the peer's.
/// File lines render only when the count is known and > 0.
/// [forceSettingsExchange] (issue #615) replaces the "no changes" line with a
/// settings-exchange note when a confirmed conflict direction forces a
/// settings-only payload despite zero chat/file deltas.
List<Widget> buildPlanSummary(
  AppLocalizations l10n,
  SyncPlan plan,
  ColorScheme cs, {
  int? outboundFileCount,
  int? outboundFileSizeBytes,
  bool forceSettingsExchange = false,
}) {
  // A file-only delta (all conversations identical) is a real sync: the plan
  // must not render "No changes" just because there are no chat increments.
  final hasFilePayload =
      (outboundFileCount ?? 0) > 0 || (plan.serverFileCount ?? 0) > 0;
  if (plan.initiatorOnlyCount == 0 &&
      plan.serverOnlyCount == 0 &&
      plan.forkCount == 0 &&
      !hasFilePayload &&
      !forceSettingsExchange) {
    return [
      Text(
        l10n.lanSyncPlanNoChanges,
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    ];
  }
  return [
    if (forceSettingsExchange)
      Text(
        l10n.lanSyncPlanPrioritySettings,
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    if (plan.initiatorOnlyCount > 0)
      Text(
        l10n.lanSyncPlanToSend(plan.initiatorOnlyCount),
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    if (plan.serverOnlyCount > 0) ...[
      const SizedBox(height: 4),
      Text(
        l10n.lanSyncPlanToReceive(plan.serverOnlyCount),
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    ],
    if (plan.forkCount > 0) ...[
      const SizedBox(height: 4),
      Text(
        l10n.lanSyncPlanForks(plan.forkCount),
        style: TextStyle(
          fontSize: 13,
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
      ),
    ],
    if (outboundFileCount != null && outboundFileCount > 0) ...[
      const SizedBox(height: 4),
      Text(
        l10n.lanSyncPlanToSendFiles(
          outboundFileCount,
          formatBytes(outboundFileSizeBytes ?? 0),
        ),
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    ],
    if (plan.serverFileCount != null && plan.serverFileCount! > 0) ...[
      const SizedBox(height: 4),
      Text(
        l10n.lanSyncPlanToReceiveFiles(
          plan.serverFileCount!,
          formatBytes(plan.serverFileSizeBytes ?? 0),
        ),
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    ],
  ];
}

/// Shared restore-failure content for the sync dialog/sheet: localized error
/// headline + the exception message + a single close action.
Widget buildRestoreError(
  String message,
  AppLocalizations l10n,
  ColorScheme cs, {
  required VoidCallback onClose,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        l10n.lanSyncRestoreFailed,
        style: TextStyle(
          fontSize: 13,
          fontWeight: AppFontWeights.semibold,
          color: cs.error,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        message,
        style: TextStyle(
          fontSize: 12,
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: onClose,
          child: Text(l10n.backupPageCancel),
        ),
      ),
    ],
  );
}
