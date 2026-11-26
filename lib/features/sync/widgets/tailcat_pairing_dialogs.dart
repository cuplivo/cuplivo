import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_transport.dart';
import '../../../core/services/sync/tailcat_pair_qr.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../scan/pages/qr_scan_page.dart';
import '../sync_messages.dart';
import 'sync_pairing_dialogs.dart' show PairingQrImage, canScanPairingQr;

/// The remote pairing surface (ADR-0021): the tailcat counterpart of the LAN
/// pairing dialogs.
///
/// Showing side: the QR that carries this device's remote address, the one-shot
/// PIN and — behind a disclosure, because the address is the capability to
/// reach the device — the address text to copy onto a device that cannot scan.
/// Joining side: scan the other device's QR, or paste its address and type the
/// PIN. Dialogs on both form factors, like the LAN flow.

/// Opens the pairing dialog that displays this device's remote pairing QR.
///
/// The remote address exists only while the remote listener runs, so this
/// starts it first (idempotent). A failed start still opens the dialog — it is
/// where the encoded error can be explained — and the dialog then shows why
/// there is no code to display.
Future<void> showTailcatPairingCodeDialog(BuildContext context) async {
  final provider = context.read<SyncProvider>();
  await provider.ensureRemoteStarted();
  if (!context.mounted) return;
  final pin = provider.openPairing();
  await showDialog<void>(
    context: context,
    // The window this dialog opens is invisible everywhere else, and a barrier
    // tap or a back gesture would leave a live PIN and QR behind no one. Only
    // the explicit close and expiry end it.
    barrierDismissible: false,
    builder: (_) => _TailcatPairingCodeDialog(provider: provider, pin: pin),
  );
}

/// Opens the dialog that pairs with a device showing its remote pairing QR:
/// scan the code, or paste the other device's remote address and type the PIN.
Future<void> showTailcatEnterCodeDialog(BuildContext context) async {
  // The joining side advertises its own remote endpoint in the request, so its
  // listener has to exist first — the same reason the shown side starts one.
  await context.read<SyncProvider>().ensureRemoteStarted();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => const _TailcatEnterCodeDialog(),
  );
}

class _TailcatPairingCodeDialog extends StatefulWidget {
  const _TailcatPairingCodeDialog({required this.provider, required this.pin});

  final SyncProvider provider;

  /// The one-shot PIN when the pairing window could be opened, or null when the
  /// remote side is not ready to show a code at all.
  final String? pin;

  @override
  State<_TailcatPairingCodeDialog> createState() =>
      _TailcatPairingCodeDialogState();
}

class _TailcatPairingCodeDialogState extends State<_TailcatPairingCodeDialog> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  /// Encoded once: the data the window pins (this device's address, PIN and
  /// fingerprint) is fixed for the window's lifetime.
  String? _qrData;

  @override
  void initState() {
    super.initState();
    _encodeQr();
    final expiresAt = widget.provider.pairingExpiresAt;
    if (widget.pin == null || expiresAt == null) return;
    _remaining = expiresAt.isAfter(DateTime.now())
        ? expiresAt.difference(DateTime.now())
        : Duration.zero;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _encodeQr() {
    final pin = widget.pin;
    final address = widget.provider.remoteAddress;
    final deviceId = widget.provider.deviceId;
    if (pin == null || address == null || deviceId == null) return;
    _qrData = TailcatPairQrPayload(
      deviceId: deviceId,
      name: widget.provider.deviceName ?? '',
      address: address,
      pin: pin,
    ).toQrString();
  }

  void _tick() {
    final expiresAt = widget.provider.pairingExpiresAt;
    if (!mounted) return;
    if (expiresAt == null) {
      _close();
      return;
    }
    final remaining = expiresAt.difference(DateTime.now());
    setState(() {
      _remaining = remaining.isNegative ? Duration.zero : remaining;
    });
    if (remaining <= Duration.zero) _close();
  }

  /// Pops this dialog exactly once, disarming the ticker first.
  ///
  /// `mounted` stays true for the whole exit animation, so a tick landing there
  /// after the close button cancelled the window would pop a second time and
  /// take the page beneath with it. The `isCurrent` guard covers the mirror
  /// order: the ticker closed the dialog just before a late tap landed.
  ///
  /// `pop`, not `maybePop`: this route refuses route-level pops.
  void _close() {
    _ticker?.cancel();
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    Navigator.of(context).pop();
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

  static String _formattedPin(String pin) =>
      pin.length == 6 ? '${pin.substring(0, 3)} ${pin.substring(3)}' : pin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final pin = widget.pin;
    final ready = pin != null && _qrData != null;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l10n.remoteSyncPairingCode),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ready) ...[
                Center(child: PairingQrImage(data: _qrData!)),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    l10n.lanSyncPairQrCaption,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    _formattedPin(pin),
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
                _RemoteAddressDisclosure(
                  address: widget.provider.remoteAddress,
                ),
                const SizedBox(height: 14),
                _TailcatFirstSyncNote(text: l10n.lanSyncPairFirstSyncNote),
              ] else
                _DialogError(message: l10n.remoteSyncPairErrorUnavailable),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              widget.provider.cancelPairing();
              _close();
            },
            child: Text(l10n.lanSyncClosePairing),
          ),
        ],
      ),
    );
  }
}

/// The "type this into the other device" address, closed by default.
///
/// Closed because the address is a secret and a long one at that: it is the
/// capability to reach this device, and the QR above is the journey. The header
/// says what is behind the tap, and copying is one more tap once it is open.
class _RemoteAddressDisclosure extends StatefulWidget {
  const _RemoteAddressDisclosure({required this.address});

  final String? address;

  @override
  State<_RemoteAddressDisclosure> createState() =>
      _RemoteAddressDisclosureState();
}

class _RemoteAddressDisclosureState extends State<_RemoteAddressDisclosure> {
  bool _revealed = false;

  Future<void> _copy() async {
    final address = widget.address;
    if (address == null) return;
    await Clipboard.setData(ClipboardData(text: address));
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      showAppSnackBar(
        context,
        message: l10n.remoteSyncAddressCopied,
        type: NotificationType.success,
      );
    } catch (_) {
      // No overlay above this point; the address is on the clipboard either way.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final address = widget.address;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.remoteSyncAddressLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (address != null && !_revealed)
              TextButton(
                onPressed: () => setState(() => _revealed = true),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(l10n.remoteSyncShowAddress),
              )
            else if (address != null)
              IconButton(
                onPressed: _copy,
                tooltip: l10n.remoteSyncCopyAddress,
                visualDensity: VisualDensity.compact,
                icon: Icon(Lucide.Copy, size: 16, color: cs.primary),
              ),
          ],
        ),
        if (address == null)
          Text(
            l10n.remoteSyncAddressEmpty,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          )
        else if (!_revealed)
          Text(
            '••••••••••••••••••••',
            style: TextStyle(
              fontSize: 14,
              letterSpacing: 2,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              address,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
      ],
    );
  }
}

class _TailcatEnterCodeDialog extends StatefulWidget {
  const _TailcatEnterCodeDialog();

  @override
  State<_TailcatEnterCodeDialog> createState() =>
      _TailcatEnterCodeDialogState();
}

class _TailcatEnterCodeDialogState extends State<_TailcatEnterCodeDialog> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (code == null || code.isEmpty || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final TailcatPairQrPayload payload;
    try {
      payload = TailcatPairQrPayload.parse(code);
    } on TailcatPairQrException catch (error) {
      setState(() => _error = tailcatQrErrorMessage(l10n, error));
      return;
    }
    await _pairQr(payload);
  }

  Future<void> _pairQr(TailcatPairQrPayload payload) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    final provider = context.read<SyncProvider>();
    final result = await provider.pairWithRemoteQr(payload);
    if (!mounted) return;
    if (result.outcome.success) {
      _notifyPaired(l10n, _pairedName(result.outcome), result.wasKnownPeer);
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = tailcatSyncPairErrorMessage(l10n, result.outcome);
    });
  }

  Future<void> _pair() async {
    final l10n = AppLocalizations.of(context)!;
    // The address is pasted as one long string; whitespace is what phone
    // keyboards and chat clients insert around it, never part of the encoding.
    final address = normalizeTailcatAddress(_address.text);
    final pin = normalizePairingCode(_pin.text);
    if (!looksLikeTailcatAddress(address)) {
      setState(() => _error = l10n.remoteSyncPairErrorInvalidAddress);
      return;
    }
    if (pin.length != 6) {
      setState(() => _error = l10n.lanSyncPairErrorInvalidPin);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final provider = context.read<SyncProvider>();
    // Known-ness must be read before pairing refreshes the peer list, and the
    // outcome carries the paired device's id, so which line to show is decided
    // against the list as it stood.
    final knownBefore = {for (final peer in provider.peers) peer.deviceId};
    final outcome = await provider.pairWithRemote(address: address, pin: pin);
    if (!mounted) return;
    if (outcome.success) {
      _notifyPaired(
        l10n,
        _pairedName(outcome),
        knownBefore.contains(outcome.peerDeviceId),
      );
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = tailcatSyncPairErrorMessage(l10n, outcome);
    });
  }

  /// The name to announce a pairing by: the record the pairing wrote, or the
  /// short id of a device that announced no name at all.
  String _pairedName(SyncPairOutcome outcome) {
    final name = outcome.peerName;
    if (name != null && name.isNotEmpty) return name;
    final id = outcome.peerDeviceId ?? '';
    return id.length > 8 ? id.substring(0, 8) : id;
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(l10n.remoteSyncEnterCode),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TailcatFirstSyncNote(text: l10n.lanSyncPairFirstSyncNote),
            const SizedBox(height: 12),
            if (canScanPairingQr) ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _scan,
                icon: Icon(Lucide.Camera, size: 16),
                label: Text(l10n.lanSyncScanQr),
              ),
              const SizedBox(height: 10),
            ],
            IosFormTextField(
              label: l10n.remoteSyncAddressLabel,
              controller: _address,
              hintText: l10n.remoteSyncAddressHint,
              inlineLabel: false,
              outerPadding: EdgeInsets.zero,
              minLines: 2,
              maxLines: 3,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              textStyle: const TextStyle(fontSize: 13, height: 1.35),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.remoteSyncAddressNote,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 12),
            IosFormTextField(
              label: l10n.remoteSyncPairingCode,
              controller: _pin,
              hintText: '123 456',
              inlineLabel: false,
              outerPadding: EdgeInsets.zero,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              onChanged: (text) {
                // Auto-submit at six digits — one less tap on the phone.
                if (normalizePairingCode(text).length == 6 && !_busy) _pair();
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              _DialogError(message: _error!),
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

/// The one-line error both dialogs share: a warning triangle and the mapped,
/// localized reason.
class _DialogError extends StatelessWidget {
  const _DialogError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Lucide.TriangleAlert, size: 15, color: cs.error),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: 12, height: 1.35, color: cs.error),
          ),
        ),
      ],
    );
  }
}

/// The "keep both devices awake for the first sync" advisory both halves of the
/// remote pairing surface carry — the same note the LAN pairing dialogs show.
class _TailcatFirstSyncNote extends StatelessWidget {
  const _TailcatFirstSyncNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.appColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Lucide.TriangleAlert,
            size: 14,
            color: context.appColors.warning,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
