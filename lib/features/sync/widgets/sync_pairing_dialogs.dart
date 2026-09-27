import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_engine.dart';
import '../../../core/services/sync/sync_pair_qr.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../scan/pages/qr_scan_page.dart';
import '../sync_messages.dart';

/// Pairing surface shared by the mobile page and the desktop pane: the
/// showing side displays the pairing QR (PIN + endpoints + fingerprint
/// bound to the one-shot window) plus the endpoints to type on a peer
/// without a camera; the entering side scans, or collects host/port/PIN.
/// Dialogs (not sheets) so both form factors share one code path.

/// Platforms whose scanner can actually be offered: Android and iOS.
///
/// `mobile_scanner` also ships a macOS implementation, but this app's macOS
/// target declares neither `NSCameraUsageDescription` nor the camera
/// entitlement, and an undeclared camera access is a process kill there — so
/// macOS shows its QR or types the code, and the phone is the scanner (the
/// primary journey). Windows and Linux have no implementation at all.
bool get canScanPairingQr => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

Future<void> showSyncPairingDialogs({
  required BuildContext context,
  required bool showCode,
}) {
  return showCode ? _showCodeDialog(context) : _showEnterCodeDialog(context);
}

Future<void> _showCodeDialog(BuildContext context) async {
  final provider = context.read<SyncProvider>();
  final pin = provider.openPairing();
  if (pin == null || !context.mounted) return;
  // The window this dialog opens lives for five minutes and is invisible
  // anywhere else, so the dialog must not be dismissible on its own: a barrier
  // tap or a system back gesture would leave a live PIN and QR on screen for
  // no one. Only the explicit close (which cancels) or expiry (which closes the
  // window first) ends it.
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PairingCodeDialog(provider: provider, pin: pin),
  );
}

class _PairingCodeDialog extends StatefulWidget {
  const _PairingCodeDialog({required this.provider, required this.pin});

  final SyncProvider provider;
  final String pin;

  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  /// Encoded once: the QR carries pin + port + addresses, none of which
  /// change per second, so the countdown ticker must not rebuild it.
  String? _qrData;

  @override
  void initState() {
    super.initState();
    _remaining = DateTime.now().isBefore(widget.provider.pairingExpiresAt!)
        ? widget.provider.pairingExpiresAt!.difference(DateTime.now())
        : Duration.zero;
    _qrData = _buildQrData();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final expiresAt = widget.provider.pairingExpiresAt;
      if (!mounted) return;
      if (expiresAt == null) {
        // `pop`, not `maybePop`: this route refuses route-level pops (the
        // window must not be dismissible by a gesture), and an expired window
        // is the one close that is not a user pop.
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _remaining = expiresAt.difference(DateTime.now());
      });
      if (!_remaining.isNegative && _remaining == Duration.zero) {
        Navigator.of(context).pop();
      }
    });
  }

  String? _buildQrData() {
    final provider = widget.provider;
    final deviceId = provider.deviceId;
    final port = provider.port;
    if (deviceId == null) return null;
    return SyncPairQrPayload(
      deviceId: deviceId,
      name: provider.deviceName ?? '',
      endpoints: [
        for (final ip in provider.localIps)
          if (port != null) (ip, port),
      ],
      pin: widget.pin,
    ).toQrString();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _countdown {
    final seconds = _remaining.isNegative ? 0 : _remaining.inSeconds;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = widget.provider;
    final endpoints = [
      for (final ip in provider.localIps) '$ip:${provider.port ?? ''}',
    ];
    // The dialog closes only through its own button (which cancels the
    // window) or the expiry ticker; a system back gesture must not leave the
    // window open behind a dismissed dialog.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l10n.lanSyncPairingCode),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_qrData != null) ...[
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      // Always white: a QR must stay dark-on-light to scan.
                      color:
                          Colors.white, // color-gate: ignore (QR scannability)
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SizedBox.square(
                      dimension: 180,
                      child: PrettyQrView.data(
                        data: _qrData!,
                        errorCorrectLevel: QrErrorCorrectLevel.M,
                        decoration: const PrettyQrDecoration(
                          shape: PrettyQrSmoothSymbol(roundFactor: 1),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    l10n.lanSyncPairQrCaption,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Center(
                child: Text(
                  '${widget.pin.substring(0, 3)} ${widget.pin.substring(3)}',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: AppFontWeights.emphasis,
                    letterSpacing: 4,
                    color: cs.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  l10n.lanSyncPairingExpiresIn(_countdown),
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                l10n.lanSyncPairingEndpointHint,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 4),
              if (endpoints.isEmpty)
                Text(
                  l10n.lanSyncPairingNoIpHint,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                )
              else
                for (final endpoint in endpoints)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      endpoint,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: AppFontWeights.medium,
                        color: cs.primary,
                      ),
                    ),
                  ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              provider.cancelPairing();
              Navigator.of(context).pop();
            },
            child: Text(l10n.lanSyncClosePairing),
          ),
        ],
      ),
    );
  }
}

Future<void> _showEnterCodeDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _EnterCodeDialog(),
  );
}

class _EnterCodeDialog extends StatefulWidget {
  const _EnterCodeDialog();

  @override
  State<_EnterCodeDialog> createState() => _EnterCodeDialogState();
}

class _EnterCodeDialogState extends State<_EnterCodeDialog> {
  late final TextEditingController _host = TextEditingController();
  late final TextEditingController _port = TextEditingController(
    text: '${SyncEngine.kPreferredPort}',
  );
  late final TextEditingController _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  /// A scanned payload without endpoints: the fingerprint still pins the
  /// manual entry once a host is typed.
  SyncPairQrPayload? _scanned;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (code == null || code.isEmpty || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final SyncPairQrPayload payload;
    try {
      payload = SyncPairQrPayload.parse(code);
    } on SyncPairQrException catch (error) {
      setState(() => _error = syncQrErrorMessage(l10n, error));
      return;
    }
    if (payload.endpoints.isEmpty) {
      // QR without a usable address: keep the fingerprint + pin, ask for the
      // host by hand.
      setState(() {
        _scanned = payload;
        _pin.text = payload.pin;
        _error = l10n.lanSyncPairErrorNoEndpointInQr;
      });
      return;
    }
    await _pairQr(payload);
  }

  Future<void> _pairQr(SyncPairQrPayload payload) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await context.read<SyncProvider>().pairWithQr(payload);
    if (!mounted) return;
    if (result.outcome.success) {
      final name = payload.name.isEmpty
          ? payload.deviceId.substring(0, 8)
          : payload.name;
      _notifyPaired(l10n, name, result.wasKnownPeer);
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = syncPairErrorMessage(l10n, result.outcome);
    });
  }

  void _notifyPaired(AppLocalizations l10n, String name, bool wasKnownPeer) {
    try {
      showAppSnackBar(
        context,
        message: wasKnownPeer
            ? l10n.lanSyncPairUpdatedSnackbar(name)
            : l10n.lanSyncPairSuccess(name),
        type: NotificationType.success,
      );
    } catch (_) {
      // No overlay above this point; the peer card appears either way.
    }
  }

  Future<void> _pair() async {
    final l10n = AppLocalizations.of(context)!;
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final pin = _pin.text.trim();
    if (host.isEmpty || port == null || pin.length != 6) {
      setState(() => _error = l10n.lanSyncPairErrorInvalidPin);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Known-ness must be read before pairing refreshes the peer list.
    final scanned = _scanned;
    final wasKnown =
        scanned != null &&
        context.read<SyncProvider>().peers.any(
          (p) => p.deviceId == scanned.deviceId,
        );
    final outcome = await context.read<SyncProvider>().pairWith(
      host: host,
      port: port,
      pin: pin,
      expectedDeviceId: scanned?.deviceId,
    );
    if (!mounted) return;
    if (outcome.success) {
      if (scanned != null) {
        final name = scanned.name.isEmpty
            ? scanned.deviceId.substring(0, 8)
            : scanned.name;
        _notifyPaired(l10n, name, wasKnown);
      }
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = syncPairErrorMessage(l10n, outcome);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(l10n.lanSyncEnterCode),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canScanPairingQr) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: Icon(Lucide.Camera, size: 16),
                  label: Text(l10n.lanSyncScanQr),
                ),
              ),
              const SizedBox(height: 10),
            ],
            IosDialogField(
              controller: _host,
              label: l10n.lanSyncHostLabel,
              hint: '192.168.1.10',
            ),
            IosDialogField(
              controller: _port,
              label: l10n.lanSyncPortLabel,
              hint: '${SyncEngine.kPreferredPort}',
              keyboardType: TextInputType.number,
            ),
            IosDialogField(
              controller: _pin,
              label: l10n.lanSyncPairingCode,
              hint: '123 456',
              keyboardType: TextInputType.number,
              onChanged: (text) {
                // Auto-submit at six digits — one less tap on the phone.
                if (text.trim().length == 6 && !_busy) _pair();
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Lucide.TriangleAlert, size: 15, color: cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.lanSyncClosePairing),
        ),
        FilledButton(
          onPressed: _busy ? null : _pair,
          child: Text(_busy ? l10n.lanSyncPairingBusy : l10n.lanSyncPairButton),
        ),
      ],
    );
  }
}

/// Minimal labeled field that fits both dialog sizes (the shared
/// [IosFormTextField] targets page layouts; this trims it for dialogs).
class IosDialogField extends StatelessWidget {
  const IosDialogField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
