import 'dart:io';

import 'package:Cuplivo/utils/kelivo_file_uri.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'sandbox_canonical_storage_test_',
    );
    SandboxPathResolver.debugSetDirs(docsDir: temp.path);
  });

  tearDown(() async {
    SandboxPathResolver.debugSetDirs();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('canonicalStorage', () {
    test('passes a kelivo-file URI through unchanged', () {
      const uri = 'kelivo-file:///avatars/a.png';
      expect(SandboxPathResolver.canonicalStorage(uri), uri);
    });

    test('canonicalizes a legacy absolute path under the managed root', () {
      final input = '${temp.path.replaceAll('\\', '/')}/avatars/avatar_123.jpg';
      final stored = SandboxPathResolver.canonicalStorage(input);
      expect(stored, 'kelivo-file:///avatars/avatar_123.jpg');
      // The canonical form must resolve back onto the same file (separators
      // are platform-native on the way out).
      expect(p.normalize(SandboxPathResolver.fix(stored)), p.normalize(input));
    });

    test('falls back to the legacy fixed form outside managed storage', () {
      final stored = SandboxPathResolver.canonicalStorage(
        '/definitely/not/managed.bin',
      );
      expect(KelivoFileUri.isKelivoFileUri(stored), isFalse);
    });
  });
}
