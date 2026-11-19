import '../../core/database/business_preferences.dart';
import '../../core/services/json_blob_store.dart';
import '../models/dsh_remote.dart';

/// Persistence for the remote DeepSeek Harness connection records.
///
/// One JSON blob in `BusinessPreferences`, exactly like the other business
/// stores: no Drift migration, no generated code, and a serialized write queue
/// so two overlapping read-modify-write cycles cannot drop each other's
/// records. The key is registered in `BusinessKeyRegistry` as
/// `KeyPolicy.deviceLocal` — a server address is this device's network path,
/// not configuration another device should inherit, and the record must never
/// ride LAN sync. The credential (the DSH v1 cookie) is not part of this blob;
/// it lives in `flutter_secure_storage` (see `DshCredentialStore`).
class DshRemoteStore extends JsonBlobStore<DshRemote> {
  DshRemoteStore(super.preferences);

  /// `BusinessPreferences` key. Registered `deviceLocal` in
  /// `BusinessKeyRegistry.rules`; CI's writer scan fails on an unregistered
  /// key, and a debug build asserts on one.
  static const String remotesKey = 'dsh_remotes_v1';

  @override
  String get storageKey => remotesKey;

  @override
  Future<R> runExclusive<R>(Future<R> Function() operation) =>
      preferences.runExclusiveMutation(operation);

  @override
  DshRemote decodeItem(Map<String, dynamic> json) => DshRemote.fromJson(json);

  @override
  Map<String, dynamic> encodeItem(DshRemote item) => item.toJson();

  /// Every stored record, ignoring rows that decode to nothing usable.
  Future<List<DshRemote>> getAll() async {
    final all = await readAll();
    return [
      for (final remote in all)
        if (remote.id.isNotEmpty && remote.baseUrl.isNotEmpty) remote,
    ];
  }

  Future<void> add(DshRemote remote) {
    return runExclusive(() async {
      final all = await readAll();
      all.removeWhere((existing) => existing.id == remote.id);
      all.add(remote);
      await writeAll(all);
    });
  }

  Future<void> update(DshRemote remote) {
    return runExclusive(() async {
      final all = await readAll();
      final index = all.indexWhere((existing) => existing.id == remote.id);
      if (index == -1) return;
      all[index] = remote;
      await writeAll(all);
    });
  }

  Future<void> remove(String id) {
    return runExclusive(() async {
      final all = await readAll();
      all.removeWhere((existing) => existing.id == id);
      await writeAll(all);
    });
  }
}
