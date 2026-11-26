import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pairing form's failure table: which wire refusal becomes which line.
///
/// Every code here is produced by a *listener this device does not own*, so the
/// table is the only place that decides what the user is told — and the wrong
/// answer is not cosmetic: `unreachable` advises checking the address and port,
/// which is false for a device that answered and refused.
void main() {
  /// The provider's table is static and pure, so no provider instance (and no
  /// database) is needed to drive it.
  SyncPairOutcome map(String code, {int? status}) =>
      SyncProvider.mapPairError(SyncClientException(code, statusCode: status));

  test('a refusal the listener sent keeps its own meaning', () {
    expect(map('pair_busy', status: 503).errorCode, 'busy');
    expect(map('invalid_pin', status: 403).errorCode, 'invalid_pin');
    expect(map('pair_no_certificate').errorCode, 'no_certificate');
    expect(map('pair_identity_mismatch').errorCode, 'id_mismatch');
    expect(map('pair_fingerprint_mismatch').errorCode, 'fingerprint_mismatch');
    expect(map('pair_busy', status: 503).success, isFalse);
  });

  test('an unknown refusal is reported as unreachable, with its detail', () {
    // The fallback is for a listener that failed in a way this table does not
    // know — a connection that never got an answer at all. The detail carries
    // the code so a bug report can name it.
    final unknown = map('something_new', status: 500);
    expect(unknown.errorCode, 'unreachable');
    expect(unknown.errorDetail, 'something_new (500)');

    final bare = map('timeout');
    expect(bare.errorCode, 'unreachable');
    expect(bare.errorDetail, 'timeout');
  });
}
