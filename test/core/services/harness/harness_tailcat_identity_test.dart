import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libtailcat/libtailcat.dart';

import 'package:Cuplivo/core/services/harness/harness_tailcat_identity.dart';

/// A generator that never touches `dart:ffi`: the store's persistence rules are
/// what these tests cover, not tailcat's key derivation.
TailcatKeys _keysFor(String suffix) => TailcatKeys(
  privateKey: TailcatPrivateKey('private-$suffix'),
  publicKey:
      'nodekey:${suffix.padRight(64, '0').substring(0, 64).replaceAll(RegExp(r'[^0-9a-f]'), '0')}',
  presharedKey: TailcatPresharedKey('preshared-$suffix'),
);

class _CountingGenerator {
  int calls = 0;
  final TailcatKeys Function(int call) _build;

  _CountingGenerator(this._build);

  TailcatKeys call() {
    final call = calls++;
    return _build(call);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late File identityFile;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('cuplivo-tailcat-id-');
    identityFile = File('${support.path}/harness/tailcat-client-identity.json');
  });

  tearDown(() async {
    if (await support.exists()) await support.delete(recursive: true);
  });

  test('generates one identity and keeps it across store instances', () async {
    final generator = _CountingGenerator((call) => _keysFor('${call}a'));

    final first = FileHarnessTailcatIdentityStore(
      supportDirectory: () async => support,
      generateKeys: generator.call,
    );
    final generated = await first.load();

    expect(generated.privateKey.reveal(), 'private-0a');
    expect(generated.publicKey, startsWith('nodekey:'));
    expect(await identityFile.exists(), isTrue);
    final stored = jsonDecode(await identityFile.readAsString());
    expect(stored, <String, Object?>{
      'version': 1,
      'privateKey': 'private-0a',
      'publicKey': generated.publicKey,
    });

    // A fresh store (the next app launch) reads the same identity back instead
    // of minting a new one: an allow-list entry has to survive restarts.
    final second = FileHarnessTailcatIdentityStore(
      supportDirectory: () async => support,
      generateKeys: generator.call,
    );
    final reloaded = await second.load();

    expect(reloaded.privateKey.reveal(), generated.privateKey.reveal());
    expect(reloaded.publicKey, generated.publicKey);
    expect(generator.calls, 1);
  });

  test('concurrent callers share one generation', () async {
    final generator = _CountingGenerator((call) => _keysFor('${call}b'));
    final store = FileHarnessTailcatIdentityStore(
      supportDirectory: () async => support,
      generateKeys: generator.call,
    );

    final identities = await Future.wait(<Future<HarnessTailcatIdentity>>[
      store.load(),
      store.load(),
      store.load(),
    ]);

    expect(generator.calls, 1);
    expect(identities[1].publicKey, identities[0].publicKey);
    expect(
      identities[2].privateKey.reveal(),
      identities[0].privateKey.reveal(),
    );
  });

  test('an unreadable file is replaced with a working identity', () async {
    await identityFile.parent.create(recursive: true);
    await identityFile.writeAsString('{"version":1,"privateKey":');

    final generator = _CountingGenerator((call) => _keysFor('${call}c'));
    final store = FileHarnessTailcatIdentityStore(
      supportDirectory: () async => support,
      generateKeys: generator.call,
    );

    final identity = await store.load();

    expect(identity.privateKey.reveal(), 'private-0c');
    expect(generator.calls, 1);
    final repaired = jsonDecode(await identityFile.readAsString());
    expect(repaired['privateKey'], 'private-0c');
    // The damaged file was overwritten, not kept beside the new identity.
    expect(identityFile.parent.listSync(), hasLength(1));
  });

  test('a file with a public key the plugin cannot use is replaced', () async {
    await identityFile.parent.create(recursive: true);
    await identityFile.writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'privateKey': 'private-bogus',
        'publicKey': 'nodekey:not-hex',
      }),
    );

    final generator = _CountingGenerator((call) => _keysFor('${call}d'));
    final store = FileHarnessTailcatIdentityStore(
      supportDirectory: () async => support,
      generateKeys: generator.call,
    );

    final identity = await store.load();

    expect(identity.privateKey.reveal(), 'private-0d');
    expect(identity.publicKey, matches(RegExp(r'^nodekey:[0-9a-f]{64}$')));
  });

  test('a failed load is not cached: the next call tries again', () async {
    var attempts = 0;
    final generator = _CountingGenerator((call) => _keysFor('${call}e'));
    final store = FileHarnessTailcatIdentityStore(
      supportDirectory: () async {
        attempts += 1;
        if (attempts == 1) throw const FileSystemException('disk unavailable');
        return support;
      },
      generateKeys: generator.call,
    );

    await expectLater(store.load(), throwsA(isA<FileSystemException>()));
    final identity = await store.load();

    expect(attempts, 2);
    expect(identity.privateKey.reveal(), 'private-0e');
  });

  test('the identity toString never carries the private key', () {
    final identity = HarnessTailcatIdentity(
      privateKey: const TailcatPrivateKey('private-super-secret'),
      publicKey: 'nodekey:${'a' * 64}',
    );

    expect(identity.toString(), contains('nodekey:'));
    expect(identity.toString(), isNot(contains('private-super-secret')));
  });
}
