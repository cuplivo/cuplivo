import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import 'sync_report_dialog.dart';

/// Turns automatic-sync arrivals into the toast a user away from the sync
/// panel sees: "Synced with `peer`", one tap away from the full report. A
/// pass-through wrapper mounted once at the app root, so it is alive wherever
/// the user is; it renders nothing of its own.
///
/// The provider decides *whether* to announce — an automatic session that
/// brought data to this device, with no sync panel mounted to show the same
/// news on its cards — and this widget decides only what the announcement
/// looks like.
class SyncArrivalAnnouncer extends StatefulWidget {
  const SyncArrivalAnnouncer({super.key, required this.child});

  final Widget child;

  @override
  State<SyncArrivalAnnouncer> createState() => _SyncArrivalAnnouncerState();
}

class _SyncArrivalAnnouncerState extends State<SyncArrivalAnnouncer> {
  StreamSubscription<SyncArrival>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = context.read<SyncProvider>().autoSyncArrivals.listen(
      _announce,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _announce(SyncArrival arrival) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    // The dialog rides the root navigator — the app's main one — so it opens
    // above whatever the user is looking at, the same surface the toast
    // manager itself falls back to.
    final dialogContext = rootNavigatorKey.currentContext;
    if (l10n == null || dialogContext == null) return;
    showAppSnackBar(
      context,
      message: l10n.lanSyncArrivalToast(arrival.peerName),
      type: NotificationType.success,
      // Long enough to reach for the action; a toast nobody can tap in time
      // is a tease.
      duration: const Duration(seconds: 5),
      actionLabel: l10n.lanSyncArrivalDetails,
      onAction: () => showSyncReportDialog(
        dialogContext,
        title: arrival.peerName,
        report: arrival.report,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
