// The sending label reads count first, bytes second.
//
// gen-l10n orders a message's placeholders alphabetically, so
// `lanSyncPhaseSendingOf` is `(bytes, done, total)` — the reverse of how the
// sentence reads. All three parameters are `Object`, so a call site that passes
// them in reading order compiles and renders `Sending 12/1.20 MB · 3`.
import 'package:Cuplivo/features/sync/sync_messages.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the sending label puts the count before the bytes', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    // What the engine publishes mid-push: 3 of 12 conversations, 1.2 MB moved.
    final progress = SyncSessionProgress(
      SyncSessionPhase.sending,
      done: 3,
      total: 12,
      bytes: 1258291,
    );
    final label = syncPhaseLabel(l10n, progress);
    // ignore: avoid_print
    print('PROBE label: $label');
    expect(label, 'Sending 3/12 · 1.20 MB');
  });
}
