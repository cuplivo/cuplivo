import 'package:flutter/widgets.dart';

import 'package:Cuplivo/l10n/app_localizations.dart';

import '../models/dsh_remote.dart';
import '../state/dsh_gateway.dart';

/// The localized sentence for a link failure class.
///
/// One mapping for every surface (creation form, settings page, owner rows) so
/// the same failure never reads differently in two places. Technical detail is
/// deliberately not appended: it is for logs, and raw English/HTTP text in a
/// Cuplivo surface is worse than a short sentence.
String dshFailureText(AppLocalizations l10n, DshFailure? failure) {
  return switch (failure) {
    null => l10n.dshErrorUnknown,
    DshFailure.notConfigured => l10n.dshErrorNotConfigured,
    DshFailure.unreachable => l10n.dshErrorUnreachable,
    DshFailure.auth => l10n.dshErrorAuth,
    DshFailure.protocol => l10n.dshErrorProtocol,
    DshFailure.unsupported => l10n.dshErrorUnsupported,
    DshFailure.unknown => l10n.dshErrorUnknown,
  };
}

/// The localized label for a link state (also used as the status dot's
/// semantic label).
String dshLinkStatusText(AppLocalizations l10n, DshLinkStatus status) {
  return switch (status.state) {
    DshLinkState.idle => l10n.dshStatusIdle,
    DshLinkState.connecting => l10n.dshStatusConnecting,
    DshLinkState.ready => l10n.dshStatusReady,
    DshLinkState.failed => dshFailureText(l10n, status.failure),
  };
}

/// The name to show for a record: the stored one, or the product name for a
/// record created before a name was set.
String dshRemoteDisplayName(AppLocalizations l10n, DshRemote remote) {
  final name = remote.name.trim();
  return name.isEmpty ? l10n.dshProductName : name;
}

/// The failure carried by a record whose last connect attempt failed (after a
/// restart the live [DshLinkStatus] is gone; `lastError` keeps the reason).
DshFailure? dshRemoteFailure(DshRemote remote) =>
    dshFailureFromName(remote.lastError);
