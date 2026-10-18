import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'dart:math' as math;

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_endpoint_prober.dart';
import '../../../core/services/sync/sync_engine.dart';
import '../../../core/services/sync/sync_limits.dart';
import '../../../core/services/sync/sync_store.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../sync_messages.dart';
import 'sync_endpoint_detail.dart';
import 'sync_pairing_dialogs.dart' show IosDialogField, showSyncEnterCodeDialog;
import 'sync_report_breakdown.dart';

/// One paired device: who it is, whether it is reachable, and what each
/// remembered address has been worth.
///
/// The header carries no IP. A peer is a device first — its name, its platform,
/// how fresh it is — and the addresses are the *tiles* underneath, one per
/// (device, network) pair, each with the one number that answers "which of
/// these is the fast one right now". Windows, phones and an office network all
/// look the same here; only the figures differ.
class SyncPeerCard extends StatelessWidget {
  const SyncPeerCard({super.key, required this.peer});

  final SyncPeerRecord peer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<SyncProvider>();
    final busy = provider.busyDeviceIds.contains(peer.deviceId);
    final online = provider.isPeerOnline(peer.deviceId);
    final progress = provider.progressFor(peer.deviceId);
    final report = peer.lastReport;
    // The address a session is going through right now, or — when none is
    // running — the one a session would try first. That is the "which channel"
    // the tiles answer at a glance. The fallback matters mid-session too: a dial
    // beat names its candidate, and the beats past the dial carry no address at
    // all, because by then the session has promoted the address that worked to
    // the head of the set.
    final activeLabel = progress?.address ?? peer.primaryEndpoint?.label;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _PlatformBadge(
                icon: syncPlatformIcon(peer.platform),
                online: online,
                presence: provider.peerPresenceSource(peer.deviceId),
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
                    _PeerSubtitle(peer: peer, online: online),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (busy)
                const _SessionProgress()
              else
                TextButton.icon(
                  onPressed: () => _syncNow(context, provider),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  icon: Icon(Lucide.RefreshCw, size: 15),
                  label: Text(l10n.lanSyncSyncNow),
                ),
              _PeerMenu(peer: peer, provider: provider),
            ],
          ),
          // The beat's label deliberately stays out of the row above: an address
          // is wider than what is left beside the name, and a Row measures a
          // non-flexible child at its intrinsic width before the flex children —
          // so a long beat would take the line and collapse the name to zero.
          // Only the bounded spinner sits up there.
          if (busy)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _SessionProgress(
                label: syncPhaseLabel(
                  l10n,
                  progress ??
                      const SyncSessionProgress(SyncSessionPhase.connecting),
                ),
              ),
            ),
          const SizedBox(height: 10),
          if (peer.endpoints.isEmpty)
            _NoAddress(peer: peer, provider: provider)
          else ...[
            _EndpointGrid(
              peer: peer,
              provider: provider,
              activeLabel: activeLabel,
            ),
            // The card must not hide the repair behind a state the user is no
            // longer in: it used to offer "add address" only while the set was
            // *empty*, so a peer remembered at one address could never be given
            // the second network it is about to be met on — the one case the
            // feature exists for. Shown until the cap, where there is genuinely
            // no room (and the add refuses rather than evicting a working
            // address).
            if (peer.endpoints.length < kMaxPeerEndpoints) ...[
              const SizedBox(height: 8),
              _AddAddressButton(peer: peer, provider: provider),
            ],
          ],
          // The first session after pairing moves the whole history at once and
          // needs both apps alive — the one moment the card owes a warning.
          if (busy && peer.lastSyncedAt == null) ...[
            const SizedBox(height: 8),
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
          if (report != null && syncReportHasRow(report)) ...[
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
}

/// The device's platform and how fresh the last session is — "Android · 2 min
/// ago" — with the "not reachable" note weakened behind it.
///
/// The note is a suffix rather than a second line because it is the weakest
/// statement on the card: a peer being away is routine, and a sentence of its
/// own would make the card look broken for a laptop that is simply asleep. It
/// shows whenever the peer is not known to be online, which includes the first
/// seconds after a launch, before any probe has answered.
class _PeerSubtitle extends StatelessWidget {
  const _PeerSubtitle({required this.peer, required this.online});

  final SyncPeerRecord peer;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final reachable = online || peer.endpoints.isEmpty;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text:
                '${syncPlatformLabel(l10n, peer.platform)} · '
                '${syncLastSyncedLabel(l10n, peer.lastSyncedAt)}',
          ),
          if (!reachable)
            TextSpan(
              text: ' · ${l10n.lanSyncTemporarilyUnreachable}',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.38)),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: cs.onSurface.withValues(alpha: 0.6),
      ),
    );
  }
}

/// The remembered addresses, three to a row: the name on top (tap it to rename)
/// and the latency underneath (tap it for the detail).
///
/// Three, because twelve is the cap and four rows of three is the most a card
/// can carry before it stops being scannable. The latency is drawn *only* when
/// the latest probe of that address answered: a stale figure beside a silent
/// address is the one thing that would make this grid lie, and the persisted
/// measurement keeps its place in the detail instead.
class _EndpointGrid extends StatelessWidget {
  const _EndpointGrid({
    required this.peer,
    required this.provider,
    required this.activeLabel,
  });

  static const _perRow = 3;

  final SyncPeerRecord peer;
  final SyncProvider provider;
  final String? activeLabel;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < peer.endpoints.length; start += _perRow) {
      final slice = peer.endpoints.sublist(
        start,
        math.min(start + _perRow, peer.endpoints.length),
      );
      final cells = <Widget>[
        for (final (index, endpoint) in slice.indexed) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(
            child: _EndpointTile(
              peer: peer,
              endpoint: endpoint,
              probe: provider.probeResultFor(
                peer.deviceId,
                endpoint.host,
                endpoint.port,
              ),
              // The tile a session is walking, or would walk first. The
              // alternative — marking the fastest — would move the highlight on
              // every tick and say nothing about what is happening now.
              active: endpoint.label == activeLabel,
            ),
          ),
        ],
        // An incomplete last row keeps the tiles the width a full row's are, so
        // 7, 8 and 9 addresses all end with the same three columns.
        for (var pad = slice.length; pad < _perRow; pad++) ...[
          const SizedBox(width: 6),
          const Expanded(child: SizedBox.shrink()),
        ],
      ];
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 6));
      rows.add(Row(children: cells));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _EndpointTile extends StatelessWidget {
  const _EndpointTile({
    required this.peer,
    required this.endpoint,
    required this.probe,
    required this.active,
  });

  final SyncPeerRecord peer;
  final SyncPeerEndpoint endpoint;
  final EndpointProbeResult? probe;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final colors = context.appColors;
    // An answer is a number: the probe result's own `answered` is carried by its
    // latency, and a silent address has neither. Nothing falls back to the
    // persisted figure — that one lives in the detail, where "when it was
    // measured" sits beside it.
    final int? latency = probe?.answered == true
        ? probe?.latency?.inMilliseconds
        : null;
    final radius = BorderRadius.circular(10);

    return Material(
      // The address is the tile's identity: it is what a test aims at, and what
      // a rename or a repair moves.
      key: ValueKey('syncEndpointTile:${endpoint.label}'),
      color: active ? cs.primary.withValues(alpha: 0.05) : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () => showSyncEndpointDetail(
          context: context,
          peer: peer,
          endpoint: endpoint,
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.12),
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (active) ...[
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // The name is the rename target and the tile is the detail
                      // target, exactly as the section's tip says.
                      onTap: () => _renameEndpoint(context),
                      child: Text(
                        endpoint.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: AppFontWeights.medium,
                          color: active
                              ? cs.primary
                              : cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                latency != null ? '$latency ms' : '—',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.semibold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: latency == null
                      ? cs.onSurface.withValues(alpha: 0.35)
                      : latency <= kSyncFastLatencyMs
                      ? colors.success
                      : cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _renameEndpoint(BuildContext context) async {
    final provider = context.read<SyncProvider>();
    final name = await showSyncEndpointNameDialog(
      context: context,
      endpoint: endpoint,
    );
    if (name == null) return;
    await provider.renamePeerEndpoint(
      peer.deviceId,
      endpoint.host,
      endpoint.port,
      name,
    );
  }
}

/// What a peer with no remembered address shows: the one state where the grid
/// cannot be drawn, and the one place an address has to be typed by hand.
class _NoAddress extends StatelessWidget {
  const _NoAddress({required this.peer, required this.provider});

  final SyncPeerRecord peer;
  final SyncProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.lanSyncNoAddress,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 6),
        _AddAddressButton(peer: peer, provider: provider),
      ],
    );
  }
}

/// The "add address" gesture, in both states: a peer with no address at all, and
/// a peer whose remembered set is not full.
///
/// One widget for both, because it is one journey — type where the other device
/// is, and this record remembers it — and the two states differ only in the
/// sentence above it.
class _AddAddressButton extends StatelessWidget {
  const _AddAddressButton({required this.peer, required this.provider});

  final SyncPeerRecord peer;
  final SyncProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return OutlinedButton.icon(
      key: const ValueKey('syncPeerCardAddAddress'),
      onPressed: () => _addAddress(context),
      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
      icon: Icon(Lucide.Plus, size: 15),
      label: Text(l10n.lanSyncAddAddress),
    );
  }

  Future<void> _addAddress(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final saved = await showSyncEndpointAddressDialog(context: context);
    if (saved == null) return;
    final outcome = await provider.addPeerEndpoint(
      peer.deviceId,
      saved.host,
      saved.port,
    );
    if (!context.mounted) return;
    // A refusal has to be said out loud: the address the user just typed was not
    // remembered, and the alternative to a line here is a save that quietly did
    // nothing — which is what this used to be.
    if (outcome == SyncEndpointAdd.full) {
      showAppSnackBar(
        context,
        message: l10n.lanSyncAddressLimit(kMaxPeerEndpoints),
        type: NotificationType.warning,
      );
    }
  }
}

/// Rename the device, or unpair it. Both used to be buttons on the card face;
/// they are the rare, deliberate actions, so they live behind the ellipsis and
/// leave the card's visible width to the addresses.
class _PeerMenu extends StatelessWidget {
  const _PeerMenu({required this.peer, required this.provider});

  final SyncPeerRecord peer;
  final SyncProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 32,
      height: 32,
      child: PopupMenuButton<_PeerAction>(
        tooltip: l10n.lanSyncMoreActions,
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(
          Lucide.Ellipsis,
          size: 18,
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
        onSelected: (action) {
          switch (action) {
            case _PeerAction.rename:
              _rename(context);
            case _PeerAction.unpair:
              _unpair(context);
          }
        },
        itemBuilder: (menuContext) => [
          PopupMenuItem(
            value: _PeerAction.rename,
            child: _MenuRow(icon: Lucide.Pencil, label: l10n.lanSyncRename),
          ),
          PopupMenuItem(
            value: _PeerAction.unpair,
            child: _MenuRow(
              icon: Lucide.Unlink,
              label: l10n.lanSyncUnpair,
              color: Theme.of(menuContext).colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(peer: peer),
    );
    if (name == null) return;
    await provider.renamePeer(peer.deviceId, name);
  }

  Future<void> _unpair(BuildContext context) async {
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

enum _PeerAction { rename, unpair }

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tint = color ?? cs.onSurface.withValues(alpha: 0.8);
    return Row(
      children: [
        Icon(icon, size: 15, color: tint),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 14, color: tint)),
      ],
    );
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
/// the dot cannot show: nothing has answered, and a session that needed a real
/// handshake could not get one. The second is the stronger statement and the one
/// a user staring at a failed sync is asking about.
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
      // The *state* comes from the same flag that paints the dot, always: a
      // session can answer ("the last sync connected") or find silence ("the
      // last sync could not connect"), and a label chosen from the source alone
      // is what once put "Online — the last sync connected" in the tooltip of a
      // grey dot.
      PresenceSource.session =>
        online ? l10n.lanSyncOnlineFromSession : l10n.lanSyncOfflineFromSession,
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
          // Flexible so a long beat — a full IPv6 address beside a long device
          // name — gives way to the row instead of overflowing it.
          Flexible(
            child: Text(
              label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.7),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The device rename form. It owns its controller, like every other dialog
/// here, because `showDialog` completes when the route *pops* and not when it is
/// gone: a controller disposed at that moment is still driving a mounted field,
/// which throws "A TextEditingController was used after being disposed" while
/// the dialog plays its exit animation.
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
