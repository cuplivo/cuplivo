import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_store.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../sync_messages.dart';
import 'sync_pairing_dialogs.dart' show IosDialogField;

/// One paired device: identity, endpoint, last outcome, and the three actions
/// that exist without discovery — sync now, fix the address, unpair.
class SyncPeerCard extends StatelessWidget {
  const SyncPeerCard({super.key, required this.peer});

  final SyncPeerRecord peer;

  IconData get _platformIcon {
    switch (peer.platform) {
      case 'android':
      case 'ios':
        return Lucide.Smartphone;
      default:
        return Lucide.Monitor;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<SyncProvider>();
    final busy = provider.busyDeviceIds.contains(peer.deviceId);
    final primary = peer.primaryEndpoint;
    final endpoint = primary?.label;
    final report = peer.lastReport;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _platformIcon,
                size: 20,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.medium,
                        color: cs.onSurface.withValues(alpha: 0.92),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        syncPlatformLabel(l10n, peer.platform),
                        if (endpoint != null) endpoint,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              busy
                  ? Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.lanSyncSyncing,
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    )
                  : TextButton.icon(
                      onPressed: () => _syncNow(context, provider),
                      icon: Icon(Lucide.RefreshCw, size: 15),
                      label: Text(l10n.lanSyncSyncNow),
                    ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            syncLastSyncedLabel(l10n, peer.lastSyncedAt),
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          if (report != null) ...[
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (report.refusal != null || !report.success) ...[
                  Icon(Lucide.TriangleAlert, size: 13, color: cs.error),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(
                    syncPeerReportMessage(l10n, report),
                    style: TextStyle(
                      fontSize: 12,
                      color: report.refusal != null || !report.success
                          ? cs.error
                          : cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: () => _rename(context, provider),
                child: Text(l10n.lanSyncRename),
              ),
              TextButton(
                onPressed: () => _editAddress(context, provider),
                child: Text(l10n.lanSyncEditAddress),
              ),
              TextButton(
                onPressed: () => _unpair(context, provider),
                style: TextButton.styleFrom(foregroundColor: cs.error),
                child: Text(l10n.lanSyncUnpair),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _syncNow(BuildContext context, SyncProvider provider) async {
    final l10n = AppLocalizations.of(context)!;
    final report = await provider.syncNow(peer.deviceId);
    if (report == null || !context.mounted) return;
    // Inline report text is rendered by the card; the snackbar covers the
    // desktop pane, where the card may have scrolled out of view.
    try {
      showAppSnackBar(
        context,
        message: syncReportMessage(l10n, report),
        type: report.success
            ? NotificationType.success
            : NotificationType.warning,
      );
    } catch (_) {
      // No overlay above this point (dialog-hosted card); the card itself
      // already shows the same line.
    }
  }

  Future<void> _rename(BuildContext context, SyncProvider provider) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: peer.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.lanSyncRenameTitle),
        content: IosDialogField(
          controller: controller,
          label: l10n.lanSyncRenameTitle,
          hint: peer.name,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    await provider.renamePeer(peer.deviceId, name);
  }

  Future<void> _editAddress(BuildContext context, SyncProvider provider) async {
    final l10n = AppLocalizations.of(context)!;
    final primary = peer.primaryEndpoint;
    final host = TextEditingController(text: primary?.host ?? '');
    final port = TextEditingController(text: '${primary?.port ?? ''}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.lanSyncEditAddress),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IosDialogField(
              controller: host,
              label: l10n.lanSyncHostLabel,
              hint: '192.168.1.10',
            ),
            IosDialogField(
              controller: port,
              label: l10n.lanSyncPortLabel,
              hint: '9527',
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    final hostText = host.text.trim();
    final portValue = int.tryParse(port.text.trim());
    host.dispose();
    port.dispose();
    if (saved != true || hostText.isEmpty || portValue == null) return;
    await provider.updatePeerEndpoint(peer.deviceId, hostText, portValue);
  }

  Future<void> _unpair(BuildContext context, SyncProvider provider) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.lanSyncUnpairConfirmTitle(peer.name)),
        content: Text(l10n.lanSyncUnpairConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.lanSyncUnpair),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await provider.unpair(peer.deviceId);
  }
}
