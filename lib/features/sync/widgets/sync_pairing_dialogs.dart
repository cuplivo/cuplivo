import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_engine.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import '../sync_messages.dart';

/// Pairing surface shared by the mobile page and the desktop pane: the
/// showing side displays the PIN plus the endpoints to type on the peer, the
/// entering side collects host/port/PIN. Dialogs (not sheets) so both form
/// factors share one code path.

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
  await showDialog<void>(
    context: context,
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

  @override
  void initState() {
    super.initState();
    _remaining = DateTime.now().isBefore(widget.provider.pairingExpiresAt!)
        ? widget.provider.pairingExpiresAt!.difference(DateTime.now())
        : Duration.zero;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final expiresAt = widget.provider.pairingExpiresAt;
      if (!mounted) return;
      if (expiresAt == null) {
        Navigator.of(context).maybePop();
        return;
      }
      setState(() {
        _remaining = expiresAt.difference(DateTime.now());
      });
      if (!_remaining.isNegative && _remaining == Duration.zero) {
        Navigator.of(context).maybePop();
      }
    });
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
    return AlertDialog(
      title: Text(l10n.lanSyncPairingCode),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
      actions: [
        TextButton(
          onPressed: () {
            provider.cancelPairing();
            Navigator.of(context).pop();
          },
          child: Text(l10n.lanSyncClosePairing),
        ),
      ],
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
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final TextEditingController _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _pin.dispose();
    super.dispose();
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
    final outcome = await context.read<SyncProvider>().pairWith(
      host: host,
      port: port,
      pin: pin,
    );
    if (!mounted) return;
    if (outcome.success) {
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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
