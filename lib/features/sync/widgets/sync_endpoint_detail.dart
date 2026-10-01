import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_local_addresses.dart';
import '../../../core/services/sync/sync_store.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/responsive/screen_type_helper.dart';
import '../../../shared/widgets/custom_bottom_sheet.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../sync_messages.dart';
import 'sync_pairing_dialogs.dart' show IosDialogField;

/// Under this, a round trip is "local network fast" and the figure is tinted;
/// above it the number is shown plainly, because on a LAN the interesting
/// distinction is "usable" versus "there is something wrong with this network",
/// not 12 ms versus 40 ms.
const int kSyncFastLatencyMs = 80;

/// Everything this device knows about one remembered address of [peer]: what it
/// last measured, how many sessions it has carried, when it was learned — and
/// the two repairs a user does here, edit the address or delete it.
///
/// A sheet on mobile and a dialog on desktop (`ResponsiveHelper.isDesktop`)
/// over *one* body, so the two form factors cannot drift apart. The title is
/// the peer's name: the user opened this from a tile that sits under that
/// name, and the body's own header answers "which address".
Future<void> showSyncEndpointDetail({
  required BuildContext context,
  required SyncPeerRecord peer,
  required SyncPeerEndpoint endpoint,
}) {
  final body = _EndpointDetailBody(peer: peer, endpoint: endpoint);
  if (ResponsiveHelper.isDesktop(context)) {
    // The dialog's own content padding is this body's inset — the sheet has to
    // say so for itself, which is why neither host's padding lives in the body.
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(peer.displayName),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: body,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
  }
  return showCustomBottomSheet<void>(
    context: context,
    title: peer.displayName,
    partialHeightFactor: 0.62,
    builder: (sheetContext, controller) => SingleChildScrollView(
      controller: controller,
      // Left 20 and right 16, so the header below lines up with the sheet's own
      // title row instead of with a number of its own invention.
      padding: const EdgeInsets.fromLTRB(20, 0, 16, 16),
      child: body,
    ),
  );
}

/// The detail's rows and actions. Live: it watches the provider, so the latency
/// follows the ten-second probe round while the sheet is open instead of
/// freezing the figure that was on the tile when it was tapped.
class _EndpointDetailBody extends StatelessWidget {
  const _EndpointDetailBody({required this.peer, required this.endpoint});

  final SyncPeerRecord peer;
  final SyncPeerEndpoint endpoint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<SyncProvider>();
    final live = provider.probeResultFor(
      peer.deviceId,
      endpoint.host,
      endpoint.port,
    );
    // The live probe outranks the persisted one: it is the same question asked
    // more recently. What it cannot do is answer for an address it never
    // reached — that is `answered == false`, and it is a verdict, not silence.
    // A `noVerdict` (a 503 from a saturated listener) is neither: the address
    // answered, it just declined to be judged.
    final bool? answered = live != null
        ? live.answered
        : (endpoint.lastProbedAt == null
              ? null
              : endpoint.lastLatencyMs != null);
    final int? latencyMs = answered == true
        ? (live?.latency?.inMilliseconds ?? endpoint.lastLatencyMs)
        : null;
    final measuredAt = live?.measuredAt ?? endpoint.lastProbedAt;

    // The rows with the design's hairlines between them: five label/value pairs
    // read as one table, and a table is what this is.
    final rows = <Widget>[
      _DetailRow(
        label: l10n.lanSyncEndpointLatency,
        value: _latencyText(
          l10n,
          answered: answered,
          latencyMs: latencyMs,
          noVerdict: live?.noVerdict ?? false,
        ),
        valueColor: answered == true
            ? (latencyMs != null && latencyMs <= kSyncFastLatencyMs
                  ? context.appColors.success
                  : cs.onSurface.withValues(alpha: 0.8))
            : cs.onSurface.withValues(alpha: 0.5),
      ),
      _DetailRow(
        label: l10n.lanSyncEndpointLastMeasured,
        value: syncElapsedLabel(l10n, measuredAt),
      ),
      _DetailRow(
        label: l10n.lanSyncEndpointLastReached,
        value: syncElapsedLabel(l10n, endpoint.lastSuccessAt),
      ),
      _DetailRow(
        label: l10n.lanSyncEndpointSuccessCount,
        value: l10n.lanSyncEndpointSuccessTimes(endpoint.successCount),
      ),
      _DetailRow(
        label: l10n.lanSyncEndpointAddedAt,
        value: endpoint.addedAt == null
            ? l10n.lanSyncNever
            : syncAddedAtLabel(l10n, endpoint.addedAt!),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailHeader(
          endpoint: endpoint,
          onRename: () => _rename(context),
          onCopy: () => _copy(context),
        ),
        const SizedBox(height: 4),
        _DetailRows(rows: rows),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _editAddress(context),
                child: Text(l10n.lanSyncEditAddress),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton(
                onPressed: () => _delete(context),
                style: TextButton.styleFrom(foregroundColor: cs.error),
                child: Text(l10n.lanSyncDeleteEndpoint),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _latencyText(
    AppLocalizations l10n, {
    required bool? answered,
    required int? latencyMs,
    required bool noVerdict,
  }) {
    // A 503 is the listener declining to be judged, not a silence: "Not
    // reachable" is a verdict the answer did not carry, so the figure stays a
    // dash.
    if (noVerdict) return '—';
    if (answered == false) return l10n.lanSyncEndpointUnreachable;
    if (answered == null || latencyMs == null) return '—';
    return '$latencyMs ms';
  }

  Future<void> _copy(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: endpoint.label));
    if (!context.mounted) return;
    _snack(context, l10n.lanSyncAddressCopied);
  }

  Future<void> _rename(BuildContext context) async {
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

  Future<void> _editAddress(BuildContext context) async {
    final provider = context.read<SyncProvider>();
    final saved = await showSyncEndpointAddressDialog(
      context: context,
      endpoint: endpoint,
    );
    if (saved == null) return;
    await provider.editPeerEndpoint(
      peer.deviceId,
      endpoint.host,
      endpoint.port,
      saved.host,
      saved.port,
    );
  }

  /// Deletes the address and closes the view: what the sheet is *about* just
  /// stopped existing, and a detail of nothing is worse than no detail.
  Future<void> _delete(BuildContext context) async {
    final provider = context.read<SyncProvider>();
    final navigator = Navigator.of(context);
    await provider.removePeerEndpoint(
      peer.deviceId,
      endpoint.host,
      endpoint.port,
    );
    if (navigator.canPop()) navigator.pop();
  }

  /// A dialog-hosted body has no overlay above it in some hosts (the desktop
  /// pane's dialog does, a test's does not), and a failed snackbar is not worth
  /// failing the action for: the clipboard already holds the address.
  void _snack(BuildContext context, String message) {
    try {
      showAppSnackBar(
        context,
        message: message,
        type: NotificationType.success,
      );
    } catch (_) {}
  }
}

/// The detail's header: the name (with the rename it implies), the address
/// underneath, and the copy at the right — the address is the one string here
/// that has somewhere else to be, typed into another device or handed to
/// whoever is on the other end of a call.
class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.endpoint,
    required this.onRename,
    required this.onCopy,
  });

  final SyncPeerEndpoint endpoint;
  final VoidCallback onRename;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      endpoint.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface.withValues(alpha: 0.92),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IosIconButton(
                    icon: Lucide.Pencil,
                    size: 14,
                    padding: const EdgeInsets.all(4),
                    color: cs.primary,
                    semanticLabel: l10n.lanSyncRenameEndpointTitle,
                    onTap: onRename,
                  ),
                ],
              ),
              Text(
                endpoint.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.5),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: onCopy,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(l10n.lanSyncCopy, style: const TextStyle(fontSize: 12.5)),
        ),
      ],
    );
  }
}

/// The label/value rows with the design's hairline between them: five pairs read
/// as one small table, which is what they are.
class _DetailRows extends StatelessWidget {
  const _DetailRows({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hairline = cs.onSurface.withValues(alpha: 0.08);
    return Column(
      children: [
        for (final (index, row) in rows.indexed) ...[
          if (index > 0) Divider(height: 1, thickness: 0.5, color: hairline),
          row,
        ],
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: valueColor ?? cs.onSurface.withValues(alpha: 0.8),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The rename form for one address. Returns the typed name — which may be blank,
/// meaning "use the address again" — or null when the sheet was dismissed.
///
/// It owns its controller, like every other dialog here, because `showDialog`
/// completes when the route *pops* and not when it is gone: a controller
/// disposed at that moment is still driving a mounted field, which throws
/// "A TextEditingController was used after being disposed" while the dialog
/// plays its exit animation.
Future<String?> showSyncEndpointNameDialog({
  required BuildContext context,
  required SyncPeerEndpoint endpoint,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _EndpointNameDialog(endpoint: endpoint),
  );
}

class _EndpointNameDialog extends StatefulWidget {
  const _EndpointNameDialog({required this.endpoint});

  final SyncPeerEndpoint endpoint;

  @override
  State<_EndpointNameDialog> createState() => _EndpointNameDialogState();
}

class _EndpointNameDialogState extends State<_EndpointNameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.endpoint.customName ?? '',
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
      title: Text(l10n.lanSyncRenameEndpointTitle),
      content: IosDialogField(
        controller: _name,
        label: l10n.lanSyncRenameEndpointTitle,
        hint: l10n.lanSyncRenameEndpointHint,
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

/// The address form, for the two journeys that need one: repairing a remembered
/// address ([endpoint] non-null, the address prefilled) and giving an address to
/// a peer that has none ([endpoint] null).
Future<({String host, int port})?> showSyncEndpointAddressDialog({
  required BuildContext context,
  SyncPeerEndpoint? endpoint,
}) {
  return showDialog<({String host, int port})>(
    context: context,
    builder: (_) => _EndpointAddressDialog(endpoint: endpoint),
  );
}

class _EndpointAddressDialog extends StatefulWidget {
  const _EndpointAddressDialog({this.endpoint});

  final SyncPeerEndpoint? endpoint;

  @override
  State<_EndpointAddressDialog> createState() => _EndpointAddressDialogState();
}

class _EndpointAddressDialogState extends State<_EndpointAddressDialog> {
  late final TextEditingController _host = TextEditingController(
    text: widget.endpoint?.host ?? '',
  );
  late final TextEditingController _port = TextEditingController(
    text: '${widget.endpoint?.port ?? ''}',
  );

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  /// Stores the same host form the pairing form stores, because the same shapes
  /// arrive here: the address the tile copies is `host:port` (bracketed for an
  /// IPv6 literal), so pasting it back is the obvious repair — and a stored
  /// literal that still wears its brackets is bracketed a second time at the
  /// next dial's URI.
  void _submit() {
    final host = normalizeHost(_host.text);
    final port = int.tryParse(_port.text.trim());
    // An unusable pair keeps the form open rather than closing it on a change
    // nobody asked for — and "unusable" includes a number that parses but is not
    // a port (`0`, `-1`, `70000`: the field has no input formatter, so a desktop
    // keyboard types them). The store refuses those as
    // [SyncEndpointAdd.invalid], so a form that popped on one would close the
    // sheet and drop the address with nothing said anywhere.
    if (host.isEmpty || port == null || port < 1 || port > 65535) return;
    Navigator.of(context).pop((host: host, port: port));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(
        widget.endpoint == null
            ? l10n.lanSyncAddAddress
            : l10n.lanSyncEditAddress,
      ),
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
