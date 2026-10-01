import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_engine.dart';
import '../../../core/services/sync/sync_local_addresses.dart';
import '../../../core/services/sync/sync_store.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../sync_messages.dart';
import 'sync_pairing_dialogs.dart' show IosDialogField, showSyncEnterCodeDialog;
import 'sync_report_breakdown.dart';

/// One paired device: identity, endpoint, whether it is reachable right now,
/// the last outcome, and the three actions that exist without discovery — sync
/// now, fix the address, unpair.
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
    final online = provider.isPeerOnline(peer.deviceId);
    final presence = provider.peerPresenceSource(peer.deviceId);
    final progress = provider.progressFor(peer.deviceId);
    final primary = peer.primaryEndpoint;
    final endpoint = primary?.label;
    final report = peer.lastReport;
    // How many addresses are remembered, as a count beside the one in use: a
    // peer this device has reached on two networks should not look like a peer
    // with a single address. The count rides with the address rather than being
    // one more field of the list, so it reads as "and two more like this".
    final subtitle = [
      syncPlatformLabel(l10n, peer.platform),
      if (endpoint != null)
        peer.endpoints.length > 1
            ? '$endpoint (+${peer.endpoints.length - 1})'
            : endpoint,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _PlatformBadge(
                icon: _platformIcon,
                online: online,
                presence: presence,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.medium,
                        color: cs.onSurface.withValues(alpha: 0.92),
                      ),
                    ),
                    const SizedBox(height: 2),
                    GestureDetector(
                      // The address is the one string on this card that has
                      // somewhere else to be — typed into another device, or
                      // handed to whoever is on the other end of a call. Tapping
                      // copies it, the way the app copies a path or a code.
                      onTap: endpoint == null
                          ? null
                          : () => _copyAddress(context, endpoint),
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                // The beat's label deliberately stays out of this row: an
                // address plus a candidate rank is wider than what is left
                // beside the name, and a Row measures a non-flexible child at
                // its intrinsic width before the flex children — so a long beat
                // would take the line and collapse the name to zero. Only the
                // bounded spinner sits here; the label reads one row below.
                const _SessionProgress()
              else
                TextButton.icon(
                  onPressed: () => _syncNow(context, provider),
                  icon: Icon(Lucide.RefreshCw, size: 15),
                  label: Text(l10n.lanSyncSyncNow),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (busy)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _SessionProgress(
                label: syncPhaseLabel(
                  l10n,
                  progress ??
                      const SyncSessionProgress(SyncSessionPhase.connecting),
                ),
              ),
            ),
          Tooltip(
            // The exact time is one hover away: this line answers "is this
            // current?", which a bare timestamp makes the reader work out.
            message: peer.lastSyncedAt == null
                ? l10n.lanSyncNeverSynced
                : syncAbsoluteLastSyncedLabel(l10n, peer.lastSyncedAt!),
            child: Text(
              syncLastSyncedLabel(l10n, peer.lastSyncedAt),
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          // The first session after pairing moves the whole history at once and
          // needs both apps alive — the one moment the card owes a warning.
          if (busy && peer.lastSyncedAt == null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Lucide.TriangleAlert,
                  size: 13,
                  color: context.appColors.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.lanSyncFirstSyncHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (report != null) ...[
            const SizedBox(height: 8),
            SyncReportBreakdown(
              report: report,
              // The refusal that says "pair again" gets the gesture, prefilled
              // with the address this card already shows.
              onPairAgain: () => showSyncEnterCodeDialog(
                context: context,
                host: peer.primaryEndpoint?.host,
                port: peer.primaryEndpoint?.port,
              ),
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

  Future<void> _copyAddress(BuildContext context, String endpoint) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: endpoint));
    if (!context.mounted) return;
    try {
      showAppSnackBar(
        context,
        message: l10n.lanSyncAddressCopied,
        type: NotificationType.success,
      );
    } catch (_) {
      // No overlay above this point (dialog-hosted card); the clipboard already
      // holds the address, which is what the tap was for.
    }
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
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(peer: peer),
    );
    if (name == null) return;
    await provider.renamePeer(peer.deviceId, name);
  }

  Future<void> _editAddress(BuildContext context, SyncProvider provider) async {
    final saved = await showDialog<({String host, int port})>(
      context: context,
      builder: (_) => _EditAddressDialog(peer: peer),
    );
    if (saved == null) return;
    await provider.updatePeerEndpoint(peer.deviceId, saved.host, saved.port);
  }

  Future<void> _unpair(BuildContext context, SyncProvider provider) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.lanSyncUnpairConfirmTitle(peer.displayName)),
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

/// The peer's platform icon with its reachability as a corner dot.
///
/// A dot and not a sentence: a peer being away is routine (asleep, off the
/// Wi-Fi), so it must be readable at a glance without a card that looks broken.
/// The ring is the card's own fill, which is what makes the dot sit *on* the
/// badge instead of over it.
///
/// [presence] rides along into the tooltip, because "offline" has two meanings
/// the dot cannot show: a probe that found no answer, and a session that needed
/// a real handshake and could not get one. The second is the stronger statement
/// and the one a user staring at a failed sync is asking about.
class _PlatformBadge extends StatelessWidget {
  const _PlatformBadge({
    required this.icon,
    required this.online,
    required this.presence,
  });

  final IconData icon;
  final bool online;
  final PresenceSource presence;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final label = switch (presence) {
      PresenceSource.sessionAnswered => l10n.lanSyncOnlineFromSession,
      PresenceSource.sessionSilent => l10n.lanSyncOfflineFromSession,
      PresenceSource.probe || PresenceSource.unknown =>
        online ? l10n.lanSyncOnline : l10n.lanSyncOffline,
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: cs.onSurface.withValues(alpha: 0.75),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: online
                        ? colors.success
                        : cs.onSurface.withValues(alpha: 0.3),
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.surfaceCard, width: 2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the card shows while a session runs: the spinner that says "busy", and
/// the beat it is on, because a first sync can be minutes long.
///
/// The two are separable because they have different widths to live in. The
/// header row carries only the spinner — 14dp, bounded whatever the beat says —
/// and the row below carries the label at the card's full width. A label in the
/// header row would fight the peer's name for the line, and win.
class _SessionProgress extends StatelessWidget {
  const _SessionProgress({this.label});

  /// The beat to name, or null for the bare spinner.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
        ),
        if (label != null) ...[
          const SizedBox(width: 8),
          // Flexible so a long beat — an address plus the candidate's rank —
          // gives way to the row instead of overflowing it.
          Flexible(
            child: Text(
              label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The address repair form.
///
/// It owns its controllers, like every other dialog here, because `showDialog`
/// completes when the route *pops* and not when it is gone: a controller
/// disposed at that moment is still driving a mounted field, which throws
/// "A TextEditingController was used after being disposed" while the dialog
/// plays its exit animation.
class _EditAddressDialog extends StatefulWidget {
  const _EditAddressDialog({required this.peer});

  final SyncPeerRecord peer;

  @override
  State<_EditAddressDialog> createState() => _EditAddressDialogState();
}

class _EditAddressDialogState extends State<_EditAddressDialog> {
  late final TextEditingController _host = TextEditingController(
    text: widget.peer.primaryEndpoint?.host ?? '',
  );
  late final TextEditingController _port = TextEditingController(
    text: '${widget.peer.primaryEndpoint?.port ?? ''}',
  );

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  /// Stores the same host form the pairing form stores, because the same shapes
  /// arrive here: the address the card shows and copies is bracketed (an IPv6
  /// literal in `host:port` form), so pasting it back is the obvious repair —
  /// and a stored literal that still wears its brackets is bracketed a second
  /// time at the next dial's URI.
  void _submit() {
    final host = normalizeHost(_host.text);
    final port = int.tryParse(_port.text.trim());
    // An unusable pair keeps the form open rather than closing it on a change
    // nobody asked for.
    if (host.isEmpty || port == null) return;
    Navigator.of(context).pop((host: host, port: port));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.lanSyncEditAddress),
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
            hint: '9527',
            keyboardType: TextInputType.number,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

/// The rename form, for the same ownership reason: the controller has to outlive
/// the route's exit animation.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.peer});

  final SyncPeerRecord peer;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.peer.displayName,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.lanSyncRenameTitle),
      content: IosDialogField(
        controller: _name,
        label: l10n.lanSyncRenameTitle,
        hint: widget.peer.displayName,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}
