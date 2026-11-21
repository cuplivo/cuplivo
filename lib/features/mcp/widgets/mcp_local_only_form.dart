import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/database/business_data.dart';
import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';

/// The form half of "this server stays on this device" (仅本机).
///
/// Both edit surfaces are separate widgets — the mobile sheet and the desktop
/// dialog — with their own state, and what they must share is not the row but
/// one rule: **a save may only write an answer the form actually knows.**
///
/// The state lives in a device-local set, so a form opens before it has read
/// anything, and "not read yet" renders identically to "not held". Writing the
/// default back would then mean *releasing* a hold the user set on another day
/// — the switch would turn itself off the first time a read failed. So the
/// value stays unknown until a read succeeds or the user touches the switch,
/// and [saveLocalOnly] refuses to write while it is unknown.
///
/// The read is also allowed to fail: a sync directory that cannot be resolved
/// leaves the switch at its default and the save a no-op, rather than throwing
/// out of an `initState` that nobody can catch.
mixin McpLocalOnlyForm<T extends StatefulWidget> on State<T> {
  SyncProvider? _sync;
  bool _held = false;
  bool _known = false;

  /// Whether this surface can offer the switch at all. A sheet pumped without a
  /// sync provider has nowhere to keep the answer.
  bool get canHoldLocalOnly => _sync != null;

  /// What the switch shows. Meaningful only once [canHoldLocalOnly]; an
  /// unread value renders as "not held", which [saveLocalOnly] then refuses to
  /// persist.
  bool get localOnlyHeld => _held;

  /// Call from `initState`, after `super.initState()`.
  ///
  /// [serverId] is null while creating: there is no key yet, and the choice is
  /// written once the row has one.
  void attachLocalOnly(String? serverId) {
    _sync = context.read<SyncProvider?>();
    if (serverId != null) unawaited(_loadLocalOnly(serverId));
  }

  Future<void> _loadLocalOnly(String id) async {
    final sync = _sync;
    if (sync == null) return;
    final Set<String> keys;
    try {
      keys = await sync.readLocalOnlyKeys();
    } catch (error) {
      debugPrint('mcp: reading the held set failed: $error');
      return;
    }
    if (!mounted) return;
    // The user answered while this read was in flight. Their answer is the one
    // that goes to disk: the file is a day-old copy, and overwriting the switch
    // here would write the opposite of what they just chose — a server they just
    // held would sync on the next round, command line and all.
    if (_known) return;
    setState(() {
      _held = keys.contains(localOnlyKey(id));
      _known = true;
    });
  }

  /// The user flipped the switch: their answer is the one to keep, whatever the
  /// file said or failed to say.
  void setLocalOnlyHeld(bool held) {
    setState(() {
      _held = held;
      _known = true;
    });
  }

  /// Persists the switch for a row that now has an id.
  ///
  /// Called before the row's own presentation writes: a server that is held but
  /// whose id is already in the table must not be visible to a session as
  /// unheld for the length of two more database writes (that is the window in
  /// which it would be pushed to the peer — the defect this feature exists for).
  Future<void> saveLocalOnly(String id) async {
    final sync = _sync;
    if (sync == null || id.isEmpty || !_known) return;
    try {
      await sync.setLocalOnly(localOnlyKey(id), _held);
    } catch (error) {
      // The row is already written by the time this runs, so failing the rest
      // of the save would lose the user's other edits and leave the sheet open
      // with no message. The save finishes; the *failure* is what gets said,
      // because a hold that did not persist is a row that will sync — the one
      // outcome this switch exists to prevent.
      debugPrint('mcp: writing the held set failed: $error');
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: AppLocalizations.of(
          context,
        )!.mcpServerEditSheetLocalOnlySaveFailed,
        type: NotificationType.warning,
      );
    }
  }

  /// The key the held set stores, named the way every other sync face names a
  /// row.
  static String localOnlyKey(String id) =>
      syncBusinessKey(BusinessEntityKind.mcpServer.wireName, id);
}
