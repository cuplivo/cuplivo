import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const guestPath =
      'PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:'
      '/usr/sbin:/usr/bin:/sbin:/bin';

  test('all sandbox environment sources expose user-local executables', () {
    for (final path in <String>[
      'android/app/src/main/kotlin/com/cup11/cuplivo/LinuxSandboxPlugin.kt',
      'ios/Runner/iSHSandbox/CuplivoISHExecutor.m',
      'tools/ios_rootfs/prepare_alpine_fakefs.py',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains(guestPath),
        reason: '$path must expose /root/.local/bin to sandbox commands',
      );
    }
  });

  test('Android non-interactive commands do not load login profiles', () {
    final source = File(
      'android/app/src/main/kotlin/com/cup11/cuplivo/LinuxSandboxPlugin.kt',
    ).readAsStringSync();

    // The shell is chosen at runtime (bash when the rootfs provides it,
    // busybox sh otherwise), but non-interactive commands must still use
    // `-c` rather than the login `-lc` form.
    expect(source, contains('listOf(shell, "-c", command)'));
    expect(source, isNot(contains('-lc')));
    expect(source, contains('guestShellFor'));
  });
}
